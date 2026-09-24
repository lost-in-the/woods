# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'openssl'
require 'timeout'
require 'woods/source_inputs/scanner'

RSpec.describe Woods::SourceInputs::Scanner do
  around do |example|
    Dir.mktmpdir('woods-source') do |root|
      @root = root
      @output = File.join(root, 'index')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      example.run
    end
  end

  def write(path, content)
    target = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, content)
    target
  end

  def scan(**limits)
    described_class.new(root: @root, output_dir: @output, key: @key, **limits).call
  end

  it 'captures shared input scopes without booting a Rails application' do
    write('app/services/pay.rb', 'class Pay; end')
    write('config/locales/en.yml', 'en: {}')
    write('docs/README.md', 'unrelated')
    result = scan
    expect(result['complete']).to be(true)
    expect(result['files'].keys).to eq(%w[app/services/pay.rb config/locales/en.yml])
    expect(result['scope_paths']).to include(
      'file:services' => ['app/services/pay.rb'], 'whole:events' => ['app/services/pay.rb'],
      'runtime' => ['app/services/pay.rb'], 'file:i18n' => ['config/locales/en.yml']
    )
  end

  it 'covers launcher boot files and declared roots while retaining generated-directory exclusions' do
    paths = %w[Rakefile config.ru application.gemspec config/application_config.rb .custom/loader.rb]
    paths.each { |path| write(path, 'input') }
    write('.agents/skills/noise.rb', 'ignored')
    rules = Woods::SourceInputs::Scopes.new(extra_roots: ['.custom'])
    result = described_class.new(root: @root, output_dir: @output, key: @key, scopes: rules).call
    expect(result['files'].keys).to eq(paths.sort)
    expect(result['scope_paths']['boot']).to eq((paths - ['.custom/loader.rb']).sort)
    expect(result['scope_paths']['declared']).to eq(['.custom/loader.rb'])
  end

  it 'uses keyed identities for every file, including low entropy secrets' do
    write('.env', 'SECRET=1234')
    result = scan
    digest = result['files'].fetch('.env')
    expect(digest).to eq(OpenSSL::HMAC.hexdigest('SHA256', @key.bytes, 'SECRET=1234'))
    expect(digest).not_to eq(Digest::SHA256.hexdigest('SECRET=1234'))
    expect(JSON.generate(result)).not_to include('SECRET=1234', @key.bytes.unpack1('H*'))
    expect(result['scope_paths']['boot']).to eq(['.env'])
  end

  it 'detects repeated same-size same-mtime rewrites through bytes' do
    path = write('app/services/pay.rb', 'version1')
    first = scan
    timestamp = File.mtime(path)
    File.binwrite(path, 'version2')
    File.utime(timestamp, timestamp, path)
    expect(scan['files']).not_to eq(first['files'])
  end

  it 'prunes the index itself and normal generated directories before scanning contents' do
    write('tmp/deep/app/services/not_input.rb', 'generated')
    write('index/app/services/not_input.rb', 'generated')
    write('app/services/pay.rb', 'input')
    result = scan
    expect(result['files'].keys).to eq(['app/services/pay.rb'])
    expect(result['metrics']['visited_files']).to eq(1)
  end

  it 'reports incomplete coverage instead of following a symlink directory blindly' do
    write('app/services/pay.rb', 'input')
    File.symlink(File.join(@root, 'app/services'), File.join(@root, 'app/linked'))
    result = scan
    expect(result['complete']).to be(false)
    expect(result['errors']).to include('reason' => 'unverified_symlink_directory', 'path' => 'app/linked')
  end

  it 'does not accept an external target swapped in after containment was checked' do
    inside = write('app/services/z_inside.rb', 'inside')
    link = File.join(@root, 'app/services/a_link.rb')
    File.symlink(inside, link)
    Dir.mktmpdir('woods-external') do |outside|
      foreign = File.join(outside, 'foreign.rb')
      File.write(foreign, 'external')
      original = File.method(:open)
      allow(File).to receive(:open).and_wrap_original do |_method, path, *args, &block|
        if [inside, link].include?(path) && File.readlink(link) == inside
          File.unlink(link)
          File.symlink(foreign, link)
        end
        original.call(path, *args, &block)
      end
      result = scan
      expect(result['complete']).to be(false)
      expect(result['files']).not_to have_key('app/services/a_link.rb')
    end
  end

  it 'handles spaces, commas and newlines without path splitting' do
    path = "app/services/a b,c\nd.rb"
    write(path, 'input')
    expect(scan['files'].keys).to eq([path])
  end

  %w[app/services public/uploads].each do |directory|
    it "records incomplete evidence for a byte-invalid filename in #{directory}" do
      write("#{directory}/bad_".b + "\xFF.rb".b, 'input')
      write('app/services/good.rb', 'input')
      result = scan
      expect(result['complete']).to be(false)
      expect(result['files'].keys).to eq(['app/services/good.rb'])
      error = result['errors'].find { |item| item['reason'] == 'undecodable_source_path' }
      expect(error.fetch('path')).to include('bad_', '\\xFF')
      expect(JSON.parse(JSON.generate(result))['complete']).to be(false)
    end
  end

  it 'prunes undecodable directories and bounds path diagnostics and traversal' do
    directory = "app/services/#{'x' * 200}/".b + ('x' * 230).b + "\xFF".b
    write(File.join(directory, 'child.rb'), 'input')
    allow(File).to receive(:lstat).and_call_original
    result = scan
    expect(File).not_to have_received(:lstat).with(a_string_ending_with('/child.rb'))
    expect(result['complete']).to be(false)
    expect(result['errors'].first.fetch('path').bytesize).to be <= 1030
    expect(result['errors'].first.fetch('path')).to end_with('...')
    expect(JSON.parse(JSON.generate(result))['complete']).to be(false)
    expect(result['files']).to be_empty
  end

  it 'counts undecodable entries against the file budget and caps their diagnostics' do
    25.times { |index| write("public/uploads/#{index}_".b + "\xFF".b, 'input') }
    result = scan
    expect(result['complete']).to be(false)
    expect(result['errors'].size).to eq(20)
    expect(result['metrics']['visited_files']).to eq(25)
    expect(scan(max_files: 1)['errors']).to include('reason' => 'scan_file_budget')
  end

  it 'returns explicit file and byte budget errors' do
    write('app/services/pay.rb', 'a' * 100)
    write('app/services/order.rb', 'b' * 100)
    expect(scan(max_files: 1)['errors']).to include('reason' => 'scan_file_budget')
    expect(scan(max_bytes: 1)['errors']).to include('reason' => 'scan_byte_budget')
  end

  it 'refuses invalid budget values' do
    [0, -1, Float::INFINITY, Float::NAN, '1'].each do |value|
      expect { scan(max_seconds: value) }.to raise_error(ArgumentError)
    end
  end

  it 'does not acknowledge bytes that change while they are read' do
    path = write('app/services/pay.rb', 'a' * 40_000)
    original = File.method(:stat)
    calls = 0
    allow(File).to receive(:stat) do |target|
      calls += 1 if target == path
      File.binwrite(path, 'b' * 40_000) if target == path && calls == 2
      original.call(target)
    end
    result = scan
    expect(result['complete']).to be(false)
    expect(result['files']).to be_empty
    expect(result['errors']).to include('reason' => 'source_changed_during_read', 'path' => 'app/services/pay.rb')
  end
