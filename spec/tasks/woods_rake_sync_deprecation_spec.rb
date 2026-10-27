# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'Notion and Unblocked sync task deprecation' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_tasks(names, fixture)
    Dir.mktmpdir('woods-sync-deprecation') do |dir|
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
        #{names.map { |n| "Rake::Task[#{n.inspect}].reenable; Rake::Task[#{n.inspect}].invoke" }.join("\n")}
      RUBY
      env = { 'WOODS_IGNORE_WATCH' => '1', 'WOODS_OUTPUT' => File.join(dir, 'index') }
      Open3.capture3(env, RbConfig.ruby, '-e', 'load ARGV.shift', rakefile, chdir: dir)
    end
  end

  let(:notion_fixture) do
    <<~RUBY
      require 'woods/notion/exporter'
      Woods.configuration.notion_api_token = 'secret_token_fixture'
      Woods.configuration.notion_database_ids = { data_models: 'db-uuid' }
      class Woods::Notion::Exporter
        def initialize(index_dir:); end
        def sync_all = { data_models: 1, columns: 1, errors: [] }
      end
    RUBY
  end

  let(:unblocked_fixture) do
    <<~RUBY
      require 'woods/unblocked/exporter'
      Woods.configuration.unblocked_api_token = 'offline'
      Woods.configuration.unblocked_collection_id = 'ours'
      Woods.configuration.unblocked_repo_url = 'https://example.test/app'
      class Woods::Unblocked::Exporter
        def initialize(**); end
        def sync_all = { synced: 1, skipped: 0, deleted: 0, errors: [] }
      end
    RUBY
  end

  {
    'woods:notion_sync' => :notion_fixture, 'woods:send' => :notion_fixture,
    'woods:unblocked_sync' => :unblocked_fixture, 'woods:relay' => :unblocked_fixture
  }.each do |task, fixture_name|
    describe task do
      it 'still runs and warns with one line pointing at the Markdown export' do
        out, err, status = run_tasks([task], send(fixture_name))
        expect(status).to be_success, "#{out}\n#{err}"
        expect(out).to include('complete')
        expect(err.lines.grep(/DEPRECATED/).size).to eq(1)
        expect(err).to include('woods:markdown')
      end

      it 'warns once per process across repeated runs' do
        _out, err, = run_tasks([task, task], send(fixture_name))
        expect(err.scan('DEPRECATED').size).to eq(1)
      end
    end
  end

  it 'warns once for the task and its alias run in the same process' do
    _out, err, = run_tasks(%w[woods:notion_sync woods:send], notion_fixture)
    expect(err.scan('DEPRECATED').size).to eq(1)
  end
end
