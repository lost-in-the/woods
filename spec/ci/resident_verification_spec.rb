# frozen_string_literal: true

require 'spec_helper'
require_relative '../../script/verification/resident_journey'

RSpec.describe WoodsVerification::ResidentJourney do
  let(:checks) { described_class::EXPECTED_CHECKS.map { |name| { 'name' => name, 'passed' => true } } }
  let(:report) { { 'status' => 'passed', 'checks' => checks } }

  it 'accepts complete successful evidence' do
    expect { described_class.verify_report!(report) }.not_to raise_error
  end

  it 'rejects a zero-work successful report' do
    expect { described_class.verify_report!({ 'status' => 'passed', 'checks' => [] }) }
      .to raise_error(WoodsVerification::AssertionFailure)
  end

  it 'does not mistake a harness failure for a successful fault control' do
    report = { 'status' => 'failed_harness', 'error' => 'cold process failed' }
    expect { described_class.verify_report!(report, negative_control: true) }
      .to raise_error(WoodsVerification::HarnessError)
  end

  it 'accepts only the intended stale generation fault after baseline controls pass' do
    faulty_checks = checks.take(5)
    faulty_checks.last['passed'] = false
    fault = { 'status' => 'failed_assertion', 'error' => 'edit advances publication',
              'checks' => faulty_checks, 'phases' => [{ 'generation' => 1, 'differences' => ['stale helper'] }] }
    expect { described_class.verify_report!(fault, negative_control: true) }.not_to raise_error
    fault['checks'].first['passed'] = false
    expect { described_class.verify_report!(fault, negative_control: true) }
      .to raise_error(WoodsVerification::HarnessError)
  end
end
