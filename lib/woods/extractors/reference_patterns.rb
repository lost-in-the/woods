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
    # They all use {JOB_ENQUEUE} now.
    #
    # Every pattern is namespace-capable (EXTA-2). Since G-1 a namespaced
    # unit's identifier is fully qualified (`Billing::ChargeService`), so a
    # `\w+`-only capture recorded `ChargeService` — an edge target matching no
    # node, invisible to `dependents`, PageRank, and the incremental blast
    # radius. The leading `(?:\w+::)*` is greedy but backtracks to the last
    # segment carrying the suffix, so `Billing::ChargeService::VERSION` still
    # targets +Billing::ChargeService+.
    module ReferencePatterns
      # Async dispatch methods that enqueue a job. `set` is ActiveJob's
      # delayed-enqueue entry point (`SyncJob.set(wait: 5).perform_later`).
      ENQUEUE_METHODS = %w[perform_later perform_async perform_in perform_at].freeze

      # `FooService.call` / `FooService::new`, namespace included.
      SERVICE_REFERENCE = /((?:\w+::)*\w+Service)(?:\.|::)/

      # `FooMailer.welcome`, namespace included.
      MAILER_REFERENCE = /((?:\w+::)*\w+Mailer)\./

      # `FooJob.perform_later` / `HardWorker.perform_async` /
      # `SyncJob.set(wait: …).perform_later`, namespace included.
      JOB_ENQUEUE =
        /((?:\w+::)*\w+(?:Job|Worker))\.(?:#{ENQUEUE_METHODS.map { |m| Regexp.escape(m) }.join('|')}|set\b)/
    end
  end
end
