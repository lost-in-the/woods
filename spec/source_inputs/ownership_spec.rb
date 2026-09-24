# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/session'

RSpec.describe 'Installed source ownership' do
  around do |example|
    Dir.mktmpdir('woods-source-ownership') do |root|
      @root = root
      @output = File.join(root, 'index')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      example.run
    end
  end

  def write(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '# loaded source')
    path
  end

  def installed_gem
    home = File.join(@root, 'vendor/bundle/ruby/example')
    spec = Gem::Specification.new do |gem|
      gem.name = 'woods_source_fixture'
      gem.version = '1.0.0'
    end
    spec.loaded_from = write(File.join(home, 'specifications', "#{spec.full_name}.gemspec"))
    path = write(File.join(spec.full_gem_path, 'lib/source_fixture.rb'))
    allow(Gem).to receive(:loaded_specs).and_return(Gem.loaded_specs.merge(spec.name => spec))
    path
  end

  def finish(path, extra_roots: [])
    rules = Woods::SourceInputs::Scopes.new(extra_roots: extra_roots)
    capture = Woods::SourceInputs::Scanner.new(root: @root, output_dir: @output, key: @key, scopes: rules).call
    allow(Woods::SourceInputs::Handoff).to receive_messages(read: capture, extra_roots: extra_roots)
    run = Woods::SourceInputs::Session.new(root: @root, output_dir: @output, baseline_path: nil, operation: 'full')
    run.consume_unit(:fixture, path)
    $LOADED_FEATURES << path
    run.finish(generation: 1, eager_load_complete: true)
  ensure
    $LOADED_FEATURES.delete(path)
  end

  it 'excludes a positively identified installed gem under the app from unit and loaded-feature errors' do
    manifest = finish(installed_gem)

    expect(manifest.data['errors']).to eq([])
    expect(manifest.expanded.fetch('unit:fixture', {})).to be_empty
  end

  it 'still captures and consumes an installed gem explicitly declared as application source' do
    path = installed_gem
    relative = path.delete_prefix("#{@root}/")
    manifest = finish(path, extra_roots: ['vendor/bundle'])

    expect(manifest.data['errors']).to eq([])
    expect(manifest.expanded.fetch('unit:fixture')).to have_key(relative)
  end

  it 'does not infer installed ownership from a vendor/bundle-shaped custom loader path' do
    path = write(File.join(@root, 'vendor/bundle/custom/source.rb'))

    expect(finish(path).data['errors']).to include(include('reason' => 'loaded_source_outside_coverage'))
  end

  it 'does not exclude local path gems merely because RubyGems knows their specification' do
    path = write(File.join(@root, 'custom_engine/lib/source.rb'))
    spec = Gem::Specification.new do |gem|
      gem.name = 'woods_path_fixture'
      gem.version = '1.0.0'
    end
    spec.loaded_from = write(File.join(@root, 'custom_engine/woods_path_fixture.gemspec'))
    allow(Gem).to receive(:loaded_specs).and_return(Gem.loaded_specs.merge(spec.name => spec))

    expect(finish(path).data['errors']).to include(include('reason' => 'loaded_source_outside_coverage'))
  end
end
