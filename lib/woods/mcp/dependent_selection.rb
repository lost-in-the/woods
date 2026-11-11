# frozen_string_literal: true

require 'set'
require_relative 'dependent_families'

module Woods
  module MCP
    # Applies a `dependents` `families:` selector to a finished, classified
    # traversal. The walk itself is untouched: a row outside the selection
    # was still expanded, so a selected row reached only through it is
    # listed. Selection runs before paging, so pages, `nodes_total` and the
    # selected counts all describe the selected rows.
    #
    # Listed rows keep their depth and only the recorded edges between listed
    # rows: a row reached through an unselected one is never shown as a
    # direct dependent of the root. `hidden_deps` counts the edges left out
    # of a row's `deps`; `reached_through_hidden` marks a row none of whose
    # recorded parents is listed. With `explain`, unselected ancestors stay
    # in the witness forest as context, marked `selection: "not_selected"`.
    class DependentSelection
      # @param result [Hash] a found traversal result {DependentFamilies.annotate} classified
      # @param selector [Hash] {DependentFamilies.resolve_selector}'s answer
      # @param include_tests [Boolean] count mapped tests toward the selected headline
      # @return [DependentSelection]
      def self.apply(result, selector, include_tests: DependentFamilies.include_tests?)
        new(result, selector).tap { |selection| selection.apply(include_tests) }
      end

      def initialize(result, selector)
        @result = result
        @selector = selector
        @root = result[:root]
        @selected = Set.new
      end

      # Filter the rows and record the selection's counts.
      #
      # @param include_tests [Boolean]
      # @return [void]
      def apply(include_tests)
        return if @result[:found] == false

        categories = @selector.fetch(:categories).to_set
        nodes = @result.fetch(:nodes)
        # In walk order, which paging and the renderers keep.
        listed = {}
        nodes.each do |identifier, entry|
          next unless identifier == @root || categories.include?(entry[:category])

          @selected.add(identifier)
          listed[identifier] = entry
        end
        rewire(nodes, listed)
        @result[:nodes] = listed
        @result[:selection] = summary(nodes, listed, include_tests)
      end

      # Label the paged witnesses with whether each was selected. Call after
      # {TraversalEvidencePage.apply}, which decides which witnesses remain.
      #
      # @return [void]
      def mark_witnesses
        witnesses = @result.dig(:explanation, :witnesses)
        return unless witnesses

        witnesses.each do |identifier, witness|
          witness[:selection] = if identifier == @root
                                  'root'
                                else
                                  @selected.include?(identifier) ? 'selected' : 'not_selected'
                                end
        end
      end

      private

      # Keep each listed row's edges to listed rows; count the rest.
      def rewire(nodes, listed)
        listed_parent = Set.new
        nodes.each do |identifier, entry|
          next unless listed.key?(identifier)

          deps = Array(entry[:deps])
          kept = deps.select { |dep| @selected.include?(dep) }
          listed_parent.merge(kept)
          entry[:hidden_deps] = deps.size - kept.size if kept.size < deps.size
          entry[:deps] = kept
        end
        listed.each do |identifier, entry|
          next if identifier == @root || listed_parent.include?(identifier)

          entry[:reached_through_hidden] = true
        end
      end

      def summary(nodes, listed, include_tests)
        rows = listed.reject { |identifier, _| identifier == @root }.values
        counts = DependentFamilies.summary(rows, include_tests, @result)
        traversed = nodes.size - (nodes.key?(@root) ? 1 : 0)
        {
          requested: @selector.fetch(:requested),
          categories: @selector.fetch(:categories),
          counts: counts.merge(not_selected: traversed - rows.size)
        }
      end
    end
  end
end
