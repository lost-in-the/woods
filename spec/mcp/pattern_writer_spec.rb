# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/pattern_writer'

RSpec.describe Woods::MCP::PatternWriter do
  let(:tmp_dir) { Dir.mktmpdir('woods-test') }
  let(:index_dir) { tmp_dir }
  let(:patterns_dir) { File.join(index_dir, 'patterns') }
  let(:writer) { described_class.new(index_dir: index_dir) }

  before do
    # Create a minimal manifest.json so the directory looks like an index
    File.write(File.join(index_dir, 'manifest.json'), '{}')
  end

  after { FileUtils.remove_entry(tmp_dir) }

  describe '#write' do
    it 'creates a unit JSON file in the patterns directory' do
      writer.write(identifier: 'order-flow', content: 'Orders require payment before shipping.')
      files = Dir.glob(File.join(patterns_dir, '*.json')).reject { |f| f.end_with?('_index.json') }
      expect(files.size).to eq(1)

      data = JSON.parse(File.read(files.first))
      expect(data['identifier']).to eq('order-flow')
      expect(data['type']).to eq('pattern')
      expect(data['source_code']).to eq('Orders require payment before shipping.')
      expect(data['file_path']).to eq('agent://patterns/order-flow')
      expect(data['metadata']['authored_by']).to eq('agent')
    end

    it 'updates _index.json with the pattern entry' do
      writer.write(identifier: 'order-flow', content: 'Some content')
      index = JSON.parse(File.read(File.join(patterns_dir, '_index.json')))
      expect(index.size).to eq(1)
      expect(index.first['identifier']).to eq('order-flow')
    end

    it 'overwrites on upsert (same identifier)' do
      writer.write(identifier: 'order-flow', content: 'Version 1')
      writer.write(identifier: 'order-flow', content: 'Version 2')

      files = Dir.glob(File.join(patterns_dir, '*.json')).reject { |f| f.end_with?('_index.json') }
      expect(files.size).to eq(1)

      data = JSON.parse(File.read(files.first))
      expect(data['source_code']).to eq('Version 2')

      index = JSON.parse(File.read(File.join(patterns_dir, '_index.json')))
      expect(index.size).to eq(1)
    end

    it 'records supersedes in metadata' do
      writer.write(identifier: 'order-flow-v2', content: 'Corrected version', supersedes: 'order-flow')
      files = Dir.glob(File.join(patterns_dir, '*.json')).reject { |f| f.end_with?('_index.json') }
      data = JSON.parse(File.read(files.first))
      expect(data['metadata']['supersedes']).to eq('order-flow')
    end

    it 'stores tags in metadata and index' do
      writer.write(identifier: 'auth-flow', content: 'Auth details', metadata: { 'tags' => %w[auth security] })
      index = JSON.parse(File.read(File.join(patterns_dir, '_index.json')))
      expect(index.first['tags']).to eq(%w[auth security])
    end

    it 'returns an ExtractedUnit' do
      unit = writer.write(identifier: 'test-pattern', content: 'Test content')
      expect(unit).to be_a(Woods::ExtractedUnit)
      expect(unit.type).to eq(:pattern)
      expect(unit.identifier).to eq('test-pattern')
    end

    context 'validation' do
      it 'rejects empty identifier' do
        expect { writer.write(identifier: '', content: 'content') }.to raise_error(ArgumentError, /non-empty/)
      end

      it 'rejects nil identifier' do
        expect { writer.write(identifier: nil, content: 'content') }.to raise_error(ArgumentError, /non-empty/)
      end

      it 'rejects identifiers exceeding max length' do
        long_id = 'a' * 257
        expect { writer.write(identifier: long_id, content: 'content') }.to raise_error(ArgumentError, /exceeds/)
      end

      it 'rejects identifiers with invalid characters' do
        expect { writer.write(identifier: 'foo;DROP TABLE', content: 'x') }.to raise_error(ArgumentError, /invalid characters/)
        expect { writer.write(identifier: "foo'bar", content: 'x') }.to raise_error(ArgumentError, /invalid characters/)
        expect { writer.write(identifier: 'foo"bar', content: 'x') }.to raise_error(ArgumentError, /invalid characters/)
        expect { writer.write(identifier: 'foo bar', content: 'x') }.to raise_error(ArgumentError, /invalid characters/)
      end

      it 'accepts valid identifier characters' do
        expect { writer.write(identifier: 'Foo::Bar/baz-qux_1.0', content: 'ok') }.not_to raise_error
      end

      it 'rejects empty content' do
        expect { writer.write(identifier: 'test', content: '') }.to raise_error(ArgumentError, /non-empty/)
      end

      it 'rejects content exceeding max length' do
        long_content = 'a' * 50_001
        expect { writer.write(identifier: 'test', content: long_content) }.to raise_error(ArgumentError, /exceeds/)
      end

      it 'rejects non-array tags' do
        expect { writer.write(identifier: 'test', content: 'ok', metadata: { 'tags' => 'not-array' }) }
          .to raise_error(ArgumentError, /must be an array/)
      end

      it 'rejects tags with invalid characters' do
        expect { writer.write(identifier: 'test', content: 'ok', metadata: { 'tags' => ['ok tag', 'bad;tag'] }) }
          .to raise_error(ArgumentError, /invalid characters/)
      end
    end
  end

  describe '#delete' do
    it 'removes the file and index entry' do
      writer.write(identifier: 'to-delete', content: 'Temporary')
      expect(writer.delete('to-delete')).to be true

      files = Dir.glob(File.join(patterns_dir, '*.json')).reject { |f| f.end_with?('_index.json') }
      expect(files).to be_empty

      index = JSON.parse(File.read(File.join(patterns_dir, '_index.json')))
      expect(index).to be_empty
    end

    it 'returns false for nonexistent pattern' do
      expect(writer.delete('nonexistent')).to be false
    end
  end

  describe '#list' do
    before do
      writer.write(identifier: 'pattern-a', content: 'A', metadata: { 'tags' => %w[auth] })
      writer.write(identifier: 'pattern-b', content: 'B', metadata: { 'tags' => %w[data-flow] })
      writer.write(identifier: 'pattern-c', content: 'C', metadata: { 'tags' => %w[auth data-flow] })
    end

    it 'returns all patterns without filter' do
      expect(writer.list.size).to eq(3)
    end

    it 'filters by tag' do
      results = writer.list(tag: 'auth')
      expect(results.size).to eq(2)
      expect(results.map { |r| r['identifier'] }).to contain_exactly('pattern-a', 'pattern-c')
    end

    it 'returns empty array when no patterns directory exists' do
      empty_writer = described_class.new(index_dir: Dir.mktmpdir('woods-empty'))
      expect(empty_writer.list).to eq([])
    end
  end

  describe '#embed' do
    it 'calls provider.embed_batch and vector_store.store' do
      unit = writer.write(identifier: 'embed-test', content: 'Test embedding')

      provider = instance_double('EmbeddingProvider')
      vector_store = instance_double('VectorStore')
      text_preparer = instance_double('TextPreparer')

      allow(text_preparer).to receive(:prepare).with(unit).and_return('[pattern] embed-test\nTest embedding')
      allow(provider).to receive(:embed_batch).with(['[pattern] embed-test\nTest embedding']).and_return([[0.1, 0.2, 0.3]])
      allow(vector_store).to receive(:store)

      writer.embed(unit, provider: provider, vector_store: vector_store, text_preparer: text_preparer)

      expect(provider).to have_received(:embed_batch).with(['[pattern] embed-test\nTest embedding'])
      expect(vector_store).to have_received(:store).with(
        'embed-test',
        [0.1, 0.2, 0.3],
        { type: 'pattern', identifier: 'embed-test', file_path: 'agent://patterns/embed-test' }
      )
    end
  end
end
