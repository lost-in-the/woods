# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'
require 'yaml'
require 'shellwords'

RSpec.describe 'Console launcher configuration validation' do
  { 'false' => [YAML.dump(false), false], 'array' => [YAML.dump([]), false],
    'scalar' => [YAML.dump('ssh'), false], 'empty file' => ['', true],
    'null' => [YAML.dump(nil), true], 'empty mapping' => [YAML.dump({}), true] }.each do |label, (contents, accepted)|
    it "#{accepted ? 'accepts' : 'rejects'} #{label} without silently changing the intended launch" do
      Dir.mktmpdir('woods-console-config-shape') do |directory|
        marker = File.join(directory, 'executed')
        config = File.join(directory, 'console.yml')
        File.write(config, contents)
        File.write(File.join(directory, 'Rakefile'), <<~RUBY)
          namespace :woods do
            task :console do
              File.write(#{marker.inspect}, 'executed')
            end
          end
        RUBY
        out, err, status = Open3.capture3({ 'WOODS_CONSOLE_CONFIG' => config }, RbConfig.ruby,
                                          File.expand_path('../../exe/woods-console-mcp', __dir__), chdir: directory)

        expect(status.exitstatus).to eq(accepted ? 0 : 1), err
        expect(out).to eq('')
        expect(err).to include('YAML mapping') unless accepted
        expect(File.exist?(marker)).to eq(accepted)
      end
    end
  end

  it 'refuses unsupported nested configuration before replacing the process' do
    Dir.mktmpdir('woods-console-config') do |directory|
      marker = File.join(directory, 'executed')
      config = File.join(directory, 'console.yml')
      command = Shellwords.join([RbConfig.ruby, '-e', "File.write(#{marker.inspect}, 'executed')"])
      File.write(config, YAML.dump('connection' => { 'mode' => 'ssh', 'host' => 'remote.example' },
                                   'command' => command))
      out, err, status = Open3.capture3({ 'WOODS_CONSOLE_CONFIG' => config }, RbConfig.ruby,
                                        File.expand_path('../../exe/woods-console-mcp', __dir__))

      expect(status.exitstatus).to eq(1)
      expect(out).to eq('')
      expect(err).to include('top-level', 'Rails initializer')
      expect(File.exist?(marker)).to be(false)
    end
  end
end
