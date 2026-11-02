# frozen_string_literal: true

require 'digest'
require_relative 'collector'

module Woods
  module SourceReferences
    # A {Collector} that parses each distinct source once for its lifetime.
    #
    # One instance spans one extraction run, so the PORO sweep and the
    # source-reference pass share a parse of the same bytes. Entries are keyed
    # by content digest, so a changed file is parsed again. Analyses are deep
    # frozen: several consumers read the same object.
    #
    # One lock covers the memo and the parse. A {Collector} keeps the record
    # it is building in instance state for the length of one `call`, and
    # both adapters keep per-parse state too, so under `concurrent_extraction`
    # two extractor threads parsing through the same instance interleaved
    # their records when concurrent extraction shares one instance. Parsing holds the GVL anyway, so serializing
    # it costs the threads nothing they could have had.
    class MemoCollector
      # @param collector [Collector] the parser to memoize
      def initialize(collector: Collector.new)
        @collector = collector
        @memo = {}
        @lock = Mutex.new
      end

      # @param source [String] original Ruby source
      # @return [Hash] frozen {Collector#call} result
      def call(source)
        key = Digest::SHA256.digest(source)
        @lock.synchronize do
          @memo[key] ||= deep_freeze(@collector.call(source))
        end
      end

      private

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |item| deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
