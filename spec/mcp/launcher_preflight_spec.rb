# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'woods-mcp-start payload preflight' do
  around do |example|
    Dir.mktmpdir('woods-launcher-preflight') do |directory|
      @directory = directory
      @root = File.join(directory, 'index')
      @payload = File.join(@root, 'payloads', 'gen-1')
      FileUtils.mkdir_p(@payload)
      FileUtils.touch(File.join(@payload, 'manifest.json'))
      example.run
    end
  end

  # Observe the wrapper itself: eventual rejection by woods-mcp would hide a
  # preflight probe outside the index. Intercept only exec and record file?
  # calls; path resolution and filesystem reads still run against real files.
  def preflight(root = @root)
    wrapper = File.expand_path('../../exe/woods-mcp-start', __dir__)
    log = File.join(@directory, 'probes.json')
    harness = <<~RUBY
      require 'json'
      wrapper, root, log = ARGV
      ARGV.replace([root])
      probes = []
      original = File.method(:file?)
      File.define_singleton_method(:file?) { |path| probes << path; original.call(path) }
      at_exit { File.write(log, JSON.generate(probes)) }
      Kernel.define_method(:exec) { |*| exit 42 }
      load wrapper
    RUBY
    output, errors, status = Open3.capture3(RbConfig.ruby, '-e', harness, wrapper, root, log)
    expect(output).to be_empty
    [status.exitstatus, errors, JSON.parse(File.read(log))]
  end

  def publish(payload)
    File.write(File.join(@root, 'generation.json'), JSON.generate(number: 1, payload: payload))
  end

  it 'execs for a legacy flat index' do
    FileUtils.touch(File.join(@root, 'manifest.json'))
    status, errors, = preflight
    expect(status).to eq(42), errors
  end

  it 'execs for a contained payload directory' do
    publish('payloads/gen-1')
    status, errors, = preflight
    expect(status).to eq(42), errors
  end

  it 'execs for a contained payload symlink' do
    File.symlink(@payload, File.join(@root, 'current'))
    publish('current')
    status, errors, = preflight
    expect(status).to eq(42), errors
  end

  it 'execs when the selected index root is itself a symlink' do
    selected = File.join(@directory, 'selected')
    File.symlink(@root, selected)
    publish('payloads/gen-1')
    status, errors, = preflight(selected)
    expect(status).to eq(42), errors
  end

  { 'an escaping symlink' => 'escape', 'a broken symlink' => 'broken',
    'a sibling-prefix path' => '../index-outside' }.each do |description, payload|
    it "rejects #{description} before probing its manifest or execing" do
      outside = File.join(@directory, 'index-outside')
      FileUtils.mkdir_p(outside)
      FileUtils.touch(File.join(outside, 'manifest.json'))
      File.symlink(outside, File.join(@root, 'escape'))
      File.symlink(File.join(@directory, 'missing'), File.join(@root, 'broken'))
      publish(payload)

      status, errors, probes = preflight
      expect(status).to eq(1), errors
      expect(errors).to include('Could not resolve a published Woods index', @root,
                                'generation.json', 'legacy flat manifest.json')
      expect(errors).not_to include('from ', 'Errno::')
      expect(probes).to eq([File.join(@root, 'manifest.json'), File.join(@root, 'generation.json')])
    end
  end
end
