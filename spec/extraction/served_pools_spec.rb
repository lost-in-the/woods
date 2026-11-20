# frozen_string_literal: true

require 'spec_helper'
require 'active_support'
require 'active_support/notifications'
require 'woods/extraction/served_pools'

RSpec.describe Woods::Extraction::ServedPools do
  let(:pool) { Object.new }
  let(:other_pool) { Object.new }
  let(:connection) { double('Connection', pool: pool) }

  def query(payload)
    ActiveSupport::Notifications.instrument(described_class::EVENT, payload)
  end

  it 'records the pool of a query that finished during the block' do
    served = described_class.during do |tracker|
      query(sql: 'SELECT 1', connection: connection)
      tracker
    end

    expect(served.served?(pool)).to be(true)
    expect(served.served?(other_pool)).to be(false)
  end

  it 'does not count a query that raised' do
    served = described_class.during do |tracker|
      query(sql: 'SELECT 1', connection: connection, exception: ['ActiveRecord::StatementInvalid', 'locked'])
      tracker
    end

    expect(served.served?(pool)).to be(false)
  end

  it 'ignores a query another thread finishes during the block, as an application thread would' do
    served = described_class.during do |tracker|
      Thread.new { query(sql: 'SELECT 1', connection: connection) }.join
      tracker
    end

    expect(served.served?(pool)).to be(false)
  end

  it 'records a query of a thread the run starts through it' do
    served = described_class.during do |tracker|
      described_class.thread { query(sql: 'SELECT 1', connection: connection) }.join
      tracker
    end

    expect(served.served?(pool)).to be(true)
  end

  it 'records a query the calling thread runs inside a fiber' do
    served = described_class.during do |tracker|
      Fiber.new { query(sql: 'SELECT 1', connection: connection) }.resume
      tracker
    end

    expect(served.served?(pool)).to be(true)
  end

  it 'starts a thread that runs its block when no run is tracking the caller' do
    expect(described_class.thread { :ran }.value).to eq(:ran)
  end

  it 'stops counting the calling thread when the block returns' do
    served = described_class.during { |tracker| tracker }
    served.note(sql: 'SELECT 1', connection: connection)

    expect(served.served?(pool)).to be(false)
  end

  it 'stops listening when the block returns' do
    served = described_class.during { |tracker| tracker }
    query(sql: 'SELECT 1', connection: connection)

    expect(served.served?(pool)).to be(false)
  end

  it 'stops listening when the block raises' do
    tracker = nil
    expect do
      described_class.during do |served|
        tracker = served
        raise ArgumentError, 'boom'
      end
    end.to raise_error(ArgumentError)
    query(sql: 'SELECT 1', connection: connection)

    expect(tracker.served?(pool)).to be(false)
  end
end
