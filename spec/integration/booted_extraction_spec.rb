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

    # Rails applications are singletons and every :booted_app spec shares this
    # constant, so a mismatch means another one booted first and this file is
    # running against its root. Fail loudly rather than quietly testing nothing.
    BootedAppRoot.assert!(dummy_root)

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.integer :status, default: 0
        t.timestamps
      end
      create_table :comments, force: true do |t|
        t.references :post
        t.text :body
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

  let(:manifest) { JSON.parse(File.read(File.join(payload_dir, 'manifest.json'))) }

  # Extraction publishes into an immutable per-generation payload directory
  # named by generation.json; resolve it the way a reader does rather than
  # reading the index root.
  def payload_dir
    Woods::Generation.new(output_dir: @output_dir).payload_dir.to_s
  end

  # Output directories are keyed by the (plural) result type, e.g. models/,
  # controllers/, jobs/ — each holding per-unit JSON plus an _index.json.
  def index_for(type)
    path = File.join(payload_dir, type.to_s, '_index.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : []
  end

  def units_in(type)
    Dir[File.join(payload_dir, type.to_s, '*.json')]
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

  # Finding G-1: files wrapped in class namespaces used to index as the
  # wrapper (Domain::Container), and both siblings collided on it.
  it 'resolves class-wrapper-nested services to their file-named constants' do
    identifiers = index_for(:services).map { |u| u['identifier'] }
    expect(identifiers).to include('Domain::Container::Parser', 'Domain::Container::Renderer')
  end

  it 'resolves the Post -> Comment association as a dependency edge' do
    post_unit = find_unit(:models, 'Post')
    expect(post_unit).not_to be_nil

    targets = (post_unit['dependencies'] || []).map { |d| d['target'] }
    expect(targets).to include('Comment')

    graph = JSON.parse(File.read(File.join(payload_dir, 'dependency_graph.json')))
    expect(graph).not_to be_empty
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

  # Full-path flow precomputation is fail closed: a failure anywhere in the
  # flow family must abort the extraction before publish_generation, leaving
  # the previously published generation resolved, readable, and byte-identical.
  # The aborted run's payload directory (gen-N+1) stays on disk but
  # unreachable — nothing points at it, and the next run's PayloadStore#create
  # empties that same unbumped-generation-numbered directory before writing
  # into it again. Kept separate from spec/extractors/flow_incremental_spec
  # per the established assertion separation.
  describe 'flow precomputation (full path, fail closed)' do
    before(:all) do
      @flow_dir = Dir.mktmpdir('woods_flow_full')
      Woods.configuration.precompute_flows = true
      Woods::Extractor.new(output_dir: @flow_dir).extract_all
    end

    after(:all) do
      Woods.configuration.precompute_flows = false
      FileUtils.rm_rf(@flow_dir) if @flow_dir
    end

    def flow_payload_dir
      Woods::Generation.new(output_dir: @flow_dir).payload_dir.to_s
    end

    def generation_bytes
      File.read(File.join(@flow_dir, 'generation.json'))
    end

    def flow_snapshot
      flows = File.join(flow_payload_dir, 'flows')
      Dir[File.join(flows, '*.json')].to_h { |p| [File.basename(p), File.read(p)] }
    end

    def full_extract
      Woods::Extractor.new(output_dir: @flow_dir).extract_all
    end

    it 'aborts publication when one action fails to assemble' do
      before_bytes = generation_bytes

      assembler = instance_double(Woods::FlowAssembler)
      allow(Woods::FlowAssembler).to receive(:new).and_return(assembler)
      allow(assembler).to receive(:assemble).and_raise(StandardError, 'broken route table')

      expect { full_extract }.to raise_error(Woods::ExtractionError, /broken route table/)

      expect(generation_bytes).to eq(before_bytes)
    end

    it 'aborts publication when the flow index write fails' do
      before_bytes = generation_bytes

      failed = false
      allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, path, content|
        if !failed && path.to_s.end_with?('flow_index.json')
          failed = true
          raise Woods::ExtractionError, 'disk full'
        end
        original.call(path, content)
      end

      expect { full_extract }.to raise_error(Woods::ExtractionError, /disk full/)

      expect(generation_bytes).to eq(before_bytes)
    end

    it 'aborts publication when the controller annotation write fails' do
      before_bytes = generation_bytes

      # The annotation rewrite is the run's only controller JSON write whose
      # serialized content carries metadata.flow_paths.
      allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, path, content|
        if path.to_s.include?('/controllers/') && content.to_s.include?('"flow_paths"')
          raise Woods::ExtractionError, 'disk full'
        end

        original.call(path, content)
      end

      expect { full_extract }.to raise_error(Woods::ExtractionError, /disk full/)

      expect(generation_bytes).to eq(before_bytes)
    end

    it 'leaves the previously published generation readable and unchanged' do
      before_bytes = generation_bytes
      before_flows = flow_snapshot
      before_manifest = File.read(File.join(flow_payload_dir, 'manifest.json'))
      before_graph = File.read(File.join(flow_payload_dir, 'dependency_graph.json'))

      allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, path, content|
        raise Woods::ExtractionError, 'disk full' if path.to_s.end_with?('flow_index.json')

        original.call(path, content)
      end

      expect { full_extract }.to raise_error(Woods::ExtractionError, /disk full/)

      # Read through the published generation pointer, mirroring the
      # incremental injections' assertion shape.
      expect(generation_bytes).to eq(before_bytes)
      expect(flow_snapshot).to eq(before_flows)
      expect(File.read(File.join(flow_payload_dir, 'manifest.json'))).to eq(before_manifest)
      expect(File.read(File.join(flow_payload_dir, 'dependency_graph.json'))).to eq(before_graph)
    end
  end
end
