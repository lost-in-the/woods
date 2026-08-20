# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require 'yaml'

RSpec.describe 'woods-console-mcp executable' do
  let(:executable) { File.expand_path('../../exe/woods-console-mcp', __dir__) }

  def command_for(output)
    Shellwords.join([RbConfig.ruby, '-e', "STDOUT.write(#{output.inspect})"])
  end

  def write_config(path, output)
    File.write(path, YAML.dump('mode' => 'direct', 'command' => command_for(output)))
  end

  it 'uses WOODS_CONSOLE_CONFIG instead of the default file when both exist' do
    Dir.mktmpdir('woods-console-cli') do |home|
      default_dir = File.join(home, '.woods')
      FileUtils.mkdir_p(default_dir)
      write_config(File.join(default_dir, 'console.yml'), 'default')
      explicit_path = File.join(home, 'explicit.yml')
      write_config(explicit_path, 'explicit')

      stdout, stderr, status = Open3.capture3(
        { 'HOME' => home, 'WOODS_CONSOLE_CONFIG' => explicit_path }, executable
      )

      expect(status).to be_success
      expect(stdout).to eq('explicit')
      expect(stderr).to be_empty
    end
  end

  it 'uses ~/.woods/console.yml when the environment override is absent' do
    Dir.mktmpdir('woods-console-cli') do |home|
      default_dir = File.join(home, '.woods')
      FileUtils.mkdir_p(default_dir)
      write_config(File.join(default_dir, 'console.yml'), 'default')

      stdout, stderr, status = Open3.capture3({ 'HOME' => home }, executable)

      expect(status).to be_success
      expect(stdout).to eq('default')
      expect(stderr).to be_empty
    end
  end

  it 'fails clearly when an explicit config path does not exist' do
    Dir.mktmpdir('woods-console-cli') do |home|
      missing = File.join(home, 'missing.yml')

      _stdout, stderr, status = Open3.capture3(
        { 'HOME' => home, 'WOODS_CONSOLE_CONFIG' => missing }, executable
      )

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('does not exist')
    end
  end

  it 'fails clearly when YAML does not contain a mapping' do
    Dir.mktmpdir('woods-console-cli') do |home|
      path = File.join(home, 'invalid.yml')
      File.write(path, YAML.dump(%w[not a mapping]))

      _stdout, stderr, status = Open3.capture3(
        { 'HOME' => home, 'WOODS_CONSOLE_CONFIG' => path }, executable
      )

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('must contain a YAML mapping')
    end
  end
end
