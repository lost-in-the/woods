# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'open3'
require 'woods/payload_store'
require 'woods/generation'

RSpec.describe 'Persistent generation pin rake tasks' do
  let(:index) { Dir.mktmpdir('woods-pin-task') }
  let(:store) { Woods::PayloadStore.new(index) }

  before do
    payload = store.create(1)
    File.write(payload.join('manifest.json'), '{}')
    File.write(payload.join('dependency_graph.json'), '{}')
    Woods::Generation.new(output_dir: index).bump!(payload: Woods::PayloadStore.name_for(1))
    @root = File.expand_path('../..', __dir__)
    File.write(File.join(index, 'Rakefile'), <<~RUBY)
      $LOAD_PATH.unshift(#{File.join(@root, 'lib').inspect})
      require 'rake'
      require 'pathname'
      require 'woods'
      task :environment
      load #{File.join(@root, 'lib/tasks/woods.rake').inspect}
    RUBY
  end

  after { FileUtils.rm_rf(index) }

  def run_task(task)
    Open3.capture3({ 'WOODS_OUTPUT' => index }, RbConfig.ruby,
                   File.join(@root, 'bin/rake'), task, chdir: index)
  end

  it 'pins and releases a generation using WOODS_OUTPUT, with stats visibility' do
    output, error, status = run_task('woods:pin[1]')
    expect(status.success?).to be(true), "#{output}\n#{error}"
    expect(output).to include('Pinned generation 1')
    expect(store.pins).to eq([1])
    output, error, status = run_task('woods:stats')
    expect(status.success?).to be(true), "#{output}\n#{error}"
    expect(output).to include('Persistent pins: 1')
    output, error, status = run_task('woods:unpin[1]')
    expect(status.success?).to be(true), "#{output}\n#{error}"
    expect(output).to include('Unpinned generation 1')
    expect(store.pins).to eq([])
  end

  it 'fails for missing, malformed, future and unknown generation arguments' do
    %w[woods:pin woods:pin[../1] woods:pin[2] woods:unpin[0] woods:unpin[99]].each do |task|
      output, error, status = run_task(task)
      expect(status.success?).to be(false), "#{task}: #{output}\n#{error}"
      expect(error).to include('Generation')
      expect(store.pins).to eq([])
    end
  end

  it 'shows the absence of persistent pins on legacy indexes' do
    FileUtils.rm_f(File.join(index, 'generation.json'))
    File.write(File.join(index, 'manifest.json'), '{}')
    output, error, status = run_task('woods:stats')
    expect(status.success?).to be(true), "#{output}\n#{error}"
    expect(output).to include('Persistent pins: none')
  end
end
