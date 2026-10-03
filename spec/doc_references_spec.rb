# frozen_string_literal: true

require 'spec_helper'
require 'woods/doc_references'

RSpec.describe Woods::DocReferences do
  let(:records) do
    [
      { type: 'model', identifier: 'Widget', paths: ['app/models/widget.rb'] },
      { type: 'state_machine', identifier: 'Widget', paths: ['app/models/widget.rb'] },
      { type: 'service', identifier: 'Widget::Importer', paths: ['app/services/widget/importer.rb'] },
      { type: 'rake_task', identifier: 'widgets:sync', paths: ['lib/tasks/widgets.rake', 'lib/tasks/extra.rake'] },
      { type: 'route', identifier: 'GET /widgets', paths: ['config/routes.rb'] },
      { type: 'route', identifier: 'GET /ledgers [subdomain=api]', paths: ['config/routes.rb'] },
      { type: 'route', identifier: 'GET /ledgers #2', paths: ['config/routes.rb'] },
      { type: 'route', identifier: 'GET /ledgers/:id', paths: ['config/routes.rb'] },
      { type: 'factory', identifier: 'widgets:sync', paths: ['spec/factories/odd.rb'] },
      { type: 'doc', identifier: 'docs/setup.md', paths: ['docs/setup.md'] },
      { type: 'doc', identifier: 'docs/widgets.md', paths: ['docs/widgets.md'] }
    ]
  end
  let(:resolver) { described_class::Resolver.new(described_class::Registry.new(records)) }

  def resolve(mentions: [], links: [], identifier: 'docs/widgets.md')
    resolver.call(identifier: identifier, mentions: mentions, links: links)
  end

  it 'links a constant to every unit type registered under that identifier' do
    result = resolve(mentions: [%w[constant Widget]])

    expect(result.edges).to eq([%w[Widget model documents], %w[Widget state_machine documents]])
    expect(result.mentions).to eq([true])
  end

  it 'falls back to the longest indexed prefix of a constant path' do
    expect(resolve(mentions: [%w[constant Widget::Importer::BATCH_SIZE]]).edges)
      .to eq([%w[Widget::Importer service documents]])
  end

  it 'records a constant that names nothing as unresolved, with no edge' do
    result = resolve(mentions: [%w[constant Shipment::Tracker], %w[constant String]])

    expect(result.edges).to eq([])
    expect(result.mentions).to eq([false, false])
  end

  it 'links a path to every unit defined in that file, including a secondary source' do
    expect(resolve(mentions: [%w[path app/models/widget.rb]]).edges)
      .to eq([%w[Widget model documents], %w[Widget state_machine documents]])
    expect(resolve(mentions: [%w[path lib/tasks/extra.rake]]).edges).to eq([%w[widgets:sync rake_task documents]])
  end

  it 'links a rake task to the rake_task unit only' do
    expect(resolve(mentions: [%w[rake_task widgets:sync]]).edges).to eq([%w[widgets:sync rake_task documents]])
    expect(resolve(mentions: [%w[rake_task db:migrate]]).mentions).to eq([false])
  end

  it 'links a route by exact identifier, else to its constrained and numbered variants' do
    expect(resolve(mentions: [['route', 'GET /widgets']]).edges).to eq([['GET /widgets', 'route', 'documents']])
    expect(resolve(mentions: [['route', 'GET /ledgers']]).edges)
      .to eq([['GET /ledgers #2', 'route', 'documents'], ['GET /ledgers [subdomain=api]', 'route', 'documents']])
    expect(resolve(mentions: [['route', 'POST /widgets']]).mentions).to eq([false])
  end

  it 'links a relative link to a doc as doc_link and to code as documents' do
    result = resolve(links: ['docs/setup.md', 'app/models/widget.rb', 'docs/missing.md', nil])

    expect(result.edges).to eq([%w[Widget model documents], %w[Widget state_machine documents],
                                %w[docs/setup.md doc doc_link]])
    expect(result.links).to eq([true, true, false, false])
  end

  it 'never links a document to itself' do
    result = resolve(mentions: [%w[path docs/widgets.md]], links: ['docs/widgets.md'])

    expect(result.edges).to eq([])
    expect(result.mentions + result.links).to eq([false, false])
  end

  it 'emits each edge once, sorted, whatever the mention order' do
    forward = resolve(mentions: [%w[constant Widget], %w[path app/models/widget.rb], %w[rake_task widgets:sync]])
    backward = resolve(mentions: [%w[rake_task widgets:sync], %w[path app/models/widget.rb], %w[constant Widget]])

    expect(forward.edges).to eq(backward.edges)
    expect(forward.edges).to eq(forward.edges.uniq.sort)
  end

  it 'is independent of record order' do
    shuffled = described_class::Resolver.new(described_class::Registry.new(records.reverse))
    mentions = [%w[constant Widget], ['route', 'GET /ledgers']]

    expect(shuffled.call(identifier: 'docs/widgets.md', mentions: mentions, links: []).edges)
      .to eq(resolve(mentions: mentions).edges)
  end
end
