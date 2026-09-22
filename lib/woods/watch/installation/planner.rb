# frozen_string_literal: true

require_relative 'templates'
require_relative 'receipt'

module Woods
  module Watch
    class Installation
      # Builds one conflict-checked transaction while preserving unowned bytes.
      class Planner
        # @param layout [Layout] destination and local transaction paths
        # @param options [Options] preflight-validated selections
        def initialize(layout:, options:)
          @layout = layout
          @options = options
          @documents = {}
          @contents = {}
          @modes = {}
        end

        # @return [Woods::AgentConfiguration::Plan] complete preview
        def call
          @receipt = Receipt.new(document(Layout::RECEIPT))
          @layout.include_previous(@receipt.paths)
          @plan = Woods::AgentConfiguration::Plan.new(layout: @layout, operation: @options.operation)
          validate_operation!
          remove_previous
          install unless @options.operation == 'remove'
          publish_plan
        end

        private

        def validate_operation!
          previous = @receipt.data
          if @options.operation == 'update' && !previous
            raise Conflict, 'No owned watcher installation to update; run setup first'
          end
          return unless previous && @options.operation == 'setup' && previous.fetch('selection') != @options.selection

          raise Conflict, 'Watcher setup selection changed; use --operation update to switch modes or commands'
        end

        def document(path)
          @documents[path] ||= @layout.document(path)
        end

        def content(path)
          @contents.key?(path) ? @contents[path] : document(path).content
        end

        def remove_previous
          return unless @receipt.data

          @receipt.data.fetch('files').each do |path, expected|
            Receipt.verify_file!(document(path), expected)
            @contents[path] = nil
          end
          @receipt.data.fetch('sections').each { |path, record| remove_section(path, record) }
          @contents[Layout::RECEIPT] = nil
        end

        def remove_section(path, record)
          text = document(path).content || ''
          block = record.fetch('owned_text')
          unless text.scan(Templates::START).size == 1 && text.scan(Templates::FINISH).size == 1 && text.include?(block)
            raise Conflict, "Owned watcher section was edited or removed: #{path}"
          end

          remaining = text.sub(block, '')
          @contents[path] = record.fetch('created_file') && remaining.empty? ? nil : remaining
        end

        def install
          @new_receipt = { 'schema_version' => 1, 'selection' => @options.selection, 'files' => {}, 'sections' => {} }
          if @options.mode != 'external'
            install_wrapper
            install_section
          end
          @contents[Layout::RECEIPT] = "#{JSON.pretty_generate(@new_receipt)}\n"
          @modes[Layout::RECEIPT] = 0o644
        end

        def install_wrapper
          path = Layout::WRAPPER
          raise Conflict, 'Refusing to overwrite an unowned bin/woods-watch' if content(path)

          text = Templates.wrapper(@options.child_command)
          @contents[path] = text
          @modes[path] = 0o755
          @new_receipt.fetch('files')[path] = { 'sha256' => Digest::SHA256.hexdigest(text), 'mode' => 0o755, 'exists' => true }
        end

        def install_section
          path = @options.mode == 'puma' ? Layout::PUMA : @options.procfile
          text = content(path) || ''
          reject_unowned_section!(text)
          block = Templates.section(@options.mode, text)
          previous = @receipt.data&.dig('sections', path)
          if previous
            block = previous.fetch('owned_text')
            @contents[path] = document(path).content
          else
            @contents[path] = text + block
          end
          @modes[path] = document(path).content ? document(path).mode : 0o644
          @new_receipt.fetch('sections')[path] = { 'owned_text' => block, 'created_file' => content_created?(path) }
        end

        def content_created?(path)
          @receipt.data&.dig('sections', path, 'created_file') || document(path).content.nil?
        end

        def reject_unowned_section!(text)
          conflict = text.include?(Templates::START) || text.include?(Templates::FINISH)
          pattern = @options.mode == 'puma' ? /^\s*plugin(?:\s+|\s*\(\s*)[:'"]woods\b/ : /^\s*woods\s*:/
          conflict ||= text.match?(pattern)
          raise Conflict, 'Unowned Woods startup directive or managed markers already exist' if conflict
        end

        def publish_plan
          @contents.each do |path, text|
            current = document(path)
            @plan.add(current, text, description: "#{@options.operation} Woods watcher ownership in #{path}")
            change = @plan.data.fetch('changes').find { |entry| entry['path'] == current.path }
            change['mode'] = @modes.fetch(path, current.mode) if change && text
          end
          @plan
        end
      end
    end
  end
end
