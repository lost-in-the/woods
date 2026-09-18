# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/verifier'

RSpec.describe Woods::SourceInputs::Verifier do
  around do |example|
    Dir.mktmpdir('woods-source-verify') do |root|
      @root = root
      @output = File.join(root, 'index')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      example.run
    end
  end

  def write(path, bytes)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, bytes)
  end

  def snapshot
    Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key).call
  end

  def manifest(capture = snapshot, boot_verified: true)
    scopes = capture.fetch('scope_paths').transform_values do |paths|
      paths.to_h { |path| [path, capture.fetch('files').fetch(path)] }
    end
    Woods::SourceInputs::Manifest.build(snapshot: capture, scopes: scopes, boot_verified: boot_verified, generation: 1)
  end

  def verify(baseline, **options)
    described_class.new(manifest: baseline, output_dir: @output, **options).call
  end

  it 'certifies a captured dirty tree by content rather than requiring a clean checkout' do
    write('app/services/pay.rb', 'already dirty source')
    baseline = manifest
    expect(verify(baseline)).to include('state' => 'current', 'mode' => 'content', 'complete' => true)
    write('app/services/pay.rb', 'another dirty version')
    result = verify(baseline)
    expect(result['state']).to eq('drifted')
    expect(result['changes']['changed']).to eq(['app/services/pay.rb'])
  end

  it 'detects additions and deletions, including newly appearing input scopes' do
    write('app/services/pay.rb', 'original')
    baseline = manifest
    FileUtils.rm(File.join(@root, 'app/services/pay.rb'))
    write('config/locales/en.yml', 'en: {}')
    result = verify(baseline)
    expect(result['state']).to eq('drifted')
    expect(result['changes']).to include('added' => ['config/locales/en.yml'], 'removed' => ['app/services/pay.rb'])
  end

  it 'does not let an event scan bless the retained identity of an omitted dirty service' do
    path = 'app/services/omitted.rb'
    write(path, 'original')
    baseline = manifest
    write(path, 'changed')
    current = snapshot
    scopes = baseline.expanded
    scopes.fetch('whole:events')[path] = current.fetch('files').fetch(path)
    mixed = Woods::SourceInputs::Manifest.build(snapshot: current, scopes: scopes, boot_verified: true, generation: 2)
    result = verify(mixed)
    expect(result['state']).to eq('drifted')
    expect(result['changes']['changed']).to eq([path])
    expect(mixed.expanded.fetch('file:services')[path]).to eq(baseline.expanded.fetch('file:services')[path])
  end

  it 'qualifies a post-boot capture as unknown even when all bytes agree' do
    write('app/services/pay.rb', 'original')
    result = verify(manifest(boot_verified: false))
    expect(result['state']).to eq('unknown')
    expect(result['reasons']).to include('unverified_boot_boundary')
  end

  it 'requires source visibility and the original private key' do
    write('app/services/pay.rb', 'original')
    baseline = manifest
    expect(verify(baseline, root: File.join(@root, 'missing'))['reasons']).to eq(['source_root_unavailable'])
    FileUtils.rm(File.join(@output, Woods::SourceInputs::PrivateKey::FILE_NAME))
    expect(verify(baseline)['reasons']).to eq(['identity_key_unavailable'])
    Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
    expect(verify(baseline)['reasons']).to eq(['identity_key_mismatch'])
  end

  it 'pins the manifest to the served generation' do
    expect(verify(manifest, generation: 2)['reasons']).to eq(['generation_mismatch'])
  end

  it 'returns unknown when byte verification exhausts its budget' do
    write('app/services/pay.rb', 'x' * 100)
    result = verify(manifest, max_bytes: 1)
    expect(result['state']).to eq('unknown')
    expect(result['complete']).to be(false)
    expect(result['reasons']).to include('scan_byte_budget')
  end

  it 'bounds and sorts summaries independently of drift state' do
    baseline = manifest
    40.times { |i| write("app/services/pay_#{i}.rb", 'added') }
    result = verify(baseline)
    expect(result).to include('state' => 'drifted', 'truncated' => true)
    expect(result['counts']['added']).to eq(40)
    expect(result['changes']['added'].size).to eq(30)
    expect(result['changes']['added']).to eq(result['changes']['added'].sort)
  end

  it 'rejects corrupted identity references and coverage fields' do
    write('app/services/pay.rb', 'source')
    baseline = manifest.data
    broken = Marshal.load(Marshal.dump(baseline))
    broken['scopes'].values.first['app/services/pay.rb'] = 999
    expect { Woods::SourceInputs::Manifest.new(broken) }.to raise_error(Woods::SourceInputs::Manifest::Invalid)
    broken = baseline.merge('errors' => [123])
    expect { Woods::SourceInputs::Manifest.new(broken) }.to raise_error(Woods::SourceInputs::Manifest::Invalid)
  end
end
