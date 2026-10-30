# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/rake_source_parser'

RSpec.describe Woods::Extractors::RakeSourceParser do
  def parse(source)
    described_class.parse(source)
  end

  def definitions(source)
    parse(source).definitions
  end

  def definition(source)
    definitions(source).first
  end

  describe 'task signatures' do
    {
      'task :a' => ['a', [], []],
      "task 'a'" => ['a', [], []],
      'task a: :b' => ['a', %w[b], []],
      'task a: [:b, "c:d"]' => ['a', %w[b c:d], []],
      'task :a => :b' => ['a', %w[b], []],
      "task 'a' => %w[b c]" => ['a', %w[b c], []],
      'task :a, [:x] => :b' => ['a', %w[b], %w[x]],
      'task :a, [:x, :y] => [:b, :c]' => ['a', %w[b c], %w[x y]],
      'task :a, %i[x y] => :b' => ['a', %w[b], %w[x y]],
      'task :a, [:x]' => ['a', [], %w[x]],
      'task :a, :x, :y' => ['a', [], %w[x y]],
      'task(:a) { }' => ['a', [], []],
      'task(a: :b) { }' => ['a', %w[b], []],
      'task({ a: :b }) { }' => ['a', %w[b], []],
      'task "a": :b' => ['a', %w[b], []],
      "task a:\n  :b do\nend" => ['a', %w[b], []]
    }.each do |source, (name, prerequisites, arguments)|
      it "reads #{source.inspect}" do
        expect(definition(source)).to include(
          kind: :task, name: name, full_name: name, prerequisites: prerequisites, arguments: arguments
        )
      end
    end

    it 'reads a hash-argument task with block parameters inside a namespace' do
      found = definition(<<~RAKE)
        namespace :one_offs do
          desc "x"
          task toggle_accounts_flag: :environment do |_, args|
            puts args
          end
        end
      RAKE

      expect(found).to include(full_name: 'one_offs:toggle_accounts_flag', description: 'x',
                               prerequisites: %w[environment], namespace: %w[one_offs], line: 3, block_line: 3)
      expect(found[:body]).to eq("    puts args\n")
    end

    # LOS-129: a statement on the `do` line or the `end` line was outside
    # the lines between them, so the body (and every edge scanned from it)
    # lost it.
    it 'keeps a statement that shares a line with the block delimiters' do
      on_do_line = definition("task a: :environment do ::Tenant.where(active: true).find_each(&:touch)\nend\n")
      expect(on_do_line[:body]).to eq(" ::Tenant.where(active: true).find_each(&:touch)\n")

      after_params = definition("task b: :environment do |_t| ::Tenant.touch_all\n  puts 'done'\nend\n")
      expect(after_params[:body]).to eq(" ::Tenant.touch_all\n  puts 'done'\n")

      on_end_line = definition("task c: :environment do\n  ::Tenant.touch_all end\n")
      expect(on_end_line[:body]).to eq('  ::Tenant.touch_all ')

      brace = definition("task(:d) { ::Tenant.touch_all\n}\n")
      expect(brace[:body]).to eq(" ::Tenant.touch_all\n")
    end

    it 'reads a long task name with arguments and an array of prerequisites' do
      name = "backfill_#{'ledger_entry_' * 12}totals"

      expect(definition("namespace :one_offs do\n  task :#{name}, [:arg] => [:environment] do |_, args|\n  end\nend\n"))
        .to include(full_name: "one_offs:#{name}", arguments: %w[arg], prerequisites: %w[environment])
    end

    it 'marks a computed name and computed prerequisites' do
      found = definitions("%w[a b].each do |n|\n  task \"sync_\#{n}\" => deps_for(n) do\n  end\nend\n")

      expect(found.size).to eq(1)
      expect(found.first).to include(name: nil, full_name: nil, prerequisites: [], prerequisites_literal: false,
                                     block_line: 2)
    end
  end

  describe 'namespaces' do
    it 'nests symbol and string namespaces and closes them' do
      names = definitions(<<~RAKE).map { |d| d[:full_name] }
        namespace :a do
          namespace 'b' do
            task :deep
          end
          task :mid
        end
        task :top
      RAKE

      expect(names).to eq(%w[a:b:deep a:mid top])
    end

    it 'splits a colon-separated string name into scope segments' do
      expect(definition("namespace :a do\n  task 'b:c'\nend\n")).to include(full_name: 'a:b:c')
    end

    it 'leaves the full name unknown under a computed namespace' do
      expect(definition("namespace name do\n  task :a\nend\n")).to include(name: 'a', full_name: nil, namespace: [nil])
    end

    it 'is not steered by keywords in comments, strings, heredocs or shift operators' do
      names = definitions(<<~RAKE).map { |d| d[:full_name] }
        LIST = []
        LIST << WIDGET
        namespace :a do # do not end here
          task :one do
            puts "end of the road"
            puts <<~TEXT
              end
            TEXT
          end; task :two do; end
        end
        task :three
      RAKE

      expect(names).to eq(%w[a:one a:two three])
    end
  end

  describe 'descriptions' do
    it 'attaches a description to the next definition only' do
      found = definitions("desc 'First'\ntask :a\ntask :b\n")

      expect(found.map { |d| d[:description] }).to eq(['First', nil])
    end

    it 'reads heredoc and adjacent-literal descriptions' do
      expect(definition("desc <<~TEXT\n  Rebuild totals\nTEXT\ntask :a\n")[:description]).to eq("Rebuild totals\n")
      expect(definition("desc 'Rebuild ' 'totals'\ntask :a\n")[:description]).to eq('Rebuild totals')
    end

    it 'marks an interpolated description as not literal' do
      expect(definition("desc \"Sync \#{name}\"\ntask :a\n"))
        .to include(description: nil, description_literal: false)
    end
  end

  describe 'other definition kinds' do
    it 'reads multitask, file, directory and rule' do
      found = definitions(<<~RAKE)
        namespace :build do
          multitask all: %i[css js]
          file 'public/app.css' => ['app/app.scss'] do
          end
          directory 'tmp/build'
          rule '.o' => '.c' do |t|
          end
          rule(/\\.min\\.js$/ => '.js')
        end
      RAKE

      expect(found.map { |d| [d[:kind], d[:full_name], d[:prerequisites]] }).to eq(
        [
          [:multitask, 'build:all', %w[css js]],
          [:file, 'public/app.css', ['app/app.scss']],
          [:directory, 'tmp/build', []],
          [:rule, '.o', ['.c']],
          [:rule, '/\\.min\\.js$/', ['.js']]
        ]
      )
    end
  end

  describe 'task classes' do
    it 'reads a gem task class inside a conditional' do
      found = definition(<<~RAKE)
        if defined?(RSpec)
          namespace :dev do
            RSpec::Core::RakeTask.new(:docs) { |t| t.pattern = 'spec/docs/**/*_spec.rb' }
          end
        end
      RAKE

      expect(found).to include(kind: :task_class, full_name: 'dev:docs', task_class: 'RSpec::Core::RakeTask',
                               conditions: ['defined?(RSpec)'])
    end

    it 'uses the well-known default name when none is given' do
      expect(definitions("RuboCop::RakeTask.new\nRSpec::Core::RakeTask.new\n").map { |d| d[:full_name] })
        .to eq(%w[rubocop spec])
    end

    it 'leaves an unknown class without a name unresolved' do
      expect(definition("Ledger::AuditTask.new\n")).to include(task_class: 'Ledger::AuditTask', full_name: nil)
    end

    it 'records the negated condition for an else branch and an unless' do
      found = definitions(<<~RAKE)
        if Rails.env.production?
          task :a
        else
          task :b
        end
        task :c unless ENV['CI']
      RAKE

      expect(found.map { |d| d[:conditions] }).to eq(
        [['Rails.env.production?'], ['!(Rails.env.production?)'], ["!(ENV['CI'])"]]
      )
    end
  end

  describe 'enhancements' do
    it 'reads prerequisites added to an existing task' do
      found = parse("Rake::Task[\"javascript:build\"].enhance([\"i18n:js:export\"])\n").enhancements

      expect(found).to contain_exactly(
        include(target: 'javascript:build', prerequisites: ['i18n:js:export'], line: 1, block_line: nil)
      )
    end

    it 'reads an enhance block and its body facts' do
      found = parse(<<~RAKE).enhancements.first
        namespace :assets do
          Rake::Task[:precompile].enhance do
            Rake::Task['ledger:warm'].invoke
            sh 'bin/sync'
          end
        end
      RAKE

      expect(found).to include(target: 'precompile', namespace: %w[assets], prerequisites: [], block_line: 2)
      expect(found[:facts][:invocations]).to eq(['ledger:warm'])
      expect(found[:facts][:calls]).to include(name: 'sh', receiver: nil, command: 'bin/sync')
    end

    it 'accepts Rake.application as the lookup and skips a computed target' do
      found = parse("Rake.application['a'].enhance([:b])\nRake::Task[name].enhance([:c])\n").enhancements

      expect(found.map { |e| e[:target] }).to eq(['a'])
    end
  end

  describe 'body facts' do
    def facts(body)
      definition("task :a do\n#{body}\nend\n")[:facts]
    end

    it 'collects invoke and execute targets' do
      found = facts(<<~BODY)
        Rake::Task['ledger:close'].invoke(1)
        Rake::Task[:reindex].execute
        Rake.application['widgets:sync'].invoke
        Rake.application.invoke_task('shipments:export[2026]')
        Rake::Task[name].invoke
      BODY

      expect(found[:invocations]).to eq(%w[ledger:close reindex widgets:sync shipments:export])
    end

    it 'collects receiverless calls with their literal command text' do
      found = facts(<<~'BODY')
        sh 'yarn build'
        system({ 'CI' => '1' }, 'bin/check', '--fast', exception: true)
        exec_in_container "yarn run gql-codegen #{flags}"
        Shell.run('make')
        sh command
      BODY

      expect(found[:calls]).to eq(
        [
          { name: 'sh', receiver: nil, command: 'yarn build' },
          { name: 'system', receiver: nil, command: 'bin/check --fast' },
          { name: 'exec_in_container', receiver: nil, command: "yarn run gql-codegen \#{flags}" },
          { name: 'flags', receiver: nil, command: nil },
          { name: 'run', receiver: 'Shell', command: 'make' },
          { name: 'sh', receiver: nil, command: nil },
          { name: 'command', receiver: nil, command: nil }
        ]
      )
    end

    it 'collects backtick and %x commands' do
      expect(facts("`git rev-parse HEAD`\n%x(du -sh \#{dir})\n")[:commands])
        .to eq(['git rev-parse HEAD', "du -sh \#{dir}"])
    end

    it 'collects referenced constants once, outermost path only' do
      expect(facts("Ledger::Entry.count\nWidget.new\nLedger::Entry.first\n")[:constants])
        .to eq(%w[Ledger::Entry Widget])
    end
  end

  describe 'methods and constants' do
    it 'records method definitions with their facts and declared constants' do
      result = parse(<<~RUBY)
        module Ops
          module Container
            def exec_in_container(command)
              sh "docker compose exec app \#{command}"
            end

            def self.running?
              system('docker compose ps')
            end
          end
        end

        class String
          def paint; self; end
        end
      RUBY

      expect(result.constants).to eq(%w[Ops Ops::Container String])
      expect(result.method_definitions.map { |m| [m[:name], m[:facts][:calls].map { |c| c[:name] }] }).to eq(
        [['exec_in_container', %w[sh]], ['running?', %w[system]], ['paint', []]]
      )
    end
  end

  describe 'robustness' do
    it 'reads what it can from a file with a syntax error' do
      expect(definitions("task :a do\n  puts 1\nend\n\ntask :b do\n  puts(\nend\n").map { |d| d[:name] })
        .to include('a')
    end

    it 'reads a file that starts with a byte order mark' do
      expect(definition("\uFEFFnamespace :a do\n  task :b\nend\n")).to include(full_name: 'a:b')
    end

    it 'does not read task definitions inside a task body' do
      expect(definitions("task :a do\n  task :inner\nend\n").map { |d| d[:name] }).to eq(['a'])
    end
  end
end
