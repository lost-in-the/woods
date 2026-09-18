# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extractors/package_extractor'
require 'woods/retriever'

# Synthetic Packwerk directory fixture. Ownership is produced by the real
# PackageExtractor, not inferred from identifier namespaces or invented for a
# host application's captured corpus. This does not claim Rails runtime evidence.
RSpec.describe 'Retrieval across declared package boundaries' do
  include_context 'extractor setup'

  it 'keeps root, nested and similarly named packages distinct using extracted ownership' do
    %w[. packs/billing packs/billing/nested packs/billing_admin].each do |package|
      create_file("#{package}/package.yml", "enforce_dependencies: true\ndependencies: []\n")
    end
    resolver = Woods::Extractors::PackageExtractor.new
    metadata = Woods::Storage::MetadataStore::InMemory.new
    resolver.extract_all.each { |unit| metadata.store(unit.identifier, unit.to_h) }
    paths = {
      'RootPayment' => 'app/services/root_payment.rb',
      'InvoicePayment' => 'packs/billing/app/services/payment.rb',
      'NestedPayment' => 'packs/billing/nested/app/services/payment.rb',
      'AdminPayment' => 'packs/billing_admin/app/services/payment.rb'
    }
    paths.each do |identifier, path|
      absolute = create_file(path, "class #{identifier}; def charge_payment; end; end")
      owner = resolver.package_for(absolute)
      metadata.store(identifier, { identifier: identifier, type: 'service', file_path: path,
                                   source_code: File.read(absolute), metadata: { package: owner } })
    end
    retriever = Woods::Retriever.new(metadata_store: metadata, vector_store: nil, graph_store: nil,
                                     embedding_provider: nil, mode: :lexical)
    %w[. packs/billing packs/billing/nested packs/billing_admin].zip(paths.keys).each do |package, identifier|
      result = retriever.retrieve('charge payment', packages: [package], types: ['service'], budget: 1200)
      expect(result.sources.map { |source| source[:identifier] }).to eq([identifier])
      expect(result.applied_scope).to include(eligible_units: 1)
    end
    combined = retriever.retrieve('charge payment', source_paths: ['packs/billing'], types: ['service'], budget: 1200)
    expect(combined.sources.map { |source| source[:identifier] }).to contain_exactly('InvoicePayment', 'NestedPayment')
  end
end
