# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'open3'
require 'timeout'
require 'woods/payload_store'
require 'woods/generation'

RSpec.describe 'Persistent payload generation pins' do
  let(:index) { Dir.mktmpdir('woods-generation-pins') }
  let(:store) { Woods::PayloadStore.new(index) }

  after { FileUtils.rm_rf(index) }

  def publish(number)
    payload = store.create(number)
    File.write(payload.join('manifest.json'), '{}')
    File.write(payload.join('dependency_graph.json'), '{}')
    Woods::Generation.new(output_dir: index).bump!(payload: Woods::PayloadStore.name_for(number))
  end

  it 'persists idempotent pins outside immutable payloads across process restarts' do
    publish(1)
    before = Dir.glob("#{store.path_for(1)}/**/*").to_h { |path| [path, File.binread(path)] }
    expect(store.pin(1)).to be(true)
    expect(store.pin('1')).to be(false)
    output, error, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-rwoods/payload_store', '-e',
                                           'p Woods::PayloadStore.new(ARGV.fetch(0)).pins', index)
    expect(status.success?).to be(true), error
    expect(output.strip).to eq('[1]')
    expect(before).to all(satisfy { |path, bytes| File.binread(path) == bytes })
    expect(Dir.children(store.path_for(1))).to contain_exactly('manifest.json', 'dependency_graph.json')
    expect(store.unpin(1)).to be(true)
    expect(store.unpin(1)).to be(false)
    expect(Woods::PayloadStore.new(index).pins).to eq([])
  end

  it 'retains pins in addition to the usual recent generations and reports skipped pins' do
    (1..5).each { |number| publish(number) }
    store.pin(1)
    skipped = []
    expect(store.prune(keep: 2, protect: 5) { |number, reason| skipped << [number, reason] })
      .to contain_exactly(2, 3)
    expect(skipped).to include([1, :persistent_pin])
    expect(store.path_for(1)).to be_directory
    store.unpin(1)
    expect(store.prune(keep: 2, protect: 5)).to eq([1])
  end

  it 'preserves an active reader after the persistent pin is released' do
    (1..3).each { |number| publish(number) }
    store.pin(1)
    File.open(store.path_for(1).join('manifest.json')) do |manifest|
      manifest.flock(File::LOCK_SH)
      store.unpin(1)
      expect(store.prune(keep: 1, protect: 3)).to eq([2])
      expect(store.path_for(1)).to be_directory
    end
    expect(store.prune(keep: 1, protect: 3)).to eq([1])
  end

  it 'rejects invalid, missing, incomplete, future, and flat generations' do
    publish(1)
    [nil, 0, -1, 1.5, '1.0', '01', '../1', '1/../2', '', 2].each do |number|
      expect { store.pin(number) }.to raise_error(ArgumentError)
    end
    store.create(2)
    expect { store.pin(2) }.to raise_error(ArgumentError)
    FileUtils.rm_f(store.path_for(1).join('dependency_graph.json'))
    expect { store.pin(1) }.to raise_error(ArgumentError)
    FileUtils.rm_rf(store.path_for(1))
    expect { store.pin(1) }.to raise_error(ArgumentError)
    Woods::Generation.new(output_dir: index).bump!
    expect { store.pin(2) }.to raise_error(ArgumentError)
  end

  it 'rejects symlinked payloads and invalid release identifiers' do
    publish(1)
    Dir.mktmpdir('woods-pin-target') do |target|
      FileUtils.cp_r(store.path_for(1).children, target)
      FileUtils.rm_rf(store.path_for(1))
      File.symlink(target, store.path_for(1))
      expect { store.pin(1) }.to raise_error(ArgumentError)
    end
    expect { store.unpin('../1') }.to raise_error(ArgumentError)
    expect { store.unpin(100) }.to raise_error(ArgumentError)
  end

  it 'fails closed on damaged persistent state without deleting payloads or overwriting pins' do
    (1..3).each { |number| publish(number) }
    store.pin(1)
    path = File.join(index, 'generation_pins.json')
    ['{', '[]', '{"version":2,"generations":[]}', '{"version":1,"generations":["1"]}'].each do |bytes|
      File.write(path, bytes)
      expect { store.prune(keep: 1, protect: 3) }.to raise_error(IOError)
      expect { store.pin(2) }.to raise_error(IOError)
      expect { store.unpin(1) }.to raise_error(IOError)
      expect(File.read(path)).to eq(bytes)
      expect(store.path_for(1)).to be_directory
    end
  end

  it 'preserves the old state if an atomic pin update fails' do
    publish(1)
    allow(Woods::AtomicFile).to receive(:write).and_call_original
    allow(Woods::AtomicFile).to receive(:write).with(File.join(index, 'generation_pins.json'), anything)
                                               .and_raise(IOError, 'synthetic write failure')
    expect { store.pin(1) }.to raise_error(IOError, 'synthetic write failure')
    expect(store.pins).to eq([])
  end

  it 'serializes concurrent processes without losing pin or unpin updates' do
    (1..6).each { |number| publish(number) }
    script = 'store = Woods::PayloadStore.new(ARGV[0]); store.public_send(ARGV[1], ARGV[2])'
    [[:pin, (1..6).to_a], [:unpin, [2, 4, 6]]].each do |operation, numbers|
      children = numbers.map do |number|
        Process.spawn(RbConfig.ruby, '-Ilib', '-rwoods/payload_store', '-e', script,
                      index, operation.to_s, number.to_s, out: File::NULL)
      end
      children.each { |pid| expect(Process.wait2(pid).last.success?).to be(true) }
    end
    expect(store.pins).to eq([1, 3, 5])
  end

  it 'commits a pin before a competing prune can delete its payload' do
    (1..3).each { |number| publish(number) }
    entered = Queue.new
    resume = Queue.new
    allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, *args, **kwargs|
      if args.first.to_s.end_with?('generation_pins.json')
        entered << true
        resume.pop
      end
      original.call(*args, **kwargs)
    end
    pin = Thread.new { Woods::PayloadStore.new(index).pin(1) }
    Timeout.timeout(5) { entered.pop }
    prune = Thread.new { Woods::PayloadStore.new(index).prune(keep: 1, protect: 3) }
    resume << true
    expect(Timeout.timeout(5) { pin.value }).to be(true)
    expect(Timeout.timeout(5) { prune.value }).to eq([2])
    expect(store.path_for(1)).to be_directory
  ensure
    resume << true
    pin&.join(5)
    prune&.join(5)
  end
  it 'rejects a pin when a competing prune already owns the deletion transaction' do
    (1..3).each { |number| publish(number) }
    entered = Queue.new
    resume = Queue.new
    allow(FileUtils).to receive(:rm_rf).and_wrap_original do |original, *args, **kwargs|
      if args.first.to_s == store.path_for(1).to_s
        entered << true
        resume.pop
      end
      original.call(*args, **kwargs)
    end
    prune = Thread.new { Woods::PayloadStore.new(index).prune(keep: 1, protect: 3) }
    Timeout.timeout(5) { entered.pop }
    pin = Thread.new do
      Woods::PayloadStore.new(index).pin(1)
    rescue ArgumentError
      :rejected
    end
    resume << true
    expect(Timeout.timeout(5) { prune.value }).to contain_exactly(1, 2)
    expect(Timeout.timeout(5) { pin.value }).to eq(:rejected)
    expect(store.pins).to eq([])
  ensure
    resume << true
    pin&.join(5)
    prune&.join(5)
  end

  it 'accepts an index reached through a symlink without accepting payload symlinks' do
    publish(1)
    Dir.mktmpdir('woods-pin-root-link') do |parent|
      link = File.join(parent, 'index')
      File.symlink(index, link)
      expect(Woods::PayloadStore.new(link).pin(1)).to be(true)
      expect(store.pins).to eq([1])
    end
  end

  it 'releases stale operational pins even when their payload was removed externally' do
    publish(1)
    store.pin(1)
    FileUtils.rm_rf(store.path_for(1))
    expect(store.unpin(1)).to be(true)
    expect(store.pins).to eq([])
  end
  it 'never reuses a pinned number after the generation marker is lost' do
    publish(1)
    store.pin(1)
    original = File.binread(store.path_for(1).join('manifest.json'))
    FileUtils.rm_f(File.join(index, 'generation.json'))
    expect { store.create(1) }.to raise_error(IOError, /pinned/)
    expect(File.binread(store.path_for(1).join('manifest.json'))).to eq(original)
  end

  it 'does not replace a pinned destination during publication number correction' do
    (1..3).each { |number| publish(number) }
    store.pin(1)
    source = store.create(4)
    File.write(source.join('manifest.json'), '{"synthetic":"replacement"}')
    require 'woods/extractor'
    extractor = Woods::Extractor.new(output_dir: index)
    extractor.instance_variable_set(:@payload_dir, source)
    extractor.instance_variable_set(:@payload_generation, 4)
    FileUtils.rm_f(File.join(index, 'generation.json'))
    expect { extractor.send(:publishable_payload_name, Woods::Generation.new(output_dir: index)) }
      .to raise_error(IOError, /pinned/)
    expect(File.read(store.path_for(1).join('manifest.json'))).to eq('{}')
    expect(source).to be_directory
  end
  it 'refuses to move a persistently pinned source payload' do
    publish(1)
    store.pin(1)
    expect { store.rename(store.path_for(1), 2) }.to raise_error(IOError, /pinned/)
    expect(store.path_for(1)).to be_directory
    expect(store.path_for(2)).not_to exist
  end

  it 'rejects pinning an absent index without creating operational files' do
    absent = File.join(index, 'absent')
    expect { Woods::PayloadStore.new(absent).pin(1) }.to raise_error(ArgumentError)
    expect(File).not_to exist(absent)
  end

  it 'reports skipped persistent pins through the extractor retention log' do
    (1..3).each { |number| publish(number) }
    store.pin(1)
    require 'woods/extractor'
    logger = double('Logger').as_null_object
    stub_const('Rails', double('Rails', logger: logger))
    extractor = Woods::Extractor.new(output_dir: index)
    extractor.instance_variable_set(:@payload_dir, store.path_for(3))
    allow(extractor).to receive(:payload_retention).and_return(1)
    extractor.send(:prune_payloads, 3)
    expect(logger).to have_received(:info).with('[Woods] Retaining generation 1: persistent pin')
    expect(store.path_for(1)).to be_directory
  end
end
