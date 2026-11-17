# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'woods/generation'
require 'woods/source_inputs/private_key'
require_relative '../support/source_input_app'

# `rake woods:seed` in fresh Rails processes: a published index in one git
# worktree of an app, the task in a second worktree. The task holds the
# target's writer lock for the whole seed, which the in-process examples in
# spec/integration/incremental_equivalence_spec.rb reproduce but cannot print.
RSpec.describe 'woods:seed through rake', :aggregate_failures, :booted_app do
  include SourceInputApp

  let(:root) { File.expand_path('../..', __dir__) }

  def git(dir, *args)
    out, err, status = Open3.capture3('git', '-C', dir, '-c', 'user.name=Seed Spec',
                                      '-c', 'user.email=seed@example.invalid', '-c', 'commit.gpgsign=false', *args)
    raise err unless status.success?

    out
  end

  def rake(app, task)
    Open3.capture3(RbConfig.ruby, File.join(root, 'bin/rake'), task, chdir: app)
  end

  def index(app)
    File.join(app, 'tmp/woods')
  end

  def key(app)
    File.binread(File.join(index(app), Woods::SourceInputs::PrivateKey::FILE_NAME))
  end

  around do |example|
    Dir.mktmpdir('woods-seed-task') do |base|
      @base = File.realpath(base)
      @main = File.join(@base, 'main')
      @work = File.join(@base, 'work')
      FileUtils.mkdir_p(@main)
      make_source_app(@main)
      File.write(File.join(@main, '.gitignore'), "tmp/\n")
      git(@main, 'init', '-q', '-b', 'main')
      git(@main, 'add', '.')
      git(@main, 'commit', '-qm', 'Seed commit')
      out, err, status = rake(@main, 'woods:extract')
      raise "#{out}\n#{err}" unless status.success?

      git(@main, 'worktree', 'add', '-q', '-b', 'work', @work)
      FileUtils.mkdir_p(File.join(@work, 'app/services'))
      File.write(File.join(@work, 'app/services/seed_probe_service.rb'),
                 "class SeedProbeService\n  def call\n    Post.new\n  end\nend\n")
      example.run
    end
  end

  it 'seeds the new worktree and brings it up to date' do
    out, err, status = rake(@work, "woods:seed[#{index(@main)}]")

    expect(status).to be_success, "#{out}\n#{err}"
    expect(out).to include('Seeded and brought up to date with 1 changed paths.')
    expect(out).not_to include('full extraction')
    expect(key(@work)).to eq(key(@main))
    expect(Dir.glob("#{index(@work)}.seed-*")).to be_empty
    payload = Woods::Generation.new(output_dir: index(@work)).payload_dir
    expect(Dir.glob('**/*.json', base: payload.to_s).join("\n")).to include('SeedProbeService')
  end

  it 'says in one line, without a host path, that it fell back to a full extraction and why' do
    File.write(File.join(@main, 'app/services/dirty_service.rb'), "class DirtyService; end\n")

    out, err, status = rake(@work, "woods:seed[#{index(@main)}]")

    expect(status).to be_success, "#{out}\n#{err}"
    fallback = out.lines.grep(/full extraction/)
    expect(fallback.size).to eq(1)
    expect(fallback.first).to start_with('Not seeded, ran a full extraction instead: ')
    expect(fallback.first).to include('uncommitted changes')
    expect(fallback.first).not_to include(@base)
    expect(key(@work)).not_to eq(key(@main))
    expect(Woods::Generation.new(output_dir: index(@work)).current.reason).to eq('full')
  end
end
