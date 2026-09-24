# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

RSpec.describe Woods::Extractor, 'identity collisions' do
  include_context 'isolated Woods runtime'

  let(:root) { Dir.mktmpdir('woods-identities') }
  let(:extractor) { described_class.new(output_dir: File.join(root, 'index')) }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(root), logger: double('Logger').as_null_object))
    extractor.instance_variable_set(:@eager_load_complete, true)
  end

  after { FileUtils.rm_rf(root) }

  def unit(path, type = :poro)
    Woods::ExtractedUnit.new(type: type, identifier: 'SharedIdentity', file_path: path)
  end

  def source(name)
    path = File.join(root, 'app/models', name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '# source')
    path
  end

  def register(*units)
    key = described_class::TYPE_TO_EXTRACTOR_KEY.fetch(units.first.type)
    extractor.send(:register_and_write, key, units, Set.new)
  end

  it 'rejects a new source claiming a retained typed identity before registration' do
    first = source('first.rb')
    second = source('second.rb')
    extractor.dependency_graph.register(unit(first))
    expect { register(unit(second)) }.to raise_error(Woods::ExtractionError, /same-type identifier collision/)
    expect(extractor.dependency_graph.node('SharedIdentity', type: :poro)[:file_path]).to eq(first)
  end

  it 'rejects two fresh claims even after the first source disappears' do
    first = source('first.rb')
    register(unit(first))
    File.unlink(first)
    expect { register(unit(source('second.rb'))) }.to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'checks a whole batch before writing any of its conflicting units' do
    expect(extractor).not_to receive(:write_unit_file)
    expect { register(unit(source('first.rb')), unit(source('second.rb'))) }
      .to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'accepts repeated same-file results and relative versus absolute paths' do
    path = source('first.rb')
    relative = path.delete_prefix("#{root}/")
    expect(register(unit(path), unit(relative))).to eq(Set['SharedIdentity'])
    expect { register(unit(path)) }.not_to raise_error
  end

  it 'keeps different unit types independent' do
    register(unit(source('first.rb')))
    expect { register(unit(source('second.rb'), :service)) }.not_to raise_error
    expect(extractor.dependency_graph.node_types('SharedIdentity')).to contain_exactly(:poro, :service)
  end

  it 'accepts a retained source move after its old regular file is removed' do
    first = source('first.rb')
    extractor.dependency_graph.register(unit(first))
    File.unlink(first)
    second = source('second.rb')
    expect { register(unit(second)) }.not_to raise_error
    expect(extractor.dependency_graph.node('SharedIdentity', type: :poro)[:file_path]).to eq(second)
  end

  it 'does not mistake a dangling symlink for a removed source' do
    first = source('first.rb')
    extractor.dependency_graph.register(unit(first))
    File.unlink(first)
    File.symlink(File.join(root, 'missing'), first)
    expect { register(unit(source('second.rb'))) }.to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'rejects fileless versus file-owned claims' do
    extractor.dependency_graph.register(unit(nil))
    expect { register(unit(source('second.rb'))) }.to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'propagates a wholesale collision before the first mutation' do
    consumer = double('PoroExtractor', extract_all: [unit(source('first.rb')), unit(source('second.rb'))])
    extractor.instance_variable_set(:@incremental_extractors, { poros: consumer })
    expect { extractor.send(:replace_type_wholesale, :poros, Set.new) }
      .to raise_error(Woods::ExtractionError, /collision/)
    expect(extractor.dependency_graph.node('SharedIdentity')).to be_nil
  end

  it 'allows authoritative wholesale replacement to relocate a framework source' do
    old = source('old.rb')
    replacement = source('new.rb')
    extractor.dependency_graph.register(unit(old, :rails_source))
    consumer = double('FrameworkExtractor', extract_all: [unit(replacement, :rails_source)])
    extractor.instance_variable_set(:@incremental_extractors, { rails_source: consumer })
    expect { extractor.send(:replace_type_wholesale, :rails_source, Set.new) }.not_to raise_error
    expect(extractor.dependency_graph.node('SharedIdentity', type: :rails_source)[:file_path]).to eq(replacement)
  end

  it 'does not grant replacement authority to incomplete runtime discovery' do
    old = source('old.rb')
    extractor.dependency_graph.register(unit(old, :controller))
    consumer = double('ControllerExtractor', extract_all: [unit(source('new.rb'), :controller)])
    extractor.instance_variable_set(:@incremental_extractors, { controllers: consumer })
    extractor.instance_variable_set(:@eager_load_complete, false)
    expect { extractor.send(:replace_type_wholesale, :controllers, Set.new) }
      .to raise_error(Woods::ExtractionError, /collision/)
    expect(extractor.dependency_graph.node('SharedIdentity', type: :controller)[:file_path]).to eq(old)
  end

  it 'refuses cross-source identities that share one extractor payload path' do
    a = unit(source('first.rb'), :graphql_type)
    b = unit(source('second.rb'), :graphql_query)
    expect { extractor.send(:deduplicate_type_units, :graphql, [a, b]) }
      .to raise_error(Woods::ExtractionError, /collision/)
  end
end
