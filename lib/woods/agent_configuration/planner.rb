# frozen_string_literal: true

require_relative 'plan'
require_relative 'managed_section'
require_relative 'planner_validation'
require_relative 'planned_files'

module Woods
  module AgentConfiguration
    class Planner
      include PlannerValidation
      include PlannedFiles

      TEMPLATE_VERSION = 1

      def initialize(layout:, operation:, entry: nil, **options)
        unknown = options.keys - %i[name instructions evidence intent]
        raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" unless unknown.empty?

        name = options.fetch(:name, 'woods')
        raise Conflict, 'Supported operations: setup, update, remove' unless %w[setup update remove].include?(operation)
        raise Conflict, 'Server name must be a simple nonempty name' unless name.match?(/\A[a-zA-Z0-9_-]+\z/)

        @layout = layout
        @operation = operation
        @entry = entry
        @name = name
        @instructions = options[:instructions]
        @evidence = options.fetch(:evidence, {})
        @intent = options.fetch(:intent, {})
      end

      def call
        @receipt_document = Document.new(@layout.receipt_path)
        @previous = @receipt_document.content && @receipt_document.json
        validate_receipt!
        @plan = Plan.new(layout: @layout, operation: @operation, evidence: @evidence)
        return @plan if @operation == 'remove' && @previous.nil?

        prepare_config
        prepare_sections
        prepare_receipt
        @plan
      end

      private

      def prepare_receipt
        if @operation == 'remove'
          @plan.add(@receipt_document, nil, description: 'remove installation receipt')
          return
        end
        receipt = { 'schema_version' => 1, 'template_version' => TEMPLATE_VERSION, 'layout' => @layout.identity,
                    'server_name' => @name, 'entry' => @entry, 'sections' => @sections,
                    'created_files' => @created_files, 'intent' => @intent, 'evidence' => @evidence }
        # A repeated setup never silently upgrades the installation's template
        # or evidence version. The explicit update operation owns that change.
        receipt = @previous if @operation == 'setup' && @previous && @plan.data.fetch('changes').empty?
        @plan.add(@receipt_document, @receipt_document.encode_json(receipt), description: 'record owned installation')
      end
    end
  end
end
