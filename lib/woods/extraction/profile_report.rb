# frozen_string_literal: true

require 'json'
require_relative '../atomic_file'
require_relative '../version'

module Woods
  module Extraction
    # Structured per-phase and whole-run profiling report for an extraction run.
    #
    # Captures monotonic wall time, process CPU time, object allocation deltas,
    # GC counts, and post-phase live heap slots without external dependencies.
    # Off unless `WOODS_PROFILE=1` or `WOODS_PROFILE_OUT` is set.
    class ProfileReport
      SCHEMA_VERSION = 1
      TOP_LIMIT = 10
      TABLE_HEADER = '  phase                       wall_ms     cpu_ms    allocations     gc'
      TABLE_ROW_FORMAT = '  %<name>-24s %<wall_ms>10.3f %<cpu_ms>10.3f %<allocations>14d %<gc_count>6d'

      attr_reader :operation, :phases, :total, :extractor_timings

      # @param operation [String] `'full'`, `'incremental'`, or `'refresh'`
      def initialize(operation:)
        @operation = operation.to_s
        @phases = []
        @total = nil
        @extractor_timings = {}
        @gc_buf = {}
        @started = nil
      end

      # Capture baseline counters for the whole run.
      #
      # @return [self]
      def start
        @started = [monotonic_now, cpu_now, gc_snapshot]
        self
      end

      # Measure one named phase and append its metrics to {#phases}.
      #
      # Calls `Process.clock_gettime(Process::CLOCK_MONOTONIC)` exactly twice
      # (before and after the block) so callers and specs observing monotonic
      # phase timing see the same clock sequence as raw timing.
      #
      # @param name [String]
      # @return [Array(Object, Float)] `[block_result, elapsed_wall_seconds]`
      def measure_phase(name)
        started_wall = monotonic_now
        started_cpu = cpu_now
        before_gc = gc_snapshot
        result = yield
        elapsed_wall = monotonic_now - started_wall
        elapsed_cpu = cpu_now - started_cpu
        @phases << build_phase_entry(name, elapsed_wall, elapsed_cpu, before_gc, gc_snapshot)
        [result, elapsed_wall]
      end

      # Finalize whole-run counters, even when the run aborted with an error.
      #
      # @param extractor_timings [Hash{String => Numeric}]
      # @param error [Exception, nil]
      # @return [Float] total elapsed wall seconds
      def finish(extractor_timings: {}, error: nil)
        started_wall, started_cpu, started_gc = @started
        elapsed_wall = started_wall ? monotonic_now - started_wall : 0.0
        elapsed_cpu = started_cpu ? cpu_now - started_cpu : 0.0
        after_gc = gc_snapshot
        @extractor_timings = extractor_timings.to_h
        @total = build_phase_entry('total', elapsed_wall, elapsed_cpu, started_gc || after_gc, after_gc)
                 .except(:name)
                 .merge(status: error ? 'error' : 'ok', error_class: error&.class&.name)
        elapsed_wall
      end

      # @return [Hash] JSON-serializable structured report
      def to_h
        {
          schema_version: SCHEMA_VERSION, operation: @operation, woods_version: Woods::VERSION,
          ruby_version: RUBY_VERSION, rails_version: current_rails_version, pid: Process.pid,
          gc_measure_total_time: GC.respond_to?(:measure_total_time) ? GC.measure_total_time : nil,
          total: @total, phases: @phases, extractor_timings: @extractor_timings,
          top_phases_by_wall: ranked_phases(:wall_ms), top_phases_by_allocations: ranked_phases(:allocations)
        }
      end

      # Write the structured profile report atomically as formatted JSON.
      #
      # @param path [String, Pathname]
      # @return [void]
      def write_json(path)
        AtomicFile.write(path, "#{JSON.pretty_generate(to_h)}\n")
      end

      # Compact human-readable breakdown of the slowest phases.
      #
      # @param limit [Integer]
      # @return [String]
      def summary_table(limit: TOP_LIMIT)
        status = @total ? @total[:status] : 'running'
        wall = @total ? @total[:wall_ms] : 0.0
        allocs = @total ? @total[:allocations] : 0
        lines = [
          "Woods Profile (#{@operation}, status: #{status}) — total wall_ms: #{wall}, allocations: #{allocs}",
          TABLE_HEADER
        ]
        ranked_phases(:wall_ms, limit: limit).each { |phase| lines << format(TABLE_ROW_FORMAT, phase) }
        lines.join("\n")
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def cpu_now
        times = Process.times
        times.utime + times.stime
      end

      def gc_snapshot
        GC.stat(@gc_buf)
        [
          @gc_buf[:total_allocated_objects].to_i, @gc_buf[:count].to_i,
          @gc_buf[:minor_gc_count].to_i, @gc_buf[:major_gc_count].to_i, @gc_buf[:heap_live_slots].to_i
        ]
      end

      def build_phase_entry(name, elapsed_wall, elapsed_cpu, before_gc, after_gc)
        {
          name: name.to_s, wall_ms: (elapsed_wall * 1000.0).round(3), cpu_ms: (elapsed_cpu * 1000.0).round(3),
          allocations: [after_gc[0] - before_gc[0], 0].max, gc_count: [after_gc[1] - before_gc[1], 0].max,
          minor_gc_count: [after_gc[2] - before_gc[2], 0].max, major_gc_count: [after_gc[3] - before_gc[3], 0].max,
          heap_live_slots: after_gc[4]
        }
      end

      def ranked_phases(metric, limit: TOP_LIMIT)
        @phases.sort_by { |phase| [-phase[metric], phase[:name]] }.first(limit)
      end

      def current_rails_version
        defined?(Rails) && Rails.respond_to?(:version) ? Rails.version.to_s : nil
      end
    end
  end
end
