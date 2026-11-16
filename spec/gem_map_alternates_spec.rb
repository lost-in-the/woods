# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/gem_mapper'
require 'woods/published_index'
require 'woods/mcp/index_reader'

RSpec.describe 'Self-map alternative definitions of one method' do
  around do |example|
    Dir.mktmpdir('woods-alternates') do |directory|
      @root = Pathname.new(directory).join('gem')
      @output = Pathname.new(directory).join('index')
      example.run
    end
  end

  def write(path, source)
    destination = @root.join(path)
    FileUtils.mkdir_p(destination.dirname)
    File.write(destination, source)
  end

  def map!
    Woods::GemMapper.new(root: @root, output_dir: @output).map!
  end

  def published_methods
    index = Woods::PublishedIndex.open(@output.to_s)
    index.units(type: 'ruby_method').to_h do |entry|
      unit = index.unit(entry['identifier'], type: 'ruby_method')
      [entry['identifier'], unit.values_at('source_code', 'file_path')]
    end
  ensure
    index&.close
  end

  def method_artifacts
    Dir.children(Woods::Generation.new(output_dir: @output.to_s).payload_dir.join('ruby_methods')) - ['_index.json']
  end

  it 'publishes each if/elsif/else body under its own identifier and artifact, in source order' do
    write('lib/woods/alt.rb', <<~RUBY)
      class Alt
        if RUBY_VERSION > '4'
          def pick; :four; end
        elsif RUBY_VERSION > '3'
          def pick; :three; end
        else
          def pick; :old; end
        end
      end
    RUBY
    map!

    methods = published_methods
    expect(methods.keys).to eq(['Alt#pick', 'Alt#pick [lib/woods/alt.rb, occurrence 2]',
                                'Alt#pick [lib/woods/alt.rb, occurrence 3]'])
    expect(methods.values.map(&:first)).to eq(["def pick; :four; end\n", "def pick; :three; end\n",
                                               "def pick; :old; end\n"].map { |text| "    #{text}" })
    expect(method_artifacts.size).to eq(3)
  end

  it 'publishes two alternatives, unless/else and modifier forms, under distinct identifiers' do
    write('lib/woods/unless.rb', <<~RUBY)
      class Unless
        unless RUBY_VERSION > '3'
          def pick = :old
        else
          def pick = :new
        end
      end
    RUBY
    write('lib/woods/modifier.rb', <<~RUBY)
      class Modifier
        def pick = :new if RUBY_VERSION > '3'
        def pick = :old unless RUBY_VERSION > '3'
      end
    RUBY
    map!

    expect(published_methods.keys).to eq(['Modifier#pick', 'Modifier#pick [lib/woods/modifier.rb, occurrence 2]',
                                          'Unless#pick', 'Unless#pick [lib/woods/unless.rb, occurrence 2]'])
    expect(method_artifacts.size).to eq(4)
  end

  it 'keeps a single definition under its plain identifier' do
    write('lib/woods/alt.rb', "class Alt\n  def pick; :only; end\nend\n")
    map!

    expect(published_methods.keys).to eq(['Alt#pick'])
  end

  it 'keeps the file-path form for a method defined once in each of two files' do
    write('lib/woods/alt.rb', "class Alt\n  def pick; :a; end\nend\n")
    write('lib/woods/other.rb', "class Alt\n  def pick; :b; end\nend\n")
    map!

    expect(published_methods.keys).to eq(['Alt#pick', 'Alt#pick [lib/woods/other.rb]'])
  end

  it 'numbers alternatives within the later of two files after the file-path form' do
    write('lib/woods/alt.rb', "class Alt\n  def pick; :a; end\nend\n")
    write('lib/woods/other.rb', "class Alt\n  if A\n    def pick; :b; end\n  else\n    def pick; :c; end\n  end\nend\n")
    map!

    expect(published_methods.transform_values { |source, _| source.strip }).to eq(
      'Alt#pick' => 'def pick; :a; end', 'Alt#pick [lib/woods/other.rb]' => 'def pick; :b; end',
      'Alt#pick [lib/woods/other.rb, occurrence 2]' => 'def pick; :c; end'
    )
  end

  it 'resolves the canonical identifier and links every alternative to it' do
    write('lib/woods/alt.rb', "class Alt\n  if A\n    def pick; :a; end\n  else\n    def pick; :b; end\n  end\nend\n")
    write('lib/woods/caller.rb', "class Caller\n  def run; Alt.new.pick; end\nend\n")
    map!

    reader = Woods::MCP::IndexReader.new(@output.to_s)
    alternate = 'Alt#pick [lib/woods/alt.rb, occurrence 2]'
    expect(reader.find_unit('Alt#pick')).to include('file_path' => 'lib/woods/alt.rb', 'type' => 'ruby_method')
    expect(reader.find_unit(alternate).dig('metadata', 'canonical_identifier')).to eq('Alt#pick')
    expect(reader.traverse_dependents('Alt#pick', depth: 1)[:nodes].keys).to include(alternate)
    expect(reader.traverse_dependents('Alt', depth: 1)[:nodes].keys).to include('Caller#run')
  end

  describe Woods::GemMapPublisher do
    def unit(identifier, path)
      Woods::ExtractedUnit.new(type: :ruby_method, identifier: identifier, file_path: path).tap do |unit|
        unit.metadata = {}
      end
    end

    it 'refuses two units that would be written to one artifact, naming both sources' do
      payload = Pathname.new(Dir.mktmpdir('woods-publisher'))
      units = [unit('Alt#pick', 'lib/woods/a.rb'), unit('Alt#pick', 'lib/woods/b.rb')]
      publisher = described_class.new(payload: payload, units: units, graph: Woods::DependencyGraph.new,
                                      checksum: 'x', health: {})

      expect { publisher.write }.to raise_error(Woods::ExtractionError, %r{lib/woods/a\.rb.*lib/woods/b\.rb})
      expect(payload.join('ruby_methods')).not_to exist
    ensure
      FileUtils.rm_rf(payload) if payload
    end

    it 'publishes no generation when a collision reaches the writer' do
      write('lib/woods/alt.rb', "class Alt\n  if A\n    def pick; :a; end\n  else\n    def pick; :b; end\n  end\nend\n")
      allow_any_instance_of(Woods::GemMapSource).to receive(:disambiguate!)

      expect { map! }.to raise_error(Woods::ExtractionError, /artifact/)
      expect(Woods::Generation.new(output_dir: @output.to_s).current.number).to eq(0)
    end
  end
end
