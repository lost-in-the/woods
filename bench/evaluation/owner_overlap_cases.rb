# frozen_string_literal: true

require_relative 'owner_overlap'
require 'woods/ruby_analyzer'
require 'woods/retrieval/query_classifier'
require 'woods/storage/metadata_store'
require 'woods/storage_identity'

module OwnerOverlap
  module Cases
    module_function

    def synthetic_sources
      methods = (1..12).map { |n| "  def step_#{n}(value)\n    value + #{n}\n  end\n" }.join
      { '/fixture/invoice.rb' => "class Invoice\n#{methods}end\n",
        '/fixture/gateway.rb' => "class Gateway\n  def charge(value)\n    value * 2\n  end\nend\n" }
    end

    def build(name:, sources:, ids:, budget:, required:, scope: :focused, intent: :understand, overrides: {})
      units = Woods::RubyAnalyzer.analyze(sources: sources)
      selected = ids.map { |id| units.find { |unit| unit.identifier == id } || raise("Missing #{id}") }
      data = selected.map { |unit| unit.to_h.merge(overrides.fetch(unit.identifier, {})) }
      { name: name, sources: sources, units: data, budget: budget, required: required,
        classification: Woods::Retrieval::QueryClassifier::Classification.new(intent: intent, scope: scope,
                                                                               framework_context: false) }
    end

    def all
      sources = synthetic_sources
      ids = ['Invoice'] + (1..12).map { |n| "Invoice#step_#{n}" } + ['Gateway#charge']
      common = { sources: sources, ids: ids, required: ['Invoice#step_1', 'Gateway#charge'] }
      [build(name: 'crowded_overlap', budget: 230, **common),
       build(name: 'single_owner', budget: 230, **common.merge(ids: ids[0...-1], required: ['Invoice#step_1'])),
       build(name: 'exact_target', budget: 230, intent: :locate, **common),
       build(name: 'pinpoint', budget: 230, scope: :pinpoint, **common),
       build(name: 'truncated_parent', budget: 210, **common.merge(sources: sources.merge('/fixture/invoice.rb' => sources.fetch('/fixture/invoice.rb').sub('class Invoice', "class Invoice\n" + ("  # Long structural preamble\n" * 60))))),
       build(name: 'disjoint_methods', budget: 150, **common.merge(ids: ['Invoice#step_1', 'Invoice#step_2', 'Gateway#charge'],
                                                               required: ['Invoice#step_1', 'Invoice#step_2'])),
       build(name: 'inlined_concern_unknown', budget: 230, **common.merge(overrides: {
         'Invoice' => { source_code: sources.fetch('/fixture/invoice.rb') + "\n# Included from: Chargeable\n# def charge; end\n" }
       }))]
    end

    def real_source
      paths = %w[lib/woods/storage_identity.rb lib/woods/filename_utils.rb]
      root = File.expand_path('../..', __dir__)
      sources = paths.to_h { |path| [path, File.read(File.join(root, path))] }
      ids = ['Woods::StorageIdentity', 'Woods::StorageIdentity.key', 'Woods::StorageIdentity.parts',
             'Woods::StorageIdentity.identifier', 'Woods::FilenameUtils#collision_safe_filename']
      build(name: 'woods_static_identity_and_filename', sources: sources, ids: ids, budget: 400,
            required: ['Woods::StorageIdentity.key', 'Woods::FilenameUtils#collision_safe_filename'])
    end

    # A fixed executable oracle for the authored synthetic tasks, independent of
    # source-substring retention. Only delivered snippets enter the isolated
    # namespace. Wrapping an attributed instance method supplies its class name,
    # never missing helper implementations. This is not an LLM answer benchmark.
    def executable_task(fixture, result)
      return nil unless fixture.fetch(:name) != 'woods_static_identity_and_filename'
      namespace = Module.new
      blocks = result.context.split(/(?=^## )/).reject(&:empty?)
      return false unless blocks.size == result.sources.size
      result.sources.zip(blocks).each do |attribution, block|
        body = block.split("\n\n", 2).last
        return false unless body
        if attribution[:type].to_s == 'ruby_method'
          owner = attribution[:identifier].split('#').first
          namespace.module_eval("class #{owner}\n#{body}\nend", '(delivered evidence)')
        else
          namespace.module_eval(body, '(delivered evidence)')
        end
      end
      fixture.fetch(:required).all? do |identifier|
        owner, method = identifier.split('#')
        expected = method == 'charge' ? 8 : 4 + Integer(method.delete_prefix('step_'))
        namespace.const_get(owner, false).new.public_send(method, 4) == expected
      end
    rescue SyntaxError, NameError, NoMethodError
      false
    end

    def run(fixture, policy:, origins: Origins.new(fixture.fetch(:sources)), equal_scores: false)
      store = Woods::Storage::MetadataStore::InMemory.new
      candidates = fixture.fetch(:units).each_with_index.map do |unit, index|
        key = Woods::StorageIdentity.key(unit.fetch(:identifier), unit.fetch(:type))
        store.store(key, unit)
        Woods::Retrieval::SearchExecutor::Candidate.new(identifier: key, score: equal_scores ? 1.0 : 1.0 - index * 0.01,
                                                         source: fixture.fetch(:candidate_sources, {}).fetch(unit.fetch(:identifier), :vector),
                                                         metadata: { type: unit.fetch(:type) })
      end
      trace = nil
      assembler = Assembler.new(metadata_store: store, origins: origins, policy: policy, recorder: ->(rows) { trace = rows })
      result = assembler.assemble(candidates: candidates, classification: fixture.fetch(:classification), budget: fixture.fetch(:budget))
      analyzed = Woods::RubyAnalyzer.analyze(sources: fixture.fetch(:sources))
      required = fixture.fetch(:required).to_h do |identifier|
        source = analyzed.find { |unit| unit.identifier == identifier }.source_code
        [identifier, result.context.include?(source.rstrip)]
      end
      owner_groups = required.keys.group_by { |id| analyzed.find { |unit| unit.identifier == id }.file_path }
      owner_coverage = owner_groups.transform_values { |ids| ids.any? { |id| required[id] } }
      { id: fixture.fetch(:name), relevant_owner_coverage: owner_coverage.values.count(true).fdiv(owner_coverage.size),
        condition: policy ? 'overlap' : 'baseline', budget: fixture.fetch(:budget),
        context: result.context, estimated_context_tokens: result.tokens_used, sources: result.sources,
        necessary_methods: required, necessary_method_recall: required.values.count(true).fdiv(required.size),
        complete_required_evidence: required.values.all?, executable_fixture_pass: executable_task(fixture, result), trace: trace }
    end
  end
end
