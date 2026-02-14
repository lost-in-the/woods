# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'codebase_index/extractors/rails_source_extractor'

RSpec.describe CodebaseIndex::Extractors::RailsSourceExtractor do
  include_context 'extractor setup'

  before do
    stub_const('Rails', double('Rails', version: '7.1.3', logger: logger, root: rails_root))

    # Default: all gems are missing
    allow(Gem::Specification).to receive(:find_by_name).and_raise(Gem::MissingSpecError.new('test', 'test'))
  end

  # Helper to create a mock gem spec pointing to tmp_dir
  def stub_gem(gem_name, version: '7.1.3')
    gem_spec = double("GemSpec:#{gem_name}",
                      gem_dir: tmp_dir,
                      version: double(to_s: version))
    allow(Gem::Specification).to receive(:find_by_name).with(gem_name).and_return(gem_spec)
    gem_spec
  end

  # ── extract_all ───────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'returns empty array when no gems are installed' do
      units = described_class.new.extract_all
      expect(units).to eq([])
    end

    it 'combines rails and gem sources' do
      stub_gem('activerecord')
      create_file('lib/active_record/callbacks.rb', <<~RUBY)
        module ActiveRecord
          module Callbacks
            def before_save
            end
          end
        end
      RUBY

      stub_gem('devise', version: '4.9.3')
      create_file('lib/devise/models', '')
      # devise paths won't match files, so only activerecord contributes

      units = described_class.new.extract_all
      expect(units.any? { |u| u.type == :rails_source }).to be true
    end
  end

  # ── extract_rails_sources ─────────────────────────────────────────────

  describe '#extract_rails_sources' do
    it 'extracts framework files from gem paths' do
      stub_gem('activerecord')

      create_file('lib/active_record/callbacks.rb', <<~RUBY)
        module ActiveRecord
          module Callbacks
            def before_save
            end

            def after_save
            end
          end
        end
      RUBY

      units = described_class.new.extract_rails_sources

      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:rails_source)
      expect(units.first.identifier).to include('activerecord')
      expect(units.first.identifier).to include('callbacks.rb')
    end

    it 'extracts files from directories' do
      stub_gem('activerecord')

      create_file('lib/active_record/associations/has_many.rb', <<~RUBY)
        module ActiveRecord
          module Associations
            class HasManyAssociation
              def reader
              end
            end
          end
        end
      RUBY

      create_file('lib/active_record/associations/belongs_to.rb', <<~RUBY)
        module ActiveRecord
          module Associations
            class BelongsToAssociation
              def writer
              end
            end
          end
        end
      RUBY

      units = described_class.new.extract_rails_sources

      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers.any? { |id| id.include?('has_many') }).to be true
      expect(identifiers.any? { |id| id.include?('belongs_to') }).to be true
    end

    it 'skips missing gems gracefully' do
      # activerecord not stubbed — will raise Gem::MissingSpecError
      units = described_class.new.extract_rails_sources
      expect(units).to eq([])
    end

    it 'extracts from multiple gem components' do
      stub_gem('activerecord')
      create_file('lib/active_record/callbacks.rb', "module ActiveRecord\n  module Callbacks\n  end\nend\n")

      stub_gem('activesupport')
      create_file('lib/active_support/callbacks.rb', "module ActiveSupport\n  module Callbacks\n  end\nend\n")

      units = described_class.new.extract_rails_sources

      components = units.map { |u| u.metadata[:component] }.uniq
      expect(components).to include('activerecord', 'activesupport')
    end
  end

  # ── extract_gem_sources ───────────────────────────────────────────────

  describe '#extract_gem_sources' do
    it 'extracts gem source files' do
      stub_gem('devise', version: '4.9.3')

      create_file('lib/devise/models/authenticatable.rb', <<~RUBY)
        module Devise
          module Models
            module Authenticatable
              def self.included(base)
                base.extend ClassMethods
              end

              module ClassMethods
                def find_for_authentication(conditions)
                end
              end
            end
          end
        end
      RUBY

      units = described_class.new.extract_gem_sources

      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:gem_source)
      expect(units.first.identifier).to include('devise')
      expect(units.first.metadata[:gem_name]).to eq('devise')
      expect(units.first.metadata[:gem_version]).to eq('4.9.3')
      expect(units.first.metadata[:priority]).to eq(:high)
    end

    it 'skips gems that are not installed' do
      # No gems stubbed
      units = described_class.new.extract_gem_sources
      expect(units).to eq([])
    end

    it 'extracts mixins from gem source' do
      stub_gem('devise', version: '4.9.3')

      create_file('lib/devise/models/authenticatable.rb', <<~RUBY)
        module Authenticatable
          def self.included(base)
            base.extend ClassMethods
          end
        end
      RUBY

      units = described_class.new.extract_gem_sources

      expect(units.first.metadata[:mixins_provided]).to include('Authenticatable')
    end

    it 'extracts configuration options from gem source' do
      stub_gem('sidekiq', version: '7.2.0')

      create_file('lib/sidekiq/worker.rb', <<~RUBY)
        module Sidekiq
          module Worker
            mattr_accessor :default_retries
            mattr_accessor :default_queue

            config.concurrency = 10
          end
        end
      RUBY

      units = described_class.new.extract_gem_sources

      configs = units.first.metadata[:configuration_options]
      expect(configs).to include('default_retries', 'default_queue', 'concurrency')
    end
  end

  # ── extract_framework_file ────────────────────────────────────────────

  describe '#extract_framework_file' do
    let(:extractor) { described_class.new }

    it 'creates a rails_source unit with correct metadata' do
      source = <<~RUBY
        module ActiveRecord
          module Callbacks
            # Options:
            # - :on - specify events

            VALID_CALLBACKS = [:before_save, :after_save, :around_save]

            def before_save
            end

            def after_save
            end

            private

            def _run_callbacks
            end
          end
        end
      RUBY

      path = create_file('lib/active_record/callbacks.rb', source)

      # Simulate gem path structure
      stub_gem('activerecord')

      unit = extractor.send(:extract_framework_file, 'activerecord', path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:rails_source)
      expect(unit.metadata[:rails_version]).to eq('7.1.3')
      expect(unit.metadata[:component]).to eq('activerecord')
    end

    it 'extracts public methods (stops at private)' do
      source = <<~RUBY
        module ActiveRecord
          module Callbacks
            def before_save
            end

            def after_save
            end

            private

            def _internal_method
            end
          end
        end
      RUBY

      path = create_file('lib/active_record/callbacks.rb', source)
      stub_gem('activerecord')

      unit = extractor.send(:extract_framework_file, 'activerecord', path)

      public_method_names = unit.metadata[:public_methods].map { |m| m[:name] }
      expect(public_method_names).to include('before_save', 'after_save')
      expect(public_method_names).not_to include('_internal_method')
    end

    it 'annotates source with framework header' do
      source = "module ActiveRecord\nend\n"
      path = create_file('lib/active_record/callbacks.rb', source)
      stub_gem('activerecord')

      unit = extractor.send(:extract_framework_file, 'activerecord', path)

      expect(unit.source_code).to include('Rails 7.1.3')
      expect(unit.source_code).to include('activerecord')
    end

    it 'extracts module and class names' do
      source = <<~RUBY
        module ActiveRecord
          class Base
            module ClassMethods
            end
          end
        end
      RUBY

      path = create_file('lib/active_record/base.rb', source)
      stub_gem('activerecord')

      unit = extractor.send(:extract_framework_file, 'activerecord', path)

      expect(unit.metadata[:defined_modules]).to include('ActiveRecord')
      expect(unit.metadata[:defined_classes]).to include('Base')
    end

    it 'handles errors gracefully' do
      unit = extractor.send(:extract_framework_file, 'activerecord', '/nonexistent/path.rb')
      expect(unit).to be_nil
    end
  end

  # ── public_api_file? ──────────────────────────────────────────────────

  describe '#public_api_file?' do
    let(:extractor) { described_class.new }

    it 'identifies associations/builder as public API' do
      expect(extractor.send(:public_api_file?, 'lib/active_record/associations/builder/has_many.rb')).to be true
    end

    it 'identifies callbacks.rb as public API' do
      expect(extractor.send(:public_api_file?, 'lib/active_record/callbacks.rb')).to be true
    end

    it 'identifies validations.rb as public API' do
      expect(extractor.send(:public_api_file?, 'lib/active_record/validations.rb')).to be true
    end

    it 'identifies base.rb as public API' do
      expect(extractor.send(:public_api_file?, 'lib/active_record/base.rb')).to be true
    end

    it 'identifies metal/ files as public API' do
      expect(extractor.send(:public_api_file?, 'lib/action_controller/metal/params_wrapper.rb')).to be true
    end

    it 'rejects non-public-API files' do
      expect(extractor.send(:public_api_file?, 'lib/active_record/connection_adapters/mysql.rb')).to be false
    end
  end

  # ── rate_importance ───────────────────────────────────────────────────

  describe '#rate_importance' do
    let(:extractor) { described_class.new }

    it 'rates high for associations files with many methods and DSL' do
      source = <<~RUBY
        module ActiveRecord
          module Associations
            def self.has_many(name) # DSL method
            end

            def self.belongs_to(name) # DSL method
            end

            #{(1..12).map { |i| "def method_#{i}\nend" }.join("\n")}
          end
        end
      RUBY

      result = extractor.send(:rate_importance, 'lib/active_record/associations.rb', source)
      expect(result).to eq(:high)
    end

    it 'rates low for internal files with few methods' do
      source = <<~RUBY
        module ActiveRecord
          class InternalHelper
            def helper
            end
          end
        end
      RUBY

      result = extractor.send(:rate_importance, 'lib/active_record/internal_helper.rb', source)
      expect(result).to eq(:low)
    end

    it 'rates medium for files with many public methods and options docs' do
      methods = (1..12).map { |i| "def method_#{i}\nend" }.join("\n")
      source = "module Foo\n# Options:\n#{methods}\nend\n"

      result = extractor.send(:rate_importance, 'lib/some_gem/utilities.rb', source)
      expect(result).to eq(:medium)
    end
  end

  # ── extract_public_api ────────────────────────────────────────────────

  describe '#extract_public_api' do
    let(:extractor) { described_class.new }

    it 'tracks visibility transitions' do
      source = <<~RUBY
        module Foo
          def public_method
          end

          def self.class_method
          end

          private

          def private_method
          end

          public

          def back_to_public
          end
        end
      RUBY

      methods = extractor.send(:extract_public_api, source)
      names = methods.map { |m| m[:name] }

      expect(names).to include('public_method', 'self.class_method', 'back_to_public')
      expect(names).not_to include('private_method')
    end

    it 'skips underscore-prefixed methods' do
      source = <<~RUBY
        module Foo
          def public_method
          end

          def _internal
          end
        end
      RUBY

      methods = extractor.send(:extract_public_api, source)
      names = methods.map { |m| m[:name] }

      expect(names).to include('public_method')
      expect(names).not_to include('_internal')
    end

    it 'identifies class methods' do
      source = <<~RUBY
        module Foo
          def self.create
          end
        end
      RUBY

      methods = extractor.send(:extract_public_api, source)
      class_method = methods.find { |m| m[:name] == 'self.create' }

      expect(class_method[:class_method]).to be true
    end

    it 'captures method signatures' do
      source = <<~RUBY
        module Foo
          def find(id)
          end
        end
      RUBY

      methods = extractor.send(:extract_public_api, source)
      find = methods.find { |m| m[:name] == 'find' }

      expect(find[:signature]).to eq('(id)')
    end
  end

  # ── extract_dsl_methods ───────────────────────────────────────────────

  describe '#extract_dsl_methods' do
    let(:extractor) { described_class.new }

    it 'detects self.method with DSL comment' do
      source = <<~RUBY
        module ActiveRecord
          def self.has_many(name) # DSL method
          end
        end
      RUBY

      dsl = extractor.send(:extract_dsl_methods, source)
      expect(dsl).to include('has_many')
    end

    it 'detects call-seq documented methods' do
      source = <<~RUBY
        module ActiveRecord
          def find(id) # :call-seq:
          end
        end
      RUBY

      dsl = extractor.send(:extract_dsl_methods, source)
      expect(dsl).to include('find')
    end
  end

  # ── extract_option_definitions ────────────────────────────────────────

  describe '#extract_option_definitions' do
    let(:extractor) { described_class.new }

    it 'finds VALID_OPTIONS constants' do
      source = <<~RUBY
        VALID_CALLBACKS = [:before_save, :after_save, :around_save]
      RUBY

      options = extractor.send(:extract_option_definitions, source)

      const_opt = options.find { |o| o[:constant] == 'VALID_CALLBACKS' }
      expect(const_opt).not_to be_nil
      expect(const_opt[:values]).to include('before_save', 'after_save', 'around_save')
    end

    it 'finds documented options in comments' do
      source = <<~RUBY
        # dependent - What to do with associated objects
        # class_name - Override the class name
      RUBY

      options = extractor.send(:extract_option_definitions, source)
      names = options.map { |o| o[:name] }

      expect(names).to include('dependent', 'class_name')
    end
  end

  # ── Source annotation ─────────────────────────────────────────────────

  describe 'source annotation' do
    let(:extractor) { described_class.new }

    it 'annotates gem source with gem name and version' do
      stub_gem('pundit', version: '2.3.1')

      source = "module Pundit\nend\n"
      create_file('lib/pundit.rb', source)

      units = described_class.new.extract_gem_sources
      pundit_units = units.select { |u| u.metadata[:gem_name] == 'pundit' }

      expect(pundit_units).not_to be_empty
      expect(pundit_units.first.source_code).to include('Gem: pundit')
      expect(pundit_units.first.source_code).to include('v2.3.1')
    end
  end
end
