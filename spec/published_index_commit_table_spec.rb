# frozen_string_literal: true

require 'spec_helper'
require 'woods/published_index'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Woods::PublishedIndex, '#git_commits' do
  let(:fixture_dir) { File.expand_path('fixtures/woods', __dir__) }
  let(:job) { 'app/jobs/notify_subscribers_job.rb' }
  let(:mailer) { 'app/mailers/mailing_list_mailer.rb' }
  let(:model) { 'app/models/post.rb' }
  let(:digest_sha) { "2e8d0b4#{'1' * 33}" }
  let(:model_sha) { "361468d#{'2' * 33}" }
  let(:mailer_sha) { "c13f7a8#{'3' * 33}" }

  def row(sha, message, files, author: 'Leah Armstrong', days_ago: 1)
    { 'sha' => sha, 'parents' => ['f' * 40], 'author' => author,
      'date' => (Time.utc(2026, 10, 23) - (days_ago * 86_400)).iso8601, 'message' => message,
      'description' => '', 'files' => files.map { |path| { 'path' => path, 'status' => 'modified' } },
      'files_omitted' => 0 }
  end

  # Design-study scenario 2: the job and the mailer were touched together six
  # days ago in a "digest" refactor.
  def scenario_table
    { 'schema_version' => 1, 'head' => model_sha, 'since' => '2025-10-23', 'window_days' => 365,
      'max_commits' => 5000, 'max_files_per_commit' => 100, 'indexed_paths_sha256' => 'x' * 64,
      'truncated' => false,
      'commits' => [row(model_sha, 'Touch the author when a post is saved', [model], days_ago: 3),
                    row(digest_sha, 'Send subscriber digests from the job', [job, mailer, 'README.md'],
                        author: 'Sam Okafor-Whitfield', days_ago: 6),
                    row(mailer_sha, 'Mailing list layout', [mailer], days_ago: 12)],
      'paths' => { mailer => [digest_sha, mailer_sha], model => [model_sha], job => [digest_sha] } }
  end

  def payload(number)
    File.join(@index_dir, 'payloads', "gen-#{number}")
  end

  around do |example|
    Dir.mktmpdir('woods-published-commits') do |dir|
      @index_dir = dir
      [1, 2].each do |number|
        FileUtils.mkdir_p(payload(number))
        FileUtils.cp_r(Dir[File.join(fixture_dir, '*')], payload(number))
      end
      File.write(File.join(dir, 'generation.json'),
                 JSON.generate('number' => 2, 'token' => 'abc', 'payload' => 'payloads/gen-2'))
      example.run
    end
  end

  def write_table(number, table)
    File.write(File.join(payload(number), 'git_commits.json'), JSON.generate(table))
  end

  it 'answers nil when the generation publishes no table' do
    described_class.open(@index_dir) { |index| expect(index.git_commits).to be_nil }
  end

  it 'answers scenario 2 step 3 (the job and mailer changed together) from the commit table' do
    write_table(2, scenario_table)

    described_class.open(@index_dir) do |index|
      table = index.git_commits
      shared = table.commits_for(job) & table.commits_for(mailer)

      expect(shared.map { |entry| entry.values_at('message', 'author') })
        .to eq([['Send subscriber digests from the job', 'Sam Okafor-Whitfield']])
      expect(table.co_changes(job)).to eq([{ 'path' => mailer, 'commits' => 1 }])
      expect(table.co_changes(mailer)).to eq([{ 'path' => job, 'commits' => 1 }])
      expect(table.indexed_paths_for(digest_sha)).to eq([job, mailer])
    end
  end

  it 'lists commits newest first and resolves the short shas recent_commits publishes' do
    write_table(2, scenario_table)

    described_class.open(@index_dir) do |index|
      table = index.git_commits

      expect(table.commits.map { |entry| entry['sha'] }).to eq([model_sha, digest_sha, mailer_sha])
      expect(table.commits_for(mailer, model).map { |entry| entry['sha'] }).to eq([model_sha, digest_sha, mailer_sha])
      expect(table.commit(digest_sha[0, 8])).to include('message' => 'Send subscriber digests from the job')
      expect(table.commit('2e8')).to be_nil
      expect(table.commit('0000000')).to be_nil
      expect(table).to have_attributes(head: model_sha, since: '2025-10-23', window_days: 365, max_commits: 5000,
                                       max_files_per_commit: 100, truncated?: false)
      expect(table.commits).to be_frozen
      expect(table.commits.first['files']).to be_frozen
    end
  end

  it 'reads the pinned generation, not the current one' do
    write_table(1, scenario_table.merge('head' => digest_sha))
    write_table(2, scenario_table)

    described_class.open(@index_dir, generation: 1) { |index| expect(index.git_commits.head).to eq(digest_sha) }
  end

  it 'refuses an unparseable, unknown-schema or symlinked table instead of reading it as absent' do
    path = File.join(payload(2), 'git_commits.json')
    File.write(path, '{')
    described_class.open(@index_dir) do |index|
      expect { index.git_commits }.to raise_error(described_class::CorruptArtifactError, /does not parse/)
    end

    write_table(2, scenario_table.merge('schema_version' => 2))
    described_class.open(@index_dir) do |index|
      expect { index.git_commits }.to raise_error(described_class::CorruptArtifactError, /schema version 1/)
    end

    File.delete(path)
    elsewhere = File.join(@index_dir, 'elsewhere.json')
    File.write(elsewhere, JSON.generate(scenario_table))
    File.symlink(elsewhere, path)
    described_class.open(@index_dir) do |index|
      expect { index.git_commits }.to raise_error(described_class::CorruptArtifactError, /symlink/)
    end
  end
end
