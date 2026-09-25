# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../script/release_profile'

RSpec.describe 'trusted maintenance release profile' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:release_tag) { 'v1.6.3' }
  let(:base_version) { '1.6.2' }
  let(:profile_prefix) { 'MAINTENANCE' }
  let(:maintenance_jobs) { ReleaseProfile::MAINTENANCE_JOBS }

  def git(repository, *args)
    output, status = Open3.capture2e('git', *args, chdir: repository)
    raise output unless status.success?

    output.strip
  end

  def write_candidate(repository, version)
    FileUtils.mkdir_p(File.join(repository, 'lib/woods'))
    File.write(File.join(repository, 'lib/woods/version.rb'), "module Woods\n VERSION = '#{version}'\nend\n")
    File.write(File.join(repository, 'CHANGELOG.md'), "## [#{version}] - 2026-09-18\n")
    git(repository, 'add', '.')
    git(repository, 'commit', '-m', version)
    git(repository, 'rev-parse', 'HEAD')
  end

  def fixture
    Dir.mktmpdir('woods-maintenance-release') do |directory|
      repository = File.join(directory, 'checkout')
      remote = File.join(directory, 'remote.git')
      FileUtils.mkdir_p(repository)
      git(repository, 'init', '-b', 'main')
      git(repository, 'config', 'user.name', 'Maintenance tests')
      git(repository, 'config', 'user.email', 'maintenance@example.invalid')
      base = write_candidate(repository, base_version)
      branch = "release/#{release_tag.delete_prefix('v')}"
      git(repository, 'checkout', '-b', branch)
      candidate = write_candidate(repository, release_tag.delete_prefix('v'))
      git(repository, 'tag', release_tag)
      git(repository, 'init', '--bare', remote)
      git(repository, 'remote', 'add', 'origin', remote)
      git(repository, 'push', 'origin', 'main', branch, "refs/tags/#{release_tag}")
      git(repository, 'checkout', 'main')
      install_trusted_scripts(repository, candidate, base)
      yield repository, remote, candidate, base
    end
  end

  def install_trusted_scripts(repository, candidate, base)
    FileUtils.mkdir_p(File.join(repository, 'script'))
    %w[validate-release validate-release-run verify-release-tag release_profile.rb].each do |name|
      FileUtils.cp(File.join(root, 'script', name), File.join(repository, 'script', name))
    end
    profile_path = File.join(repository, 'script/release_profile.rb')
    profile = File.read(profile_path)
                  .sub(/#{profile_prefix}_BASE = '[0-9a-f]{40}'/, "#{profile_prefix}_BASE = '#{base}'")
                  .sub(/#{profile_prefix}_APPROVED_SHA = (?:nil|'[0-9a-f]{40}')/,
                       "#{profile_prefix}_APPROVED_SHA = '#{candidate}'")
    File.write(profile_path, profile)
    git(repository, 'add', '.')
    git(repository, 'commit', '-m', 'trusted tooling with reviewed candidate pin')
  end

  def validate(repository, candidate, script: 'validate-release', extra: {}, trusted: true)
    env = {
      'RELEASE_TAG' => release_tag, 'RELEASE_SHA' => candidate,
      'RELEASE_TRUSTED_SHA' => git(repository, 'rev-parse', 'HEAD'),
      'RUBYGEMS_VERSIONS_JSON' => '[]'
    }.merge(extra)
    args = trusted ? ['--trusted-checkout'] : []
    Open3.capture3(env, 'ruby', File.join(repository, 'script', script), *args, chdir: repository)
  end

  it 'keeps the reviewed pin either disabled or a full immutable commit SHA' do
    expect(ReleaseProfile::MAINTENANCE_APPROVED_SHA).to be_nil.or match(/\A[0-9a-f]{40}\z/)
  end

  it 'allowlists only the 1.6.3 target, immutable 1.6.2 base and reviewed candidate' do
    expect(ReleaseProfile::MAINTENANCE_TAG).to eq('v1.6.3')
    expect(ReleaseProfile::MAINTENANCE_BRANCH).to eq('release/1.6.3')
    expect(ReleaseProfile::MAINTENANCE_BASE).to eq('4b40e17fd68122a70ccf00d9d2ffb8af42171d3d')
    expect(ReleaseProfile::MAINTENANCE_APPROVED_SHA).to eq('60d6b7c4a3ddc421073f1fb57a7249eccb77826e')
  end

  it 'is disabled until a reviewed main commit pins the complete candidate SHA' do
    stub_const('ReleaseProfile::MAINTENANCE_APPROVED_SHA', nil)
    expect { ReleaseProfile.validate_candidate!('v1.6.3', 'a' * 40) }
      .to raise_error(ReleaseProfile::Error, /disabled until/)
  end

  it 'does not select maintenance requirements for any other tag or caller environment' do
    %w[v1.6.2 v1.6.5 v2.0.0.beta3].each do |tag|
      expect(ReleaseProfile.maintenance?(tag)).to be(false)
      expect(ReleaseProfile.branch(tag)).to eq('main')
      expect(ReleaseProfile.package_spec(tag)).to eq('spec/integration/packaged_gem_spec.rb')
      expect(ReleaseProfile.package_mcp_floor(tag)).to eq('')
    end
    expect(ReleaseProfile.package_spec('v1.6.3')).to eq('spec/integration/maintenance_packaged_gem_spec.rb')
  end

  it 'accepts a pinned maintenance candidate outside main and verifies its live remote tag' do
    fixture do |repository, _remote, candidate, _base|
      _stdout, stderr, status = validate(repository, candidate)
      expect(status).to be_success, stderr
      _stdout, stderr, status = validate(repository, candidate, script: 'verify-release-tag')
      expect(status).to be_success, stderr
    end
  end

  it 'refuses an unapproved SHA before history or candidate content can authorize it' do
    fixture do |repository, _remote, _candidate, base|
      %w[validate-release verify-release-tag].each do |script|
        _stdout, stderr, status = validate(repository, base, script: script)
        expect(status).not_to be_success
        expect(stderr).to include('differs from the approved maintenance SHA')
      end
    end
  end

  it 'refuses candidate-checkout maintenance validation even when the SHA was approved' do
    fixture do |repository, _remote, candidate, _base|
      %w[validate-release verify-release-tag].each do |script|
        _stdout, stderr, status = validate(repository, candidate, script: script, trusted: false)
        expect(status).not_to be_success
        expect(stderr).to match(/trusted-checkout|checked-out HEAD/)
      end
    end
  end

  it 'refuses a target branch that no longer contains the approved candidate' do
    fixture do |repository, remote, candidate, base|
      git(remote, 'update-ref', 'refs/heads/release/1.6.3', base)
      _stdout, stderr, status = validate(repository, candidate)
      expect(status).not_to be_success
      expect(stderr).to include('not reachable')
    end
  end

  it 'does not let a caller substitute main for the fixed maintenance branch' do
    fixture do |repository, remote, candidate, _base|
      git(remote, 'update-ref', 'refs/heads/main', candidate)
      git(remote, 'update-ref', '-d', 'refs/heads/release/1.6.3')
      _stdout, stderr, status = validate(repository, candidate, extra: { 'RELEASE_MAIN_REF' => 'refs/heads/main' })
      expect(status).not_to be_success
      expect(stderr).to include('refs/heads/release/1.6.3')
    end
  end

  it 'refuses a moved remote tag both during validation and immediately before publication' do
    fixture do |repository, remote, candidate, base|
      git(remote, 'update-ref', 'refs/tags/v1.6.3', base)
      %w[validate-release verify-release-tag].each do |script|
        _stdout, stderr, status = validate(repository, candidate, script: script)
        expect(status).not_to be_success
        expect(stderr).to include('not release SHA')
      end
    end
  end

  it 'refuses a reviewed candidate whose pinned legacy base is not its ancestor' do
    fixture do |repository, _remote, candidate, _base|
      path = File.join(repository, 'script/release_profile.rb')
      source = File.read(path).sub(/MAINTENANCE_BASE = '[0-9a-f]{40}'/,
                                   "MAINTENANCE_BASE = '#{git(repository, 'rev-parse', 'HEAD')}'")
      File.write(path, source)
      git(repository, 'add', '.')
      git(repository, 'commit', '-m', 'invalid base fixture')
      _stdout, stderr, status = validate(repository, candidate)
      expect(status).not_to be_success
      expect(stderr).to include('does not descend from approved v1.6.2 base')
    end
  end

  it 'retains the already-published refusal for maintenance' do
    fixture do |repository, _remote, candidate, _base|
      _stdout, stderr, status = validate(
        repository, candidate, extra: { 'RUBYGEMS_VERSIONS_JSON' => '[{"number":"1.6.3"}]' }
      )
      expect(status).not_to be_success
      expect(stderr).to include('already published')
    end
  end
  def maintenance_run(sha)
    {
      'id' => 123, 'workflow_id' => 678, 'path' => '.github/workflows/ci.yml',
      'conclusion' => 'success', 'event' => 'push', 'head_branch' => release_tag, 'head_sha' => sha,
      'repository' => { 'full_name' => 'lost-in-the/woods' },
      'head_repository' => { 'full_name' => 'lost-in-the/woods' }
    }
  end

  def run_responses(sha, jobs, artifact)
    {
      '/repos/lost-in-the/woods/actions/runs/123' => maintenance_run(sha),
      '/repos/lost-in-the/woods/actions/workflows/ci.yml' =>
        { 'id' => 678, 'path' => '.github/workflows/ci.yml', 'name' => 'CI' },
      '/repos/lost-in-the/woods/actions/runs/123/jobs' => { 'jobs' => jobs },
      '/repos/lost-in-the/woods/actions/runs/123/artifacts' => {
        'artifacts' => if artifact
                         [{ 'id' => 900, 'name' => "woods-release-#{sha}",
                            'digest' => "sha256:#{'f' * 64}" }]
                       else
                         []
                       end
      },
      '/repos/lost-in-the/woods/environments/release' => {
        'protection_rules' => [{ 'type' => 'required_reviewers' }], 'can_admins_bypass' => false
      }
    }
  end

  def write_fake_api(repository)
    fake_bin = File.join(repository, '.git/fake-bin')
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, 'gh'), <<~SCRIPT)
      #!/usr/bin/env ruby
      require 'json'
      puts JSON.generate(JSON.parse(ENV.fetch('RESPONSES')).fetch(ARGV.last))
    SCRIPT
    FileUtils.chmod(0o755, File.join(fake_bin, 'gh'))
    fake_bin
  end

  def validate_run(repository, candidate, jobs: nil, sha: candidate, artifact: true)
    jobs ||= maintenance_jobs.map { |name| { 'name' => name, 'conclusion' => 'success' } }
    responses = run_responses(sha, jobs, artifact)
    fake_bin = write_fake_api(repository)
    output = File.join(repository, '.git/output')
    env = {
      'PATH' => "#{fake_bin}:#{ENV.fetch('PATH')}", 'CI_RUN_ID' => '123',
      'GITHUB_REPOSITORY' => 'lost-in-the/woods', 'GITHUB_OUTPUT' => output,
      'RELEASE_TAG' => release_tag, 'RESPONSES' => JSON.generate(responses)
    }
    stdout, stderr, status = Open3.capture3(env, 'ruby', File.join(repository, 'script/validate-release-run'))
    [stdout, stderr, status, File.exist?(output) ? File.read(output) : '']
  end

  it 'accepts every exact maintenance job and emits only the trusted v1 package spec and exact artifact' do
    fixture do |repository, _remote, candidate, _base|
      _stdout, stderr, status, outputs = validate_run(repository, candidate)
      expect(status).to be_success, stderr
      expect(outputs).to include('package-spec=spec/integration/maintenance_packaged_gem_spec.rb')
      expect(outputs).to include('maintenance-release=true')
      expect(outputs).to include('package-mcp-floor=0.23.0')
      expect(outputs).to include("release-sha=#{candidate}", 'artifact-id=900')
    end
  end

  it 'refuses a successful run for any SHA other than the reviewed pin' do
    fixture do |repository, _remote, candidate, base|
      _stdout, stderr, status, outputs = validate_run(repository, candidate, sha: base)
      expect(status).not_to be_success
      expect(stderr).to include('differs from the approved maintenance SHA')
      expect(outputs).to be_empty
    end
  end

  it 'requires each matrix cell rather than accepting one row with a common prefix' do
    fixture do |repository, _remote, candidate, _base|
      ReleaseProfile::MAINTENANCE_JOBS.each do |missing|
        jobs = (ReleaseProfile::MAINTENANCE_JOBS - [missing]).map do |name|
          { 'name' => name, 'conclusion' => 'success' }
        end
        _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: jobs)
        expect(status).not_to be_success
        expect(stderr).to include(missing)
        expect(outputs).to be_empty
      end
    end
  end

  it 'refuses skipped, failed or duplicate maintenance job rows' do
    fixture do |repository, _remote, candidate, _base|
      %w[skipped failure duplicate].each do |condition|
        jobs = ReleaseProfile::MAINTENANCE_JOBS.map { |name| { 'name' => name, 'conclusion' => 'success' } }
        condition == 'duplicate' ? jobs.push(jobs.first.dup) : jobs.first['conclusion'] = condition
        _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: jobs)
        expect(status).not_to be_success
        expect(stderr).to include('exactly one successful maintenance job')
        expect(outputs).to be_empty
      end
    end
  end

  it 'retains the immutable artifact requirement for an otherwise approved maintenance run' do
    fixture do |repository, _remote, candidate, _base|
      _stdout, stderr, status, outputs = validate_run(repository, candidate, artifact: false)
      expect(status).not_to be_success
      expect(stderr).to include('no artifact named')
      expect(outputs).to be_empty
    end
  end

  context 'with the disabled 1.6.4 maintenance profile' do
    let(:release_tag) { 'v1.6.4' }
    let(:base_version) { '1.6.3' }
    let(:profile_prefix) { 'V1_PATCH' }
    let(:maintenance_jobs) { ReleaseProfile::MAINTENANCE_JOBS + ['Maintenance security backends'] }

    it 'binds only the final 1.6.4 tag to its branch and immutable published 1.6.3 base' do
      expect(ReleaseProfile.branch(release_tag)).to eq('release/1.6.4')
      expect(ReleaseProfile.base(release_tag)).to eq('60d6b7c4a3ddc421073f1fb57a7249eccb77826e')
      expect(ReleaseProfile.base_tag(release_tag)).to eq('v1.6.3')
      expect(ReleaseProfile::V1_PATCH_APPROVED_SHA).to be_nil
      expect(ReleaseProfile.exact_ci_jobs(release_tag)).to eq(maintenance_jobs)
      expect(ReleaseProfile.exact_ci_jobs('v1.6.3')).not_to include('Maintenance security backends')
      expect(ReleaseProfile.package_mcp_floor(release_tag)).to eq('0.23.0')
      %w[v1.6.4.alpha v1.6.4.rc1 v1.6.5].each do |tag|
        expect(ReleaseProfile.maintenance?(tag)).to be(false)
        expect(ReleaseProfile.branch(tag)).to eq('main')
      end
    end

    it 'accepts only a pinned candidate and emits the trusted legacy package spec and SDK floor' do
      fixture do |repository, _remote, candidate, base|
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script)
          expect(status).to be_success, stderr
          _stdout, stderr, status = validate(repository, base, script: script)
          expect(status).not_to be_success
          expect(stderr).to include('differs from the approved maintenance SHA')
        end
        _stdout, stderr, status, outputs = validate_run(repository, candidate)
        expect(status).to be_success, stderr
        expect(outputs).to include('package-spec=spec/integration/maintenance_packaged_gem_spec.rb',
                                   'package-mcp-floor=0.23.0', 'maintenance-release=true')
        FileUtils.rm_f(File.join(repository, '.git/output'))
        _stdout, stderr, status, outputs = validate_run(repository, candidate, sha: base)
        expect(status).not_to be_success
        expect(stderr).to include('differs from the approved maintenance SHA')
        expect(outputs).to be_empty
      end
    end

    it 'keeps all three validators disabled until its own SHA is approved' do
      fixture do |repository, _remote, candidate, _base|
        path = File.join(repository, 'script/release_profile.rb')
        File.write(path, File.read(path).sub(/V1_PATCH_APPROVED_SHA = '[0-9a-f]{40}'/,
                                             'V1_PATCH_APPROVED_SHA = nil'))
        git(repository, 'add', '.')
        git(repository, 'commit', '-m', 'disable 1.6.4 fixture profile')
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script)
          expect(status).not_to be_success
          expect(stderr).to include('disabled until its prepared SHA is approved')
        end
        _stdout, stderr, status, outputs = validate_run(repository, candidate)
        expect(status).not_to be_success
        expect(stderr).to include('disabled until its prepared SHA is approved')
        expect(outputs).to be_empty
      end
    end

    it 'requires every legacy CI row and refuses a moved branch or tag after validation' do
      fixture do |repository, remote, candidate, base|
        jobs = maintenance_jobs.drop(1).map { |name| { 'name' => name, 'conclusion' => 'success' } }
        _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: jobs)
        expect(status).not_to be_success
        expect(stderr).to include('exactly one successful maintenance job')
        expect(outputs).to be_empty
        _stdout, stderr, status = validate(repository, candidate)
        expect(status).to be_success, stderr
        git(remote, 'update-ref', 'refs/heads/release/1.6.4', base)
        _stdout, stderr, status = validate(repository, candidate, extra: { 'RELEASE_MAIN_REF' => 'HEAD' })
        expect(status).not_to be_success
        expect(stderr).to include('not reachable')
        git(remote, 'update-ref', 'refs/heads/release/1.6.4', candidate)
        git(remote, 'update-ref', 'refs/tags/v1.6.4', base)
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script)
          expect(status).not_to be_success
          expect(stderr).to include('not release SHA')
        end
      end
    end

    it 'requires exactly one successful 1.6.4 backend job beyond the unchanged legacy rows' do
      fixture do |repository, _remote, candidate, _base|
        %w[missing skipped failure duplicate].each do |condition|
          jobs = ReleaseProfile::MAINTENANCE_JOBS.map { |name| { 'name' => name, 'conclusion' => 'success' } }
          backend = { 'name' => 'Maintenance security backends', 'conclusion' => 'success' }
          case condition
          when 'duplicate' then jobs.push(backend, backend.dup)
          when 'skipped', 'failure' then jobs << backend.merge('conclusion' => condition)
          end
          _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: jobs)
          expect(status).not_to be_success
          expect(stderr).to include('exactly one successful maintenance job "Maintenance security backends"')
          expect(outputs).to be_empty
        end
      end
    end

    it 'refuses ancestry outside the fixed 1.6.3 base' do
      fixture do |repository, _remote, candidate, _base|
        path = File.join(repository, 'script/release_profile.rb')
        File.write(path, File.read(path).sub(/V1_PATCH_BASE = '[0-9a-f]{40}'/,
                                             "V1_PATCH_BASE = '#{git(repository, 'rev-parse', 'HEAD')}'"))
        git(repository, 'add', '.')
        git(repository, 'commit', '-m', 'invalid 1.6.4 base fixture')
        _stdout, stderr, status = validate(repository, candidate)
        expect(status).not_to be_success
        expect(stderr).to include('does not descend from approved v1.6.3 base')
      end
    end
  end

  context 'with the disabled 2.0.1 maintenance profile' do
    let(:release_tag) { 'v2.0.1' }
    let(:base_version) { '2.0.0' }
    let(:profile_prefix) { 'V2_MAINTENANCE' }
    let(:v2_jobs) do
      source = File.read(File.join(root, 'script/validate-release-run'))
      names = eval(source[/REQUIRED_CI_JOBS = (\{.*?\})\.freeze/m, 1]) # rubocop:disable Security/Eval
      names.values.map { |name| { 'name' => name, 'conclusion' => 'success' } }
    end

    it 'binds only the final 2.0.1 tag to its fixed branch and immutable 2.0.0 base' do
      expect(ReleaseProfile.maintenance?(release_tag)).to be(true)
      expect(ReleaseProfile.branch(release_tag)).to eq('release/2.0.1')
      expect(ReleaseProfile.base(release_tag)).to eq('838252a79b89846937be6dbd21e283fa7cad897f')
      expect(ReleaseProfile::V2_MAINTENANCE_APPROVED_SHA).to be_nil
      expect { ReleaseProfile.validate_candidate!(release_tag, 'a' * 40) }
        .to raise_error(ReleaseProfile::Error, /disabled until/)
      %w[v2.0.1.alpha v2.0.1.rc1 v2.0.2].each do |tag|
        expect(ReleaseProfile.maintenance?(tag)).to be(false)
        expect(ReleaseProfile.branch(tag)).to eq('main')
      end
    end

    it 'accepts an exactly approved candidate outside main using normal v2 CI and package tests' do
      fixture do |repository, _remote, candidate, _base|
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script)
          expect(status).to be_success, stderr
        end
        _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: v2_jobs)
        expect(status).to be_success, stderr
        expect(outputs).to include('package-spec=spec/integration/packaged_gem_spec.rb', 'maintenance-release=true')
        expect(outputs.lines(chomp: true)).to include('package-mcp-floor=')
      end
    end

    it 'refuses unapproved candidate bytes in every validator' do
      fixture do |repository, _remote, candidate, base|
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, base, script: script)
          expect(status).not_to be_success
          expect(stderr).to include('differs from the approved maintenance SHA')
        end
        _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: v2_jobs, sha: base)
        expect(status).not_to be_success
        expect(stderr).to include('differs from the approved maintenance SHA')
        expect(outputs).to be_empty
      end
    end

    it 'keeps every validator disabled when the trusted prepared-SHA pin is absent' do
      fixture do |repository, _remote, candidate, _base|
        path = File.join(repository, 'script/release_profile.rb')
        profile = File.read(path).sub(/V2_MAINTENANCE_APPROVED_SHA = '[0-9a-f]{40}'/,
                                      'V2_MAINTENANCE_APPROVED_SHA = nil')
        File.write(path, profile)
        git(repository, 'add', '.')
        git(repository, 'commit', '-m', 'disable v2 fixture profile')
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script)
          expect(status).not_to be_success
          expect(stderr).to include('disabled until its prepared SHA is approved')
        end
        _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: v2_jobs)
        expect(status).not_to be_success
        expect(stderr).to include('disabled until its prepared SHA is approved')
        expect(outputs).to be_empty
      end
    end

    it 'does not let the caller replace the fixed branch or execute candidate-checkout validation' do
      fixture do |repository, remote, candidate, _base|
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script, trusted: false)
          expect(status).not_to be_success
          expect(stderr).to match(/trusted-checkout|checked-out HEAD/)
        end
        git(remote, 'update-ref', 'refs/heads/main', candidate)
        git(remote, 'update-ref', '-d', 'refs/heads/release/2.0.1')
        _stdout, stderr, status = validate(repository, candidate, extra: { 'RELEASE_MAIN_REF' => 'refs/heads/main' })
        expect(status).not_to be_success
        expect(stderr).to include('refs/heads/release/2.0.1')
      end
    end

    it 'cannot substitute the legacy job set for required v2 backend, transport and dependency checks' do
      fixture do |repository, _remote, candidate, _base|
        _stdout, stderr, status, outputs = validate_run(repository, candidate)
        expect(status).not_to be_success
        expect(stderr).to include('live-backends')
        expect(outputs).to be_empty
        ['MCP transports', 'Minimum runtime dependencies'].each do |missing|
          jobs = v2_jobs.reject { |job| job['name'].start_with?(missing) }
          _stdout, stderr, status, outputs = validate_run(repository, candidate, jobs: jobs)
          expect(status).not_to be_success
          expect(stderr).to include(missing)
          expect(outputs).to be_empty
        end
      end
    end

    it 'refuses a moved branch or tag after the initial validation succeeds' do
      fixture do |repository, remote, candidate, base|
        _stdout, stderr, status = validate(repository, candidate)
        expect(status).to be_success, stderr
        git(remote, 'update-ref', 'refs/heads/release/2.0.1', base)
        _stdout, stderr, status = validate(repository, candidate)
        expect(status).not_to be_success
        expect(stderr).to include('not reachable')
        git(remote, 'update-ref', 'refs/heads/release/2.0.1', candidate)
        git(remote, 'update-ref', 'refs/tags/v2.0.1', base)
        %w[validate-release verify-release-tag].each do |script|
          _stdout, stderr, status = validate(repository, candidate, script: script)
          expect(status).not_to be_success
          expect(stderr).to include('not release SHA')
        end
      end
    end

    it 'refuses an unrelated base and names the v2 base instead of the legacy line' do
      fixture do |repository, _remote, candidate, _base|
        path = File.join(repository, 'script/release_profile.rb')
        source = File.read(path).sub(/V2_MAINTENANCE_BASE = '[0-9a-f]{40}'/,
                                     "V2_MAINTENANCE_BASE = '#{git(repository, 'rev-parse', 'HEAD')}'")
        File.write(path, source)
        git(repository, 'add', '.')
        git(repository, 'commit', '-m', 'invalid v2 base fixture')
        _stdout, stderr, status = validate(repository, candidate)
        expect(status).not_to be_success
        expect(stderr).to include('does not descend from approved v2.0.0 base')
      end
    end
  end
end
