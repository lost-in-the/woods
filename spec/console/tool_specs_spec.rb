# frozen_string_literal: true

require 'spec_helper'
require 'mcp'

# tool_specs.rb is a pure data table. Tier 4 `handler:` values use `begin`
# blocks that instantiate EvalGuard / SqlValidator at require-time, and
# Tier 1–3 lambdas reference `Tools::TierN` (resolved lexically from
# `Woods::Console::Server`). Loading the real dependencies — rather than
# stubbing them here — prevents spec-order pollution: empty stubs at
# `Woods::Console::Server::Tools::Tier1` or `Server::SqlValidator` would
# shadow the real constants for every later spec that exercises the
# server through its tool lambdas.
require 'woods/console/eval_guard'
require 'woods/console/sql_validator'
require 'woods/console/tools/tier1'
require 'woods/console/tools/tier2'
require 'woods/console/tools/tier3'
require 'woods/console/tools/tier4'
require 'woods/console/tool_specs'

RSpec.describe Woods::Console::Server do
  let(:all_specs) { described_class::TOOL_SPECS }

  let(:valid_tiers) { (1..4).to_a }
  let(:tier_constants) do
    {
      1 => described_class::TIER1_TOOLS,
      2 => described_class::TIER2_TOOLS,
      3 => described_class::TIER3_TOOLS,
      4 => described_class::TIER4_TOOLS
    }
  end

  # ── Catalogue completeness ─────────────────────────────────────────────────

  describe 'TOOL_SPECS' do
    it 'contains 31 entries' do
      expect(all_specs.size).to eq(31)
    end

    it 'is frozen' do
      expect(all_specs).to be_frozen
    end
  end

  describe 'CONTRACT_MATRIX' do
    let(:matrix) { described_class::CONTRACT_MATRIX }

    it 'derives one frozen contract row from each of the 31 tool specs' do
      expect(matrix).to be_frozen
      expect(matrix.size).to eq(31)
      expect(matrix.map { |row| row.fetch(:name) }).to eq(all_specs.map(&:name))
    end

    it 'records the complete capability and safety contract for every row' do
      required_keys = %i[
        name mode required valid_output invalid_input authorization table_gate
        redaction credential_scan confirmation audit
      ]

      expect(matrix).to all(satisfy { |row| (required_keys - row.keys).empty? })
    end

    it 'marks only Tier 1 tools executable in default embedded mode' do
      executable = matrix.select { |row| row.fetch(:mode).include?(:embedded) }

      expect(executable.map { |row| row.fetch(:name) }).to contain_exactly(
        *described_class::TIER1_TOOLS.map { |name| "console_#{name}" }
      )
    end

    it 'adds only SQL and query in embedded read mode' do
      executable = matrix.select { |row| row.fetch(:mode).include?(:embedded_read) }
      expected = described_class::TIER1_TOOLS.map { |name| "console_#{name}" } +
                 %w[console_sql console_query]

      expect(executable.map { |row| row.fetch(:name) }).to contain_exactly(*expected)
    end

    it 'does not claim confirmation or audit for an executable tool' do
      executable = matrix.select { |row| row.fetch(:mode).any? }

      expect(executable).to all(include(confirmation: false, audit: false))
    end
  end

  # ── Required fields on every ToolSpec ─────────────────────────────────────

  describe 'each ToolSpec' do
    it 'has a non-empty String name' do
      expect(all_specs).to all(satisfy { |s| s.name.is_a?(String) && !s.name.empty? })
    end

    it 'has a non-empty String description' do
      expect(all_specs).to all(satisfy { |s| s.description.is_a?(String) && !s.description.empty? })
    end

    it 'has a Hash properties value' do
      expect(all_specs).to all(satisfy { |s| s.properties.is_a?(Hash) })
    end

    it 'has a valid tier (1–4)' do
      expect(all_specs).to all(satisfy { |s| valid_tiers.include?(s.tier) })
    end

    it 'has a callable handler' do
      expect(all_specs).to all(satisfy { |s| s.handler.respond_to?(:call) })
    end

    it 'has required that is nil or an Array of Strings' do
      all_specs.each do |spec|
        next if spec.required.nil?

        expect(spec.required).to be_an(Array), "#{spec.name}: required must be nil or Array"
        expect(spec.required).to all(be_a(String)), "#{spec.name}: required entries must be Strings"
      end
    end
  end

  # ── No duplicate names ────────────────────────────────────────────────────

  describe 'TOOL_SPECS names' do
    it 'are unique (no duplicates)' do
      names = all_specs.map(&:name)
      expect(names).to eq(names.uniq)
    end

    it 'all start with the console_ prefix' do
      expect(all_specs).to all(satisfy { |s| s.name.start_with?('console_') })
    end
  end

  # ── Tier catalogue cross-check ────────────────────────────────────────────

  describe 'tier constants' do
    it 'TIER1_TOOLS, TIER2_TOOLS, TIER3_TOOLS, TIER4_TOOLS are non-overlapping' do
      all_names = [
        described_class::TIER1_TOOLS,
        described_class::TIER2_TOOLS,
        described_class::TIER3_TOOLS,
        described_class::TIER4_TOOLS
      ].flatten
      expect(all_names).to eq(all_names.uniq)
    end

    it 'each TOOL_SPEC name appears in exactly one tier constant (strip console_ prefix)' do
      all_specs.each do |spec|
        short_name = spec.name.delete_prefix('console_')
        matching_tiers = tier_constants.select { |_, names| names.include?(short_name) }
        msg = "#{spec.name}: expected in exactly one tier constant, found in #{matching_tiers.keys}"
        expect(matching_tiers.size).to eq(1), msg
      end
    end

    it 'every name in a tier constant maps to a TOOL_SPEC with that tier number' do
      tier_constants.each do |tier_num, names|
        names.each do |short_name|
          full_name = "console_#{short_name}"
          spec = all_specs.find { |s| s.name == full_name }
          expect(spec).not_to be_nil, "No ToolSpec found for #{full_name}"
          expect(spec.tier).to eq(tier_num),
                               "#{full_name}: expected tier #{tier_num}, got #{spec.tier}"
        end
      end
    end
  end

  # ── Properties schema validity ────────────────────────────────────────────

  describe 'each ToolSpec property definition' do
    it 'has a type field' do
      all_specs.each do |spec|
        spec.properties.each do |prop_name, defn|
          expect(defn).to have_key(:type),
                          "#{spec.name}.#{prop_name}: missing :type key"
        end
      end
    end

    it 'has a description field' do
      all_specs.each do |spec|
        spec.properties.each do |prop_name, defn|
          expect(defn).to have_key(:description),
                          "#{spec.name}.#{prop_name}: missing :description key"
        end
      end
    end

    it 'uses only allowed JSON Schema types' do
      allowed_types = %w[string integer boolean object array number].freeze
      all_specs.each do |spec|
        spec.properties.each do |prop_name, defn|
          types = Array(defn[:type])
          expect(types).to all(satisfy { |type| allowed_types.include?(type) }),
                           "#{spec.name}.#{prop_name}: unexpected type '#{defn[:type]}'"
        end
      end
    end

    it 'declares minimum and maximum for every integer property' do
      all_specs.each do |spec|
        spec.properties.each do |prop_name, definition|
          next unless definition[:type] == 'integer'

          expect(definition[:minimum]).to be_an(Integer),
                                          "#{spec.name}.#{prop_name}: missing integer minimum"
          expect(definition[:maximum]).to be_an(Integer),
                                          "#{spec.name}.#{prop_name}: missing integer maximum"
          expect(definition[:minimum]).to be <= definition[:maximum]
        end
      end
    end
  end

  # ── required field cross-check ────────────────────────────────────────────

  describe 'required fields' do
    it 'each required field name exists as a property key' do
      all_specs.each do |spec|
        next unless spec.required

        spec.required.each do |req|
          expect(spec.properties).to have_key(req.to_sym).or(have_key(req)),
                                     "#{spec.name}: required field '#{req}' not found in properties"
        end
      end
    end
  end

  # ── Spot checks on specific tools ─────────────────────────────────────────

  describe 'console_count' do
    subject(:spec) { all_specs.find { |s| s.name == 'console_count' } }

    it 'is tier 1' do
      expect(spec.tier).to eq(1)
    end

    it 'requires model' do
      expect(spec.required).to eq(['model'])
    end

    it 'defines a model property of type string' do
      expect(spec.properties[:model][:type]).to eq('string')
    end
  end

  describe 'console_sql' do
    subject(:spec) { all_specs.find { |s| s.name == 'console_sql' } }

    it 'is tier 4' do
      expect(spec.tier).to eq(4)
    end

    it 'requires sql' do
      expect(spec.required).to include('sql')
    end
  end

  describe 'console_query having schema' do
    subject(:schema) do
      spec = all_specs.find { |candidate| candidate.name == 'console_query' }
      MCP::Tool::InputSchema.new(properties: spec.properties, required: spec.required)
    end

    it 'accepts a non-empty condition object or a two-element parameterized array' do
      expect { schema.validate_arguments(model: 'Order', select: ['id'], having: { count: 2 }) }
        .not_to raise_error
      expect { schema.validate_arguments(model: 'Order', select: ['id'], having: ['COUNT(*) > ?', 2]) }
        .not_to raise_error
    end

    it 'rejects raw strings, empty objects, and arrays with the wrong shape' do
      invalid_values = ['COUNT(*) > 2', {}, ['COUNT(*) > ?'], ['COUNT(*) > ?', 2, 3]]

      invalid_values.each do |having|
        expect { schema.validate_arguments(model: 'Order', select: ['id'], having: having) }
          .to raise_error(MCP::Tool::InputSchema::ValidationError)
      end
    end
  end

  describe 'console_status' do
    subject(:spec) { all_specs.find { |s| s.name == 'console_status' } }

    it 'has no required fields' do
      expect(spec.required).to be_nil
    end

    it 'has an empty properties Hash' do
      expect(spec.properties).to eq({})
    end
  end
end
