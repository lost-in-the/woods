# frozen_string_literal: true

module Woods
  module Extractors
    # Stable, readable middleware arguments without inspecting opaque runtime state.
    # Literal strings and custom #to_s implementations remain application data.
    module MiddlewareArgument
      module_function

      # @param value [Object] Runtime middleware argument
      # @return [String] Deterministic description for ordinary Ruby runtime values
      def render(value, ancestors = [], nested: false)
        return "<recursive #{value.class}>" if ancestors.any? { |ancestor| ancestor.equal?(value) }

        ancestors += [value]
        case value
        when String then nested ? value.inspect : value
        when Symbol then nested ? value.inspect : value.to_s
        when NilClass then nested ? 'nil' : ''
        when Array then "[#{value.map { |item| render(item, ancestors, nested: true) }.join(', ')}]"
        when Hash
          pairs = value.map { |key, item| "#{render(key, ancestors, nested: true)}=>#{render(item, ancestors, nested: true)}" }
          "{#{pairs.join(', ')}}"
        when Module then module_name(value)
        when Proc then "#<#{value.lambda? ? 'lambda' : 'Proc'} #{value.source_location&.join(':') || 'native'}>"
        else
          # Only Object's identity-based implementation is replaced. Never scrub
          # arbitrary hex strings or override application-defined textual values.
          if [Kernel, Object].include?(value.method(:to_s).owner)
            "#<#{module_name(value.class)}>"
          else
            value.to_s
          end
        end
      end

      def module_name(value)
        return value.name if value.name && !value.name.empty?

        parent = value.is_a?(Class) ? " < #{module_name(value.superclass)}" : ''
        methods = (value.instance_methods(false) + value.private_instance_methods(false)).uniq.sort.map do |name|
          "#{name}@#{value.instance_method(name).source_location&.join(':') || 'native'}"
        end
        "#<anonymous #{value.class}#{parent}#{" (#{methods.join(', ')})" unless methods.empty?}>"
      end
      private_class_method :module_name
    end
  end
end