end

RSpec.describe Woods::SourceInputs::PrivateKey do
  it 'creates a private stable key outside generation payloads' do
    Dir.mktmpdir('woods-key') do |output|
      key = described_class.new(output_dir: output, create: true)
      again = described_class.new(output_dir: output, create: true)
      expect(again.bytes).to eq(key.bytes)
      expect(File.stat(File.join(output, described_class::FILE_NAME)).mode & 0o777).to eq(0o600)
    end
  end

  it 'refuses a FIFO key without blocking before validation' do
    Dir.mktmpdir('woods-key') do |output|
      path = File.join(output, described_class::FILE_NAME)
      File.mkfifo(path, 0o600)
      Timeout.timeout(1) do
        expect { described_class.new(output_dir: output) }.to raise_error(described_class::Unavailable)
      end
    end
  end

  it 'never repairs or trusts an insecure existing key' do
    Dir.mktmpdir('woods-key') do |output|
      path = File.join(output, described_class::FILE_NAME)
      File.binwrite(path, 'x' * 32)
      File.chmod(0o644, path)
      expect { described_class.new(output_dir: output, create: true) }
        .to raise_error(described_class::Unavailable, 'insecure_identity_key')
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end
  end

  it 'reports a missing key without creating one on the reader path' do
    Dir.mktmpdir('woods-key') do |output|
      expect { described_class.new(output_dir: output) }
        .to raise_error(described_class::Unavailable, 'identity_key_unavailable')
      expect(Dir.children(output)).to be_empty
    end
  end
end
