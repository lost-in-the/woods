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

  it_behaves_like 'extracts multibyte source under a POSIX locale',
                  path: 'lib/tasks/ledger.rake',
                  source: <<~SOURCE,
                    # Ledger — maintenance
                    namespace :ledger do
                      desc 'Reconcile the ledger — nightly'
                      task reconcile: :environment do
                        puts 'done'
                      end
                    end
                  SOURCE
                  identifier: 'ledger:reconcile'

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
      allow(File).to receive(:read).and_wrap_original do |method, path, **options|
        reads[path.to_s] += 1
        method.call(path, **options)
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

  # ── EXTB-1: keywords in comments, strings, and heredocs ─────────────

  describe 'keywords that are not code' do
    it 'does not count a block keyword inside a comment (EXTB-1)' do
      # `# do not touch production` matched `block_opener?`, inflating depth
      # with no matching `end`: the namespace stack stopped popping, so the
      # following namespace inherited a stale `cleanup:` prefix, and the
      # earlier task swallowed the next one's lines as its own body.
      path = create_file('lib/tasks/clean.rake', <<~RAKE)
        namespace :cleanup do
          desc 'first'
          task stale: :environment do
            # do not touch production
            puts 'one'
          end

          desc 'second'
          task fresh: :environment do
            puts 'two'
          end
        end

        namespace :other do
          task third: :environment do
            puts 'three'
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)

      expect(units.map(&:identifier)).to contain_exactly('cleanup:stale', 'cleanup:fresh', 'other:third')
      stale = units.find { |u| u.identifier == 'cleanup:stale' }
      expect(stale.metadata[:source_lines]).to eq(2)
    end

    it 'does not count a keyword inside a string literal (EXTB-1)' do
      path = create_file('lib/tasks/say.rake', <<~RAKE)
        namespace :say do
          task hello: :environment do
            puts 'things to do'
          end
        end

        namespace :other do
          task bye: :environment do
            puts 'bye'
          end
        end
      RAKE

      units = described_class.new.extract_rake_file(path)

      expect(units.map(&:identifier)).to contain_exactly('say:hello', 'other:bye')
    end

    it 'does not let an `end`-leading heredoc line truncate the task body (EXTB-1)' do
      # The heredoc line `end of the road` matched END_LINE, popping the
      # task's own frame: the body stopped at one line and the service call
      # after the heredoc produced no dependency edge.
      path = create_file('lib/tasks/hd.rake', <<~RAKE)
        namespace :db do
          task fix: :environment do
            msg = <<~TXT
              end of the road
            TXT
            ImportantService.call(msg)
          end
        end
      RAKE

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.identifier).to eq('db:fix')
      expect(unit.dependencies).to include(hash_including(type: :service, target: 'ImportantService'))
    end
  end

  # ── Assignment-form multi-line conditionals ─────────────────────────

  describe 'assignment-form multi-line conditionals' do
    # `value = if cond` opens a construct whose line-leading `end` pops a
    # depth frame, but `block_opener?` counted `if`/`unless` only in
    # line-leading position — the frame was never pushed, so that `end`
    # closed the enclosing namespace one construct early and every task
    # after it lost its prefix. `case`/`begin` matched anywhere on the
    # line, so the same syntactic shape was counted for one keyword and
    # not the other. Five-case matrix from the PR #276 downstream
    # validation; every case expects `probe:alpha` and `probe:beta`.

    def probe_identifiers(alpha_body)
      path = create_file('lib/tasks/probe.rake', <<~RAKE)
        namespace :probe do
          task alpha: :environment do
        #{alpha_body.gsub(/^/, '    ').chomp}
          end

          task beta: :environment do
            puts 'beta'
          end
        end
      RAKE
      described_class.new.extract_rake_file(path).map(&:identifier)
    end

    it 'control: plain tasks keep the namespace' do
      expect(probe_identifiers("puts 'alpha'")).to contain_exactly('probe:alpha', 'probe:beta')
    end

    it 'keeps the namespace across an assignment-form multi-line if' do
      body = <<~RUBY
        value = if ENV['MODE']
          'special'
        else
          'plain'
        end
        puts value
      RUBY
      expect(probe_identifiers(body)).to contain_exactly('probe:alpha', 'probe:beta')
    end

    it 'keeps the namespace across a comment containing a block keyword (EXTB-1)' do
      body = <<~RUBY
        # do not run this outside maintenance windows
        puts 'alpha'
      RUBY
      expect(probe_identifiers(body)).to contain_exactly('probe:alpha', 'probe:beta')
    end

    it 'keeps the namespace when the comment and the assignment-form if appear together' do
      body = <<~RUBY
        # do not run this outside maintenance windows
        value = if ENV['MODE']
          'special'
        else
          'plain'
        end
        puts value
      RUBY
      expect(probe_identifiers(body)).to contain_exactly('probe:alpha', 'probe:beta')
    end

    it 'keeps the namespace across an assignment-form multi-line case' do
      body = <<~RUBY
        value = case ENV['MODE']
                when 'a' then 'special'
                else 'plain'
                end
        puts value
      RUBY
      expect(probe_identifiers(body)).to contain_exactly('probe:alpha', 'probe:beta')
    end

    it 'keeps the assignment-form conditional inside the task body' do
      body = <<~RUBY
        value = if ENV['MODE']
          'special'
        else
          'plain'
        end
        puts value
      RUBY
      path = create_file('lib/tasks/probe.rake', <<~RAKE)
        namespace :probe do
          task alpha: :environment do
        #{body.gsub(/^/, '    ').chomp}
          end

          task beta: :environment do
            puts 'beta'
          end
        end
      RAKE
      alpha = described_class.new.extract_rake_file(path).find { |u| u.identifier == 'probe:alpha' }
      expect(alpha.source_code).to include('else').and include('puts value')
      # The task block is the 6 body lines through the conditional's `end`
      # plus `puts value` — a truncated walk stops at 4.
      expect(alpha.metadata[:source_lines]).to eq(6)
    end
  end

  # ── EXTB-9: quoted namespaced task dependencies ─────────────────────

  describe 'quoted task dependencies' do
    it 'keeps the namespace of a quoted dependency (EXTB-9)' do
      # `dep_str.scan(/:(\w+)/)` read `'assets:precompile'` as symbol syntax
      # and recorded only `precompile`, pointing the edge at a task that
      # does not exist.
      path = create_file('lib/tasks/dep.rake', <<~RAKE)
        task deploy: 'assets:precompile' do
          puts 'deploying'
        end
      RAKE

      unit = described_class.new.extract_rake_file(path).find { |u| u.identifier == 'deploy' }

      expect(unit.metadata[:task_dependencies]).to eq(['assets:precompile'])
      expect(unit.dependencies).to include(
        hash_including(type: :rake_task, target: 'assets:precompile', via: :task_dependency)
      )
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

  # ── Configured roots ────────────────────────────────────────────────

  describe 'rake_task_paths roots' do
    def unit_named(units, identifier)
      units.find { |unit| unit.identifier == identifier }
    end

    it 'extracts tasks from a root rake/ directory and the Rakefile' do
      create_file('rake/graph.rake', <<~RAKE)
        namespace :graph do
          task(:codegen) { exec_in_container "yarn run graph-codegen" }
        end
      RAKE
      create_file('Rakefile', "task :bootstrap do\n  sh 'bin/setup'\nend\n")
      create_file('lib/tasks/export.rake', "task :export\n")

      units = described_class.new.extract_all

      expect(units.map(&:identifier)).to contain_exactly('graph:codegen', 'bootstrap', 'export')
      expect(unit_named(units, 'graph:codegen').file_path).to eq(File.join(tmp_dir, 'rake/graph.rake'))
      expect(unit_named(units, 'bootstrap').metadata).to include(kind: 'task', shell_commands: ['bin/setup'])
    end

    it 'follows config.rake_task_paths' do
      create_file('ops/deploy.rake', "task :deploy\n")
      create_file('lib/tasks/export.rake', "task :export\n")
      allow(Woods::Extractors::RakeTaskPaths).to receive(:configured).and_return(['ops/*.rake'])

      expect(described_class.new.extract_all.map(&:identifier)).to eq(['deploy'])
    end

    it 'extracts a Rakefile through the per-file entry point' do
      path = create_file('Rakefile', "task :bootstrap\n")

      expect(described_class.new.extract_rake_file(path).map(&:identifier)).to eq(['bootstrap'])
    end
  end

  # ── Shapes the line parser missed ───────────────────────────────────

  describe 'an ordinary one-off task file' do
    def identifiers(source)
      path = create_file('lib/tasks/one_offs/toggle.rake', source)
      described_class.new.extract_rake_file(path).map(&:identifier)
    end

    it 'extracts a hash-argument task with block parameters' do
      expect(identifiers(<<~RAKE)).to eq(['one_offs:toggle_accounts_flag'])
        namespace :one_offs do
          desc "x"
          task toggle_accounts_flag: :environment do |_, args|
            Widget.find_each { |widget| widget.update!(flag: args[:on]) }
          end
        end
      RAKE
    end

    it 'extracts a long name with arguments and an array of prerequisites' do
      name = "backfill_#{'ledger_entry_' * 12}totals"

      source = "namespace :one_offs do\n  task :#{name}, [:arg] => [:environment] do |_, args|\n  end\nend\n"

      expect(identifiers(source)).to eq(["one_offs:#{name}"])
    end

    it 'extracts string names, parenthesized calls and multi-line signatures' do
      expect(identifiers(<<~RAKE)).to eq(%w[one_offs:a one_offs:b one_offs:c one_offs:d])
        namespace :one_offs do
          task 'a' => :environment do
          end
          task(b: :environment) do |_, args|
          end
          task c:
            :environment do
          end
          task :d do; end
        end
      RAKE
    end

    it 'extracts a file holding multibyte text when the process encoding is US-ASCII' do
      previous = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII

      expect(identifiers("# Toggle — run once\nnamespace :one_offs do\n  task toggle: :environment do\n  end\nend\n"))
        .to eq(['one_offs:toggle'])
    ensure
      Encoding.default_external = previous
    end

    it 'lists every defining file when two files define the same task' do
      create_file('lib/tasks/a.rake', "namespace :one_offs do\n  task toggle: :environment\nend\n")
      path = create_file('lib/tasks/one_offs/toggle.rake', "namespace :one_offs do\n  task toggle: :environment\nend\n")

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.metadata[:defined_in]).to eq(%w[lib/tasks/a.rake lib/tasks/one_offs/toggle.rake])
    end
  end

  # ── enhance, invoke, task classes ───────────────────────────────────

  describe 'enhance' do
    it 'gives a one-line enhance file a unit with a task_dependency edge' do
      path = create_file('lib/tasks/i18n.rake', %(Rake::Task["javascript:build"].enhance(["i18n:js:export"])\n))

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.identifier).to eq('javascript:build')
      expect(unit.file_path).to eq(path)
      expect(unit.metadata).to include(kind: 'enhancement', task_name: 'build', task_namespace: 'javascript',
                                       task_dependencies: ['i18n:js:export'],
                                       enhanced_in: ['lib/tasks/i18n.rake'])
      expect(unit.dependencies).to eq([{ type: :rake_task, target: 'i18n:js:export', via: :task_dependency }])
    end

    it 'merges an enhancement into the task another file defines' do
      definition = create_file('lib/tasks/assets.rake', "namespace :assets do\n  task :build do\n  end\nend\n")
      create_file('lib/tasks/z_hooks.rake', <<~RAKE)
        Rake::Task['assets:build'].enhance(['assets:clean']) do
          Rake::Task['assets:report'].invoke
          sh 'bin/notify'
        end
      RAKE

      unit = described_class.new.extract_all.find { |candidate| candidate.identifier == 'assets:build' }

      expect(unit.file_path).to eq(definition)
      expect(unit.metadata).to include(kind: 'task', enhanced_in: ['lib/tasks/z_hooks.rake'],
                                       task_dependencies: ['assets:clean'], shell_commands: ['bin/notify'])
      expect(unit.metadata).not_to have_key(:defined_in)
      expect(unit.dependencies).to include(
        { type: :rake_task, target: 'assets:report', via: :task_invoke },
        { type: :rake_task, target: 'assets:clean', via: :task_dependency }
      )
      expect(unit.source_code).to include("sh 'bin/notify'").and include('task :build do')
    end

    it 'resolves an enhance target against the enclosing namespace' do
      create_file('lib/tasks/assets.rake', <<~RAKE)
        namespace :assets do
          task :build
          Rake::Task[:build].enhance([:clean])
          task :clean
        end
      RAKE

      unit = described_class.new.extract_all.find { |candidate| candidate.identifier == 'assets:build' }

      expect(unit.dependencies).to eq([{ type: :rake_task, target: 'assets:clean', via: :task_dependency }])
    end
  end

  describe 'task invocations' do
    it 'records invoke and execute with the same edge shape' do
      path = create_file('lib/tasks/nightly.rake', <<~RAKE)
        task nightly: :environment do
          Rake::Task['ledger:close'].invoke
          Rake::Task['ledger:report'].execute
        end
      RAKE

      expect(described_class.new.extract_rake_file(path).first.dependencies).to eq(
        [{ type: :rake_task, target: 'ledger:close', via: :task_invoke },
         { type: :rake_task, target: 'ledger:report', via: :task_invoke }]
      )
    end
  end

  describe 'prerequisite scope' do
    it 'points a prerequisite at the task Rake would find from that namespace' do
      path = create_file('lib/tasks/js.rake', <<~RAKE)
        task :lint
        namespace :js do
          task build: %i[compile lint missing]
          task :compile
        end
      RAKE

      unit = described_class.new.extract_rake_file(path).find { |candidate| candidate.identifier == 'js:build' }

      expect(unit.metadata[:task_dependencies]).to eq(%w[compile lint missing])
      expect(unit.dependencies.map { |dependency| dependency[:target] }).to eq(%w[js:compile lint missing])
    end
  end

  describe 'task classes' do
    it 'gives a gem task class inside a conditional a unit' do
      path = create_file('lib/tasks/docs.rake', <<~RAKE)
        if defined?(RSpec)
          RSpec::Core::RakeTask.new(:docs) { |t| t.pattern = 'spec/docs/**/*_spec.rb' }
        end
      RAKE

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.identifier).to eq('docs')
      expect(unit.metadata).to include(kind: 'task_class', task_class: 'RSpec::Core::RakeTask',
                                       conditions: ['defined?(RSpec)'])
    end

    it 'names a nameless well-known task class by its default' do
      path = create_file('lib/tasks/lint.rake', "RuboCop::RakeTask.new\n")

      expect(described_class.new.extract_rake_file(path).first.identifier).to eq('rubocop')
    end
  end

  describe 'other definition kinds' do
    it 'extracts multitask, file and rule definitions' do
      path = create_file('lib/tasks/build.rake', <<~RAKE)
        namespace :build do
          multitask all: %i[css js]
          file 'public/app.css' => ['app/app.scss']
          rule '.o' => '.c'
        end
      RAKE

      units = described_class.new.extract_rake_file(path)

      expect(units.map { |unit| [unit.identifier, unit.metadata[:kind], unit.namespace] }).to eq(
        [['build:all', 'multitask', 'build'], ['public/app.css', 'file', nil], ['.o', 'rule', nil]]
      )
    end
  end

  # ── Shell commands ──────────────────────────────────────────────────

  describe 'shell commands' do
    it 'records literal commands, truncated, without adding edges' do
      path = create_file('lib/tasks/ship.rake', <<~RAKE)
        task :ship do
          sh 'bin/build'
          system('bin/push', '--tags')
          `git rev-parse HEAD`
          exec "bin/long \#{'x'} #{'y' * 300}"
          sh command
          puts 'not a command'
        end
      RAKE

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.metadata[:shell_commands][0..2])
        .to eq(['bin/build', 'bin/push --tags', "bin/long \#{'x'} #{'y' * 184}"])
      expect(unit.metadata[:shell_commands].last).to eq('git rev-parse HEAD')
      expect(unit.metadata[:shell_commands].map(&:length).max).to eq(200)
      expect(unit.dependencies).to eq([])
    end

    it 'records commands passed to a helper that shells out' do
      create_file('rake/lib/container.rb', <<~RUBY)
        module Container
          def exec_in_container(command)
            run_compose("exec app \#{command}")
          end

          def run_compose(arguments)
            sh "docker compose \#{arguments}"
          end

          def banner(text)
            puts text
          end
        end
      RUBY
      path = create_file('rake/graph.rake', <<~RAKE)
        namespace :graph do
          task(:codegen) do
            banner 'Generating'
            exec_in_container "yarn run graph-codegen"
          end
        end
      RAKE

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.metadata[:shell_commands]).to eq(['yarn run graph-codegen'])
    end
  end

  # ── Support files ───────────────────────────────────────────────────

  describe 'support files under a rake root' do
    before do
      create_file('rake/lib/container.rb', <<~RUBY)
        module Container
          def exec_in_container(command)
            sh "docker compose exec app \#{command}"
          end
        end
      RUBY
      create_file('rake/lib/core_ext/string.rb', "class String\n  def paint\n    self\n  end\nend\n")
      create_file('rake/lib/palette.rb', "module Palette\n  extend Container\n  DEFAULT = 'green'.paint\nend\n")
      create_file('rake/graph.rake', <<~RAKE)
        task :codegen do
          exec_in_container 'yarn run graph-codegen'
          puts Palette::DEFAULT
        end
      RAKE
    end

    it 'indexes each Ruby file as a rake_support unit' do
      units = described_class.new.extract_all.select { |unit| unit.metadata[:kind] == 'rake_support' }

      expect(units.map(&:identifier))
        .to eq(%w[rake/lib/container.rb rake/lib/core_ext/string.rb rake/lib/palette.rb])
      container = units.first
      expect(container.type).to eq(:rake_task)
      expect(container.file_path).to eq(File.join(tmp_dir, 'rake/lib/container.rb'))
      expect(container.metadata).to include(constants: ['Container'], methods: ['exec_in_container'],
                                            shell_commands: ["docker compose exec app \#{command}"])
      expect(container.source_code).to include('module Container')
    end

    it 'links a task to the support files it calls or names' do
      unit = described_class.new.extract_all.find { |candidate| candidate.identifier == 'codegen' }

      expect(unit.dependencies).to eq(
        [{ type: :rake_task, target: 'rake/lib/container.rb', via: :method_call },
         { type: :rake_task, target: 'rake/lib/palette.rb', via: :code_reference }]
      )
    end

    it 'links one support file to another' do
      palette = described_class.new.extract_all.find { |unit| unit.identifier == 'rake/lib/palette.rb' }

      expect(palette.dependencies).to eq(
        [{ type: :rake_task, target: 'rake/lib/container.rb', via: :code_reference }]
      )
    end

    it 'extracts a support file through the per-file entry point' do
      units = described_class.new.extract_rake_file(File.join(tmp_dir, 'rake/lib/palette.rb'))

      expect(units.map(&:identifier)).to eq(['rake/lib/palette.rb'])
    end
  end

  # ── Loaded Rake application ─────────────────────────────────────────

  describe 'tasks the loaded Rake application resolves' do
    require 'rake'

    def load_into_runtime(*paths)
      application = Rake::Application.new
      Rake.with_application(application) { paths.each { |path| load path } }
      allow(Woods::Extractors::RakeRuntimeIndex).to receive(:current)
        .and_return(Woods::Extractors::RakeRuntimeIndex.new(application))
    end

    let(:source) do
      <<~RAKE
        namespace :sync do
          %w[widgets ledgers].each do |name|
            desc "Sync \#{name}"
            task name => [:environment, "prepare_\#{name}"] do
              puts name
            end
          end
          task :environment
          task :prepare_widgets
          task :prepare_ledgers
        end
      RAKE
    end

    it 'names computed tasks and reads their prerequisites from the runtime' do
      path = create_file('lib/tasks/sync.rake', source)
      load_into_runtime(path)

      units = described_class.new.extract_rake_file(path)
      widgets = units.find { |unit| unit.identifier == 'sync:widgets' }

      expect(units.map(&:identifier))
        .to eq(%w[sync:ledgers sync:widgets sync:environment sync:prepare_widgets sync:prepare_ledgers])
      expect(widgets.metadata).to include(task_dependencies: %w[environment prepare_widgets],
                                          name_source: 'runtime', line_number: 4)
      expect(widgets.dependencies).to include(
        { type: :rake_task, target: 'sync:prepare_widgets', via: :task_dependency }
      )
    end

    it 'emits nothing for a computed task when the file was never loaded' do
      path = create_file('lib/tasks/sync.rake', source)

      expect(described_class.new.extract_rake_file(path).map(&:identifier))
        .to eq(%w[sync:environment sync:prepare_widgets sync:prepare_ledgers])
    end

    it 'keeps what the source states when the loaded application is stale' do
      path = create_file('lib/tasks/ship.rake', "task ship: :build do\nend\ntask :build\ntask :package\n")
      load_into_runtime(path)
      File.write(path, "task ship: :package do\nend\ntask :build\ntask :package\n")

      unit = described_class.new.extract_rake_file(path).first

      expect(unit.metadata[:task_dependencies]).to eq(['package'])
      expect(unit.metadata).not_to have_key(:name_source)
    end
  end

  # ── Determinism ─────────────────────────────────────────────────────

  describe 'repeat runs' do
    it 'serialize identically' do
      create_file('rake/lib/container.rb', "module Container\n  def run(c)\n    sh c\n  end\nend\n")
      create_file('rake/a.rake', "task a: :b do\n  run 'make'\nend\ntask :b\n")
      create_file('lib/tasks/b.rake', "Rake::Task['a'].enhance(['b'])\n")

      runs = Array.new(2) do
        described_class.new.extract_all.map { |unit| unit.to_h.except(:extracted_at) }
      end

      expect(JSON.generate(runs.first)).to eq(JSON.generate(runs.last))
    end
  end

  # ── Pathological nesting ────────────────────────────────────────────

  describe 'a file nested too deeply to walk' do
    it 'is skipped with an error log and leaves other files alone' do
      create_file('lib/tasks/deep.rake', "task :deep\n")
      create_file('lib/tasks/fine.rake', "task :fine\n")
      allow_any_instance_of(described_class).to receive(:parse_tasks).and_wrap_original do |method, source|
        raise SystemStackError, 'stack level too deep' if source.include?(':deep')

        method.call(source)
      end

      expect(logger).to receive(:error).with(a_string_including('deep.rake'))
      expect(described_class.new.extract_all.map(&:identifier)).to eq(['fine'])
    end
  end
end
