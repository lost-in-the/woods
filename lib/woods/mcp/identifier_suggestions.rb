# frozen_string_literal: true

module Woods
  module MCP
    # Near matches for an identifier the index does not hold.
    #
    # An agent that asks for `Subscription` when the unit is
    # `Billing::Subscription`, for a file path, or for `Controller#action`
    # otherwise gets a bare "not found" and spends another round trip on
    # `search`. The matches are read from the per-type index entries, so no
    # unit file is opened.
    module IdentifierSuggestions
      LIMIT = 5

      # Match tiers, best first. A lower tier always sorts ahead of a higher one.
      EXACT = 0
      PATH = 1
      SAME_NAME = 2
      NAMESPACED = 3
      SHORT_NAME = 4
      SPELLING = 5

      module_function

      # @param query [String] the identifier that was not found
      # @param entries [Enumerable<Hash>] index entries with 'identifier', 'type' and 'file_path'
      # @param limit [Integer] most suggestions to return
      # @return [Array<Hash>] `{ identifier:, type: }`, best match first
      def for(query, entries, limit: LIMIT)
        query = query.to_s.strip
        return [] if query.empty?

        entries = entries.select { |entry| entry.is_a?(Hash) && entry['identifier'].is_a?(String) }
        ranked = query.include?('/') ? path_matches(query, entries) : name_matches(query, entries)
        ranked.sort_by { |tier, entry| [tier, entry['identifier'].length, entry['identifier'], entry['type'].to_s] }
              .map { |_tier, entry| { identifier: entry['identifier'], type: entry['type'] } }
              .uniq.first(limit)
      end

      # @param suggestions [Array<Hash>] the result of {.for}
      # @return [String, nil] a sentence to append to a not-found message
      def sentence(suggestions)
        return nil if suggestions.empty?

        names = suggestions.map do |suggestion|
          suggestion[:type] ? "#{suggestion[:identifier]} (#{suggestion[:type]})" : suggestion[:identifier]
        end
        "Did you mean: #{names.join(', ')}?"
      end

      # @param message [String] a not-found message
      # @param suggestions [Array<Hash>] the result of {.for}
      # @return [String] the message, followed by the suggestions when there are any
      def append(message, suggestions)
        hint = sentence(suggestions)
        return message unless hint

        "#{message}#{'.' unless message.end_with?('.', '?', '!')} #{hint}"
      end

      # Units published from the file a path names. A leading `./`, an
      # absolute prefix and a trailing `:line` are ignored.
      def path_matches(query, entries)
        path = query.delete_prefix('./').sub(/:\d+\z/, '')
        entries.filter_map do |entry|
          file = entry['file_path']
          next unless file.is_a?(String) && !file.empty?

          [PATH, entry] if file == path || path.end_with?("/#{file}") || file.end_with?("/#{path}")
        end
      end

      def name_matches(query, entries)
        # `Controller#action` and `Model.scope` name a member of a unit.
        owner = query.split(/[#.]/, 2).first.to_s
        owner = query if owner.empty?
        wanted = normalize(owner)
        short = wanted.split('::').last
        ranked = entries.filter_map do |entry|
          tier = name_tier(entry['identifier'], owner, wanted, short)
          [tier, entry] if tier
        end
        ranked.empty? ? spelling_matches(owner, entries) : ranked
      end

      def name_tier(identifier, owner, wanted, short)
        return EXACT if identifier == owner

        candidate = normalize(identifier)
        return SAME_NAME if candidate == wanted
        return NAMESPACED if candidate.end_with?("::#{wanted}")

        SHORT_NAME if candidate.split('::').last == short
      end

      # A misspelled name, corrected against the indexed identifiers and
      # their last segments.
      def spelling_matches(owner, entries)
        return [] unless defined?(DidYouMean::SpellChecker)

        by_name = Hash.new { |hash, key| hash[key] = [] }
        entries.each do |entry|
          by_name[entry['identifier']] << entry
          by_name[entry['identifier'].split('::').last] << entry
        end
        corrected = DidYouMean::SpellChecker.new(dictionary: by_name.keys).correct(owner)
        corrected.flat_map { |name| by_name[name] }.uniq.map { |entry| [SPELLING, entry] }
      end

      def normalize(name)
        name.downcase.delete('_')
      end
    end
  end
end
