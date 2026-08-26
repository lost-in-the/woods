# frozen_string_literal: true

require 'spec_helper'
require 'active_support/core_ext/object/blank' # count_loc uses present?
require 'woods/extractors/model_extractor'

RSpec.describe Woods::Extractors::ModelExtractor do
  let(:extractor) { described_class.new }

  # Stub every callback-chain reader extract_callbacks and callback_count
  # ask a model for. Empty by default; individual examples override.
  def stub_callback_chains(model)
    %i[before_validation after_validation before_save after_save around_save
       before_create after_create around_create before_update after_update
       around_update before_destroy after_destroy around_destroy
       after_commit after_rollback after_initialize after_find after_touch
       validation save create update destroy commit rollback].each do |type|
      allow(model).to receive(:"_#{type}_callbacks").and_return([])
    end
  end

  # A minimally viable model double for extract_metadata / extract_model:
  # no table, no associations, no validators, empty callback chains.
  def stub_bare_model(name)
    model = double('Model', name: name)
    allow(model).to receive_messages(
      table_name: name.underscore.tr('/', '_'),
      primary_key: 'id',
      module_parent: Object,
      reflect_on_all_associations: [],
      _validators: {},
      inheritance_column: 'type',
      descends_from_active_record?: true,
      superclass: double('Superclass', name: 'ApplicationRecord'),
      singleton_class: double('SingletonClass', included_modules: []),
      table_exists?: false,
      instance_methods: []
    )
    stub_callback_chains(model)
    model
  end

  # Stub the extractor to see exactly one included concern with the given
  # name and source code (bypasses concern file discovery).
  def stub_inlined_concern(name, code)
    mod = Module.new
    allow(mod).to receive(:name).and_return(name)
    allow(extractor).to receive(:extract_included_modules).and_return([mod])
    allow(extractor).to receive(:concern_source).with(mod).and_return([name, code])
    mod
  end

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

  # ── callback_count ────────────────────────────────────────────────

  describe '#callback_count' do
    # Mirrors ActiveSupport::Callbacks::CallbackChain: it includes
    # Enumerable (so #count works) but defines NO #size. Stubbing with a
    # plain Array here would mask a regression to #size — Arrays have both.
    let(:chain_class) do
      Class.new do
        include Enumerable

        def initialize(callbacks)
          @callbacks = callbacks
        end

        def each(&block)
          @callbacks.each(&block)
        end
      end
    end

    it 'sums callbacks across chains using an API CallbackChain actually has' do
      model = double('Model')
      %i[validation save create update destroy commit rollback].each do |type|
        allow(model).to receive(:"_#{type}_callbacks").and_return(chain_class.new(%i[a b]))
      end

      expect(extractor.send(:callback_count, model)).to eq(14)
    end

    it 'counts a chain type as zero when reading it raises' do
      model = double('Model')
      %i[validation save create update destroy commit rollback].each do |type|
        allow(model).to receive(:"_#{type}_callbacks").and_return(chain_class.new([:a]))
      end
      allow(model).to receive(:_commit_callbacks).and_raise(NoMethodError)

      expect(extractor.send(:callback_count, model)).to eq(6)
    end
  end

  # ── implicit_belongs_to_validator? ────────────────────────────────

  describe '#implicit_belongs_to_validator?' do
    # A stand-in for ActiveRecord::Validations::PresenceValidator; is_a?
    # checks need a real class, not a double.
    let(:presence_validator_class) do
      Class.new do
        attr_reader :attributes

        def initialize(attributes)
          @attributes = attributes
        end
      end
    end

    before do
      stub_const('ActiveRecord::Validations::PresenceValidator', presence_validator_class)
    end

    def model_with_belongs_to(*names)
      reflections = names.map { |n| double('Reflection', name: n) }
      model = double('Model')
      allow(model).to receive(:reflect_on_all_associations).with(:belongs_to).and_return(reflections)
      model
    end

    it 'flags a presence validator on a belongs_to association attribute' do
      model = model_with_belongs_to(:author)
      validator = presence_validator_class.new([:author])

      expect(extractor.send(:implicit_belongs_to_validator?, model, validator)).to be true
    end

    it 'does not flag a presence validator on a plain attribute' do
      # The previous source_location heuristic flagged EVERY AR presence
      # validator — PresenceValidator#validate always lives in the gem.
      model = model_with_belongs_to(:author)
      validator = presence_validator_class.new([:title])

      expect(extractor.send(:implicit_belongs_to_validator?, model, validator)).to be false
    end

    it 'does not flag when the model has no belongs_to associations' do
      model = model_with_belongs_to
      validator = presence_validator_class.new([:title])

      expect(extractor.send(:implicit_belongs_to_validator?, model, validator)).to be false
    end

    it 'does not flag non-presence validators' do
      model = model_with_belongs_to(:author)
      other = double('FormatValidator')

      expect(extractor.send(:implicit_belongs_to_validator?, model, other)).to be false
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

    it 'returns convention path when file exists' do
      model = double('Model', name: 'Order')
      allow(File).to receive(:exist?).with('/app/app/models/order.rb').and_return(true)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/order.rb')
    end

    it 'falls back to resolve_source_location when convention path does not exist' do
      method_double = double('Method', source_location: ['/app/app/models/invoice.rb', 10])
      model = double('Model', name: 'Invoice', instance_methods: [:foo], methods: [])
      allow(model).to receive(:instance_method).with(:foo).and_return(method_double)
      allow(File).to receive(:exist?).with('/app/app/models/invoice.rb').and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/invoice.rb')
    end

    it 'returns convention path as final fallback — never a gem path' do
      model = double('Model', name: 'Legacy', instance_methods: [], methods: [])
      allow(File).to receive(:exist?).with('/app/app/models/legacy.rb').and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/legacy.rb')
    end

    it 'rejects vendor bundle paths that start with app_root' do
      vendor_path = '/app/vendor/bundle/ruby/3.3.0/gems/' \
                    'activerecord-7.0.8.7/lib/active_record/autosave_association.rb'
      vendor_method = double('Method', source_location: [vendor_path, 1])
      model = double('Model', name: 'VendorLeaky', instance_methods: [:save_associated], methods: [])
      allow(model).to receive(:instance_method).with(:save_associated).and_return(vendor_method)
      allow(File).to receive(:exist?).with('/app/app/models/vendor_leaky.rb').and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)

      result = extractor.send(:source_file_for, model)
      expect(result).to eq('/app/app/models/vendor_leaky.rb')
    end
  end

  # ── build_model_source_with_concerns ──────────────────────────────

  describe '#build_model_source_with_concerns' do
    let(:concern_code) do
      <<~RUBY
        module Trackable
          extend ActiveSupport::Concern

          included do
            before_save :set_slug
          end

          def set_slug
            self.slug = name.parameterize
          end
        end
      RUBY
    end

    it 'inlines the concern block after a compact-style namespaced class declaration' do
      stub_inlined_concern('Trackable', concern_code)
      model = double('Model', name: 'Admin::AuditLog')
      source = <<~RUBY
        class Admin::AuditLog < ApplicationRecord
          validates :action, presence: true
        end
      RUBY

      inlined, names = extractor.send(:build_model_source_with_concerns, model, source)

      expect(inlined).to include('Included from: Trackable')
      expect(inlined).to include('before_save :set_slug')
      expect(inlined.index('class Admin::AuditLog')).to be < inlined.index('Included from: Trackable')
      expect(names).to eq(['Trackable'])
      expect(extractor.warnings).to be_empty
    end

    it 'inserts after the model class line, not an earlier class sharing the name prefix' do
      stub_inlined_concern('Trackable', concern_code)
      model = double('Model', name: 'Book')
      source = <<~RUBY
        class BookmarkError < StandardError
        end

        class Book < ApplicationRecord
        end
      RUBY

      inlined, = extractor.send(:build_model_source_with_concerns, model, source)

      expect(inlined.index('Included from: Trackable')).to be > inlined.index('class Book < ApplicationRecord')
      # BookmarkError's declaration must be left untouched
      expect(inlined).to include("class BookmarkError < StandardError\nend")
    end

    it 'appends the concern block with a warning when no class declaration matches' do
      stub_inlined_concern('Trackable', concern_code)
      model = double('Model', name: 'Ledger')
      source = <<~RUBY
        Ledger = Class.new(ApplicationRecord) do
          validates :entry, presence: true
        end
      RUBY

      inlined, names = extractor.send(:build_model_source_with_concerns, model, source)

      expect(inlined).to include('Included from: Trackable')
      expect(inlined.index('Included from: Trackable')).to be > inlined.index('Ledger = Class.new')
      expect(names).to eq(['Trackable'])
      expect(extractor.warnings.size).to eq(1)
      expect(extractor.warnings.first).to include('Ledger')
    end

    it 'returns the source untouched with no inlined names when no concern resolves' do
      allow(extractor).to receive(:extract_included_modules).and_return([])
      model = double('Model', name: 'Plain')
      source = "class Plain < ApplicationRecord\nend\n"

      expect(extractor.send(:build_model_source_with_concerns, model, source)).to eq([source, []])
    end
  end

  # ── extract_metadata — inlined_concerns truthfulness ──────────────

  describe '#extract_metadata (inlined_concerns)' do
    it 'does not claim concerns were inlined when the model source cannot be read' do
      model = stub_bare_model('Admin::AuditLog')
      stub_inlined_concern('Trackable', "module Trackable\nend\n")
      allow(extractor).to receive(:source_file_for).and_return(nil)

      metadata = extractor.send(:extract_metadata, model, nil)

      expect(metadata[:inlined_concerns]).to eq([])
    end

    it 'lists the concerns actually inlined when source is present' do
      model = stub_bare_model('Admin::AuditLog')
      stub_inlined_concern('Trackable', "module Trackable\nend\n")
      source = <<~RUBY
        class Admin::AuditLog < ApplicationRecord
        end
      RUBY

      metadata = extractor.send(:extract_metadata, model, source)

      expect(metadata[:inlined_concerns]).to eq(['Trackable'])
    end
  end

  # ── extract_model — concern inlining end to end ───────────────────

  describe '#extract_model (concern-defined callbacks)' do
    let(:model_path) { '/app/app/models/audit_log.rb' }

    let(:model_source) do
      <<~RUBY
        class AuditLog < ApplicationRecord
        end
      RUBY
    end

    let(:concern_code) do
      <<~RUBY
        module Trackable
          extend ActiveSupport::Concern

          included do
            before_save :set_slug
          end

          def set_slug
            self.slug = name.parameterize
            SlugJob.perform_later(id)
          end
        end
      RUBY
    end

    before do
      stub_const('Rails', double('Rails', root: Pathname.new('/app'), logger: double('Logger').as_null_object))
    end

    it 'enriches a concern-defined callback with side effects while keeping the commented display block' do
      model = stub_bare_model('AuditLog')
      column = double('Column', name: 'slug', type: :string, sql_type: 'varchar(255)',
                                limit: nil, null: true, default: nil)
      allow(model).to receive_messages(table_exists?: true, columns: [column], column_names: %w[slug])
      callback = double('Callback', filter: :set_slug, kind: :before)
      allow(model).to receive(:_before_save_callbacks).and_return([callback])
      stub_inlined_concern('Trackable', concern_code)
      allow(extractor).to receive(:source_file_for).and_return(model_path)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(model_path).and_return(true)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(model_path).and_return(model_source)

      unit = extractor.send(:extract_model, model)

      expect(extractor.warnings).to be_empty
      expect(unit).not_to be_nil

      # Display composite keeps the deliberate commented presentation
      expect(unit.source_code).to include('Included from: Trackable')
      expect(unit.source_code).to include('  # module Trackable')

      # Metadata reflects what was actually inlined
      expect(unit.metadata[:inlined_concerns]).to eq(['Trackable'])

      # The concern-defined callback method is visible to the analyzer
      enriched = unit.metadata[:callbacks].find { |cb| cb[:filter] == 'set_slug' }
      expect(enriched[:side_effects][:columns_written]).to include('slug')
      expect(enriched[:side_effects][:jobs_enqueued]).to include('SlugJob')
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

      unit = Woods::ExtractedUnit.new(
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

    it 'analyzes concern-defined callback methods via the parse-friendly analysis source' do
      model_source = <<~RUBY
        class User < ApplicationRecord
        end
      RUBY
      concern_source = <<~RUBY
        module Sluggable
          included do
            before_save :set_slug
          end

          def set_slug
            self.slug = name.parameterize
            SlugJob.perform_later(id)
          end
        end
      RUBY

      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      # The display composite carries the concern only as comment lines —
      # deliberately — so it must NOT be what the analyzer parses.
      unit.source_code = model_source + concern_source.lines.map { |l| "  # #{l.rstrip}" }.join("\n")
      unit.metadata = {
        callbacks: [{ type: :before_save, filter: 'set_slug', kind: :before, conditions: {} }],
        column_names: %w[slug name]
      }

      extractor.send(:enrich_callbacks_with_side_effects, unit, model_source,
                     analysis_source: "#{model_source}\n#{concern_source}")

      callback = unit.metadata[:callbacks].first
      expect(callback[:side_effects][:columns_written]).to include('slug')
      expect(callback[:side_effects][:jobs_enqueued]).to include('SlugJob')
    end

    it 'skips enrichment when source is nil' do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.metadata = {
        callbacks: [{ type: :before_save, filter: 'foo', kind: :before, conditions: {} }]
      }

      extractor.send(:enrich_callbacks_with_side_effects, unit, nil)

      callback = unit.metadata[:callbacks].first
      expect(callback).not_to have_key(:side_effects)
    end

    it 'skips enrichment when callbacks are empty' do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.source_code = 'class User; end'
      unit.metadata = { callbacks: [], column_names: %w[email] }

      extractor.send(:enrich_callbacks_with_side_effects, unit, 'class User; end')

      expect(unit.metadata[:callbacks]).to eq([])
    end
  end

  # ── build_callbacks_chunk ──────────────────────────────────────────

  describe '#build_callbacks_chunk' do
    it 'includes side-effect annotations in chunk text' do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
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
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
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
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
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

  # ── extract_active_storage_attachments ────────────────────────────

  describe '#extract_active_storage_attachments' do
    it 'extracts has_one_attached declarations' do
      source = <<~RUBY
        class User < ApplicationRecord
          has_one_attached :avatar
        end
      RUBY

      attachments = extractor.send(:extract_active_storage_attachments, source)
      expect(attachments).to include(hash_including(name: 'avatar', type: :has_one_attached))
    end

    it 'extracts has_many_attached declarations' do
      source = <<~RUBY
        class Post < ApplicationRecord
          has_many_attached :images
        end
      RUBY

      attachments = extractor.send(:extract_active_storage_attachments, source)
      expect(attachments).to include(hash_including(name: 'images', type: :has_many_attached))
    end

    it 'extracts multiple attachments of mixed types' do
      source = <<~RUBY
        class Document < ApplicationRecord
          has_one_attached :cover
          has_many_attached :pages
        end
      RUBY

      attachments = extractor.send(:extract_active_storage_attachments, source)
      names = attachments.map { |a| a[:name] }
      expect(names).to include('cover', 'pages')
    end

    it 'returns empty array when no attachments are present' do
      source = <<~RUBY
        class Plain < ApplicationRecord
          validates :name, presence: true
        end
      RUBY

      attachments = extractor.send(:extract_active_storage_attachments, source)
      expect(attachments).to eq([])
    end

    it 'returns empty array when source is nil' do
      expect(extractor.send(:extract_active_storage_attachments, nil)).to eq([])
    end
  end

  # ── extract_action_text_fields ────────────────────────────────────

  describe '#extract_action_text_fields' do
    it 'extracts has_rich_text declarations' do
      source = <<~RUBY
        class Post < ApplicationRecord
          has_rich_text :content
        end
      RUBY

      fields = extractor.send(:extract_action_text_fields, source)
      expect(fields).to include('content')
    end

    it 'extracts multiple has_rich_text declarations' do
      source = <<~RUBY
        class Article < ApplicationRecord
          has_rich_text :body
          has_rich_text :summary
        end
      RUBY

      fields = extractor.send(:extract_action_text_fields, source)
      expect(fields).to include('body', 'summary')
    end

    it 'returns empty array when no rich text fields are present' do
      source = <<~RUBY
        class Plain < ApplicationRecord
          validates :name, presence: true
        end
      RUBY

      fields = extractor.send(:extract_action_text_fields, source)
      expect(fields).to eq([])
    end

    it 'returns empty array when source is nil' do
      expect(extractor.send(:extract_action_text_fields, nil)).to eq([])
    end
  end

  # ── extract_variant_definitions ───────────────────────────────────

  describe '#extract_variant_definitions' do
    it 'extracts variant definitions' do
      source = <<~RUBY
        class User < ApplicationRecord
          has_one_attached :avatar do |attachable|
            attachable.variant :thumb, resize_to_limit: [100, 100]
          end
        end
      RUBY

      variants = extractor.send(:extract_variant_definitions, source)
      expect(variants).to include(hash_including(name: 'thumb'))
    end

    it 'returns empty array when no variants are defined' do
      source = <<~RUBY
        class Plain < ApplicationRecord
          has_one_attached :avatar
        end
      RUBY

      variants = extractor.send(:extract_variant_definitions, source)
      expect(variants).to eq([])
    end

    it 'returns empty array when source is nil' do
      expect(extractor.send(:extract_variant_definitions, nil)).to eq([])
    end
  end

  # ── extract_database_roles ────────────────────────────────────────

  describe '#extract_database_roles' do
    it 'extracts connects_to database roles' do
      source = <<~RUBY
        class AnimalsBase < ApplicationRecord
          self.abstract_class = true
          connects_to database: { writing: :primary, reading: :replica }
        end
      RUBY

      roles = extractor.send(:extract_database_roles, source)
      expect(roles).to eq({ writing: :primary, reading: :replica })
    end

    it 'returns nil when connects_to is not present' do
      source = <<~RUBY
        class User < ApplicationRecord
          validates :name, presence: true
        end
      RUBY

      roles = extractor.send(:extract_database_roles, source)
      expect(roles).to be_nil
    end

    it 'returns nil when source is nil' do
      expect(extractor.send(:extract_database_roles, nil)).to be_nil
    end
  end

  # ── extract_shard_config ──────────────────────────────────────────

  describe '#extract_shard_config' do
    it 'extracts connects_to shard configuration' do
      source = <<~RUBY
        class ShardedBase < ApplicationRecord
          self.abstract_class = true
          connects_to shards: { shard_one: { writing: :shard_one }, shard_two: { writing: :shard_two } }
        end
      RUBY

      shards = extractor.send(:extract_shard_config, source)
      expect(shards).to have_key(:shard_one)
      expect(shards[:shard_one]).to eq({ writing: :shard_one })
    end

    it 'returns nil when no shard config is present' do
      source = <<~RUBY
        class User < ApplicationRecord
          validates :name, presence: true
        end
      RUBY

      shards = extractor.send(:extract_shard_config, source)
      expect(shards).to be_nil
    end

    it 'returns nil when source is nil' do
      expect(extractor.send(:extract_shard_config, nil)).to be_nil
    end
  end

  # ── extract_dependencies (concern tracking) ───────────────────────

  describe '#extract_dependencies (concern via labels)' do
    let(:app_root) { '/app' }
    let(:rails_root) { Pathname.new(app_root) }

    before do
      stub_const('Rails', double('Rails', root: rails_root, logger: double(error: nil)))
    end

    it 'gives included concerns via: :include' do
      included_mod = Module.new
      allow(included_mod).to receive(:name).and_return('Concerns::Searchable')

      model = double('Model',
                     name: 'Post',
                     module_parent: Object,
                     reflect_on_all_associations: [],
                     included_modules: [included_mod],
                     singleton_class: double('SC', included_modules: []))

      allow(extractor).to receive(:app_source?).and_return(true)
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(extractor).to receive(:defined_in_app?).and_return(true)
      allow(extractor).to receive(:source_file_for).and_return(nil)

      deps = extractor.send(:extract_dependencies, model, nil)
      include_dep = deps.find { |d| d[:target] == 'Concerns::Searchable' }
      expect(include_dep).not_to be_nil
      expect(include_dep[:via]).to eq(:include)
      expect(include_dep[:type]).to eq(:concern)
    end

    it 'gives extended concerns via: :extend' do
      extended_mod = Module.new
      allow(extended_mod).to receive(:name).and_return('Concerns::ClassMethods')

      builtin_sc = double('Object SC', included_modules: [])
      singleton_class_double = double('SC', included_modules: [extended_mod])

      model = double('Model',
                     name: 'Post',
                     module_parent: Object,
                     reflect_on_all_associations: [],
                     included_modules: [],
                     singleton_class: singleton_class_double)

      allow(Object).to receive(:singleton_class).and_return(builtin_sc)
      allow(extractor).to receive(:app_source?).and_return(true)
      allow(Object).to receive(:respond_to?).with(:const_source_location).and_return(false)
      allow(Object).to receive(:respond_to?).and_call_original
      allow(extractor).to receive(:defined_in_app?).and_return(true)
      allow(extractor).to receive(:source_file_for).and_return(nil)

      deps = extractor.send(:extract_dependencies, model, nil)
      extend_dep = deps.find { |d| d[:target] == 'Concerns::ClassMethods' }
      expect(extend_dep).not_to be_nil
      expect(extend_dep[:via]).to eq(:extend)
      expect(extend_dep[:type]).to eq(:concern)
    end

    it 'does not leak Ruby builtin modules (e.g., Kernel, PP) as extend deps' do
      kernel_mod = Kernel
      singleton_class_double = double('SC', included_modules: [kernel_mod])

      model = double('Model',
                     name: 'Post',
                     module_parent: Object,
                     reflect_on_all_associations: [],
                     included_modules: [],
                     singleton_class: singleton_class_double)

      allow(extractor).to receive(:source_file_for).and_return(nil)

      deps = extractor.send(:extract_dependencies, model, nil)
      kernel_dep = deps.find { |d| d[:target] == 'Kernel' }
      expect(kernel_dep).to be_nil
    end
  end

  # ── extract_dependencies (association edges) ──────────────────────

  describe '#extract_dependencies (association edges)' do
    before do
      stub_const('Rails', double('Rails', root: Pathname.new('/app'), logger: double(error: nil)))
    end

    # A model double with exactly the surface extract_dependencies touches
    # when no source is resolvable: associations plus empty module lists.
    def model_with_associations(*assocs)
      model = double('Model',
                     name: 'Comment',
                     module_parent: Object,
                     reflect_on_all_associations: assocs,
                     included_modules: [],
                     singleton_class: double('SC', included_modules: []))
      allow(extractor).to receive(:source_file_for).and_return(nil)
      model
    end

    it 'labels a polymorphic belongs_to as :polymorphic_interface, never as a :belongs_to model edge' do
      # AssociationReflection#class_name camelizes without constantizing, so
      # a polymorphic belongs_to yields an interface name ("Commentable"),
      # not a model — the NameError rescue never fires (#199).
      poly = double('Assoc(commentable)', name: :commentable, macro: :belongs_to,
                                          class_name: 'Commentable', polymorphic?: true)

      deps = extractor.send(:extract_dependencies, model_with_associations(poly), nil)

      commentable_edges = deps.select { |d| d[:target] == 'Commentable' }
      expect(commentable_edges).to contain_exactly(
        { type: :model, target: 'Commentable', via: :polymorphic_interface }
      )
    end

    it 'keeps the macro via label for a normal belongs_to' do
      normal = double('Assoc(author)', name: :author, macro: :belongs_to,
                                       class_name: 'User', polymorphic?: false)

      deps = extractor.send(:extract_dependencies, model_with_associations(normal), nil)

      expect(deps).to include({ type: :model, target: 'User', via: :belongs_to })
      expect(deps.map { |d| d[:via] }).not_to include(:polymorphic_interface)
    end

    it 'distinguishes polymorphic and normal associations on the same model' do
      poly = double('Assoc(commentable)', name: :commentable, macro: :belongs_to,
                                          class_name: 'Commentable', polymorphic?: true)
      normal = double('Assoc(author)', name: :author, macro: :belongs_to,
                                       class_name: 'User', polymorphic?: false)

      deps = extractor.send(:extract_dependencies, model_with_associations(poly, normal), nil)

      expect(deps).to include({ type: :model, target: 'Commentable', via: :polymorphic_interface })
      expect(deps).to include({ type: :model, target: 'User', via: :belongs_to })
    end

    it 'treats a reflection that lacks #polymorphic? as a plain association' do
      # Plain RSpec doubles answer respond_to?(:polymorphic?) with false
      # when the method is not stubbed — exercising the respond_to? guard.
      habtm = double('Assoc(tags)', name: :tags, macro: :has_and_belongs_to_many, class_name: 'Tag')

      deps = extractor.send(:extract_dependencies, model_with_associations(habtm), nil)

      expect(deps).to include({ type: :model, target: 'Tag', via: :has_and_belongs_to_many })
    end
  end

  # ── build_callback_effects_chunk ──────────────────────────────────

  describe '#build_callback_effects_chunk' do
    it 'groups callbacks by lifecycle phase with side-effect narrative' do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Order', file_path: 'app/models/order.rb')
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
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
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
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
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

  # ── extract_associations — error resilience ───────────────────────

  describe '#extract_associations' do
    let(:model) { double('Model', name: 'Post') }

    # rubocop:disable-next Metrics/AbcSize
    def make_assoc(name, class_name: name.to_s.classify)
      a = double("Assoc(#{name})")
      allow(a).to receive(:name).and_return(name)
      allow(a).to receive(:macro).and_return(:has_many)
      allow(a).to receive(:class_name).and_return(class_name)
      allow(a).to receive(:options).and_return({})
      allow(a).to receive(:polymorphic?).and_return(false)
      allow(a).to receive(:foreign_key).and_return("#{name}_id")
      allow(a).to receive(:inverse_of).and_return(nil)
      a
    end

    it 'skips a broken association and returns the rest' do
      good1 = make_assoc(:comments)
      broken = make_assoc(:tags)
      good2 = make_assoc(:likes)

      allow(broken).to receive(:class_name).and_raise(NameError, 'uninitialized constant Tags')
      allow(model).to receive(:reflect_on_all_associations).and_return([good1, broken, good2])

      results = extractor.send(:extract_associations, model)

      expect(results.size).to eq(2)
      expect(results.map { |a| a[:name] }).to eq(%i[comments likes])
    end

    it 'records a warning for each skipped association' do
      broken = make_assoc(:gadgets)
      allow(broken).to receive(:class_name).and_raise(NameError, 'uninitialized constant Gadgets')
      allow(model).to receive(:reflect_on_all_associations).and_return([broken])

      extractor.send(:extract_associations, model)

      expect(extractor.warnings.size).to eq(1)
      expect(extractor.warnings.first).to include('Post')
      expect(extractor.warnings.first).to include('gadgets')
    end
  end

  # ── warnings ─────────────────────────────────────────────────────

  describe '#warnings' do
    it 'is empty by default' do
      expect(extractor.warnings).to eq([])
    end

    it 'records a warning when extract_model fails' do
      stub_const('Rails', double('Rails'))
      allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)

      model = double('Model', name: 'BrokenModel')
      allow(extractor).to receive(:source_file_for).and_raise(StandardError, 'bad path')

      extractor.send(:extract_model, model)

      expect(extractor.warnings.size).to eq(1)
      expect(extractor.warnings.first).to include('BrokenModel')
    end
  end
end
