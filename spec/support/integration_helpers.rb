# frozen_string_literal: true

require 'json'
require 'codebase_index/extracted_unit'

module IntegrationHelpers
  FIXTURE_PATH = File.expand_path('../fixtures/integration/extracted_units.json', __dir__)

  # Load and parse the shared fixture file.
  #
  # @return [Array<Hash>] raw unit hashes with string keys
  def load_fixture_units
    JSON.parse(File.read(FIXTURE_PATH))
  end

  # Convert a raw hash (string keys) into an ExtractedUnit instance.
  #
  # @param hash [Hash] unit data from JSON
  # @return [CodebaseIndex::ExtractedUnit]
  def build_extracted_unit(hash) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    unit = CodebaseIndex::ExtractedUnit.new(
      type: hash['type'].to_sym,
      identifier: hash['identifier'],
      file_path: hash['file_path']
    )
    unit.namespace = hash['namespace']
    unit.source_code = hash['source_code']
    unit.metadata = hash['metadata'] || {}
    unit.dependencies = (hash['dependencies'] || []).map { |d| d.transform_keys(&:to_sym) }
    unit.dependents = (hash['dependents'] || []).map { |d| d.is_a?(Hash) ? d.transform_keys(&:to_sym) : d }
    unit.chunks = (hash['chunks'] || []).map { |c| c.transform_keys(&:to_sym) }
    unit
  end

  # Populate all three store types from an array of ExtractedUnit instances.
  #
  # @param units [Array<CodebaseIndex::ExtractedUnit>]
  # @param vector_store [CodebaseIndex::Storage::VectorStore::Interface]
  # @param metadata_store [CodebaseIndex::Storage::MetadataStore::Interface]
  # @param graph_store [CodebaseIndex::Storage::GraphStore::Memory]
  # @param provider [CodebaseIndex::Embedding::Provider::Interface]
  def populate_stores(units, vector_store:, metadata_store:, graph_store:, provider:)
    units.each do |unit|
      # Metadata store
      metadata_store.store(unit.identifier, {
                             type: unit.type.to_s,
                             identifier: unit.identifier,
                             file_path: unit.file_path,
                             namespace: unit.namespace,
                             source_code: unit.source_code
                           })

      # Graph store
      graph_store.register(unit)

      # Vector store (embed and store)
      vector = provider.embed(unit.source_code || '')
      vector_store.store(unit.identifier, vector, {
                           type: unit.type.to_s,
                           identifier: unit.identifier,
                           file_path: unit.file_path
                         })
    end
  end
end

RSpec.configure do |config|
  config.include IntegrationHelpers, :integration
end
