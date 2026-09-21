# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'
require_relative '../../../script/typesafe/evidence'

RSpec.describe WoodsDevelopment::TypeSafe::Evidence do
  let(:temporary) { Dir.mktmpdir('woods-evidence') }
  let(:root) { Pathname.new(temporary).join('root') }
  let(:entry) { materialize("original\r\n雪\nlast") }
  let(:manifest) { { 'schema_version' => 1, 'evidence' => [entry] } }
  let(:invalid_evidence) { WoodsDevelopment::TypeSafe::InvalidEvidence }

  before { root.mkpath }
  after { FileUtils.remove_entry(temporary) }

  def materialize(content, path: 'materialized/example.rb', id: 'example-one')
    target = root.join(path)
    target.dirname.mkpath
    File.binwrite(target, content)
    { 'evidence_id' => id, 'path' => path, 'sha256' => Digest::SHA256.hexdigest(content) }
  end

  def read_evidence(root: self.root, manifest: self.manifest)
    described_class.read(root: root, manifest: manifest)
  end

  it 'preserves manifest order and exact UTF-8 bytes, including empty files and no final newline' do
    first = materialize("雪\r\nsecond\nlast", path: 'any extension.data', id: 'z-last')
    second = materialize('', path: 'empty', id: 'a-first')
    manifest['evidence'] = [first, second]

    expect(read_evidence).to eq([
                                  first.merge('content' => "雪\r\nsecond\nlast"),
                                  second.merge('content' => '')
                                ])
    expect(read_evidence.map { |row| row.fetch('content').encoding }).to eq([Encoding::UTF_8] * 2)
  end

  it 'copies metadata without mutating or freezing caller objects' do
    entry.transform_values!(&:dup)
    original = Marshal.load(Marshal.dump(manifest))
    row = read_evidence.first

    expect(manifest).to eq(original)
    expect(row).not_to equal(entry)
    entry.each do |key, value|
      expect(row.fetch(key)).not_to equal(value)
      expect(value).not_to be_frozen
      row.fetch(key).replace('changed')
    end
    expect(manifest).to eq(original)
    expect(manifest).not_to be_frozen
    expect(manifest.fetch('evidence')).not_to be_frozen
    expect(entry).not_to be_frozen
  end

  it 'accepts a deeply frozen manifest' do
    entry.each_value(&:freeze)
    entry.freeze
    manifest.fetch('evidence').freeze
    manifest.freeze

    expect(read_evidence.first.fetch('content')).to eq("original\r\n雪\nlast")
  end

  it 'accepts ASCII-compatible string tags when the unchanged bytes are UTF-8' do
    entry['evidence_id'] = '証拠'.b
    entry['path'] = entry.fetch('path').encode(Encoding::US_ASCII)
    entry['sha256'] = entry.fetch('sha256').b
    encodings = entry.transform_values(&:encoding)

    row = read_evidence.first
    entry.each do |key, value|
      expect(row.fetch(key)).to eq(value)
      expect(row.fetch(key).encoding).to eq(value.encoding)
    end
    expect(entry.transform_values(&:encoding)).to eq(encodings)
  end

  it 'rejects duplicate IDs even when the same UTF-8 bytes have different encoding tags' do
    entry['evidence_id'] = '証拠'
    manifest['evidence'] << entry.merge('evidence_id' => '証拠'.b)

    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  it 'allows a repeated path for distinct IDs' do
    manifest['evidence'] << entry.merge('evidence_id' => 'second')

    expect(read_evidence.map { |row| row.fetch('content') }).to eq(["original\r\n雪\nlast"] * 2)
  end

  [nil, [], 'manifest', {}, { schema_version: 1, evidence: [] }].each do |invalid|
    it "rejects malformed manifest #{invalid.inspect}" do
      expect { read_evidence(manifest: invalid) }.to raise_error(invalid_evidence)
    end
  end

  [nil, '1', 1.0, true, 0, 2].each do |invalid|
    it "rejects schema version #{invalid.inspect}" do
      manifest['schema_version'] = invalid
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  [nil, {}, 'entries', []].each do |invalid|
    it "rejects invalid evidence array #{invalid.inspect}" do
      manifest['evidence'] = invalid
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'accepts 100 entries and rejects 101' do
    empty = materialize('', path: 'empty')
    manifest['evidence'] = Array.new(100) { |index| empty.merge('evidence_id' => index.to_s) }
    expect(read_evidence.length).to eq(100)

    manifest['evidence'] << empty.merge('evidence_id' => 'one-too-many')
    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  it 'rejects unknown and symbol manifest keys' do
    ['extra', :schema_version].each do |key|
      expect { read_evidence(manifest: manifest.merge(key => 1)) }.to raise_error(invalid_evidence)
    end
  end

  [nil, [], 'entry', {}, { evidence_id: 'one', path: 'file', sha256: '0' * 64 }].each do |invalid|
    it "rejects malformed entry #{invalid.inspect}" do
      manifest['evidence'] = [invalid]
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'rejects each missing entry field' do
    entry.each_key do |key|
      invalid = entry.reject { |candidate, _| candidate == key }
      expect { read_evidence(manifest: manifest.merge('evidence' => [invalid])) }.to raise_error(invalid_evidence)
    end
  end

  it 'rejects unknown and symbol entry keys' do
    ['content', :path].each do |key|
      invalid = entry.merge(key => 'unexpected')
      expect { read_evidence(manifest: manifest.merge('evidence' => [invalid])) }.to raise_error(invalid_evidence)
    end
  end

  [nil, 1, '', " \t\r\n", "\u00a0\u3000", "\xFF".b].each do |invalid|
    it "rejects invalid evidence ID #{invalid.inspect}" do
      entry['evidence_id'] = invalid
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  %w[evidence_id path sha256].each do |field|
    [Encoding::UTF_16LE, Encoding::UTF_32BE].each do |encoding|
      it "rejects #{encoding} tagged #{field} without changing it" do
        entry[field] = entry.fetch(field).encode(encoding)
        original = entry.fetch(field).dup
        expect { read_evidence }.to raise_error(invalid_evidence)
        expect(entry.fetch(field)).to eq(original)
        expect(entry.fetch(field).encoding).to eq(encoding)
      end
    end
  end

  [nil, 1, '0' * 63, '0' * 65, 'A' * 64, 'g' * 64, "#{'0' * 64}\n"].each do |invalid|
    it "rejects invalid digest #{invalid.inspect}" do
      entry['sha256'] = invalid
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'rejects a later mismatching digest and exposes no partial result or evidence in the message' do
    secret = 'PRIVATE EVIDENCE BODY'
    second = materialize(secret, path: 'second')
    second['sha256'] = '0' * 64
    manifest['evidence'] << second
    result = :not_returned

    expect { result = read_evidence }.to raise_error(invalid_evidence) { |error|
      expect(error.message).not_to include(secret)
    }
    expect(result).to eq(:not_returned)
  end

  [nil, 1, '', '/absolute', "nul\0byte", 'dir\\file', 'C:relative', 'c:/absolute',
   'dir//file', 'dir/', '.', '..', './file', 'dir/./file', '../file', 'dir/../file', "\xFF".b].each do |invalid|
    it "rejects invalid relative path #{invalid.inspect}" do
      entry['path'] = invalid
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'accepts a Unicode path supplied as binary-tagged UTF-8 bytes' do
    manifest['evidence'] = [materialize('body', path: '証拠/file')]
    manifest.fetch('evidence').first['path'] = '証拠/file'.b
    expect(read_evidence.first.fetch('content')).to eq('body')
  end

  it 'accepts a binary-tagged Unicode root and filename' do
    unicode_root = root.join('雪')
    unicode_root.mkpath
    File.binwrite(unicode_root.join('証拠'), 'body')
    manifest['evidence'] = [{ 'evidence_id' => 'unicode', 'path' => '証拠'.b,
                              'sha256' => Digest::SHA256.hexdigest('body') }]

    expect(read_evidence(root: unicode_root.to_s.b).first.fetch('content')).to eq('body')
  end

  it 'wraps filesystem read failures without exposing their messages' do
    entry
    allow(File).to receive(:open).and_raise(Errno::EACCES, 'PRIVATE BODY')
    expect { read_evidence }.to raise_error(invalid_evidence) do |error|
      expect(error.message).not_to include('PRIVATE BODY')
    end
  end

  it 'rejects missing, non-directory and invalid roots' do
    entry
    [root.join('missing'), root.join(entry.fetch('path')), nil, "bad\0root"].each do |invalid|
      expect { read_evidence(root: invalid) }.to raise_error(invalid_evidence)
    end
  end

  it 'rejects a missing candidate and a directory candidate' do
    %w[missing materialized].each do |path|
      entry['path'] = path
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'rejects a FIFO before attempting a blocking content read' do
    fifo = root.join('pipe')
    File.mkfifo(fifo)
    entry['path'] = 'pipe'
    expect(File).not_to receive(:open).with(fifo.to_s, anything)
    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  it 'allows in-root symlinks and a symlinked root alias' do
    entry
    root.join('alias').make_symlink(root.join(entry.fetch('path')))
    alias_root = Pathname.new(temporary).join('root-alias')
    alias_root.make_symlink(root)
    entry['path'] = 'alias'

    expect(read_evidence(root: alias_root.to_s).first.fetch('content')).to eq("original\r\n雪\nlast")
  end

  it 'rejects symlinks that escape into a sibling whose name starts with the root name' do
    sibling = Pathname.new("#{root}-outside")
    sibling.mkpath
    File.binwrite(sibling.join('file'), 'outside')
    root.join('escape').make_symlink(sibling)
    entry['path'] = 'escape/file'
    entry['sha256'] = Digest::SHA256.hexdigest('outside')

    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  it 'rejects dangling and cyclic symlinks' do
    root.join('dangling').make_symlink(root.join('absent'))
    root.join('cyclic').make_symlink(root.join('cyclic'))
    %w[dangling cyclic].each do |path|
      entry['path'] = path
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'accepts exactly 1 MiB per file measured in raw bytes' do
    body = 'é' * 524_288
    manifest['evidence'] = [materialize(body)]
    expect(read_evidence.first.fetch('content')).to eq(body)
  end

  it 'rejects a file one raw byte over 1 MiB despite having fewer characters' do
    manifest['evidence'] = [materialize("#{'é' * 524_288}x")]
    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  it 'never requests an unbounded content read for a large file' do
    manifest['evidence'] = [materialize('x' * 2_097_152)]
    allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
      original.call(*args) do |io|
        allow(io).to receive(:read).and_wrap_original do |read, length, *rest|
          expect(length).to be_between(1, 1_048_577)
          read.call(length, *rest)
        end
        block.call(io)
      end
    end
    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  it 'counts repeated paths separately, accepting 4 MiB and rejecting one extra byte' do
    full = materialize('x' * 1_048_576, path: 'full')
    extra = materialize('x', path: 'extra', id: 'extra')
    manifest['evidence'] = Array.new(4) { |index| full.merge('evidence_id' => index.to_s) }
    expect(read_evidence.sum { |row| row.fetch('content').bytesize }).to eq(4_194_304)
    manifest['evidence'] << materialize('', path: 'empty', id: 'empty')
    expect(read_evidence.last.fetch('content')).to eq('')

    manifest['evidence'] << extra
    expect { read_evidence }.to raise_error(invalid_evidence)
  end

  ["\xFF".b, "\xC3".b, "\xC0\xAF".b].each do |bytes|
    it "rejects invalid UTF-8 content #{bytes.inspect} even with a matching digest" do
      manifest['evidence'] = [materialize(bytes)]
      expect { read_evidence }.to raise_error(invalid_evidence)
    end
  end

  it 'loads with stdlib alone under US-ASCII defaults, without Git or credentials, and never executes content' do
    marker = root.join('executed')
    body = "File.write(#{marker.to_s.inspect}, 'bad')\n# 雪\r\n"
    manifest['evidence'] = [materialize(body)]
    source = File.expand_path('../../../script/typesafe/evidence', __dir__)
    program = <<~PROGRAM
      require 'json'
      require ARGV.fetch(0)
      rows = WoodsDevelopment::TypeSafe::Evidence.read(root: ARGV.fetch(1), manifest: JSON.parse(ARGV.fetch(2)))
      STDOUT.binmode
      STDOUT.write(rows.fetch(0).fetch('content'))
    PROGRAM
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-EUS-ASCII', '-e', program,
                                            source, root.to_s, JSON.generate(manifest), unsetenv_others: true)

    expect(status.success?).to be(true), stderr
    expect(stdout.b).to eq(body.b)
    expect(stderr).to eq('')
    expect(marker).not_to exist
    expect(root.join('.git')).not_to exist
  end
end
