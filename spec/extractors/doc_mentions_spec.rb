# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/doc_mentions'

RSpec.describe Woods::Extractors::DocMentions do
  def scan(text)
    described_class.scan(text)
  end

  it 'finds constant paths and keeps the receiver of a call' do
    expect(scan('Widget::Importer.call(Ledger.new)')).to eq([%w[constant Widget::Importer], %w[constant Ledger]])
  end

  it 'drops a leading scope operator and a method suffix' do
    expect(scan('::Shipment#deliver!')).to eq([%w[constant Shipment]])
  end

  it 'does not read a capital inside a lowercase word as a constant' do
    expect(scan('fooBar some_Widget x9Y')).to eq([])
  end

  it 'finds repository paths with an extension and strips a line suffix' do
    expect(scan('(see ./app/models/widget.rb:12, lib/tasks/widgets.rake)'))
      .to eq([%w[path app/models/widget.rb], %w[path lib/tasks/widgets.rake]])
  end

  it 'ignores absolute paths, directories and URLs' do
    expect(scan('/etc/hosts app/models/ https://example.test/a.rb')).to eq([])
  end

  it 'finds rake tasks behind rake, bin/rake and bundle exec' do
    expect(scan('bundle exec rake widgets:sync[42]')).to eq([%w[rake_task widgets:sync]])
    expect(scan('bin/rake cleanup')).to eq([%w[rake_task cleanup]])
  end

  it 'requires a namespace for a rails command' do
    expect(scan('bin/rails ledger:post')).to eq([%w[rake_task ledger:post]])
    expect(scan('rails server')).to eq([])
  end

  it 'finds a route as verb plus path, without its query string' do
    expect(scan('curl -X GET /widgets/:id?page=2')).to eq([['route', 'GET /widgets/:id']])
    expect(scan('DELETE /')).to eq([['route', 'DELETE /']])
  end

  it 'reads a verb without a path as a constant candidate' do
    expect(scan('GET widgets')).to eq([%w[constant GET]])
  end

  it 'skips words over the byte cap' do
    expect(scan("Widget #{'A' * 300} Ledger")).to eq([%w[constant Widget], %w[constant Ledger]])
  end
end
