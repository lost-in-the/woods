# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'rake'

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

  it 'derives a conditional tool registration from the server implementation' do
    server_path = File.join(root, 'lib/woods/mcp/server.rb')
    original = File.read(server_path)
    changed = original.sub('if operator', 'if audit_operator')
    expect(changed).not_to eq(original)

    File.write(server_path, changed)

    condition = surface_inventory.inventory.fetch('index_mcp').fetch('tools')
                                 .find { |tool| tool.fetch('name') == 'pipeline_extract' }
                                 .fetch('registration_condition')

    expect(condition).to eq('audit_operator')
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
end
