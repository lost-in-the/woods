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

  def install_source_fixture(home, name)
    spec = Gem::Specification.new do |gem|
      gem.name = name
      gem.version = '1.0.0'
      gem.summary = 'Offline source ownership fixture'
      gem.authors = ['Woods fixture']
    end
    gemspec = File.join(home, 'specifications', "#{spec.full_name}.gemspec")
    source = File.join(home, 'gems', spec.full_name, 'lib', "#{name}.rb")
    FileUtils.mkdir_p([File.dirname(gemspec), File.dirname(source)])
    File.write(gemspec, spec.to_ruby)
    File.write(source, "module #{name.split('_').map(&:capitalize).join}; end\n")
    "Gem::Specification.load(#{gemspec.inspect}).activate\nrequire #{name.inspect}\n"
  end

  it 'keeps freshness current for installed gems inside or outside the application checkout' do
    Dir.mktmpdir('woods-source-installed') do |parent|
      app = File.join(parent, 'app')
      FileUtils.mkdir_p(app)
      make_source_app(app)
      inside = install_source_fixture(File.join(app, 'vendor/bundle/ruby/fixture'), 'woods_inside_fixture')
      outside = install_source_fixture(File.join(parent, 'external_gems'), 'woods_outside_fixture')
      FileUtils.mkdir_p(File.join(app, 'config/initializers'))
      File.write(File.join(app, 'config/initializers/source_gems.rb'), inside + outside)

      launch(app, 'full')

      expect(state(app)).to include('state' => 'current', 'recorded_root' => app, 'checked_root' => app)
      expect(source_manifest(app).data['errors']).to eq([])
    end
  end

  it 'checks a copied booted index against the task process checkout while preserving explicit mappings' do
    Dir.mktmpdir('woods-source-copy') do |parent|
      app = File.join(parent, 'original')
      FileUtils.mkdir_p(app)
      make_source_app(app)
      launch(app, 'full')
      copy = File.join(parent, 'copy')
      FileUtils.cp_r(app, copy)
      File.write(File.join(copy, 'app/services/copied_probe.rb'), "class CopiedProbe; end\n")
      encoded = Base64.strict_encode64(JSON.generate(output: output(copy), mode: 'deep'))
      result = Dir.chdir(copy) { Woods::SourceInputs::Status.from_transport(encoded) }

      expect(result).to include('state' => 'drifted', 'recorded_root' => app, 'checked_root' => copy)
      expect(result.dig('changes', 'added')).to include('app/services/copied_probe.rb')
      expect(state(copy)).to include('state' => 'current', 'checked_root' => app, 'root_source' => 'recorded')
    end
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

  it 'preserves the published generation when captured Ruby changes after boot, then recovers on a fresh run' do
    Dir.mktmpdir('woods-source-rails') do |app|
      make_source_app(app)
      path = File.join(app, 'app/services/source_probe.rb')
      before = "class SourceProbe; def call; :before; end; end\n"
      File.write(path, before)
      launch(app, 'full')
      pointer = File.binread(File.join(output(app), 'generation.json'))
      payload = Woods::Generation.new(output_dir: output(app)).payload_dir
      artifacts = %w[source_inputs.json source_references.json dependency_graph.json].to_h do |name|
        [name, File.binread(File.join(payload, name))]
      end
      Open3.popen3({ 'WOODS_SOURCE_BARRIER' => '1' }, *command(app, 'full')) do |input, out, err, child|
        input.close
        stdout = Thread.new { out.read }
        stderr = Thread.new { err.read }
        Timeout.timeout(15) { sleep 0.01 until File.exist?(File.join(app, 'boot-ready')) || !child.alive? }
        expect(child).to be_alive, "#{stdout.value unless child.alive?} #{stderr.value unless child.alive?}"
        File.write(path, before.sub(':before', ':after'))
        File.write(File.join(app, 'boot-release'), 'continue')
        expect(child.value).not_to be_success, "#{stdout.value}\n#{stderr.value}"
        expect(stderr.value).to include('source_snapshot_mismatch', 'app/services/source_probe.rb', 'fresh process')
      end
      expect(File.binread(File.join(output(app), 'generation.json'))).to eq(pointer)
      artifacts.each { |name, bytes| expect(File.binread(File.join(payload, name))).to eq(bytes) }
      manifest = source_manifest(app)
      key = Woods::SourceInputs::PrivateKey.new(output_dir: output(app))
      expect(manifest.data['boot_verified']).to be(true)
      expect(manifest.expanded['file:services']['app/services/source_probe.rb']).to eq(OpenSSL::HMAC.hexdigest(
                                                                                         'SHA256', key.bytes, before
                                                                                       ))
      expect(state(app)['state']).to eq('drifted')
      expect(state(app)['changes']['changed']).to include('app/services/source_probe.rb')
      launch(app, 'full')
      expect(state(app)['state']).to eq('current')
      assert_current_identities(app, 'tmp/woods')
    end
  end

  it 'validates independent full/incremental identities and refuses unconsumed Ruby during a partial refresh' do
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
      pointer = File.binread(File.join(output(app), 'generation.json'))
      File.write(File.join(app, omitted), "class OmittedSource; def call; :after; end; end\n")
      out, err, result = Open3.capture3(*command(app, 'refresh', 'events'))
      expect(result).not_to be_success, "#{out}\n#{err}"
      expect(err).to include('Source-reference baseline needs a full extraction', omitted)
      expect(File.binread(File.join(output(app), 'generation.json'))).to eq(pointer)
      expect(state(app)['state']).to eq('drifted')
      expect(state(app)['changes']['changed']).to include(omitted)
      launch(app, 'full')
      expect(state(app)['state']).to eq('current')
      assert_current_identities(app, 'tmp/woods')
    end
  end

  it 'keeps an omitted view stale when no retained reference-bearing Ruby input changed' do
    Dir.mktmpdir('woods-source-rails') do |app|
      make_source_app(app)
      view = 'app/views/posts/source_probe.html.erb'
      FileUtils.mkdir_p(File.dirname(File.join(app, view)))
      File.write(File.join(app, view), '<p>before</p>')
      launch(app, 'full')
      previous = source_manifest(app).expanded.fetch('unit:view_templates').fetch(view)
      File.write(File.join(app, view), '<p>after</p>')
      launch(app, 'refresh', 'events')
      expect(source_manifest(app).expanded.fetch('unit:view_templates').fetch(view)).to eq(previous)
      expect(state(app)['state']).to eq('drifted')
      expect(state(app)['changes']['changed']).to include(view)
    end
  end
end
