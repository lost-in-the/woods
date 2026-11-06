# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/experimental/incremental_reuse'
Woods::Experimental::IncrementalReuse::TemplateFacts.install!
RSpec.describe 'Bounded template derivation experiment' do
  include_context 'extractor setup'
  include_context 'isolated Woods runtime'
  let(:cache) { Woods::Experimental::IncrementalReuse::TemplateFacts::Cache.new }
  before do
    stub_const('ActionController::Base', Class.new)
    stub_const('AlphaController', Class.new(ActionController::Base) do
      def self._prefixes = %w[alpha application]
      def self._layout = nil
    end)
    stub_const('BetaController', Class.new(ActionController::Base) do
      def self._prefixes = %w[beta application]
      def self._layout = nil
    end)
    create_file('app/views/alpha/show.html.erb', "<%= render 'shared/panel' %>\n")
    create_file('app/views/beta/show.html.erb', "<p>Beta</p>\n")
    create_file('app/views/shared/_panel.html.erb', "<%= render 'badge' %>\n")
    create_file('app/views/alpha/_badge.html.erb', "<b>Alpha</b>\n")
    create_file('app/views/beta/_badge.html.erb', "<b>Beta</b>\n")
  end
  def derive(use_cache: true, routes: nil)
    allow(Woods::Experimental::IncrementalReuse::TemplateFacts).to receive(:active_cache)
      .and_return(use_cache ? cache : nil)
    ex = Woods::Extractors::ViewTemplateExtractor.new
    ex.instance_variable_set(:@route_helper_map, routes) if routes
    yield ex if block_given?
    ex.extract_all
  end

  def comparable(units)
    units.to_h { |u| [u.identifier, u.to_h.except(:extracted_at)] }
  end

  def expect_oracle(units)
    expect(comparable(units)).to eq(comparable(derive(use_cache: false)))
  end
  it 'replays packed engine query arguments as the current engine instance' do
    extractor = Woods::Extractors::ViewTemplateExtractor.new
    engine = extractor.instance_variable_get(:@engines).first
    packed = extractor.send(:reuse_pack, [engine, 'literal'])
    expect(extractor.send(:reuse_unpack, packed)).to eq([engine, 'literal'])
  end

  it 'uses owned raw copies and resolves the complete caller tree on cache hits' do
    initial = derive
    initial.first.metadata[:corrupt] = true
    got = derive
    expect_oracle(got)
    expect(cache.counts[:hits]).to eq(5)
    expect(got.find { |u| u.identifier == 'shared/_panel.html.erb' }.dependencies)
      .to include(type: :view_template, target: 'alpha/_badge.html.erb', via: :render)
  end
  it 'derives only one changed raw template for an ordinary text edit' do
    derive
    before = cache.counts.dup
    create_file('app/views/beta/show.html.erb', "<p>Updated text</p>\n")
    expect_oracle(derive)
    expect(cache.counts[:misses] - before[:misses]).to eq(1)
    expect(cache.counts[:hits] - before[:hits]).to eq(4)
  end
  it 'retargets an unchanged partial when a changed caller introduces ambiguity' do
    derive
    create_file('app/views/beta/show.html.erb', "<%= render 'shared/panel' %>\n")
    got = derive
    expect_oracle(got)
    panel = got.find { |u| u.identifier == 'shared/_panel.html.erb' }
    expect(panel.dependencies.select { |d| d[:via] == :render }).to eq([])
    expect(panel.metadata[:unresolved_partials]).to include(
      kind: 'caller_prefix', name: 'badge',
      candidates: ['alpha/_badge.html.erb', 'beta/_badge.html.erb']
    )
  end
  it 'invalidates the inventory on deletion' do
    derive
    File.unlink(File.join(tmp_dir, 'app/views/alpha/_badge.html.erb'))
    expect_oracle(derive)
    expect(cache.counts[:inventory_invalidations]).to eq(1)
  end
  it 'invalidates on rename and derives the new identity' do
    derive
    File.rename(File.join(tmp_dir, 'app/views/alpha/_badge.html.erb'),
                File.join(tmp_dir, 'app/views/alpha/_badge_new.html.erb'))
    create_file('app/views/shared/_panel.html.erb', "<%= render 'badge_new' %>\n")
    got = derive
    expect_oracle(got)
    expect(got.map(&:identifier)).to include('alpha/_badge_new.html.erb')
    expect(got.map(&:identifier)).not_to include('alpha/_badge.html.erb')
  end
  it 'invalidates on added format/engine variants' do
    derive
    create_file('app/views/alpha/_badge.html+phone.haml', "%b Phone\n")
    expect_oracle(derive)
    expect(cache.counts[:inventory_invalidations]).to eq(1)
  end
  it 'queries fresh controller prefixes even when class identity stays unchanged' do
    derive
    AlphaController.define_singleton_method(:_prefixes) { %w[beta application] }
    expect_oracle(derive)
  end
  it 'invalidates owning-class identity after a runtime replacement' do
    derive
    stub_const('AlphaController', Class.new(ActionController::Base))
    before = cache.counts.dup
    expect_oracle(derive)
    expect(cache.counts[:misses] - before[:misses]).to be >= 1
  end
  it 'rechecks route/navigation values outside template source bytes' do
    create_file('app/views/beta/show.html.erb', "<%= link_to 'Go', widgets_path %>\n")
    Woods.configuration.extract_navigation_edges = true
    a = { 'widgets' => { controller: 'WidgetsController', action: 'index', path: '/widgets', verb: 'GET' } }
    b = { 'widgets' => { controller: 'OtherController', action: 'show', path: '/other', verb: 'POST' } }
    derive(routes: a)
    got = derive(routes: b)
    reference = derive(use_cache: false, routes: b)
    expect(comparable(got)).to eq(comparable(reference))
    expect(got.find do |u|
      u.identifier == 'beta/show.html.erb'
    end.dependencies).to include(type: :controller, target: 'OtherController',
                                 via: :link_to)
  end
  it 'bounds entry count without changing extraction results' do
    small = Woods::Experimental::IncrementalReuse::TemplateFacts::Cache.new(max_entries: 1, max_bytes: 100_000)
    allow(self).to receive(:cache).and_return(small)
    expect_oracle(derive)
    expect(small.entries.size).to eq(1)
    expect(small.counts[:bounded_refusals]).to be > 0
  end
  it 'bounds serialized bytes without changing extraction results' do
    small = Woods::Experimental::IncrementalReuse::TemplateFacts::Cache.new(max_bytes: 1)
    allow(self).to receive(:cache).and_return(small)
    expect_oracle(derive)
    expect(small.bytes).to eq(0)
    expect(small.counts[:bounded_refusals]).to eq(5)
  end
  it 'falls back after a cache probe failure' do
    derive
    allow(cache).to receive(:fetch).and_raise(IOError, 'controlled probe failure')
    expect_oracle(derive)
    expect(cache.counts[:probe_errors]).to eq(5)
  end
  it 'always reruns helper and frontend resolution on raw hits' do
    state = 'before'
    instrument = lambda do |ex|
      allow(ex).to receive(:apply_helper_calls).and_wrap_original do |original, unit, *args|
        original.call(unit, *args)
        unit.metadata[:pilot_fresh_helper] = state
      end
      allow(ex).to receive(:apply_frontend_references).and_wrap_original do |original, unit, *args|
        result = original.call(unit, *args)
        unit.metadata[:pilot_fresh_frontend] = state
        result
      end
    end
    derive(&instrument)
    state = 'after'
    got = derive(&instrument)
    expect(comparable(got)).to eq(comparable(derive(use_cache: false, &instrument)))
    expect(got.map { |u| u.metadata[:pilot_fresh_helper] }.uniq).to eq(['after'])
    expect(got.map { |u| u.metadata[:pilot_fresh_frontend] }.uniq).to eq(['after'])
    expect(cache.counts[:hits]).to eq(5)
  end
  it 'does not turn failed cache storage into an application failure' do
    allow(cache).to receive(:put).and_raise(IOError, 'controlled storage failure')
    expect_oracle(derive)
    expect(cache.counts[:probe_errors]).to eq(5)
  end
  it 'retains the original source-read failure handling after probe fallback' do
    derive
    path = File.join(tmp_dir, 'app/views/beta/show.html.erb')
    allow(Woods::SourceFile).to receive(:read).and_call_original
    allow(Woods::SourceFile).to receive(:read).with(path).and_raise(IOError, 'controlled application source failure')
    expect(logger).to receive(:error).with(/controlled application source failure/).at_least(:once)
    expect_oracle(derive)
    expect(cache.counts[:probe_errors]).to eq(0)
  end
  it 'does not retry away a transient application source-read failure' do
    derive
    path = File.join(tmp_dir, 'app/views/beta/show.html.erb')
    calls = 0
    allow(Woods::SourceFile).to receive(:read).and_wrap_original do |original, p|
      if p == path
        calls += 1
        raise IOError, 'transient application source failure' if calls == 1
      end
      original.call(p)
    end
    expect(logger).to receive(:error).with(/transient application source failure/).once
    got = derive
    expect(calls).to eq(1)
    expect(got.map(&:identifier)).not_to include('beta/show.html.erb')
  end
  it 'does not retry away a transient application dependency-query failure' do
    derive
    calls = 0
    expect(logger).to receive(:error).with(/transient application query failure/).once
    got = derive do |ex|
      allow(ex).to receive(:resolve_navigation_candidates).and_wrap_original do |original, engine, source|
        if source == "<p>Beta</p>\n"
          calls += 1
          raise IOError, 'transient application query failure' if calls == 1
        end
        original.call(engine, source)
      end
    end
    expect(calls).to eq(1)
    expect(got.map(&:identifier)).not_to include('beta/show.html.erb')
  end
  it 'preserves SourceFile UTF-8 decoding and scrubbing semantics on cache hits' do
    path = File.join(tmp_dir, 'app/views/beta/show.html.erb')
    File.binwrite(path, "<p>Unicode — badge</p>\n".b + "\xff".b)
    derive
    got = derive
    expect_oracle(got)
    text = got.find { |u| u.identifier == 'beta/show.html.erb' }.source_code
    expect(text).to be_valid_encoding
    expect(text).to include('Unicode — badge', "\uFFFD")
    # Different invalid bytes normalize to the same extraction input string;
    # raw-byte freshness is independently owned by SourceInputs, not this cache.
    File.binwrite(path, "<p>Unicode — badge</p>\n".b + "\xfe".b)
    expect_oracle(derive)
  end
end
