# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'woods'

# `woods-mcp-start --checkout` takes no index path: it serves the index of the
# checkout it was started in, so a project configuration can name no
# absolute path.
RSpec.describe 'woods-mcp-start --checkout' do
  let(:wrapper) { File.expand_path('../../exe/woods-mcp-start', __dir__) }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-checkout-launch') do |directory|
      @base = File.realpath(directory)
      example.run
    end
  end

  # A checkout with a HEAD file; `index:` publishes a fixture index under
  # `output` that records +root+ as its source.
  def checkout(root, index: true, output: 'tmp/woods', worktree_of: nil)
    FileUtils.mkdir_p(root)
    branch = worktree_of ? File.basename(root) : 'main'
    if worktree_of
      private_dir = File.join(worktree_of, '.git', 'worktrees', File.basename(root))
      FileUtils.mkdir_p(private_dir)
      File.write(File.join(private_dir, 'HEAD'), "ref: refs/heads/#{branch}\n")
      File.write(File.join(root, '.git'), "gitdir: #{private_dir}\n")
    else
      FileUtils.mkdir_p(File.join(root, '.git'))
      File.write(File.join(root, '.git', 'HEAD'), "ref: refs/heads/main\n")
    end
    publish(File.expand_path(output, root), root, branch) if index
    root
  end

  def publish(index_dir, root, branch)
    payload = File.join(index_dir, 'payloads', 'gen-1')
    FileUtils.mkdir_p(File.dirname(payload))
    FileUtils.cp_r(fixture_dir, payload)
    manifest = JSON.parse(File.read(File.join(payload, 'manifest.json')))
                   .merge('woods_version' => Woods::VERSION, 'root' => root, 'git_branch' => branch)
    File.write(File.join(payload, 'manifest.json'), JSON.generate(manifest))
    File.write(File.join(index_dir, 'generation.json'),
               JSON.generate(number: 1, token: 't1', updated_at: '2026-11-01T10:00:00Z', payload: 'payloads/gen-1'))
  end

  # Runs the real launcher with exec intercepted: exit 42 and the argv it
  # would have exec'd with, or its own exit status.
  def launch(cwd:, args: ['--checkout'], env: {})
    log = File.join(@base, 'exec.json')
    harness = <<~RUBY
      require 'json'
      wrapper, log, *argv = ARGV
      ARGV.replace(argv)
      Kernel.define_method(:exec) do |*command|
        File.write(log, JSON.generate(command))
        exit 42
      end
      load wrapper
    RUBY
    env = { 'WOODS_DIR' => nil, 'WOODS_OUTPUT' => nil, 'WOODS_MCP_CHECKOUT' => nil, 'WOODS_MCP_ALLOW_MISMATCH' => nil,
            'WOODS_MCP_CLIENT_ROOT' => nil, 'WOODS_MCP_CLIENT_ROOT_AS' => nil }.merge(env)
    _out, errors, status = Open3.capture3(env, RbConfig.ruby, '-e', harness, wrapper, log, *args, chdir: cwd)
    [status.exitstatus, errors, status.exitstatus == 42 ? JSON.parse(File.read(log)).last : nil]
  end

  it "serves the checkout's own tmp/woods from any directory inside it" do
    root = checkout(File.join(@base, 'shop'))
    nested = File.join(root, 'app', 'models')
    FileUtils.mkdir_p(nested)

    code, errors, served = launch(cwd: nested)

    expect(code).to eq(42), errors
    expect(served).to eq(File.join(root, 'tmp', 'woods'))
    expect(errors).not_to include('Warning')
  end

  it 'takes WOODS_MCP_CHECKOUT=1 as the flag, and not 0' do
    root = checkout(File.join(@base, 'shop'))

    on, on_errors, served = launch(cwd: root, args: [], env: { 'WOODS_MCP_CHECKOUT' => '1' })
    off, off_errors, = launch(cwd: root, args: [], env: { 'WOODS_MCP_CHECKOUT' => '0' })

    expect(on).to eq(42), on_errors
    expect(served).to eq(File.join(root, 'tmp', 'woods'))
    expect(off).to eq(1)
    expect(off_errors).to include('No index directory specified')
  end

  describe 'in a linked worktree' do
    it "serves the worktree's own index, never the main checkout's, even nested inside it" do
      main = checkout(File.join(@base, 'shop'))
      worktree = checkout(File.join(main, 'worktrees', 'topic'), worktree_of: main)

      code, errors, served = launch(cwd: worktree)

      expect(code).to eq(42), errors
      expect(served).to eq(File.join(worktree, 'tmp', 'woods'))
      expect(errors).not_to include('Warning')
    end

    it 'refuses a worktree with no index of its own instead of falling back to the main checkout' do
      main = checkout(File.join(@base, 'shop'))
      worktree = checkout(File.join(@base, 'shop-topic'), worktree_of: main, index: false)

      code, errors, = launch(cwd: worktree)

      expect(code).to eq(1)
      expect(errors).to include("Index directory does not exist: #{File.join(worktree, 'tmp', 'woods')}")
      expect(errors).not_to include(File.join(main, 'tmp', 'woods'))
    end
  end

  describe 'with WOODS_OUTPUT' do
    it 'resolves a relative output directory against the checkout, not the working directory' do
      root = checkout(File.join(@base, 'shop'), output: 'web/tmp/index')
      nested = File.join(root, 'web')

      code, errors, served = launch(cwd: nested, env: { 'WOODS_OUTPUT' => 'web/tmp/index' })

      expect(code).to eq(42), errors
      expect(served).to eq(File.join(root, 'web', 'tmp', 'index'))
    end

    it 'accepts an absolute output directory inside the checkout and refuses one outside it' do
      root = checkout(File.join(@base, 'shop'))
      other = checkout(File.join(@base, 'other-shop'))

      inside, inside_errors, served = launch(cwd: root, env: { 'WOODS_OUTPUT' => File.join(root, 'tmp', 'woods') })
      outside, outside_errors, = launch(cwd: root, env: { 'WOODS_OUTPUT' => File.join(other, 'tmp', 'woods') })

      expect(inside).to eq(42), inside_errors
      expect(served).to eq(File.join(root, 'tmp', 'woods'))
      expect(outside).to eq(1)
      expect(outside_errors).to include('WOODS_OUTPUT', File.join(other, 'tmp', 'woods'),
                                        "outside the checkout #{root}")
    end
  end

  it 'refuses to run outside any checkout, naming the alternative' do
    outside = File.join(@base, 'plain-directory')
    FileUtils.mkdir_p(outside)

    code, errors, = launch(cwd: outside)

    expect(code).to eq(1)
    expect(errors).to include("#{outside} is not inside a git checkout", 'pass the index directory as a path')
  end

  it 'refuses an index path as well, given as an argument or by WOODS_DIR' do
    root = checkout(File.join(@base, 'shop'))
    index = File.join(root, 'tmp', 'woods')

    [{ args: ['--checkout', index] }, { args: [index], env: { 'WOODS_MCP_CHECKOUT' => '1' } },
     { env: { 'WOODS_DIR' => index } }].each do |form|
      code, errors, = launch(cwd: root, **form)

      expect(code).to eq(1), "#{form}: #{errors}"
      expect(errors).to include('--checkout takes no index path', index)
    end
  end
end
