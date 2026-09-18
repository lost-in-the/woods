# frozen_string_literal: true

module Woods
  module AgentConfiguration
    # Compute exact document replacements while tracking receipt-owned files.
    module PlannedFiles
      private

      def prepare_config
        document = Document.new(@layout.config_path)
        value = document.json
        servers = value.fetch('mcpServers', {})
        raise Conflict, "mcpServers must be an object: #{document.path}" unless servers.is_a?(Hash)

        validate_server_ownership!(servers)
        @created_files = @previous ? @previous.fetch('created_files').dup : []
        track_created_file(document)
        if @operation == 'remove'
          servers.delete(@name)
        else
          servers[@name] = @entry
        end
        value['mcpServers'] = servers
        @plan.add(document, config_content(document, value),
                  description: "#{@operation} owned Index MCP entry #{@name}")
      end

      def config_content(document, value)
        return if @operation == 'remove' && @created_files.include?(document.path) && value == { 'mcpServers' => {} }

        document.encode_json(value)
      end

      def prepare_sections
        previous_sections = @previous ? @previous.fetch('sections') : {}
        requested = @instructions || previous_sections.keys
        requested = [] if @operation == 'remove'
        validate_instruction_selection!(requested, previous_sections)
        @sections = {}
        (previous_sections.keys | requested).each do |name|
          prepare_section(name, previous_sections[name], removing: !requested.include?(name))
        end
      end

      def prepare_section(name, previous, removing:)
        document = Document.new(@layout.instruction_path(name))
        content, ownership = ManagedSection.change(document.content, previous: previous, remove: removing)
        track_created_file(document)
        content = nil if removing && content == '' && @created_files.include?(document.path)
        @sections[name] = ownership if ownership
        @plan.add(document, content, description: "#{removing ? 'remove' : 'write'} owned Woods instruction section")
      end

      def track_created_file(document)
        return unless document.content.nil? && !@created_files.include?(document.path)

        @created_files << document.path
      end
    end
  end
end
