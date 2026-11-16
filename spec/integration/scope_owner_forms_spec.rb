# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

# What the live class answers is the oracle: a scope verifies only when it is
# declared in the model's own class body and the class answers it as an
# Active Record scope. Every other declaration in that body stays, static.
RSpec.describe 'Scopes a model unit publishes, against the live class', :booted_app do
  before(:all) do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/scope_owner_forms/boot.rb')
    raise "#{stdout}\n#{stderr}" unless status.success?

    report = JSON.parse(stdout.lines.last)
    @rails = Gem::Version.new(report.fetch('rails'))
    @models = report.fetch('models')
  end

  def outer
    @models.fetch('ScopeOwner')
  end

  def nested
    @models.fetch('ScopeOwner::NestedScoped')
  end

  it 'verifies the model’s own live scope, in scopes and as a span' do
    expect(outer.dig('answers', 'own_scope')).to eq('site' => 'named.rb', 'own' => true)
    expect(outer.dig('scopes', 'own_scope')).to eq('verified')
    expect(outer.dig('spans', 'own_scope')).to eq('verified')
  end

  it 'publishes a nested model’s scope on the nested unit only' do
    expect(outer['answers']).not_to have_key('nested_scope')
    expect(outer['scopes']).not_to have_key('nested_scope')
    expect(nested['scopes']).to eq('nested_scope' => 'verified')
    expect(nested['spans']).to eq('nested_scope' => 'verified')
  end

  it 'keeps a scope under if false as static' do
    expect(outer['answers']).not_to have_key('dead_scope')
    expect(outer.dig('scopes', 'dead_scope')).to eq('static')
    expect(outer.dig('spans', 'dead_scope')).to eq('static')
  end

  it 'keeps scopes declared inside instance methods as static' do
    expect(outer['answers'].keys).not_to include('deferred_scope', 'bare_scope')
    expect(outer['scopes'].values_at('deferred_scope', 'bare_scope')).to eq(%w[static static])
    expect(outer.dig('spans', 'bare_scope')).to eq('static')
  end

  it 'does not verify a dead scope whose name a class method answers' do
    expect(outer.dig('answers', 'dead_twin')).to eq('site' => 'scope_owner.rb', 'own' => true)
    expect(outer.dig('scopes', 'dead_twin')).to eq('static')
    expect(outer.dig('spans', 'dead_twin')).to eq('static')
  end

  it 'does not verify a dead scope whose name an enum scope answers' do
    expect(outer.dig('answers', 'active')).to eq('site' => 'named.rb', 'own' => true)
    expect(outer.dig('scopes', 'active')).to eq('static')
    expect(outer.dig('spans', 'active')).to eq('static')
  end

  it 'does not verify a dead scope whose name an enum without instance methods answers' do
    skip 'instance_methods: false needs Rails 7.1' if @rails < Gem::Version.new('7.1')

    expect(outer.dig('answers', 'gold')).to eq('site' => 'named.rb', 'own' => true)
    expect(outer.dig('scopes', 'gold')).to eq('static')
    expect(outer.dig('spans', 'gold')).to eq('static')
  end
end
