# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/source_references/cache'
require 'woods/source_references/collector'

RSpec.describe Woods::SourceReferences::Cache do
  around do |example|
    Dir.mktmpdir('woods-reference-cache') do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, described_class::FILE_NAME) }
  let(:analysis) do
    Woods::SourceReferences::Collector.new.call(<<~RUBY)
      class Caller
        MissingTarget.call
        class << self
          TokenCodec.decode
        end
        factory::Dynamic.call
      end
    RUBY
  end
  let(:data) do
    {
      'version' => described_class::VERSION,
      'callers' => { 'poro' => %w[lib model] },
      'files' => { 'app/models/caller.rb' => { 'identity' => 'a' * 64, 'analysis' => analysis } },
      'owners' => [{ 'type' => 'poro', 'identifier' => 'Caller', 'file_path' => 'app/models/caller.rb',
                     'added' => [{ 'type' => 'lib', 'target' => 'TokenCodec', 'via' => 'code_reference' }] }]
    }
  end

  def write_json(value)
    File.write(path, JSON.generate(value))
  end

  it 'returns nil only for a missing cache' do
    expect(described_class.read(path)).to be_nil
    write_json({})
    expect { described_class.read(path) }.to raise_error(described_class::Invalid)
  end

  it 'round trips unresolved candidates, singleton context and pass-owned edges unchanged' do
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it 'round trips optional selector evidence including operators without adding it to bare constants' do
    data['files'].values.first['analysis'] = Woods::SourceReferences::Collector.new.call(
      'class Caller; Target.call; Target[Argument] = Value; Target + Other; Target; end'
    )
    records = data['files'].values.first['analysis'].fetch('references')
    expect(records.map { |record| record['method'] }).to eq(['call', '[]=', nil, nil, '+', nil, nil])
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
  end

  it 'requires format 8 and refuses format 7 so unchanged callers gain mixin tags after a full rebuild' do
    expect(described_class::VERSION).to eq(8)
    write_json(data.merge('version' => 7))
    expect { described_class.read(path) }.to raise_error(described_class::Invalid, /unsupported version/)
  end

  it 'round trips declaration macros and rejects a macro outside the declaration set' do
    data['files'].values.first['analysis'] = Woods::SourceReferences::Collector.new.call(
      "class Caller\n  belongs_to :author\n  before_save :set_slug, :touch_it\n  scope :recent, -> {}\nend\n"
    )
    described_class.write(path, data)
    macros = described_class.read(path).dig('files', 'app/models/caller.rb', 'analysis', 'macros')
    expect(macros.map { |record| record.values_at('macro', 'name') })
      .to eq([%w[belongs_to author], %w[before_save set_slug], %w[before_save touch_it], %w[scope recent]])
    data['files'].values.first['analysis']['macros'].first['macro'] = 'define_method'
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid, /declaration macro/)
  end

  [nil, '', 1, true, false, [], {}, "call\n", "call\0", "call\u0085", "\xFF".b, 'a' * 4097].each do |value|
    it "rejects invalid selector evidence #{value.inspect}" do
      analysis['references'].first['method'] = value
      expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
      unless value.is_a?(String) && !value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        write_json(data)
        expect { described_class.read(path) }.to raise_error(described_class::Invalid)
      end
    end
  end

  it 'round trips a mixin tag and rejects any value other than include, extend or prepend' do
    data['files'].values.first['analysis'] = Woods::SourceReferences::Collector.new.call(
      'class Caller; include A; extend B; prepend C; D; end'
    )
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
    ['load', '', nil, :include, 1].each do |value|
      data['files'].values.first['analysis']['references'].first['mixin'] = value
      expect { described_class.write(path, data) }.to raise_error(described_class::Invalid, /mixin/)
    end
  end

  it 'allows an absent optional selector without claiming semantic completeness' do
    analysis['references'].each { |record| record.delete('method') }
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
  end

  it 'records the caller policy that produced the edges' do
    data.delete('callers')
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid, /record keys/)
  end

  it 'refuses a format 3 cache so an upgraded index is rebuilt by a full extraction' do
    data.delete('callers')
    write_json(data.merge('version' => 3))
    expect { described_class.read(path) }.to raise_error(described_class::Invalid, /unsupported version/)
  end

  {
    'a caller type outside the registry' => { 'route' => %w[model] },
    'a target type outside the registry' => { 'poro' => %w[route] },
    'an empty target list' => { 'poro' => [] },
    'unsorted targets' => { 'poro' => %w[model lib] },
    'repeated targets' => { 'poro' => %w[lib lib] },
    'a non-array target list' => { 'poro' => 'all' },
    'a non-hash policy' => [%w[poro lib]]
  }.each do |label, callers|
    it "rejects a caller policy with #{label}" do
      data['callers'] = callers
      expect { described_class.write(path, data) }.to raise_error(described_class::Invalid, /caller policy/)
    end
  end

  it 'refuses format 4 records without positions' do
    analysis['references'].each do |record|
      record.delete('column')
      record.delete('length')
    end
    write_json(data.merge('version' => 4))
    expect { described_class.read(path) }.to raise_error(described_class::Invalid, /unsupported version/)
  end

  [['column', nil], ['column', -1], ['column', 1.5], ['column', 1_000_000_001],
   ['length', nil], ['length', 0], ['length', -1], ['length', true], ['length', 1_000_000_001]].each do |key, value|
    it "rejects invalid position #{key}=#{value.inspect}" do
      analysis['references'].first[key] = value
      expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
    end
  end

  it 'accepts an empty cache and a library source path' do
    empty = { 'version' => described_class::VERSION, 'callers' => {}, 'files' => {}, 'owners' => [] }
    described_class.write(path, empty)
    expect(described_class.read(path)).to eq(empty)
    data['files']['lib/token_codec.rb'] = data['files'].values.first
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
  end

  it 'preserves a hardlinked generation seed on replacement' do
    described_class.write(path, data)
    seed = File.join(@dir, 'previous.json')
    File.link(path, seed)
    original = File.binread(seed)
    data['owners'].first['added'].clear
    described_class.write(path, data)
    expect(File.binread(seed)).to eq(original)
    expect(described_class.read(path)).to eq(data)
    expect(File.stat(path).ino).not_to eq(File.stat(seed).ino)
  end

  it 'leaves the existing cache unchanged when validation fails' do
    described_class.write(path, data)
    original = File.binread(path)
    data['files'].values.first['source_code'] = 'private application source'
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
    expect(File.binread(path)).to eq(original)
  end

  it 'retains syntax diagnostics without partial candidates' do
    data['files'].values.first['analysis'] = Woods::SourceReferences::Collector.new.call('class Broken;')
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
  end

  it 'rejects partial records next to a parse failure' do
    analysis['parse_error'] = { 'message' => 'invalid syntax', 'line' => 1 }
    write_json(data)
    expect { described_class.read(path) }.to raise_error(described_class::Invalid)
  end

  ['{', 'null', '[]', "\xFF"].each do |content|
    it "rejects malformed JSON or root shape #{content.inspect}" do
      File.binwrite(path, content)
      expect { described_class.read(path) }.to raise_error(described_class::Invalid)
    end
  end

  it 'refuses the previous cache format so unchanged files gain assigned-class declarations after a full extraction' do
    data['version'] = 1
    write_json(data)
    expect { described_class.read(path) }.to raise_error(described_class::Invalid, /unsupported version/)
  end

  it 'round trips assigned-class evidence and refuses arbitrary constructor claims' do
    data['files'].values.first['analysis'] = Woods::SourceReferences::Collector.new.call('Value = Struct.new(:item)')
    described_class.write(path, data)
    expect(described_class.read(path)).to eq(data)
    data['files'].values.first['analysis']['declarations'].first['constructor'] = 'Factory'
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid, /constructor/)
  end

  it 'rejects unsupported cache versions' do
    data['version'] = described_class::VERSION + 1
    write_json(data)
    expect { described_class.read(path) }.to raise_error(described_class::Invalid)
  end

  it 'rejects duplicate JSON keys instead of choosing a conflicting value' do
    File.write(path, '{"version":0,"version":1,"files":{},"owners":[]}')
    expect { described_class.read(path) }.to raise_error(described_class::Invalid)
  end

  it 'rejects duplicate owner identities instead of choosing an edge ownership record' do
    data['owners'] << data['owners'].first.dup
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
  end

  it 'rejects duplicate pass-owned edges that could consume a base-owned edge twice' do
    data['owners'].first['added'] *= 2
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
  end

  it 'reports unreadable existing files as invalid rather than missing' do
    write_json(data)
    allow(File).to receive(:open).with(path, anything).and_raise(Errno::EACCES)
    expect { described_class.read(path) }.to raise_error(described_class::Invalid)
  end

  [true, false].each do |existing|
    it "rejects a #{existing ? 'live' : 'dangling'} cache symlink on read and write" do
      target = File.join(@dir, 'target.json')
      File.write(target, JSON.generate(data)) if existing
      File.symlink(target, path)
      expect { described_class.read(path) }.to raise_error(described_class::Invalid)
      expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
      expect(File.symlink?(path)).to be(true)
    end
  end

  it 'rejects directories as caches' do
    Dir.mkdir(path)
    expect { described_class.read(path) }.to raise_error(described_class::Invalid)
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
  end

  it 'rejects oversized bytes before parsing and before replacement' do
    stub_const('Woods::SourceReferences::Cache::MAX_BYTES', 64)
    File.write(path, ' ' * 65)
    expect { described_class.read(path) }.to raise_error(described_class::Invalid, /size/)
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid, /size/)
    expect(File.size(path)).to eq(65)
  end

  ['../caller.rb', 'app/../caller.rb', '/app/caller.rb', 'app//caller.rb', 'app/./caller.rb',
   'vendor/caller.rb', 'lib/caller.txt', 'app\\caller.rb', "app/caller\0.rb"].each do |unsafe|
    it "rejects unsafe source path #{unsafe.inspect}" do
      data['files'] = { unsafe => data['files'].values.first }
      write_json(data)
      expect { described_class.read(path) }.to raise_error(described_class::Invalid)
    end
  end

  {
    identity: ->(value) { value['files'].values.first['identity'] = 'not an HMAC' },
    owner_path: ->(value) { value['owners'].first['file_path'] = 'app/missing.rb' },
    owner_type: ->(value) { value['owners'].first['type'] = 'factory' },
    edge_type: ->(value) { value['owners'].first['added'].first['type'] = 1 },
    edge_target: ->(value) { value['owners'].first['added'].first['target'] = 'TokenCodec.call' },
    edge_label: ->(value) { value['owners'].first['added'].first['via'] = 'include' },
    raw_source: ->(value) { value['files'].values.first['analysis']['source_code'] = 'class Caller; end' },
    reference_owner: ->(value) { value['files'].values.first['analysis']['references'].first['owner'] = 'Wrong' },
    reference_name: ->(value) { value['files'].values.first['analysis']['references'].first['name'] = 'foo()' },
    line: ->(value) { value['files'].values.first['analysis']['references'].first['line'] = 0 },
    end_line: ->(value) { value['files'].values.first['analysis']['declarations'].first['end_line'] = 0 },
    kind: ->(value) { value['files'].values.first['analysis']['declarations'].first['kind'] = 'method' },
    nesting: ->(value) { value['files'].values.first['analysis']['references'].first['nesting'] = ['foo()'] },
    singleton: ->(value) { value['files'].values.first['analysis']['references'].first['singleton_depth'] = -1 },
    skipped: ->(value) { value['files'].values.first['analysis']['skipped'].first['reason'] = 1 },
    parse_error: ->(value) { value['files'].values.first['analysis']['parse_error'] = { 'message' => [], 'line' => 1 } }
  }.each do |label, mutate|
    it "rejects invalid #{label} evidence" do
      mutate.call(data)
      write_json(data)
      expect { described_class.read(path) }.to raise_error(described_class::Invalid)
    end
  end

  { MAX_FILES: 0, MAX_OWNERS: 0, MAX_RECORDS: 1, MAX_NESTING: 0, MAX_STRING_BYTES: 4 }.each do |limit, size|
    it "enforces #{limit} on read and write" do
      write_json(data)
      stub_const("Woods::SourceReferences::Cache::#{limit}", size)
      expect { described_class.read(path) }.to raise_error(described_class::Invalid)
      expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
    end
  end

  it 'counts candidate records across files rather than independently per file' do
    data['files']['lib/other.rb'] = data['files'].values.first
    count = analysis.values_at('declarations', 'references', 'skipped').sum(&:length)
    stub_const('Woods::SourceReferences::Cache::MAX_RECORDS', count + 1)
    expect { described_class.write(path, data) }.to raise_error(described_class::Invalid)
  end
end
