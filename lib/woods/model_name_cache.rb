# frozen_string_literal: true

module Woods
  # Caches ActiveRecord model names and builds a precompiled regex
  # for scanning source code for model references.
  #
  # Avoids O(n*m) per-extractor iteration of ActiveRecord::Base.descendants.
  # Invalidated per extraction run (call .reset! before a new run).
  #
  # Provides two resolution layers:
  # 1. {.model_names_regex} — whole-word match against every fully-qualified
  #    model name. Catches `User`, `Library::Book`, and `"Library::Book"`
  #    (as a string literal) because `\b` treats `:` and `"` as boundaries.
  # 2. {.resolve_short_name} — when source references the bare inner name
  #    (e.g. `Book.new` inside `module Library`), resolve it back to its
  #    fully-qualified owner when the short name is unambiguous. Needed
  #    because the cache holds `Library::Book` but the source writes
  #    `Book` after a `module Library` opens.
  #
  # @example
  #   Woods::ModelNameCache.model_names
  #   # => ["User", "Library::Book", ...]
  #
  #   Woods::ModelNameCache.model_names_regex
  #   # => /\b(?:User|Library::Book|...)\b/
  #
  #   Woods::ModelNameCache.resolve_short_name("Book")
  #   # => "Library::Book"   (or nil when ambiguous)
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

      # Short-name → fully-qualified owner mapping. Ambiguous short names
      # (two different models sharing the same inner name) map to nil so
      # callers can detect the collision and skip the edge rather than
      # guess.
      #
      # @return [Hash{String => String, nil}]
      def short_name_map
        @short_name_map ||= build_short_name_map
      end

      # Resolve a bare short name (e.g. `Book`) to its fully-qualified
      # owner (`Library::Book`) when unambiguous. Returns nil otherwise.
      #
      # @param short [String]
      # @return [String, nil]
      def resolve_short_name(short)
        short_name_map[short.to_s]
      end

      # Regex matching bare short names of namespaced models. Used by the
      # dependency scanner to surface references like `Book.new`
      # inside the `Library` module, which the full-name regex misses.
      #
      # @return [Regexp]
      def short_names_regex
        @short_names_regex ||= build_short_names_regex
      end

      # Clear cache (call at the start of each extraction run)
      def reset!
        @model_names = nil
        @model_names_regex = nil
        @short_name_map = nil
        @short_names_regex = nil
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

      # Build short-name → full-name mapping. A short name that appears on
      # multiple fully-qualified models resolves to nil so ambiguity bubbles
      # up (instead of silently picking one). Bare top-level names
      # (no `::`) map to themselves.
      def build_short_name_map
        map = {}
        model_names.each do |full|
          short = full.split('::').last
          map[short] = if map.key?(short) && map[short] != full
                         nil # mark ambiguous
                       else
                         full
                       end
        end
        map
      end

      def build_short_names_regex
        unambiguous = short_name_map.select { |short, full| full && short != full }.keys
        return /(?!)/ if unambiguous.empty?

        # Match the short name only when:
        # - NOT preceded by `::`, `.`, or another word char (avoids
        #   double-counting the full-name hit + rejects `RareBook`).
        # - Followed by a recognisable constant-use context: method call
        #   (`.` / `(`), namespace (`::`), list boundary (`,` / `)` / `]`),
        #   or end-of-line. This filters out mentions inside sentences
        #   (" ... update Book later") and inside string literals
        #   that lack a follow-up method call (`"Book"` alone).
        names = unambiguous.map { |n| Regexp.escape(n) }.join('|')
        /(?<![:.\w])(?:#{names})\b(?=\s*(?:\.|::|\(|,|\)|\]|=(?!=)|$))/
      end
    end
  end
end
