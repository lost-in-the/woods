# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rake'
require 'rbconfig'
require 'woods'

# The Console MCP server was removed in 2.2.0. Every name an older setup can
# still reach stops with the same one line. The configuration setters are
# covered in spec/configuration_spec.rb.
RSpec.describe 'Console removal tombstones' do
  let(:root) { File.expand_path('..', __dir__) }
  let(:message) { Woods::Console::REMOVED_MESSAGE }

  it 'names the removal release and the page with the cleanup steps' do
    expect(message).to include('removed in Woods 2.2.0', 'docs/CONSOLE_REMOVED.md')
    expect(File).to exist(File.join(root, 'docs/CONSOLE_REMOVED.md'))
  end

  describe Woods::Console::RackMiddleware do
    let(:app) { ->(_env) { [200, {}, ['ok']] } }

    it 'raises the removal message when constructed, with or without options' do
      [[app], [app, { path: '/mcp/console' }]].each do |args|
        expect { described_class.new(*args) }.to raise_error(Woods::ConfigurationError, message)
      end
      expect { described_class.new(app, path: '/mcp/console', embedded_read_tools: true) }
        .to raise_error(Woods::ConfigurationError, message)
    end
  end

  %w[exe/woods-console exe/woods-console-mcp].each do |path|
    it "prints the removal message on stderr and exits 1 from #{path}, without loading Rails" do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(root, path), stdin_data: '')

      expect([stdout, stderr, status.exitstatus]).to eq(['', "#{message}\n", 1])
    end
  end

  describe 'rake woods:console' do
    around do |example|
      previous = Rake.application
      Rake.application = Rake::Application.new
      example.run
    ensure
      Rake.application = previous
    end

    it 'prints the removal message on stderr and exits 1, with no Rails prerequisite' do
      previous_verbose = $VERBOSE
      $VERBOSE = nil
      load File.join(root, 'lib/tasks/woods.rake')
      $VERBOSE = previous_verbose
      task = Rake::Task['woods:console']

      expect(task.prerequisites).to eq([])
      expect { task.invoke }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output("#{message}\n").to_stderr
    ensure
      $VERBOSE = previous_verbose
    end
  end
end
