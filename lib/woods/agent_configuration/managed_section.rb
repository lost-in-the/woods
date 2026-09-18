# frozen_string_literal: true

require_relative 'error'

module Woods
  module AgentConfiguration
    # Only a receipt-owned, byte-identical section may be replaced or removed.
    class ManagedSection
      START = '<!-- woods:managed:start -->'
      FINISH = '<!-- woods:managed:end -->'
      BODY = <<~MARKDOWN
        ## Codebase index (Woods)

        Call `woods_status` before relying on the published index. For structural
        questions use `search`, `lookup`, and `dependencies`/`dependents` as needed.
        Check freshness and search completeness before treating missing evidence
        as absent code. Read source and run relevant tests to verify changes.
        The server's tool descriptions define its available capabilities.
      MARKDOWN

      def self.render(content)
        newline = content&.include?("\r\n") ? "\r\n" : "\n"
        "#{START}\n#{BODY}#{FINISH}\n".gsub("\n", newline)
      end

      def self.change(content, previous:, remove: false)
        text = content || ''
        starts = text.scan(START).size
        finishes = text.scan(FINISH).size
        return replace_owned(text, previous, starts, finishes, remove) if previous

        unless starts.zero? && finishes.zero?
          raise Conflict, 'Unowned or ambiguous Woods markers; resolve them before setup'
        end
        return [content, nil] if remove

        prefix = separator(text)
        block = prefix + render(text)
        [text + block, { 'owned_text' => block, 'prefix' => prefix }]
      end

      def self.replace_owned(text, previous, starts, finishes, remove)
        unless starts == 1 && finishes == 1 && text.include?(previous.fetch('owned_text'))
          raise Conflict, 'Managed instruction section was edited or removed; restore it or resolve ownership manually'
        end
        return [text.sub(previous.fetch('owned_text'), ''), nil] if remove

        block = previous.fetch('prefix') + render(text)
        [text.sub(previous.fetch('owned_text'), block), { 'owned_text' => block, 'prefix' => previous.fetch('prefix') }]
      end
      private_class_method :replace_owned

      def self.separator(text)
        return '' if text.empty?

        newline = text.include?("\r\n") ? "\r\n" : "\n"
        text.end_with?(newline) ? newline : newline * 2
      end
      private_class_method :separator
    end
  end
end
