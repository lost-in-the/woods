# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractor'

# What a full extraction seeds its private stage with from the published
# generation. Every file it would replace or remove is left out; everything
# the run keeps is still seeded.
RSpec.describe Woods::Extractor, 'full extraction payload seed' do
  let(:tmpdir) { Dir.mktmpdir('woods_full_seed') }
  let(:output) { Pathname.new(tmpdir).join('output') }
  let(:published) { output.join('payloads', 'gen-1') }
  let(:extractor) { described_class.new(output_dir: output.to_s) }
  let(:logger) { double('Logger').as_null_object }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(tmpdir), logger: logger, version: '8.0.0'))
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    allow(Woods::AtomicFile).to receive(:sync_directory_tree).and_return(:syncfs)
    seed_published_generation
    stub_full_run
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  def seed_published_generation
    { 'flows/Legacy__PostsController_index.json' => {}, 'flows/flow_index.json' => {},
      'flows/by_unit.json' => {}, 'models/Post_a5554622.json' => {},
      'rails_source/ActiveRecord__Base_0123abcd.json' => {} }.each do |relative, data|
      FileUtils.mkdir_p(published.join(relative).dirname)
      File.write(published.join(relative), JSON.generate(data))
    end
    File.write(output.join('generation.json'),
               JSON.generate('number' => 1, 'token' => 'seed', 'updated_at' => Time.now.utc.iso8601,
                             'reason' => 'full', 'payload' => 'payloads/gen-1'))
  end

  def stub_full_run
    %i[safe_eager_load! extract_all_sequential deduplicate_results annotate_packages resolve_dependents
       enrich_with_git_data annotate_graph_with_git_data normalize_file_paths write_results
       write_dependency_graph write_graph_analysis write_manifest write_structural_summary
       capture_published_snapshot log_summary].each { |phase| allow(extractor).to receive(phase) }
    allow(Woods::ModelNameCache).to receive(:reset!)
    allow(Woods::GraphAnalyzer).to receive(:new).and_return(double('GraphAnalyzer', analyze: {}))
  end

  # The stage's JSON files, relative to it, as the given step begins.
  def staged_json_when(step)
    seen = nil
    allow(extractor).to receive(step) do
      stage = Pathname.new(extractor.payload_dir)
      seen = Dir[stage.join('**', '*.json').to_s].map { |path| Pathname.new(path).relative_path_from(stage).to_s }
    end
    extractor.extract_all
    seen
  end

  it 'leaves out the flow documents a run that precomputes flows writes again' do
    Woods.configuration.precompute_flows = true

    expect(staged_json_when(:precompute_flows).grep(%r{\Aflows/})).to be_empty
  end

  it 'leaves out the flow documents a run without flow precomputation withdraws' do
    Woods.configuration.precompute_flows = false

    expect(staged_json_when(:withdraw_disabled_flows).grep(%r{\Aflows/})).to be_empty
  end

  it 'still seeds the units of a family the configuration gates out of the run' do
    Woods.configuration.include_framework_sources = false
    Woods.configuration.precompute_flows = true

    staged = staged_json_when(:precompute_flows)

    expect(staged).to include('rails_source/ActiveRecord__Base_0123abcd.json')
    expect(staged).not_to include('models/Post_a5554622.json')
  end
end
