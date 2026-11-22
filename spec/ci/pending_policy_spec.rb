# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tempfile'
require 'tmpdir'
require 'woods/git_version'

RSpec.describe 'CI pending policy' do
  def run_example(body, ci_value: 'true')
    Tempfile.create(['woods-pending-policy', '.rb']) do |file|
      file.write("RSpec.describe('policy probe') { #{body} }")
      file.flush
      Open3.capture3({ 'CI' => ci_value, 'COVERAGE' => nil }, RbConfig.ruby,
                     Gem.bin_path('rspec-core', 'rspec'), '--options', File::NULL,
                     '--require', File.expand_path('../support/pending_policy.rb', __dir__), file.path)
    end
  end

  it 'fails CI for a newly skipped example' do
    output, errors, status = run_example("it('new skip') { skip 'not implemented' }")
    expect(status.exitstatus).to eq(1), output + errors
    expect(output + errors).to include('Unexpected pending examples', 'new skip', 'not implemented')
  end

  it 'fails CI for xit and pending metadata' do
    ['xit(\'disabled\') {}', "it('disabled', pending: 'later') { raise 'known failure' }"].each do |body|
      output, errors, status = run_example(body)
      expect(status.exitstatus).to eq(1), output + errors
      expect(output + errors).to include('Unexpected pending examples')
    end
  end

  it 'does not alter local pending behavior' do
    output, errors, status = run_example("it('local skip') { skip 'local experiment' }", ci_value: nil)
    expect(status.exitstatus).to eq(0), output + errors
  end

  it 'does not accept a reviewed reason on an unrelated example' do
    output, errors, status = run_example("it('unrelated') { skip 'tokenizers gem not installed' }")
    expect(status.exitstatus).to eq(1), output + errors
  end

  it 'keeps ordinary passing examples green in CI' do
    output, errors, status = run_example("it('passes') { expect(1).to eq(1) }")
    expect(status.exitstatus).to eq(0), output + errors
  end
end

RSpec.describe PendingPolicy do
  def pending_example(file:, description:, reason:)
    double(metadata: { file_path: File.join(described_class::ROOT, file) }, full_description: description,
           execution_result: double(pending_message: reason))
  end

  it 'accepts only the exact reviewed example and reason while the capability is unavailable' do
    file, description, reason, unavailable = described_class::ENTRIES.first
    allow(unavailable).to receive(:call).and_return(true)
    expect(described_class.allowed?(pending_example(file: file, description: description, reason: reason))).to be true
    expect(described_class.allowed?(pending_example(file: file, description: description, reason: 'other'))).to be false
    expect(described_class.allowed?(pending_example(file: file, description: 'other', reason: reason))).to be false
    expect(described_class.allowed?(pending_example(file: 'spec/other.rb', description: description,
                                                    reason: reason))).to be false
    allow(unavailable).to receive(:call).and_return(false)
    expect(described_class.allowed?(pending_example(file: file, description: description, reason: reason))).to be false
  end
end

RSpec.describe 'CI pending policy for examples that need a capable git' do
  let(:reason) { 'needs Git 2.31.0 or newer' }
  let(:rows) { PendingPolicy::ENTRIES.select { |_file, _description, row_reason, _unavailable| row_reason == reason } }

  # Every spec file that tags an example :capable_git, other than this one.
  def tagged_files
    Dir[File.join(PendingPolicy::ROOT, 'spec/**/*_spec.rb')].select do |path|
      path != __FILE__ && File.read(path).include?(':capable_git')
    end
  end

  # A directory whose git answers `git --version` with 2.30.2 and runs the real git for everything else.
  def old_git_dir(dir)
    real = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |entry| File.join(entry, 'git') }
              .find { |candidate| File.executable?(candidate) }
    File.write(File.join(dir, 'git'),
               "#!/bin/sh\n[ \"$1\" = --version ] && { echo 'git version 2.30.2'; exit 0; }\nexec #{real} \"$@\"\n")
    File.chmod(0o755, File.join(dir, 'git'))
    dir
  end

  it 'keeps CI green with every tagged example pending on a git older than 2.31' do
    Dir.mktmpdir('woods-old-git') do |dir|
      results = File.join(dir, 'results.json')
      env = { 'CI' => 'true', 'COVERAGE' => nil,
              'PATH' => [old_git_dir(dir), ENV.fetch('PATH')].join(File::PATH_SEPARATOR) }
      output, errors, status = Open3.capture3(env, RbConfig.ruby, Gem.bin_path('rspec-core', 'rspec'),
                                              '--options', File::NULL, '--require', 'spec_helper',
                                              '--tag', 'capable_git', '--format', 'json', '--out', results,
                                              *tagged_files, chdir: PendingPolicy::ROOT)

      report = JSON.parse(File.read(results))
      expect(status.exitstatus).to eq(0), [output, errors, *report['messages']].join("\n")
      examples = report.fetch('examples')
      expect(examples).not_to be_empty
      expect(examples.map { |example| [example['status'], example['pending_message']] }.uniq)
        .to eq([['pending', reason]])
    end
  end

  it 'lets every tagged example run on a git that is new enough' do
    expect(rows).not_to be_empty
    answered = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture2).with('git', '--version').and_return(["git version 2.31.0\n", answered])
    expect(rows.map { |row| row[3].call }.uniq).to eq([false])

    allow(Open3).to receive(:capture2).with('git', '--version').and_return(["git version 2.30.2\n", answered])
    expect(rows.map { |row| row[3].call }.uniq).to eq([true])
  end
end
