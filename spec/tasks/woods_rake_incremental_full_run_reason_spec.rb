# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'pathname'
require 'stringio'
require 'woods/rake_helpers'

# With no CHANGED_FILES and no CI range, `woods:incremental` diffs `HEAD~1`
# against the working tree, so an uncommitted restart input (a local Gemfile
# pin) turns a run meant to cover one commit into a full extraction. The task
# printed "Full extraction for N changed files" and nothing about which path
# forced it or where that path came from (#948). It now names each forcing path
# and its source, bounded to FullRunReason::LIMIT paths.
RSpec.describe 'woods:incremental full-run reason (#948)' do
  let(:repo_dir) { Dir.mktmpdir('woods_full_run_reason') }
  let(:output_dir) { Dir.mktmpdir('woods_full_run_reason_index') }
  let(:extractor) do
    require 'woods/extractor'
    instance_double(Woods::Extractor, raise_on_publication_failure!: nil, extractor_timings: {})
  end

  around do |example|
    keys = %w[CHANGED_FILES CI_COMMIT_BEFORE_SHA CI_COMMIT_SHA GITHUB_BASE_REF WOODS_IGNORE_WATCH WOODS_GIT_DIR]
    saved = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.rm_rf(repo_dir)
    FileUtils.rm_rf(output_dir)
  end

  def git(*args)
    out, status = Open3.capture2e('git', *args, chdir: repo_dir)
    raise "git #{args.join(' ')} failed:\n#{out}" unless status.success?

    out
  end

  def write(path, content)
    full = File.join(repo_dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(message, allow_empty: false)
    git('add', '-A')
    git('commit', '--quiet', *(allow_empty ? ['--allow-empty'] : []), '-m', message)
  end

  before do
    git('init', '--quiet', '--initial-branch', 'main')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Test')
    git('config', 'commit.gpgsign', 'false')
    git('config', 'gc.autoDetach', 'false')
    git('config', 'gc.auto', '0')
    write('Gemfile', "source 'https://rubygems.org'\n")
    write('app/models/user.rb', "class User; end\n")
    commit('initial')

    require 'woods/extractor'
    stub_const('Rails', double('Rails', root: Pathname.new(repo_dir)))
    ENV['WOODS_OUTPUT'] = output_dir
    allow(Woods::RakeHelpers).to receive(:woods_daemon_coverage).and_return(:none)
    allow(Woods::RakeHelpers).to receive(:woods_with_extraction_lock).and_yield
    allow(Woods::Extractor).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:extract_all).and_return({ models: [] })
    allow(Woods::RakeHelpers).to receive(:woods_git_enrichment_summary).and_return('')
  end

  def run_incremental
    previous = Rake.application
    Rake.application = Rake::Application.new
    load File.expand_path('../../lib/tasks/woods.rake', __dir__)
    out = StringIO.new
    original = $stdout
    $stdout = out
    Rake::Task['woods:incremental'].execute
    out.string
  ensure
    $stdout = original if original
    Rake.application = previous if previous
  end

  it 'names an uncommitted restart input as coming from the working tree' do
    commit('empty', allow_empty: true)
    write('Gemfile', "source 'https://rubygems.org'\ngem 'local', path: '../local'\n")

    output = run_incremental

    expect(output).to include('Full extraction forced by 1 restart input')
    expect(output).to include('  - Gemfile (working tree, uncommitted)')
    expect(output).not_to match(/Gemfile \(committed/)
    expect(output).to match(/Uncommitted changes are included.*CHANGED_FILES/m)
  end

  it 'names a committed restart input as committed in the range' do
    write('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\n")
    commit('pin rails')

    output = run_incremental

    expect(output).to include('  - Gemfile (committed in HEAD~1..HEAD)')
    expect(output).not_to include('working tree')
  end

  it 'names a path changed in both places with both sources' do
    write('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\n")
    commit('pin rails')
    write('Gemfile', "source 'https://rubygems.org'\ngem 'rails', path: '../rails'\n")

    output = run_incremental

    expect(output).to include('  - Gemfile (committed in HEAD~1..HEAD, then changed again in the working tree)')
  end

  it 'caps the forcing list and counts the rest' do
    names = (1..12).map { |n| format('config/initializers/i%02d.rb', n) }
    names.each { |name| write(name, "# frozen\n") }
    commit('initializers')
    commit('empty', allow_empty: true)
    names.each { |name| write(name, "# changed\n") }

    output = run_incremental
    reason_rows = output.lines.grep(%r{\A  - config/initializers/i\d+\.rb \(})

    expect(output).to include('Full extraction forced by 12 restart inputs')
    expect(reason_rows.size).to eq(10)
    expect(reason_rows.first).to start_with('  - config/initializers/i01.rb (working tree')
    expect(output).to include('  ... and 2 more')
  end

  it 'attributes explicit CHANGED_FILES paths to CHANGED_FILES without consulting git' do
    ENV['CHANGED_FILES'] = 'Gemfile.lock'
    expect(Woods::RakeHelpers).not_to receive(:woods_changed_paths_for_range)

    output = run_incremental

    expect(output).to include('  - Gemfile.lock (named by CHANGED_FILES)')
    expect(output).not_to include('Uncommitted changes are included')
  end

  it 'prints no reason for an incremental run' do
    commit('empty', allow_empty: true)
    write('app/models/user.rb', "class User\nend\n")
    allow(extractor).to receive(:extract_changed).and_return([])

    output = run_incremental

    expect(output).to include('Incremental extraction for 1 changed files')
    expect(output).not_to include('forced by')
  end
end
