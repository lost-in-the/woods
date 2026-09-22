# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../../script/typesafe/review_packet'

RSpec.describe WoodsDevelopment::TypeSafe::ReviewPacket do
  let(:root) { @temporary.join('source') }
  let(:index_root) { @temporary.join('index') }
  let(:payload) { index_root.join('payloads/gen-1') }
  let(:invalid) { WoodsDevelopment::TypeSafe::InvalidEvidence }
  let(:model_path) { 'app/models/shared.rb' }
  let(:service_path) { 'app/services/shared.rb' }
  let(:test_path) { 'spec/models/café_spec.rb' }
  let(:test_content) do
    "RSpec.describe Shared do\r\n  it 'persists' do\r\n    perform\r\n    expect(result).to eq('雪')\r\n  end\r\nend"
  end
  let(:manifest) do
    { 'schema_version' => 1, 'evidence' => [
      materialize(model_path, 'class Shared; end'),
      materialize(service_path, 'class Shared; def call; end; end'),
      materialize(test_path, test_content)
    ] }
  end

  around do |example|
    Dir.mktmpdir('woods-review-packet') do |dir|
      @temporary = Pathname.new(dir)
      root.mkpath
      payload.mkpath
      build_index
      example.run
    end
  end

  def write_json(path, value)
    path.dirname.mkpath
    path.binwrite(JSON.generate(value))
  end

  def materialize(path, content)
    target = root.join(path)
    target.dirname.mkpath
    target.binwrite(content)
    { 'evidence_id' => path, 'path' => path, 'sha256' => Digest::SHA256.hexdigest(content) }
  end

  def unit_path(type, identifier = 'Shared')
    directory = type == 'gem_source' ? 'rails_source' : "#{type}s"
    payload.join(directory, "#{identifier}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json")
  end

  def build_index
    write_json(index_root.join('generation.json'), 'number' => 1, 'payload' => 'payloads/gen-1', 'token' => 'first')
    write_json(payload.join('manifest.json'), 'woods_version' => '2.0.0.beta2', 'git_sha' => 'unknown')
    { 'model' => model_path, 'service' => service_path }.each do |type, path|
      unit = { 'identifier' => 'Shared', 'type' => type, 'file_path' => path,
               'source_code' => "indexed #{type} source with inlined concern", 'metadata' => { 'sentinel' => type } }
      write_json(unit_path(type), unit)
      write_json(unit_path(type).dirname.join('_index.json'), [unit.slice('identifier', 'file_path')])
    end
    write_json(payload.join('dependency_graph.json'), {
                 'nodes' => { 'Shared' => { 'type' => 'model', 'file_path' => model_path } },
                 'edges' => { 'Shared' => [{ 'target' => 'Record', 'via' => 'belongs_to' }] },
                 'variants' => [{ 'identifier' => 'Shared', 'type' => 'service', 'file_path' => service_path,
                                  'edges' => [{ 'target' => 'Worker', 'via' => 'code_reference' }] }],
                 'file_map' => { model_path => ['Shared'], service_path => ['Shared'] }
               })
  end

  def build(selection = manifest)
    described_class.build(root: root, index_dir: index_root, manifest: selection)
  end

  it 'preserves complete files, Unicode paths, assertion tails, CRLF and a missing final newline' do
    packet = build

    expect(packet.fetch('evidence').last).to include('path' => test_path, 'content' => test_content)
    expect(packet.fetch('evidence').map { |row| row.fetch('sha256') })
      .to eq(manifest.fetch('evidence').map { |row| row.fetch('sha256') })
    expect(packet.fetch('evidence').last.fetch('unit_keys')).to eq([])
    expect(packet.fetch('unmapped_paths')).to eq([test_path])
  end

  it 'retains both typed identities and their distinct outgoing edges and indexed source' do
    units = build.fetch('units')

    expect(units.map { |unit| [unit.fetch('identifier'), unit.fetch('type')] })
      .to eq([%w[Shared model], %w[Shared service]])
    expect(units.map { |unit| unit.fetch('edges').first.fetch('target') }).to eq(%w[Record Worker])
    expect(units.map { |unit| unit.fetch('data').fetch('metadata').fetch('sentinel') }).to eq(%w[model service])
    units.each do |unit|
      expect(unit.fetch('data_sha256')).to eq(Digest::SHA256.hexdigest(JSON.generate(unit.fetch('data'))))
    end
  end

  it 'records pinned artifact hashes and explicit limits on provenance and test context' do
    packet = build

    expect(packet.fetch('source_lineage')).to eq('unverified')
    expect(packet.fetch('test_context')).to eq('explicit_files_only')
    expect(packet.fetch('index')).to include(
      'generation' => 1,
      'manifest_sha256' => Digest::SHA256.file(payload.join('manifest.json')).hexdigest,
      'graph_sha256' => Digest::SHA256.file(payload.join('dependency_graph.json')).hexdigest,
      'manifest' => { 'woods_version' => '2.0.0.beta2', 'git_sha' => 'unknown' }
    )
  end

  it 'does not silently drop graph units with missing payload files' do
    unit_path('service').delete
    units = build.fetch('units')

    expect(units.size).to eq(2)
    expect(units.last).to include('unit_status' => 'unavailable', 'data' => nil, 'data_sha256' => nil)
  end

  it 'rejects a unit whose actual identity disagrees with the selected graph identity' do
    write_json(unit_path('service'), 'identifier' => 'Other', 'type' => 'service')

    expect { build }.to raise_error(invalid, /identity/)
  end

  it 'keeps gem_source identity when its native locator is rails_source' do
    write_json(unit_path('gem_source'), 'identifier' => 'Shared', 'type' => 'gem_source', 'source_code' => 'gem bytes')
    write_json(unit_path('gem_source').dirname.join('_index.json'), [{ 'identifier' => 'Shared' }])
    write_json(payload.join('dependency_graph.json'), {
                 'nodes' => { 'Shared' => { 'type' => 'gem_source', 'file_path' => model_path } },
                 'edges' => {}, 'file_map' => { model_path => ['Shared'] }
               })

    expect(build.fetch('units').first).to include('type' => 'gem_source', 'unit_status' => 'present')
  end

  it 'rejects stale selected bytes rather than supplying a partial packet' do
    selection = manifest
    root.join(model_path).binwrite('changed since selection')

    expect { build(selection) }.to raise_error(invalid, /SHA-256 mismatch/)
  end

  it 'does not switch to a new generation halfway through the export' do
    second = index_root.join('payloads/gen-2')
    FileUtils.cp_r(payload, second)
    write_json(second.join('manifest.json'), 'woods_version' => 'different')
    allow(Woods::PublishedIndex).to receive(:open).and_wrap_original do |original, *args, **kwargs, &block|
      original.call(*args, **kwargs) do |index|
        write_json(index_root.join('generation.json'), 'number' => 2, 'payload' => 'payloads/gen-2',
                                                       'token' => 'second')
        block.call(index)
      end
    end

    expect(build.fetch('index')).to include('generation' => 1, 'manifest' => { 'woods_version' => '2.0.0.beta2',
                                                                               'git_sha' => 'unknown' })
  end

  it 'rejects flat legacy indexes because they do not provide an atomic snapshot' do
    selection = manifest

    expect { described_class.build(root: root, index_dir: payload, manifest: selection) }
      .to raise_error(invalid, /numbered generation/)
  end

  it 'rejects a missing graph instead of treating it as zero coverage' do
    payload.join('dependency_graph.json').delete

    expect { build }.to raise_error(invalid)
  end

  it 'rejects excessive serialized packet bytes without trimming any evidence' do
    stub_const('WoodsDevelopment::TypeSafe::ReviewPacket::MAX_PACKET_BYTES', 100)

    expect { build }.to raise_error(invalid, /packet byte limit/)
  end

  it 'does not change caller input and produces repeatable packet bytes' do
    selection = manifest
    original = Marshal.load(Marshal.dump(selection))

    expect(JSON.generate(build(selection))).to eq(JSON.generate(build(selection)))
    expect(selection).to eq(original)
  end

  describe 'standalone CLI' do
    let(:script) { File.expand_path('../../../script/typesafe/export_review_packet.rb', __dir__) }
    let(:selection_file) { @temporary.join('selection.json') }

    it 'exports valid JSON offline without requiring Rails or credentials' do
      write_json(selection_file, manifest)
      stdout, stderr, status = Open3.capture3('ruby', script, root.to_s, index_root.to_s, selection_file.to_s)

      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch('units').size).to eq(2)
      expect(stderr).to eq('')
    end

    it 'fails without printing source bytes or a partial JSON packet' do
      write_json(selection_file, manifest)
      root.join(model_path).binwrite('secret marker not for stderr')
      stdout, stderr, status = Open3.capture3('ruby', script, root.to_s, index_root.to_s, selection_file.to_s)

      expect(status.exitstatus).to eq(2)
      expect(stdout).to eq('')
      expect(stderr).not_to include('secret marker')
    end

    it 'preserves Unicode content when Ruby defaults to US-ASCII' do
      write_json(selection_file, manifest)
      stdout, stderr, status = Open3.capture3('ruby', '-EUS-ASCII', script, root.to_s,
                                              index_root.to_s, selection_file.to_s)

      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch('evidence').last.fetch('content')).to eq(test_content)
    end
  end
end
