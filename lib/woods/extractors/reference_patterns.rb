# frozen_string_literal: true

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
      # @return [Array<String>] Enqueued job classes in source order, repeats kept
      def job_enqueues(source)
        references(source, **JOB_ENQUEUE_RULE)
      end

      # Each constant chain contributes at most one reference: the chain up
      # to its last segment that matches `segment` and is followed by
      # `follower`. Scanning resumes after the follower, which can end
      # inside the next word (`Job.perform_laterX`), as the regex did.
      #
      # @param source [String]
      # @param segment [Regexp] Anchored test for one chain segment
      # @param follower [Regexp] `\G`-anchored test at the segment's end
      # @return [Array<String>]
      def references(source, segment:, follower:)
        found = []
        position = 0
        while (chain = CONSTANT_CHAIN.match(source, position))
          finish, follower_end = last_qualifying_end(source, chain, segment, follower)
          if finish
            found << source[chain.begin(0)...finish]
            position = follower_end
          else
            position = chain.end(0)
          end
        end
        found
      end

      # @return [Array(Integer, Integer), nil] Source offsets where the
      #   reference and its follower end
      def last_qualifying_end(source, chain, segment, follower)
        finish = chain.end(0)
        chain[0].split('::').reverse_each do |part|
          if part.match?(segment) && (follow = follower.match(source, finish))
            return [finish, follow.end(0)]
          end

          finish -= part.length + 2
        end
        nil
      end
    end
  end
end
