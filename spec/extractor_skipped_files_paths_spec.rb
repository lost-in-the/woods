# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Extractor skipped files report input' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-skipped-paths') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  let(:output) { @root.join('index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output) }
  let(:unit) { Woods::ExtractedUnit.new(type: :lib, identifier: 'Split', file_path: 'lib/split.rb') }
  let(:fake_extractor_class) do
    split = unit
    Class.new { define_method(:extract_all) { [split] } }
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object, version: '8.0.0'))
    Woods.configuration.concurrent_extraction = false
    stub_const('Woods::Extractor::EXTRACTORS', { lib: fake_extractor_class })
    %i[setup_output_directory safe_eager_load! prepare_source_reference_baseline deduplicate_results
       resolve_dependents enrich_with_git_data normalize_file_paths write_dependency_graph
       write_graph_analysis write_manifest write_structural_summary capture_snapshot log_summary
       write_results enrich_source_references_full project_source_references_full
       enrich_doc_references_full refresh_commit_table publish_generation withdraw_disabled_flows].each do |phase|
      allow(extractor).to receive(phase)
    end
    allow(Woods::ModelNameCache).to receive(:reset!)
    allow(Woods::GraphAnalyzer).to receive(:new).and_return(double('GraphAnalyzer', analyze: {}))
    allow(Woods::DependencyGraph).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |graph|
        allow(graph).to receive(:registered_paths).and_return(%w[lib/split.rb lib/split/version.rb])
      end
    end
  end

  it 'builds the full run report from the graph paths, which include secondary contributor files' do
    built = nil
    skipped = instance_double(Woods::SkippedFiles)
    allow(skipped).to receive(:build) do |paths|
      built = paths.to_a
      { 'total' => 0, 'counts' => {}, 'files' => [] }
    end
    allow(Woods::SkippedFiles).to receive(:new).and_return(skipped)
    allow(Woods::SkippedFiles).to receive(:write)

    extractor.extract_all

    expect(built).to match_array(%w[lib/split.rb lib/split/version.rb])
  end
end
