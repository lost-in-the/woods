# frozen_string_literal: true

require 'json'

module Woods
  # The part of a unit's JSON its extractor produced.
  #
  # A published unit also carries what later passes add after registration:
  # `dependents`, Git facts, and source-reference edges and occurrence metadata.
  # A freshly extracted unit has none of them yet, so the two are comparable
  # only in this form. Flow annotations stay in: a controller that carries
  # them must be re-registered for its flow documents to be reassembled.
  #
  # @example
  #   ExtractedForm.of(published, reference_edges: added) == ExtractedForm.of(fresh)
  module ExtractedForm
    module_function

    # @param data [Hash] string-keyed unit JSON
    # @param reference_edges [Array<Hash>] string-keyed edges the
    #   source-reference pass added to this unit
    # @return [String, nil] canonical JSON, or nil when a recorded reference
    #   edge is absent from the unit
    def of(data, reference_edges: [])
      dependencies = own_dependencies(data['dependencies'], reference_edges)
      return nil unless dependencies

      form = data.except('extracted_at')
      form['dependents'] = []
      form['dependencies'] = dependencies
      form['metadata'] = without_git(form['metadata']) if form['metadata'].is_a?(Hash)
      JSON.generate(form)
    end

    # @param dependencies [Array<Hash>, nil] published edges
    # @param reference_edges [Array<Hash>, nil] edges the reference pass added
    # @return [Array<Hash>, nil] the extractor's own edges, or nil when an
    #   added edge is not among them
    def own_dependencies(dependencies, reference_edges)
      own = Array(dependencies).dup
      Array(reference_edges).each do |edge|
        position = own.index(edge)
        return nil unless position

        own.delete_at(position)
      end
      own
    end

    # @param metadata [Hash]
    # @return [Hash] metadata without Git facts and pass-derived references
    def without_git(metadata)
      stripped = metadata.except('git', 'references')
      contributors = stripped['source_contributors']
      return stripped unless contributors.is_a?(Array)

      stripped['source_contributors'] = contributors.map do |record|
        record.is_a?(Hash) ? record.except('git') : record
      end
      stripped
    end
  end
end
