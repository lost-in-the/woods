# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

RSpec.describe 'Application-owned optional extraction', :booted_app do
  it 'keeps components, mailers and schedules consistent through every writer path' do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/component_ownership/boot.rb')
    expect(status).to be_success, "#{stdout}\n#{stderr}"
    expected = [
      'legacy fixture contains external definitions',
      'inflected components under an autoload-only views root are discovered',
      'Kit calls and sibling renders target qualified component units',
      'authoritative reconciliation removes only dependency-owned definitions',
      'all application mailer inheritance branches are indexed without execution',
      'ownership full/incremental equivalence',
      'component and mailer edits full/incremental equivalence',
      'component and mailer refresh equivalence',
      'a sidecar template edit retargets its component',
      'sidecar template edit full/incremental equivalence',
      'conflicting schedules retain jobs and qualified identities',
      'schedule collision addition equivalence',
      'schedule refresh equivalence',
      'collision removal restores legacy identity without stale nodes',
      'schedule collision deletion equivalence',
      'ambiguous schedule failure retains prior generation in every mode'
    ]
    expect(JSON.parse(stdout.lines.last).fetch('checks')).to eq(expected)
  end
end
