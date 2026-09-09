# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'woods/release/preparer'

RSpec.describe 'release rake tasks' do
  let(:rake_path) { File.expand_path('../../lib/tasks/release.rake', __dir__) }
  let(:root) { File.expand_path('../..', __dir__) }

  # `bundler/gem_tasks` already defines a `release` namespace whose entry point
  # tags and pushes to RubyGems from wherever it runs, which this flow forbids.
  # The stand-ins below stand for those tasks so the guard can be exercised
  # without loading Bundler's real ones.
  # Rake only records `desc` metadata when its CLI asks it to, so the comment
  # assertions below need the same switch the `rake` binary flips.
  def with_release_tasks
    application = Rake::Application.new
    recording = Rake::TaskManager.record_task_metadata
    Rake::TaskManager.record_task_metadata = true
    Rake.with_application(application) do
      Rake::Task.define_task('release') { raise 'bundler release ran' }
      Rake::Task.define_task('release:rubygem_push') { raise 'bundler gem push ran' }
      Rake::Task.define_task('release_v2:write_surface_inventory') { inventory_runs << :written }
      load rake_path
      yield application
    end
  ensure
    Rake::TaskManager.record_task_metadata = recording
  end

  let(:inventory_runs) { [] }

  it 'exposes one documented task per transition, each taking the target version' do
    with_release_tasks do |application|
      expect(application['release:prepare'].arg_names).to eq([:version])
      expect(application['release:reopen'].arg_names).to eq([:version])
      expect(application['release:prepare'].comment).to include('release')
      expect(application['release:reopen'].comment).to include('development')
    end
  end

  it 'delegates to the release machinery and regenerates the surface inventory last' do
    result = Woods::Release::Preparer::Result.new(
      previous: Woods::Release::VersionState.parse('2.0.0.alpha'),
      target: Woods::Release::VersionState.parse('2.0.0.beta1'),
      changed_paths: ['CHANGELOG.md'], render: ->(changed) { "Changed: #{changed.join(', ')}" }
    )
    allow(Woods::Release::Preparer).to receive(:prepare)
      .with(root: root, version: '2.0.0.beta1').and_return(result)

    with_release_tasks do |application|
      expect { application['release:prepare'].invoke('2.0.0.beta1') }
        .to output(%r{Changed: \.Codex/release-v2/surface-inventory\.json, CHANGELOG\.md}).to_stdout
    end

    expect(Woods::Release::Preparer).to have_received(:prepare)
    expect(inventory_runs).to eq([:written])
  end

  it 'delegates reopening to the release machinery' do
    result = Woods::Release::Preparer::Result.new(
      previous: Woods::Release::VersionState.parse('2.0.0'),
      target: Woods::Release::VersionState.parse('2.1.0.alpha'),
      changed_paths: ['README.md'], render: ->(changed) { "Reopened: #{changed.join(', ')}" }
    )
    allow(Woods::Release::Preparer).to receive(:reopen)
      .with(root: root, version: '2.1.0.alpha').and_return(result)

    with_release_tasks do |application|
      expect { application['release:reopen'].invoke('2.1.0.alpha') }
        .to output(/Reopened: README\.md/).to_stdout
    end
  end

  it 'turns a refusal into a clean abort instead of a backtrace' do
    allow(Woods::Release::Preparer).to receive(:prepare)
      .and_raise(Woods::Release::Preparer::DirtyWorkingTree, 'the working tree has uncommitted changes')

    with_release_tasks do |application|
      expect { application['release:prepare'].invoke('2.0.0.beta1') }
        .to raise_error(SystemExit).and output(/the working tree has uncommitted changes/).to_stderr
    end
    expect(inventory_runs).to be_empty
  end

  it 'refuses to run without a target version' do
    with_release_tasks do |application|
      expect { application['release:prepare'].invoke }
        .to raise_error(SystemExit).and output(/release:prepare\[/).to_stderr
    end
  end

  it 'blocks the bundler release tasks that would publish from a laptop' do
    with_release_tasks do |application|
      expect { application['release'].invoke }
        .to raise_error(SystemExit).and output(/release:prepare/).to_stderr
      expect { application['release:rubygem_push'].invoke }
        .to raise_error(SystemExit).and output(/dispatch workflow/).to_stderr
    end
  end

  # A blocked task with no comment vanishes from `rake -T`, so the next person
  # rediscovers it by running it. Keep it listed, and say what to run instead.
  it 'keeps the blocked tasks visible in the task list with a pointer to the flow' do
    with_release_tasks do |application|
      %w[release release:rubygem_push].each do |name|
        expect(application[name].comment).to include('BLOCKED'), "#{name} is not listed as blocked"
        expect(application[name].comment).to include('release:prepare')
      end
    end
  end
end
