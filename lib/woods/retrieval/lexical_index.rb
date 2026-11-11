# frozen_string_literal: true

require 'digest'
require 'json'
require 'set'
require 'active_support/inflector'
require_relative 'query_classifier'
require_relative 'search_executor'
require_relative 'lexical_token_cache'

module Woods
  module Retrieval
    # Immutable field-aware lexical snapshot. Only published unit values enter
    # the vocabulary; bookkeeping and arbitrary JSON keys cannot become hits.
    class LexicalIndex
      FIELD_WEIGHTS = { 'identifier' => 4.0, 'file_path' => 2.0, 'source_code' => 1.0, 'runtime' => 2.0 }.freeze
      RUNTIME_FIELDS = %w[callbacks associations validations scopes concerns included_modules
                          methods instance_methods class_methods actions routes columns table_name
                          description purpose dependencies].freeze
      DEFAULT_LIMIT = 20
      K1 = 1.2
      B = 0.75
      # Bump when {#tokenize} or {#field_values} would split the same text
      # differently: it is part of every {LexicalTokenCache} key.
      TOKENIZER_VERSION = 1
      # The tokenizer's patterns: a run of letters and digits, an upper-case
      # letter, and the two CamelCase boundaries. The Unicode set is the
      # definition; the ASCII set is the same definition restricted to ASCII
      # text, where \p{L} is A-Z and a-z, \p{N} is 0-9, and the case
      # properties are the two ASCII letter ranges, so an ASCII-only value
      # tokenizes identically through either set and several times faster
      # through the ASCII one.
      UNICODE_PATTERNS = [/[\p{L}\p{N}]+/u, /\p{Lu}/u, /(\p{Ll}|\d)(\p{Lu})/u, /(\p{Lu})(\p{Lu}\p{Ll})/u].freeze
      ASCII_PATTERNS = [/[A-Za-z0-9]+/, /[A-Z]/, /([a-z0-9])([A-Z])/, /([A-Z])([A-Z][a-z])/].freeze
      STOP_WORDS = QueryClassifier::STOP_WORDS
      private_constant :UNICODE_PATTERNS, :ASCII_PATTERNS, :STOP_WORDS
      # +terms+ is the document's distinct vocabulary and +lengths+ its
      # per-field token totals, tallied once at build so a view's statistics
      # come from the tallies, not from the token counts again. +digest+ is
      # the {.field_digest} of its indexed text, the token cache's key.
      Document = Struct.new(:key, :unit, :fields, :terms, :lengths, :digest, keyword_init: true)
      private_constant :Document

      # The indexed units by key: immutable, shared with every candidate's
      # +metadata+ and with the scope corpus the pipeline keeps (F6 step 2).
      #
      # @return [Hash{String => Hash}] in key order
      attr_reader :units

      # This index's immutable documents by key, for a later build of the
      # next generation to reuse (+reusable:+).
      #
      # @return [Hash{String => Document}] frozen
      attr_reader :documents_by_key

      # The {.configuration_key} its documents were tokenized under, or nil
      # for a view over another index's documents. A later build reuses
      # documents only under the same key.
      #
      # @return [String, nil]
      attr_reader :configuration_key

      # @param metadata_store [MetadataStore::Interface] the records to index
      # @param units [Hash{String => Hash}, nil] the records to index instead,
      #   by key, each already deep-frozen JSON data owned by this index (for
      #   example parsed with +JSON.parse(text, freeze: true)+). They are kept
      #   as given: no copy and no second freeze.
      # @param token_cache [LexicalTokenCache, nil] tokenized fields to reuse
      #   from earlier builds in this process, and to keep for later ones
      # @param documents [Array<Document>, nil] an already-built, immutable
      #   document set to index instead (see {#restricted_to})
      # @param statistics [Array(Hash, Hash), nil] per-field length totals
      #   and document frequencies already known for +documents+
      # @param candidate_postings [Array(Hash, Hash), nil] the root's frozen
      #   token and exact-identifier postings, shared by restricted views
      # @param reusable [LexicalIndex, nil] an earlier index: a document of
      #   its {#documents_by_key} whose key names the very same unit object
      #   in +units+ is kept as it is, so a corpus read generation after
      #   generation rebuilds only the documents of changed units. Nothing is
      #   reused when it was tokenized under another {.configuration_key}.
      def initialize(metadata_store: nil, units: nil, token_cache: nil, documents: nil, statistics: nil,
                     candidate_postings: nil, reusable: nil)
        @stems = {}
        @configuration_key = self.class.configuration_key unless documents
        @reusable = reusable.documents_by_key if reusable && reusable.configuration_key == @configuration_key
        @documents = (documents || build_documents(metadata_store, units, token_cache)).freeze
        @documents_by_key = @documents.to_h { |doc| [doc.key, doc] }.freeze
        @units = @documents_by_key.transform_values(&:unit).freeze
        @totals, @frequencies = statistics || tally(@documents)
        @totals.freeze
        @frequencies.freeze
        @averages = @totals.to_h do |field, total|
          [field, @documents.empty? ? 1.0 : [total.fdiv(@documents.size), 1.0].max]
        end.freeze
        @shared_postings = !candidate_postings.nil?
        @postings, @exact_identifiers = candidate_postings
        build_candidate_postings unless documents
      end

      # Everything besides the indexed text that decides how a unit is
      # tokenized: the tokenizer version, the fields and their weights, the
      # stop words and the English singular rules the stemmer applies.
      #
      # @return [String] hex digest
      def self.configuration_key
        inflections = ActiveSupport::Inflector.inflections(:en)
        singulars = inflections.singulars.map { |rule, replacement| [rule.inspect, replacement] }
        Digest::SHA256.hexdigest(Marshal.dump([TOKENIZER_VERSION, FIELD_WEIGHTS.to_a, RUNTIME_FIELDS, K1, B,
                                               QueryClassifier::STOP_WORDS.to_a.sort, singulars,
                                               inflections.uncountables.to_a.sort]))
      end

      # The digest of a unit's {#field_values}: the exact text, field by
      # field, that tokenizing reads. Length-prefixed, so no two different
      # field sets share an encoding.
      #
      # @param values [Hash{String => Object}]
      # @return [String] raw SHA-256
      def self.field_digest(values)
        digest = Digest::SHA256.new
        values.each do |field, value|
          text = value.to_s
          digest << field << "\0" << text.encoding.name << "\0" << text.bytesize.to_s << "\0" << text
        end
        digest.digest
      end

      # A view over the eligible subset of this index's documents, answering
      # exactly what an index built over those records would: the BM25
      # statistics (field-length averages, document frequencies) are
      # recomputed over the subset and the documents, immutable, are shared,
      # so nothing is re-read or re-tokenised (F6 step 2). Candidate postings
      # hold keys only, shared with the root and resolved through this view's
      # own documents. Keeping a view does not retain unrelated document bodies
      # or their scoring tallies. A scoped request used to build a whole index
      # over the eligible records every time.
      # When the subset is most of the index, the statistics come from
      # subtracting the excluded documents' tallies from this index's own,
      # so a near-whole scope costs the exclusions, not the whole corpus.
      #
      # @param keys [Enumerable<String>] eligible document keys
      # @return [LexicalIndex]
      def restricted_to(keys)
        allowed = keys.to_set
        documents, excluded = @documents.partition { |doc| allowed.include?(doc.key) }
        statistics = subtract(excluded) if excluded.size < documents.size
        self.class.new(documents: documents, statistics: statistics,
                       candidate_postings: @postings && [@postings, @exact_identifiers])
      end

      def execute(query:, limit: DEFAULT_LIMIT, type_filter: nil, exclude_types: nil)
        terms = tokenize(query).uniq
        candidates = candidate_documents(query, terms).filter_map do |doc|
          next unless eligible?(doc.unit, type_filter, exclude_types)

          score, fields = score_document(doc, terms)
          score *= coordination(doc, terms)
          exact = doc.unit['identifier'].to_s.casecmp?(query.strip)
          score += 1.0 if exact
          fields << 'identifier:exact' if exact
          next unless score.positive?

          SearchExecutor::Candidate.new(identifier: doc.key, score: score, source: :lexical,
                                        metadata: doc.unit, matched_fields: fields.sort)
        end
        candidates.sort_by! do |candidate|
          [candidate.matched_fields.include?('identifier:exact') ? 0 : 1, -candidate.score, candidate.identifier]
        end
        SearchExecutor::ExecutionResult.new(candidates: candidates.first(limit), strategy: :lexical, query: query)
      end

      private

      # Only a root snapshot builds postings; restricted views share keys and
      # vocabulary, without keeping other documents' source/unit payload alive.
      def build_candidate_postings
        @postings = {}
        @exact_identifiers = {}
        @documents.each do |doc|
          doc.terms.each { |term| (@postings[term] ||= []) << doc.key }
          identifier = doc.unit['identifier'].to_s.downcase(:fold)
          (@exact_identifiers[identifier] ||= []) << doc.key
        end
        [@postings, @exact_identifiers].each do |postings|
          postings.each_value(&:freeze)
          postings.freeze
        end
      end

      # An exact identifier may contain only stop words, so it cannot rely on
      # token postings. The scorer still checks casecmp? before boosting it.
      # Common queries use the original scan to avoid building a large union.
      def candidate_documents(query, terms)
        return @documents unless @postings
        # Legacy scoped scans only inspect query.strip after eligibility.
        # Preserve that behavior for invalid inputs and empty views.
        return @documents if @shared_postings && (!query.is_a?(String) || @documents.empty?)

        lists = terms.filter_map { |term| @postings[term] if @frequencies.key?(term) }
        exact = @exact_identifiers[query.strip.downcase(:fold)]
        exact = exact.select { |key| @documents_by_key.key?(key) } if exact && @shared_postings
        lists << exact if exact
        return @documents if lists.sum(&:size) >= @documents.size

        selected = {}
        lists.each do |keys|
          keys.each do |key|
            doc = @documents_by_key[key]
            selected[key] = doc if doc
          end
        end
        selected.values
      end

      def build_documents(metadata_store, units, token_cache)
        cache_build = token_cache&.begin_build(@configuration_key)
        documents = if units
                      owned_documents(units, cache_build)
                    else
                      store_documents(metadata_store, cache_build)
                    end
        token_cache&.commit(cache_build)
        documents
      end

      # One JSON round trip copies a store's record into plain, unshared
      # JSON data, and the parse freezes it deeply.
      def store_documents(metadata_store, cache_build)
        metadata_store.all_identifiers.sort.map do |key|
          unit = metadata_store.find(key)
          raise ArgumentError, "missing unit metadata for #{key.inspect}" unless unit.is_a?(Hash)

          document(key, JSON.parse(JSON.generate(unit), freeze: true), cache_build)
        end
      end

      def owned_documents(units, cache_build)
        units.keys.sort.map do |key|
          unit = units.fetch(key)
          raise ArgumentError, "unit #{key.inspect} must be a frozen Hash" unless unit.is_a?(Hash) && unit.frozen?

          reused_document(key, unit, cache_build) || document(key, unit, cache_build)
        end
      end

      # An earlier index's document for the same unit object. Its tokens are
      # fetched from the build all the same, so the cache keeps them and
      # counts the reuse as it counts any other.
      def reused_document(key, unit, cache_build)
        previous = @reusable&.[](key)
        return unless previous && previous.unit.equal?(unit)

        cache_build&.fetch(previous.digest) { [previous.fields, previous.terms, previous.lengths] }
        previous
      end

      def document(key, unit, cache_build)
        values = field_values(unit)
        digest = self.class.field_digest(values)
        fields, terms, lengths = if cache_build
                                   cache_build.fetch(digest) { tokenized(values) }.drop(1)
                                 else
                                   tokenized(values)
                                 end
        Document.new(key: key.frozen? ? key : key.dup.freeze, unit: unit,
                     fields: fields, terms: terms, lengths: lengths, digest: digest.freeze).freeze
      end

      # @return [Array(Hash, Array, Hash)] per-field token counts, distinct
      #   terms and per-field token totals, all frozen
      def tokenized(values)
        fields = values.transform_values { |value| tokenize(value).tally.freeze }.freeze
        [fields, fields.values.flat_map(&:keys).uniq.freeze,
         fields.transform_values { |counts| counts.values.sum }.freeze]
      end

      # Per-field length totals and document frequencies over +documents+.
      #
      # @return [Array(Hash, Hash)]
      def tally(documents)
        totals = FIELD_WEIGHTS.to_h { |field, _| [field, 0] }
        frequencies = Hash.new(0)
        documents.each do |doc|
          doc.lengths.each { |field, length| totals[field] += length }
          doc.terms.each { |term| frequencies[term] += 1 }
        end
        [totals, frequencies]
      end

      # This index's statistics less the +excluded+ documents' tallies. The
      # totals are integer sums, so the result equals a fresh tally over the
      # remaining documents exactly; a term left with no document is dropped.
      def subtract(excluded)
        totals = @totals.dup
        frequencies = @frequencies.dup
        excluded.each do |doc|
          doc.lengths.each { |field, length| totals[field] -= length }
          doc.terms.each { |term| frequencies.delete(term) if (frequencies[term] -= 1).zero? }
        end
        [totals, frequencies]
      end

      # Terms: CamelCase and snake_case parts, singular (a question about
      # "labels" must reach a method named +set_label+), without stop
      # words. Each distinct term is singularized once per index.
      #
      # Only runs of letters and digits can hold a term, so the text is
      # scanned for those first and only a run with an upper-case letter is
      # split at its CamelCase boundaries. This yields exactly the terms of
      # splitting the whole text first (a boundary space can only fall
      # inside such a run), and most of a source file is neither. The split
      # run is scanned again after +downcase+, as the whole text was: a
      # lower-case form need not be letters and digits only ("İ" becomes
      # "i" and a combining dot, which ends a term).
      def tokenize(value)
        text = value.to_s
        word_run, upper, lower_upper, upper_upper_lower = text.ascii_only? ? ASCII_PATTERNS : UNICODE_PATTERNS
        terms = []
        text.scan(word_run) do |run|
          if run.match?(upper)
            terms.concat(run.gsub(lower_upper, '\1 \2').gsub(upper_upper_lower, '\1 \2').downcase.scan(word_run))
          else
            terms << run.downcase
          end
        end
        terms.reject! { |term| STOP_WORDS.include?(term) }
        terms.map! { |term| stem(term) }
      end

      # Interned, so a term reused from an earlier build and the same term
      # tokenized now are one String.
      def stem(term)
        @stems[term] ||= -(if term.length > 3 && term.match?(/\A\p{L}+\z/u)
                             ActiveSupport::Inflector.singularize(term)
                           else
                             term
                           end)
      end

      def field_values(unit)
        metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
        runtime = RUNTIME_FIELDS.filter_map { |key| metadata[key] || unit[key] }
        { 'identifier' => unit['identifier'], 'file_path' => unit['file_path'],
          'source_code' => unit['source_code'], 'runtime' => values_text(runtime) }
      end

      def values_text(value)
        case value
        when Hash then value.values.map { |child| values_text(child) }.join(' ')
        when Array then value.map { |child| values_text(child) }.join(' ')
        when String, Symbol, Numeric then value.to_s
        else ''
        end
      end

      def eligible?(unit, allowed, excluded)
        return allowed.map(&:to_s).include?(unit['type']) if allowed && !allowed.empty?

        !Array(excluded).map(&:to_s).include?(unit['type'])
      end

      # The share of the query's words a document holds anywhere, squared: a
      # unit that answers every word of a question outranks one that repeats
      # a single rare word in its name. A one-word query is unchanged.
      def coordination(doc, terms)
        return 1.0 if terms.size < 2

        held = terms.count { |term| doc.fields.each_value.any? { |counts| counts.key?(term) } }
        (held.to_f / terms.size)**2
      end

      def score_document(doc, terms)
        fields = []
        score = FIELD_WEIGHTS.sum do |field, weight|
          counts = doc.fields.fetch(field)
          normalization = K1 * (1 - B + (B * doc.lengths.fetch(field) / @averages.fetch(field)))
          terms.sum do |term|
            frequency = counts.fetch(term, 0)
            next 0.0 if frequency.zero?

            fields << "#{field}:#{term}"
            document_frequency = @frequencies.fetch(term)
            idf = Math.log(1 + ((@documents.size - document_frequency + 0.5) / (document_frequency + 0.5)))
            weight * idf * frequency * (K1 + 1) / (frequency + normalization)
          end
        end
        [score, fields]
      end
    end
  end
end
