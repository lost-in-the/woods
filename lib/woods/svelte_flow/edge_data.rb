# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Normalizes dependency-graph edge entries for the visualization layer.
    #
    # `DependencyGraph#to_h[:edges]` maps each source identifier to an array of
    # edge entries. After {DependencyGraph.from_h} or {DependencyGraph#register}
    # each entry is a `{ target:, via: }` hash with symbol keys, but older
    # serialized graphs (and hand-built fixtures) may carry bare target strings
    # or string-keyed hashes. These helpers extract the target and relationship
    # (`:via`) uniformly so edge consumers never have to branch on shape.
    #
    # @example
    #   EdgeData.target({ target: 'Post', via: :belongs_to })  # => "Post"
    #   EdgeData.via({ target: 'Post', via: :belongs_to })      # => :belongs_to
    #   EdgeData.target('Post')                                 # => "Post"
    #
    module EdgeData
      module_function

      # Extract the target identifier from an edge entry.
      #
      # @param entry [Hash, String] Edge entry — `{ target:, via: }` hash or bare string
      # @return [String, nil] Target identifier
      def target(entry)
        return entry if entry.is_a?(String)
        return unless entry.is_a?(Hash)

        (entry[:target] || entry['target'])&.to_s
      end

      # Extract the relationship label (`:via`) from an edge entry.
      #
      # @param entry [Hash, String] Edge entry
      # @return [Symbol, nil] Relationship label, or nil for bare-string / unlabeled edges
      def via(entry)
        return unless entry.is_a?(Hash)

        via = entry[:via] || entry['via']
        via&.to_sym
      end

      # Map an array of edge entries to their target identifiers, dropping nils.
      #
      # @param entries [Array<Hash, String>, nil] Edge entries for one source
      # @return [Array<String>] Target identifiers
      def targets(entries)
        (entries || []).filter_map { |entry| target(entry) }
      end
    end
  end
end
