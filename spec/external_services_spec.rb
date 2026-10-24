# frozen_string_literal: true

require 'spec_helper'
require 'woods/external_services'

RSpec.describe Woods::ExternalServices do
  describe '.from_gems' do
    it 'names the services whose client gem the Gemfile declares for runtime, with the gems as evidence' do
      gems = [{ name: 'rails', groups: [] }, { name: 'stripe', groups: [] },
              { name: 'aws-sdk-s3', groups: ['production'] }, { name: 'sentry-ruby', groups: %w[default] },
              { name: 'twilio-ruby', groups: %w[development test] }, { 'name' => 'faraday', 'groups' => [] }]
      expect(described_class.from_gems(gems)).to eq(
        [{ name: 'Amazon S3', category: 'storage', gems: ['aws-sdk-s3'] },
         { name: 'Sentry', category: 'monitoring', gems: ['sentry-ruby'] },
         { name: 'Stripe', category: 'payments', gems: ['stripe'] }]
      )
    end

    it 'publishes nothing for unknown gems or none' do
      expect(described_class.from_gems([{ name: 'my-internal-gem', groups: [] }])).to eq([])
      expect(described_class.from_gems(nil)).to eq([])
    end
  end

  describe '.dependencies' do
    it 'records a call through a client constant as an edge to its service' do
      source = <<~RUBY
        class ChargeCustomer
          def call = Stripe::Charge.create(amount: 100)
          def upload = Aws::S3::Client.new.put_object(bucket: "b")
          def report(e) = Sentry.capture_exception(e)
        end
      RUBY
      expect(described_class.dependencies(source)).to eq(
        [{ type: :external_service, target: 'Stripe', via: :service_call },
         { type: :external_service, target: 'Amazon S3', via: :service_call },
         { type: :external_service, target: 'Sentry', via: :service_call }]
      )
    end

    it 'ignores look-alike names and constants that are not called through' do
      source = "class StripeCustomer < MyStripe::Base\n  STRIPE = 1\n  def x = Stripe\nend\n"
      expect(described_class.dependencies(source)).to eq([])
      expect(described_class.dependencies('')).to eq([])
    end
  end
end
