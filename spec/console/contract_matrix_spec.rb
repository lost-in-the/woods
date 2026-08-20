# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'woods/console/server'

RSpec.describe Woods::Console::Server::CONTRACT_MATRIX do
  subject(:matrix) { described_class }

  let(:specs_by_name) do
    Woods::Console::Server::TOOL_SPECS.to_h { |spec| [spec.name, spec] }
  end

  def input_schema(row)
    MCP::Tool::InputSchema.new(row.dig(:arguments, :constraints))
  end

  it 'derives argument names and constraints from every ToolSpec' do
    expect(matrix.size).to eq(31)

    matrix.each do |row|
      spec = specs_by_name.fetch(row.fetch(:name))
      required = Array(spec.required)

      expect(row.fetch(:arguments)).to eq(
        required: required,
        optional: spec.properties.keys.map(&:to_s) - required,
        constraints: spec.input_schema
      )
    end
  end

  it 'provides schema-valid and schema-invalid representative input for all 31 rows' do
    matrix.each do |row|
      expect { input_schema(row).validate_arguments(row.fetch(:representative_valid_input)) }
        .not_to raise_error, row.fetch(:name)

      invalid = row.fetch(:representative_invalid_input)
      expect(invalid.fetch(:error_class)).to eq('MCP::Tool::InputSchema::ValidationError')
      expect { input_schema(row).validate_arguments(invalid.fetch(:arguments)) }
        .to raise_error(MCP::Tool::InputSchema::ValidationError), row.fetch(:name)
    end
  end

  it 'executes every registered row representative through its real request handler' do
    matrix.select { |row| row.fetch(:executable_modes).any? }.each do |row|
      spec = specs_by_name.fetch(row.fetch(:name))
      request = spec.handler.call(row.fetch(:representative_valid_input).transform_keys(&:to_sym))

      expect(request.fetch(:tool)).to eq(row.fetch(:name).delete_prefix('console_'))
      expect(request.fetch(:params)).to be_a(Hash)
      expect(row.dig(:semantic_output, :availability)).to eq(:executable)
      expect(row.dig(:semantic_output, :shape)).to be_a(Hash)
    end
  end

  it 'keeps every unsupported row out of all registration modes with honest inactive controls' do
    registered_names = Woods::Console::Server::EXECUTABLE_MODES.values.flatten.uniq
    unsupported = matrix.reject { |row| row.fetch(:executable_modes).any? }

    expect(unsupported.size).to eq(20)
    unsupported.each do |row|
      expect(registered_names).not_to include(row.fetch(:name))
      expect(row.fetch(:authorization)).to eq(:not_applicable_unregistered)
      expect(row.fetch(:table_gate)).to eq(:not_active_unregistered)
      expect(row.fetch(:redaction)).to eq(:not_active_unregistered)
      expect(row.fetch(:credential_scan)).to eq(:not_active_unregistered)
      expect(row.dig(:semantic_output, :availability)).to eq(:inventory_only)
    end
  end

  it 'records the unimplemented confirmation and audit prerequisites explicitly' do
    rows = matrix.to_h { |row| [row.fetch(:name), row] }

    expect(rows.fetch('console_update_setting').fetch(:confirmation)).to eq(:required_before_registration)
    expect(rows.fetch('console_job_find').fetch(:confirmation)).to eq(:required_for_retry_before_registration)
    expect(rows.fetch('console_eval').fetch(:confirmation)).to eq(:required_before_registration)
    expect(rows.fetch('console_eval').fetch(:audit)).to eq(:required_before_registration)

    executable = matrix.select { |row| row.fetch(:executable_modes).any? }
    expect(executable).to all(include(confirmation: :not_required, audit: :not_recorded))
  end
end
