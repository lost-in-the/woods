# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# Booted-app extraction test (#136). Boots the minimal Rails app under
# spec/dummy in-process against the Rails version the active gemfile resolves
# (see gemfiles/ + Appraisals), runs a real end-to-end extraction, and asserts a
# non-zero unit count plus the expected models/associations. This is the
# version-sensitive introspection gate the unit suite (which stubs Rails) can't
# provide.
#
# Tagged :booted_app — excluded from the default `rake spec` run and opted into
# by the CI Rails-version matrix with WOODS_RUN_BOOTED_APP=1 under a gemfile that
# bundles full Rails.
RSpec.describe 'Booted-app extraction', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    dummy_root = File.expand_path('../dummy', __dir__)

    # File-backed sqlite shared across connections (config/database.yml reads
    # WOODS_DUMMY_DB). Kept in a tmp dir and cleaned up after the run.
    @db_dir = Dir.mktmpdir('woods_dummy_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    # A single minimal application per process. Avoid load_defaults so the boot
    # stays neutral across Rails 6.0–8.0.
    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.consider_all_requests_local = true
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = dummy_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyApplication.initialize!
    end

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.integer :status, default: 0
        t.string :type
        t.string :slug
        t.integer :user_id
        t.timestamps
      end
      create_table :comments, force: true do |t|
        t.references :post
        t.integer :user_id
        t.text :body
        t.timestamps
      end
      create_table :users, force: true do |t|
        t.string :email
        t.string :name
        t.timestamps
      end
      create_table :profiles, force: true do |t|
        t.references :user
        t.text :bio
        t.timestamps
      end
      create_table :tags, force: true do |t|
        t.string :name
        t.string :slug
        t.timestamps
      end
      create_table :taggings, force: true do |t|
        t.references :tag
        t.string :taggable_type
        t.integer :taggable_id
        t.timestamps
      end
      create_table :notifications, force: true do |t|
        t.references :user
        t.string :notifiable_type
        t.integer :notifiable_id
        t.boolean :read, default: false
        t.timestamps
      end
    end

    # Ensure the app's classes are loaded so descendants-based discovery works.
    Rails.application.eager_load!

    @output_dir = Dir.mktmpdir('woods_booted')
    require 'woods'
    require 'woods/extractor'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false

    Woods::Extractor.new(output_dir: @output_dir).extract_all
  end

  # Restore the global state this file mutates so it can't corrupt other specs.
  # (CI runs this file solo via WOODS_RUN_BOOTED_APP, but the isolation is
  # enforced here rather than assumed. The booted Rails.application singleton
  # can't be torn down, but the config and DB connection are restored.)
  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    FileUtils.rm_rf(@output_dir) if @output_dir
    FileUtils.rm_rf(@db_dir) if @db_dir
    ENV.delete('WOODS_DUMMY_DB')
  end

  let(:manifest) { JSON.parse(File.read(File.join(@output_dir, 'manifest.json'))) }

  # Output directories are keyed by the (plural) result type, e.g. models/,
  # controllers/, jobs/ — each holding per-unit JSON plus an _index.json.
  def index_for(type)
    path = File.join(@output_dir, type.to_s, '_index.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : []
  end

  def units_in(type)
    Dir[File.join(@output_dir, type.to_s, '*.json')]
      .reject { |p| File.basename(p) == '_index.json' }
      .map { |p| JSON.parse(File.read(p)) }
  end

  def find_unit(type, identifier)
    units_in(type).find { |u| u['identifier'] == identifier }
  end

  it 'writes a manifest recording the running Rails and Ruby versions' do
    expect(manifest['rails_version']).to eq(Rails.version)
    expect(manifest['ruby_version']).to eq(RUBY_VERSION)
  end

  it 'extracts a non-zero unit count' do
    expect(manifest['total_units']).to be > 0
  end

  it 'extracts the application models from real source' do
    identifiers = index_for(:models).map { |u| u['identifier'] }
    expect(identifiers).to include('Post', 'Comment')
  end

  it 'extracts the controller and job units' do
    expect(index_for(:controllers).map { |u| u['identifier'] }).to include('PostsController')
    expect(index_for(:jobs).map { |u| u['identifier'] }).to include('PublishPostJob')
  end

  it 'resolves the Post -> Comment association as a dependency edge' do
    post_unit = find_unit(:models, 'Post')
    expect(post_unit).not_to be_nil

    targets = (post_unit['dependencies'] || []).map { |d| d['target'] }
    expect(targets).to include('Comment')

    graph = JSON.parse(File.read(File.join(@output_dir, 'dependency_graph.json')))
    expect(graph).not_to be_empty
  end

  it 'extracts app-defined callbacks from the real chains (kind + event naming)' do
    post_unit = find_unit(:models, 'Post')
    callbacks = post_unit['metadata']['callbacks'] || []
    filters = callbacks.map { |cb| [cb['type'], cb['filter']] }

    expect(filters).to include(%w[before_save normalize_title])
    expect(callbacks.map { |cb| cb['filter'] }).not_to include(a_string_starting_with('autosave_'))
  end

  it 'records git provenance (resolved or "unknown"), never crashing on a non-repo dummy' do
    expect(manifest).to have_key('git_branch')
    expect(manifest).to have_key('git_sha')
  end

  # End-to-end Obsidian export (B-056) against the *real* extraction output above
  # — not synthetic fixtures. Confirms the exporter consumes genuine artifacts
  # (manifest, dependency_graph.json, per-unit JSON) and produces a coherent vault.
  describe 'Obsidian vault export' do
    before(:all) do
      require 'stringio'
      require 'yaml'
      require 'woods/obsidian/vault_exporter'
      @vault_dir = Dir.mktmpdir('woods_obsidian')
      @export_stats = Woods::Obsidian::VaultExporter.new(
        index_dir: @output_dir, vault_path: @vault_dir, output: StringIO.new
      ).export_all
    end

    after(:all) { FileUtils.rm_rf(@vault_dir) if @vault_dir }

    def vault_read(rel)
      File.read(File.join(@vault_dir, rel), encoding: 'UTF-8')
    end

    it 'writes a note per application model with valid flat frontmatter' do
      expect(@export_stats[:exported]).to be > 0
      expect(File).to exist(File.join(@vault_dir, 'models/Post.md'))
      expect(File).to exist(File.join(@vault_dir, 'models/Comment.md'))
      fm = YAML.safe_load(vault_read('models/Post.md').split("\n---\n").first)
      expect(fm).to include('id' => 'Post', 'type' => 'model', 'woods_managed' => true)
    end

    it 'encodes the real Post -> Comment dependency as a resolvable wikilink' do
      expect(vault_read('models/Post.md')).to include('[[models/Comment|Comment]]')
    end

    it 'emits no dangling wikilinks across the whole vault' do
      Dir.glob(File.join(@vault_dir, '**', '*.md')).each do |file|
        File.read(file, encoding: 'UTF-8').scan(/\[\[([^\]|#^]+)[|\]]/).flatten.uniq.each do |target|
          expect(File).to(exist(File.join(@vault_dir, "#{target}.md")), "dangling link [[#{target}]] in #{file}")
        end
      end
    end

    it 'writes a machine sidecar with a bijective id<->path manifest and a verbatim graph copy' do
      manifest = JSON.parse(vault_read('_woods/manifest.json'))
      expect(manifest['notes']).not_to be_empty
      manifest['notes'].each { |id, info| expect(manifest['paths'][info['path']]).to eq(id) }
      expect(File).to exist(File.join(@vault_dir, '_woods/dependency_graph.json'))
    end

    it 'is idempotent — a second export produces byte-identical notes' do
      before_bytes = File.binread(File.join(@vault_dir, 'models/Post.md'))
      Woods::Obsidian::VaultExporter.new(
        index_dir: @output_dir, vault_path: @vault_dir, output: StringIO.new
      ).export_all
      expect(File.binread(File.join(@vault_dir, 'models/Post.md'))).to eq(before_bytes)
    end
  end

  # End-to-end HTML explorer export against the *real* extraction output above
  # — not synthetic fixtures. Confirms the SiteBuilder consumes genuine
  # artifacts (manifest, dependency_graph.json, per-unit JSON) and produces a
  # self-contained site with a coherent embedded payload.
  describe 'HTML explorer export' do
    before(:all) do
      require 'stringio'
      require 'woods/explorer/site_builder'
      @explorer_dir = Dir.mktmpdir('woods_explorer')
      @explorer_stats = Woods::Explorer::SiteBuilder.new(
        index_dir: @output_dir, output_dir: @explorer_dir, output: StringIO.new
      ).export_all
    end

    after(:all) { FileUtils.rm_rf(@explorer_dir) if @explorer_dir }

    def explorer_read(rel)
      File.read(File.join(@explorer_dir, rel), encoding: 'UTF-8')
    end

    def explorer_payload
      JSON.parse(explorer_read('data.json'))
    end

    def node_index(payload, id)
      payload['nodes'].index { |n| n['id'] == id }
    end

    it 'exports a substantial node count from the real extraction' do
      expect(@explorer_stats[:nodes]).to be > 30
    end

    it 'writes an index.html embedding parseable JSON that carries the app units' do
      html = explorer_read('index.html')
      segment = html[%r{<script id="woods-data" type="application/json">(.*?)</script>}m, 1]
      expect(segment).not_to be_nil
      ids = JSON.parse(segment)['nodes'].map { |n| n['id'] }
      expect(ids).to include('Post', 'PostsController')
    end

    it 'writes a data.json sidecar under the versioned schema' do
      expect(explorer_payload['schema']).to eq('woods-explorer/1')
    end

    it 'distills real model facts including callback side-effects for Post' do
      payload = explorer_payload
      post = payload['nodes'][node_index(payload, 'Post')]
      expect(post['facts']['table_name']).to eq('posts')

      publish = (post['facts']['callbacks'] || []).find { |cb| cb['filter'] == 'schedule_publish' }
      expect(publish).not_to be_nil
      expect(publish.dig('side_effects', 'jobs_enqueued')).to include('PublishPostJob')
    end

    it 'encodes the real Comment -> Post association as an indexed belongs_to edge' do
      payload = explorer_payload
      comment_idx = node_index(payload, 'Comment')
      post_idx = node_index(payload, 'Post')
      expect(comment_idx).not_to be_nil
      expect(post_idx).not_to be_nil
      expect(payload['edges']).to include([comment_idx, post_idx, 'belongs_to'])
    end

    it 'is idempotent — a second export produces a byte-identical index.html' do
      before_bytes = File.binread(File.join(@explorer_dir, 'index.html'))
      Woods::Explorer::SiteBuilder.new(
        index_dir: @output_dir, output_dir: @explorer_dir, output: StringIO.new
      ).export_all
      expect(File.binread(File.join(@explorer_dir, 'index.html'))).to eq(before_bytes)
    end
  end
end
