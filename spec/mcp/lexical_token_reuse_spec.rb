# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/filename_utils'
require 'woods/mcp/published_lexical_retriever'

# A published lexical snapshot reuses tokenized fields from an earlier
# generation in the same process. Each case states its facts on its own
# (which units were re-tokenized, what a query now finds) and also checks
# every answer against a cold build with an empty cache.
RSpec.describe Woods::MCP::PublishedLexicalRetriever, 'token reuse across generations' do
  let(:index_dir) { Dir.mktmpdir('woods-lexical-reuse') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:cache) { Woods::Retrieval::LexicalTokenCache.new }
  let(:retriever) { described_class.new(index_dir: index_dir, token_cache: cache) }
  let(:queries) { %w[Post Article comments title posts articles oldword newword publish] }

  before { Woods.configuration = Woods::Configuration.new }
  after { FileUtils.rm_rf(index_dir) }

  def publish(name)
    relative = "payloads/#{name}"
    target = File.join(index_dir, relative)
    FileUtils.mkdir_p(target)
    FileUtils.cp_r("#{fixture_dir}/.", target)
    yield target if block_given?
    Woods::Generation.new(output_dir: index_dir).bump!(payload: relative)
  end

  def post_path(target, identifier = 'Post')
    filename = Object.new.extend(Woods::FilenameUtils).collision_safe_filename(identifier)
    File.join(target, 'models', filename)
  end

  def edit_post(target)
    path = post_path(target)
    data = JSON.parse(File.read(path))
    yield data
    File.write(path, JSON.generate(data))
  end

  def edit_model_index(target)
    path = File.join(target, 'models', '_index.json')
    File.write(path, JSON.generate(yield(JSON.parse(File.read(path)))))
  end

  # Everything a caller sees: the rendered context and the typed sources.
  def answers(subject, **options)
    queries.to_h { |query| [query, JSON.generate(subject.retrieve(query, **options).to_h.slice(:context, :sources))] }
  end

  def cold_answers(**options)
    answers(described_class.new(index_dir: index_dir, token_cache: Woods::Retrieval::LexicalTokenCache.new),
            **options)
  end

  def source_ids(query, **options)
    retriever.retrieve(query, **options).sources.map { |source| source[:identifier] }
  end

  it 're-tokenizes only the changed unit after a one-file change and answers like a cold build' do
    publish('one') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldword; end' } }
    expect(source_ids('oldword')).to eq(['Post'])
    expect(cache.stats[:last_build]).to eq(hits: 0, misses: 9)

    publish('two') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; newword; end' } }

    expect(source_ids('newword')).to eq(['Post'])
    expect(source_ids('oldword')).to be_empty
    expect(cache.stats[:last_build]).to eq(hits: 8, misses: 1)
    expect(answers(retriever)).to eq(cold_answers)
  end

  it 'reuses every unit on a no-op publication' do
    publish('one')
    retriever.warmup!
    publish('two')
    retriever.warmup!
    expect(cache.stats[:last_build]).to eq(hits: 9, misses: 0)
    expect(answers(retriever)).to eq(cold_answers)
  end

  it 'drops a deleted unit, its terms and its statistics' do
    publish('one') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldword; end' } }
    retriever.warmup!
    publish('two') do |target|
      File.unlink(post_path(target))
      edit_model_index(target) { |entries| entries.reject { |entry| entry['identifier'] == 'Post' } }
      manifest = File.join(target, 'manifest.json')
      data = JSON.parse(File.read(manifest))
      data['counts']['models'] -= 1
      data['total_units'] -= 1
      File.write(manifest, JSON.generate(data))
    end

    expect(source_ids('oldword')).to be_empty
    expect(retriever.metadata_store.count).to eq(8)
    expect(cache.stats[:last_build]).to eq(hits: 8, misses: 0)
    expect(answers(retriever)).to eq(cold_answers)
  end

  it 'indexes a renamed unit under its new identity, never the cached old one' do
    publish('one')
    retriever.warmup!
    publish('two') do |target|
      data = JSON.parse(File.read(post_path(target)))
      File.unlink(post_path(target))
      File.write(post_path(target, 'Article'),
                 JSON.generate(data.merge('identifier' => 'Article', 'file_path' => 'app/models/article.rb')))
      edit_model_index(target) do |entries|
        entries.map { |entry| entry['identifier'] == 'Post' ? entry.merge('identifier' => 'Article') : entry }
      end
    end

    expect(source_ids('Article')).to start_with('Article')
    expect(source_ids('Post', types: ['model'])).not_to include('Post')
    # The identifier and path are tokenized fields, so the renamed unit is a
    # miss even though its source is byte-identical.
    expect(cache.stats[:last_build]).to eq(hits: 8, misses: 1)
    expect(answers(retriever)).to eq(cold_answers)
  end

  context 'with a metadata change' do
    before do
      publish('one') { |target| edit_post(target) { |data| data['metadata']['package'] = 'packs/billing' } }
      retriever.warmup!
    end

    it 'reuses the tokens of an unindexed metadata change but scopes by the new unit' do
      publish('two') { |target| edit_post(target) { |data| data['metadata']['package'] = 'packs/other' } }

      expect(source_ids('Post', packages: ['packs/other'])).to eq(['Post'])
      expect { retriever.retrieve('Post', packages: ['packs/billing']) }
        .to raise_error(Woods::Retrieval::Scope::InvalidScopeError, %r{unknown package scope: packs/billing})
      expect(retriever.metadata_store.find(Woods::StorageIdentity.key('Post', 'model')))
        .to include('metadata' => include('package' => 'packs/other'))
      expect(cache.stats[:last_build]).to eq(hits: 9, misses: 0)
      expect(answers(retriever, packages: ['packs/other'])).to eq(cold_answers(packages: ['packs/other']))
    end

    it 're-tokenizes an indexed metadata change' do
      publish('two') { |target| edit_post(target) { |data| data['metadata']['table_name'] = 'articles' } }

      expect(source_ids('articles')).to eq(['Post'])
      expect(cache.stats[:last_build]).to eq(hits: 8, misses: 1)
      expect(answers(retriever)).to eq(cold_answers)
    end
  end

  context 'when the lexical configuration changes between generations' do
    let(:inflections) { ActiveSupport::Inflector.inflections(:en) }

    after { inflections.uncountables.delete('oldwords') }

    it 're-tokenizes every unit under a new singular rule' do
      publish('one') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldwords; end' } }
      expect(source_ids('oldword')).to eq(['Post'])

      inflections.uncountable('oldwords')
      publish('two') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldwords; end' } }

      expect(source_ids('oldword')).to be_empty
      expect(source_ids('oldwords')).to eq(['Post'])
      expect(cache.stats[:last_build]).to eq(hits: 0, misses: 9)
      expect(answers(retriever)).to eq(cold_answers)
    end

    it 're-tokenizes every unit under a new tokenizer version' do
      publish('one')
      retriever.warmup!
      stub_const('Woods::Retrieval::LexicalIndex::TOKENIZER_VERSION',
                 Woods::Retrieval::LexicalIndex::TOKENIZER_VERSION + 1)
      publish('two')
      retriever.warmup!
      expect(cache.stats[:last_build]).to eq(hits: 0, misses: 9)
    end
  end

  context 'when the published marker alternates between two payloads' do
    def publish_pointer(name)
      Woods::Generation.new(output_dir: index_dir).bump!(payload: "payloads/#{name}")
    end

    before do
      publish('one') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldword; end' } }
      retriever.warmup!
      publish('two') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; newword; end' } }
      retriever.warmup!
    end

    it 'reuses both payloads and serves each one exactly' do
      %w[one two one two].each do |name|
        publish_pointer(name)
        expect(source_ids(name == 'one' ? 'oldword' : 'newword')).to eq(['Post'])
        expect(source_ids(name == 'one' ? 'newword' : 'oldword')).to be_empty
        expect(cache.stats[:last_build]).to eq(hits: 9, misses: 0)
        expect(answers(retriever)).to eq(cold_answers)
      end
    end

    it 're-tokenizes a payload after it has aged out of the build bound' do
      publish('three') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; thirdword; end' } }
      retriever.warmup!
      publish_pointer('one')

      expect(source_ids('oldword')).to eq(['Post'])
      expect(cache.stats[:last_build]).to eq(hits: 8, misses: 1)
      expect(answers(retriever)).to eq(cold_answers)
    end
  end

  it 'still refuses a corrupt unit and commits nothing from the failed build' do
    publish('one')
    retriever.warmup!
    before = cache.stats
    publish('two') { |target| File.write(post_path(target), '{broken') }

    expect { retriever.retrieve('Post') }.to raise_error(Woods::Retriever::StoreError, /JSON::ParserError/)
    expect(cache.stats).to eq(before)

    publish('three')
    expect(source_ids('Post')).to include('Post')
    expect(cache.stats[:last_build]).to eq(hits: 9, misses: 0)
  end

  it 'shares one process cache between retrievers by default' do
    publish('one')
    shared = Woods::Retrieval::LexicalTokenCache.shared
    shared.clear!
    described_class.new(index_dir: index_dir).warmup!
    described_class.new(index_dir: index_dir).warmup!
    expect(shared.stats[:last_build]).to eq(hits: 9, misses: 0)
  ensure
    shared&.clear!
  end
end
