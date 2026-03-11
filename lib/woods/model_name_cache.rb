# frozen_string_literal: true

module CodebaseIndex
  # Caches ActiveRecord model names and builds a precompiled regex
  # for scanning source code for model references.
  #
  # Avoids O(n*m) per-extractor iteration of ActiveRecord::Base.descendants.
  # Invalidated per extraction run (call .reset! before a new run).
  #
  # @example
  #   CodebaseIndex::ModelNameCache.model_names
  #   # => ["User", "Order", "Product", ...]
  #
  #   CodebaseIndex::ModelNameCache.model_names_regex
  #   # => /\b(?:User|Order|Product|...)\b/
  #
  module ModelNameCache
    class << self
      # @return [Array<String>] All named AR model descendant names
      def model_names
        @model_names ||= compute_model_names
      end

      # @return [Regexp] Precompiled regex matching any model name as a whole word
      def model_names_regex
        @model_names_regex ||= build_regex
      end

      # Clear cache (call at the start of each extraction run)
      def reset!
        @model_names = nil
        @model_names_regex = nil
      end

      private

      def compute_model_names
        return [] unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.descendants.filter_map(&:name).uniq
      end

      def build_regex
        names = model_names
        return /(?!)/ if names.empty? # never-matching regex

        /\b(?:#{names.map { |n| Regexp.escape(n) }.join('|')})\b/
      end
    end
  end
end
