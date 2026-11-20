# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/service_extractor'
require 'woods/extractors/configuration_extractor'
require 'woods/source_inputs/consumer_errors'

RSpec.describe Woods::SourceInputs::ConsumerErrors do
  include_context 'extractor setup'

  it 'distinguishes a handled empty result from a successful negative match on separate consumers' do
    file = create_file('app/services/pay.rb', 'class Pay; def call; end; end')
    failed = Woods::Extractors::ServiceExtractor.new
    unaffected = Woods::Extractors::ServiceExtractor.new
    allow(failed).to receive(:extract_metadata).and_raise(IOError, 'fixture metadata failure')
    expect(logger).to receive(:error).with("Failed to extract service #{file}: fixture metadata failure")

    results = [failed, unaffected].map { |consumer| Thread.new { consumer.extract_all } }.map(&:value)
    expect(results.first).to eq([])
    expect(results.last.map(&:identifier)).to eq(['Pay'])
    expect(described_class.failed?(failed)).to be(true)
    expect(described_class.failed?(unaffected)).to be(false)

    File.write(file, "module Pay\nend\n")
    expect(unaffected.extract_all).to eq([])
    expect(described_class.failed?(unaffected)).to be(false)
  end

  describe '.log' do
    let(:not_established) { stub_const('ActiveRecord::ConnectionNotEstablished', Class.new(StandardError)) }
    let(:checkout_timeout) { stub_const('ActiveRecord::ConnectionTimeoutError', Class.new(not_established)) }
    let(:statement_invalid) { stub_const('ActiveRecord::StatementInvalid', Class.new(StandardError)) }
    let(:no_database) { stub_const('ActiveRecord::NoDatabaseError', Class.new(statement_invalid)) }
    let(:pool) { Object.new }
    let(:served) { ->(candidate) { candidate.equal?(pool) } }
    let(:unserved) { ->(_candidate) { false } }

    before do
      checkout_timeout
      no_database
    end

    def log_while_handling(error, **options)
      consumer = Object.new
      begin
        raise error
      rescue StandardError
        described_class.log(consumer, 'handled', **options)
      end
      consumer
    end

    # Rails 7.1 and later attach the pool a checkout waited for to the error.
    def timeout_on(waited_for)
      on_pool(checkout_timeout.new('could not obtain a connection'), waited_for)
    end

    def on_pool(error, pool)
      error.tap { error.define_singleton_method(:connection_pool) { pool } }
    end

    it 'refuses a pool-less checkout timeout (Rails before 7.1) on the answering pool the handler names' do
      consumer = log_while_handling(checkout_timeout.new('could not obtain a connection'), pool: pool)

      expect(described_class.schema_failed?(consumer, served)).to be(true)
      expect(described_class.schema_failed?(consumer, unserved)).to be(false)
    end

    it "refuses on the pool a checkout timeout carries, not the handler's, when only that pool answered" do
      consumer = log_while_handling(timeout_on(pool), pool: Object.new)

      expect(described_class.schema_failed?(consumer, served)).to be(true)
    end

    it "lets a checkout timeout carrying an unanswered pool publish, though the handler's pool answered" do
      handler_pool = Object.new
      consumer = log_while_handling(timeout_on(pool), pool: handler_pool)

      expect(described_class.schema_failed?(consumer, ->(candidate) { candidate.equal?(handler_pool) })).to be(false)
    end

    it "refuses on the handler's pool when the error answers that it carries no pool (Rails 7.1 and later)" do
      consumer = log_while_handling(timeout_on(nil), pool: pool)

      expect(described_class.schema_failed?(consumer, served)).to be(true)
    end

    it 'passes the message alone to the logger when the handler names a pool' do
      expect(logger).to receive(:error).with('handled')

      log_while_handling(checkout_timeout.new('could not obtain a connection'), pool: pool)
    end

    it 'refuses a connection that failed on a pool that answered another query in the run' do
      consumer = log_while_handling(on_pool(not_established.new('too many connections'), pool))

      expect(described_class.schema_failed?(consumer, served)).to be(true)
    end

    it 'lets a connection that failed on a pool that answered nothing in the run publish' do
      consumer = log_while_handling(on_pool(not_established.new('refused'), pool))

      expect(described_class.failed?(consumer)).to be(true)
      expect(described_class.schema_failed?(consumer, unserved)).to be(false)
    end

    it 'refuses a checkout that timed out on a pool that answered another query in the run' do
      expect(described_class.schema_failed?(log_while_handling(timeout_on(pool)), served)).to be(true)
    end

    it 'lets a checkout that timed out on a pool that answered nothing in the run publish' do
      consumer = log_while_handling(timeout_on(pool))

      expect(described_class.failed?(consumer)).to be(true)
      expect(described_class.schema_failed?(consumer, unserved)).to be(false)
    end

    it 'lets a checkout timeout whose pool is not known publish, since no read can be shown to have reached it' do
      consumer = log_while_handling(checkout_timeout.new('pool'))

      expect(described_class.failed?(consumer)).to be(true)
      expect(described_class.schema_failed?(consumer, served)).to be(false)
    end

    it 'refuses a statement the database refused, whatever the run read before' do
      expect(described_class.schema_failed?(log_while_handling(statement_invalid.new('locked')), unserved)).to be(true)
    end

    it 'lets a connection that could not be made at all publish, recording the failure' do
      consumer = log_while_handling(not_established.new('refused'))

      expect(described_class.failed?(consumer)).to be(true)
      expect(described_class.schema_failed?(consumer, served)).to be(false)
    end

    it 'lets a database that does not exist publish, recording the failure' do
      consumer = log_while_handling(no_database.new('missing'))

      expect(described_class.failed?(consumer)).to be(true)
      expect(described_class.schema_failed?(consumer, served)).to be(false)
    end

    it 'marks only the consumer failure for an error that is not a database read' do
      consumer = log_while_handling(NameError.new('uninitialized constant Missing'))

      expect(described_class.failed?(consumer)).to be(true)
      expect(described_class.schema_failed?(consumer, served)).to be(false)
    end

    it 'clears both marks on reset' do
      consumer = log_while_handling(statement_invalid.new('locked'))
      described_class.reset(consumer)

      expect(described_class.failed?(consumer)).to be(false)
      expect(described_class.schema_failed?(consumer, served)).to be(false)
    end
  end

  it 'propagates a nested behavioral profile failure without changing its result' do
    consumer = Woods::Extractors::ConfigurationExtractor.new
    profiler = Woods::Extractors::BehavioralProfile.new
    allow(Woods::Extractors::BehavioralProfile).to receive(:new).and_return(profiler)
    allow(profiler).to receive(:extract) do
      described_class.record(profiler)
      nil
    end
    expect(consumer.extract_all).to eq([])
    expect(described_class.failed?(consumer)).to be(true)
  end
end
