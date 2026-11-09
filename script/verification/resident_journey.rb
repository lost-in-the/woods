# frozen_string_literal: true

require_relative 'journey'

module WoodsVerification
  class ResidentJourney < Journey
    VERIFIER_ROOT = File.expand_path('../..', __dir__)
    RESIDENT_FIXTURE = File.join(VERIFIER_ROOT, 'spec/fixtures/verification_resident/boot.rb')
    EXPECTED_CHECKS = [
      'independent full/full baseline agrees', 'resident baseline agrees with independent cold full',
      'baseline contains both concerns', 'edit unloads views namespace', 'edit advances publication',
      'edit retains both concerns', 'edit matches independent cold full', 'restore unloads views namespace',
      'restore advances publication', 'restore retains both concerns', 'restore matches independent cold full'
    ].freeze

    def initialize(**args)
      super
      @receipt[:journey] = 'resident-reload-independent-cold-full'
      @receipt[:issue] = 'https://github.com/lost-in-the/woods/issues/1040'
      @receipt[:limits] = [
        'Synthetic helper edit and restoration; native watcher and private client application are untested.',
        'Parity uses candidate IndexComparison exclusions; it does not compare every freshness/reader field.',
        'No installed package, other Rails versions, hosted CI or merge-policy verification.'
      ]
    end

    def self.verify_report!(observed, negative_control: false)
      raise HarnessError, 'Resident report is not an object' unless observed.is_a?(Hash)
      raise HarnessError, observed['error'] if observed['status'] == 'failed_harness'
      return verify_negative!(observed) if negative_control

      expected = EXPECTED_CHECKS.map { |name| { 'name' => name, 'passed' => true } }
      valid = observed['status'] == 'passed' && observed['checks'] == expected
      raise AssertionFailure, "Resident verification failed: #{observed.fetch('error', 'missing checks')}" unless valid
    end

    def self.verify_negative!(observed)
      expected = EXPECTED_CHECKS.take(5).map { |name| { 'name' => name, 'passed' => true } }
      expected.last['passed'] = false
      assertion = observed.values_at('status', 'error') == ['failed_assertion', 'edit advances publication']
      phase = observed.fetch('phases', []).first || {}
      stale = stale_phase?(phase)
      return if assertion && observed['checks'] == expected && stale

      raise HarnessError, 'Resident negative control did not produce the expected stale publication'
    end

    def self.stale_phase?(phase)
      phase['generation'] == 1 && phase['differences'].is_a?(Array) && !phase['differences'].empty?
    end

    private

    def identity
      files = Dir.glob(File.join(VERIFIER_ROOT, 'script/verification/*.rb')) +
              [RESIDENT_FIXTURE, File.join(VERIFIER_ROOT, 'script/verify-resident-journey')]
      verifier = files.map { |path| [path, Digest::SHA256.file(path).hexdigest] }
      super.merge(verifier_digest: Digest::SHA256.hexdigest(JSON.generate(verifier)))
    end

    def drive(fixture_root)
      command = [RbConfig.ruby, '-Ilib', RESIDENT_FIXTURE, fixture_root, 'resident',
                 File.join(fixture_root, 'tmp/index')]
      command << 'skip_incremental' if @negative_control
      observed = execute('resident', command)
      @receipt[:observations] = [observed]
      checkpoint!
      self.class.verify_report!(observed, negative_control: @negative_control)
    end
  end
end
