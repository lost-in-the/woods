# frozen_string_literal: true

require 'digest'
require 'open3'
require 'set'
require_relative 'git_command'

module Woods
  # The files Git reads to say whether a path is tracked or ignored,
  # fingerprinted without spawning git. {GitSourceAnswers} keeps
  # Git's answers for as long as the fingerprint holds, so an incremental
  # cycle that changed none of them does no git work (#721).
  #
  # The fingerprint covers:
  # * the index, by its stat and its trailing checksum (every add, removal,
  #   commit or checkout rewrites it);
  # * the `.gitignore` of every directory from the root down to each path;
  # * the repository's exclude file (`info/exclude`);
  # * the repository's, the global and the system Git configuration, and the
  #   global excludes file they name (`core.excludesFile`, or Git's default);
  # * the environment variables that select any of these, and the paths.
  #
  # Not covered: a file a configuration includes (`include.path`), and a
  # system configuration outside `/etc/gitconfig` without
  # `GIT_CONFIG_SYSTEM`. An edit there is seen with the next index change.
  class GitIgnoreInputs
    # Environment variables, besides every `GIT_*` one, that move Git's files.
    ENV_KEYS = ['HOME', 'XDG_CONFIG_HOME', GitCommand::OVERRIDE_KEY].freeze

    # Bytes read from the end of the index: its SHA-1 or SHA-256 checksum.
    INDEX_TRAILER_BYTES = 32

    # Ask Git once where its index, exclude file and configuration live.
    #
    # @param root [String] application root
    # @return [GitIgnoreInputs, nil] nil when Git cannot name them
    def self.resolve(root)
      out, _err, status = Open3.capture3(*GitCommand.argv(root, 'rev-parse', '--git-path', 'index',
                                                          '--git-path', 'info/exclude', '--git-path', 'config',
                                                          '--git-path', 'config.worktree'))
      return unless status.success?

      index, exclude, *configs = out.lines(chomp: true).map { |line| File.expand_path(line, root) }
      new(root: root, index: index, exclude: exclude, configs: configs) if configs.size == 2
    rescue SystemCallError
      nil
    end

    # @param root [String] application root
    # @param index [String] absolute path of the index
    # @param exclude [String] absolute path of the repository's exclude file
    # @param configs [Array<String>] absolute paths of the repository's configuration files
    def initialize(root:, index:, exclude:, configs:)
      @root = root
      @index = index
      @exclude = exclude
      @configs = configs
    end

    # A digest of everything Git's answers for +relatives+ depend on. Spawns
    # git only to read `core.excludesFile` again after a configuration change.
    #
    # @param relatives [Array<String>] root-relative paths, without `.` or `..` segments
    # @return [String] hex SHA256
    def fingerprint(relatives)
      config = contents_digest(config_files)
      digest = Digest::SHA256.new
      digest << environment << "\0" << index_stamp << "\0" << config << "\0"
      digest << contents_digest([@exclude, excludes_file(config), *ignore_files(relatives)])
      relatives.each { |relative| digest << relative << "\0" }
      digest.hexdigest
    end

    private

    def environment
      ENV.select { |key, _| key.start_with?('GIT_') || ENV_KEYS.include?(key) }.sort.inspect
    end

    def index_stamp
      stat = File.stat(@index)
      trailer = File.open(@index, 'rb') do |file|
        file.seek([stat.size - INDEX_TRAILER_BYTES, 0].max)
        file.read
      end
      [stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r, trailer.unpack1('H*')].join(':')
    rescue SystemCallError
      'absent'
    end

    def contents_digest(paths)
      paths.each_with_object(Digest::SHA256.new) do |path, digest|
        digest << path.to_s << "\0" << contents(path) << "\0"
      end.hexdigest
    end

    def contents(path)
      return "\1absent" if path.nil?

      File.binread(path)
    rescue SystemCallError, IOError
      "\1absent"
    end

    def config_files
      [*@configs, *global_configs, system_config]
    end

    def global_configs
      return [ENV['GIT_CONFIG_GLOBAL']] if ENV['GIT_CONFIG_GLOBAL']

      [home && File.join(home, '.gitconfig'), xdg_file('config')]
    end

    def system_config
      return if ENV['GIT_CONFIG_NOSYSTEM']

      ENV['GIT_CONFIG_SYSTEM'] || '/etc/gitconfig'
    end

    # Git's own reading of `core.excludesFile`, again only when a
    # configuration file changed since the last reading.
    def excludes_file(config)
      return @excludes_file if @excludes_config == config

      out, _err, status = Open3.capture3(*GitCommand.argv(@root, 'config', '--path', '--get', 'core.excludesFile'))
      @excludes_config = config
      @excludes_file = status.success? ? File.expand_path(out.chomp, @root) : xdg_file('ignore')
    rescue SystemCallError
      @excludes_config = nil
      @excludes_file = xdg_file('ignore')
    end

    def xdg_file(name)
      base = ENV['XDG_CONFIG_HOME'].to_s
      base = home && File.join(home, '.config') if base.empty?
      base && File.join(base, 'git', name)
    end

    def home
      Dir.home
    rescue ArgumentError
      nil
    end

    def ignore_files(relatives)
      directories = relatives.each_with_object(Set['.']) do |relative, found|
        directory = File.dirname(relative)
        until directory == '.'
          break unless found.add?(directory)

          directory = File.dirname(directory)
        end
      end
      directories.sort.map { |directory| File.join(@root, directory, '.gitignore') }
    end
  end
end
