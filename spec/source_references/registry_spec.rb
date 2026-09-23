# frozen_string_literal: true

require 'spec_helper'
require 'woods/source_references/registry'
require 'woods/extracted_unit'

RSpec.describe Woods::SourceReferences::Registry do
  let(:root) { '/application' }
  let(:sources) { {} }
  let(:units) { [] }

  def add_unit(name, type: :poro, path: nil, kind: 'class', nesting: nil)
    path ||= "#{root}/#{name.gsub('::', '_')}.rb"
    unit = Woods::ExtractedUnit.new(type: type, identifier: name, file_path: path)
    units << unit
    source = (sources[path] ||= { 'declarations' => [], 'references' => [], 'parse_error' => nil })
    source['declarations'] << {
      'owner' => name, 'name' => "::#{name}", 'kind' => kind,
      'nesting' => nesting || [name], 'enclosing_nesting' => [], 'line' => 1, 'end_line' => 9
    }
    unit
  end

  def reference(name, owner: 'RefCaller', nesting: [owner])
    { 'owner' => owner, 'nesting' => nesting, 'name' => name, 'line' => 4 }
  end

  def registry
    described_class.new(units: units, sources: sources, root: root)
  end

  before do
    stub_const('RefCaller', Class.new)
    stub_const('RefToken', Class.new)
    add_unit('RefCaller')
    add_unit('RefToken')
  end

  it 'resolves a root-qualified constant without executing a method' do
    RefToken.define_singleton_method(:generate) { raise 'must not execute application methods' }
    expect(registry.resolve(reference('::RefToken'), file_path: '/application/RefCaller.rb'))
      .to eq(type: :poro, target: 'RefToken', via: :code_reference)
  end

  it 'resolves bare constants through the real top-level binding' do
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb'))
      .to include(target: 'RefToken')
  end

  it 'does not infer a constant target from a factory identity' do
    units.last.type = :factory
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'does not accept source ownership from a filename alone' do
    sources['/application/RefToken.rb']['declarations'].clear
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'requires the caller to own the source declaration' do
    expect(registry.resolve(reference('RefToken'), file_path: '/application/unrelated.rb')).to be_nil
  end

  it 'declines an identifier with colliding extracted types' do
    add_unit('RefToken', type: :service)
    expect(registry.explain(reference('RefToken'), file_path: '/application/RefCaller.rb'))
      .to include('status' => 'unresolved', 'reason' => 'ambiguous_target')
  end

  it 'respects scalar shadowing instead of falling back to a global target' do
    RefCaller.const_set(:RefToken, 123)
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb')).to be_nil
    expect(registry.resolve(reference('::RefToken'), file_path: '/application/RefCaller.rb'))
      .to include(target: 'RefToken')
  end

  it 'distinguishes nested lexical scopes from compact declarations' do
    stub_const('RefOuter', Module.new)
    RefOuter.const_set(:RefCaller, Class.new)
    RefOuter.const_set(:RefToken, Class.new)
    add_unit('RefOuter::RefCaller', nesting: %w[RefOuter::RefCaller RefOuter])
    add_unit('RefOuter::RefToken')
    nested = reference('RefToken', owner: 'RefOuter::RefCaller', nesting: %w[RefOuter::RefCaller RefOuter])
    compact = nested.merge('nesting' => ['RefOuter::RefCaller'])
    expect(registry.resolve(nested, file_path: '/application/RefOuter_RefCaller.rb'))
      .to include(target: 'RefOuter::RefToken')
    expect(registry.resolve(compact, file_path: '/application/RefOuter_RefCaller.rb'))
      .to include(target: 'RefToken')
  end

  it 'uses inherited constants after lexical bindings' do
    stub_const('RefParent', Class.new)
    RefParent.const_set(:RefToken, Class.new)
    stub_const('RefChild', Class.new(RefParent))
    add_unit('RefChild')
    add_unit('RefParent::RefToken')
    expect(registry.resolve(reference('RefToken', owner: 'RefChild'), file_path: '/application/RefChild.rb'))
      .to include(target: 'RefParent::RefToken')
  end

  it 'never triggers an unresolved autoload or falls back past it' do
    RefCaller.autoload(:RefToken, '/does/not/exist/never_load.rb')
    expect(registry.explain(reference('RefToken'), file_path: '/application/RefCaller.rb'))
      .to include('reason' => 'autoload_pending')
    expect(RefCaller.autoload?(:RefToken)).to eq('/does/not/exist/never_load.rb')
  end

  it 'bypasses application overrides of constant reflection' do
    RefCaller.define_singleton_method(:const_get) { |*| raise 'must not call application code' }
    RefCaller.define_singleton_method(:const_defined?) { |*| raise 'must not call application code' }
    RefCaller.define_singleton_method(:const_missing) { |*| raise 'must not call application code' }
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb'))
      .to include(target: 'RefToken')
    expect(registry.resolve(reference('NoSuchConstant'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'does not guess from globally unique short names' do
    stub_const('RefDomain', Module.new)
    RefDomain.const_set(:OnlyThere, Class.new)
    add_unit('RefDomain::OnlyThere')
    expect(registry.resolve(reference('OnlyThere'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'does not resolve a longer absent path to a known prefix' do
    expect(registry.resolve(reference('RefToken::Missing'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'accepts a verified unloaded library declaration for a root-qualified reference' do
    add_unit('RefOffline', type: :lib)
    expect(registry.resolve(reference('::RefOffline'), file_path: '/application/RefCaller.rb'))
      .to include(type: :lib, target: 'RefOffline')
  end

  it 'declines an unloaded non-library declaration' do
    add_unit('RefOffline')
    expect(registry.resolve(reference('::RefOffline'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'does not treat a BasicObject subclass as having Object constant lookup' do
    stub_const('RefMinimal', Class.new(BasicObject))
    add_unit('RefMinimal')
    result = registry.resolve(reference('RefToken', owner: 'RefMinimal'), file_path: '/application/RefMinimal.rb')
    expect(result).to be_nil
  end

  it 'prefers a qualified receiver own constant over a prepended module' do
    stub_const('RefPrepended', Module.new)
    RefPrepended.const_set(:RefToken, Class.new)
    RefCaller.const_set(:RefToken, Class.new)
    RefCaller.prepend(RefPrepended)
    add_unit('RefPrepended::RefToken')
    add_unit('RefCaller::RefToken')
    expect(registry.resolve(reference('RefCaller::RefToken'), file_path: '/application/RefCaller.rb'))
      .to include(target: 'RefCaller::RefToken')
  end

  it 'rejects qualified private constants but accepts their bare lexical references' do
    stub_const('RefPrivate', Module.new)
    RefPrivate.const_set(:RefToken, Class.new)
    RefPrivate.const_set(:RefCaller, Class.new)
    add_unit('RefPrivate::RefToken')
    add_unit('RefPrivate::RefCaller')
    RefPrivate.private_constant(:RefToken)
    expect(registry.resolve(reference('::RefPrivate::RefToken'), file_path: '/application/RefCaller.rb')).to be_nil
    bare = reference('RefToken', owner: 'RefPrivate::RefCaller', nesting: %w[RefPrivate::RefCaller RefPrivate])
    expect(registry.resolve(bare, file_path: '/application/RefPrivate_RefCaller.rb'))
      .to include(target: 'RefPrivate::RefToken')
  end

  it 'does not resolve a root library through a BasicObject scope' do
    stub_const('RefMinimal', Class.new(BasicObject))
    add_unit('RefMinimal')
    add_unit('RefOffline', type: :lib)
    record = reference('RefOffline', owner: 'RefMinimal')
    expect(registry.resolve(record, file_path: '/application/RefMinimal.rb')).to be_nil
    expect(registry.resolve(record.merge('name' => '::RefOffline'), file_path: '/application/RefMinimal.rb'))
      .to include(target: 'RefOffline')
  end

  it 'does not find top-level constants through a qualified class path' do
    expect(registry.resolve(reference('RefCaller::RefToken'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'does not invoke overridden type, identity or hashing methods on application constants' do
    %i[is_a? equal? hash eql? name].each do |method|
      RefCaller.define_singleton_method(method) { |*| raise 'application reflection override invoked' }
      RefToken.define_singleton_method(method) { |*| raise 'application reflection override invoked' }
    end
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb'))
      .to include(target: 'RefToken')
  end

  it 'declines singleton-class lookup until its constant table is verified' do
    record = reference('RefToken').merge('singleton_depth' => 1)
    expect(registry.explain(record, file_path: '/application/RefCaller.rb'))
      .to include('reason' => 'unsupported_singleton_scope')
  end

  it 'rejects a declaration whose runtime kind differs from the source' do
    sources['/application/RefToken.rb']['declarations'].first['kind'] = 'module'
    expect(registry.resolve(reference('RefToken'), file_path: '/application/RefCaller.rb')).to be_nil
  end

  it 'rejects malformed constant expressions without evaluating them' do
    expect(registry.resolve(reference('RefToken.new'), file_path: '/application/RefCaller.rb')).to be_nil
  end
end
