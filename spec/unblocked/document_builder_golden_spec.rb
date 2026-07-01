# frozen_string_literal: true

require 'spec_helper'
require 'woods/unblocked/document_builder'
require_relative '../fixtures/unblocked/golden_units'

# Golden-output regression: pins DocumentBuilder's EXACT body bytes per unit
# type. Unblocked detects changes by hashing the rendered body
# (Exporter#fingerprint), so any drift in this output forces a one-time mass
# re-push on the next sync. These specs are the safety net for the B-057
# UnitFacts refactor — they must stay green through it.
#
# To intentionally change the output, regenerate with REGENERATE_GOLDEN=1 and
# review the diff before committing.
RSpec.describe 'Woods::Unblocked::DocumentBuilder golden output' do
  let(:builder) { Woods::Unblocked::DocumentBuilder.new(repo_url: 'https://github.com/org/repo') }
  golden_dir = File.expand_path('../fixtures/unblocked/golden', __dir__)

  GoldenUnits.all.each do |name, unit|
    it "renders the #{name} body byte-for-byte as the golden master" do
      body = builder.build(unit)[:body]
      path = File.join(golden_dir, "#{name}.md")
      File.write(path, body) if ENV['REGENERATE_GOLDEN']
      expect(body).to eq(File.read(path, encoding: 'UTF-8'))
    end
  end
end
