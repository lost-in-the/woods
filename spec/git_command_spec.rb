# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods/git_command'

RSpec.describe Woods::GitCommand do
  describe '.argv' do
    # Git before 2.15 rejects an unknown global option (`--no-optional-locks`)
    # and fails the whole command; it ignores an unknown environment variable.
    it 'puts no global option ahead of -C that an older Git would reject' do
      expect(described_class.argv('/app', 'status', '--porcelain', env: {}))
        .to eq(%w[git -C /app status --porcelain])
    end

    it 'adds only the selected git directory when WOODS_GIT_DIR is set' do
      expect(described_class.argv('/app', 'log', env: { 'WOODS_GIT_DIR' => '/git' }))
        .to eq(%w[git --git-dir /git --work-tree /app -C /app log])
    end
  end

  describe 'CHILD_ENV' do
    it 'turns off optional locks through the environment' do
      expect(described_class::CHILD_ENV).to eq('GIT_OPTIONAL_LOCKS' => '0')
    end

    # Every Woods git child process gets the environment, so a status or diff
    # added later cannot take the index lock by omission.
    it 'is passed by every git spawn in lib/' do
      root = File.expand_path('..', __dir__)
      spawn = /Open3\.\w+\(\s*(?<first>[^,\n]*)/
      git_spawns = Dir.glob(File.join(root, 'lib/**/*.rb')).flat_map do |path|
        source = File.read(path, encoding: Encoding::UTF_8)
        source.to_enum(:scan, spawn).filter_map do
          match = Regexp.last_match
          following = source[match.begin(0), 240]
          next unless following.match?(/\A[^)]*?(?:GitCommand\.argv|git_argv|\*argv\b)/m)

          ["#{path.delete_prefix("#{root}/")}:#{source[0...match.begin(0)].count("\n") + 1}", match[:first]]
        end
      end

      expect(git_spawns.size).to be >= 20
      missing = git_spawns.reject { |_site, first| first.match?(/\A(?:Woods::)?GitCommand::CHILD_ENV\z/) }
      expect(missing.map(&:first)).to eq([])
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

      _out, _err, status = Open3.capture3(described_class::CHILD_ENV,
                                          *described_class.argv(@root, 'status', '--porcelain', env: {}))

      expect(status).to be_success
      expect(index_digest).to eq(before)
    end

    it 'is a fixture plain git status does rewrite, so the example above can fail' do
      before = index_digest

      # Explicit, so an inherited GIT_OPTIONAL_LOCKS=0 cannot make the control pass.
      Open3.capture3({ 'GIT_OPTIONAL_LOCKS' => '1' }, *described_class.argv(@root, 'status', '--porcelain', env: {}))

      expect(index_digest).not_to eq(before)
    end
  end
end
