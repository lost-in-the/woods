# frozen_string_literal: true

require_relative 'class_declarations'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # Identifies migration declarations without running historical migration code.
    # Filename ownership disambiguates a migration from its local migration base.
    class MigrationDeclaration
      class Ambiguous < StandardError; end

      # @param source [String] original Ruby source
      # @param file_path [String] migration filename
      def initialize(source:, file_path:)
        @declarations = ClassDeclarations.read(source)
        @lookup = SourceReferences::RuntimeLookup.new
        @expected = File.basename(file_path, '.rb').sub(/\A\d+_/, '').camelize
      end

      # @return [Hash, nil] selected identifier and its declaration source
      # @raise [Ambiguous] when ownership is ambiguous
      def call
        candidates = @declarations.select { |record| migration?(record, []) }.group_by { |record| record[:identifier] }
        selected = select_identity(candidates.keys)
        return unless selected

        source = @declarations.select { |record| record[:identifier] == selected }.map { |record| record[:source] }
        { identifier: selected, source: source.join("\n") }
      end

      private

      def select_identity(identifiers)
        matching = identifiers.select { |name| name == @expected }
        matching = identifiers.select { |name| name.split('::').last == @expected } if matching.empty?
        matching = identifiers if matching.empty?
        return matching.first if matching.size <= 1

        raise Ambiguous, "Ambiguous migration declaration: #{matching.join(', ')}"
      end

      def migration?(record, visiting)
        identifier = record.fetch(:identifier)
        return false if visiting.include?(identifier)

        parent = ClassDeclarations.parent_name(record)
        return false unless parent

        local = local_parent(parent, record.fetch(:nesting))
        return local.any? { |candidate| migration?(candidate, [*visiting, identifier]) } unless local.empty?

        runtime_parent?(parent, record.fetch(:nesting))
      end

      def local_parent(parent, nesting)
        candidates = if parent.start_with?('::')
                       [parent.delete_prefix('::')]
                     else
                       nesting.map { |scope| "#{scope}::#{parent}" } + [parent]
                     end
        candidates.each do |name|
          records = @declarations.select { |record| record[:identifier] == name }
          return records unless records.empty?
        end
        []
      end

      def runtime_parent?(parent, nesting)
        result = @lookup.call(parent, nesting: nesting, allow_private: true)
        if result[:status] == :resolved
          return false unless @lookup.class_object?(result[:value])

          return @lookup.reflect(result[:value], :ancestors).any? do |ancestor|
            @lookup.reflect(ancestor, :name) == 'ActiveRecord::Migration'
          end
        end
        return false unless %w[constant_missing unloaded_scope autoload_pending].include?(result[:reason])

        # The standard Rails declaration is structural evidence even when the
        # migration namespace has never been loaded. Unknown custom bases are
        # not inferred from their spelling or evaluated to find out.
        parent.delete_prefix('::') == 'ActiveRecord::Migration'
      end
    end
  end
end
