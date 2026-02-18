# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extractors/model_extractor'

RSpec.describe CodebaseIndex::Extractors::ModelExtractor do
  let(:extractor) { described_class.new }

  # ── habtm_join_model? ─────────────────────────────────────────────

  describe '#habtm_join_model?' do
    it 'detects top-level HABTM join models' do
      model = double('Model', name: 'HABTM_Products')

      expect(extractor.send(:habtm_join_model?, model)).to be true
    end

    it 'detects namespaced HABTM join models' do
      model = double('Model', name: 'Product::HABTM_Categories')

      expect(extractor.send(:habtm_join_model?, model)).to be true
    end

    it 'returns false for normal model names' do
      model = double('Model', name: 'Post')

      expect(extractor.send(:habtm_join_model?, model)).to be false
    end
  end

  # ── extract_scopes ────────────────────────────────────────────────

  describe '#extract_scopes' do
    it 'extracts single-line brace scope' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :active, -> { where(active: true) }
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('active')
      expect(scopes[0][:source]).to include('where(active: true)')
    end

    it 'extracts multi-line brace scope' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :complex, -> {
            joins(:comments)
              .where(comments: { approved: true })
              .group(:id)
          }
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('complex')
      expect(scopes[0][:source]).to include('joins(:comments)')
      expect(scopes[0][:source]).to include('}')
    end

    it 'extracts scope with do/end style' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :block_style, -> do
            where(active: true)
          end
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('block_style')
      expect(scopes[0][:source]).to include('where(active: true)')
      expect(scopes[0][:source]).to include('end')
    end

    it 'extracts scope with nested blocks inside do/end' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :conditional, -> do
            if Rails.env.production?
              where(active: true)
            end
          end
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('conditional')
      expect(scopes[0][:source]).to include('if Rails.env.production?')
      expect(scopes[0][:source].scan('end').size).to eq(2) # inner if + outer do
    end

    it 'extracts scope with parameterized lambda' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :by_status, ->(status) { where(status: status) }
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('by_status')
    end

    it 'extracts multiple scopes' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :active, -> { where(active: true) }
          scope :recent, -> { where("created_at > ?", 1.week.ago) }
          scope :featured, -> { where(featured: true) }
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(3)
      expect(scopes.map { |s| s[:name] }).to eq(%w[active recent featured])
    end

    it 'handles scopes with strings containing braces' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :with_json, -> { where("data::jsonb @> '{}'::jsonb") }
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('with_json')
    end

    it 'handles scope with inline comment' do
      source = <<~RUBY
        class Post < ApplicationRecord
          scope :active, -> { where(active: true) } # only active posts
        end
      RUBY
      scopes = extractor.send(:extract_scopes, nil, source)
      expect(scopes.size).to eq(1)
      expect(scopes[0][:name]).to eq('active')
    end
  end

  # ── source_file_for ────────────────────────────────────────────────

  describe '#source_file_for' do
    let(:app_root) { '/app' }
    let(:rails_root) { Pathname.new(app_root) }

    before do
      stub_const('Rails', double('Rails', root: rails_root))
    end

    it 'returns instance method source location when in app root (tier 1)' do
      method_double = double('Method', source_location: ['/app/app/models/user.rb', 10])
      model = double('Model', name: 'User', instance_methods: [:foo], methods: [])
      allow(model).to receive(:instance_method).with(:foo).and_return(method_double)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/user.rb')
    end

    it 'falls back to class methods when no instance methods in app (tier 2)' do
      method_double = double('Method', source_location: ['/app/app/models/widget.rb', 5])
      model = double('Model', name: 'Widget', instance_methods: [], methods: [:my_scope])
      allow(model).to receive(:method).with(:my_scope).and_return(method_double)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/widget.rb')
    end

    it 'falls back to convention path when file exists (tier 3)' do
      model = double('Model', name: 'Order', instance_methods: [], methods: [])
      allow(File).to receive(:exist?).with('/app/app/models/order.rb').and_return(true)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/order.rb')
    end

    it 'falls back to const_source_location when available (tier 4)' do
      model = double('Model', name: 'Invoice', instance_methods: [], methods: [])
      allow(File).to receive(:exist?).with('/app/app/models/invoice.rb').and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(true)
      allow(Object).to receive(:const_source_location).with('Invoice').and_return(['/app/app/models/invoice.rb', 1])

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/invoice.rb')
    end

    it 'returns convention path as final fallback — never a gem path (tier 5)' do
      model = double('Model', name: 'Legacy', instance_methods: [], methods: [])
      allow(File).to receive(:exist?).with('/app/app/models/legacy.rb').and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/legacy.rb')
    end

    it 'skips instance method locations outside app root' do
      gem_method = double('Method', source_location: ['/gems/activerecord/base.rb', 1])
      model = double('Model', name: 'Thing', instance_methods: [:initialize], methods: [])
      allow(model).to receive(:instance_method).with(:initialize).and_return(gem_method)
      allow(File).to receive(:exist?).with('/app/app/models/thing.rb').and_return(true)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/thing.rb')
    end
  end

  # ── enrich_callbacks_with_side_effects ─────────────────────────────

  describe '#enrich_callbacks_with_side_effects' do
    it 'adds side_effects to callback metadata' do
      source = <<~RUBY
        class User < ApplicationRecord
          def normalize_email
            self.email = email.downcase
          end
        end
      RUBY

      unit = CodebaseIndex::ExtractedUnit.new(
        type: :model,
        identifier: 'User',
        file_path: 'app/models/user.rb'
      )
      unit.source_code = source
      unit.metadata = {
        callbacks: [{ type: :before_save, filter: 'normalize_email', kind: :before, conditions: {} }],
        column_names: %w[email name]
      }

      extractor.send(:enrich_callbacks_with_side_effects, unit, source)

      callback = unit.metadata[:callbacks].first
      expect(callback).to have_key(:side_effects)
      expect(callback[:side_effects][:columns_written]).to include('email')
    end

    it 'skips enrichment when source is nil' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [{ type: :before_save, filter: 'foo', kind: :before, conditions: {} }]
      }

      extractor.send(:enrich_callbacks_with_side_effects, unit, nil)

      callback = unit.metadata[:callbacks].first
      expect(callback).not_to have_key(:side_effects)
    end

    it 'skips enrichment when callbacks are empty' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.source_code = 'class User; end'
      unit.metadata = { callbacks: [], column_names: %w[email] }

      extractor.send(:enrich_callbacks_with_side_effects, unit, 'class User; end')

      expect(unit.metadata[:callbacks]).to eq([])
    end
  end

  # ── build_callbacks_chunk ──────────────────────────────────────────

  describe '#build_callbacks_chunk' do
    it 'includes side-effect annotations in chunk text' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [
          {
            type: :before_save, filter: 'normalize_email', kind: :before, conditions: {},
            side_effects: {
              columns_written: ['email'], jobs_enqueued: [], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          }
        ]
      }

      chunk = extractor.send(:build_callbacks_chunk, unit)
      expect(chunk).to include('normalize_email')
      expect(chunk).to include('writes: email')
    end

    it 'omits annotations when no side effects detected' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [
          {
            type: :before_save, filter: 'do_nothing', kind: :before, conditions: {},
            side_effects: {
              columns_written: [], jobs_enqueued: [], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          }
        ]
      }

      chunk = extractor.send(:build_callbacks_chunk, unit)
      expect(chunk).to include('do_nothing')
      expect(chunk).not_to include('[')
    end

    it 'handles callbacks without side_effects key gracefully' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [
          { type: :before_save, filter: 'legacy_callback', kind: :before, conditions: {} }
        ]
      }

      chunk = extractor.send(:build_callbacks_chunk, unit)
      expect(chunk).to include('legacy_callback')
    end
  end

  # ── format_callback_line ───────────────────────────────────────────

  describe '#format_callback_line' do
    it 'shows multiple side effect types' do
      callback = {
        filter: 'after_create_actions',
        side_effects: {
          columns_written: ['status'],
          jobs_enqueued: ['WelcomeJob'],
          services_called: ['AuditService'],
          mailers_triggered: ['UserMailer'],
          database_reads: ['where'],
          operations: []
        }
      }

      line = extractor.send(:format_callback_line, callback)
      expect(line).to include('writes: status')
      expect(line).to include('enqueues: WelcomeJob')
      expect(line).to include('calls: AuditService')
      expect(line).to include('mails: UserMailer')
      expect(line).to include('reads: where')
    end
  end

  # ── build_callback_effects_chunk ──────────────────────────────────

  describe '#build_callback_effects_chunk' do
    it 'groups callbacks by lifecycle phase with side-effect narrative' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'Order', file_path: 'app/models/order.rb')
      unit.metadata = {
        callbacks: [
          {
            type: :before_save, filter: 'calculate_total', kind: :before, conditions: {},
            side_effects: {
              columns_written: ['total_cents'], jobs_enqueued: [], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          },
          {
            type: :after_commit, filter: 'send_confirmation', kind: :after, conditions: {},
            side_effects: {
              columns_written: [], jobs_enqueued: ['ConfirmationJob'], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          }
        ]
      }

      chunk = extractor.send(:build_callback_effects_chunk, unit)
      expect(chunk).to include('Order - Callback Side Effects')
      expect(chunk).to include('Save Lifecycle')
      expect(chunk).to include('calculate_total')
      expect(chunk).to include('writes total_cents')
      expect(chunk).to include('After Commit')
      expect(chunk).to include('send_confirmation')
      expect(chunk).to include('enqueues ConfirmationJob')
    end

    it 'excludes callbacks with no side effects' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [
          {
            type: :before_save, filter: 'normalize_email', kind: :before, conditions: {},
            side_effects: {
              columns_written: ['email'], jobs_enqueued: [], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          },
          {
            type: :before_save, filter: 'no_effects', kind: :before, conditions: {},
            side_effects: {
              columns_written: [], jobs_enqueued: [], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          }
        ]
      }

      chunk = extractor.send(:build_callback_effects_chunk, unit)
      expect(chunk).to include('normalize_email')
      expect(chunk).not_to include('no_effects')
    end

    it 'returns empty string when no callbacks have side effects' do
      unit = CodebaseIndex::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [
          {
            type: :before_save, filter: 'no_effects', kind: :before, conditions: {},
            side_effects: {
              columns_written: [], jobs_enqueued: [], services_called: [],
              mailers_triggered: [], database_reads: [], operations: []
            }
          }
        ]
      }

      chunk = extractor.send(:build_callback_effects_chunk, unit)
      expect(chunk).to eq('')
    end
  end
end
