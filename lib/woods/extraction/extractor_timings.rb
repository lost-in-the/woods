# frozen_string_literal: true

module Woods
  module Extraction
    # Wall time spent in each extractor family during one run.
    #
    # A full extraction times every family's `extract_all`; an incremental
    # run or a targeted refresh times only the families it reaches, per file
    # or wholesale, so the published hash names what that run actually paid
    # for. Durations accumulate per family across calls and are read on the
    # monotonic clock, so a wall-clock adjustment mid-run cannot produce a
    # negative value. Safe to call from the concurrent extraction threads.
    #
    # The collector is a run fact, not a profiler: it answers which family a
    # slow run should be profiled under (LOS-130), nothing finer.
    class ExtractorTimings
      # How many families the task summary names before it stops.
      SUMMARY_TOP = 8

      def initialize
        @seconds = Hash.new(0.0)
        @mutex = Mutex.new
      end

      # Time one extractor call and add it to the family's total.
      #
      # The time is recorded even when the block raises, so a family that
      # failed after a long run is still accounted for in the log.
      #
      # @param key [Symbol, String] extractor key, as in {Extractor::EXTRACTORS}
      # @return [Object] whatever the block returned
      def time(key)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        @mutex.synchronize { @seconds[key.to_s] += elapsed }
      end

      # @return [Boolean] whether no family was timed
      def empty?
        @mutex.synchronize { @seconds.empty? }
      end

      # The manifest shape: string keys sorted by family, seconds rounded to
      # three decimals. A fresh hash each call.
      #
      # @return [Hash{String => Float}]
      def to_h
        @mutex.synchronize { @seconds.sort.to_h { |key, seconds| [key, seconds.round(3)] } }
      end

      # One line for a task summary: the slowest families first, the total,
      # and how many families the run timed in all.
      #
      # @param timings [Hash{String => Numeric}, nil] a {#to_h} or the
      #   manifest's `extractor_timings`
      # @param top [Integer] how many families to name
      # @return [String, nil] nil when nothing was timed
      def self.line(timings, top: SUMMARY_TOP)
        return nil if timings.nil? || timings.empty?

        ranked = timings.sort_by { |key, seconds| [-seconds.to_f, key.to_s] }
        named = ranked.first(top).map { |key, seconds| "#{key} #{seconds_label(seconds)}" }
        "Extractor timings (#{scope_label(ranked.size, top)}, total #{seconds_label(timings.values.sum(&:to_f))}): " \
          "#{named.join(', ')}"
      end

      # @param count [Integer] families timed
      # @param top [Integer] families named
      # @return [String]
      def self.scope_label(count, top)
        return "top #{top} of #{count}" if count > top

        "#{count} #{count == 1 ? 'family' : 'families'}"
      end

      # Tenths of a second, rounded half up (1.25 reads 1.3s, as the per-type
      # log lines round), never the printf half-even of the raw float.
      #
      # @param seconds [Numeric]
      # @return [String]
      def self.seconds_label(seconds)
        format('%.1fs', seconds.to_f.round(1))
      end

      private_class_method :scope_label, :seconds_label
    end
  end
end
