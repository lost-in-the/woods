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
    class MemoCollector
      # @param collector [Collector] the parser to memoize
      def initialize(collector: Collector.new)
        @collector = collector
        @memo = {}
      end

      # @param source [String] original Ruby source
      # @return [Hash] frozen {Collector#call} result
      def call(source)
        @memo[Digest::SHA256.digest(source)] ||= deep_freeze(@collector.call(source))
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
