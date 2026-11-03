# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'woods/source_inputs/session'
require 'woods/mcp/index_reader'
require 'woods/mcp/server'

# An index extracted where its recorded root was one path and served from the
# same checkout under another path. The reader re-resolves the source root
# from the served index directory, or takes WOODS_SOURCE_ROOT, and verifies
# the captured paths and bytes there.
#
# Root resolution, as the reader applies it:
#
# | WOODS_SOURCE_ROOT | recorded root here | app root owns index | identity tie | root_source | state   |
# |-------------------|--------------------|---------------------|--------------|-------------|---------|
# | set               | any                | any                 | n/a          | explicit    | checked |
# | unset             | yes                | any                 | n/a          | recorded    | checked |
# | unset             | no                 | yes                 | yes          | re_resolved | checked |
# | unset             | no                 | yes                 | no           | re_resolved | unknown |
# | unset             | no                 | no                  | n/a          | recorded    | unknown |
#
# The identity tie for a re-resolved root:
#
# | config/application.rb captured | it matches | captured files verified | tie |
# |--------------------------------|------------|-------------------------|-----|
# | yes                            | yes        | any                     | yes |
# | yes                            | no         | any (even all others)   | no  |
# | no                             | n/a        | at least one            | yes |
# | no                             | n/a        | none                    | no  |
#
# "unknown" here is always `source_root_unavailable` with `root_rejected`,
# never drift. The tie is a heuristic: it cannot reject an unrelated tree
# whose application file is byte-identical.
RSpec.describe 'Source freshness for an index served from a relocated root' do
  around do |example|
    Dir.mktmpdir('woods-relocated-root') do |workspace|
      @workspace = File.realpath(workspace)
      @original = File.join(@workspace, 'original')
      @moved = File.join(@workspace, 'moved')
      example.run
    end
  end

  before { stub_const('ENV', ENV.to_h.except('WOODS_SOURCE_ROOT')) }

  def write(root, path, bytes)
    target = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, bytes)
  end

  def build_checkout(root)
    FileUtils.mkdir_p(File.join(root, '.git'))
    write(root, 'config/application.rb', 'module Shop; class Application; end; end')
    write(root, 'app/models/order.rb', 'class Order; end')
    write(root, 'app/services/checkout.rb', 'class Checkout; end')
  end

  def output(root)
    File.join(root, 'tmp/woods')
  end

  def publish(root, complete: true) # rubocop:disable Metrics/AbcSize -- publishes a complete independent generation fixture
    key = Woods::SourceInputs::PrivateKey.new(output_dir: output(root), create: true)
    capture = Woods::SourceInputs::Scanner.new(root: root, output_dir: output(root), key: key).call
    capture['complete'] = false unless complete
    scopes = capture.fetch('scope_paths').transform_values do |paths|
      paths.to_h { |path| [path, capture.fetch('files').fetch(path)] }
    end
    generation = Woods::Generation.new(output_dir: output(root))
    number = generation.current.number + 1
    payload = "payloads/gen-#{number}"
    dir = File.join(output(root), payload)
    FileUtils.mkdir_p(dir)
    manifest = Woods::SourceInputs::Manifest.build(snapshot: capture, scopes: scopes, boot_verified: true,
                                                   generation: number)
    File.write(File.join(dir, 'source_inputs.json'), JSON.generate(manifest.data))
    File.write(File.join(dir, 'manifest.json'),
               JSON.generate(counts: { 'models' => 1 }, total_units: 1, git_sha: 'a' * 40,
                             extracted_at: Time.now.utc.iso8601))
    generation.bump!(reason: 'full', payload: payload)
  end

  def extract_and_relocate(complete: true)
    build_checkout(@original)
    yield @original if block_given?
    publish(@original, complete: complete)
    File.rename(@original, @moved)
  end

  def freshness(root = @moved, mode: 'deep')
    Woods::MCP::IndexReader.new(output(root)).source_freshness(mode: mode)
  end

  describe 'the same checkout under another path' do
    it 'is current against the re-resolved checkout and states both roots, the scope and the exclusions' do
      extract_and_relocate

      result = freshness
      expect(result).to include('state' => 'current', 'root_source' => 're_resolved',
                                'recorded_root' => @original, 'checked_root' => @moved, 'complete' => true)
      expect(result['scope']['consumer_scopes']).to include('runtime', 'file:services', 'boot')
      expect(result['scope']['declared_roots']).to eq([])
      expect(result['exclusions']['directories']).to include('tmp', 'log', 'coverage', 'node_modules')
      expect(result['exclusions']).to include('hidden_entries' => true, 'index_output' => output(@moved))
    end

    it 'still checks the recorded root when that path is reachable, as before' do
      build_checkout(@original)
      publish(@original)
      FileUtils.cp_r(@original, @moved)
      write(@moved, 'app/models/order.rb', 'edited only in the copy')

      expect(freshness).to include('state' => 'current', 'root_source' => 'recorded', 'checked_root' => @original)
    end

    it 'checks WOODS_SOURCE_ROOT when it is set, over both the recorded and the re-resolved root' do
      extract_and_relocate
      mapped = File.join(@workspace, 'mapped')
      FileUtils.cp_r(@moved, mapped)
      write(mapped, 'app/models/order.rb', 'edited in the mapped tree')
      stub_const('ENV', ENV.to_h.merge('WOODS_SOURCE_ROOT' => mapped))

      result = freshness
      expect(result).to include('state' => 'drifted', 'root_source' => 'explicit', 'checked_root' => mapped)
      expect(result['changes']['changed']).to eq(['app/models/order.rb'])
    end
  end

  describe 'drift within the captured scope' do
    it 'reports a changed relevant file' do
      extract_and_relocate
      write(@moved, 'app/models/order.rb', 'class Order; def total; end; end')

      result = freshness
      expect(result).to include('state' => 'drifted', 'root_source' => 're_resolved')
      expect(result['changes']).to eq('added' => [], 'changed' => ['app/models/order.rb'], 'removed' => [])
    end

    it 'reports a deleted relevant file' do
      extract_and_relocate
      FileUtils.rm(File.join(@moved, 'app/services/checkout.rb'))

      result = freshness
      expect(result['state']).to eq('drifted')
      expect(result['changes']).to eq('added' => [], 'changed' => [], 'removed' => ['app/services/checkout.rb'])
    end

    it 'reports a newly added relevant file' do
      extract_and_relocate
      write(@moved, 'app/models/refund.rb', 'class Refund; end')

      result = freshness
      expect(result['state']).to eq('drifted')
      expect(result['changes']).to eq('added' => ['app/models/refund.rb'], 'changed' => [], 'removed' => [])
    end

    # Near misses: each file is new in the relocated tree, but none would have
    # been captured, so none is drift.
    {
      'a generated coverage report' => 'coverage/index.html',
      'a log file' => 'log/development.log',
      'a temporary Ruby file' => 'tmp/scratch.rb',
      'a compiled asset' => 'public/assets/application-0f3c.js',
      'a dependency under node_modules' => 'node_modules/pkg/index.js',
      'a hidden editor file' => 'app/models/.order.rb.swp',
      'a file inside the served index' => 'tmp/woods/report.json'
    }.each do |label, path|
      it "does not count #{label} as drift" do
        extract_and_relocate
        write(@moved, path, 'not an input')

        expect(freshness).to include('state' => 'current', 'root_source' => 're_resolved')
      end
    end

    it 'never reports a partial capture as current, even when every captured byte matches' do
      extract_and_relocate(complete: false)

      result = freshness
      expect(result).to include('state' => 'unknown', 'root_source' => 're_resolved', 'complete' => false)
      expect(result['reasons']).to include('incomplete_capture')
      expect(result['coverage']['verified_files']).to eq(result['coverage']['recorded_files'])
    end
  end

  describe 'the identity tie' do
    it 'accepts a relocation with a few changed files as drift' do
      extract_and_relocate { |root| 4.times { |i| write(root, "app/services/step_#{i}.rb", "class Step#{i}; end") } }
      write(@moved, 'app/services/step_0.rb', 'class Step0; def run; end; end')

      result = freshness
      expect(result).to include('state' => 'drifted', 'root_source' => 're_resolved')
      expect(result['changes']['changed']).to eq(['app/services/step_0.rb'])
    end

    it 'accepts the same repository at another commit as drift while the application file is unchanged' do
      extract_and_relocate { |root| 4.times { |i| write(root, "app/services/step_#{i}.rb", "class Step#{i}; end") } }
      %w[app/models/order.rb app/services/checkout.rb].each { |path| write(@moved, path, 'rewritten later') }
      4.times { |i| write(@moved, "app/services/step_#{i}.rb", 'rewritten later') }

      result = freshness
      expect(result['coverage']).to include('application_verified' => true)
      expect(result).to include('state' => 'drifted', 'root_source' => 're_resolved')
      expect(result['counts']['changed']).to eq(6)
    end

    context 'without a captured config/application.rb, as before' do
      def build_rack_checkout(root)
        FileUtils.mkdir_p(File.join(root, '.git'))
        write(root, 'config.ru', 'run Shop::Application')
        3.times { |i| write(root, "app/services/step_#{i}.rb", "class Step#{i}; end") }
      end

      def extract_rack_and_relocate
        build_rack_checkout(@original)
        publish(@original)
        File.rename(@original, @moved)
      end

      it 'accepts the root when any captured file verifies' do
        extract_rack_and_relocate
        %w[app/services/step_0.rb app/services/step_1.rb app/services/step_2.rb].each do |path|
          write(@moved, path, 'changed')
        end

        result = freshness
        expect(result['coverage']).to include('recorded_files' => 4, 'verified_files' => 1)
        expect(result['coverage']).not_to have_key('application_verified')
        expect(result).to include('state' => 'drifted', 'root_source' => 're_resolved')
      end

      it 'rejects the root when no captured file verifies' do
        extract_rack_and_relocate
        write(@moved, 'config.ru', 'run Other::Application')
        3.times { |i| write(@moved, "app/services/step_#{i}.rb", 'changed') }

        result = freshness
        expect(result).to include('state' => 'unknown', 'reasons' => ['source_root_unavailable'],
                                  'root_rejected' => 'no_identity_match')
      end
    end
  end

  describe 'Git dirtiness' do
    def git(root, *args)
      env = { 'GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_NOSYSTEM' => '1' }
      out, status = Open3.capture2e(env, 'git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
                                    *args, chdir: root)
      raise "git #{args.join(' ')} failed: #{out}" unless status.success?

      out
    end

    it 'proves nothing either way: a dirty tree can be current and a clean one drifted' do
      extract_and_relocate do |root|
        FileUtils.rm_rf(File.join(root, '.git'))
        write(root, '.gitignore', "/tmp/\n")
        git(root, 'init', '-q')
        git(root, 'add', '-A')
        git(root, 'commit', '-q', '-m', 'fixture')
        write(root, 'app/models/order.rb', 'uncommitted at capture')
      end

      expect(git(@moved, 'status', '--porcelain')).not_to be_empty
      expect(freshness).to include('state' => 'current', 'root_source' => 're_resolved')

      write(@moved, 'app/models/order.rb', 'committed after capture')
      git(@moved, 'commit', '-q', '-am', 'later')
      expect(git(@moved, 'status', '--porcelain')).to be_empty
      expect(freshness['changes']['changed']).to eq(['app/models/order.rb'])
    end
  end

  describe 'an unrelated directory' do
    it 'is unavailable when no application root owns the served index' do
      extract_and_relocate
      detached = File.join(@workspace, 'detached-index')
      File.rename(output(@moved), detached)

      result = Woods::MCP::IndexReader.new(detached).source_freshness(mode: 'deep')
      expect(result).to include('state' => 'unknown', 'reasons' => ['source_root_unavailable'],
                                'root_source' => 'recorded', 'checked_root' => @original)
    end

    it 'is unavailable, not drifted, when the owning application shares no captured bytes' do
      extract_and_relocate
      other = File.join(@workspace, 'other-app')
      FileUtils.mkdir_p(File.join(other, '.git'))
      write(other, 'config/application.rb', 'module Other; class Application; end; end')
      write(other, 'app/models/invoice.rb', 'class Invoice; end')
      FileUtils.mkdir_p(File.join(other, 'tmp'))
      File.rename(output(@moved), output(other))

      result = freshness(other)
      expect(result).to include('state' => 'unknown', 'reasons' => ['source_root_unavailable'],
                                'root_source' => 're_resolved', 'checked_root' => other,
                                'root_rejected' => 'no_identity_match')
      expect(result).not_to have_key('changes')
      expect(result['recommendations']).to include('inspect_source_scan')
    end

    it 'is unavailable when only generated boilerplate matches and the application file differs' do
      boilerplate = {
        'config/boot.rb' => "require 'bundler/setup'",
        'config/environment.rb' => "require_relative 'application'\nRails.application.initialize!",
        'config/environments/development.rb' => 'Rails.application.configure { config.eager_load = false }',
        'config/environments/production.rb' => 'Rails.application.configure { config.eager_load = true }',
        'config/puma.rb' => 'threads 5, 5',
        'config/initializers/filter_parameter_logging.rb' => 'Rails.application.config.filter_parameters += [:token]'
      }
      extract_and_relocate { |root| boilerplate.each { |path, bytes| write(root, path, bytes) } }
      other = File.join(@workspace, 'other-app')
      FileUtils.mkdir_p(File.join(other, '.git'))
      boilerplate.each { |path, bytes| write(other, path, bytes) }
      write(other, 'config/application.rb', 'module Other; class Application; end; end')
      FileUtils.mkdir_p(File.join(other, 'tmp'))
      File.rename(output(@moved), output(other))

      result = freshness(other)
      expect(result['coverage']['verified_files']).to be > result['coverage']['recorded_files'] / 2
      expect(result).to include('state' => 'unknown', 'reasons' => ['source_root_unavailable'],
                                'root_rejected' => 'no_identity_match')
      expect(result).not_to have_key('changes')
    end

    it 'keeps a scan limit visible when it rejects a relocated root that matched nothing' do
      extract_and_relocate
      write(@moved, 'app/services/checkout.rb', 'unrelated')
      write(@moved, 'app/models/order.rb', 'unrelated')
      write(@moved, 'config/application.rb', 'unrelated')
      stub_const('Woods::SourceInputs::Scanner::DEFAULT_LIMITS',
                 Woods::SourceInputs::Scanner::DEFAULT_LIMITS.merge(max_files: 1))

      result = freshness
      expect(result).to include('state' => 'unknown', 'root_rejected' => 'no_identity_match')
      expect(result['verification_reasons']).to include('scan_file_budget', 'source_root_unavailable')
    end
  end

  describe 'what the relocated check leaves alone' do
    it 'runs no git process, leaves history unknown and keeps serving saved-index answers' do
      extract_and_relocate
      allow(Open3).to receive(:capture3).and_call_original
      allow(Open3).to receive(:capture2).and_call_original
      allow(Open3).to receive(:capture2e).and_call_original

      reader = Woods::MCP::IndexReader.new(output(@moved))
      expect(reader.source_freshness(mode: 'deep')).to include('state' => 'current', 'root_source' => 're_resolved')
      expect(Open3).not_to have_received(:capture3)
      expect(Open3).not_to have_received(:capture2)
      expect(Open3).not_to have_received(:capture2e)

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: output(@moved))
      expect(status[:index][:history]).to include(state: 'unknown', reason: 'root_unreachable')
      expect(status[:index][:source_freshness]).to include('state' => 'current', 'root_source' => 're_resolved')
      expect(reader.manifest).to include('total_units' => 1, 'counts' => { 'models' => 1 })
    end
  end

  # | marker on the way up            | checkout boundary  | app_root            |
  # |---------------------------------|--------------------|---------------------|
  # | nearest app inside the checkout | repository         | that app            |
  # | only above the checkout         | repository         | nil (never crossed) |
  # | an app, no checkout anywhere    | none               | that app            |
  # | none                            | none               | nil                 |
  describe 'the owning application root' do
    def app_root(path)
      Woods::MCP::ServedIdentity.app_root(path)
    end

    it 'is the nearest application root, so an app in a repository subdirectory is the app, not the repository' do
      repo = File.join(@workspace, 'repo')
      FileUtils.mkdir_p(File.join(repo, '.git'))
      write(repo, 'config.ru', 'run ->(_) { [200, {}, []] }')
      write(repo, 'apps/shop/config/application.rb', 'module Shop; end')
      index = File.join(repo, 'apps/shop/tmp/woods')
      FileUtils.mkdir_p(index)

      expect(app_root(index)).to eq(File.join(repo, 'apps/shop'))
    end

    it 'never walks past the checkout that holds the index' do
      write(@workspace, 'config.ru', 'run ->(_) { [200, {}, []] }')
      repo = File.join(@workspace, 'repo')
      FileUtils.mkdir_p(File.join(repo, '.git'))
      index = File.join(repo, 'tmp/woods')
      FileUtils.mkdir_p(index)

      expect(app_root(index)).to be_nil
    end

    it 'finds an application outside any checkout, and nothing where no application root exists' do
      app = File.join(@workspace, 'exported')
      write(app, 'config/application.rb', 'module Exported; end')
      FileUtils.mkdir_p(File.join(app, 'tmp/woods'))
      bare = File.join(@workspace, 'bare/tmp/woods')
      FileUtils.mkdir_p(bare)

      expect(app_root(File.join(app, 'tmp/woods'))).to eq(app)
      expect(app_root(bare)).to be_nil
      expect(app_root(File.join(@workspace, 'missing'))).to be_nil
    end
  end
end
