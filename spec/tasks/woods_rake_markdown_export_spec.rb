# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# Subprocess fixtures in the woods_rake_error_exit_code_spec style: a throwaway
# Rakefile loads the real lib/tasks/woods.rake and swaps the exporters for
# recorders, so the specs see which flavor and path each task asked for.
RSpec.describe 'woods:markdown and the deprecated export tasks' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_tasks(task_names, fixture, env: {})
    Dir.mktmpdir('woods-markdown-task') do |dir|
      rakefile = File.join(dir, 'Rakefile')
      File.write(rakefile, <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        require 'woods'

        module Rails
          def self.version = '8.0.0'
          def self.root = Pathname.new(#{dir.inspect})
        end

        task :environment
        load #{File.join(root, 'lib/tasks/woods.rake').inspect}

        #{fixture}
      RUBY

      base = { 'WOODS_IGNORE_WATCH' => '1', 'WOODS_OUTPUT' => File.join(dir, 'index') }
      Open3.capture3(base.merge(env), RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', rakefile,
                     *Array(task_names), chdir: dir)
    end
  end

  let(:markdown_fixture) do
    <<~RUBY
      require 'woods/obsidian/vault_exporter'
      class Woods::Obsidian::VaultExporter
        def initialize(index_dir:, vault_path:, include_source:, include_framework:, force_purge:, obsidian:)
          puts "EXPORTER obsidian=\#{obsidian} dir=\#{File.basename(vault_path)} source=\#{include_source}"
        end
        def export_all = { exported: 2, indexes: 1, swept: 0, skipped: 0, errors: [] }
      end
    RUBY
  end

  describe 'woods:markdown' do
    it 'exports plain Markdown by default without any deprecation notice' do
      out, err, status = run_tasks('woods:markdown', markdown_fixture)
      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include('EXPORTER obsidian=false dir=markdown')
      expect(out).not_to include('Obsidian')
      expect(err).not_to include('DEPRECATED')
    end

    it 'opts into the Obsidian flavor with WOODS_MARKDOWN_OBSIDIAN' do
      out, err, status = run_tasks('woods:markdown', markdown_fixture, env: { 'WOODS_MARKDOWN_OBSIDIAN' => '1' })
      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include('EXPORTER obsidian=true')
    end

    it 'reads WOODS_MARKDOWN_INCLUDE_SOURCE' do
      out, = run_tasks('woods:markdown', markdown_fixture, env: { 'WOODS_MARKDOWN_INCLUDE_SOURCE' => '1' })
      expect(out).to include('source=true')
    end
  end

  %w[woods:obsidian woods:vault].each do |name|
    describe name do
      it 'still exports the Obsidian vault and warns pointing at woods:markdown' do
        out, err, status = run_tasks(name, markdown_fixture)
        expect(status).to be_success, "#{out}\n#{err}"
        expect(out).to include('EXPORTER obsidian=true dir=obsidian_vault')
        expect(err).to include('DEPRECATED', 'woods:markdown')
      end

      it 'warns once per process' do
        task = "Rake::Task[#{name.inspect}]"
        fixture = "#{markdown_fixture}\n2.times { #{task}.reenable; #{task}.invoke }"
        _out, err, = run_tasks(name, fixture)
        expect(err.scan('DEPRECATED').size).to eq(1)
      end

      it 'honours the legacy WOODS_OBSIDIAN_* variables' do
        out, = run_tasks(name, markdown_fixture, env: { 'WOODS_OBSIDIAN_INCLUDE_SOURCE' => 'true' })
        expect(out).to include('source=true')
      end
    end
  end
end
