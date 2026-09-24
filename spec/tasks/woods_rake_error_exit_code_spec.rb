# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# INF-4 (+ EXP-4). `woods:embed`, `woods:embed_incremental` and
# `woods:notion_sync` printed `Errors: N` and exited 0. In the CI/cron
# deployments these tasks are written for, a revoked API key failing mid-run, a
# full vector store, or a Notion 401 on every page left the pipeline green
# while the index or the Notion database rotted. Their siblings already fail
# loudly: `woods:unblocked_sync` (with its budget-exhaustion carve-out) and
# `woods:obsidian` both exit 1, and #270 fixed the same posture for the
# extraction family. Same CI exposure, same contract.
#
# Subprocess fixtures in the woods_rake_publication_spec style: a throwaway
# Rakefile that loads the real lib/tasks/woods.rake under a minimal fake Rails
# and swaps the indexer/exporter for one that reports errors.
RSpec.describe 'embedding and export task exit codes on reported errors' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_task(task_name, fixture)
    Dir.mktmpdir('woods-error-exit-task') do |dir|
      rakefile = File.join(dir, 'Rakefile')
      File.write(rakefile, <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        require 'woods'

        module Rails
          def self.version = '8.0.0'
          def self.root = Pathname.new(#{dir.inspect})
        end

        task :environment
        load #{File.join(root, 'lib/tasks/woods.rake').inspect}

        #{fixture}
      RUBY

      env = {
        'WOODS_IGNORE_WATCH' => '1',
        'WOODS_OUTPUT' => File.join(dir, 'index')
      }
      Open3.capture3(env, RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', rakefile, task_name,
                     chdir: dir)
    end
  end

  # An indexer whose stats carry a non-zero :errors count, the shape
  # Embedding::Indexer produces when per-unit failures accumulate.
  def embed_fixture(errors:)
    <<~RUBY
      require 'woods/tasks'
      module Woods
        module Tasks
          def self.build_embed_indexer
            Object.new.tap do |indexer|
              def indexer.index_all = { processed: 4, skipped: 1, errors: #{errors} }
              def indexer.index_incremental = { processed: 4, skipped: 1, errors: #{errors} }
            end
          end
        end
      end
    RUBY
  end

  def notion_fixture(errors:)
    <<~RUBY
      require 'woods/notion/exporter'
      Woods.configuration.notion_api_token = 'secret_token_fixture'
      Woods.configuration.notion_database_ids = { data_models: 'db-uuid' }
      class Woods::Notion::Exporter
        def initialize(index_dir:); end
        def sync_all = { data_models: 2, columns: 5, errors: #{errors.inspect} }
      end
    RUBY
  end

  def unblocked_fixture(stats:, preview: false)
    <<~RUBY
      require 'woods/unblocked/exporter'
      Woods.configuration.unblocked_api_token = 'offline'
      Woods.configuration.unblocked_collection_id = 'ours'
      Woods.configuration.unblocked_repo_url = 'https://example.test/app'
      ENV['UNBLOCKED_DRY_RUN'] = #{preview.to_s.inspect}
      ENV['UNBLOCKED_MIGRATE_FROM_REF'] = 'old-branch'
      class Woods::Unblocked::Exporter
        def initialize(index_dir:, force_full:, force_purge:, dry_run:, migrate_from_ref:)
          raise 'wrong preview flag' unless dry_run == #{preview}
          raise 'wrong source ref' unless migrate_from_ref == 'old-branch'
        end
        def sync_all = #{stats.inspect}
      end
    RUBY
  end

  describe 'woods:unblocked_sync' do
    it 'shows a machine-readable preview without claiming a completed sync' do
      fixture = unblocked_fixture(preview: true, stats: { dry_run: true, complete: false, migration: [] })
      out, err, status = run_task('woods:unblocked_sync', fixture)
      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include('Sync preview', '"migration": []')
      expect(out).not_to include('Sync complete!')
    end

    it 'fails incomplete cleanup even when no remote error was reported' do
      fixture = unblocked_fixture(stats: { synced: 0, skipped: 12, deleted: 0, errors: [], complete: false })
      out, _err, status = run_task('woods:unblocked_sync', fixture)
      expect(status.exitstatus).to eq(1)
      expect(out).to include('Sync incomplete')
      expect(out).not_to include('Sync complete!')
    end
  end

  describe 'woods:embed' do
    it 'exits non-zero when the indexer reports errors' do
      out, err, status = run_task('woods:embed', embed_fixture(errors: 7))

      expect(status).not_to be_success
      expect(out).to include('Errors:    7')
      expect("#{out}\n#{err}").to match(/failing so CI surfaces it|completed with errors/i)
    end

    it 'exits 0 on a clean run' do
      out, err, status = run_task('woods:embed', embed_fixture(errors: 0))

      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include('Embedding complete!')
    end
  end

  describe 'woods:embed_incremental' do
    it 'exits non-zero when the indexer reports errors' do
      out, _err, status = run_task('woods:embed_incremental', embed_fixture(errors: 3))

      expect(status).not_to be_success
      expect(out).to include('Errors:    3')
    end

    it 'exits 0 on a clean run' do
      out, err, status = run_task('woods:embed_incremental', embed_fixture(errors: 0))

      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include('Incremental embedding complete!')
    end
  end

  describe 'woods:notion_sync' do
    it 'exits non-zero when the exporter reports errors' do
      out, _err, status = run_task('woods:notion_sync', notion_fixture(errors: ['401 Unauthorized']))

      expect(status).not_to be_success
      expect(out).to include('Errors:      1')
    end

    it 'exits 0 on a clean run' do
      out, err, status = run_task('woods:notion_sync', notion_fixture(errors: []))

      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include('Sync complete!')
    end
  end
end
