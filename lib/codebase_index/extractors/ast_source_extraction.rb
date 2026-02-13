# frozen_string_literal: true

require_relative '../ast/method_extractor'

module CodebaseIndex
  module Extractors
    # Shared extraction of individual method source code via the AST layer.
    #
    # Included by extractors that need to pull a single method's source from
    # a class (e.g., ControllerExtractor, MailerExtractor).
    #
    # @example
    #   class FooExtractor
    #     include AstSourceExtraction
    #
    #     def build_chunk(klass, action)
    #       source = extract_action_source(klass, action)
    #       # ...
    #     end
    #   end
    #
    module AstSourceExtraction
      private

      # Extract the source code of a single action method using the AST layer.
      #
      # @param klass [Class] The class that defines the method
      # @param action [String, Symbol] The method name to extract
      # @return [String, nil] The method source, or nil if not extractable
      def extract_action_source(klass, action)
        method = klass.instance_method(action)
        source_location = method.source_location
        return nil unless source_location

        file, _line = source_location
        return nil unless File.exist?(file)

        source = File.read(file)
        Ast::MethodExtractor.new.extract_method_source(source, action.to_s)
      rescue StandardError => e
        Rails.logger.debug("Could not extract action source for #{klass}##{action}: #{e.message}")
        nil
      end
    end
  end
end
