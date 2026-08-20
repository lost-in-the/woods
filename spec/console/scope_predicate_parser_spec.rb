# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/scope_predicate_parser'

RSpec.describe Woods::Console::ScopePredicateParser do
  let(:registry) do
    {
      'Order' => %w[id status total amount created_at updated_at transaction_id total_refund notes]
    }
  end
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }

  subject(:parser) do
    described_class.new(model_name: 'Order', model_validator: validator)
  end

  # ── Arel table / relation helpers ──────────────────────────────────────────

  # Minimal Arel double that records which predicates were built.
  let(:arel_col)   { double('Arel::Attributes::Attribute') }
  let(:arel_node)  { double('arel_node') }
  let(:arel_table) { double('Arel::Table') }
  let(:relation)   { double('ActiveRecord::Relation') }

  before do
    allow(relation).to receive(:arel_table).and_return(arel_table)
    allow(arel_table).to receive(:[]).and_return(arel_col)

    # Default: all predicate methods return a node double
    %i[eq not_eq gt gteq lt lteq in not_in matches].each do |pred|
      allow(arel_col).to receive(pred).and_return(arel_node)
    end

    # Chained Arel nodes for _present / _blank
    allow(arel_node).to receive(:and).and_return(arel_node)
    allow(arel_node).to receive(:or).and_return(arel_node)

    allow(relation).to receive(:where).and_return(relation)
  end

  # ── Equality pass-through ───────────────────────────────────────────────────

  describe 'plain equality hash (no suffix)' do
    it 'delegates to relation.where without touching the parser' do
      parser.parse(relation, { 'status' => 'paid' })
      expect(relation).to have_received(:where).with({ 'status' => 'paid' })
    end

    it 'returns relation unchanged for empty hash' do
      result = parser.parse(relation, {})
      expect(result).to eq(relation)
      expect(relation).not_to have_received(:where)
    end

    it 'rejects an unknown equality column before relation.where' do
      expect do
        parser.parse(relation, { 'unknown' => 'paid' })
      end.to raise_error(Woods::Console::ValidationError, /Unknown column 'unknown'/)

      expect(relation).not_to have_received(:where)
    end
  end

  # ── Supported suffixes ──────────────────────────────────────────────────────

  describe '_eq suffix' do
    it 'builds eq predicate' do
      allow(arel_table).to receive(:[]).with('status').and_return(arel_col)
      allow(arel_col).to receive(:eq).with('paid').and_return(arel_node)

      parser.parse(relation, { 'status_eq' => 'paid' })
      expect(arel_col).to have_received(:eq).with('paid')
    end
  end

  describe '_not_eq suffix' do
    it 'builds not_eq predicate' do
      allow(arel_table).to receive(:[]).with('status').and_return(arel_col)
      allow(arel_col).to receive(:not_eq).with('pending').and_return(arel_node)

      parser.parse(relation, { 'status_not_eq' => 'pending' })
      expect(arel_col).to have_received(:not_eq).with('pending')
    end
  end

  describe '_gt suffix' do
    it 'builds gt predicate' do
      allow(arel_table).to receive(:[]).with('total').and_return(arel_col)
      allow(arel_col).to receive(:gt).with(0).and_return(arel_node)

      parser.parse(relation, { 'total_gt' => 0 })
      expect(arel_col).to have_received(:gt).with(0)
    end
  end

  describe '_gteq suffix' do
    it 'builds gteq predicate' do
      allow(arel_table).to receive(:[]).with('total').and_return(arel_col)
      allow(arel_col).to receive(:gteq).with(100).and_return(arel_node)

      parser.parse(relation, { 'total_gteq' => 100 })
      expect(arel_col).to have_received(:gteq).with(100)
    end
  end

  describe '_lt suffix' do
    it 'builds lt predicate' do
      allow(arel_table).to receive(:[]).with('amount').and_return(arel_col)
      allow(arel_col).to receive(:lt).with(50).and_return(arel_node)

      parser.parse(relation, { 'amount_lt' => 50 })
      expect(arel_col).to have_received(:lt).with(50)
    end
  end

  describe '_lteq suffix' do
    it 'builds lteq predicate' do
      allow(arel_table).to receive(:[]).with('amount').and_return(arel_col)
      allow(arel_col).to receive(:lteq).with(200).and_return(arel_node)

      parser.parse(relation, { 'amount_lteq' => 200 })
      expect(arel_col).to have_received(:lteq).with(200)
    end
  end

  describe '_in suffix' do
    it 'builds in predicate with array value' do
      allow(arel_table).to receive(:[]).with('status').and_return(arel_col)
      allow(arel_col).to receive(:in).with(%w[paid refunded]).and_return(arel_node)

      parser.parse(relation, { 'status_in' => %w[paid refunded] })
      expect(arel_col).to have_received(:in).with(%w[paid refunded])
    end

    it 'wraps scalar value in Array' do
      allow(arel_table).to receive(:[]).with('status').and_return(arel_col)
      allow(arel_col).to receive(:in).with(['paid']).and_return(arel_node)

      parser.parse(relation, { 'status_in' => 'paid' })
      expect(arel_col).to have_received(:in).with(['paid'])
    end
  end

  describe '_not_in suffix' do
    it 'builds not_in predicate' do
      allow(arel_table).to receive(:[]).with('status').and_return(arel_col)
      allow(arel_col).to receive(:not_in).with(%w[cancelled failed]).and_return(arel_node)

      parser.parse(relation, { 'status_not_in' => %w[cancelled failed] })
      expect(arel_col).to have_received(:not_in).with(%w[cancelled failed])
    end
  end

  describe '_null suffix' do
    it 'builds eq(nil) when value is true' do
      allow(arel_table).to receive(:[]).with('transaction_id').and_return(arel_col)
      allow(arel_col).to receive(:eq).with(nil).and_return(arel_node)

      parser.parse(relation, { 'transaction_id_null' => true })
      expect(arel_col).to have_received(:eq).with(nil)
    end

    it 'builds not_eq(nil) when value is false' do
      allow(arel_table).to receive(:[]).with('transaction_id').and_return(arel_col)
      allow(arel_col).to receive(:not_eq).with(nil).and_return(arel_node)

      parser.parse(relation, { 'transaction_id_null' => false })
      expect(arel_col).to have_received(:not_eq).with(nil)
    end
  end

  describe '_not_null suffix' do
    it 'builds not_eq(nil) when value is true' do
      allow(arel_table).to receive(:[]).with('transaction_id').and_return(arel_col)
      allow(arel_col).to receive(:not_eq).with(nil).and_return(arel_node)

      parser.parse(relation, { 'transaction_id_not_null' => true })
      expect(arel_col).to have_received(:not_eq).with(nil)
    end

    it 'builds eq(nil) when value is false' do
      allow(arel_table).to receive(:[]).with('transaction_id').and_return(arel_col)
      allow(arel_col).to receive(:eq).with(nil).and_return(arel_node)

      parser.parse(relation, { 'transaction_id_not_null' => false })
      expect(arel_col).to have_received(:eq).with(nil)
    end
  end

  describe '_present suffix' do
    it 'builds NOT NULL AND != empty-string when true' do
      allow(arel_table).to receive(:[]).with('notes').and_return(arel_col)
      not_null_node = double('not_null')
      allow(arel_col).to receive(:not_eq).with(nil).and_return(not_null_node)
      allow(not_null_node).to receive(:and).and_return(arel_node)

      parser.parse(relation, { 'notes_present' => true })
      expect(arel_col).to have_received(:not_eq).with(nil)
      expect(not_null_node).to have_received(:and)
    end

    it 'builds NULL OR empty-string when false' do
      allow(arel_table).to receive(:[]).with('notes').and_return(arel_col)
      null_node = double('null')
      allow(arel_col).to receive(:eq).with(nil).and_return(null_node)
      allow(null_node).to receive(:or).and_return(arel_node)

      parser.parse(relation, { 'notes_present' => false })
      expect(arel_col).to have_received(:eq).with(nil)
      expect(null_node).to have_received(:or)
    end
  end

  describe '_blank suffix' do
    it 'builds NULL OR empty-string when true' do
      allow(arel_table).to receive(:[]).with('notes').and_return(arel_col)
      null_node = double('null')
      allow(arel_col).to receive(:eq).with(nil).and_return(null_node)
      allow(null_node).to receive(:or).and_return(arel_node)

      parser.parse(relation, { 'notes_blank' => true })
      expect(arel_col).to have_received(:eq).with(nil)
      expect(null_node).to have_received(:or)
    end
  end

  describe '_matches suffix' do
    it 'builds LIKE predicate' do
      allow(arel_table).to receive(:[]).with('notes').and_return(arel_col)
      allow(arel_col).to receive(:matches).with('%refund%').and_return(arel_node)

      parser.parse(relation, { 'notes_matches' => '%refund%' })
      expect(arel_col).to have_received(:matches).with('%refund%')
    end
  end

  # ── Mixed hash (equality + predicate) ──────────────────────────────────────

  describe 'mixed hash' do
    it 'splits equality keys from predicate keys' do
      allow(arel_table).to receive(:[]).with('total_refund').and_return(arel_col)
      allow(arel_col).to receive(:gt).with(0).and_return(arel_node)

      parser.parse(relation, { 'status' => 'paid', 'total_refund_gt' => 0 })

      # Plain equality routed to where(hash)
      expect(relation).to have_received(:where).with({ 'status' => 'paid' })
      # Predicate built via Arel
      expect(arel_col).to have_received(:gt).with(0)
    end
  end

  # ── Suffix value-type enforcement (truthiness-inversion guard) ─────────────

  describe 'existence-suffix strict boolean enforcement' do
    %w[transaction_id_null transaction_id_not_null notes_present notes_blank].each do |key|
      it "raises ValidationError for the string 'false' on #{key} instead of treating it as truthy" do
        expect do
          parser.parse(relation, { key => 'false' })
        end.to raise_error(Woods::Console::ValidationError, /requires a strict boolean value/)
      end

      it "raises ValidationError for a non-boolean value on #{key}" do
        expect do
          parser.parse(relation, { key => 1 })
        end.to raise_error(Woods::Console::ValidationError, /requires a strict boolean value/)
      end

      it "accepts a real boolean on #{key}" do
        allow(arel_table).to receive(:[]).and_return(arel_col)

        expect { parser.parse(relation, { key => true }) }.not_to raise_error
        expect { parser.parse(relation, { key => false }) }.not_to raise_error
      end
    end
  end

  describe 'comparison-suffix scalar enforcement' do
    %w[total_gt total_gteq amount_lt amount_lteq].each do |key|
      it "raises ValidationError for an Array value on #{key}" do
        expect do
          parser.parse(relation, { key => [1, 2] })
        end.to raise_error(Woods::Console::ValidationError, /requires a scalar/)
      end

      it "raises ValidationError for a Hash value on #{key}" do
        expect do
          parser.parse(relation, { key => { 'a' => 1 } })
        end.to raise_error(Woods::Console::ValidationError, /requires a scalar/)
      end
    end
  end

  # ── Column validation (SQL injection guard) ─────────────────────────────────

  describe 'column validation' do
    it 'raises ValidationError for unknown column with predicate suffix' do
      expect do
        parser.parse(relation, { 'evil_column_gt' => 0 })
      end.to raise_error(Woods::Console::ValidationError, /Unknown column 'evil_column'/)
    end

    it 'raises ValidationError for injection attempt in column name' do
      expect do
        parser.parse(relation, { 'id; DROP TABLE orders; --_eq' => 1 })
      end.to raise_error(Woods::Console::ValidationError, /Unknown column/)
    end
  end

  # ── Symbol keys ────────────────────────────────────────────────────────────

  describe 'symbol keys' do
    it 'handles symbol predicate keys' do
      allow(arel_table).to receive(:[]).with('total').and_return(arel_col)
      allow(arel_col).to receive(:gt).with(0).and_return(arel_node)

      parser.parse(relation, { total_gt: 0 })
      expect(arel_col).to have_received(:gt).with(0)
    end

    it 'handles plain symbol equality keys' do
      parser.parse(relation, { status: 'paid' })
      expect(relation).to have_received(:where).with({ status: 'paid' })
    end
  end
end
