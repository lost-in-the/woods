# frozen_string_literal: true

# Loaded from the trusted default-branch checkout, never from the candidate.
# Adding a maintenance release requires a reviewed main change. The final SHA
# pin binds the complete candidate tree, including its CI and package tests.
module ReleaseProfile
  class Error < StandardError; end

  MAINTENANCE_TAG = 'v1.6.2'
  MAINTENANCE_BRANCH = 'release/1.6.2'
  MAINTENANCE_BASE = '73423a42644176b09961be373e13648c94690933'
  # Prepared and reviewed in maintenance PR #464; pin the protected branch's
  # exact merge commit, never a moving branch tip or caller-supplied revision.
  MAINTENANCE_APPROVED_SHA = '4b40e17fd68122a70ccf00d9d2ffb8af42171d3d'
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

  module_function

  def maintenance?(tag)
    tag == MAINTENANCE_TAG
  end

  def validate_candidate!(tag, sha)
    return unless maintenance?(tag)

    unless MAINTENANCE_APPROVED_SHA.to_s.match?(/\A[0-9a-f]{40}\z/)
      raise Error, "#{tag} maintenance release is disabled until its prepared SHA is approved in trusted main"
    end
    return if sha == MAINTENANCE_APPROVED_SHA

    raise Error, "#{tag} candidate SHA #{sha} differs from the approved maintenance SHA #{MAINTENANCE_APPROVED_SHA}"
  end

  def branch(tag)
    maintenance?(tag) ? MAINTENANCE_BRANCH : 'main'
  end

  def package_spec(tag)
    if maintenance?(tag)
      'spec/integration/maintenance_packaged_gem_spec.rb'
    else
      'spec/integration/packaged_gem_spec.rb'
    end
  end
end
