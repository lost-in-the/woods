# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/worktree_seed'

# The seed is built in `<output>.seed-<pid>` and its incremental run executes
# application code in process. A child forked during that run unwinds the
# rest of the seed: promotion of the staging directory, the fallback to a
# full extraction, and the removal of the staging directory. All of it
# belongs to the process that built the staging directory.
RSpec.describe Woods::WorktreeSeed, 'in a child forked during the incremental run',
               if: Process.respond_to?(:fork) do
  let(:base) { Dir.mktmpdir('woods-seed-fork') }
  let(:output) { Pathname.new(File.join(base, 'worktree', 'tmp', 'woods')) }
  let(:staging) { Pathname.new("#{output}.seed-#{Process.pid}") }
  let(:child_full_run) { File.join(base, 'child-ran-a-full-extraction') }

  after { FileUtils.rm_rf(base) }

  before do
    allow(Woods::WorktreeSeed::Verification).to receive(:new)
      .and_return(instance_double(Woods::WorktreeSeed::Verification, call: { 'git_sha' => 'abc123' }))
    allow(Woods::WorktreeSeed::Changes).to receive(:new)
      .and_return(instance_double(Woods::WorktreeSeed::Changes, since: ['app/models/post.rb']))
  end

  # What a seeded copy holds by the time the incremental run starts.
  def stage_seed(seed)
    allow(seed).to receive(:build_staging) do |dir, _baseline|
      FileUtils.mkdir_p(dir.join(Woods::PayloadStore::DIRNAME, 'gen-1'))
      File.write(dir.join(Woods::PayloadStore::DIRNAME, 'gen-1', 'parent.json'), '{}')
      File.write(dir.join(Woods::SourceInputs::PrivateKey::FILE_NAME), 'key')
      File.write(dir.join(Woods::Generation::FILENAME), JSON.generate(number: 1, payload: 'payloads/gen-1'))
    end
  end

  # An extractor whose incremental run forks. The child leaves as +leave+
  # says; the parent records what the child left behind.
  def forking_extractor(leave, seen)
    full_run = child_full_run
    staged = staging
    published = output.join(Woods::Generation::FILENAME)
    Class.new do
      define_method(:initialize) { |output_dir:| @output_dir = output_dir }
      define_method(:extract_all) { File.write(full_run, '') }
      define_method(:raise_on_publication_failure!) { nil }
      define_method(:extract_changed) do |_paths|
        child = fork
        next leave.call if child.nil?

        Process.wait(child)
        seen.merge!(staging_kept: staged.join('payloads', 'gen-1', 'parent.json').file?,
                    promoted_by_child: published.exist?, child_full_run: File.exist?(full_run))
        []
      end
    end
  end

  def seed_once_in_parent(seed)
    parent = Process.pid
    seed.call
  rescue RuntimeError
    raise if Process.pid == parent
  ensure
    exit!(0) unless Process.pid == parent
  end

  {
    'returns normally' => -> {},
    'raises an extraction error' => -> { raise Woods::ExtractionError, 'the child failed' },
    'raises' => -> { raise 'the child failed' },
    'calls exit!' => -> { exit!(0) }
  }.each do |exit_kind, leave|
    it "leaves the staging directory to the parent when the child #{exit_kind}, and the parent still seeds" do
      seen = {}
      seed = described_class.new(source_dir: File.join(base, 'source'), output_dir: output,
                                 root: File.join(base, 'worktree'), extractor: forking_extractor(leave, seen))
      stage_seed(seed)

      result = seed_once_in_parent(seed)

      expect(seen).to eq(staging_kept: true, promoted_by_child: false, child_full_run: false)
      expect(result.mode).to eq(:seeded)
      expect(output.join(Woods::PayloadStore::DIRNAME, 'gen-1', 'parent.json')).to be_file
      expect(staging).not_to exist
    end
  end
end
