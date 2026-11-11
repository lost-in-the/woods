# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/worktree_seed'

# Seeding replaces the target's payloads and restarts it at generation 1. A
# target whose generation.json exists but is malformed is not an unpublished
# index: readers refuse it, so the seed must not write over it either.
RSpec.describe Woods::WorktreeSeed do
  let(:base) { Dir.mktmpdir('woods-seed-target-marker') }
  let(:output) { File.join(base, 'worktree', 'tmp', 'woods') }
  let(:sentinel) { File.join(output, 'payloads', 'gen-3', 'sentinel.json') }
  let(:marker) { File.join(output, Woods::Generation::FILENAME) }
  let(:extractor) { Class.new { def initialize(**) = raise('no extraction expected') } }

  before do
    FileUtils.mkdir_p(File.dirname(sentinel))
    File.write(sentinel, 'kept')
    File.write(marker, '{broken')
  end

  after { FileUtils.rm_rf(base) }

  it 'refuses to seed or extract over a corrupt target marker' do
    seed = described_class.new(source_dir: File.join(base, 'seed'), output_dir: output,
                               root: File.join(base, 'worktree'), extractor: extractor)

    expect { seed.call }.to raise_error(Woods::Generation::InvalidMarker)
    expect(File.read(marker)).to eq('{broken')
    expect(File.read(sentinel)).to eq('kept')
  end
end
