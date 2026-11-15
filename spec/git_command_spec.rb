# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods/git_command'

RSpec.describe Woods::GitCommand do
  describe '.argv' do
    it 'passes --no-optional-locks as a global option before the subcommand' do
      expect(described_class.argv('/app', 'status', '--porcelain', env: {}))
        .to eq(%w[git --no-optional-locks -C /app status --porcelain])
    end

    it 'passes --no-optional-locks when WOODS_GIT_DIR selects the git directory' do
      expect(described_class.argv('/app', 'log', env: { 'WOODS_GIT_DIR' => '/git' }))
        .to eq(%w[git --no-optional-locks --git-dir /git --work-tree /app -C /app log])
    end

    it 'keeps caller global options ahead of the subcommand' do
      expect(described_class.argv('/app', '-c', 'core.quotePath=false', 'ls-files', env: {}))
        .to eq(%w[git --no-optional-locks -C /app -c core.quotePath=false ls-files])
    end
  end

  # A tracked file whose stat data changed while its content did not makes a
  # plain `git status` refresh the index and write it back under index.lock.
  # That optional write is the lock a developer's `git checkout` collides with.
  describe 'against a checkout whose index has stale stat data' do
    around do |example|
      Dir.mktmpdir('woods-git-command') do |dir|
        @root = dir
        example.run
      end
    end

    def git(*args)
      _out, err, status = Open3.capture3('git', '-C', @root, *args)
      raise err unless status.success?
    end

    def index_digest
      Digest::SHA256.file(File.join(@root, '.git', 'index')).hexdigest
    end

    before do
      File.write(File.join(@root, 'post.rb'), "class Post; end\n")
      git('init', '-q')
      git('add', '.')
      git('-c', 'user.name=Spec', '-c', 'user.email=spec@example.invalid', 'commit', '-qm', 'init')
      past = Time.now - 86_400
      File.utime(past, past, File.join(@root, 'post.rb'))
    end

    it 'answers status without rewriting .git/index' do
      before = index_digest

      _out, _err, status = Open3.capture3(*described_class.argv(@root, 'status', '--porcelain', env: {}))

      expect(status).to be_success
      expect(index_digest).to eq(before)
    end

    it 'is a fixture plain git status does rewrite, so the example above can fail' do
      before = index_digest

      Open3.capture3('git', '-C', @root, 'status', '--porcelain')

      expect(index_digest).not_to eq(before)
    end
  end
end
