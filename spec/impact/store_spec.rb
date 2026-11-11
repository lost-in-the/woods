# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'cgi'
require 'woods/impact/store'
require 'woods/impact/renderers'
require 'woods/impact/value'

RSpec.describe Woods::Impact::Store do
  around do |example|
    Dir.mktmpdir('impact-store') do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  let(:store) { described_class.new(@root) }
  let(:json) do
    JSON.generate('schema_version' => 1, 'parameters' => { 'mode' => 'range' }, 'range' => {},
                  'coverage' => { 'complete' => false }, 'changed' => [], 'affected' => [], 'flows' => [],
                  'tables' => [], 'templates' => [], 'risks' => [], 'tests' => [], 'unknowns' => [])
  end

  it 'saves exact bytes under their digest with restrictive directory and file modes' do
    id = store.save(json)
    expect(id).to eq(Digest::SHA256.hexdigest(json))
    path = store.path_for(id)
    expect(path.binread).to eq(json)
    expect(path.stat.mode & 0o777).to eq(0o600)
    [path.dirname, path.dirname.parent, path.dirname.parent.parent].each do |dir|
      expect(dir.stat.mode & 0o777).to eq(0o700)
    end
    expect(store.read(id)).to eq(json)
  end

  it 'renders a stored sparse schema 1 report without changing its original JSON or values' do
    sparse_json = JSON.pretty_generate(JSON.parse(json).except('tables', 'templates'))
    id = store.save(sparse_json)
    data = Woods::Impact::Value.copy(JSON.parse(store.read(id)))
    original = JSON.generate(data)
    markdown = CGI.unescapeHTML(Woods::Impact::Renderers.markdown(data))
    mermaid = Woods::Impact::Renderers.mermaid(data)
    expect(markdown).to include('tables=not_computed', 'templates=not_computed', '2 unknown records')
    expect(mermaid).to include('Incomplete report', '2 unknown records')
    expect(JSON.generate(data)).to eq(original)
    expect(data).not_to have_key('tables')
    expect(data).not_to have_key('templates')
    expect(store.read(id)).to eq(sparse_json)
    expect(id).to eq(Digest::SHA256.hexdigest(sparse_json))
  end

  it 'publishes concurrent duplicates idempotently without replacing the report' do
    ids = Array.new(4) { Thread.new { described_class.new(@root).save(json) } }.map(&:value)
    expect(ids.uniq).to eq([Digest::SHA256.hexdigest(json)])
    path = store.path_for(ids.first)
    before = path.stat.ino
    expect(store.save(json)).to eq(ids.first)
    expect(path.stat.ino).to eq(before)
    expect(path.dirname.children.map { |entry| entry.basename.to_s }).to eq(['impact.json'])
  end

  %i[write fsync].each do |operation|
    it "can retry after the first temporary #{operation} fails without stranding its new directory" do
      failed = false
      allow(Tempfile).to receive(:new).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do |temporary|
          unless failed
            failed = true
            allow(temporary).to receive(operation).and_raise(Errno::ENOSPC)
          end
        end
      end
      id = Digest::SHA256.hexdigest(json)
      expect { store.save(json) }.to raise_error(described_class::Error)
      expect(store.path_for(id).dirname).not_to exist
      expect(store.save(json)).to eq(id)
      expect(store.read(id)).to eq(json)
    end
  end

  it 'can retry after its first no-replace link fails transiently' do
    failed = false
    allow(File).to receive(:link).and_wrap_original do |original, *arguments|
      unless failed
        failed = true
        raise Errno::EIO
      end
      original.call(*arguments)
    end
    id = Digest::SHA256.hexdigest(json)
    expect { store.save(json) }.to raise_error(described_class::Error)
    expect(store.path_for(id).dirname).not_to exist
    expect(store.save(json)).to eq(id)
    expect(store.read(id)).to eq(json)
  end

  it 'preserves a published destination if failure occurs after the report is renamed into place' do
    allow(File).to receive(:rename).and_wrap_original do |original, *arguments|
      original.call(*arguments)
      raise Errno::EIO
    end
    id = Digest::SHA256.hexdigest(json)
    expect { store.save(json) }.to raise_error(described_class::Error)
    expect(store.read(id)).to eq(json)
    expect(store.save(json)).to eq(id)
  end

  it 'refuses a corrupt existing ID destination without overwriting it' do
    id = store.save(json)
    path = store.path_for(id)
    path.write('{}')
    expect { store.save(json) }.to raise_error(described_class::Error)
    expect(path.read).to eq('{}')
  end

  it 'refuses a report directory without its report that holds anything a writer does not make' do
    id = store.save(json)
    path = store.path_for(id)
    FileUtils.rm(path)
    path.dirname.join('notes.txt').write('kept')
    expect { store.save(json) }.to raise_error(described_class::Error)
    expect(path.dirname.join('notes.txt').read).to eq('kept')
    expect(path).not_to exist
  end

  # A writer that died between creating the report directory and linking its
  # report used to leave a directory every later save refused, wedging the ID.
  it 'recovers a report directory a dead writer left without its report' do
    id = Digest::SHA256.hexdigest(json)
    leftover = @root.join('explorer', 'impacts', id)
    FileUtils.mkdir_p(leftover, mode: 0o700)
    leftover.join('.impact-20261111-1-abc').binwrite(json[0, 10])
    File.chmod(0o600, leftover.join('.impact-20261111-1-abc'))
    expect(store.save(json)).to eq(id)
    expect(store.read(id)).to eq(json)
    expect(leftover.children.map { |entry| entry.basename.to_s }).to eq(['impact.json'])
  end

  %i[link rename].each do |operation|
    it "leaves nothing at the report path when a writer dies at its #{operation}" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      died = false
      allow(File).to receive(operation).and_wrap_original do |original, *arguments|
        unless died
          died = true
          raise crash
        end
        original.call(*arguments)
      end
      id = Digest::SHA256.hexdigest(json)
      expect { store.save(json) }.to raise_error(crash)
      expect(store.path_for(id).dirname).not_to exist
      expect(store.save(json)).to eq(id)
      expect(store.read(id)).to eq(json)
      expect(store.path_for(id).dirname.parent.children.map { |entry| entry.basename.to_s })
        .to contain_exactly('.lock', id)
    end
  end

  it 'refuses symlink components, ID directories, report files and lock files' do
    other = @root.join('outside')
    other.mkdir(0o700)
    File.symlink(other, @root.join('explorer'))
    expect { store.save(json) }.to raise_error(described_class::Error)
    File.unlink(@root.join('explorer'))
    id = store.save(json)
    path = store.path_for(id)
    FileUtils.rm(path)
    File.symlink(other.join('elsewhere.json'), path)
    expect { store.read(id) }.to raise_error(described_class::Error)
    FileUtils.rm(path)
    FileUtils.rmdir(path.dirname)
    File.symlink(other, path.dirname)
    expect { store.save(json) }.to raise_error(described_class::Error)
    File.unlink(path.dirname)
    FileUtils.rm(path.dirname.parent.join('.lock'))
    File.symlink(other.join('lock'), path.dirname.parent.join('.lock'))
    expect { store.save(json) }.to raise_error(described_class::Error)
    expect(other.children).to eq([])
  end

  it 'rejects unsafe IDs, invalid reports and loosely accessible stored files' do
    expect { store.read('../elsewhere') }.to raise_error(described_class::Error)
    expect { store.save('{ broken') }.to raise_error(described_class::Error)
    expect { store.save(JSON.generate('schema_version' => 9)) }.to raise_error(described_class::Error)
    expect(@root.join('explorer')).not_to exist
    id = store.save(json)
    File.chmod(0o644, store.path_for(id))
    expect { store.read(id) }.to raise_error(described_class::Error)
  end

  it 'reads saved report bytes after generation payloads have been retained away' do
    payload = @root.join('payloads', 'gen-1')
    FileUtils.mkdir_p(payload)
    payload.join('manifest.json').write('{}')
    id = store.save(json)
    FileUtils.rm_rf(@root.join('payloads'))
    expect(store.read(id)).to eq(json)
  end
end
