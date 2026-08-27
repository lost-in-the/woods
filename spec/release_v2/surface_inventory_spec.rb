# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'rake'
require 'woods/release_v2/surface_inventory'

RSpec.describe 'release-v2 public-surface inventory' do
  let(:rakefile) { File.expand_path('../../Rakefile', __dir__) }
  let(:root) { File.expand_path('../..', __dir__) }
  let(:surface_inventory) { Woods::ReleaseV2::SurfaceInventory }

  it 'provides a deterministic inventory verification task' do
    load rakefile

    expect(Rake::Task.task_defined?('release_v2:verify_surface_inventory')).to be(true)
    expect(Rake::Task['release_v2:verify_surface_inventory'].arg_names).to eq([])
    expect { Rake::Task['release_v2:verify_surface_inventory'].invoke }.not_to raise_error
  end

  it 'records an allowed disposition for every unresolved release blocker' do
    findings = JSON.parse(File.read(File.join(root, '.Codex/release-v2/findings.json'))).fetch('findings')
    allowed_dispositions = %w[fixed documented_limitation deferred_with_issue rejected_with_evidence]

    findings.each do |finding|
      expect(allowed_dispositions).to include(finding.fetch('disposition'))
      expect(finding.fetch('status')).to eq('confirmed') if finding.fetch('release_blocking')
    end
  end

  it 'rejects a drifted count in current public documentation' do
    documentation_path = File.join(root, 'docs/README.md')
    original = File.read(documentation_path)
    changed = original.sub('34 extractors', '35 extractors')
    expect(changed).not_to eq(original)

    File.write(documentation_path, changed)

    expect { surface_inventory.verify! }
      .to raise_error(Woods::ReleaseV2::SurfaceInventory::DriftError, %r{docs/README\.md})
  ensure
    File.write(documentation_path, original) if original
  end

  it 'rejects a drifted Index MCP count in the current guide' do
    documentation_path = File.join(root, 'docs/MCP_SERVERS.md')
    original = File.read(documentation_path)
    changed = original.sub('### Tools (29', '### Tools (28')
    expect(changed).not_to eq(original)

    File.write(documentation_path, changed)

    expect { surface_inventory.verify! }
      .to raise_error(Woods::ReleaseV2::SurfaceInventory::DriftError, %r{docs/MCP_SERVERS\.md})
  ensure
    File.write(documentation_path, original) if original
  end

  it 'rejects a drifted Console MCP heading count in the current guide' do
    documentation_path = File.join(root, 'docs/MCP_SERVERS.md')
    original = File.read(documentation_path)
    changed = original.sub(
      '### Tool inventory (31 schemas; 9 registered by default)',
      '### Tool inventory (30 schemas; 9 registered by default)'
    )
    expect(changed).not_to eq(original)

    File.write(documentation_path, changed)

    expect { surface_inventory.verify! }
      .to raise_error(Woods::ReleaseV2::SurfaceInventory::DriftError, /MCP_SERVERS\.md/)
  ensure
    File.write(documentation_path, original) if original
  end

  it 'rejects a drifted Console MCP default registration count in the current guide' do
    documentation_path = File.join(root, 'docs/MCP_SERVERS.md')
    original = File.read(documentation_path)
    changed = original.sub(
      '### Tool inventory (31 schemas; 9 registered by default)',
      '### Tool inventory (31 schemas; 8 registered by default)'
    )
    expect(changed).not_to eq(original)

    File.write(documentation_path, changed)

    expect { surface_inventory.verify! }
      .to raise_error(Woods::ReleaseV2::SurfaceInventory::DriftError, /MCP_SERVERS\.md/)
  ensure
    File.write(documentation_path, original) if original
  end

  it 'derives each Console executable mode from the registration contract' do
    modes = surface_inventory.inventory.fetch('console_mcp').fetch('executable_modes')

    expect(modes.fetch('embedded')).to contain_exactly(
      *Woods::Console::Server::TIER1_TOOLS.map { |name| "console_#{name}" }
    )
    expect(modes.fetch('embedded_read')).to contain_exactly(
      *Woods::Console::Server::TIER1_TOOLS.map { |name| "console_#{name}" },
      'console_sql',
      'console_query'
    )
  end

  it 'derives current guides from the documentation index' do
    guides = surface_inventory.inventory.fetch('documentation_claims').keys

    expect(guides).to include('docs/MCP_SERVERS.md')
    expect(guides).not_to include('docs/COVERAGE_GAP_ANALYSIS.md', 'docs/PG_QUERY_SPIKE.md')
  end

  it 'derives a conditional tool registration from the server implementation' do
    server_path = File.join(root, 'lib/woods/mcp/server.rb')
    original = File.read(server_path)
    changed = original.sub('if operator', 'if audit_operator')
    expect(changed).not_to eq(original)

    File.write(server_path, changed)

    condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                 .find { |tool| tool.fetch('name') == 'pipeline_extract' }
                                 .fetch('registration_condition')

    expect(condition.fetch('call_site_guard')).to eq('audit_operator')
  ensure
    File.write(server_path, original) if original
  end

  it 'derives predicate logic from the server implementation' do
    server_path = File.join(root, 'lib/woods/mcp/server.rb')
    original = File.read(server_path)
    changed = original.sub('!token.nil? && ids && !ids.empty?', '!token.nil? && ids && ids.any?')
    expect(changed).not_to eq(original)

    File.write(server_path, changed)

    condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                 .find { |tool| tool.fetch('name') == 'notion_sync' }
                                 .fetch('registration_condition')

    expect(condition.fetch('predicate_logic')).to include('ids.any?')
  ensure
    File.write(server_path, original) if original
  end

  it 'derives internal registration guards from the server implementation' do
    server_path = File.join(root, 'lib/woods/mcp/server.rb')
    original = File.read(server_path)
    registration = 'define_pipeline_extract_tool(server, operator, respond, respond_err, op_missing, task_store)'
    changed = original.sub(registration, "#{registration} if pipeline_enabled?")
    expect(changed).not_to eq(original)

    File.write(server_path, changed)

    condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                 .find { |tool| tool.fetch('name') == 'pipeline_extract' }
                                 .fetch('registration_condition')

    expect(condition.fetch('internal_guards')).to include('pipeline_enabled?')
  ensure
    File.write(server_path, original) if original
  end

  it 'derives block registration guards from the complete helper source' do
    server_path = File.join(root, 'lib/woods/mcp/server.rb')
    original = File.read(server_path)
    registration = 'define_pipeline_extract_tool(server, operator, respond, respond_err, op_missing, task_store)'
    changed = original.sub(registration, "if pipeline_enabled?\n            #{registration}\n          end")
    expect(changed).not_to eq(original)

    File.write(server_path, changed)

    condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                 .find { |tool| tool.fetch('name') == 'pipeline_extract' }
                                 .fetch('registration_condition')

    expect(condition.fetch('registration_logic')).to include('if pipeline_enabled?')
  ensure
    File.write(server_path, original) if original
  end

  it 'captures callable predicate arguments in the registration condition contract' do
    server_path = File.join(root, 'lib/woods/mcp/server.rb')
    original = File.read(server_path)
    changed = original.sub('if notion_wired?', 'if notion_wired?(strict: true)')
    expect(changed).not_to eq(original)

    original_condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                          .find { |tool| tool.fetch('name') == 'notion_sync' }
                                          .fetch('registration_condition')

    File.write(server_path, changed)

    changed_condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                         .find { |tool| tool.fetch('name') == 'notion_sync' }
                                         .fetch('registration_condition')

    expect(changed_condition).not_to eq(original_condition)
    expect(changed_condition.fetch('call_site_guard')).to eq('notion_wired?(strict: true)')
    expect(changed_condition.fetch('predicate_definitions').fetch('notion_wired?')).to include('def notion_wired?')
  ensure
    File.write(server_path, original) if original
  end

  it 'derives vector-store adapters from the builder implementation' do
    builder_path = File.join(root, 'lib/woods/builder.rb')
    original = File.read(builder_path)
    changed = original.sub('when :qdrant', 'when :audit_vector')
    expect(changed).not_to eq(original)

    File.write(builder_path, changed)

    expect(surface_inventory.inventory.fetch('adapters').fetch('vector_stores')).to include('audit_vector')
  ensure
    File.write(builder_path, original) if original
  end

  it 'derives exporter availability from exporter implementations' do
    exporter_path = File.join(root, 'lib/woods/obsidian/vault_exporter.rb')
    original = File.read(exporter_path)
    changed = original.sub('class VaultExporter', 'class AuditVaultExporter')
    expect(changed).not_to eq(original)

    File.write(exporter_path, changed)

    exporter = surface_inventory.inventory.fetch('adapters').fetch('exporters')
                                .find { |entry| entry.fetch('name') == 'obsidian' }

    expect(exporter.fetch('class')).to eq('Woods::Obsidian::AuditVaultExporter')
  ensure
    File.write(exporter_path, original) if original
  end

  it 'inventories the surface under a US-ASCII default external encoding' do
    require 'open3'
    require 'rbconfig'
    # Inventoried sources legitimately contain multibyte comment characters;
    # a bare Pathname#read under LANG=C tags them US-ASCII and the regex
    # scans raise ArgumentError, so the verify task crashes in any C-locale
    # environment (plain containers, launchd, this repo's own canary rule).
    script = 'require "woods/release_v2/surface_inventory"; ' \
             'Woods::ReleaseV2::SurfaceInventory.inventory; print "ok"'
    stdout, stderr, status = Open3.capture3(
      { 'LANG' => 'C', 'LC_ALL' => 'C' },
      RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script,
      chdir: root
    )

    expect(status).to be_success, stderr
    expect(stdout).to eq('ok')
  end
end
