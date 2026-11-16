# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

# Each model saves a record, so the columns Ruby wrote are the oracle for
# the callback side effects the model unit publishes.
RSpec.describe 'Callback side effects of the body Ruby dispatches', :booted_app do
  before(:all) do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/callback_dispatch_forms/boot.rb')
    raise "#{stdout}\n#{stderr}" unless status.success?

    @models = JSON.parse(stdout.lines.last).fetch('models')
  end

  def form(name)
    @models.fetch(name)
  end

  def published_columns(name)
    form(name).fetch('published').values.flat_map { |entry| entry.fetch('columns') }.uniq.sort
  end

  def statuses(name)
    form(name).fetch('published').transform_values { |entry| entry.fetch('status') }
  end

  # The first operation of a stamp body is its column write, one line under the def.
  def first_site(name, filter = 'stamp')
    form(name).dig('published', filter, 'sites').first
  end

  def dispatched_body(name, filter = 'stamp')
    file, line = form(name).dig('dispatched', filter)
    [file, line + 1]
  end

  {
    'RedefinedRecord' => ['a method redefined later in the class', %w[b]],
    'PrependedRecord' => ['a prepended override', %w[b]],
    'ChainedRecord' => ['a prepended override calling super', %w[a b]],
    'SiblingRecord' => ['a same-named method in a class earlier in the file', %w[d]],
    'TwoConcernRecord' => ['two included concerns defining the method', %w[b]],
    'NestedRecord' => ['a same-named method in a nested class', %w[d]],
    'StiOverrideStamp' => ['an STI child overriding the method', %w[b]],
    'IncludedRecord' => ['a concern registering its callback in included do', %w[a c]]
  }.each do |model, (description, columns)|
    it "publishes what Ruby writes for #{description}" do
      expect(form(model).fetch('saved')).to eq(columns)
      expect(statuses(model).values).to all(eq('analyzed'))
      expect(published_columns(model)).to eq(form(model).fetch('saved'))
      expect(first_site(model)).to eq(dispatched_body(model))
    end
  end

  # Both definitions of stamp share one line, in exclusive branches.
  { 'BranchThenRecord' => %w[a], 'BranchElseRecord' => %w[b] }.each do |model, columns|
    it "publishes what Ruby writes for the branch #{model} installs on a shared line" do
      expect(form(model).fetch('saved')).to eq(columns)
      expect(statuses(model)).to eq('stamp' => 'analyzed')
      expect(published_columns(model)).to eq(columns)
      expect(first_site(model)).to eq(form(model).dig('dispatched', 'stamp'))
    end
  end

  it 'reads the super body after the prepended one' do
    expect(form('ChainedRecord').dig('published', 'stamp', 'sites'))
      .to eq([['app/models/concerns/stamp_chain.rb', 3], ['app/models/chained_record.rb', 6]])
  end

  it 'reports an STI child inheriting the method unsupported' do
    expect(form('StiHeirStamp').fetch('saved')).to eq(%w[a])
    expect(statuses('StiHeirStamp')).to eq('stamp' => 'unsupported')
  end
end
