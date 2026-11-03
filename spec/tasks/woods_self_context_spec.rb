# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'stringio'
require 'woods/self_map/task'

RSpec.describe 'Woods self context tasks' do
  around do |example|
    previous = Rake.application
    previous_out = $stdout
    keys = %w[CHANGED_FILES WOODS_SELF_IMPACT_OPTIONS]
    environment = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    Dir.mktmpdir('woods-self-tasks') do |directory|
      @root = Pathname.new(directory)
      @root.join('lib/woods').mkpath
      @root.join('spec').mkpath
      @root.join('lib/woods/a space.rb').write('class Store; end')
      @root.join('spec/store_spec.rb').write("require_relative '../lib/woods/a space'")
      @runner = Woods::SelfMap::Task.new(root: @root, index_dir: @root.join('tmp/index'),
                                         output_dir: @root.join('tmp/context'))
      keys.each { |key| ENV.delete(key) }
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment) { raise 'must not boot Rails' }
      load File.expand_path('../../lib/tasks/woods.rake', __dir__)
      @out = $stdout = StringIO.new
      example.run
    end
  ensure
    Rake.application = previous
    $stdout = previous_out
    environment.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before { allow(Woods::SelfMap::Task).to receive(:from_environment).and_return(@runner) }

  it 'publishes guides without loading Rails and prints the completed directory' do
    expect(Rake::Task['woods:self_docs'].prerequisites).to eq([])
    Rake::Task['woods:self_docs'].invoke
    expect(Pathname.new(File.join(@out.string.strip, 'START_HERE.md'))).to be_file
  end

  it 'accepts quoted relative paths and returns a saved report without Rails' do
    expect(Rake::Task['woods:self_impact'].prerequisites).to eq([])
    Rake::Task['woods:self_impact'].invoke('"lib/woods/a space.rb"')
    report = JSON.parse(File.read(File.join(@out.string.strip, 'impact.json')))
    expect(report['paths']).to eq(['lib/woods/a space.rb'])
    expect(report['suggested_specs']).to include('spec/store_spec.rb')
  end

  it 'rejects malformed options without publishing or printing a success path' do
    ENV['WOODS_SELF_IMPACT_OPTIONS'] = '[]'
    expect { Rake::Task['woods:self_impact'].invoke('lib/woods/a.rb') }.to raise_error(ArgumentError)
    expect(@out.string).to eq('')
  end
end
