# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../../../script/typesafe/extraction_receipt'
require_relative '../../../script/typesafe/review_packet'

RSpec.describe WoodsDevelopment::TypeSafe::ExtractionReceipt do
  let(:root) { @temporary.join('source') }
  let(:producer) { @temporary.join('producer') }
  let(:index_root) { @temporary.join('index') }
  let(:payload) { index_root.join('payloads/gen-1') }
  let(:invalid) { WoodsDevelopment::TypeSafe::InvalidEvidence }
  let(:source_path) { 'app/models/record.rb' }
  let(:producer_path) { 'lib/extractor.rb' }
  let(:revision) { 'c025434fbc003bcec61fafa2808cb6d3d4149fc7' }
  let(:capture_options) do
    { root: root, source_paths: [source_path], producer_root: producer,
      producer_paths: [producer_path], producer_revision: revision, index_dir: index_root }
  end

  around do |example|
    Dir.mktmpdir('woods-extraction-receipt') do |directory|
      @temporary = Pathname.new(directory)
      root.join(source_path).dirname.mkpath
      root.join(source_path).binwrite("class Record; end\r\n")
      producer.join(producer_path).dirname.mkpath
      producer.join(producer_path).binwrite('# extractor implementation')
      example.run
    end
  end

  def write_json(path, value)
    path.dirname.mkpath
    path.binwrite(JSON.generate(value))
  end

  # Writes the fixture and returns the capture callback's explicit success sentinel.
  # rubocop:disable-next Naming/PredicateMethod
  def publish!
    write_json(payload.join('manifest.json'), 'woods_version' => 'fixture')
    write_json(payload.join('dependency_graph.json'), 'nodes' => {}, 'edges' => {}, 'file_map' => {})
    write_json(payload.join('models/_index.json'), [])
    write_json(index_root.join('generation.json'), 'number' => 1, 'payload' => 'payloads/gen-1', 'token' => 'fresh')
    true
  end

  def capture(&block)
    described_class.capture(**capture_options, &block || method(:publish!))
  end

  def verify(receipt, files: [])
    Woods::PublishedIndex.open(index_root) do |index|
      described_class.verify!(receipt: receipt, root: root, producer_root: producer, index: index, files: files)
    end
  end

  def selected_file
    { 'evidence_id' => 'record', 'path' => source_path,
      'sha256' => Digest::SHA256.file(root.join(source_path)).hexdigest }
  end

  it 'records actual declared input bytes and every published JSON artifact around a successful fresh extraction' do
    receipt = capture

    expected_source = { 'path' => source_path, 'sha256' => Digest::SHA256.file(root.join(source_path)).hexdigest,
                        'bytes' => 19 }
    expect(receipt.fetch('source').fetch('files')).to eq([expected_source])
    expect(receipt.fetch('producer')).to include('revision' => revision)
    expect(receipt.fetch('index')).to include('generation' => 1, 'token' => 'fresh', 'payload' => 'payloads/gen-1')
    expect(receipt.fetch('index').fetch('artifacts').map { |entry| entry.fetch('path') })
      .to eq(%w[dependency_graph.json manifest.json models/_index.json])
    expect(verify(JSON.parse(JSON.generate(receipt)))).to eq(true)
  end

  it 'allows an empty precreated output directory' do
    index_root.mkpath

    expect(verify(capture)).to eq(true)
  end

  it 'does not invoke extraction when the output contains an existing index or unrelated file' do
    index_root.mkpath
    index_root.join('old').write('do not overwrite')
    called = false

    expect { capture { called = true } }.to raise_error(invalid, /empty/)
    expect(called).to eq(false)
  end

  it 'rejects a failed extraction even if it left a published index' do
    expect do
      capture do
        publish!
        false
      end
    end.to raise_error(invalid, /successful/)
  end

  it 'does not expose exception messages from the extraction callback' do
    expect { capture { raise 'private source or credentials' } }.to raise_error(invalid) { |error|
      expect(error.message).not_to include('private source')
      expect(error.cause).to be_nil
    }
  end

  it 'requires an explicit success result from the extraction callback' do
    expect do
      capture do
        publish!
        nil
      end
    end.to raise_error(invalid, /successful/)
  end

  it 'rejects an extraction that did not publish a numbered index' do
    expect { capture { true } }.to raise_error(invalid)
  end

  [%i[source root source_path], %i[producer producer producer_path]].each do |label, directory, path|
    it "rejects #{label} bytes changed during extraction" do
      expect do
        capture do
          publish!
          public_send(directory).join(public_send(path)).binwrite('changed during extraction')
          true
        end
      end.to raise_error(invalid, /changed/)
    end

    it "rejects #{label} bytes changed after the receipt was created" do
      receipt = capture
      public_send(directory).join(public_send(path)).binwrite('changed after capture')

      expect { verify(receipt) }.to raise_error(invalid, /changed/)
    end

    it "rejects a missing declared #{label} file" do
      receipt = capture
      public_send(directory).join(public_send(path)).delete

      expect { verify(receipt) }.to raise_error(invalid)
    end
  end

  it 'rejects an artifact changed after capture even when the manifest and generation are unchanged' do
    receipt = capture
    write_json(payload.join('models/_index.json'), [{ 'identifier' => 'Unexpected' }])

    expect { verify(receipt) }.to raise_error(invalid, /changed/)
  end

  it 'rejects added or removed payload artifacts' do
    receipt = capture
    write_json(payload.join('new.json'), {})

    expect { verify(receipt) }.to raise_error(invalid, /changed/)
  end

  it 'rejects a substituted generation token' do
    receipt = capture
    write_json(index_root.join('generation.json'), 'number' => 1, 'payload' => 'payloads/gen-1', 'token' => 'other')

    expect { verify(receipt) }.to raise_error(invalid, /generation/)
  end

  it 'rejects another generation instead of accepting identical artifact bytes' do
    receipt = capture
    FileUtils.cp_r(payload, index_root.join('payloads/gen-2'))
    write_json(index_root.join('generation.json'), 'number' => 2, 'payload' => 'payloads/gen-2', 'token' => 'second')

    expect { verify(receipt) }.to raise_error(invalid, /generation/)
  end

  it 'rejects selected evidence absent from the declared source inventory' do
    receipt = capture
    other = selected_file.merge('path' => 'spec/not_declared_spec.rb')

    expect { verify(receipt, files: [other]) }.to raise_error(invalid, /selected/)
  end

  it 'rejects selected evidence whose digest disagrees with capture' do
    receipt = capture

    expect { verify(receipt, files: [selected_file.merge('sha256' => '0' * 64)]) }
      .to raise_error(invalid, /selected/)
  end

  it 'rejects a source symlink escape without evaluating or reading target code' do
    root.join(source_path).delete
    File.symlink(producer.join(producer_path), root.join(source_path))

    expect { capture }.to raise_error(invalid)
  end

  it 'rejects a payload symlink escape' do
    expect do
      capture do
        publish!
        File.symlink(producer.join(producer_path), payload.join('outside.json'))
        true
      end
    end.to raise_error(invalid)
  end

  it 'rejects invalid relative paths before invoking extraction' do
    capture_options[:source_paths] = ['../producer/lib/extractor.rb']

    expect { capture { raise 'should not run' } }.to raise_error(invalid, /path/)
  end

  it 'rejects duplicate declared paths' do
    capture_options[:source_paths] = [source_path, source_path]

    expect { capture }.to raise_error(invalid, /Duplicate/)
  end

  it 'rejects non UTF-8 path bytes before extraction starts' do
    bad_path = "app/models/invalid-\xff.rb".b
    root.join(bad_path).binwrite('source')
    capture_options[:source_paths] = [bad_path]
    called = false

    expect do
      capture do
        called = true
        publish!
      end
    end.to raise_error(invalid, /path/)
    expect(called).to eq(false)
  end

  it 'rejects excessive declared inventory counts before reading or extracting' do
    stub_const('WoodsDevelopment::TypeSafe::ReceiptInventory::MAX_FILES', 1)
    capture_options[:source_paths] = [source_path, 'other.rb']

    expect { capture }.to raise_error(invalid, /inventory size/)
  end

  it 'rejects oversized source bytes before extraction' do
    stub_const('WoodsDevelopment::TypeSafe::ReceiptInventory::MAX_FILE_BYTES', 10)

    expect { capture }.to raise_error(invalid, /byte limit/)
  end

  describe 'regular file read allocation' do
    let(:inventory) { WoodsDevelopment::TypeSafe::ReceiptInventory.new(root) }

    def observe_reader(&observer)
      allow(File).to receive(:open).and_wrap_original do |original, *arguments, &block|
        original.call(*arguments) do |file|
          observer.call(file)
          block.call(file)
        end
      end
    end

    it 'allocates at most the actual file size plus one byte when the configured ceiling is much larger' do
      size = root.join(source_path).size
      observe_reader do |file|
        expect(file).to receive(:read).with(size + 1).and_call_original
      end

      expect(inventory.fingerprint([source_path]).first.fetch('bytes')).to eq(size)
    end

    it 'rejects an already oversized regular file before allocating a read buffer' do
      observe_reader { |file| expect(file).not_to receive(:read) }

      expect { inventory.read(source_path, 10) }.to raise_error(invalid, /byte limit/)
    end

    ['short', 'longer than the original nineteen bytes'].each do |replacement|
      it "rejects a file whose size changes between fstat and read to #{replacement.bytesize} bytes" do
        observe_reader do |file|
          allow(file).to receive(:read).and_wrap_original do |reader, *arguments|
            root.join(source_path).binwrite(replacement)
            reader.call(*arguments)
          end
        end

        expect { inventory.fingerprint([source_path]) }.to raise_error(invalid, /changed/)
      end
    end
  end

  it 'rejects payload directory recursion beyond its finite traversal limit' do
    stub_const('WoodsDevelopment::TypeSafe::ReceiptInventory::MAX_DEPTH', 1)

    expect do
      capture do
        publish!
        write_json(payload.join('a/b/c.json'), {})
        true
      end
    end.to raise_error(invalid, /traversal limit/)
  end

  it 'does not read a FIFO supplied as an input file' do
    root.join(source_path).delete
    File.mkfifo(root.join(source_path))

    expect { capture }.to raise_error(invalid, /regular file/)
  end

  it 'does not certify the contents of an undeclared source file' do
    receipt = capture
    root.join('undeclared.rb').binwrite('changed without appearing in the declared inventory')

    expect(verify(receipt)).to eq(true)
    expect(receipt.fetch('attestation')).to eq('trusted_local_capture_declared_inputs')
  end

  it 'rejects unsupported receipt schemas, invalid digests and extra fields' do
    receipt = capture
    invalid_receipts = [receipt.merge('schema_version' => 2), receipt.merge('extra' => 'unexpected')]
    bad_digest = JSON.parse(JSON.generate(receipt))
    bad_digest.fetch('source').fetch('files').first['sha256'] = 'invalid'
    invalid_receipts << bad_digest

    invalid_receipts.each { |value| expect { verify(value) }.to raise_error(invalid) }
  end

  it 'makes a recorded packet only after verifying declared sources, producer and the pinned payload' do
    receipt = capture
    manifest = { 'schema_version' => 1, 'evidence' => [selected_file] }
    packet = WoodsDevelopment::TypeSafe::ReviewPacket.build(root: root, index_dir: index_root, manifest: manifest,
                                                            receipt: receipt, producer_root: producer)

    expect(packet.fetch('source_lineage')).to eq('recorded_extraction')
    expect(packet.fetch('extraction_receipt')).to eq(receipt)
    expect(packet.fetch('evidence').first.fetch('content')).to eq("class Record; end\r\n")
  end

  it 'rejects mutations made while the packet is being hydrated' do
    receipt = capture
    manifest = { 'schema_version' => 1, 'evidence' => [selected_file] }
    packet_builder = WoodsDevelopment::TypeSafe::ReviewPacket
    allow_any_instance_of(packet_builder).to receive(:call).and_wrap_original do |original, *args|
      packet = original.call(*args)
      root.join(source_path).binwrite('changed while hydrating')
      packet
    end

    expect do
      WoodsDevelopment::TypeSafe::ReviewPacket.build(root: root, index_dir: index_root, manifest: manifest,
                                                     receipt: receipt, producer_root: producer)
    end.to raise_error(invalid, /changed/)
  end

  it 'rejects generation replacement while the same packet reader remains pinned' do
    receipt = capture
    manifest = { 'schema_version' => 1, 'evidence' => [selected_file] }
    packet_builder = WoodsDevelopment::TypeSafe::ReviewPacket
    allow_any_instance_of(packet_builder).to receive(:call).and_wrap_original do |original, *args|
      packet = original.call(*args)
      FileUtils.cp_r(payload, index_root.join('payloads/gen-2'))
      write_json(index_root.join('generation.json'), 'number' => 2, 'payload' => 'payloads/gen-2', 'token' => 'new')
      packet
    end

    expect do
      WoodsDevelopment::TypeSafe::ReviewPacket.build(root: root, index_dir: index_root, manifest: manifest,
                                                     receipt: receipt, producer_root: producer)
    end.to raise_error(invalid, /generation/)
  end
end
