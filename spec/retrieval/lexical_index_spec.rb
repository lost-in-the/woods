# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/lexical_index'
require 'woods/storage/metadata_store'
require 'woods/storage_identity'
require 'weakref'

RSpec.describe Woods::Retrieval::LexicalIndex do
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }

  def add(identifier, type: 'model', source: '', metadata: {}, path: nil)
    key = Woods::StorageIdentity.key(identifier, type)
    store.store(key, { 'identifier' => identifier, 'type' => type, 'source_code' => source,
                       'file_path' => path, 'metadata' => metadata })
    key
  end

  def search(query, **options)
    described_class.new(metadata_store: store).execute(query: query, **options).candidates
  end

  # Keep a full-scan oracle for candidate selection. Scoring and the final
  # comparator are unchanged; every document reaches the original scorer.
  let(:scan_class) do
    Class.new(described_class) do
      private

      def candidate_documents(_query, _terms)
        @documents
      end
    end
  end

  it 'scores only possible matches for selective and absent queries' do
    20.times { |i| add("Unrelated#{i}", source: 'ordinary work') }
    target = add('Delivery', source: 'rareword')
    index = described_class.new(metadata_store: store)
    scored = []
    allow(index).to receive(:score_document).and_wrap_original do |method, document, terms|
      scored << document.key
      method.call(document, terms)
    end

    expect(index.execute(query: 'rareword').candidates.map(&:identifier)).to eq([target])
    expect(scored).to eq([target])
    scored.clear
    expect(index.execute(query: 'neverindexed').candidates).to be_empty
    expect(scored).to be_empty
  end

  it 'matches the full scan for exact identities, Unicode, filters, limits and scoped statistics' do
    keys = [add('The'), add('Straße'), add('Σ'), add('İ'), add('I'),
            add('ÉclairPayment', path: 'app/services/charge_card.rb', source: 'label payment rareword',
                                 metadata: { 'callbacks' => ['normalize_phone'] }),
            add('Billing::Invoice', source: 'label label commonword'),
            add('Billing::Invoice', type: 'service', source: 'payment commonword'),
            add('Other', source: 'rareword commonword'), add('EqualA', source: 'notify'),
            add('EqualB', source: 'notify'), add('Spec', type: 'test_mapping', source: 'notify'),
            add(''), add('::')]
    index = described_class.new(metadata_store: store)
    scan = scan_class.new(metadata_store: store)
    queries = ['  THE  ', 'STRASSE', 'σ', 'ς', 'i', "i\u0307", 'ı', 'éclair charge card',
               "e\u0301clair", 'labels payment', 'rareword rareword', 'normalize phone',
               'Billing::Invoice', 'notify', 'commonword', 'neverindexed', 'how does the', '', '::']
    options = [{}, { limit: 0 }, { limit: 1 }, { limit: 40 },
               { type_filter: [:service], exclude_types: ['service'] },
               { type_filter: [], exclude_types: ['model'] }, { exclude_types: ['test_mapping'] }]
    scopes = [nil, [], keys, keys.first(1), keys.first(3), keys.first(6), keys.first(13),
              [keys.first, keys.first, 'unknown:key']]

    scopes.each do |scope|
      actual = scope ? index.restricted_to(scope) : index
      expected = scope ? scan.restricted_to(scope) : scan
      queries.product(options).each do |query, arguments|
        result = actual.execute(query: query, **arguments)
        expect(result).to eq(expected.execute(query: query, **arguments)), "#{scope.inspect}: #{query}: #{arguments}"
        result.candidates.each do |candidate|
          expect(candidate.metadata).to equal(actual.units.fetch(candidate.identifier))
          expect(candidate.metadata).to be_frozen
        end
      end
    end

    nested = index.restricted_to(keys.first(3)).restricted_to(keys.last(3))
    expect(nested.execute(query: 'notify').candidates).to be_empty
  end

  it 'scores only scoped posting matches without rebuilding documents or postings, including nested views' do
    keys = 30.times.map { |i| add("Ordinary#{i}", source: 'commonword') }
    target = add('Delivery', source: 'rareword commonword')
    outside = add('Outside', source: 'rareword commonword')
    index = described_class.new(metadata_store: store)
    expect(store).not_to receive(:find)
    expect_any_instance_of(described_class).not_to receive(:build_documents)
    expect_any_instance_of(described_class).not_to receive(:build_candidate_postings)

    broad = index.restricted_to(keys + [target])
    narrow = broad.restricted_to(keys.first(8) + [target, outside])
    [broad, narrow].each do |view|
      expect(view.units.fetch(target)).to equal(index.units.fetch(target))
      scored = []
      allow(view).to receive(:score_document).and_wrap_original do |method, document, terms|
        scored << document.key
        method.call(document, terms)
      end
      expect(view.execute(query: 'rareword').candidates.map(&:identifier)).to eq([target])
      expect(scored).to eq([target])
      scored.clear
      expect(view.execute(query: 'neverindexed').candidates).to be_empty
      expect(scored).to be_empty
    end
  end

  it 'matches fresh full-scan subset indexes for empty, narrow, broad and nested scopes' do
    keys = [add('The'), add('Straße'), add('Σ'), add('İ'), add('I'),
            add('Invoice', source: 'rareword commonword'),
            add('Invoice', type: 'service', source: 'commonword'),
            add('EqualA', source: 'notify'), add('EqualB', source: 'notify')]
    index = described_class.new(metadata_store: store)
    parent = index.restricted_to(keys.first(8))
    scopes = [[], keys.first(1), keys.first(4), keys.first(8), keys, [keys.first, keys.first, 'unknown']]
    queries = ['THE', 'STRASSE', 'ς', "i\u0307", 'rareword', 'commonword', 'notify', '', 'how does the']
    options = [{}, { limit: 0 }, { limit: 1 }, { limit: 50 },
               { type_filter: [:service], exclude_types: ['service'] }, { exclude_types: ['model'] }]
    scopes.each do |scope|
      [index, parent].each do |origin|
        eligible = Woods::Storage::MetadataStore::InMemory.new
        (scope & origin.units.keys).each { |key| eligible.store(key, store.find(key)) }
        fresh = scan_class.new(metadata_store: eligible)
        view = origin.restricted_to(scope)
        expect(view).not_to receive(:tally)
        queries.product(options).each do |query, arguments|
          expect(view.execute(query: query, **arguments)).to eq(fresh.execute(query: query, **arguments))
        end
      end
    end
  end

  it 'does not score scoped documents for globally common terms or stop-word exacts outside the scope' do
    keys = 12.times.map { |i| add("Outside#{i}", source: 'foreignword') }
    add('The')
    inside = add('Inside', source: 'localword')
    index = described_class.new(metadata_store: store)
    view = index.restricted_to([inside])
    expect(view).not_to receive(:score_document)
    %w[foreignword THE].each { |query| expect(view.execute(query: query).candidates).to be_empty }
    expect(index.restricted_to(keys).execute(query: 'foreignword').candidates.size).to eq(12)
  end

  it 'preserves scoped invalid query and limit behavior, including empty and type-excluded views' do
    key = add('Inside', source: 'localword')
    index = described_class.new(metadata_store: store)
    empty = index.restricted_to([])
    view = index.restricted_to([key])
    [nil, 1, :localword].each do |query|
      expect(empty.execute(query: query).candidates).to be_empty
      expect(view.execute(query: query, exclude_types: ['model']).candidates).to be_empty
      expect { view.execute(query: query) }.to raise_error(NoMethodError)
    end
    expect { view.execute(query: 'localword', limit: -1) }.to raise_error(ArgumentError)
    expect { empty.execute(query: '', limit: -1) }.to raise_error(ArgumentError)
  end

  # Construct on a separate stack so only the returned view and weak probes
  # survive. MetadataStore retains its original records, not the index copies.
  def detached_view(nested:)
    keep = add('Inside', source: 'localword')
    outside = add('Outside', source: 'foreignword ' * 4000)
    index = described_class.new(metadata_store: store)
    document = index.instance_variable_get(:@documents).find { |doc| doc.key == outside }
    probes = [index, document, document.unit, document.unit.fetch('source_code'), document.fields,
              document.lengths].map { |object| WeakRef.new(object) }
    view = index.restricted_to([keep])
    view = view.restricted_to([keep, outside]) if nested
    [view, probes, keep]
  end

  it 'lets detached narrow and nested views release unrelated document bodies and scoring tallies' do
    [false, true].each do |nested|
      view, probes, keep = detached_view(nested: nested)
      3.times { GC.start(full_mark: true, immediate_sweep: true) }

      probes.each { |probe| expect(probe.weakref_alive?).to be_falsey }
      expect(view.execute(query: 'localword').candidates.map(&:identifier)).to eq([keep])
      %w[foreignword Outside].each { |query| expect(view.execute(query: query).candidates).to be_empty }
    end
  end

  it 'ranks exact identifiers first and preserves ambiguous typed identities' do
    first = add('Billing::Invoice')
    second = add('Billing::Invoice', type: 'service')
    add('Other', source: 'Billing Invoice ' * 50)
    expect(search('Billing::Invoice').first(2).map(&:identifier)).to match_array([first, second])
  end

  it 'splits CamelCase, snake case, paths and Unicode without matching bookkeeping' do
    target = add('ÉclairPayment', path: 'app/services/charge_card.rb')
    add('Other', metadata: { 'source_hash' => 'eclair charge card' })
    expect(search('éclair charge card').map(&:identifier)).to eq([target])
    expect(search('charge').first.matched_fields).to include('file_path:charge')
  end

  # A question in the plural reaches a method named in the singular, and
  # a unit that holds more of its words outranks units that only repeat one
  # rare word in their names.
  it 'ranks the unit whose method name answers the question above units named after one word' do
    source = "before_validation :set_widget_label\ndef set_widget_label\n  self.label ||= next_label\nend"
    callbacks = [{ 'type' => 'before_validation', 'filter' => 'set_widget_label' }]
    widget = add('Widget', path: 'app/models/widget.rb', source: source, metadata: { 'callbacks' => callbacks })
    add('Labels', type: 'lib', path: 'lib/seeds/labels.rb', source: 'LABELS = %w[red blue].freeze')
    add('PrintLabelsController', type: 'controller', path: 'app/controllers/print_labels_controller.rb',
                                 source: 'def index; @labels = Labels::LABELS; end')
    8.times { |i| add("WidgetPart#{i}", source: 'widget widget') }

    results = search('how are widget labels assigned')
    expect(results.first.identifier).to eq(widget)
    expect(results.first.matched_fields).to include('source_code:widget', 'source_code:label', 'runtime:label')
  end

  it 'leaves a one-word query scored by that word alone' do
    one = add('Gadget', source: 'label')
    two = add('Labels', type: 'lib', source: 'nothing')
    expect(search('labels').map(&:identifier)).to eq([two, one])
  end

  it 'finds resolved callback metadata without a literal target name' do
    target = add('Record', metadata: { 'callbacks' => { 'before_save' => ['normalize_phone'] } })
    expect(search('normalize phone').first.identifier).to eq(target)
    expect(search('normalize phone').first.matched_fields).to include('runtime:normalize')
  end

  it 'filters before the candidate limit and never seeds unrelated hubs' do
    25.times { |i| add("Noise#{i}", source: 'notify', type: 'model') }
    target = add('Delivery', source: 'notify', type: 'service')
    add('GlobalHub', metadata: { 'pagerank' => 1000 })
    expect(search('notify', type_filter: ['service'], limit: 1).map(&:identifier)).to eq([target])
    expect(search('nothing-matches')).to be_empty
    expect(search('how does the')).to be_empty
  end

  it 'excludes types and breaks equal scores deterministically' do
    add('Two', source: 'notify')
    add('One', source: 'notify')
    add('Spec', type: 'test_mapping', source: 'notify')
    results = search('notify', exclude_types: ['test_mapping'])
    expect(results.map(&:identifier)).to eq(results.map(&:identifier).sort)
    expect(results.size).to eq(2)
  end

  it 'uses an explicit exact-match tier even against a long term-rich corpus' do
    exact_name = (1..80).map { |i| "Term#{i}" }.join('::')
    target = add(exact_name, source: 'irrelevant ' * 10_000)
    30.times { |i| add("Alternative#{i}", source: exact_name.gsub('::', ' ') * 20) }
    expect(search(exact_name).first.identifier).to eq(target)
  end

  # F6 step 2. A scoped request used to build a whole new index over the
  # eligible records, re-reading and re-tokenising every one of them per
  # request (4.8 s for a 6,130-unit scope on the self-map). A view over this
  # index's own documents answers exactly what that rebuilt index did: the
  # BM25 statistics are recomputed over the subset, the documents are shared.
  it 'answers a restricted view exactly like an index built over the subset, without re-reading the store' do
    billing = add('Invoice', source: 'charge the customer ledger', path: 'packs/billing/app/models/invoice.rb')
    add('Ledger', source: 'ledger ledger entries', path: 'packs/billing/app/models/ledger.rb')
    add('Shipment', source: 'ledger of parcels', path: 'packs/shipping/app/models/shipment.rb')
    index = described_class.new(metadata_store: store)
    subset = Woods::Storage::MetadataStore::InMemory.new
    [billing, Woods::StorageIdentity.key('Ledger', 'model')].each { |key| subset.store(key, store.find(key)) }
    direct = described_class.new(metadata_store: subset)
    allow(store).to receive(:find).and_call_original

    view = index.restricted_to(subset.all_identifiers)

    expect(store).not_to have_received(:find)
    %w[ledger customer parcels Invoice].each do |query|
      shape = ->(result) { result.candidates.map { |c| [c.identifier, c.score, c.matched_fields, c.metadata] } }
      expect(shape.call(view.execute(query: query))).to eq(shape.call(direct.execute(query: query)))
    end
    # Statistics are the subset's: "ledger" is rarer in the full index than in the view.
    full_score = index.execute(query: 'ledger').candidates.find { |c| c.identifier == billing }.score
    view_score = view.execute(query: 'ledger').candidates.find { |c| c.identifier == billing }.score
    expect(view_score).not_to eq(full_score)
    expect(view.execute(query: 'parcels').candidates).to be_empty
  end

  # The restricted view derives its statistics either by recounting the
  # subset or, when the subset is most of the index, by subtracting the
  # excluded documents from the full-index tallies. Both must equal a fresh
  # index over the subset, including for a term only the excluded document
  # carried and for one whose rarity the exclusion changes.
  it 'derives majority and minority views by the same statistics as a fresh index over the subset' do
    keys = [add('Invoice', source: 'charge the customer ledger'),
            add('Ledger', source: 'ledger ledger entries'),
            add('Payment', source: 'customer payment entries'),
            add('Refund', source: 'refund the customer'),
            add('Shipment', source: 'ledger of parcels')]
    index = described_class.new(metadata_store: store)
    shape = ->(result) { result.candidates.map { |c| [c.identifier, c.score, c.matched_fields, c.metadata] } }
    [keys.first(4), keys.first(2)].each do |subset|
      eligible = Woods::Storage::MetadataStore::InMemory.new
      subset.each { |key| eligible.store(key, store.find(key)) }
      fresh = described_class.new(metadata_store: eligible)
      view = index.restricted_to(subset)
      %w[ledger parcels customer entries Invoice refund].each do |query|
        expect(shape.call(view.execute(query: query))).to eq(shape.call(fresh.execute(query: query)))
      end
      expect(view.execute(query: 'parcels').candidates).to be_empty
    end
  end

  it 'exposes its immutable units by key for a shared scope corpus' do
    key = add('Invoice', source: 'charge', path: 'app/models/invoice.rb')
    index = described_class.new(metadata_store: store)
    expect(index.units.keys).to eq([key])
    expect(index.units).to be_frozen
    expect(index.units.fetch(key)).to be_frozen
    expect(index.units.fetch(key)).to equal(index.execute(query: 'charge').candidates.first.metadata)
  end

  it 'retains an immutable snapshot when the underlying store changes' do
    key = add('Record', source: 'oldword')
    index = described_class.new(metadata_store: store)
    store.store(key, { 'identifier' => 'Record', 'type' => 'model', 'source_code' => 'newword' })
    expect(index.execute(query: 'oldword').candidates.first.metadata['source_code']).to eq('oldword')
    expect(index.execute(query: 'newword').candidates).to be_empty
  end
end
