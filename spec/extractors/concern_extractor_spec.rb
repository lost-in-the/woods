# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/concern_extractor'

RSpec.describe CodebaseIndex::Extractors::ConcernExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers concern files in app/models/concerns/' do
      create_file('app/models/concerns/searchable.rb', <<~RUBY)
        module Searchable
          extend ActiveSupport::Concern

          included do
            scope :search, ->(query) { where('name LIKE ?', "%\#{query}%") }
          end

          def search_summary
            "Searchable: \#{self.class.name}"
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Searchable')
      expect(units.first.type).to eq(:concern)
    end

    it 'discovers concern files in app/controllers/concerns/' do
      create_file('app/controllers/concerns/authenticatable.rb', <<~RUBY)
        module Authenticatable
          extend ActiveSupport::Concern

          included do
            before_action :authenticate_user!
          end

          def current_user
            @current_user ||= User.find(session[:user_id])
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Authenticatable')
    end

    it 'discovers files in nested directories' do
      create_file('app/models/concerns/billing/invoiceable.rb', <<~RUBY)
        module Billing::Invoiceable
          extend ActiveSupport::Concern

          def generate_invoice
            InvoiceService.call(self)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Billing::Invoiceable')
      expect(units.first.namespace).to eq('Billing')
    end

    it 'skips files that are not concern modules' do
      create_file('app/models/concerns/empty.rb', <<~RUBY)
        # just a comment, no module
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'discovers plain mixin modules without ActiveSupport::Concern' do
      create_file('app/models/concerns/sluggable.rb', <<~RUBY)
        module Sluggable
          def self.included(base)
            base.before_save :generate_slug
          end

          def generate_slug
            self.slug = name.parameterize
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Sluggable')
    end
  end

  # ── extract_concern_file ───────────────────────────────────────────

  describe '#extract_concern_file' do
    it 'extracts ActiveSupport::Concern metadata' do
      path = create_file('app/models/concerns/searchable.rb', <<~RUBY)
        module Searchable
          extend ActiveSupport::Concern

          included do
            scope :search, ->(query) { where('name LIKE ?', "%\#{query}%") }
            validates :name, presence: true
          end

          class_methods do
            def find_by_search(query)
              search(query).first
            end
          end

          def search_summary
            "Searchable: \#{self.class.name}"
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:concern)
      expect(unit.identifier).to eq('Searchable')
      expect(unit.metadata[:concern_type]).to eq('active_support')
      expect(unit.metadata[:concern_scope]).to eq('model')
      expect(unit.metadata[:uses_active_support]).to be true
      expect(unit.metadata[:has_included_block]).to be true
      expect(unit.metadata[:has_class_methods_block]).to be true
      expect(unit.metadata[:instance_methods]).to include('search_summary')
      expect(unit.metadata[:scopes_defined]).to include('search')
      expect(unit.metadata[:validations_defined]).to include('validates')
    end

    it 'extracts plain mixin metadata' do
      path = create_file('app/models/concerns/sluggable.rb', <<~RUBY)
        module Sluggable
          def self.included(base)
            base.before_save :generate_slug
          end

          def generate_slug
            self.slug = name.parameterize
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:concern_type]).to eq('plain_mixin')
      expect(unit.metadata[:uses_active_support]).to be false
      expect(unit.metadata[:instance_methods]).to include('generate_slug')
    end

    it 'detects controller concern scope' do
      path = create_file('app/controllers/concerns/authenticatable.rb', <<~RUBY)
        module Authenticatable
          extend ActiveSupport::Concern

          def current_user
            @current_user
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      expect(unit.metadata[:concern_scope]).to eq('controller')
    end

    it 'detects included modules' do
      path = create_file('app/models/concerns/full_text_search.rb', <<~RUBY)
        module FullTextSearch
          extend ActiveSupport::Concern
          include Searchable
          include Sortable

          def full_search(query)
            search(query).sort_results
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      expect(unit.metadata[:included_modules]).to include('Searchable', 'Sortable')
    end

    it 'detects callbacks defined in concern' do
      path = create_file('app/models/concerns/auditable.rb', <<~RUBY)
        module Auditable
          extend ActiveSupport::Concern

          included do
            after_create :log_creation
            after_update :log_update
            before_destroy :log_destruction
          end

          def log_creation
            AuditLog.create(action: 'create')
          end

          def log_update
            AuditLog.create(action: 'update')
          end

          def log_destruction
            AuditLog.create(action: 'destroy')
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      expect(unit.metadata[:callbacks_defined]).to include('after_create', 'after_update', 'before_destroy')
    end

    it 'annotates source with header' do
      path = create_file('app/models/concerns/searchable.rb', <<~RUBY)
        module Searchable
          extend ActiveSupport::Concern

          def search_summary
            "summary"
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      expect(unit.source_code).to include('Concern: Searchable')
      expect(unit.source_code).to include('Type:')
      expect(unit.source_code).to include('Methods:')
    end

    it 'returns nil for non-concern files' do
      path = create_file('app/models/concerns/empty.rb', <<~RUBY)
        # just a comment
      RUBY

      unit = described_class.new.extract_concern_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_concern_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'counts lines of code excluding blanks and comments' do
      path = create_file('app/models/concerns/simple.rb', <<~RUBY)
        # A comment
        module Simple
          extend ActiveSupport::Concern

          # Another comment
          def foo
            bar
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      expect(unit.metadata[:loc]).to eq(6) # module, extend, blank lines excluded as comments/blanks
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_concern_file,
                    'app/models/concerns/auditable.rb',
                    <<~RUBY
                      module Auditable
                        extend ActiveSupport::Concern
                        include Trackable

                        def audit
                          AuditService.call(self)
                        end
                      end
                    RUBY

    it 'detects included concern dependencies' do
      path = create_file('app/models/concerns/full_text_search.rb', <<~RUBY)
        module FullTextSearch
          extend ActiveSupport::Concern
          include Searchable

          def full_search(query)
            search(query)
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      concern_deps = unit.dependencies.select { |d| d[:type] == :concern }
      expect(concern_deps.map { |d| d[:target] }).to include('Searchable')
      expect(concern_deps.first[:via]).to eq(:include)
    end

    it 'detects service dependencies' do
      path = create_file('app/models/concerns/billable.rb', <<~RUBY)
        module Billable
          extend ActiveSupport::Concern

          def charge
            BillingService.call(self)
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('BillingService')
      expect(service_deps.first[:via]).to eq(:code_reference)
    end

    it 'detects job dependencies' do
      path = create_file('app/models/concerns/async_processable.rb', <<~RUBY)
        module AsyncProcessable
          extend ActiveSupport::Concern

          def process_later
            ProcessingJob.perform_later(id)
          end
        end
      RUBY

      unit = described_class.new.extract_concern_file(path)
      job_deps = unit.dependencies.select { |d| d[:type] == :job }
      expect(job_deps.first[:target]).to eq('ProcessingJob')
    end
  end
end
