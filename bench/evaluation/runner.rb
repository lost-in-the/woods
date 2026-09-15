# frozen_string_literal: true

# Developer-only replay of captured real model vectors through the live pipeline.
require 'json'
require 'digest'
require 'fileutils'
require 'woods'
require 'woods/retriever'
require 'woods/extracted_unit'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/storage/graph_store'
require 'woods/embedding/text_preparer'
require 'woods/evaluation/metrics'

module RetrievalBaseline
  ROOT = File.expand_path(__dir__)

  class CapturedProvider
    def initialize(vectors)
      @vectors = vectors
    end

    def embed(text)
      @vectors.fetch(Digest::SHA256.hexdigest(text))
    end
  end

  class Runner
    attr_reader :corpus

    def initialize(root: ROOT, runtime: "#{RUBY_ENGINE}-#{RUBY_VERSION.split('.').first(2).join('.')}")
      @root = root
      profiles = JSON.parse(File.read(File.join(@root, 'profiles.json')))
      raise 'Unsupported runtime profiles schema' unless profiles.fetch('schema_version') == 1
      @profile = profiles.fetch('runtimes').fetch(runtime) do
        raise "Unmeasured Ruby runtime #{runtime}: capture and review a retrieval baseline before adding a profile"
      end
      @corpus = read('corpus.json')
    end

    def read(name)
      JSON.parse(File.read(path_for(name), encoding: 'UTF-8'))
    end

    def path_for(name)
      selected = case name
                 when 'baseline.json' then @profile.fetch('baseline')
                 when 'capture_report.json' then @profile.fetch('capture_report')
                 else name
                 end
      File.join(@root, selected)
    end

    def units
      @units ||= corpus.fetch('units').map do |data|
        unit = Woods::ExtractedUnit.new(type: data.fetch('type').to_sym,
                                       identifier: data.fetch('identifier'), file_path: data.fetch('file_path'))
        unit.source_code = data.fetch('source_code')
        unit.namespace = data['namespace']
        unit.metadata = data.fetch('metadata', {})
        unit.dependencies = data.fetch('dependencies').map { |edge| edge.transform_keys(&:to_sym) }
        unit
      end
    end

    def texts
      preparer = Woods::Embedding::TextPreparer.new
      units.map { |unit| preparer.prepare(unit) } + corpus.fetch('queries').map { |q| q.fetch('query') }
    end

    def stores(vectors)
      metadata = Woods::Storage::MetadataStore::InMemory.new
      vector = Woods::Storage::VectorStore::InMemory.new
      graph = Woods::Storage::GraphStore::Memory.new
      provider = CapturedProvider.new(vectors)
      prepared = texts
      units.each_with_index do |unit, index|
        metadata.store(unit.identifier, unit.to_h.transform_keys(&:to_s).reject { |key, _| key == 'extracted_at' })
        vector.store(unit.identifier, provider.embed(prepared[index]), { type: unit.type.to_s })
        graph.register(unit)
      end
      { vector_store: vector, metadata_store: metadata, graph_store: graph, embedding_provider: provider }
    end

    def run
      capture = read('vectors.json')
      verify_capture!(capture)
      retriever = Woods::Retriever.new(**stores(capture.fetch('vectors')))
      results = corpus.fetch('queries').map { |query| measure(retriever, query) }
      attach_token_counts(results) if File.exist?(path_for('capture_report.json'))
      {
        schema_version: 1, corpus: corpus.fetch('name'),
        runtime: { engine: RUBY_ENGINE, version: RUBY_VERSION, platform: RUBY_PLATFORM },
        corpus_sha256: digest('corpus.json'), vectors_sha256: digest('vectors.json'),
        token_accounting: 'estimated_context_tokens is Woods chars/token; exact cl100k counts are in capture report',
        latency_scope: 'warm in-process pipeline including vector replay lookup; excludes live embedding and network latency',
        results: results,
        strategies: results.group_by { |r| r[:strategy] }.transform_values { |rows| aggregate(rows) }
      }
    end

    def attach_token_counts(results)
      captured = read('capture_report.json').fetch('results').to_h { |row| [row.fetch('id'), row] }
      results.each do |row|
        previous = captured.fetch(row.fetch(:id))
        next unless previous.fetch('context_sha256') == Digest::SHA256.hexdigest(row.fetch(:context))

        row[:actual_context_tokens_cl100k] = previous.fetch('actual_context_tokens_cl100k')
      end
    end

    def verify_capture!(capture)
      raise 'Corpus changed: recapture and review the baseline' unless capture.fetch('corpus_sha256') == digest('corpus.json')
      raise 'Unsupported capture schema' unless capture.fetch('schema_version') == 1
      raise 'Unsupported corpus schema' unless corpus.fetch('schema_version') == 1
      expected = texts.map { |text| Digest::SHA256.hexdigest(text) }.sort
      raise 'Embedding inputs changed: recapture required' unless capture.fetch('vectors').keys.sort == expected
    end

    def digest(name)
      Digest::SHA256.file(path_for(name)).hexdigest
    end

    def measure(retriever, query)
      options = { budget: query.fetch('budget') }
      options[:types] = query['types'] if query['types']
      retriever.retrieve(query.fetch('query'), **options) # Warm the ranker's graph cache.
      latencies = []
      result = nil
      5.times do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = retriever.retrieve(query.fetch('query'), **options)
        latencies << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end
      ids = result.sources.map { |source| source.fetch(:identifier) }
      expected = query.fetch('expected_units')
      actual_strategy = result.strategy.to_s
      fallback = result.type_rank_context&.values&.any? { |v| v[:source] == :within_type_fallback }
      actual_strategy = 'fallback' if fallback
      {
        id: query.fetch('id'), strategy: query.fetch('strategy'), actual_strategy: actual_strategy,
        retrieved: ids, expected: expected, context: result.context,
        precision_at5: Woods::Evaluation::Metrics.precision_at_k(ids, expected, cutoff: 5),
        recall: Woods::Evaluation::Metrics.recall(ids, expected), mrr: Woods::Evaluation::Metrics.mrr(ids, expected),
        estimated_context_tokens: result.tokens_used,
        latency_ms: { median: latencies.sort[2], min: latencies.min, max: latencies.max }
      }
    end

    def aggregate(rows)
      %i[precision_at5 recall mrr estimated_context_tokens].to_h do |metric|
        [metric, rows.sum { |row| row.fetch(metric) } / rows.size.to_f]
      end.merge(queries: rows.size)
    end

    def validate_baseline!(baseline)
      raise 'Unsupported baseline schema' unless baseline.fetch('schema_version') == 1

      baseline.fetch('thresholds').each_value do |thresholds|
        unless thresholds.keys.sort == %w[mrr precision_at5 recall]
          raise 'Every strategy requires precision_at5, recall, and mrr thresholds'
        end
        unless thresholds.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }
          raise 'Quality thresholds must be positive finite numbers'
        end
      end
    end

    def violations(report, baseline: read('baseline.json'))
      validate_baseline!(baseline)
      errors = []
      errors << 'Runtime profiles differ from reviewed baseline' unless baseline.fetch('profiles_sha256') == digest('profiles.json')
      %w[corpus vectors].each do |name|
        errors << "#{name} digest differs from reviewed baseline" unless baseline.fetch("#{name}_sha256") == report.fetch(:"#{name}_sha256")
      end
      errors << 'Token capture digest differs from reviewed baseline' unless baseline.fetch('capture_report_sha256') == digest('capture_report.json')
      unless baseline.fetch('thresholds').keys.sort == report.fetch(:strategies).keys.sort
        errors << 'Strategy coverage differs from reviewed baseline'
      end
      report.fetch(:results).each do |row|
        errors << "#{row[:id]} context changed; recapture exact token counts" unless row[:actual_context_tokens_cl100k]
        errors << "#{row[:id]} exercised #{row[:actual_strategy]}, expected #{row[:strategy]}" unless row[:actual_strategy] == row[:strategy]
      end
      baseline.fetch('thresholds').each do |strategy, thresholds|
        metrics = report.fetch(:strategies).fetch(strategy)
        thresholds.each do |metric, minimum|
          raise 'Quality thresholds must be positive' unless minimum.positive?
          actual = metrics.fetch(metric.to_sym)
          errors << "#{strategy} #{metric}: #{actual} < #{minimum}" if actual < minimum
        end
      end
      errors
    end
  end
end

if $PROGRAM_NAME == __FILE__
  runner = RetrievalBaseline::Runner.new
  if ARGV.delete('--inputs')
    puts JSON.pretty_generate(runner.texts)
  else
    output = ARGV.shift || 'tmp/retrieval-evaluation.json'
    report = runner.run
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, JSON.pretty_generate(report) + "\n")
    errors = runner.violations(report)
    puts JSON.pretty_generate(report[:strategies])
    abort(errors.join("\n")) unless errors.empty?
    puts "Retrieval quality gate passed; report: #{output}"
  end
end
