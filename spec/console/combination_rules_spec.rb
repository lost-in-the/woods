# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'active_support/core_ext/string/inflections'
require 'woods/console/embedded_executor'
require 'woods/console/server'

# `console_find` and `console_aggregate` each carry one cross-argument rule as
# a top-level combinator in their authoritative schema. `tools/list` serves a
# copy without it, so the SDK's pre-dispatch check no longer sees the rule.
# These examples prove the rule is still refused at runtime, by the unchanged
# authoritative schema, and that the refusal names its code, argument and hint.
RSpec.describe 'Console cross-argument rules after the advertised schema drops its combinators' do
  let(:validator) { Woods::Console::ModelValidator.new(registry: { 'Post' => %w[id title status] }) }
  let(:connection) { double('Connection', adapter_name: 'SQLite', execute: nil) }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }
  let(:post_model) { double('Post model') }
  let(:record) { double('Post record', attributes: { 'id' => 1, 'title' => 'Alpha', 'status' => 10 }) }
  let(:server) do
    Woods::Console::Server.build_embedded(model_validator: validator, safe_context: safe_context,
                                          connection: connection)
  end
  let(:specs_by_name) { Woods::Console::Server::TOOL_SPECS.to_h { |spec| [spec.name, spec] } }

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    stub_const('Post', post_model)
    allow(post_model).to receive(:find_by).and_return(record)
    allow(post_model).to receive_messages(sum: 60, count: 3, all: post_model, to_sql: 'SELECT posts.* FROM posts')
  end

  def tools_call(name, arguments)
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                           params: { name: name, arguments: arguments }))
    JSON.parse(raw).fetch('result')
  end

  # The message the authoritative schema itself gives for these arguments.
  def authoritative_refusal(name, arguments)
    MCP::Tool::InputSchema.new(specs_by_name.fetch(name).input_schema)
                          .validate_arguments(JSON.parse(JSON.generate(arguments)))
    nil
  rescue MCP::Tool::InputSchema::ValidationError => e
    e.message
  end

  def rule_meta(name, rule)
    { 'error_code' => rule[:code], 'tool' => name, 'argument' => rule[:argument], 'hint' => rule[:hint] }
  end

  it 'keeps both combinators in the authoritative schema and only there' do
    find = specs_by_name.fetch('console_find')
    aggregate = specs_by_name.fetch('console_aggregate')

    expect(find.input_schema[:oneOf]).to eq([{ required: ['id'] }, { required: ['by'] }])
    expect(aggregate.input_schema[:allOf].first[:then]).to eq(required: ['column'])
    expect(find.advertised_input_schema).to eq(find.input_schema.except(:oneOf))
    expect(aggregate.advertised_input_schema).to eq(aggregate.input_schema.except(:allOf))
  end

  describe 'console_find: exactly one of id or by' do
    let(:rule) { Woods::Console::Server::FIND_LOCATOR_RULE }

    # Truth table over the two locators. by: {} is a near miss: present but
    # empty, refused by the property's own minProperties, not by the rule.
    [
      [{ id: 1 }, :allowed],
      [{ by: { 'title' => 'Alpha' } }, :allowed],
      [{ id: 1, by: { 'title' => 'Alpha' } }, :rule_refusal],
      [{}, :rule_refusal],
      [{ by: {} }, :property_refusal]
    ].each do |locators, outcome|
      it "#{outcome} for #{locators.keys.inspect}" do
        arguments = { model: 'Post' }.merge(locators)
        result = tools_call('console_find', arguments)

        case outcome
        when :allowed
          expect(result['isError']).to be(false), result.inspect
          expect(result.dig('content', 0, 'text')).to include('record')
        when :rule_refusal
          message = authoritative_refusal('console_find', arguments)
          expect(message).to start_with('Invalid arguments:')
          expect(result).to eq(
            'content' => [{ 'type' => 'text', 'text' => "#{message}\nHint: #{rule[:hint]}" }],
            'isError' => true,
            '_meta' => rule_meta('console_find', rule)
          )
          expect(post_model).not_to have_received(:find_by)
        when :property_refusal
          expect(result['isError']).to be(true)
          expect(result.dig('content', 0, 'text')).to start_with('Invalid arguments:')
          expect(result.dig('content', 0, 'text')).not_to include('Hint:')
          expect(result).not_to have_key('_meta')
        end
      end
    end

    it 'leaves an unknown locator column to the column check, not to the rule' do
      result = tools_call('console_find', model: 'Post', by: { 'nickname' => 'x' })

      expect(result['isError']).to be(true)
      expect(result.dig('content', 0, 'text')).to include('nickname')
      expect(result.fetch('_meta', {})).not_to include('error_code' => rule[:code])
    end
  end

  describe 'console_aggregate: column required for sum, average, minimum and maximum' do
    let(:rule) { Woods::Console::Server::AGGREGATE_COLUMN_RULE }

    # Truth table over function x column presence.
    {
      %w[count absent] => :allowed,
      %w[count present] => :allowed,
      %w[sum present] => :allowed,
      %w[sum absent] => :rule_refusal,
      %w[average absent] => :rule_refusal,
      %w[minimum absent] => :rule_refusal,
      %w[maximum absent] => :rule_refusal
    }.each do |(function, column), outcome|
      it "#{outcome} for #{function} with column #{column}" do
        arguments = { model: 'Post', function: function }
        arguments[:column] = 'status' if column == 'present'
        allow(post_model).to receive_messages(average: 20, minimum: 10, maximum: 30)
        result = tools_call('console_aggregate', arguments)

        if outcome == :allowed
          expect(result['isError']).to be(false), result.inspect
          expect(result.dig('content', 0, 'text')).to include('value')
        else
          message = authoritative_refusal('console_aggregate', arguments)
          expect(message).to start_with('Invalid arguments:')
          expect(result).to eq(
            'content' => [{ 'type' => 'text', 'text' => "#{message}\nHint: #{rule[:hint]}" }],
            'isError' => true,
            '_meta' => rule_meta('console_aggregate', rule)
          )
          expect(post_model).not_to have_received(function.to_sym)
        end
      end
    end

    it 'leaves a missing function to the required-argument check, not to the rule' do
      result = tools_call('console_aggregate', model: 'Post')

      expect(result).to eq(
        'content' => [{ 'type' => 'text', 'text' => 'Missing required arguments: function' }],
        'isError' => true
      )
    end
  end

  describe 'executor refusal shape' do
    let(:executor) { Woods::Console::EmbeddedExecutor.new(model_validator: validator, safe_context: safe_context) }

    it 'returns code, argument and hint beside the message for a rule refusal' do
      rule = Woods::Console::Server::FIND_LOCATOR_RULE
      response = executor.send_request('tool' => 'find',
                                       'params' => { 'model' => 'Post', 'id' => 1, 'by' => { 'title' => 'A' } })

      expect(response).to eq(
        'ok' => false, 'error_type' => 'validation',
        'error' => authoritative_refusal('console_find', model: 'Post', id: 1, by: { 'title' => 'A' }),
        'code' => rule[:code], 'argument' => rule[:argument], 'hint' => rule[:hint]
      )
    end

    it 'labels other schema refusals invalid_arguments without a hint' do
      response = executor.send_request('tool' => 'aggregate',
                                       'params' => { 'model' => 'Post', 'function' => 'bogus' })

      expect(response).to include('ok' => false, 'error_type' => 'validation', 'code' => 'invalid_arguments')
      expect(response).not_to have_key('hint')
    end

    it 'keeps the plain shape for refusals that carry no detail' do
      response = executor.send_request('tool' => 'count', 'params' => { 'model' => 'Missing' })

      expect(response.keys).to contain_exactly('ok', 'error', 'error_type')
    end
  end

  describe 'contract matrix' do
    it 'declares the combination refusal for exactly the two rule-bearing tools' do
      rows = Woods::Console::Server::CONTRACT_MATRIX.select { |row| row[:combination_refusal] }

      expect(rows.map { |row| row[:name] }).to contain_exactly('console_find', 'console_aggregate')
      rows.each do |row|
        refusal = row.fetch(:combination_refusal)
        result = tools_call(row[:name], refusal.fetch(:arguments))
        contract = refusal.fetch(:error_contract)

        expect(result.dig('content', 0, 'text')).to start_with(contract.fetch(:text_prefix))
        expect(result.fetch('_meta')).to include('error_code' => contract.fetch(:code),
                                                 'argument' => contract.fetch(:argument),
                                                 'hint' => contract.fetch(:hint))
      end
    end
  end
end
