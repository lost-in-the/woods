# frozen_string_literal: true

# Loaded from the trusted default-branch checkout, never from the candidate.
# Adding a maintenance release requires a reviewed main change. The final SHA
# pin binds the complete candidate tree, including its CI and package tests.
module ReleaseProfile
  class Error < StandardError; end

  MAINTENANCE_TAG = 'v1.6.3'
  MAINTENANCE_BRANCH = 'release/1.6.3'
  MAINTENANCE_BASE = '4b40e17fd68122a70ccf00d9d2ffb8af42171d3d'
  # Reviewed protected-branch candidate; all 18 required CI jobs passed in run 35675785349.
  # Any candidate change requires a new reviewed pin and fresh tag-push CI.
  MAINTENANCE_APPROVED_SHA = '60d6b7c4a3ddc421073f1fb57a7249eccb77826e'
  MAINTENANCE_JOBS = [
    'Unit specs (Ruby 3.0)',
    'Unit specs (Ruby 3.1)',
    'Unit specs (Ruby 3.2)',
    'Unit specs (Ruby 3.3)',
    'Unit specs (Ruby 4.0)',
    'Booted extraction (Ruby 3.0 / Rails 6.0)',
    'Booted extraction (Ruby 3.0 / Rails 6.1)',
    'Booted extraction (Ruby 3.1 / Rails 7.0)',
    'Booted extraction (Ruby 3.2 / Rails 7.1)',
    'Booted extraction (Ruby 3.3 / Rails 7.2)',
    'Booted extraction (Ruby 3.3 / Rails 8.0)',
    'Booted extraction (Ruby 4.0 / Rails 8.0)',
    'Installed maintenance package (Ruby 3.0 / Rails 6.0)',
    'Installed maintenance package (Ruby 4.0 / Rails 8.1)',
    'lint', 'coverage', 'security', 'build'
  ].freeze

  V2_MAINTENANCE_TAG = 'v2.0.1'
  V2_MAINTENANCE_BRANCH = 'release/2.0.1'
  V2_MAINTENANCE_BASE = '838252a79b89846937be6dbd21e283fa7cad897f'
  # Disabled until a separate reviewed main change pins the prepared candidate.
  V2_MAINTENANCE_APPROVED_SHA = nil

  module_function

  def maintenance?(tag)
    !maintenance_profile(tag).nil?
  end

  def maintenance_profile(tag)
    case tag
    when MAINTENANCE_TAG
      { branch: MAINTENANCE_BRANCH, base: MAINTENANCE_BASE, base_tag: 'v1.6.2',
        approved_sha: MAINTENANCE_APPROVED_SHA, exact_ci_jobs: MAINTENANCE_JOBS,
        package_spec: 'spec/integration/maintenance_packaged_gem_spec.rb' }
    when V2_MAINTENANCE_TAG
      { branch: V2_MAINTENANCE_BRANCH, base: V2_MAINTENANCE_BASE, base_tag: 'v2.0.0',
        approved_sha: V2_MAINTENANCE_APPROVED_SHA }
    end
  end

  def validate_candidate!(tag, sha)
    profile = maintenance_profile(tag)
    return unless profile

    approved_sha = profile.fetch(:approved_sha)
    unless approved_sha.to_s.match?(/\A[0-9a-f]{40}\z/)
      raise Error, "#{tag} maintenance release is disabled until its prepared SHA is approved in trusted main"
    end
    return if sha == approved_sha

    raise Error, "#{tag} candidate SHA #{sha} differs from the approved maintenance SHA #{approved_sha}"
  end

  def branch(tag)
    maintenance_profile(tag)&.fetch(:branch) || 'main'
  end

  def base(tag)
    maintenance_profile(tag)&.fetch(:base)
  end

  def base_tag(tag)
    maintenance_profile(tag)&.fetch(:base_tag)
  end

  def exact_ci_jobs(tag)
    maintenance_profile(tag)&.fetch(:exact_ci_jobs, nil)
  end

  def package_spec(tag)
    maintenance_profile(tag)&.fetch(:package_spec, nil) || 'spec/integration/packaged_gem_spec.rb'
  end
end
