# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'
require 'woods/source_inputs/status'
require_relative '../support/source_input_app'

RSpec.describe 'Verified launch output selection', :booted_app do
  include SourceInputApp

  let(:root) { File.expand_path('../..', __dir__) }

  def launch(app, *arguments, output: nil)
    Open3.capture3({ 'WOODS_OUTPUT' => output }, RbConfig.ruby, '-I', File.join(root, 'lib'),
                   File.join(root, 'exe/woods-extract'), '--root', app, *arguments)
  end

  def verify(app, directory)
    Woods::SourceInputs::Status.new(output_dir: File.join(app, directory), mode: 'deep').call
  end

  around do |example|
    Dir.mktmpdir('woods-source-output') do |app|
      @app = app
      make_source_app(app)
      FileUtils.mkdir_p(File.join(app, 'config/initializers'))
      File.write(File.join(app, 'config/initializers/woods_output.rb'), <<~RUBY)
        Woods.configuration.output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('custom index'))
      RUBY
      example.run
    end
  end

  [%w[full], %w[incremental config/initializers/woods_output.rb], %w[refresh routes]].each do |arguments|
    it "refuses implicit default output for custom configuration during #{arguments.first}" do
      out, err, status = launch(@app, '--output', 'custom index', 'full')
      expect(status).to be_success, "#{out}\n#{err}"
      pointer = File.binread(File.join(@app, 'custom index/generation.json'))

      out, err, status = launch(@app, *arguments)

      expect(status).not_to be_success, "#{out}\n#{err}"
      expect(err).to include('configured output', 'custom index', '--output', 'WOODS_OUTPUT')
      expect(File.exist?(File.join(@app, 'tmp/woods/generation.json'))).to be(false)
      expect(File.binread(File.join(@app, 'custom index/generation.json'))).to eq(pointer)
    end
  end

  %i[relative absolute environment].each do |selection|
    it "keeps #{selection} output, private key and verified capture together" do
      path = selection == :absolute ? File.join(@app, 'custom index') : 'custom index'
      arguments = selection == :environment ? [] : ['--output', path]
      output = selection == :environment ? path : nil
      out, err, status = launch(@app, *arguments, 'full', output: output)
      expect(status).to be_success, "#{out}\n#{err}"
      expect(verify(@app, 'custom index')['state']).to eq('current')
      expect(File.exist?(File.join(@app, 'tmp/woods'))).to be(false)
    end
  end
end
