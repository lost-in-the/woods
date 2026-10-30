# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'yaml'
require_relative '../../script/ci_local_environment'

# The complete source and subprocess fixtures are intentionally explicit.
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize

# Load the checked-in runner without running its CLI or defining global methods.
module CiLocalRunnerSpecHarness
  source = File.expand_path('../../script/ci-local', __dir__)
  module_eval(File.read(source), source)
end

RSpec.describe CiLocalEnvironment do
  def fixture(root)
    %w[lib/woods exe assets puma gemfiles bin].each { |path| FileUtils.mkdir_p(File.join(root, path)) }
    File.write(File.join(root, '.gitignore'), "Gemfile.lock\ngemfiles/*.gemfile.lock\n.bundle/\ntmp/\n")
    File.write(File.join(root, '.rspec'), "--format progress\n")
    File.write(File.join(root, 'lib/woods/version.rb'), "module Woods; VERSION = '0.0.1'; end\n")
    File.write(File.join(root, 'lib/woods/example.rb'), "ORIGINAL = true\n")
    File.write(File.join(root, 'exe/woods-watch'), "#!/usr/bin/env ruby\nputs 'watch'\n")
    FileUtils.chmod(0o755, File.join(root, 'exe/woods-watch'))
    File.write(File.join(root, 'assets/marker.txt'), 'complete-source-resource')
    File.write(File.join(root, 'woods.gemspec'), <<~GEMSPEC)
      require_relative 'lib/woods/version'
      Gem::Specification.new do |s|
        s.name = 'woods'; s.version = Woods::VERSION; s.summary = 'fixture'; s.authors = ['Fixture']
        s.files = Dir['lib/**/*', 'exe/*', 'assets/*']; s.bindir = 'exe'; s.executables = ['woods-watch']
      end
    GEMSPEC
    File.write(File.join(root, 'puma/puma.gemspec'), <<~GEMSPEC)
      Gem::Specification.new do |s|
        s.name = 'puma'; s.version = '8.0.2'; s.summary = 'fixture'; s.authors = ['Fixture']
      end
    GEMSPEC
    File.write(File.join(root, 'Gemfile'), <<~GEMFILE)
      source 'https://rubygems.org'
      gemspec
      gem 'puma', ENV.fetch('WOODS_PUMA_REQ', '>= 6.0'), path: 'puma'
      gem 'json', '= #{Gem.loaded_specs.fetch('json').version}'
    GEMFILE
    File.write(File.join(root, 'gemfiles/rails_6.0.gemfile'), <<~GEMFILE)
      ENV['WOODS_SQLITE3_REQ'] = '~> 1.4'
      eval_gemfile File.expand_path('../Gemfile', __dir__)
    GEMFILE
    File.write(File.join(root, 'gemfiles/rails_8.1.gemfile'), <<~GEMFILE)
      eval_gemfile File.expand_path('../Gemfile', __dir__)
    GEMFILE
    File.write(File.join(root, 'bin/rspec'), <<~RUBY)
      require 'rubygems'
      require 'bundler/setup'
      load Gem.bin_path('rspec-core', 'rspec')
    RUBY
  end

  def fixture_git(root, *args)
    env = { 'PATH' => ENV.fetch('PATH'), 'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_SYSTEM' => File::NULL,
            'GIT_AUTHOR_NAME' => 'Fixture', 'GIT_AUTHOR_EMAIL' => 'fixture@example.test',
            'GIT_COMMITTER_NAME' => 'Fixture', 'GIT_COMMITTER_EMAIL' => 'fixture@example.test' }
    out, err, status = Open3.capture3(env, 'git', '-C', root, *args, unsetenv_others: true)
    raise "fixture git failed: #{err}" unless status.success?

    out.strip
  end

  def commit_fixture(root)
    fixture_git(root, 'init', '-q')
    fixture_git(root, 'add', '.')
    fixture_git(root, 'commit', '-qm', 'fixture')
    fixture_git(root, 'rev-parse', 'HEAD')
  end

  # Real Bundler, local-only path gems, and a private Gemfile. Running this spec
  # under 2.2, 2.5 and 4 exercises each installed Bundler's actual boundary.
  def bundle_fixture(root, *args, env: {})
    bundle = Gem.bin_path('bundler', 'bundle', Bundler::VERSION)
    program = "gem 'bundler', #{Bundler::VERSION.inspect}; load ARGV.shift"
    fixture_ruby(root, program, bundle, *args, env: env)
  end

  def fixture_ruby(root, program, *args, env: {})
    child = { 'PATH' => ENV.fetch('PATH'), 'GEM_HOME' => Gem.dir, 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR),
              'GEMRC' => File::NULL, 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile'),
              'BUNDLE_IGNORE_CONFIG' => 'true', 'GIT_CONFIG_GLOBAL' => File::NULL,
              'GIT_CONFIG_SYSTEM' => File::NULL }.merge(env)
    Open3.capture3(child, RbConfig.ruby, '-e', program, '--', *args, chdir: root, unsetenv_others: true)
  end

  # Bundler 4's local lock/install can leave empty package checksums. Finalize
  # only temporary fixture locks, from installed specs and cached archives,
  # before frozen consumers. add_checksums would enable remote sources.
  def finalize_fixture_lock(root, env: {})
    return if Gem::Version.new(Bundler::VERSION) < Gem::Version.new('4')

    program = <<~RUBY
      gem 'bundler', #{Bundler::VERSION.inspect}
      require 'bundler'
      require 'rubygems/package'
      gemfile = File.realpath(ENV.fetch('BUNDLE_GEMFILE'))
      lock = Bundler.default_lockfile.expand_path.to_s
      unless gemfile.start_with?(File.realpath(Dir.pwd) + '/') && lock == gemfile + '.lock'
        abort 'checksum finalization requires a native fixture lock inside its temporary root'
      end
      abort 'checksum finalization requires unfrozen fixture preparation' if Bundler.frozen_bundle?
      definition = Bundler.definition
      abort 'Bundler 4 fixture lock must retain CHECKSUMS' unless definition.locked_checksums
      definition.sources.local_only!
      resolved = definition.resolve
      specs = resolved.materialize(definition.requested_dependencies)
      missing = resolved.missing_specs + resolved.incomplete_specs
      abort 'fixture specs are not completely available locally' unless missing.empty?
      resolved.each do |locked|
        next unless locked.source.is_a?(Bundler::Source::Rubygems)
        spec = specs.find { |candidate| candidate.lock_name == locked.lock_name }
        abort 'fixture spec is not materialized locally: ' + locked.full_name unless spec
        archive = spec.source.cached_built_in_gem(spec, local: true)
        abort 'missing cached fixture archive: ' + spec.full_name unless archive && File.file?(archive)
        package = Gem::Package.new(archive)
        abort 'cached fixture archive identity mismatch: ' + archive unless package.spec.full_name == spec.full_name
        checksum = Bundler::Checksum.from_gem_package(package)
        abort 'fixture archive checksum is unavailable: ' + archive unless checksum
        spec.source.checksum_store.register(spec, checksum)
      end
      definition.lock
    RUBY
    out, err, status = fixture_ruby(root, program, env: env)
    raise "fixture checksum finalization failed: #{out} #{err}" unless status.success?
  end

  def lock_fixture(root, puma: nil, gemfile: 'Gemfile')
    env = { 'WOODS_PUMA_REQ' => puma, 'BUNDLE_GEMFILE' => File.join(root, gemfile) }
    out, err, status = bundle_fixture(root, 'lock', '--local', env: env)
    raise "fixture lock failed: #{out} #{err}" unless status.success?

    finalize_fixture_lock(root, env: env)
    File.binread("#{File.join(root, gemfile)}.lock")
  end

  def activation(root, puma: nil, extra: {})
    helper = File.expand_path('../../script/ci_local_environment.rb', __dir__)
    code = <<~RUBY
      require #{helper.inspect}
      data = CiLocalEnvironment.observe
      data['resource'] = File.read(File.join(data.fetch('woods_path'), 'assets/marker.txt'))
      puts JSON.generate(data)
    RUBY
    bundle_fixture(root, 'exec', RbConfig.ruby, '-e', code,
                   env: { 'BUNDLE_FROZEN' => 'true', 'WOODS_PUMA_REQ' => puma }.merge(extra))
  end

  def fixture_record(root, lock, row = 'unit')
    config = described_class::ROWS.fetch(row)
    dependencies = described_class.hashes(root, described_class.dependencies(row))
    commands = described_class::COMMAND_INPUTS.to_h { |path| [path, 'b' * 64] }
    identity = { 'ruby_engine' => 'ruby', 'ruby_version' => "#{config[:ruby]}.1", 'ruby_revision' => '123abc',
                 'ruby_description' => 'ruby fixture', 'ruby_path' => '/ruby/bin/ruby', 'ruby_sha256' => 'c' * 64,
                 'ruby_platform' => 'x86_64-linux', 'gem_platform' => 'x86_64-linux', 'rubygems' => '3.5.22',
                 'bundler' => '2.5.22', 'gemfile_path' => File.join('/host/woods', config[:gemfile]),
                 'lock_path' => "#{File.join('/host/woods', config[:gemfile])}.lock",
                 'lock_sha256' => Digest::SHA256.hexdigest(lock),
                 'gems' => [%w[puma 8.0.2 ruby], %w[woods 0.0.1 ruby]],
                 'dependency_inputs' => described_class.expected_inputs(row),
                 'woods_path' => '/host/woods', 'woods_executable' => '/host/woods/exe/woods-watch',
                 'woods_version_file' => '/host/woods/lib/woods/version.rb',
                 'os' => { 'ID' => 'ubuntu', 'VERSION_ID' => '24.04' } }
    { 'schema' => 2, 'repository' => 'lost-in-the/woods', 'run_id' => '123', 'attempt' => '1',
      'event' => 'pull_request', 'reference_source_sha' => 'a' * 40, 'row' => row, 'job' => config[:job],
      'gemfile' => config[:gemfile], 'dependency_hashes' => dependencies, 'command_hashes' => commands,
      'identity' => identity, 'image' => { 'ImageOS' => 'ubuntu24', 'ImageVersion' => '20261012.334.1' },
      'profile' => row.start_with?('rails-') ? described_class.profile(false, true, config[:ruby]) : nil }
  end

  def write_reference(directory, row, record, lock)
    target = File.join(directory, row)
    FileUtils.mkdir_p(target)
    File.write(File.join(target, 'environment.json'), JSON.generate(record))
    File.binwrite(File.join(target, 'Gemfile.lock'), lock)
  end

  # Synthetic bytes are used only for JSON/header refusal tests. The activation,
  # capture and checkout cases above/below use Bundler-generated fixture locks.
  def reference_lock
    "GEM\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\nBUNDLED WITH\n   2.5.22\n"
  end

  it 'activates lint and unit frozen against one existing fast-mode lock without changing it', :baseline_puma do
    Dir.mktmpdir do |root|
      fixture(root)
      original = lock_fixture(root)
      _, _, wrong = activation(root, puma: '~> 8.0')
      expect(wrong.success?).to be(false)
      %w[lint unit].each do |row|
        actual = described_class.bundle_env(root, row, File.join(root, 'tmp/bundles'))
        out, err, status = activation(root, puma: actual['WOODS_PUMA_REQ'])
        expect(status.success?).to be(true), "#{row}: #{out} #{err}"
        observed = JSON.parse(out.lines.last)
        expect(observed['woods_path']).to eq(File.realpath(root))
        expect(observed['resource']).to eq('complete-source-resource')
        expect(File.binread(File.join(root, 'Gemfile.lock'))).to eq(original)
      end
    end
  end

  it 'binds each fresh frozen row to its own complete candidate checkout' do
    Dir.mktmpdir do |directory|
      a = File.join(directory, 'candidate-a')
      b = File.join(directory, 'candidate-b')
      other = File.join(directory, 'unit-lock-source')
      [a, other].each do |path|
        FileUtils.mkdir_p(path)
        fixture(path)
      end
      lint_lock = lock_fixture(a)
      unit_lock = lock_fixture(other, puma: '~> 8.0')
      rails_lock = lock_fixture(a, gemfile: 'gemfiles/rails_6.0.gemfile')
      ref_lint = File.join(directory, 'lint.lock')
      ref_unit = File.join(directory, 'unit.lock')
      ref_rails = File.join(directory, 'rails.lock')
      File.binwrite(ref_lint, lint_lock)
      File.binwrite(ref_unit, unit_lock)
      File.binwrite(ref_rails, rails_lock)
      sha = commit_fixture(a)
      fixture_git(directory, 'clone', '--no-hardlinks', '-q', '--', a, b)
      File.binwrite(File.join(b, 'Gemfile.lock'), lint_lock)
      storage = File.join(directory, 'profiles')
      identity = { 'candidate_source_sha' => sha, 'reference_source_sha' => sha, 'run_id' => '123', 'attempt' => '1' }
      lint = identity.merge('reference_lock' => ref_lint,
                            'identity' => { 'lock_sha256' => Digest::SHA256.hexdigest(lint_lock) })
      unit = identity.merge('reference_lock' => ref_unit,
                            'identity' => { 'lock_sha256' => Digest::SHA256.hexdigest(unit_lock) })
      lint['identity']['bundler'] = Bundler::VERSION
      unit['identity']['bundler'] = Bundler::VERSION
      rails = identity.merge('reference_lock' => ref_rails,
                             'identity' => { 'bundler' => Bundler::VERSION,
                                             'lock_sha256' => Digest::SHA256.hexdigest(rails_lock) })
      source_a = described_class.prepare_checkout(a, lint, 'lint', storage)
      File.write(File.join(a, 'lib/woods/example.rb'), "CHANGED_A = true\n")
      source_b = described_class.prepare_checkout(b, lint, 'lint', storage)
      unit_b = described_class.prepare_checkout(b, unit, 'unit', storage)
      rails_b = described_class.prepare_checkout(b, rails, 'rails-3.0-6.0', storage)
      expect(source_b).not_to eq(source_a)
      expect do
        described_class.verify_checkout!(a, lint, 'lint', storage)
      end.to raise_error(described_class::Error, /changes/)
      expect(described_class.verify_checkout!(b, lint, 'lint', storage)).to eq(source_b)
      rows = [[source_b, lint_lock, nil, 'Gemfile'], [unit_b, unit_lock, '~> 8.0', 'Gemfile'],
              [rails_b, rails_lock, nil, 'gemfiles/rails_6.0.gemfile']]
      rows.each do |source, lock, puma, gemfile|
        env = { 'BUNDLE_GEMFILE' => File.join(source, gemfile) }
        out, err, status = activation(source, puma: puma, extra: env)
        expect(status.success?).to be(true), "#{source}: #{out} #{err}"
        observed = JSON.parse(out.lines.last)
        expect(observed['woods_path']).to eq(File.realpath(source))
        expect { described_class.verify_source!(observed, source, env.fetch('BUNDLE_GEMFILE')) }.not_to raise_error
        expect(observed['woods_executable']).to eq(File.realpath(File.join(source, 'exe/woods-watch')))
        expect(observed['resource']).to eq('complete-source-resource')
        exe_out, exe_err, exe_status = bundle_fixture(
          source, 'exec', RbConfig.ruby, '-e', "load Gem.bin_path('woods', 'woods-watch')",
          env: env.merge('BUNDLE_FROZEN' => 'true', 'WOODS_PUMA_REQ' => puma)
        )
        expect(exe_status.success?).to be(true), exe_err
        expect(exe_out).to include('watch')
        expect(File.binread("#{env.fetch('BUNDLE_GEMFILE')}.lock")).to eq(lock)
      end
      expect(File.binread(File.join(b, 'Gemfile.lock'))).to eq(lint_lock)
      out, err, status = activation(source_a)
      expect(status.success?).to be(true), "#{out} #{err}"
      expect do
        described_class.verify_source!(JSON.parse(out.lines.last), source_b, File.join(source_b, 'Gemfile'))
      end.to raise_error(described_class::Error, /not bound/)
      binding_path = File.join(File.dirname(source_b), 'binding.json')
      wrong_binding = File.read(File.join(File.dirname(source_a), 'binding.json'))
      File.write(binding_path, wrong_binding)
      expect do
        described_class.prepare_checkout(b, lint, 'lint', storage)
      end.to raise_error(described_class::Error, /wrong candidate binding/)
      expect(File.read(binding_path)).to eq(wrong_binding)
    end
  end

  it 'ignores setup-ruby vendor files but rejects tracked edits and unrelated untracked source' do
    Dir.mktmpdir do |root|
      fixture(root)
      sha = commit_fixture(root)
      vendor = File.join(root, 'vendor/bundle/ruby/gems/example/lib/example.rb')
      FileUtils.mkdir_p(File.dirname(vendor))
      File.write(vendor, 'generated')
      expect(described_class.source_sha(root, hosted: true)).to eq(sha)
      File.write(File.join(root, 'unexpected.rb'), 'untracked')
      expect { described_class.source_sha(root, hosted: true) }.to raise_error(described_class::Error, /changes/)
      File.delete(File.join(root, 'unexpected.rb'))
      File.write(File.join(root, 'Gemfile'), 'tracked edit')
      expect { described_class.source_sha(root, hosted: true) }.to raise_error(described_class::Error, /changes/)
    end
  end

  CiLocalEnvironment::ROWS.each do |row, config|
    next unless config[:ruby] == RUBY_VERSION.split('.').first(2).join('.')

    it "captures #{row} with real Bundler/vendor files and refuses unexpected source" do
      Dir.mktmpdir do |directory|
        root = File.join(directory, 'hosted')
        FileUtils.mkdir_p(root)
        fixture(root)
        described_class::COMMAND_INPUTS.each do |path|
          target = File.join(root, path)
          next if File.exist?(target)

          FileUtils.mkdir_p(File.dirname(target))
          if path == 'script/ci_local_environment.rb'
            FileUtils.cp(File.expand_path('../../script/ci_local_environment.rb', __dir__), target)
          else
            File.write(target, "fixture command input\n")
          end
        end
        sha = commit_fixture(root)
        lock = lock_fixture(root, puma: config[:puma], gemfile: config[:gemfile])
        vendor = File.join(root, 'vendor/bundle/ruby/gems/example/lib/example.rb')
        FileUtils.mkdir_p(File.dirname(vendor))
        File.write(vendor, 'generated')
        target = File.join(directory, 'capture')
        env = { 'BUNDLE_GEMFILE' => File.join(root, config[:gemfile]), 'GITHUB_ACTIONS' => 'true',
                'GITHUB_REPOSITORY' => 'lost-in-the/woods', 'GITHUB_JOB' => config[:job], 'GITHUB_SHA' => sha,
                'GITHUB_RUN_ID' => '123', 'GITHUB_RUN_ATTEMPT' => '1', 'GITHUB_EVENT_NAME' => 'pull_request',
                'ImageOS' => 'ubuntu24', 'ImageVersion' => 'fixture', 'WOODS_PUMA_REQ' => config[:puma] }
        if row.start_with?('rails-')
          depths = described_class.profile(false, true, config[:ruby])
          env['WOODS_CI_REFERENCE_OPS'], env['WOODS_CI_REFERENCE_SEEDS'] = depths
        end
        args = ['exec', RbConfig.ruby, File.join(root, 'script/ci_local_environment.rb'), 'capture', row, target]
        out, err, status = bundle_fixture(root, *args, env: env)
        expect(status.success?).to be(true), "#{out} #{err}"
        expect(File.binread(File.join(target, 'Gemfile.lock'))).to eq(lock)
        record = JSON.parse(File.read(File.join(target, 'environment.json')))
        expect(record).to include('row' => row, 'reference_source_sha' => sha, 'run_id' => '123')
        expect(record.fetch('identity').fetch('dependency_inputs')).to eq(described_class.expected_inputs(row))
        File.write(File.join(root, 'unexpected.rb'), 'untracked')
        _, err, status = bundle_fixture(root, *args, env: env)
        expect(status.success?).to be(false), err
        expect(err).to include('source has tracked or untracked changes')
        File.delete(File.join(root, 'unexpected.rb'))
        File.open(File.join(root, 'Gemfile'), 'a') { |file| file.puts('# tracked change') }
        _, err, status = bundle_fixture(root, *args, env: env)
        expect(status.success?).to be(false), err
        expect(err).to include('source has tracked or untracked changes')
      end
    end
  end

  it 'runs real RSpec examples at the requested seed through the controlled command boundary' do
    Dir.mktmpdir do |root|
      xdg = File.join(root, 'xdg/rspec')
      FileUtils.mkdir_p(xdg)
      File.write(File.join(xdg, 'options'), '--dry-run --seed 1 --tag not_selected')
      File.write(File.join(root, '.rspec'), '--format progress')
      File.write(File.join(root, '.rspec-local'), '--dry-run --seed 2 --tag not_selected')
      FileUtils.mkdir_p(File.join(root, 'bin'))
      File.write(File.join(root, 'bin/rspec'), "require 'bundler/setup'; load Gem.bin_path('rspec-core', 'rspec')\n")
      core = Gem.loaded_specs.fetch('rspec-core').version
      support = Gem.loaded_specs.fetch('rspec-support').version
      File.write(File.join(root, 'Gemfile'), <<~GEMFILE)
        source 'https://rubygems.org'
        gem 'rspec-core', '= #{core}'
        gem 'rspec-support', '= #{support}'
      GEMFILE
      lock_fixture(root)
      marker = File.join(root, 'executed')
      spec = File.join(root, 'probe_spec.rb')
      File.write(spec, <<~RUBY)
        RSpec.describe('probe') do
          it('runs') { File.write(ENV.fetch('MARKER'), RSpec.configuration.seed.to_s) }
        end
      RUBY
      old = ENV.to_h.slice('SPEC_OPTS', 'RSPEC_OPTS', 'BUNDLER_ORIG_SPEC_OPTS')
      begin
        ENV['SPEC_OPTS'] = '--dry-run --seed 1 --tag not_selected'
        ENV['BUNDLER_ORIG_SPEC_OPTS'] = ENV.fetch('SPEC_OPTS', nil)
        ENV['RSPEC_OPTS'] = ENV.fetch('SPEC_OPTS', nil)
        stub_const('CiLocalRunnerSpecHarness::ROOT', root)
        runner = Object.new.extend(CiLocalRunnerSpecHarness)
        env = runner.send(:bundle_env, 'lint')
        env.merge!('MARKER' => marker, 'XDG_CONFIG_HOME' => File.join(root, 'xdg'),
                   'GEM_HOME' => Gem.dir, 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR),
                   'BUNDLE_GEMFILE' => File.join(root, 'Gemfile'))
        prefix = File.expand_path('..', File.dirname(RbConfig.ruby))
        minor = RUBY_VERSION.split('.').first(2).join('.')
        runner.instance_variable_set(:@rubies, { [minor, nil] => prefix })
        argv = described_class.rspec_argv(root, [spec], 43_656)
        step = CiLocalRunnerSpecHarness::Step.new('RSpec boundary', minor, env, argv, 'lint')
        ok, = runner.send(:run_step, step, { report_dir: nil })
        expect(ok).to be(true)
        expect(File).to exist(marker)
        expect(File.read(marker)).to eq('43656')
        expect(ENV.fetch('SPEC_OPTS', nil)).to include('--dry-run')
      ensure
        %w[SPEC_OPTS RSPEC_OPTS BUNDLER_ORIG_SPEC_OPTS].each { |key| ENV[key] = old[key] }
      end
    end
  end

  it 'uses the setup lock guard and actual Bundler lock despite inherited BUNDLE_LOCKFILE' do
    Dir.mktmpdir do |root|
      fixture(root)
      alternate = File.join(root, 'sentinel.lock')
      File.write(alternate, 'do not touch')
      previous = ENV.fetch('BUNDLE_LOCKFILE', nil)
      original_override = ENV.fetch('BUNDLER_ORIG_BUNDLE_LOCKFILE', nil)
      begin
        ENV['BUNDLE_LOCKFILE'] = alternate
        ENV['BUNDLER_ORIG_BUNDLE_LOCKFILE'] = alternate
        stub_const('CiLocalRunnerSpecHarness::ROOT', root)
        runner = Object.new.extend(CiLocalRunnerSpecHarness)
        step = runner.send(:setup_steps, ['rails-4.0-8.1']).first
        managed = step.env.merge('GEM_HOME' => Gem.dir, 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR))
        native = "#{managed.fetch('BUNDLE_GEMFILE')}.lock"
        expect(File).not_to exist(native)
        expect(managed['BUNDLE_FROZEN']).to be_nil
        out, err, status = bundle_fixture(root, *step.argv.drop(1), '--local', env: managed)
        expect(status.success?).to be(true), "#{out} #{err}"
        expect(File.read(alternate)).to eq('do not touch')
        finalize_fixture_lock(root, env: managed)
        frozen = managed.merge('BUNDLE_FROZEN' => 'true')
        out, err, status = activation(root, extra: frozen)
        expect(status.success?).to be(true), "#{out} #{err}"
        expect(JSON.parse(out.lines.last)['lock_path']).to eq(native)
        expect(File.read(alternate)).to eq('do not touch')
        expect(ENV.fetch('BUNDLE_LOCKFILE', nil)).to eq(alternate)
      ensure
        ENV['BUNDLE_LOCKFILE'] = previous
        ENV['BUNDLER_ORIG_BUNDLE_LOCKFILE'] = original_override
      end
    end
  end

  it 'admits a later clean candidate only while dependency-defining inputs match' do
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'candidate')
      FileUtils.mkdir_p(root)
      fixture(root)
      sha = commit_fixture(root)
      ref = File.join(directory, 'reference')
      lock = reference_lock
      valid = fixture_record(root, lock).merge('reference_source_sha' => sha)
      write_reference(ref, 'unit', valid, lock)
      File.write(File.join(root, 'lib/woods/example.rb'), "LATER_CANDIDATE = true\n")
      fixture_git(root, 'add', '.')
      fixture_git(root, 'commit', '-qm', 'later source')
      later = fixture_git(root, 'rev-parse', 'HEAD')
      current, records = described_class.references(ref, ['unit'], '123', '1', root)
      expect(current).to eq(later)
      expect(records.fetch('unit')).to include('reference_source_sha' => sha, 'candidate_source_sha' => later)
      expect(later).not_to eq(sha)
      File.open(File.join(root, 'Gemfile'), 'a') { |file| file.puts('# changed dependency definition') }
      fixture_git(root, 'add', '.')
      fixture_git(root, 'commit', '-qm', 'changed dependency input')
      expect do
        described_class.references(ref, ['unit'], '123', '1', root)
      end.to raise_error(described_class::Error, /dependency-defining/)
    end
  end

  it 'refuses malformed and contradictory evidence in the CLI before any installer or gate' do
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'candidate')
      FileUtils.mkdir_p(root)
      fixture(root)
      FileUtils.mkdir_p(File.join(root, 'script'))
      %w[ci-local ci_local_environment.rb].each do |name|
        FileUtils.cp(File.expand_path("../../script/#{name}", __dir__), File.join(root, 'script', name))
      end
      commit_fixture(root)
      reference = File.join(directory, 'reference')
      lock = reference_lock
      valid = fixture_record(root, lock)
      identity = valid.fetch('identity')
      invalid = [nil, [], 42, valid.merge('identity' => nil), valid.merge('job' => 'lint'),
                 valid.merge('attempt' => '2'), valid.merge('image' => []),
                 valid.merge('identity' => identity.except('bundler')),
                 valid.merge('identity' => identity.merge('dependency_inputs' =>
                   described_class.expected_inputs('lint'))),
                 valid.merge('identity' => identity.merge('gems' => [['puma', nil, 'ruby']])),
                 valid.merge('identity' => identity.merge('ruby_revision' => 123)),
                 valid.merge('identity' => identity.merge('woods_version_file' => '/another/woods/version.rb')),
                 valid.merge('identity' => identity.merge('bundler' => '2.5.23')),
                 valid.merge('dependency_hashes' => valid['dependency_hashes'].merge('Gemfile' => '0' * 64)),
                 valid.merge('command_hashes' => valid['command_hashes'].merge('bin/rspec' => nil))]
      fake_bin = File.join(directory, 'bin')
      FileUtils.mkdir_p(fake_bin)
      fake_mise = File.join(fake_bin, 'mise')
      File.write(fake_mise, "#!/bin/sh\nprintf called > \"$CI_MISE_MARKER\"\nexit 88\n")
      FileUtils.chmod(0o755, fake_mise)
      marker = File.join(directory, 'mise-called')
      env = { 'PATH' => "#{fake_bin}:#{ENV.fetch('PATH')}", 'GIT_CONFIG_GLOBAL' => File::NULL,
              'GIT_CONFIG_SYSTEM' => File::NULL, 'CI_MISE_MARKER' => marker,
              'WOODS_CI_LOCAL_BUNDLE' => File.join(directory, 'profiles') }
      argv = [RbConfig.ruby, File.join(root, 'script/ci-local'), '--reference', reference,
              '--run-id', '123', '--attempt', '1', '--only', 'unit', '--setup']
      invalid.each do |record|
        write_reference(reference, 'unit', record, lock)
        out, err, status = Open3.capture3(env, *argv, chdir: root, unsetenv_others: true)
        expect(status.exitstatus).to eq(1), "#{out} #{err}"
        expect(err).to include('ci-local preflight failed:')
        expect(err).not_to include('NoMethodError')
        expect(File).not_to exist(marker)
        expect(File).not_to exist(File.join(directory, 'profiles'))
      end
      write_reference(reference, 'lint', fixture_record(root, lock, 'lint'), lock)
      write_reference(reference, 'unit', nil, lock)
      argv[-3, 2] = ['--skip-booted']
      _, _, status = Open3.capture3(env, *argv, chdir: root, unsetenv_others: true)
      expect(status.exitstatus).to eq(1)
      expect(File).not_to exist(marker)
      expect(File).not_to exist(File.join(directory, 'profiles'))
    end
  end

  it 'rejects contradictory Rails 6 sqlite evidence and absent references' do
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'candidate')
      FileUtils.mkdir_p(File.join(root, 'gemfiles'))
      fixture(root)
      File.write(File.join(root, 'gemfiles/rails_6.0.gemfile'), 'fixture appraisal')
      commit_fixture(root)
      ref = File.join(directory, 'reference')
      lock = reference_lock
      record = fixture_record(root, lock, 'rails-3.0-6.0')
      record['identity']['dependency_inputs']['WOODS_SQLITE3_REQ'] = nil
      write_reference(ref, 'rails-3.0-6.0', record, lock)
      expect do
        described_class.references(ref, ['rails-3.0-6.0'], '123', '1', root)
      end.to raise_error(described_class::Error, /contradictory/)
      expect do
        described_class.references(ref, ['lint'], '123', '1', root)
      end.to raise_error(described_class::Error, /missing or invalid/)
    end
  end

  it 'checks a real advertised Ruby runtime before invoking either gem installer' do
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'candidate')
      fixture(root)
      FileUtils.mkdir_p(File.join(root, 'script'))
      FileUtils.cp(File.expand_path('../../script/ci_local_environment.rb', __dir__), File.join(root, 'script'))
      lock = lock_fixture(root)
      sha = commit_fixture(root)
      reference = File.join(directory, 'reference.lock')
      File.binwrite(reference, lock)
      record = fixture_record(root, lock, 'lint').merge(
        'candidate_source_sha' => sha, 'reference_source_sha' => sha, 'reference_lock' => reference
      )
      record['identity'].merge!('bundler' => Bundler::VERSION, 'ruby_revision' => '0' * 40)
      storage = File.join(directory, 'storage')
      prefix = File.join(storage, 'mise/data/installs/ruby', record.dig('identity', 'ruby_version'))
      FileUtils.mkdir_p(File.join(prefix, 'bin'))
      File.symlink(RbConfig.ruby, File.join(prefix, 'bin/ruby'))
      %w[gem bundle].each do |name|
        File.write(File.join(prefix, 'bin', name), "File.write(ENV.fetch('CI_INSTALL_MARKER'), 'called'); exit 88\n")
      end
      bin = File.join(directory, 'bin')
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, 'mise'), <<~SHELL)
        #!/bin/sh
        if [ "$1" = where ]; then printf '%s\n' "$CI_RUBY_PREFIX"; exit 0; fi
        printf called > "$CI_INSTALL_MARKER"
        exit 88
      SHELL
      FileUtils.chmod(0o755, File.join(bin, 'mise'))
      marker = File.join(directory, 'installer-called')
      old = ENV.to_h.slice('PATH', 'CI_RUBY_PREFIX', 'CI_INSTALL_MARKER')
      begin
        ENV['PATH'] = "#{bin}:#{ENV.fetch('PATH')}"
        ENV['CI_RUBY_PREFIX'] = prefix
        ENV['CI_INSTALL_MARKER'] = marker
        expect do
          described_class.provision(root, record, 'lint', storage)
        end.to raise_error(described_class::Error, %r{Ruby/RubyGems/platform drift:.*ruby_revision})
        expect(File).not_to exist(marker)
      ensure
        %w[PATH CI_RUBY_PREFIX CI_INSTALL_MARKER].each { |key| ENV[key] = old[key] }
      end
    end
  end

  it 'detects required toolchain drift but reports OS and binary drift separately' do
    keys = described_class::MATCH_KEYS.to_h { |key| [key, key] }
    expect(described_class.differences(keys, keys.merge('os' => 'omarchy', 'ruby_sha256' => 'different'))).to be_empty
    required = %w[ruby_engine ruby_version ruby_revision rubygems bundler lock_sha256 gems
                  dependency_inputs ruby_platform gem_platform]
    required.each do |key|
      expect(described_class.differences(keys, keys.merge(key => 'changed'))).to include(key)
    end
    expect(described_class.report_status({ 'ImageOS' => 'ubuntu24' }, { 'ImageOS' => nil })).to eq('unknown')
  end

  it 'stops on the first failing real subprocess and leaves later gates unrun' do
    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'later-ran')
      runner = Object.new.extend(CiLocalRunnerSpecHarness)
      prefix = File.expand_path('..', File.dirname(RbConfig.ruby))
      runner.instance_variable_set(:@rubies, { ['3.3', nil] => prefix })
      runner.instance_variable_set(:@references, nil)
      step = CiLocalRunnerSpecHarness::Step
      env = { 'GEM_HOME' => Gem.dir }
      steps = [step.new('first', '3.3', env, ['/bin/sh', '-c', 'exit 0'], 'lint'),
               step.new('failed', '3.3', env, ['/bin/sh', '-c', 'exit 7'], 'lint'),
               step.new('later', '3.3', env.merge('MARKER' => marker), ['/bin/sh', '-c', 'touch "$MARKER"'], 'lint')]
      results, failed = runner.send(:execute_gates, [['lint', steps]], { report_dir: nil })
      expect(failed).to eq('lint: failed')
      expect(results.last.last).to eq('FAILED')
      expect(File).not_to exist(marker)
    end
  end

  it 'keeps gate selections and PR/full profiles aligned with the checked-in workflow' do
    jobs = YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true).fetch('jobs')
    expect(jobs.fetch('test-required').dig('strategy', 'matrix', 'include').first)
      .to include('ruby-version' => '3.3', 'puma' => '~> 8.0', 'pr' => true)
    rows = jobs.fetch('rails-matrix').dig('strategy', 'matrix', 'include')
    [%w[4.0 8.1], %w[3.0 6.0]].each do |ruby, rails|
      entry = rows.find { |item| item['ruby'] == ruby && item['rails'] == rails }
      expect(entry['pr']).to eq(described_class::PULL_REQUEST_ROWS.include?("rails-#{ruby}-#{rails}"))
      expect(entry.values_at('pr_diff_ops', 'pr_diff_seeds')).to eq(described_class.profile(false, true, ruby))
      expect(described_class.profile(false, false, ruby)).to eq(%w[8 1])
      expect(described_class.profile(true, false, ruby)).to eq(['60', '1,2,3'])
    end
    runner = Object.new.extend(CiLocalRunnerSpecHarness)
    opts = { only: 'booted', skip_booted: false, full: false, match: 'incremental_equivalence',
             hosted_pr: true, rspec_seed: 43_656 }
    steps = runner.send(:gates, opts).first.last
    expect(steps.map(&:row)).to eq(%w[rails-4.0-8.1])
    expect(runner.send(:gates, opts.merge(hosted_pr: false)).first.last.map(&:row))
      .to eq(%w[rails-4.0-8.1 rails-3.0-6.0])
    expect(steps.map { |step| step.argv.last(2) }).to all(eq(%w[--seed 43656]))
    expect(runner.send(:gates, opts.merge(skip_booted: true))).to be_empty
  end
end

# rubocop:enable Metrics/MethodLength, Metrics/AbcSize
