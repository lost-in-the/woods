# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'timeout'
require 'woods/source_inputs/status'
require_relative '../support/source_input_app'

RSpec.describe 'Fresh-process source provenance', :booted_app do
  include SourceInputApp

  let(:root) { File.expand_path('../..', __dir__) }

  def command(app, *args)
    [RbConfig.ruby, '-I', File.join(root, 'lib'), File.join(root, 'exe/woods-extract'), '--root', app, *args]
  end

  def launch(app, *args)
    out, err, result = Open3.capture3(*command(app, *args))
    expect(result).to be_success, "#{out}\n#{err}"
  end

  def output(app, name = 'tmp/woods')
    File.join(app, name)
  end

  def source_manifest(app, name = 'tmp/woods')
    payload = Woods::Generation.new(output_dir: output(app, name)).payload_dir
    Woods::SourceInputs::Manifest.parse(File.read(File.join(payload, 'source_inputs.json')))
  end

  def state(app, name = 'tmp/woods')
    Woods::SourceInputs::Status.new(output_dir: output(app, name), mode: 'deep').call
  end

  def assert_current_identities(app, name)
    manifest = source_manifest(app, name)
    key = Woods::SourceInputs::PrivateKey.new(output_dir: output(app, name))
    manifest.expanded.each_value do |paths|
      paths.each do |path, identity|
        expected = OpenSSL::HMAC.hexdigest('SHA256', key.bytes, File.binread(File.join(app, path)))
        expect(identity).to eq(expected), "#{name}: #{path}"
      end
    end
    manifest.expanded.transform_values { |paths| paths.keys.sort }
  end

  it 'captures an already-dirty baseline and detects another same-size edit with the same mtime' do
    Dir.mktmpdir('woods-source-rails') do |app|
      make_source_app(app)
      path = File.join(app, 'app/services/source_probe.rb')
      File.write(path, "class SourceProbe; def call; :first; end; end\n")
      launch(app, 'full')
      expect(state(app)).to include('state' => 'current')
      timestamp = File.stat(path).mtime
      File.write(path, "class SourceProbe; def call; :other; end; end\n")
      File.utime(timestamp, timestamp, path)
      expect(state(app)['changes']['changed']).to include('app/services/source_probe.rb')
      expect(state(app)['state']).to eq('drifted')
    end
  end

  it 'publishes explicit uncertainty when a full extractor handles a failure and returns no units' do
    Dir.mktmpdir('woods-source-rails') do |app|
      make_source_app(app)
      File.write(File.join(app, 'app/services/source_probe.rb'), "class SourceProbe; def call; :ok; end; end\n")
      out, err, result = Open3.capture3({ 'WOODS_SOURCE_FAILED_SERVICE' => '1' }, *command(app, 'full'))
      expect(result).to be_success, "#{out}\n#{err}"
      manifest = source_manifest(app)
      expect(manifest.data['boot_verified']).to be(true)
      expect(manifest.data['unverified_scopes']).to include('extractor:services')
      expect(manifest.data['unverified_scopes']).not_to include('extractor:events')
      expect(manifest.expanded['whole:events']).to include('app/services/source_probe.rb')
      expect(state(app)['state']).to eq('unknown')
    end
  end

  it 'retains the preboot identity when a loaded source changes before extraction starts' do
    Dir.mktmpdir('woods-source-rails') do |app|
      make_source_app(app)
      path = File.join(app, 'app/services/source_probe.rb')
      before = "class SourceProbe; def call; :before; end; end\n"
      File.write(path, before)
      Open3.popen3({ 'WOODS_SOURCE_BARRIER' => '1' }, *command(app, 'full')) do |input, out, err, child|
        input.close
        stdout = Thread.new { out.read }
        stderr = Thread.new { err.read }
        Timeout.timeout(15) { sleep 0.01 until File.exist?(File.join(app, 'boot-ready')) || !child.alive? }
        expect(child).to be_alive, "#{stdout.value unless child.alive?} #{stderr.value unless child.alive?}"
        File.write(path, before.sub(':before', ':after'))
        File.write(File.join(app, 'boot-release'), 'continue')
        expect(child.value).to be_success, "#{stdout.value}\n#{stderr.value}"
      end
      manifest = source_manifest(app)
      key = Woods::SourceInputs::PrivateKey.new(output_dir: output(app))
      expect(manifest.data['boot_verified']).to be(true)
      expect(manifest.expanded['file:services']['app/services/source_probe.rb']).to eq(OpenSSL::HMAC.hexdigest(
                                                                                         'SHA256', key.bytes, before
                                                                                       ))
      expect(state(app)['state']).to eq('drifted')
      expect(state(app)['reasons']).to include('source_changed_during_extraction')
    end
  end

  it 'validates independent full/incremental identities with each private key and keeps omitted inputs stale' do
    Dir.mktmpdir('woods-source-rails') do |app|
      make_source_app(app)
      view = File.join(app, 'app/views/posts/source_probe.html.erb')
      FileUtils.mkdir_p(File.dirname(view))
      File.write(view, '<p>before</p>')
      launch(app, 'full')
      File.write(view, '<p>after</p>')
      launch(app, 'incremental', 'app/views/posts/source_probe.html.erb')
      launch(app, '--output', 'tmp/full-oracle', 'full')
      expect(state(app)['state']).to eq('current')
      expect(state(app, 'tmp/full-oracle')['state']).to eq('current')
      expect(source_manifest(app).data['key_id']).not_to eq(source_manifest(app, 'tmp/full-oracle').data['key_id'])
      expect(assert_current_identities(app, 'tmp/woods')).to eq(assert_current_identities(app, 'tmp/full-oracle'))

      omitted = 'app/services/omitted_source.rb'
      File.write(File.join(app, omitted), "class OmittedSource; def call; :before; end; end\n")
      launch(app, 'full')
      File.write(File.join(app, omitted), "class OmittedSource; def call; :after; end; end\n")
      launch(app, 'refresh', 'events')
      expect(state(app)['state']).to eq('drifted')
      expect(state(app)['changes']['changed']).to include(omitted)
    end
  end
end
