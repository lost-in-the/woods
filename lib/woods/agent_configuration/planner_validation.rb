# frozen_string_literal: true

module Woods
  module AgentConfiguration
    # Receipt and command validation shared by the planner's file preparations.
    module PlannerValidation
      private

      def validate_receipt!
        if @previous
          validate_receipt_identity!
        elsif @operation == 'update'
          raise Conflict, 'No owned installation to update; run setup first'
        end
        return if @operation == 'remove'

        validate_entry!
        validate_setup_compatibility! if @operation == 'setup' && @previous
      end

      def validate_receipt_identity!
        valid = @previous['schema_version'] == 1 && @previous['layout'] == @layout.identity &&
                @previous['server_name'] == @name && @previous['sections'].is_a?(Hash) &&
                @previous['created_files'].is_a?(Array)
        raise Conflict, 'Installation receipt does not match this application/client/scope/server' unless valid

        validate_receipt_content!
      end

      def validate_receipt_content!
        sections = @previous.fetch('sections')
        valid_sections = sections.values.all? do |section|
          section.is_a?(Hash) && section['owned_text'].is_a?(String) && section['prefix'].is_a?(String)
        end
        valid_files = (@previous.fetch('created_files') - @layout.allowed_paths).empty?
        return if valid_sections && valid_files && @previous['entry'].is_a?(Hash)

        raise Conflict, 'Malformed ownership receipt; restore it before updating or removing configuration'
      end

      def validate_entry!
        return if @entry.is_a?(Hash) && @entry['command'].is_a?(String) && @entry['args'].is_a?(Array)

        raise Conflict, 'A preflight-validated Index MCP command is required'
      end

      def validate_setup_compatibility!
        if @previous['entry'] != @entry
          raise Conflict, 'Setup differs from the owned installation; preview an explicit update'
        end
        return if @previous['template_version'] == self.class::TEMPLATE_VERSION

        raise Conflict, 'The instruction template changed; preview an explicit update'
      end

      def validate_server_ownership!(servers)
        if @previous
          return if servers[@name] == @previous.fetch('entry')

          raise Conflict, 'The owned MCP entry was edited or removed; restore it or resolve ownership manually'
        end
        return unless servers.key?(@name)

        raise Conflict, "MCP entry #{@name.inspect} already exists without a Woods receipt; choose another name"
      end

      def validate_instruction_selection!(requested, previous_sections)
        unless requested.is_a?(Array) && requested.uniq == requested
          raise Conflict, 'Instruction files must be a unique list'
        end
        return unless @operation == 'setup' && @previous && requested.sort != previous_sections.keys.sort

        raise Conflict, 'Instruction selection differs; preview an explicit update'
      end
    end
  end
end
