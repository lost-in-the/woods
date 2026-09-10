# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'woods/release/preparer'
require 'woods/release/rake_support'

RSpec.describe 'release rake tasks' do
  let(:rake_path) { File.expand_path('../../lib/tasks/release.rake', __dir__) }
  let(:root) { File.expand_path('../..', __dir__) }
  let(:inventory_path) { File.join(root, Woods::Release::RakeSupport::SURFACE_INVENTORY_PATH) }

  # `bundler/gem_tasks` already defines a `release` namespace whose entry point
  # tags and pushes to RubyGems from wherever it runs, which this flow forbids.
  # The stand-ins below stand for those tasks so the guard can be exercised
  # without loading Bundler's real ones.
  # Rake only records `desc` metadata when its CLI asks it to, so the comment
  # assertions below need the same switch the `rake` binary flips.
  #
  # `on_write_inventory` stands for what `release_v2:write_surface_inventory`
  # does to the real inventory file: the default is a no-op (the file this
  # process reads is untouched, which is the "regeneration changed nothing"
  # case), and a test that wants the "it moved" case overrides it to write
  # different bytes. Either way, this restores the real file's content
  # afterward so the wiring test never leaves the checkout dirty.
  def with_release_tasks(on_write_inventory: -> {})
    original_inventory = File.binread(inventory_path)
    application = Rake::Application.new
    recording = Rake::TaskManager.record_task_metadata
    Rake::TaskManager.record_task_metadata = true
    Rake.with_application(application) do
      Rake::Task.define_task('release') { raise 'bundler release ran' }
      Rake::Task.define_task('release:rubygem_push') { raise 'bundler gem push ran' }
      Rake::Task.define_task('release_v2:write_surface_inventory') do
        inventory_runs << :written
        on_write_inventory.call
      end
      load rake_path
      yield application
    end
  ensure
    Rake::TaskManager.record_task_metadata = recording
    File.binwrite(inventory_path, original_inventory)
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

  it 'exposes release:preflight standalone, printing the same advisory report prepare prints' do
    with_release_tasks do |application|
      expect(application['release:preflight'].comment).to include('Advisory')
      expect { application['release:preflight'].invoke }.to output(/Preflight \(advisory/).to_stdout
    end
  end

  def stub_prepare_result(changed_paths: ['CHANGELOG.md'])
    result = Woods::Release::Preparer::Result.new(
      previous: Woods::Release::VersionState.parse('2.0.0.alpha'),
      target: Woods::Release::VersionState.parse('2.0.0.beta1'),
      changed_paths: changed_paths, render: ->(changed) { "Changed: #{changed.join(', ')}" }
    )
    allow(Woods::Release::Preparer).to receive(:prepare)
      .with(root: root, version: '2.0.0.beta1').and_return(result)
  end

  it 'prints the preflight report before the report holding the tag and dispatch commands' do
    result = Woods::Release::Preparer::Result.new(
      previous: Woods::Release::VersionState.parse('2.0.0.alpha'),
      target: Woods::Release::VersionState.parse('2.0.0.beta1'), changed_paths: ['CHANGELOG.md'],
      render: ->(_changed) { 'git tag v2.0.0.beta1 <merge-sha>' }
    )
    allow(Woods::Release::Preparer).to receive(:prepare).with(root: root, version: '2.0.0.beta1').and_return(result)

    output = nil
    with_release_tasks do |application|
      original_stdout = $stdout
      $stdout = StringIO.new
      begin
        application['release:prepare'].invoke('2.0.0.beta1')
        output = $stdout.string
      ensure
        $stdout = original_stdout
      end
    end

    preflight_index = output.index('Preflight (advisory')
    tag_command_index = output.index('git tag v2.0.0.beta1')
    expect(preflight_index).not_to be_nil
    expect(tag_command_index).not_to be_nil
    expect(preflight_index).to be < tag_command_index
  end

  it 'regenerates the surface inventory last and lists it as changed when regeneration moves it' do
    stub_prepare_result

    with_release_tasks(on_write_inventory: lambda {
      File.write(inventory_path, "#{File.read(inventory_path)}\n")
    }) do |application|
      expect { application['release:prepare'].invoke('2.0.0.beta1') }
        .to output(%r{Changed: \.Codex/release-v2/surface-inventory\.json, CHANGELOG\.md}).to_stdout
    end

    expect(Woods::Release::Preparer).to have_received(:prepare)
    expect(inventory_runs).to eq([:written])
  end

  # The three-minor follow-up from the beta1 release-flow review: the task
  # used to list the inventory unconditionally, even when its own
  # regeneration left the file byte-identical (the ordinary case, since the
  # inventory only drifts when a public surface changed). A reviewer reading
  # "Changed:" should only see files that actually moved.
  def lists_only_changelog_as_changed?(text)
    text.include?('Changed: CHANGELOG.md') && !text.include?('surface-inventory.json')
  end

  it 'omits the inventory from Changed when regenerating it changes nothing' do
    stub_prepare_result

    with_release_tasks do |application| # default on_write_inventory is a no-op
      expect { application['release:prepare'].invoke('2.0.0.beta1') }
        .to output(satisfy { |text| lists_only_changelog_as_changed?(text) }).to_stdout
    end

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
