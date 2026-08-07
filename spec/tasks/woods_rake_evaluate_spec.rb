# frozen_string_literal: true

require 'spec_helper'
require 'rake'

# The evaluation rake file shipped in the gem for its whole life without ever
# being loaded — the railtie loaded only `woods.rake` — so `woods:evaluate`
# existed on no host, and nothing noticed that its body called four `Woods.*`
# store accessors that have never existed (#212 / B-099).
#
# These examples load the file into a real Rake application and read its
# source, so both halves are pinned: the tasks exist, and they reach for the
# API that is actually there.
RSpec.describe 'lib/tasks/woods_evaluation.rake' do
  let(:rake_path) { File.expand_path('../../lib/tasks/woods_evaluation.rake', __dir__) }
  # Explicit UTF-8: the file has em dashes in its comments, and a US-ASCII
  # default external encoding makes every match? raise.
  let(:source) { File.read(rake_path, encoding: 'UTF-8') }
  # Comments deliberately name the dead accessors to explain the history, so
  # the "does not call" examples below must read code, not prose.
  let(:code) { source.lines.reject { |line| line.strip.start_with?('#') }.join }
  let(:railtie_source) do
    File.read(File.expand_path('../../lib/woods/railtie.rb', __dir__), encoding: 'UTF-8')
  end

  describe 'task definitions' do
    around do |example|
      previous = Rake.application
      Rake.application = Rake::Application.new
      # `=> :environment` is a Rails-supplied prerequisite; define a no-op so
      # the file loads outside a Rails app.
      Rake::Task.define_task(:environment)
      example.run
    ensure
      Rake.application = previous
    end

    # One example, so the file is loaded once per suite run. Loading it twice
    # re-opens the module and Ruby warns about every already-initialized
    # constant — noise that would train the eye to ignore real warnings.
    it 'defines both evaluation tasks' do
      load rake_path

      expect(Rake::Task.task_defined?('woods:evaluate')).to be(true)
      expect(Rake::Task.task_defined?('woods:evaluate:baseline')).to be(true)
      expect(Rake::Task['woods:evaluate:baseline'].arg_names).to eq([:strategy])
    end
  end

  describe 'the railtie loads it' do
    it 'loads woods_evaluation.rake alongside woods.rake' do
      expect(railtie_source).to include("load File.expand_path('../tasks/woods_evaluation.rake', __dir__)")
    end
  end

  describe 'store construction' do
    # The four accessors the file used to call. None has ever existed on the
    # Woods module, so every task raised NoMethodError on its first line of
    # real work.
    %w[Woods.vector_store Woods.metadata_store Woods.graph_store Woods.embedding_provider].each do |dead|
      it "does not call the non-existent #{dead}" do
        expect(code).not_to include(dead)
        expect(Woods).not_to respond_to(dead.split('.').last.to_sym)
      end
    end

    it 'builds the retriever through Builder, like every other entry point' do
      expect(source).to include('build_retriever')
    end

    it 'builds the metadata store through Builder for baselines' do
      expect(source).to include('build_metadata_store')
    end
  end

  # A rake file's bare `def`s land on Object and become callable on every
  # object in the host app.
  it 'defines its task bodies in a module rather than at top level' do
    expect(source).to include('module EvaluationTasks')
    expect(source).not_to match(/^def [a-z_]+/)
  end
end
