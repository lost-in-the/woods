# frozen_string_literal: true

require_relative '../ast/method_extractor'

module Woods
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

        file, line = source_location
        return nil unless File.exist?(file)

        definition_for(action_definitions_for(file), action.to_s, line)
      rescue StandardError => e
        Rails.logger.debug("Could not extract action source for #{klass}##{action}: #{e.message}")
        nil
      end

      # Every instance-method definition in one file, keyed by
      # `[name, line]` — read and parsed once per file per extractor
      # instance (audit P1).
      #
      # {#build_action_chunks} in the including extractors calls
      # {#extract_action_source} once per action, so a 30-action controller
      # previously read and re-parsed its own source 30 times. The parse
      # result is a pure function of the file's bytes, so answering every
      # action from one parse is byte-identical to parsing per action.
      #
      # A file whose source fails to parse stays uncached (the `||=` never
      # assigns), so each action retries it and rescues exactly as before.
      #
      # @param file [String] Absolute path of the defining file
      # @return [Hash{Array(String, Integer) => String}] [name, line] => source text
      def action_definitions_for(file)
        (@action_definitions ||= {})[file] ||=
          Ast::MethodExtractor.new.extract_method_definitions(File.read(file))
      end

      # The definition Ruby dispatches: the `def` at the line `source_location`
      # reports. A name-only lookup served the first `def` by that name, so a
      # redefined action, two classes in one file sharing an action name, or a
      # `class << self` def beside the instance method all published the wrong
      # body (F5). A name defined exactly once still resolves when the line
      # does not match (a definition evaluated with a line offset).
      #
      # @param definitions [Hash{Array(String, Integer) => String}]
      # @param name [String]
      # @param line [Integer, nil]
      # @return [String, nil]
      def definition_for(definitions, name, line)
        return definitions[[name, line]] if definitions.key?([name, line])

        candidates = definitions.select { |(defined_name, _), _| defined_name == name }.values
        candidates.first if candidates.size == 1
      end
    end
  end
end
