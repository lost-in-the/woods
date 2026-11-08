# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/filename_utils'
require 'woods/mcp/published_lexical_retriever'

# A published lexical snapshot keeps the units it decoded and the documents
# it built, and a generation seeded from the one before (unchanged unit
# files hard-linked, as Woods' payload seeding leaves them) is rebuilt from
# them: only a changed unit is decoded and tokenized again. Every answer is
# checked against a cold build, and the token cache's accounting is the one
# the token-reuse contract states, reuse or not.
RSpec.describe Woods::MCP::PublishedLexicalRetriever, 'document reuse across seeded generations' do
  let(:index_dir) { Dir.mktmpdir('woods-document-reuse') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:cache) { Woods::Retrieval::LexicalTokenCache.new }
  let(:retriever) { described_class.new(index_dir: index_dir, token_cache: cache) }
  let(:queries) { %w[Post Article comments title posts articles oldword newword publish] }

  before { Woods.configuration = Woods::Configuration.new }
  after { FileUtils.rm_rf(index_dir) }

  def publish(name, from: nil, except: [])
    relative = "payloads/#{name}"
    target = File.join(index_dir, relative)
    if from
      seed(File.join(index_dir, "payloads/#{from}"), target, except)
    else
      FileUtils.mkdir_p(target)
      FileUtils.cp_r("#{fixture_dir}/.", target)
    end
    yield target if block_given?
    Woods::Generation.new(output_dir: index_dir).bump!(payload: relative)
  end

  # What Woods' payload seeding leaves: every file of +source+ hard-linked
  # into +target+, except the ones named, which are copied.
  def seed(source, target, except)
    Dir.glob('**/*', base: source).sort.each do |entry|
      src = File.join(source, entry)
      dst = File.join(target, entry)
      FileUtils.mkdir_p(File.dirname(dst))
      next FileUtils.mkdir_p(dst) if File.directory?(src)

      except.include?(entry) ? FileUtils.cp(src, dst) : File.link(src, dst)
    end
  end

  def post_file
    "models/#{Object.new.extend(Woods::FilenameUtils).collision_safe_filename('Post')}"
  end

  def edit_post(target)
    path = File.join(target, post_file)
    data = JSON.parse(File.read(path))
    yield data
    File.write(path, JSON.generate(data))
  end

  def answers(subject)
    queries.to_h { |query| [query, JSON.generate(subject.retrieve(query).to_h.slice(:context, :sources))] }
  end

  def cold_answers
    answers(described_class.new(index_dir: index_dir, token_cache: Woods::Retrieval::LexicalTokenCache.new))
  end

  def documents
    retriever.instance_variable_get(:@last_index).documents_by_key
  end

  def units
    retriever.instance_variable_get(:@last_index).units
  end

  it 'rebuilds only the changed unit after a seeded one-file change and answers like a cold build' do
    publish('gen-1')
    retriever.warmup!
    before_units = units
    before_documents = documents
    publish('gen-2', from: 'gen-1', except: [post_file]) do |target|
      edit_post(target) { |data| data['source_code'] = "#{data['source_code']}\n# newword" }
    end

    expect(answers(retriever)).to eq(cold_answers)
    expect(cache.stats[:last_build]).to eq(hits: 8, misses: 1)
    kept = units.select { |key, unit| before_units[key].equal?(unit) }
    expect(kept.size).to eq(before_units.size - 1)
    expect(kept.keys).not_to include(units.keys.find { |key| key.start_with?('model:Post') || key == 'Post' })
    kept.each_key { |key| expect(documents[key]).to equal(before_documents[key]) }
    expect(retriever.retrieve('newword').context).to include('newword')
  end

  it 'reuses the whole snapshot on a seeded no-op publication, and counts its tokens as reused' do
    publish('gen-1')
    retriever.warmup!
    before_index = retriever.instance_variable_get(:@last_index)
    before_snapshot = retriever.snapshot.last
    publish('gen-2', from: 'gen-1')

    expect(answers(retriever)).to eq(cold_answers)
    expect(cache.stats[:last_build]).to eq(hits: 9, misses: 0)
    expect(retriever.instance_variable_get(:@last_index)).to equal(before_index)
    expect(retriever.snapshot.last).to equal(before_snapshot)
    expect(retriever.snapshot.first.first).to eq(2)
  end

  it 'drops a unit the new generation no longer lists, hard links or not' do
    publish('gen-1')
    retriever.warmup!
    publish('gen-2', from: 'gen-1', except: ['models/_index.json', 'manifest.json']) do |target|
      File.unlink(File.join(target, post_file))
      path = File.join(target, 'models/_index.json')
      entries = JSON.parse(File.read(path)).reject { |entry| entry['identifier'] == 'Post' }
      File.write(path, JSON.generate(entries))
      manifest = File.join(target, 'manifest.json')
      data = JSON.parse(File.read(manifest))
      data['counts']['models'] -= 1
      data['total_units'] -= 1
      File.write(manifest, JSON.generate(data))
    end

    expect(answers(retriever)).to eq(cold_answers)
    expect(units.keys.none? { |key| key.end_with?('Post') && !key.end_with?('ApplicationPost') }).to be(true)
    expect(retriever.retrieve('Post').sources.map { |source| source[:identifier] }).not_to include('Post')
  end

  context 'when the lexical configuration changes between seeded generations' do
    let(:inflections) { ActiveSupport::Inflector.inflections(:en) }

    after { inflections.uncountables.delete('oldwords') }

    def comment_file
      "models/#{Object.new.extend(Woods::FilenameUtils).collision_safe_filename('Comment')}"
    end

    def publish_oldwords
      publish('gen-1') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldwords; end' } }
      retriever.warmup!
      expect(retriever.retrieve('oldword').sources.map { |source| source[:identifier] }).to include('Post')
      inflections.uncountable('oldwords')
    end

    def shared_cache_answers
      answers(described_class.new(index_dir: index_dir, token_cache: cache))
    end

    it 're-tokenizes a hard-linked unit when another unit changed' do
      publish_oldwords
      publish('gen-2', from: 'gen-1', except: [comment_file]) do |target|
        path = File.join(target, comment_file)
        data = JSON.parse(File.read(path))
        data['source_code'] = "#{data['source_code']}\n# edited"
        File.write(path, JSON.generate(data))
      end

      expect(answers(retriever)).to eq(cold_answers)
      expect(shared_cache_answers).to eq(cold_answers)
    end

    it 're-tokenizes every unit of a hard-linked no-op publication' do
      publish_oldwords
      publish('gen-2', from: 'gen-1')

      expect(answers(retriever)).to eq(cold_answers)
      expect(shared_cache_answers).to eq(cold_answers)
    end
  end

  it 'serves the snapshot of the generation it built after a reload installed another one' do
    publish('gen-1') { |target| edit_post(target) { |data| data['source_code'] = 'class Post; oldword; end' } }
    retriever.warmup!
    publish('gen-2', from: 'gen-1', except: [post_file]) do |target|
      edit_post(target) { |data| data['source_code'] = 'class Post; newword; end' }
    end
    candidate = described_class.new(index_dir: index_dir, token_cache: cache).warmup!
    retriever.install_snapshot!(candidate.snapshot)
    Woods::Generation.new(output_dir: index_dir).bump!(payload: 'payloads/gen-1')

    expect(retriever.retrieve('oldword').sources.map { |source| source[:identifier] }).to include('Post')
    expect(retriever.retrieve('newword').sources.map { |source| source[:identifier] }).not_to include('Post')
    expect(answers(retriever)).to eq(cold_answers)
  end

  it 'keeps the reused documents of a copied payload out of the way: a new inode is decoded again' do
    publish('gen-1')
    retriever.warmup!
    before_units = units
    publish('gen-2') # a full copy: every file is a new inode

    expect(answers(retriever)).to eq(cold_answers)
    expect(cache.stats[:last_build]).to eq(hits: 9, misses: 0)
    expect(units.none? { |key, unit| before_units[key].equal?(unit) }).to be(true)
  end
end
