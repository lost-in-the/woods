# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/migration_extractor'

RSpec.describe 'Migration declaration identity' do
  include_context 'extractor setup'

  def migration(name, source)
    path = create_file("db/migrate/20260101000000_#{name}.rb", source)
    Woods::Extractors::MigrationExtractor.new.extract_migration_file(path)
  end

  it 'selects distinct migrations after a shared helper model and excludes sibling helper DDL' do
    units = %w[accounts orders].map do |table|
      migration("create_#{table}", <<~RUBY)
        raise 'historical migration must not execute'
        class MigrationHelper < ActiveRecord::Base
          def self.unrelated
            create_table :decoy
          end
        end
        class Create#{table.capitalize} < ActiveRecord::Migration[7.1]
          def change
            create_table :#{table} do |t|
              t.string :label
            end
          end
        end
      RUBY
    end

    expect(units.map(&:identifier)).to eq(%w[CreateAccounts CreateOrders])
    expect(units.map { |unit| unit.metadata[:tables_affected] }).to eq([['accounts'], ['orders']])
    expect(units.map { |unit| unit.metadata[:columns_added].map { |column| column[:column] } })
      .to eq([['label'], ['label']])
  end

  it 'tracks actual namespaces and leading-root migration superclass qualification' do
    unit = migration('create_entries', <<~RUBY)
      module Unrelated
        class Helper < Object; end
      end
      module Billing
        class CreateEntries < ::ActiveRecord::Migration[7.1]
          def change
            create_table :entries
          end
        end
      end
    RUBY

    expect(unit&.identifier).to eq('Billing::CreateEntries')
    expect(unit.metadata[:tables_affected]).to eq(['entries'])
  end

  it 'uses the filename to select a migration inheriting a same-source structural base' do
    unit = migration('create_entries', <<~RUBY)
      class LocalMigration < ActiveRecord::Migration[7.1]; end
      class CreateEntries < LocalMigration
        def change
          create_table :entries
        end
      end
    RUBY

    expect(unit&.identifier).to eq('CreateEntries')
    expect(unit.metadata[:tables_affected]).to eq(['entries'])
  end

  it 'resolves a qualified declaration against its existing root namespace' do
    stub_const('ReviewOuter', Module.new)
    stub_const('ReviewRoot', Module.new)
    %i[const_defined? const_get autoload? ancestors name].each do |method|
      ReviewOuter.define_singleton_method(method) { |*| raise 'application reflection override invoked' }
    end
    unit = migration('create_entries', <<~RUBY)
      module ReviewOuter
        class ReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit&.identifier).to eq('ReviewRoot::CreateEntries')
  end

  it 'prefers an existing lexical owner over a same-named root namespace' do
    stub_const('ReviewOuter', Module.new)
    stub_const('ReviewOuter::ReviewRoot', Module.new)
    stub_const('ReviewOuter::Inner', Module.new)
    stub_const('ReviewRoot', Module.new)
    unit = migration('create_entries', <<~RUBY)
      module ReviewOuter
        module Inner
          class ReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
        end
      end
    RUBY

    expect(unit&.identifier).to eq('ReviewOuter::ReviewRoot::CreateEntries')
  end

  it 'keeps a namespace established structurally in the current source' do
    unit = migration('create_entries', <<~RUBY)
      module ReviewOuter
        module ReviewRoot; end
        class ReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit&.identifier).to eq('ReviewOuter::ReviewRoot::CreateEntries')
  end

  it 'honors a leading root qualifier even inside another lexical namespace' do
    stub_const('ReviewRoot', Module.new)
    unit = migration('create_entries', <<~RUBY)
      module ReviewOuter
        module ReviewRoot; end
        class ::ReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit&.identifier).to eq('ReviewRoot::CreateEntries')
  end

  it 'reports unresolved qualified ownership instead of inventing a nested identity' do
    stub_const('ReviewOuter', Module.new)
    unit = migration('create_entries', <<~RUBY)
      module ReviewOuter
        class UnknownReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit).to be_nil
    expect(logger).to have_received(:error).with(/unresolved qualified declaration/i)
  end

  it 'refuses to infer a root owner when a lexical constant table is unavailable' do
    stub_const('ReviewRoot', Module.new)
    unit = migration('create_entries', <<~RUBY)
      module UnloadedReviewOuter
        class ReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit).to be_nil
    expect(logger).to have_received(:error).with(/unresolved qualified declaration/i)
  end

  it 'refuses an inaccessible root namespace from a BasicObject lexical class' do
    stub_const('ReviewRoot', Module.new)
    stub_const('ReviewBare', Class.new(BasicObject))
    unit = migration('create_entries', <<~RUBY)
      class ReviewBare
        class ReviewRoot::CreateEntries < ::ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit).to be_nil
    expect(logger).to have_received(:error).with(/unresolved qualified declaration/i)
  end

  it 'does not trigger an autoload to resolve a qualified namespace' do
    stub_const('ReviewOuter', Module.new)
    pending_path = create_file('pending_review_root.rb', "raise 'autoload must not execute'")
    ReviewOuter.autoload(:ReviewRoot, pending_path)
    unit = migration('create_entries', <<~RUBY)
      module ReviewOuter
        class ReviewRoot::CreateEntries < ActiveRecord::Migration[7.1]; end
      end
    RUBY

    expect(unit).to be_nil
    expect(ReviewOuter.autoload?(:ReviewRoot)).to eq(pending_path)
    expect(logger).to have_received(:error).with(/unresolved qualified declaration/i)
  end

  it 'rejects ambiguous migration declarations when the filename selects neither' do
    unit = migration('ambiguous', <<~RUBY)
      class FirstMigration < ActiveRecord::Migration[7.1]; end
      class SecondMigration < ActiveRecord::Migration[7.1]; end
    RUBY

    expect(unit).to be_nil
    expect(logger).to have_received(:error).with(/ambiguous migration declaration/i)
  end

  it 'does not take migration identity from strings, comments, or an unrelated same-named runtime class' do
    stub_const('CreateEntries', Class.new)
    unit = migration('create_entries', <<~RUBY)
      # class Imaginary < ActiveRecord::Migration[7.1]
      EXAMPLE = "class Example < ActiveRecord::Migration[7.1]"
      class CreateEntries < Object; end
    RUBY

    expect(unit).to be_nil
  end

  it 'accepts an already-loaded application migration base without loading historical declarations' do
    stub_const('ActiveRecord', Module.new)
    stub_const('ActiveRecord::Migration', Class.new)
    stub_const('ApplicationMigration', Class.new(ActiveRecord::Migration))
    unit = migration('create_entries', <<~RUBY)
      raise 'must not execute'
      class CreateEntries < ApplicationMigration
        def change
          create_table :entries
        end
      end
    RUBY

    expect(unit&.identifier).to eq('CreateEntries')
    expect(unit.metadata[:tables_affected]).to eq(['entries'])
    expect(Object.const_defined?(:CreateEntries, false)).to be(false)
  end

  it 'rejects an unrelated runtime application base and a locally shadowed ActiveRecord migration constant' do
    stub_const('ApplicationMigration', Class.new)
    expect(migration('create_entries', 'class CreateEntries < ApplicationMigration; end')).to be_nil
    unit = migration('create_entries', <<~RUBY)
      module Local
        module ActiveRecord
          class Migration < Object; end
        end
        class CreateEntries < ActiveRecord::Migration; end
      end
    RUBY
    expect(unit).to be_nil
  end
end
