# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# exe/woods-mcp-start hands over to woods-mcp with exec. Execing the script
# path directly goes through its `#!/usr/bin/env ruby` line, which can pick a
# different Ruby and drops any -I the launcher was started with (#992).
RSpec.describe 'woods-mcp-start exec handoff' do
  let(:wrapper) { File.expand_path('../../exe/woods-mcp-start', __dir__) }
  let(:server) { File.expand_path('../../exe/woods-mcp', __dir__) }
  let(:woods_lib) { File.expand_path('../../lib', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-launcher-exec') do |directory|
      @directory = directory
      @index = File.join(directory, 'index')
      FileUtils.mkdir_p(@index)
      FileUtils.touch(File.join(@index, 'manifest.json'))
      example.run
    end
  end

  # Runs the real launcher with exec intercepted. The harness records the argv
  # and the RUBYLIB it would have exec'd with (and the one it started with,
  # since a bundled spec run can already set one), then exits 42.
  # `bindir:` stands in for a Ruby installed under that directory.
  def handoff(ruby_flags: [], env: {}, bindir: nil)
    log = File.join(@directory, 'exec.json')
    harness = <<~RUBY
      require 'json'
      require 'rbconfig'
      wrapper, index, log, bindir = ARGV
      RbConfig::CONFIG['bindir'] = bindir unless bindir.empty?
      ARGV.replace([index])
      before = ENV.fetch('RUBYLIB', nil)
      Kernel.define_method(:exec) do |*argv|
        File.write(log, JSON.generate('argv' => argv, 'rubylib' => ENV.fetch('RUBYLIB', nil), 'before' => before))
        exit 42
      end
      load wrapper
    RUBY
    env = { 'RUBYLIB' => nil, 'WOODS_MCP_ALLOW_MISMATCH' => '1' }.merge(env)
    # Outside the bundle: bundler/setup would put Woods' lib on the load path
    # itself and hide whether the launcher's own -I is what got carried.
    _out, errors, status = Bundler.with_unbundled_env do
      Open3.capture3(env, RbConfig.ruby, *ruby_flags, '-e', harness, wrapper, @index, log, bindir.to_s,
                     chdir: @directory)
    end
    expect(status.exitstatus).to eq(42), errors
    JSON.parse(File.read(log))
  end

  it 'execs woods-mcp through the running Ruby, not the script shebang' do
    argv = handoff.fetch('argv')

    expect(argv).to eq([RbConfig.ruby, server, @index])
  end

  it 'execs an unquoted interpreter path when Ruby lives under a directory with a space' do
    bindir = File.join(@directory, 'Ruby Install', 'bin')
    FileUtils.mkdir_p(bindir)
    interpreter = File.join(bindir, File.basename(RbConfig.ruby))
    File.symlink(RbConfig.ruby, interpreter)

    executable = handoff(bindir: bindir).fetch('argv').first

    expect(executable).to eq(interpreter)
    expect(File.executable?(executable)).to be(true)
  end

  it "carries an -I for Woods' own lib forward to woods-mcp" do
    rubylib = handoff(ruby_flags: ['-I', woods_lib]).fetch('rubylib')

    expect(rubylib.to_s.split(File::PATH_SEPARATOR)).to include(woods_lib)
  end

  it 'keeps an existing RUBYLIB and adds the lib only once' do
    existing = File.join(@directory, 'other_lib')
    rubylib = handoff(ruby_flags: ['-I', woods_lib],
                      env: { 'RUBYLIB' => [existing, woods_lib].join(File::PATH_SEPARATOR) }).fetch('rubylib')

    entries = rubylib.split(File::PATH_SEPARATOR)
    expect(entries).to include(existing)
    expect(entries.count(woods_lib)).to eq(1)
  end

  it "puts Woods' own lib first even when RUBYLIB already lists it behind another checkout" do
    other_checkout = File.join(@directory, 'other_checkout', 'lib')
    rubylib = handoff(ruby_flags: ['-I', woods_lib],
                      env: { 'RUBYLIB' => [other_checkout, woods_lib].join(File::PATH_SEPARATOR) }).fetch('rubylib')

    expect(rubylib.split(File::PATH_SEPARATOR)).to eq([woods_lib, other_checkout])
  end

  it "leaves RUBYLIB untouched when Woods' lib was not on the load path" do
    result = handoff

    expect(result.fetch('rubylib')).to eq(result.fetch('before'))
  end
end
