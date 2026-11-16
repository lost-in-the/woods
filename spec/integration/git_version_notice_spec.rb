# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require 'stringio'

# The woods rake tasks on a git too old for the history walk (2.31 added
# `--diff-merges=first-parent`), in a booted copy of spec/dummy. A wrapper
# answers `git --version` with 2.30.2 and runs the real git for everything
# else, so this runs on every row; the last example uses the machine's own git
# and runs only where that git really is older than 2.31.
RSpec.describe 'Git version notice', :booted_app do
  let(:notice) do
    '[Woods] Git 2.30.2 is older than 2.31, which git enrichment and git_commits.json need; ' \
      "extraction continues without them.\n"
  end

  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'
    require File.expand_path('../dummy/config/application_config', __dir__)

    @app_root = Dir.mktmpdir('woods_git_notice_app')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @app_root)
    @db_dir = Dir.mktmpdir('woods_git_notice_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')
    git('init', '-q')
    git('add', '.')
    git('commit', '-qm', 'baseline')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @app_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyConfig.apply(WoodsDummyApplication.config, @app_root)
      WoodsDummyApplication.initialize!
    end
    BootedAppRoot.assert!(@app_root)

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:posts, force: true) do |t|
        t.string :title
        t.integer :status, default: 0
        t.timestamps
      end
      create_table(:comments, force: true) do |t|
        t.references :post
        t.text :body
        t.timestamps
      end
    end

    require 'woods'
    require 'woods/git_version'
    require 'rake'
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake::Task.define_task(:environment)
    load File.expand_path('../../lib/tasks/woods.rake', __dir__)
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    [@app_root, @db_dir].compact.each { |dir| FileUtils.rm_rf(dir) }
    ENV.delete('WOODS_DUMMY_DB')
  end

  around do |example|
    output = Dir.mktmpdir('woods_git_notice_index')
    previous = ENV.to_h.slice('WOODS_OUTPUT', 'CHANGED_FILES', 'PATH')
    ENV['WOODS_OUTPUT'] = output
    @output = output
    Woods::GitVersion.reset_announcements!
    example.run
  ensure
    %w[WOODS_OUTPUT CHANGED_FILES PATH].each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
    Woods::GitVersion.reset_announcements!
    FileUtils.rm_rf(output)
  end

  def git(*args)
    output, status = Open3.capture2e({ 'GIT_CONFIG_GLOBAL' => File::NULL }, 'git', '-C', @app_root,
                                     '-c', 'user.name=Woods test', '-c', 'user.email=test@example.invalid',
                                     '-c', 'commit.gpgsign=false', *args)
    raise "git #{args.first} failed: #{output}" unless status.success?

    output
  end

  # Put a `git` first on PATH that answers `--version` with 2.30.2, hands
  # every other command to the real git, and records each command it runs.
  def pretend_old_git
    real, status = Open3.capture2('sh', '-c', 'command -v git')
    raise 'git is not on PATH' unless status.success?

    bin = Dir.mktmpdir('woods_old_git')
    @git_calls = File.join(bin, 'calls')
    File.write(File.join(bin, 'git'), <<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then echo "git version 2.30.2"; exit 0; fi
      echo "$*" >> #{@git_calls}
      exec #{real.strip} "$@"
    SH
    File.chmod(0o755, File.join(bin, 'git'))
    ENV['PATH'] = "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
  end

  # @return [Array<String>] the `git log` commands the wrapper ran
  def history_walks
    File.exist?(@git_calls) ? File.readlines(@git_calls).grep(/(?:\A| )log /) : []
  end

  # Run one rake task and return what the terminal showed.
  def rake(task, *args)
    out = StringIO.new
    err = StringIO.new
    stdout = $stdout
    stderr = $stderr
    $stdout = out
    $stderr = err
    @rake[task].reenable
    @rake[task].invoke(*args)
    { stdout: out.string, stderr: err.string }
  ensure
    $stdout = stdout
    $stderr = stderr
  end

  def git_enrichment
    payload = Woods::Generation.new(output_dir: @output).payload_dir
    JSON.parse(File.read(payload.join('manifest.json'), encoding: 'UTF-8')).fetch('git_enrichment')
  end

  def commit_table?
    Woods::Generation.new(output_dir: @output).payload_dir.join('git_commits.json').exist?
  end

  it 'says once per run, on full, incremental and refresh runs, that git is too old, and records why' do
    pretend_old_git

    full = rake('woods:extract')
    expect(full.fetch(:stderr).lines.grep(/Git 2\.30\.2/)).to eq([notice])
    expect(full.fetch(:stdout)).to include('Git enrichment: unavailable, git_too_old (')
    expect(git_enrichment).to include('state' => 'unavailable', 'reason' => 'git_too_old', 'head_sha' => nil)
    expect(commit_table?).to be(false)
    expect(history_walks).to be_empty

    service = File.join(@app_root, 'app/services/notice_probe_service.rb')
    File.write(service, "class NoticeProbeService\n  def call = :ok\nend\n")
    ENV['CHANGED_FILES'] = 'app/services/notice_probe_service.rb'
    [rake('woods:incremental'), rake('woods:refresh', 'services')].each do |run|
      expect(run.fetch(:stderr)).to eq('')
      expect(git_enrichment).to include('reason' => 'git_too_old')
    end
    expect(history_walks).to be_empty

    # A separate process for each of the next runs, as a one-shot task is.
    Woods::GitVersion.reset_announcements!
    expect(rake('woods:incremental').fetch(:stderr).lines.grep(/Git 2\.30\.2/)).to eq([notice])
    Woods::GitVersion.reset_announcements!
    expect(rake('woods:refresh', 'services').fetch(:stderr).lines.grep(/Git 2\.30\.2/)).to eq([notice])
  ensure
    FileUtils.rm_f(service) if service
  end

  it 'says so with the real git of a machine older than 2.31' do
    found = Woods::GitVersion.parse(Open3.capture2('git', '--version').first)
    skip 'needs a git older than 2.31' unless Woods::GitVersion.too_old?(found)

    full = rake('woods:extract')
    expect(full.fetch(:stderr).lines.grep(/\[Woods\] Git /).size).to eq(1)
    expect(full.fetch(:stderr)).to include("[Woods] Git #{found} is older than 2.31")
    expect(full.fetch(:stdout)).to include('Git enrichment: unavailable, git_too_old (')
    expect(git_enrichment).to include('reason' => 'git_too_old')
  end
end
