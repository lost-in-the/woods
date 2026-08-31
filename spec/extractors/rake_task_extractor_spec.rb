# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/model_name_cache'
require 'woods/extractors/rake_task_extractor'

RSpec.describe Woods::Extractors::RakeTaskExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing lib/tasks directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── B-126: one task reopened in two files ──────────────────────────

  describe 'a task defined in two .rake files (B-126)' do
    before do
      create_file('lib/tasks/a_seed.rake', <<~RAKE)
        namespace :db do
          desc 'Seed the base data'
          task seed: :environment do
            puts 'base'
          end
        end
      RAKE
      create_file('lib/tasks/b_seed.rake', <<~RAKE)
        namespace :db do
          task seed: :environment do
            Rake::Task['db:extra'].invoke
          end
        end
      RAKE
    end

    it 'merges both definitions into one unit on a full run' do
      units = described_class.new.extract_all.select { |u| u.identifier == 'db:seed' }
      expect(units.size).to eq(1)
      unit = units.first
      expect(unit.metadata[:defined_in]).to eq(%w[lib/tasks/a_seed.rake lib/tasks/b_seed.rake])
      expect(unit.source_code).to include("puts 'base'").and include("Rake::Task['db:extra']")
      expect(unit.dependencies).to include(hash_including(target: 'db:extra', via: :task_invoke))
    end

    it 'produces the same merged unit from either file on a per-file run' do
      extractor = described_class.new
      from_a = extractor.extract_rake_file(File.join(tmp_dir, 'lib/tasks/a_seed.rake')).find do |u|
        u.identifier == 'db:seed'
      end
      from_b = extractor.extract_rake_file(File.join(tmp_dir, 'lib/tasks/b_seed.rake')).find do |u|
        u.identifier == 'db:seed'
      end
      expect(from_b.file_path).to eq(from_a.file_path)
      expect(from_b.source_code).to eq(from_a.source_code)
      expect(from_b.metadata[:defined_in]).to eq(from_a.metadata[:defined_in])
    end

    # P9a. extract_rake_file reads and parses each file, and the first
    # sibling_definitions call triggers all_definitions, which re-read and
    # re-parsed every .rake file. Output is identical either way; the read
    # and parse counts below fail on the pre-fix shape.
    it 'reads and parses each .rake file once per run' do
      reads = Hash.new(0)
      allow(File).to receive(:read).and_wrap_original do |method, path|
        reads[path.to_s] += 1
        method.call(path)
      end
      parses = 0
      allow_any_instance_of(described_class).to receive(:parse_tasks).and_wrap_original do |method, source|
        parses += 1
        method.call(source)
      end

      units = described_class.new.extract_all

      seed_unit = units.find { |u| u.identifier == 'db:seed' }
      expect(seed_unit.metadata[:defined_in]).to eq(%w[lib/tasks/a_seed.rake lib/tasks/b_seed.rake])

      expect(parses).to eq(2)
      expect(reads[File.join(tmp_dir, 'lib/tasks/a_seed.rake')]).to eq(1)
      expect(reads[File.join(tmp_dir, 'lib/tasks/b_seed.rake')]).to eq(1)
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

    it 'excludes woods namespace tasks' do
      path = create_file('lib/tasks/woods.rake', <<~RAKE)
        namespace :woods do
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
      expect(meta[:line_number]).to eq(3)
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

  # ── Task signature forms (#176) ─────────────────────────────────────

  describe 'task signature forms' do
    it 'extracts all four task forms from one file' do
      path = create_file('lib/tasks/forms.rake', <<~RAKE)
        task :report => :environment do
          puts "report"
        end

        task archive_stale: :environment do
          puts "archiving"
        end

        task :plain do
          puts "plain"
        end

        task :with_args, [:id] => :environment do |t, args|
          puts args[:id]
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.map(&:identifier)).to contain_exactly('report', 'archive_stale', 'plain', 'with_args')

      report = units.find { |u| u.identifier == 'report' }
      archive = units.find { |u| u.identifier == 'archive_stale' }
      plain = units.find { |u| u.identifier == 'plain' }
      with_args = units.find { |u| u.identifier == 'with_args' }

      expect(report.metadata[:task_dependencies]).to eq(['environment'])
      expect(archive.metadata[:task_dependencies]).to eq(['environment'])
      expect(archive.metadata[:has_environment_dependency]).to be true
      expect(plain.metadata[:task_dependencies]).to eq([])
      expect(with_args.metadata[:task_dependencies]).to eq(['environment'])
      expect(with_args.metadata[:arguments]).to eq(['id'])
    end

    it 'extracts a modern label-form task (task name: :environment)' do
      path = create_file('lib/tasks/modern.rake', <<~RAKE)
        task archive_stale: :environment do
          puts "archiving"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('archive_stale')
      expect(units.first.metadata[:task_dependencies]).to eq(['environment'])
    end

    it 'extracts label-form array dependencies (task name: [:dep1, :dep2])' do
      path = create_file('lib/tasks/modern.rake', <<~RAKE)
        task compile: [:environment, :setup] do
          puts "compiling"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.metadata[:task_dependencies]).to contain_exactly('environment', 'setup')
    end

    # `extract_task_block` used to gate on a bare `include?('do')`, so a
    # blockless task whose own name contains the substring "do" (`docs`)
    # looked like it opened a block and swallowed the next task's body.
    it 'does not let a blockless task named "docs" swallow the next task as its own body' do
      path = create_file('lib/tasks/docs.rake', <<~RAKE)
        task docs: :environment
        task :other do
          DocsService.call
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      docs = units.find { |u| u.identifier == 'docs' }
      other = units.find { |u| u.identifier == 'other' }

      expect(docs.dependencies.map { |d| d[:target] }).not_to include('DocsService')
      expect(other.dependencies.map { |d| d[:target] }).to include('DocsService')
    end

    it 'extracts a label-form task without a do block' do
      path = create_file('lib/tasks/modern.rake', <<~RAKE)
        task setup: :environment
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('setup')
      expect(units.first.metadata[:task_dependencies]).to eq(['environment'])
    end
  end

  # ── String-form namespaces (#176) ───────────────────────────────────

  describe 'string-form namespaces' do
    it 'qualifies tasks inside a single-quoted namespace' do
      path = create_file('lib/tasks/admin.rake', <<~RAKE)
        namespace 'admin' do
          task cleanup: :environment do
            puts "cleaning"
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('admin:cleanup')
      expect(units.first.namespace).to eq('admin')
    end

    it 'qualifies tasks inside a double-quoted namespace' do
      path = create_file('lib/tasks/admin.rake', <<~RAKE)
        namespace "admin" do
          task :cleanup do
            puts "cleaning"
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.first.identifier).to eq('admin:cleanup')
    end

    it 'keeps depth tracking in sync across nested namespaces mixing forms' do
      path = create_file('lib/tasks/mixed.rake', <<~RAKE)
        namespace :admin do
          namespace 'reports' do
            task generate: :environment do
              puts "generating"
            end
          end

          task :cleanup do
            puts "cleaning"
          end
        end

        task :outer do
          puts "outer"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('admin:reports:generate', 'admin:cleanup', 'outer')

      generate = units.find { |u| u.identifier == 'admin:reports:generate' }
      expect(generate.namespace).to eq('admin:reports')
    end
  end

  # ── Chained `end` and namespace depth tracking ──────────────────────

  describe 'chained end lines' do
    # An exact `stripped == 'end'` check missed `end.freeze`, so the
    # depth counter never returned to the level `namespace :admin do`
    # opened at, and the namespace was never popped for tasks that follow.
    it 'keeps namespace depth in sync when a block end is chained (end.freeze)' do
      path = create_file('lib/tasks/admin.rake', <<~RAKE)
        namespace :admin do
          LIST = %w[a b].map do |x|
            x
          end.freeze

          task :cleanup do
            puts "cleaning"
          end
        end

        task :outer do
          puts "outer"
        end
      RAKE

      units = described_class.new.extract_rake_file(path)
      expect(units.map(&:identifier)).to contain_exactly('admin:cleanup', 'outer')
    end
  end

  # ── Zero-task diagnostic (#176) ─────────────────────────────────────

  describe 'zero-task diagnostic' do
    it 'logs a debug line naming the file when no tasks are parsed' do
      path = create_file('lib/tasks/none.rake', "# only comments here\n")

      expect(logger).to receive(:debug).with(a_string_including('none.rake'))
      described_class.new.extract_rake_file(path)
    end

    it 'does not log the diagnostic when tasks are parsed' do
      path = create_file('lib/tasks/some.rake', <<~RAKE)
        task :cleanup do
          puts "cleaning"
        end
      RAKE

      expect(logger).not_to receive(:debug)
      described_class.new.extract_rake_file(path)
    end
  end
end
