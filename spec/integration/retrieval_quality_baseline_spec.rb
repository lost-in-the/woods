# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../bench/evaluation/runner'

RSpec.describe 'Captured real-model retrieval quality gate' do
  let(:runner) { RetrievalBaseline::Runner.new }

  it 'replays every annotated strategy through the real pipeline and meets reviewed floors' do
    report = runner.run

    expect(runner.violations(report)).to be_empty
    expect(report[:strategies].keys).to contain_exactly('keyword', 'vector', 'graph', 'hybrid', 'direct', 'fallback')
    expect(report[:results]).to all(include(actual_context_tokens_cl100k: a_value > 0))
  end

  it 'exits nonzero when real vector search loses its results' do
    Dir.mktmpdir do |dir|
      hook = File.join(dir, 'broken_vector.rb')
      File.write(hook, <<~RUBY)
        require 'woods/storage/vector_store'
        class Woods::Storage::VectorStore::InMemory
          def search(*)
            []
          end
        end
      RUBY
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, '-Ilib', '-r', hook,
        'bench/evaluation/runner.rb', File.join(dir, 'report.json')
      )

      expect(status.success?).to be(false), stdout
      expect(stderr).to include('vector recall:', 'fallback recall:')
    end
  end

  it 'refuses a corpus changed without matching captured vectors' do
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[File.join(RetrievalBaseline::ROOT, '*.json')], dir)
      path = File.join(dir, 'corpus.json')
      File.write(path, "#{File.read(path)}\n")

      expect { RetrievalBaseline::Runner.new(root: dir).run }.to raise_error(/Corpus changed/)
    end
  end

  it 'rejects vectors or token provenance changed without baseline review' do
    report = runner.run
    baseline = runner.read('baseline.json').merge('vectors_sha256' => 'changed', 'capture_report_sha256' => 'changed')

    expect(runner.violations(report, baseline: baseline)).to include(
      'vectors digest differs from reviewed baseline', 'Token capture digest differs from reviewed baseline'
    )
  end
  it 'refuses unsupported baseline schemas and omitted quality metrics' do
    baseline = runner.read('baseline.json')
    expect { runner.validate_baseline!(baseline.merge('schema_version' => 2)) }.to raise_error(/baseline schema/)
    baseline.fetch('thresholds').fetch('vector').delete('recall')
    expect { runner.validate_baseline!(baseline) }.to raise_error(/requires precision_at5, recall, and mrr/)
  end

  it 'refuses nonfinite and nonpositive quality thresholds' do
    baseline = runner.read('baseline.json')
    [Float::NAN, Float::INFINITY, 0, -1].each do |value|
      baseline.fetch('thresholds').fetch('vector')['recall'] = value
      expect { runner.validate_baseline!(baseline) }.to raise_error(/positive finite/)
    end
  end

  it 'requires an explicit capture for an unmeasured Ruby engine or version' do
    expect { RetrievalBaseline::Runner.new(runtime: 'jruby-9.4') }.to raise_error(/Unmeasured Ruby runtime/)
    expect { RetrievalBaseline::Runner.new(runtime: 'ruby-9.9') }.to raise_error(/capture and review/)
  end
end
