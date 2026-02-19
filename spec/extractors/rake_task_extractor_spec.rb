# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/rake_task_extractor'

RSpec.describe CodebaseIndex::Extractors::RakeTaskExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing lib/tasks directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers .rake files in lib/tasks/' do
      create_file('lib/tasks/cleanup.rake', <<~RAKE)
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:rake_task)
    end

    it 'discovers .rake files in subdirectories' do
      create_file('lib/tasks/admin/reports.rake', <<~RAKE)
        namespace :admin do
          task :reports do
            puts "generating"
          end
        end
      RAKE

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('admin:reports')
    end

    it 'returns multiple units from a single file' do
      create_file('lib/tasks/maintenance.rake', <<~RAKE)
        namespace :maintenance do
          task :cleanup do
            puts "cleanup"
          end

          task :optimize do
            puts "optimize"
          end
        end
      RAKE

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('maintenance:cleanup', 'maintenance:optimize')
    end

    it 'collects units from multiple rake files' do
      create_file('lib/tasks/cleanup.rake', <<~RAKE)
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      create_file('lib/tasks/reports.rake', <<~RAKE)
        task :reports do
          puts "reporting"
        end
      RAKE

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end
  end

  # ── extract_rake_file ────────────────────────────────────────────────

  describe '#extract_rake_file' do
    it 'extracts a simple top-level task' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:rake_task)
      expect(unit.identifier).to eq('cleanup')
      expect(unit.namespace).to be_nil
    end

    it 'extracts a namespaced task' do
      path = create_file('lib/tasks/db.rake', <<~RAKE)
        namespace :db do
          task :seed_demo do
            puts "seeding"
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.identifier).to eq('db:seed_demo')
      expect(unit.namespace).to eq('db')
    end

    it 'extracts nested namespaces' do
      path = create_file('lib/tasks/admin.rake', <<~RAKE)
        namespace :admin do
          namespace :reports do
            task :generate do
              puts "generating"
            end
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('admin:reports:generate')
      expect(units.first.namespace).to eq('admin:reports')
    end

    it 'captures desc description' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        desc 'Remove stale orders older than 30 days'
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:description]).to eq('Remove stale orders older than 30 days')
    end

    it 'captures desc with double quotes' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        desc "Remove stale orders"
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:description]).to eq('Remove stale orders')
    end

    it 'captures task dependencies' do
      path = create_file('lib/tasks/reports.rake', <<~RAKE)
        task :reports => [:environment, :setup] do
          puts "reporting"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:task_dependencies]).to contain_exactly('environment', 'setup')
    end

    it 'captures single task dependency' do
      path = create_file('lib/tasks/reports.rake', <<~RAKE)
        task :reports => :environment do
          puts "reporting"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:task_dependencies]).to eq(['environment'])
      expect(units.first.metadata[:has_environment_dependency]).to be true
    end

    it 'captures task arguments' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        task :cleanup, [:days, :dry_run] do |t, args|
          puts args[:days]
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:arguments]).to contain_exactly('days', 'dry_run')
    end

    it 'detects model/service/job dependencies via source scanning' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        task :cleanup => :environment do
          OrderService.call
          CleanupJob.perform_later
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      deps = units.first.dependencies
      dep_targets = deps.map { |d| d[:target] }
      expect(dep_targets).to include('OrderService')
      expect(dep_targets).to include('CleanupJob')
    end

    it 'detects cross-task invocations via Rake::Task' do
      path = create_file('lib/tasks/deploy.rake', <<~RAKE)
        task :deploy do
          Rake::Task["db:migrate"].invoke
          Rake::Task["cache:clear"].invoke
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      deps = units.first.dependencies
      rake_deps = deps.select { |d| d[:type] == :rake_task }
      expect(rake_deps.map { |d| d[:target] }).to contain_exactly('db:migrate', 'cache:clear')
      expect(rake_deps.first[:via]).to eq(:task_invoke)
    end

    it 'sets file_path on each unit' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.file_path).to eq(path)
    end

    it 'sets source_code with annotation header' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        desc 'Clean up data'
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.source_code).to include('# Rake task: cleanup')
      expect(units.first.source_code).to include('# Clean up data')
      expect(units.first.source_code).to include('puts "cleaning"')
    end

    it 'includes dependencies with :via key' do
      path = create_file('lib/tasks/reports.rake', <<~RAKE)
        task :reports => :environment do
          OrderService.call
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      units.first.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'excludes codebase_index namespace tasks' do
      path = create_file('lib/tasks/codebase_index.rake', <<~RAKE)
        namespace :codebase_index do
          task :extract do
            puts "extracting"
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units).to eq([])
    end

    it 'returns empty array for non-rake files' do
      path = create_file('lib/tasks/readme.txt', 'not a rake file')
      units = described_class.new.extract_rake_file(path)
      expect(units).to eq([])
    end

    it 'handles read errors gracefully' do
      units = described_class.new.extract_rake_file('/nonexistent/path.rake')
      expect(units).to eq([])
    end

    it 'returns empty array for empty rake file' do
      path = create_file('lib/tasks/empty.rake', '')
      units = described_class.new.extract_rake_file(path)
      expect(units).to eq([])
    end

    it 'handles tasks without do block' do
      path = create_file('lib/tasks/simple.rake', <<~RAKE)
        task :setup => :environment
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('setup')
      expect(units.first.metadata[:task_dependencies]).to eq(['environment'])
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        namespace :data do
          desc 'Clean old records'
          task :cleanup, [:days] => :environment do |t, args|
            puts args[:days]
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      meta = units.first.metadata

      expect(meta[:task_name]).to eq('cleanup')
      expect(meta[:full_name]).to eq('data:cleanup')
      expect(meta[:description]).to eq('Clean old records')
      expect(meta[:task_namespace]).to eq('data')
      expect(meta[:task_dependencies]).to eq(['environment'])
      expect(meta[:arguments]).to eq(['days'])
      expect(meta[:has_environment_dependency]).to be true
      expect(meta[:source_lines]).to be_a(Integer)
    end

    it 'sets has_environment_dependency to false when no :environment dep' do
      path = create_file('lib/tasks/simple.rake', <<~RAKE)
        task :simple do
          puts "hi"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:has_environment_dependency]).to be false
    end
  end

  # ── Serialization round-trip ────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('lib/tasks/cleanup.rake', <<~RAKE)
        desc 'Clean up'
        task :cleanup => :environment do
          puts "cleaning"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      hash = units.first.to_h

      expect(hash[:type]).to eq(:rake_task)
      expect(hash[:identifier]).to eq('cleanup')
      expect(hash[:source_code]).to include('# Rake task: cleanup')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      # JSON round-trip
      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('rake_task')
      expect(parsed['identifier']).to eq('cleanup')
    end
  end

  # ── Multiple tasks in namespace ─────────────────────────────────────

  describe 'multiple tasks per namespace' do
    it 'correctly assigns namespace to each task' do
      path = create_file('lib/tasks/data.rake', <<~RAKE)
        namespace :data do
          task :import do
            puts "importing"
          end

          task :export do
            puts "exporting"
          end

          namespace :cleanup do
            task :stale do
              puts "cleaning stale"
            end
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(3)

      import = units.find { |u| u.identifier == 'data:import' }
      export = units.find { |u| u.identifier == 'data:export' }
      stale = units.find { |u| u.identifier == 'data:cleanup:stale' }

      expect(import.namespace).to eq('data')
      expect(export.namespace).to eq('data')
      expect(stale.namespace).to eq('data:cleanup')
    end
  end
end
