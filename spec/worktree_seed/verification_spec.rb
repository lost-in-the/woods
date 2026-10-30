# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods'
require 'woods/worktree_seed'
require_relative '../support/quiet_git'

RSpec.describe Woods::WorktreeSeed::Verification do
  let(:base) { File.realpath(Dir.mktmpdir('woods-seed-verification')) }
  let(:source_index) { Pathname.new(File.join(base, 'seed', 'tmp', 'woods')) }
  let(:source_checkout) { File.join(base, 'seed') }
  let(:worktree) { File.join(base, 'worktree') }
  let(:manifest) do
    { 'woods_version' => Woods::VERSION, 'git_sha' => head(source_checkout), 'gemfile_lock_sha' => nil, 'schema_sha' => nil }
  end

  before do
    [source_checkout, worktree].each { |dir| init_repo(dir) }
    publish_seed
  end

  after { FileUtils.rm_rf(base) }

  def git(dir, *args)
    out, status = Open3.capture2e('git', '-C', dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out.strip
  end

  def head(dir)
    git(dir, 'rev-parse', 'HEAD')
  end

  def init_repo(dir)
    git(base, 'init', '-q', '-b', 'main', dir)
    QuietGit.configure(dir)
    File.write(File.join(dir, 'README.md'), "#{File.basename(dir)}\n")
    git(dir, 'add', 'README.md')
    git(dir, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'commit.gpgsign=false',
        'commit', '-q', '-m', 'init')
  end

  def publish_seed(inputs: { 'root' => source_checkout })
    payload = source_index.join('payloads', 'gen-1')
    FileUtils.mkdir_p(payload)
    File.write(payload.join('manifest.json'), JSON.generate(manifest))
    File.write(payload.join('dependency_graph.json'), JSON.generate('nodes' => {}, 'edges' => {}))
    File.write(payload.join('source_inputs.json'), JSON.generate(inputs))
    File.write(source_index.join('generation.json'),
               JSON.generate('number' => 1, 'token' => 'abc', 'updated_at' => '2026-01-01T00:00:00Z',
                             'reason' => 'full', 'payload' => 'payloads/gen-1'))
  end

  def rewrite_manifest(changes)
    path = source_index.join('payloads', 'gen-1', 'manifest.json')
    File.write(path, JSON.generate(manifest.merge(changes)))
  end

  def verify
    described_class.new(source: source_index, root: Pathname.new(worktree)).call
  end

  it 'refuses a seed written by another Woods version' do
    rewrite_manifest('woods_version' => '1.0.0')

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /written by Woods 1\.0\.0/)
  end

  it 'refuses a seed that records no commit' do
    rewrite_manifest('git_sha' => 'unknown')

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /records no commit/)
  end

  it 'refuses a commit the worktree repository does not have' do
    rewrite_manifest('git_sha' => 'a' * 40)

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /does not have the seed's commit/)
  end

  it 'refuses when a gitignored boot input differs from the seed' do
    sha = head(worktree)
    rewrite_manifest('git_sha' => sha, 'gemfile_lock_sha' => Digest::SHA256.hexdigest('locked'))
    File.write(File.join(worktree, 'Gemfile.lock'), 'a different lock')

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /gemfile_lock differs/)
  end

  it 'refuses when the schema differs from the seed' do
    sha = head(worktree)
    rewrite_manifest('git_sha' => sha, 'schema_sha' => Digest::SHA256.hexdigest('old schema'))
    FileUtils.mkdir_p(File.join(worktree, 'db'))
    File.write(File.join(worktree, 'db/schema.rb'), 'new schema')

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /schema differs/)
  end

  it 'refuses a seed that does not record its source checkout' do
    rewrite_manifest('git_sha' => head(worktree))
    publish_seed(inputs: {})
    rewrite_manifest('git_sha' => head(worktree))

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /does not record its source checkout/)
  end

  it 'refuses a source checkout this process cannot reach' do
    sha = head(worktree)
    publish_seed(inputs: { 'root' => File.join(base, 'gone') })
    rewrite_manifest('git_sha' => sha)

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /not reachable/)
  end

  it 'refuses a source checkout that moved off the indexed commit' do
    rewrite_manifest('git_sha' => head(worktree))

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /seed's checkout is at/)
  end

  it 'refuses a source checkout with uncommitted changes' do
    sha = head(source_checkout)
    git(worktree, 'fetch', '-q', source_checkout)
    rewrite_manifest('git_sha' => sha)
    File.write(File.join(source_checkout, 'stray.rb'), "x = 1\n")

    expect { verify }.to raise_error(Woods::WorktreeSeed::Unverifiable, /uncommitted changes/)
  end
end
