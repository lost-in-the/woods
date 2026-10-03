# frozen_string_literal: true

require 'strscan'

module Woods
  module Extractors
    # Turns one inline code span or fence line into candidate mentions of
    # indexed units: constant paths, repository file paths, rake tasks and
    # routes. Candidates are a pure function of the text; whether one names a
    # unit is decided later against the full index ({Woods::DocReferences}).
    #
    # Text is split on whitespace and each word is classified once, so the
    # cost is linear in the text.
    #
    # @example
    #   DocMentions.scan('rake widgets:sync updates Widget')
    #   # => [["rake_task", "widgets:sync"], ["constant", "Widget"]]
    module DocMentions
      HTTP_VERBS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS].freeze
      # Longer words are not identifiers anyone wrote by hand.
      MAX_WORD_BYTES = 256

      CONSTANT = /[A-Z][A-Za-z0-9_]*+(?:::[A-Z][A-Za-z0-9_]*+)*+/
      CAPITAL = /[A-Z]/
      WORD_CHARACTERS = /[A-Za-z0-9_]*+/
      REPOSITORY_PATH = %r{\A(?:[A-Za-z0-9_.@-]++/)++[A-Za-z0-9_.@-]++\z}
      TASK_NAME = /\A[a-z_][A-Za-z0-9_]*+(?::[A-Za-z0-9_]++)*+/
      BEFORE_COLON = /\A[^:]*+/
      BEFORE_QUERY = /\A[^?#]*+/
      LEADING = '([{<\'"`'.bytes.freeze
      TRAILING = ')]}>\'"`,;.:!?'.bytes.freeze
      private_constant :CONSTANT, :CAPITAL, :WORD_CHARACTERS, :REPOSITORY_PATH, :TASK_NAME, :BEFORE_COLON,
                       :BEFORE_QUERY, :LEADING, :TRAILING

      module_function

      # @param text [String] one inline code span or fence line
      # @return [Array<Array(String, String)>] `[kind, text]` in order of appearance
      def scan(text)
        words = text.split.map { |word| word.bytesize > MAX_WORD_BYTES ? '' : trim(word) }
        words.each_with_index.flat_map do |word, index|
          next [] if word.empty?

          following = words[index + 1].to_s
          command_mentions(word, following) || word_mentions(word)
        end
      end

      # @return [Array, nil] route or rake mention when +word+ introduces one
      def command_mentions(word, following)
        if HTTP_VERBS.include?(word)
          route = route_path(following)
          return [['route', "#{word} #{route}"]] if route
        elsif rake_command?(word)
          task = task_name(following, namespaced: !word.end_with?('rake'))
          return [['rake_task', task]] if task
        end
        nil
      end

      def word_mentions(word)
        path = repository_path(word)
        return [['path', path]] if path
        # A URL is not a constant path, and neither is a command-line flag (`-X`).
        return [] if word.include?('://') || word.start_with?('-')

        constants(word).map { |constant| ['constant', constant] }
      end

      def rake_command?(word)
        %w[rake rails].include?(word) || word.end_with?('/rake', '/rails')
      end

      def route_path(word)
        return nil unless word.start_with?('/')

        path = word[BEFORE_QUERY]
        path.size > 1 ? path.delete_suffix('/') : path
      end

      def task_name(word, namespaced:)
        name = word[TASK_NAME]
        return nil unless name
        return nil unless name.size == word.size || word[name.size] == '['
        return nil if namespaced && !name.include?(':')

        name
      end

      def repository_path(word)
        return nil unless word.include?('/') && !word.start_with?('/') && !word.include?('://')

        path = word[BEFORE_COLON].delete_prefix('./')
        return nil unless REPOSITORY_PATH.match?(path)

        File.extname(path).size.between?(2, 9) ? path : nil
      end

      # A constant starts at a capital that no word character precedes.
      def constants(word)
        scanner = StringScanner.new(word)
        found = []
        while scanner.skip_until(CAPITAL)
          start = scanner.pos - 1
          if start.positive? && word_byte?(word.getbyte(start - 1))
            scanner.skip(WORD_CHARACTERS)
          else
            scanner.pos = start
            found << scanner.scan(CONSTANT)
          end
        end
        found
      end

      def word_byte?(byte)
        byte == 95 || byte.between?(48, 57) || byte.between?(65, 90) || byte.between?(97, 122)
      end

      def trim(word)
        first = 0
        last = word.bytesize
        first += 1 while first < last && LEADING.include?(word.getbyte(first))
        last -= 1 while last > first && TRAILING.include?(word.getbyte(last - 1))
        word.byteslice(first, last - first)
      end
    end
  end
end
