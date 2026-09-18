# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods'
require 'woods/retrieval/context_assembler'

RSpec.describe 'Concurrent evidence assembly' do
  it 'keeps overlapping calls modes, queries and generations separate' do
    entered = Queue.new
    release = Queue.new
    metadata = Woods::Storage::MetadataStore::InMemory.new
    metadata.store('Invoice', { identifier: 'Invoice', type: 'model', file_path: 'invoice.rb',
                                source_code: 'class Invoice; def refund; :refund_ok; end; ' \
                                             'def charge; :charge_ok; end; end' })
    original = metadata.method(:find_batch)
    metadata.define_singleton_method(:find_batch) do |ids|
      if Thread.current[:held_assembly]
        entered << true
        release.pop
      end
      original.call(ids)
    end
    assembler = Woods::Retrieval::ContextAssembler.new(metadata_store: metadata)
    candidate = Woods::Retrieval::SearchExecutor::Candidate.new(identifier: 'Invoice', score: 1.0, source: :vector)
    classification = Woods::Retrieval::QueryClassifier.new.classify('How do refunds work?')
    held = Thread.new do
      Thread.current[:held_assembly] = true
      assembler.assemble(candidates: [candidate], classification: classification, evidence: 'compact',
                         query: 'refund', generation: 11, budget: 800)
    end
    Timeout.timeout(5) { entered.pop }
    full = assembler.assemble(candidates: [candidate], classification: classification, evidence: 'full',
                              query: 'charge', generation: 12, budget: 800)
    release << true
    compact = Timeout.timeout(5) { held.value }
    expect(full.context).not_to include('Evidence:')
    expect(full.sources.first).not_to have_key(:evidence)
    expect(compact.sources.first[:evidence]).to include(mode: 'compact', generation: 11)
    expect(compact.sources.first[:evidence][:spans].first[:name]).to eq('refund')
  ensure
    release << true if release
    held&.join(5)
  end
end
