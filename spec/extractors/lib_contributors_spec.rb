# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/lib_extractor'
require 'woods/dependency_graph'
require 'woods/extractor'

RSpec.describe 'Library contributors' do
  include_context 'extractor setup'

  def fragments
    [create_file('lib/shared_library.rb', "module SharedLibrary\n  ONE = :one\nend\n"),
     create_file('lib/shared_library/version.rb', "module SharedLibrary\n  VERSION = 'é'\nend\n")]
  end

  it 'aggregates a reopened owner with every original file and exact fragment bytes' do
    paths = fragments
    units = Woods::Extractors::LibExtractor.new.extract_all
    expect(units.size).to eq(1)
    unit = units.first
    expect(unit.identifier).to eq('SharedLibrary')
    expect(unit.metadata[:defined_in]).to eq(%w[lib/shared_library.rb lib/shared_library/version.rb])
    records = unit.metadata.fetch(:source_contributors)
    records.zip(paths).each do |record, path|
      fragment = unit.source_code.byteslice(record.fetch('published_start_byte')...record.fetch('published_end_byte'))
      expect(fragment).to eq(File.read(path, encoding: 'UTF-8'))
      expect(record.fetch('source_sha256')).to eq(Digest::SHA256.hexdigest(fragment))
    end
  end

  it 'decodes Unicode contributors independently of the process external encoding' do
    fragments
    original = Encoding.default_external
    begin
      Encoding.default_external = Encoding::US_ASCII
      unit = Woods::Extractors::LibExtractor.new.extract_all.fetch(0)
      expect(unit.source_code.encoding).to eq(Encoding::UTF_8)
      expect(unit.source_code).to include("VERSION = 'é'")
    ensure
      Encoding.default_external = original
    end
  end

  it 'returns the complete aggregate through either direct file entry point' do
    paths = fragments
    extractor = Woods::Extractors::LibExtractor.new
    units = paths.map { |path| extractor.extract_lib_file(path) }
    expect(units.map(&:source_code).uniq.size).to eq(1)
    expect(units.first.source_code).to include('ONE = :one', "VERSION = 'é'")
  end

  it 'does not merge a class and module with the same spelling' do
    create_file('lib/a.rb', 'class SharedLibrary; end')
    create_file('lib/b.rb', "module SharedLibrary\nend\n")
    expect(Woods::Extractors::LibExtractor.new.extract_all.size).to eq(2)
  end

  it 'does not merge a path fallback with an actual declaration' do
    create_file('lib/shared_library.rb', 'puts :unexecuted')
    create_file('lib/other.rb', "module SharedLibrary\nend\n")
    expect(Woods::Extractors::LibExtractor.new.extract_all.size).to eq(2)
  end

  it 'persists secondary path ownership without confusing another type of the same name' do
    paths = fragments
    unit = Woods::Extractors::LibExtractor.new.extract_all.first
    other = Woods::ExtractedUnit.new(type: :configuration, identifier: unit.identifier,
                                     file_path: File.join(tmp_dir, 'service.rb'))
    graph = Woods::DependencyGraph.new
    graph.register(unit)
    graph.register(other)
    restored = Woods::DependencyGraph.from_h(JSON.parse(JSON.generate(graph.to_h)))
    expect(restored.units_for_path(paths.last)).to eq([['SharedLibrary', :lib]])
    restored.remove('SharedLibrary', type: :lib)
    expect(restored.units_for_path(paths.last)).to be_empty
    expect(restored.node('SharedLibrary', type: :configuration)).not_to be_nil
  end

  it 'preserves core-extension definitions and conflicting scalar facts without loading source' do
    create_file('lib/a_string.rb', "class String; def initialize(one); raise 'never run'; end; end")
    create_file('lib/b_string.rb', 'class String; def initialize(two, three); end; end')
    unit = Woods::Extractors::LibExtractor.new.extract_all.fetch(0)
    expect(unit.identifier).to eq('String')
    expect(unit.metadata).not_to have_key(:initialize_params)
    expect(unit.metadata[:source_contributors].map { |record| record['facts'][:initialize_params] }.uniq.size).to eq(2)
    expect(unit.source_code).to include("raise 'never run'")
  end

  it 'does not combine an alias or unresolved autoload with another spelling of that owner' do
    stub_const('LibraryOriginal', Module.new)
    stub_const('LibraryAlias', LibraryOriginal)
    create_file('lib/a.rb', "module LibraryAlias\nend\n")
    create_file('lib/b.rb', "module LibraryAlias\nend\n")
    units = Woods::Extractors::LibExtractor.new.extract_all
    expect(units.map(&:identifier)).to eq(%w[LibraryAlias LibraryAlias])
  end

  it 'retains refusal for a value-class assignment colliding with a declaration' do
    create_file('lib/a.rb', 'SharedLibrary = Struct.new(:id)')
    create_file('lib/shared_library.rb', 'class SharedLibrary; end')
    stub_const('SharedLibrary', Struct.new(:id))
    expect(Woods::Extractors::LibExtractor.new.extract_all.size).to eq(2)
  end

  it 'refuses incompatible or dynamic superclass declarations without invoking them' do
    create_file('lib/a.rb', 'class LibraryParent; end')
    create_file('lib/b.rb', 'class LibraryParent < Object; end')
    create_file('lib/c.rb', "class LibraryParent < raise('must not execute'); end")
    expect(Woods::Extractors::LibExtractor.new.extract_all.size).to eq(3)
  end

  it 'keeps cached source paths independent of writer normalization' do
    paths = fragments
    extractor = Woods::Extractors::LibExtractor.new
    File.delete(paths.last)
    extractor.extract_lib_file(paths.first).file_path = 'lib/shared_library.rb'
    expect(extractor.extract_all.first.file_path).to eq(paths.first)
  end

  it 'retains publication refusal for incompatible same-name declarations' do
    create_file('lib/a.rb', 'class SharedLibrary; end')
    create_file('lib/b.rb', "module SharedLibrary\nend\n")
    units = Woods::Extractors::LibExtractor.new.extract_all
    expect(units.map(&:identifier)).to eq(%w[SharedLibrary SharedLibrary])
    expect { Woods::Extractor.allocate.send(:deduplicate_type_units, :libs, units) }
      .to raise_error(Woods::IdentityCollisionError)
  end

  it 'refuses the contributor set if one physical source cannot be read' do
    paths = fragments
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(paths.last, encoding: 'UTF-8').and_raise(Errno::EACCES)
    expect { Woods::Extractors::LibExtractor.new.extract_all }
      .to raise_error(Woods::ExtractionError, /complete library contributor set/)
  end

  it 'names an invalid UTF-8 contributor in the log and refuses a partial aggregate' do
    paths = fragments
    File.binwrite(paths.last, "module SharedLibrary; VALUE = '\xFF'; end".b)
    expect(Rails.logger).to receive(:error).with(include(paths.last, 'Source is not valid UTF-8'))

    expect { Woods::Extractors::LibExtractor.new.extract_all }
      .to raise_error(Woods::ExtractionError, /complete library contributor set/)
  end

  it 'does not load a pending autoload to authorize aggregation' do
    stub_const('PendingLibrary', Module.new)
    pending_file = create_file('pending.rb', "raise 'must not load'")
    PendingLibrary.autoload(:Child, pending_file)
    create_file('lib/a.rb', 'class PendingLibrary::Child; end')
    create_file('lib/b.rb', 'class PendingLibrary::Child; end')
    expect(Woods::Extractors::LibExtractor.new.extract_all.size).to eq(2)
    expect(PendingLibrary.autoload?(:Child)).to eq(pending_file)
  end
end
