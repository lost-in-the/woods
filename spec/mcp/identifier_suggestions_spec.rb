# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/identifier_suggestions'

RSpec.describe Woods::MCP::IdentifierSuggestions do
  def entry(identifier, type, file_path = nil)
    { 'identifier' => identifier, 'type' => type, 'file_path' => file_path }
  end

  let(:entries) do
    [
      entry('Billing::Subscription', 'model', 'app/models/billing/subscription.rb'),
      entry('Billing::SubscriptionChange', 'model', 'app/models/billing/subscription_change.rb'),
      entry('SubscriptionsController', 'controller', 'app/controllers/subscriptions_controller.rb'),
      entry('Api::V1::SubscriptionsController', 'controller', 'app/controllers/api/v1/subscriptions_controller.rb'),
      entry('Subscriber', 'model', 'app/models/subscriber.rb'),
      entry('Order', 'model', 'app/models/order.rb'),
      entry('Order', 'serializer', 'app/serializers/order.rb'),
      entry('GET /orders', 'route', 'config/routes.rb')
    ]
  end

  def identifiers(query, **options)
    described_class.for(query, entries, **options).map { |suggestion| suggestion[:identifier] }
  end

  it 'finds a namespaced unit from its short name' do
    expect(described_class.for('Subscription', entries).first)
      .to eq(identifier: 'Billing::Subscription', type: 'model')
  end

  it 'finds a unit from a partial namespace' do
    expect(identifiers('V1::SubscriptionsController'))
      .to eq(%w[Api::V1::SubscriptionsController SubscriptionsController])
  end

  it 'ignores case and underscores' do
    expect(identifiers('billing::subscription_change')).to eq(['Billing::SubscriptionChange'])
    expect(identifiers('subscriber')).to eq(['Subscriber'])
  end

  it 'names the owner of a Class#method or Class.method reference' do
    expect(identifiers('SubscriptionsController#create').first).to eq('SubscriptionsController')
    expect(identifiers('Subscriber.active')).to eq(['Subscriber'])
  end

  it 'ranks the exact owner ahead of a namespaced unit with the same short name' do
    expect(identifiers('SubscriptionsController#create'))
      .to eq(%w[SubscriptionsController Api::V1::SubscriptionsController])
  end

  it 'lists every type an identifier is published under' do
    expect(described_class.for('Order', entries))
      .to eq([{ identifier: 'Order', type: 'model' }, { identifier: 'Order', type: 'serializer' }])
  end

  it 'finds the units published from a file path' do
    expect(identifiers('app/models/billing/subscription.rb')).to eq(['Billing::Subscription'])
    expect(identifiers('./app/models/subscriber.rb:42')).to eq(['Subscriber'])
    expect(identifiers('/srv/app/app/models/subscriber.rb')).to eq(['Subscriber'])
    expect(identifiers('models/subscriber.rb')).to eq(['Subscriber'])
  end

  it 'does not match a path against a file that merely ends with the same letters' do
    expect(identifiers('app/models/bscriber.rb')).to eq([])
  end

  it 'corrects a misspelled name' do
    expect(identifiers('Subscripton')).to include('Billing::Subscription')
    expect(identifiers('Billing::Subscriptoin')).to include('Billing::Subscription')
  end

  it 'returns nothing for a name unlike any identifier' do
    expect(identifiers('Zeppelin')).to eq([])
    expect(identifiers('')).to eq([])
    expect(identifiers(nil)).to eq([])
  end

  it 'honours the limit' do
    many = Array.new(9) { |index| entry("Ns#{index}::Widget", 'model') }
    expect(described_class.for('Widget', many).size).to eq(5)
    expect(described_class.for('Widget', many, limit: 2).size).to eq(2)
  end

  it 'skips malformed entries' do
    expect(described_class.for('Order', [nil, {}, { 'identifier' => 1 }, entry('Order', 'model')]))
      .to eq([{ identifier: 'Order', type: 'model' }])
  end

  describe '.sentence' do
    it 'is nil without suggestions' do
      expect(described_class.sentence([])).to be_nil
    end

    it 'names each suggestion with its type' do
      expect(described_class.sentence([{ identifier: 'Order', type: 'model' }, { identifier: 'X', type: nil }]))
        .to eq('Did you mean: Order (model), X?')
    end
  end
end
