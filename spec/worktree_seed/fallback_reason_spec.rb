# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/worktree_seed'

# `woods:seed` prints why it fell back to a full extraction. The reason is a
# line for a terminal or a log, so it names no host path.
RSpec.describe Woods::WorktreeSeed, 'fallback reason' do
  let(:base) { File.realpath(Dir.mktmpdir('woods-seed-reason')) }
  let(:root) { File.join(base, 'worktree') }
  let(:extractor) do
    Class.new do
      def initialize(output_dir:) = @output_dir = output_dir
      def extract_all = nil
      def raise_on_publication_failure! = nil
    end
  end

  before { FileUtils.mkdir_p(root) }
  after { FileUtils.rm_rf(base) }

  def fall_back(because, root: self.root)
    allow(Woods::WorktreeSeed::Verification).to receive(:new).and_raise(Woods::WorktreeSeed::Unverifiable, because)
    described_class.new(source_dir: File.join(base, 'main/tmp/woods'), output_dir: File.join(root, 'tmp/woods'),
                        root: root, extractor: extractor).call
  end

  it 'names a path in this checkout relative to its root' do
    result = fall_back("cannot read #{root}/tmp/woods.seed-12/manifest.json; retry")

    expect(result.mode).to eq(:full)
    expect(result.reason).to eq('cannot read tmp/woods.seed-12/manifest.json; retry')
  end

  it 'names a path in this checkout relative to its root when the root is given through a link' do
    link = File.join(base, 'linked')
    File.symlink(root, link)

    result = fall_back("cannot read #{root}/app/models/post.rb", root: link)

    expect(result.reason).to eq('cannot read app/models/post.rb')
  end

  it 'names any other absolute path by its last component' do
    result = fall_back("the seed's checkout #{base}/main has uncommitted changes")

    expect(result.reason).to eq("the seed's checkout main has uncommitted changes")
  end

  it 'keeps a reason with only relative paths as written' do
    result = fall_back('config/initializers/seed_probe.rb changed and needs a fresh Rails boot')

    expect(result.reason).to eq('config/initializers/seed_probe.rb changed and needs a fresh Rails boot')
  end
end
