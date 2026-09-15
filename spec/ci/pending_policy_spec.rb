# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tempfile'

RSpec.describe 'CI pending policy' do
  def run_example(body, ci_value: 'true')
    Tempfile.create(['woods-pending-policy', '.rb']) do |file|
      file.write("RSpec.describe('policy probe') { #{body} }")
      file.flush
      Open3.capture3({ 'CI' => ci_value, 'COVERAGE' => nil }, RbConfig.ruby,
                     Gem.bin_path('rspec-core', 'rspec'), '--options', File::NULL,
                     '--require', File.expand_path('../support/pending_policy.rb', __dir__), file.path)
    end
  end

  it 'fails CI for a newly skipped example' do
    output, errors, status = run_example("it('new skip') { skip 'not implemented' }")
    expect(status.exitstatus).to eq(1), output + errors
    expect(output + errors).to include('Unexpected pending examples', 'new skip', 'not implemented')
  end

  it 'fails CI for xit and pending metadata' do
    ['xit(\'disabled\') {}', "it('disabled', pending: 'later') { raise 'known failure' }"].each do |body|
      output, errors, status = run_example(body)
      expect(status.exitstatus).to eq(1), output + errors
      expect(output + errors).to include('Unexpected pending examples')
    end
  end

  it 'does not alter local pending behavior' do
    output, errors, status = run_example("it('local skip') { skip 'local experiment' }", ci_value: nil)
    expect(status.exitstatus).to eq(0), output + errors
  end

  it 'does not accept a reviewed reason on an unrelated example' do
    output, errors, status = run_example("it('unrelated') { skip 'tokenizers gem not installed' }")
    expect(status.exitstatus).to eq(1), output + errors
  end

  it 'keeps ordinary passing examples green in CI' do
    output, errors, status = run_example("it('passes') { expect(1).to eq(1) }")
    expect(status.exitstatus).to eq(0), output + errors
  end
end

RSpec.describe PendingPolicy do
  def pending_example(file:, description:, reason:)
    double(metadata: { file_path: File.join(described_class::ROOT, file) }, full_description: description,
           execution_result: double(pending_message: reason))
  end

  it 'accepts only the exact reviewed example and reason while the capability is unavailable' do
    file, description, reason, = described_class::ENTRIES.first
    hide_const('Tokenizers')
    expect(described_class.allowed?(pending_example(file: file, description: description, reason: reason))).to be true
    expect(described_class.allowed?(pending_example(file: file, description: description, reason: 'other'))).to be false
    expect(described_class.allowed?(pending_example(file: file, description: 'other', reason: reason))).to be false
    expect(described_class.allowed?(pending_example(file: 'spec/other.rb', description: description,
                                                    reason: reason))).to be false
    stub_const('Tokenizers', Module.new)
    expect(described_class.allowed?(pending_example(file: file, description: description, reason: reason))).to be false
  end
end
