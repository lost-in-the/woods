# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'

# Capture and compare the four jobs used by ci-local. Reference artifacts are
# inputs supplied by the caller; this code does not authenticate their origin.
# Keep the explicit record checks and subprocess boundary together.
# rubocop:disable Metrics/ModuleLength, Metrics/MethodLength, Metrics/AbcSize
# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
module CiLocalEnvironment
  ROOT = File.expand_path('..', __dir__)
  ROWS = {
    'lint' => { ruby: '3.3', gemfile: 'Gemfile', job: 'lint', puma: nil, sqlite: nil },
    'unit' => { ruby: '3.3', gemfile: 'Gemfile', job: 'test-required', puma: '~> 8.0', sqlite: nil },
    'rails-4.0-8.1' => { ruby: '4.0', gemfile: 'gemfiles/rails_8.1.gemfile', job: 'rails-matrix',
                         puma: nil, sqlite: nil },
    'rails-3.0-6.0' => { ruby: '3.0', gemfile: 'gemfiles/rails_6.0.gemfile', job: 'rails-matrix',
                         puma: nil, sqlite: '~> 1.4' }
  }.freeze
  COMMAND_INPUTS = %w[.github/workflows/ci.yml script/ci-local script/ci_local_environment.rb
                      script/parallel-rspec script/parallel_rspec.rb script/parallel_rspec_timings.json
                      bin/rake bin/rubocop bin/rspec .rspec spec/spec_helper.rb
                      spec/ci/ci_local_environment_spec.rb].freeze
  RUNTIME_KEYS = %w[ruby_engine ruby_version ruby_revision ruby_platform gem_platform rubygems].freeze
  MATCH_KEYS = (RUNTIME_KEYS + %w[bundler lock_sha256 gems dependency_inputs]).freeze
  class Error < StandardError; end

  def self.digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def self.dependencies(row)
    (%w[Gemfile woods.gemspec lib/woods/version.rb] + [ROWS.fetch(row)[:gemfile]]).uniq
  end

  def self.hashes(root, paths)
    paths.to_h { |path| [path, digest(File.join(root, path))] }
  end

  # Reject redirected repository selection without changing any Git config.
  def self.git(root, *args)
    env = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR].to_h { |key| [key, nil] }
    out, err, status = Open3.capture3(env, 'git', '-C', root, *args)
    raise Error, "git #{args.first} failed in #{root}: #{err.strip}" unless status.success?

    out
  end

  def self.source_sha(root, hosted: false)
    top = git(root, 'rev-parse', '--show-toplevel').strip
    raise Error, "not the expected checkout root: #{root}" unless File.realpath(top) == File.realpath(root)

    sha = git(root, 'rev-parse', 'HEAD').strip
    entries = git(root, 'status', '--porcelain=v1', '--untracked-files=all', '-z').split("\0")
    # setup-ruby installs exactly here after checkout. Only untracked files in
    # that directory are exempt; tracked modifications are always refused.
    entries.reject! { |entry| hosted && entry.start_with?('?? vendor/bundle/') }
    raise Error, "source has tracked or untracked changes: #{root}" unless entries.empty?
    raise Error, "invalid source SHA: #{sha}" unless hex?(sha, [40, 64])

    sha
  end

  def self.os_identity
    fields = File.readlines('/etc/os-release', chomp: true).filter_map do |line|
      key, value = line.split('=', 2)
      [key, value.to_s.delete_prefix('"').delete_suffix('"')] if %w[ID VERSION_ID].include?(key)
    end.to_h
    { 'ID' => fields.fetch('ID', 'unknown'), 'VERSION_ID' => fields.fetch('VERSION_ID', 'unknown') }
  rescue Errno::ENOENT
    { 'ID' => 'unknown', 'VERSION_ID' => 'unknown' }
  end

  def self.runtime
    { 'ruby_engine' => RUBY_ENGINE, 'ruby_version' => RUBY_VERSION, 'ruby_revision' => RUBY_REVISION.to_s,
      'ruby_description' => RUBY_DESCRIPTION, 'ruby_path' => Gem.ruby, 'ruby_sha256' => digest(Gem.ruby),
      'ruby_platform' => RUBY_PLATFORM, 'gem_platform' => Gem::Platform.local.to_s,
      'rubygems' => Gem::VERSION, 'os' => os_identity }
  end

  # Called inside bundle exec, so Bundler reports its actual effective lock and
  # its materialized, platform-selected specs rather than guessed filenames.
  def self.observe
    require 'bundler'
    specs = Bundler.definition.specs
    woods = specs.find { |spec| spec.name == 'woods' }
    raise Error, 'Woods is absent from the active bundle' unless woods

    path = File.realpath(woods.full_gem_path)
    executable = File.realpath(Gem.bin_path('woods', 'woods-watch'))
    require 'woods/version'
    version_feature = $LOADED_FEATURES.find { |feature| feature.end_with?('/woods/version.rb') }
    raise Error, 'Woods version was not loaded' unless version_feature

    gemfile = File.realpath(Bundler.default_gemfile.to_s)
    lock = File.realpath(Bundler.default_lockfile.to_s)
    inputs = %w[WOODS_PUMA_REQ WOODS_SQLITE3_REQ].to_h { |key| [key, ENV.fetch(key, nil)] }
    runtime.merge('bundler' => Bundler::VERSION, 'gemfile_path' => gemfile,
                  'lock_path' => lock, 'lock_sha256' => digest(lock),
                  'gems' => specs.map { |spec| [spec.name, spec.version.to_s, spec.platform.to_s] }.sort,
                  'dependency_inputs' => inputs, 'woods_path' => path, 'woods_executable' => executable,
                  'woods_version_file' => File.realpath(version_feature))
  end

  def self.verify_source!(identity, source, gemfile)
    expected_root = File.realpath(source)
    expected_gemfile = File.realpath(gemfile)
    expected_lock = "#{expected_gemfile}.lock"
    expected_exe = File.realpath(File.join(source, 'exe/woods-watch'))
    expected_version = File.realpath(File.join(source, 'lib/woods/version.rb'))
    valid = [expected_gemfile, expected_exe, expected_version].all? { |path| path.start_with?("#{expected_root}/") } &&
            identity['woods_path'] == expected_root && identity['woods_executable'] == expected_exe &&
            identity['woods_version_file'] == expected_version && identity['gemfile_path'] == expected_gemfile &&
            identity['lock_path'] == expected_lock
    raise Error, "active bundle is not bound to #{source} and #{expected_lock}" unless valid
  end

  def self.rspec_argv(source, files, seed = nil)
    argv = %w[bundle exec ruby bin/rspec] + ['--options', File.join(source, '.rspec')] + files
    argv += ['--seed', seed.to_s] if seed
    argv
  end

  def self.profile(full, hosted_pr, ruby)
    full || (hosted_pr && ruby == '3.0') ? ['60', '1,2,3'] : %w[8 1]
  end

  def self.expected_inputs(row)
    config = ROWS.fetch(row)
    { 'WOODS_PUMA_REQ' => config[:puma], 'WOODS_SQLITE3_REQ' => config[:sqlite] }
  end

  def self.capture(row, directory)
    config = ROWS.fetch(row) { raise Error, "unknown row #{row.inspect}" }
    unless ENV['GITHUB_ACTIONS'] == 'true' && ENV['GITHUB_REPOSITORY'] == 'lost-in-the/woods' &&
           ENV['GITHUB_JOB'] == config[:job]
      raise Error, 'capture is only valid in the named GitHub repository and job'
    end

    sha = source_sha(ROOT, hosted: true)
    raise Error, 'checked-out source differs from GITHUB_SHA' unless sha == ENV['GITHUB_SHA']

    gemfile = File.join(ROOT, config[:gemfile])
    selected_gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', gemfile), ROOT)
    raise Error, 'wrong Gemfile for capture' unless selected_gemfile == gemfile

    identity = observe
    verify_source!(identity, ROOT, gemfile)
    raise Error, 'wrong dependency inputs for capture' unless identity['dependency_inputs'] == expected_inputs(row)
    raise Error, 'wrong Ruby line for capture' unless identity['ruby_version'].start_with?("#{config[:ruby]}.")

    run, attempt, event = ENV.values_at('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_EVENT_NAME')
    unless positive?(run) && positive?(attempt) && %w[pull_request push].include?(event)
      raise Error, 'invalid hosted run identity'
    end

    image = ENV.values_at('ImageOS', 'ImageVersion')
    raise Error, 'hosted runner image identity is missing' unless image.all? { |value| nonempty?(value) }

    depths = row.start_with?('rails-') ? ENV.values_at('WOODS_CI_REFERENCE_OPS', 'WOODS_CI_REFERENCE_SEEDS') : nil
    record = { 'schema' => 2, 'repository' => 'lost-in-the/woods', 'run_id' => run, 'attempt' => attempt,
               'event' => event, 'reference_source_sha' => sha, 'row' => row, 'job' => config[:job],
               'gemfile' => config[:gemfile], 'dependency_hashes' => hashes(ROOT, dependencies(row)),
               'command_hashes' => hashes(ROOT, COMMAND_INPUTS), 'identity' => identity,
               'image' => { 'ImageOS' => image[0], 'ImageVersion' => image[1] }, 'profile' => depths }
    validate_record!(record, row, run, attempt, identity['lock_sha256'])
    validate_lock!(identity.fetch('lock_path'), record)
    FileUtils.mkdir_p(directory)
    FileUtils.cp(identity.fetch('lock_path'), File.join(directory, 'Gemfile.lock'))
    unless digest(File.join(directory, 'Gemfile.lock')) == identity['lock_sha256']
      raise Error, 'lock changed during capture'
    end

    File.write(File.join(directory, 'environment.json'), "#{JSON.pretty_generate(record)}\n")
  end

  def self.nonempty?(value)
    value.is_a?(String) && !value.empty?
  end

  def self.positive?(value)
    value.is_a?(String) && value.match?(/\A[1-9]\d*\z/)
  end

  def self.hex?(value, lengths = [64])
    value.is_a?(String) && lengths.include?(value.length) && value.match?(/\A[0-9a-f]+\z/)
  end

  def self.valid_hashes?(value, paths)
    value.is_a?(Hash) && value.keys.sort == paths.sort && value.values.all? { |hash| hex?(hash) }
  end

  def self.valid_identity?(identity, row, lock_sha)
    return false unless identity.is_a?(Hash)

    config = ROWS.fetch(row)
    strings = RUNTIME_KEYS + %w[bundler ruby_description ruby_path ruby_sha256 gemfile_path lock_path lock_sha256
                                woods_path woods_executable woods_version_file]
    return false unless strings.all? { |key| nonempty?(identity[key]) }
    return false unless identity['ruby_engine'] == 'ruby' &&
                        identity['ruby_version'].match?(/\A#{Regexp.escape(config[:ruby])}\.\d+\z/)
    return false unless identity['bundler'].match?(/\A\d+\.\d+\.\d+\z/) &&
                        identity['rubygems'].match?(/\A\d+\.\d+\.\d+\z/)
    return false if config[:ruby] == '3.0' && Gem::Version.new(identity['bundler']) >= Gem::Version.new('4')
    return false unless hex?(identity['ruby_revision'], (1..64).to_a)
    return false unless hex?(identity['ruby_sha256']) && hex?(identity['lock_sha256']) &&
                        identity['lock_sha256'] == lock_sha
    return false unless identity['dependency_inputs'] == expected_inputs(row)

    path_keys = %w[ruby_path woods_path gemfile_path lock_path woods_executable woods_version_file]
    valid_paths = path_keys.all? do |key|
      identity[key].start_with?('/') && File.expand_path(identity[key]) == identity[key]
    end
    return false unless valid_paths

    source = identity['woods_path']
    return false unless identity['gemfile_path'] == File.join(source, config[:gemfile]) &&
                        identity['lock_path'] == "#{identity['gemfile_path']}.lock" &&
                        identity['woods_executable'] == File.join(source, 'exe/woods-watch') &&
                        identity['woods_version_file'] == File.join(source, 'lib/woods/version.rb')

    os = identity['os']
    gems = identity['gems']
    valid_os = os.is_a?(Hash) && os.keys.sort == %w[ID VERSION_ID] && os.values.all? { |value| nonempty?(value) }
    return false unless valid_os && gems.is_a?(Array) && !gems.empty?
    return false unless gems.all? { |tuple| tuple.is_a?(Array) && tuple.length == 3 && tuple.all? { |v| nonempty?(v) } }

    valid_gems = gems.all? do |name, version, platform|
      name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/) && Gem::Version.correct?(version) &&
        platform.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
    end
    return false unless valid_gems

    names = gems.map(&:first)
    names.uniq.length == names.length && names.include?('woods') && gems == gems.sort
  end

  def self.validate_lock!(path, record)
    unless locked_bundler(path) == record.dig('identity', 'bundler') &&
           digest(path) == record.dig('identity', 'lock_sha256')
      raise Error, "lock bytes or BUNDLED WITH contradict the reference: #{path}"
    end
  end

  def self.locked_bundler(path)
    return unless File.file?(path)

    version = File.binread(path)[/^BUNDLED WITH\r?\n[ \t]+([^\s]+)[ \t]*\r?\n?\z/, 1]
    raise Error, "missing or invalid BUNDLED WITH: #{path}" unless version&.match?(/\A\d+\.\d+\.\d+\z/)

    version
  end

  def self.validate_record!(record, row, run, attempt, lock_sha)
    raise Error, "reference for #{row} must be a JSON object" unless record.is_a?(Hash)

    config = ROWS.fetch(row)
    fixed = { 'schema' => 2, 'repository' => 'lost-in-the/woods', 'row' => row,
              'job' => config[:job], 'gemfile' => config[:gemfile], 'run_id' => run, 'attempt' => attempt }
    image = record['image']
    event = record['event']
    expected_profile = profile(event == 'push', event == 'pull_request', config[:ruby]) if row.start_with?('rails-')
    valid = fixed.all? { |key, value| record[key] == value } && positive?(run) && positive?(attempt) &&
            %w[pull_request push].include?(event) && hex?(record['reference_source_sha'], [40, 64]) &&
            record.key?('profile') && record['profile'] == expected_profile &&
            image.is_a?(Hash) && %w[ImageOS ImageVersion].all? { |key| nonempty?(image[key]) } &&
            valid_hashes?(record['dependency_hashes'], dependencies(row)) &&
            valid_hashes?(record['command_hashes'], COMMAND_INPUTS) &&
            valid_identity?(record['identity'], row, lock_sha)
    raise Error, "incomplete or contradictory reference for #{row}" unless valid
  end

  # Validate every row, dependency input and common run identity before setup.
  def self.references(directory, rows, run, attempt, candidate_root)
    raise Error, 'no selected reference rows' if rows.empty?

    candidate_sha = source_sha(candidate_root)
    records = rows.to_h do |row|
      path = File.join(directory, row)
      record = JSON.parse(File.read(File.join(path, 'environment.json')))
      lock = File.join(path, 'Gemfile.lock')
      validate_record!(record, row, run, attempt, digest(lock))
      validate_lock!(lock, record)
      unless record['dependency_hashes'] == hashes(candidate_root, dependencies(row))
        raise Error, "dependency-defining source inputs differ for #{row}"
      end

      [row, record.merge('reference_lock' => File.expand_path(lock), 'candidate_source_sha' => candidate_sha)]
    end
    origins = records.values.map { |record| record.values_at('event', 'reference_source_sha') }.uniq
    raise Error, 'references must come from one run, attempt, event and source' unless origins.one?

    commands = records.values.map { |record| record.fetch('command_hashes') }.uniq
    raise Error, 'reference command input hashes disagree between rows' unless commands.one?

    [candidate_sha, records]
  rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => e
    raise Error, "missing or invalid hosted reference: #{e.message}"
  end

  def self.report_status(expected, actual)
    unknown = [expected, actual].any? do |value|
      value.nil? || value == 'unknown' ||
        (value.is_a?(Hash) && value.values.any? { |entry| !nonempty?(entry) || entry == 'unknown' })
    end
    return 'unknown' if unknown

    expected == actual ? 'match' : 'different'
  end

  def self.differences(expected, actual, keys = MATCH_KEYS)
    keys.reject { |key| expected[key] == actual[key] }
  end

  # These values affect subprocesses only, including Bundler's saved original
  # environment. Do not modify global mise, Bundler, Git or shell settings.
  def self.child_env
    keys = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_ORIG_|GEM_|WOODS_RUN_|WOODS_DIFF_)/)
    keys += %w[BUNDLE_LOCKFILE BUNDLER_VERSION BUNDLER_SETUP GEMRC RB_USER_INSTALL RUBYOPT RUBYLIB
               SPEC_OPTS RSPEC_OPTS WOODS_PUMA_REQ WOODS_SQLITE3_REQ WOODS_PARALLEL_PROCESSES COVERAGE]
    keys.uniq.to_h { |key| [key, nil] }.merge('BUNDLE_IGNORE_CONFIG' => 'true', 'GEMRC' => File::NULL)
  end

  def self.mise_env(bundle_root)
    base = File.expand_path(ENV.fetch('WOODS_CI_LOCAL_MISE_ROOT', File.join(bundle_root, 'mise')))
    { 'MISE_DATA_DIR' => File.join(base, 'data'), 'MISE_CACHE_DIR' => File.join(base, 'cache'),
      'MISE_STATE_DIR' => File.join(base, 'state'), 'MISE_CONFIG_DIR' => File.join(base, 'config') }
  end

  def self.bundle_env(source, row, bundle_root, record: nil, candidate_root: ROOT)
    config = ROWS.fetch(row)
    home = if record
             File.join(profile_dir(bundle_root, candidate_root, record, row), 'gems')
           else
             label = [config[:ruby], config[:gemfile] == 'Gemfile' ? nil : File.basename(config[:gemfile], '.gemfile')]
             File.join(bundle_root, label.compact.join('-'))
           end
    env = child_env.merge('GEM_HOME' => home, 'GEM_PATH' => home,
                          'BUNDLE_GEMFILE' => File.join(source, config[:gemfile]), 'BUNDLE_FROZEN' => 'true',
                          'WOODS_PUMA_REQ' => record ? config[:puma] : nil)
    env.merge!(mise_env(bundle_root)) if record
    env['CI'] = 'true' if record
    env
  end

  def self.profile_dir(bundle_root, candidate_root, record, row)
    identity = Digest::SHA256.hexdigest(File.realpath(candidate_root))
    File.join(bundle_root, 'reference', identity, record.fetch('candidate_source_sha'),
              "#{record.fetch('run_id')}-#{record.fetch('attempt')}", row)
  end

  def self.binding(candidate_root, record, row)
    { 'candidate_root' => File.realpath(candidate_root), 'candidate_source_sha' => record.fetch('candidate_source_sha'),
      'reference_source_sha' => record.fetch('reference_source_sha'),
      'lock_sha256' => record.dig('identity', 'lock_sha256'),
      'run_id' => record.fetch('run_id'), 'attempt' => record.fetch('attempt'), 'row' => row }
  end

  def self.verify_checkout!(candidate_root, record, row, bundle_root, require_lock: true)
    expected = binding(candidate_root, record, row)
    directory = profile_dir(bundle_root, candidate_root, record, row)
    source = File.join(directory, 'source')
    stored = JSON.parse(File.read(File.join(directory, 'binding.json')))
    raise Error, "wrong candidate binding for #{row}" unless stored == expected
    unless source_sha(candidate_root) == expected['candidate_source_sha']
      raise Error, 'candidate source changed since preflight'
    end
    raise Error, "profile Git directory is not local for #{row}" unless File.directory?(File.join(source, '.git'))
    unless source_sha(source) == expected['candidate_source_sha']
      raise Error, "wrong or dirty source checkout for #{row}"
    end

    actual = File.realpath(source)
    raise Error, 'profile source is redirected' unless actual == File.join(File.realpath(directory), 'source')
    raise Error, 'candidate and profile checkout are the same directory' if actual == File.realpath(candidate_root)

    if require_lock
      lock = "#{File.join(source, ROWS.fetch(row)[:gemfile])}.lock"
      raise Error, "reference lock is redirected for #{row}" if File.symlink?(lock)
      raise Error, "reference lock changed for #{row}" unless digest(lock) == record.dig('identity', 'lock_sha256')
    end

    source
  rescue Errno::ENOENT, JSON::ParserError => e
    raise Error, "reference checkout for #{row} is missing or invalid: #{e.message}; run --setup"
  end

  def self.prepare_checkout(candidate_root, record, row, bundle_root)
    directory = profile_dir(bundle_root, candidate_root, record, row)
    source = File.join(directory, 'source')
    unless File.exist?(directory)
      FileUtils.mkdir_p(File.dirname(directory))
      FileUtils.mkdir(directory)
      env = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR].to_h { |key| [key, nil] }
      ok = system(env, 'git', 'clone', '--local', '--no-hardlinks', '--no-checkout', '--', candidate_root, source)
      raise Error, "clone failed for #{row}" unless ok

      ok = system(env, 'git', '-C', source, 'checkout', '--detach', record.fetch('candidate_source_sha'))
      raise Error, "checkout failed for #{row}" unless ok

      File.write(File.join(directory, 'binding.json'), JSON.generate(binding(candidate_root, record, row)))
    end
    source = verify_checkout!(candidate_root, record, row, bundle_root, require_lock: false)
    destination = "#{File.join(source, ROWS.fetch(row)[:gemfile])}.lock"
    raise Error, "refusing redirected lock #{destination}" if File.symlink?(destination)

    if File.exist?(destination)
      unless digest(destination) == record.dig('identity', 'lock_sha256')
        raise Error, "refusing to replace different lock #{destination}"
      end
    else
      validate_lock!(record.fetch('reference_lock'), record)
      FileUtils.cp(record.fetch('reference_lock'), destination)
    end
    verify_checkout!(candidate_root, record, row, bundle_root)
  end

  def self.command(env, root, *argv)
    out, err, status = Open3.capture3(env, *argv, chdir: root)
    raise Error, "#{argv.first} failed: #{err.strip} #{out.strip}" unless status.success?

    out
  end

  # mise selects the installation, then absolute Ruby/bundle paths and the
  # controlled environment cross the execution boundary. mise exec cannot
  # reintroduce project/global env options after we have cleared them.
  def self.ruby_prefix(source, version, env)
    path = command(env, source, 'mise', 'where', "ruby@#{version}").strip
    raise Error, "invalid mise installation path for ruby@#{version}" unless path.start_with?('/')

    prefix = File.realpath(path)
    %w[ruby bundle gem].each do |name|
      raise Error, "ruby@#{version} is missing bin/#{name}" unless File.file?(File.join(prefix, 'bin', name))
    end
    if env['MISE_DATA_DIR']
      owned = File.join(File.realpath(env.fetch('MISE_DATA_DIR')), 'installs', 'ruby')
      raise Error, 'reference Ruby must be in the task-owned mise data directory' unless prefix.start_with?("#{owned}/")
    end
    prefix
  rescue Error => e
    raise Error, "#{e.message}; install the required ruby@#{version} in the selected mise data directory"
  end

  def self.ruby_env(prefix, env)
    paths = [File.join(prefix, 'bin'), File.join(env.fetch('GEM_HOME'), 'bin'), env.fetch('PATH', ENV.fetch('PATH'))]
    env.merge('PATH' => paths.join(File::PATH_SEPARATOR))
  end

  def self.bundle_command(prefix, bundler = nil)
    argv = [File.join(prefix, 'bin', 'ruby'), File.join(prefix, 'bin', 'bundle')]
    argv << "_#{bundler}_" if bundler
    argv
  end

  def self.probe(source, prefix, env, bundler = nil, runtime_only: false)
    argv = [File.join(prefix, 'bin', 'ruby'), File.join(source, 'script/ci_local_environment.rb'),
            runtime_only ? 'runtime' : 'probe']
    unless runtime_only
      bundler ||= locked_bundler("#{env.fetch('BUNDLE_GEMFILE')}.lock")
      argv = bundle_command(prefix, bundler) + ['exec', *argv]
    end
    JSON.parse(command(ruby_env(prefix, env), source, *argv))
  rescue JSON::ParserError => e
    raise Error, "cannot read runtime identity: #{e.message}"
  end

  def self.provision(candidate_root, record, row, bundle_root)
    source = prepare_checkout(candidate_root, record, row, bundle_root)
    env = bundle_env(source, row, bundle_root, record: record, candidate_root: candidate_root)
    ruby = record.dig('identity', 'ruby_version')
    bundler = record.dig('identity', 'bundler')
    puts "Task mise directories: #{mise_env(bundle_root).inspect}"
    unless system(env, 'mise', 'where', "ruby@#{ruby}", out: File::NULL, err: File::NULL)
      puts "$ mise install ruby@#{ruby} (task-owned mise directories)"
      raise Error, "cannot install ruby@#{ruby}" unless system(env, 'mise', 'install', "ruby@#{ruby}")
    end
    prefix = ruby_prefix(source, ruby, env)
    env = ruby_env(prefix, env)
    observed = probe(source, prefix, env, nil, runtime_only: true)
    puts "Runtime before gem installation: #{JSON.generate(observed)}"
    drift = differences(record.fetch('identity'), observed, RUNTIME_KEYS)
    raise Error, "#{row} Ruby/RubyGems/platform drift: #{drift.join(', ')}" unless drift.empty?

    gem_env = env.merge('BUNDLE_GEMFILE' => nil, 'BUNDLE_FROZEN' => nil)
    gem_command = [File.join(prefix, 'bin', 'ruby'), File.join(prefix, 'bin', 'gem'), 'install', 'bundler',
                   '--version', bundler, '--no-document']
    puts "$ #{JSON.generate(gem_command)} (GEM_HOME=#{env.fetch('GEM_HOME')})"
    ok = system(gem_env, *gem_command)
    raise Error, "cannot install Bundler #{bundler}" unless ok

    install = bundle_command(prefix, bundler) + ['install']
    puts "$ #{JSON.generate(install)} (frozen, cwd=#{source})"
    ok = system(env, *install, chdir: source)
    raise Error, "bundle install failed for #{row}" unless ok

    lock = "#{env.fetch('BUNDLE_GEMFILE')}.lock"
    raise Error, "lock changed during setup for #{row}" unless digest(lock) == record.dig('identity', 'lock_sha256')

    source
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
# rubocop:enable Metrics/ModuleLength, Metrics/MethodLength, Metrics/AbcSize

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV.shift
    when 'runtime' then puts JSON.generate(CiLocalEnvironment.runtime)
    when 'probe' then puts JSON.generate(CiLocalEnvironment.observe)
    when 'capture' then CiLocalEnvironment.capture(ARGV.fetch(0), ARGV.fetch(1))
    else abort 'usage: ruby script/ci_local_environment.rb capture ROW DIRECTORY'
    end
  rescue CiLocalEnvironment::Error, KeyError, Errno::ENOENT => e
    warn e.message
    exit 1
  end
end
