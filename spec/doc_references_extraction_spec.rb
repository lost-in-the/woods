# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

RSpec.describe Woods::DocReferences::Extraction do
  around do |example|
    Dir.mktmpdir('woods-doc-reference-extraction') do |root|
      @root = root
      example.run
    end
  end

  let(:extractor) { Woods::Extractor.new(output_dir: File.join(@root, 'index')) }
  let(:graph) { extractor.dependency_graph }
  let(:identifier) { 'docs/guide.md' }
  let(:path) { extractor.payload_dir.join('docs', extractor.send(:collision_safe_filename, identifier)) }
  let(:target) do
    Woods::ExtractedUnit.new(type: :poro, identifier: 'DocWriterTarget',
                             file_path: File.join(@root, 'app/models/doc_writer_target.rb'))
  end
  let(:span) do
    { line: 1, column: 0, length: 10, target: 'SpanTarget', target_type: 'poro',
      kind: 'constant', confidence: 'verified' }
  end
  let(:edge) { { 'type' => 'poro', 'target' => 'DocWriterTarget', 'via' => 'documents' } }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(@root), logger: double('Logger').as_null_object))
  end

  def seed_document(reference_state)
    document = Woods::ExtractedUnit.new(type: :doc, identifier: identifier,
                                        file_path: File.join(@root, identifier))
    document.source_code = 'SpanTarget and `DocWriterTarget`'
    document.metadata = { mentions: [{ kind: 'constant', text: 'DocWriterTarget', resolved: false }], links: [],
                          git: { commit_count: 7 }, custom: ['keep'] }
    document.metadata[:references] = reference_state == 'empty' ? [] : [span] unless reference_state == 'absent'
    document.chunks = [{ id: 'kept-chunk', content: 'keep' }]
    graph.register(document)
    FileUtils.mkdir_p(path.dirname)
    # Seed the legacy missing-field case directly: write_unit_file defaults it to [].
    File.write(path, JSON.generate(document.to_h.merge(extracted_at: '2026-01-01T00:00:00Z')))
    JSON.parse(File.read(path))
  end

  %w[absent empty populated].each do |reference_state|
    it "preserves #{reference_state} source spans through document-edge additions and removals" do
      before = seed_document(reference_state)
      affected = Set.new
      graph.register(target)

      expect(extractor.send(:enrich_doc_references_incremental, affected)).to eq(Set[identifier])
      after = JSON.parse(File.read(path))
      expected_metadata = before.fetch('metadata').merge(
        'mentions' => [{ 'kind' => 'constant', 'text' => 'DocWriterTarget', 'resolved' => true }]
      )
      expect(after).to eq(before.merge('dependencies' => [edge], 'metadata' => expected_metadata))
      expect(affected).to eq(Set[:docs])
      expect(graph.dependencies_of(identifier, type: :doc)).to eq(['DocWriterTarget'])
      expect(graph.dependents_of('DocWriterTarget', via: :documents)).to eq([identifier])

      graph.remove('DocWriterTarget', type: :poro)
      affected.clear
      expect(extractor.send(:enrich_doc_references_incremental, affected)).to eq(Set[identifier])
      expect(JSON.parse(File.read(path))).to eq(before)
      expect(affected).to eq(Set[:docs])
      expect(graph.dependencies_of(identifier, type: :doc)).to eq([])
      expect(graph.dependents_of('DocWriterTarget', via: :documents)).to eq([])

      bytes = File.binread(path)
      expect(extractor.send(:enrich_doc_references_incremental, Set.new)).to be_empty
      expect(File.binread(path)).to eq(bytes)
    end
  end
end
