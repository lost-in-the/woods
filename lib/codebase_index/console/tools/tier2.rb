# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Tools
      # Tier 2: Domain-aware tools for querying live Rails data.
      #
      # These tools build on Tier 1 primitives to provide higher-level
      # domain operations: model diagnostics, data snapshots, validation,
      # settings management, policy checks, and decorator invocation.
      #
      # Each method builds a bridge request hash from validated parameters.
      # The bridge executes the operation against the Rails environment.
      #
      module Tier2
        module_function

        # Diagnose a model by composing multiple queries: count, recent records, and aggregates.
        #
        # @param model [String] Model name
        # @param scope [Hash, nil] Filter conditions
        # @param sample_size [Integer] Number of sample records (default: 5, max: 25)
        # @return [Hash] Bridge request
        def console_diagnose_model(model:, scope: nil, sample_size: 5)
          sample_size = [sample_size, 25].min
          { tool: 'diagnose_model', params: { model: model, scope: scope, sample_size: sample_size }.compact }
        end

        # Snapshot a record with its associations for debugging.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param associations [Array<String>, nil] Association names to include
        # @param depth [Integer] Association traversal depth (default: 1, max: 3)
        # @return [Hash] Bridge request
        def console_data_snapshot(model:, id:, associations: nil, depth: 1)
          depth = [depth, 3].min
          { tool: 'data_snapshot',
            params: { model: model, id: id, associations: associations, depth: depth }.compact }
        end

        # Run validations on an existing record, optionally with changed attributes.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param attributes [Hash, nil] Attributes to set before validating
        # @return [Hash] Bridge request
        def console_validate_record(model:, id:, attributes: nil)
          { tool: 'validate_record', params: { model: model, id: id, attributes: attributes }.compact }
        end

        # Check a configuration setting value.
        #
        # @param key [String] Setting key
        # @param namespace [String, nil] Setting namespace
        # @return [Hash] Bridge request
        def console_check_setting(key:, namespace: nil)
          { tool: 'check_setting', params: { key: key, namespace: namespace }.compact }
        end

        # Update a configuration setting (requires human confirmation).
        #
        # @param key [String] Setting key
        # @param value [Object] New value
        # @param namespace [String, nil] Setting namespace
        # @return [Hash] Bridge request with requires_confirmation flag
        def console_update_setting(key:, value:, namespace: nil)
          { tool: 'update_setting',
            params: { key: key, value: value, namespace: namespace }.compact,
            requires_confirmation: true }
        end

        # Check authorization policy for a record and user.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param user_id [Integer] User to check authorization for
        # @param action [String] Policy action (e.g., "update", "destroy")
        # @return [Hash] Bridge request
        def console_check_policy(model:, id:, user_id:, action:)
          { tool: 'check_policy',
            params: { model: model, id: id, user_id: user_id, action: action } }
        end

        # Validate attributes against a model without persisting.
        #
        # @param model [String] Model name
        # @param attributes [Hash] Attributes to validate
        # @param context [String, nil] Validation context (e.g., "create", "update")
        # @return [Hash] Bridge request
        def console_validate_with(model:, attributes:, context: nil)
          { tool: 'validate_with', params: { model: model, attributes: attributes, context: context }.compact }
        end

        # Check feature eligibility for a record.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param feature [String] Feature name to check
        # @return [Hash] Bridge request
        def console_check_eligibility(model:, id:, feature:)
          { tool: 'check_eligibility', params: { model: model, id: id, feature: feature } }
        end

        # Invoke a decorator on a record and return computed attributes.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param methods [Array<String>, nil] Specific decorator methods to call
        # @return [Hash] Bridge request
        def console_decorate(model:, id:, methods: nil)
          { tool: 'decorate', params: { model: model, id: id, methods: methods }.compact }
        end
      end
    end
  end
end
