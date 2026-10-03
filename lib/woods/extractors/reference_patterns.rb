# frozen_string_literal: true

require 'strscan'
require_relative 'source_nesting'
require_relative 'lexical_constant'

module Woods
  module Extractors
    # Regexes for "this source references that class", shared by every site
    # that scans Ruby text for service, job/worker, and mailer references.
    #
    # Three implementations of "detect an enqueue" used to disagree pairwise —
    # the scanner missed `*Worker` and `.set(…)`, JobExtractor missed
    # `*Worker`, CallbackAnalyzer missed `.set(…)` — so which units recorded
    # an edge to a job depended on which extractor happened to look (EXTA-4).
    # They all use {.job_enqueues} now.
    #
    # Every pattern is namespace-capable (EXTA-2). Since G-1 a namespaced
    # unit's identifier is fully qualified (`Billing::ChargeService`), so a
    # `\w+`-only capture recorded `ChargeService` — an edge target matching no
    # node, invisible to `dependents`, PageRank, and the incremental blast
    # radius. A reference is the constant chain up to its last segment that
    # carries the suffix and the right follower, so
    # `Billing::ChargeService::VERSION` still targets +Billing::ChargeService+.
    #
    # Source is uncontrolled, so the scan is one linear pass over constant
    # chains. It returns what scanning `((?:\w+::)*\w+Service)(?:\.|::)` (and
    # the mailer and job forms) returned, without that pattern's polynomial
    # backtracking.
    module ReferencePatterns
      # Async dispatch methods that enqueue a job. `set` is ActiveJob's
      # delayed-enqueue entry point (`SyncJob.set(wait: 5).perform_later`).
      ENQUEUE_METHODS = %w[perform_later perform_async perform_in perform_at].freeze

      # A chain of `::`-joined word segments, read whole.
      CONSTANT_CHAIN = /\w++(?:::\w++)*+/

      # Every rule's segment ends in a capitalized suffix (Service, Mailer,
      # Job, Worker), so a chain with no capital letter cannot qualify and is
      # skipped before it is split. Ordinary text is mostly such chains.
      CAPITAL = /[A-Z]/

      # `FooService.call` / `FooService::new`.
      SERVICE_RULE = { segment: /\A\w+Service\z/, follower: /\G(?:\.|::)/ }.freeze

      # `FooMailer.welcome`.
      MAILER_RULE = { segment: /\A\w+Mailer\z/, follower: /\G\./ }.freeze

      # `FooJob.perform_later` / `HardWorker.perform_async` /
      # `SyncJob.set(wait: …).perform_later`.
      JOB_ENQUEUE_RULE = {
        segment: /\A\w+(?:Job|Worker)\z/,
        follower: /\G\.(?:#{ENQUEUE_METHODS.map { |m| Regexp.escape(m) }.join('|')}|set\b)/
      }.freeze

      module_function

      # @param source [String]
      # @return [Array<String>] Service references in source order, repeats kept
      def service_references(source)
        references(source, **SERVICE_RULE)
      end

      # @param source [String]
      # @return [Array<String>] Mailer references in source order, repeats kept
      def mailer_references(source)
        references(source, **MAILER_RULE)
      end

      # @param source [String]
      # @param enclosing [Array<String>] names of the scopes around the whole
      #   of +source+, innermost first, when it is an excerpt (a method body
      #   cut out of its class)
      # @return [Array<String>] Enqueued job classes in source order, repeats kept
      def job_enqueues(source, enclosing: [])
        references(source, **JOB_ENQUEUE_RULE, enclosing: enclosing)
      end

      # Each constant chain contributes at most one reference: the chain up
      # to its last segment that matches `segment` and is followed by
      # `follower`. Scanning resumes after the follower, which can end
      # inside the next word (`Job.perform_laterX`), as the regex did.
      #
      # Positions are byte offsets kept by a StringScanner. A character
      # offset into a UTF-8 string (`MatchData#begin`, `String#[]`) is
      # counted from the string's start on every call, which made this loop
      # quadratic in the size of ordinary text.
      #
      # @param source [String]
      # @param segment [Regexp] Anchored test for one chain segment
      # @param follower [Regexp] `\G`-anchored test at the segment's end
      # @param enclosing [Array<String>] scopes around the whole of +source+
      # @return [Array<String>]
      def references(source, segment:, follower:, enclosing: [])
        found = []
        scanner = StringScanner.new(source)
        while scanner.skip_until(CONSTANT_CHAIN)
          chain = scanner.matched
          next unless chain.match?(CAPITAL)

          chain_end = scanner.pos
          start = chain_end - chain.bytesize
          finish, follower_end = last_qualifying_end(scanner, chain, chain_end, segment, follower)
          if finish
            found << [source.byteslice(start, finish - start), start]
            scanner.pos = follower_end
          else
            scanner.pos = chain_end
          end
        end
        resolve_lexically(source, found, enclosing)
      end

      # Name each reference the way Ruby's constant lookup at its call site
      # would: `PingJob` inside `class Shipment` is `Shipment::PingJob` when
      # that constant exists. A reference stays as written outside any class
      # or module, after an explicit `::`, or when no candidate is loaded.
      #
      # @param source [String]
      # @param found [Array<Array(String, Integer)>] reference text and the
      #   byte offset it starts at
      # @param enclosing [Array<String>] scopes around the whole of +source+,
      #   outside every scope it declares
      # @return [Array<String>]
      def resolve_lexically(source, found, enclosing = [])
        return [] if found.empty?

        nesting = NestingSweep.new(SourceNesting.lexical_scopes(source) || [])
        modules = {}
        resolved = {}
        found.map do |text, offset|
          innermost, scopes = nesting.at(offset)
          scopes += enclosing if enclosing.any?
          next text if scopes.empty? || (offset >= 2 && source.byteslice(offset - 2, 2) == '::')

          resolved[[text, innermost.object_id]] ||= LexicalConstant.resolve(text, scopes, modules: modules)
        end
      end

      # The scopes open at ascending offsets, in one pass over scopes listed
      # outer-before-inner in source order (the order
      # {SourceNesting.lexical_scopes} returns).
      class NestingSweep
        # @param scopes [Array<Array(Integer, Integer, String)>]
        def initialize(scopes)
          @scopes = scopes
          @next = 0
          @open = []
          @names = {}.compare_by_identity
        end

        # @param offset [Integer] no smaller than the previous call's
        # @return [Array(Array, Array<String>)] the innermost scope containing
        #   +offset+ (nil at the top level), and the names of every scope
        #   containing it, innermost first
        def at(offset)
          while @next < @scopes.size && @scopes[@next][0] <= offset
            enter(@scopes[@next])
            @next += 1
          end
          close_before(offset)
          innermost = @open.last
          [innermost, @names[innermost] ||= @open.reverse.map(&:last)]
        end

        private

        def enter(scope)
          close_before(scope[0])
          @open << scope
        end

        def close_before(offset)
          @open.pop while @open.any? && @open.last[1] <= offset
        end
      end
      private_constant :NestingSweep

      # @return [Array(Integer, Integer), nil] Byte offsets where the
      #   reference and its follower end
      def last_qualifying_end(scanner, chain, chain_end, segment, follower)
        finish = chain_end
        chain.split('::').reverse_each do |part|
          if part.match?(segment)
            scanner.pos = finish
            length = scanner.match?(follower)
            return [finish, finish + length] if length
          end

          finish -= part.bytesize + 2
        end
        nil
      end
    end
  end
end
