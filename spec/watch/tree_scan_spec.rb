# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/tree_scan'
require 'woods/watch/watcher'

RSpec.describe Woods::Watch::TreeScan do
  let(:root) { Dir.mktmpdir('woods_tree_scan') }
  let(:ignored) { Woods::Watch::Watcher::DEFAULT_IGNORED_DIRECTORIES }

  after { FileUtils.rm_rf(root) }

  def write(relative, contents = 'x')
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def files
    described_class.files(root: root, ignored: ignored)
  end

  it 'yields regular source files as absolute paths' do
    target = write('app/models/user.rb')

    expect(files).to eq([target])
  end

  it 'skips ignored directories' do
    write('app/models/user.rb')
    write('node_modules/pkg/index.js')
    write('tmp/cache/thing')

    expect(files.map { |f| f.delete_prefix("#{root}/") }).to eq(['app/models/user.rb'])
  end

  it 'skips dotfiles but keeps the ones Woods reads' do
    write('.hidden_thing', 'x')
    ruby_version = write('.ruby-version', "3.3.6\n")

    expect(files).to eq([ruby_version])
  end

  # ReloadPolicy classifies these :restart (they are boot-captured config), so
  # filtering them out here would make that classification unreachable — the
  # daemon would never learn the file changed at all.
  it 'keeps dotenv files, which the reload policy treats as boot state' do
    written = ['.env', '.env.local', '.env.development'].map { |name| write(name, 'A=1') }
    written << write('.ruby-version', "3.3.6\n")

    expect(files).to match_array(written)
  end

  # The point of Find.prune over Dir.glob: an ignored subtree must never be
  # entered. A glob enumerates and then filters, so on a large tree across a
  # bind mount it stats everything inside .git and node_modules before throwing
  # the results away — which can exceed the poll interval on its own.
  it 'never descends into an ignored directory' do
    write('app/models/user.rb')
    write('.git/objects/ab/cdef')
    write('node_modules/big/nested/deep/file.js')

    visited = []
    allow(File).to receive(:directory?).and_wrap_original do |original, path|
      visited << path
      original.call(path)
    end
    files

    expect(visited.grep(/node_modules|\.git/).map { |p| p.delete_prefix("#{root}/") })
      .to contain_exactly('.git', 'node_modules')
  end

  # Generated worktree paths really do contain brackets, and an interpolated
  # glob pattern would match nothing there — silently watching an empty tree.
  it 'walks a root containing glob metacharacters' do
    nested = File.join(root, 'slot[1]{a}')
    FileUtils.mkdir_p(nested)
    File.write(File.join(nested, 'thing.rb'), 'x')

    expect(described_class.files(root: nested, ignored: ignored))
      .to eq([File.join(nested, 'thing.rb')])
  end

  it 'returns nothing rather than raising when the root vanishes' do
    missing = File.join(root, 'gone')

    expect(described_class.files(root: missing, ignored: ignored)).to eq([])
  end

  # `Find` stats with lstat, so before this a symlinked directory was neither
  # descended nor reported — the entry silently vanished, while a full
  # extraction's `Dir.glob` followed it and indexed the tree.
  describe 'symlinked directories' do
    # The target lives *outside* the watched root, which is the case that was
    # invisible: a monorepo linking shared code in, or a symlinked app/models.
    it 'walks files under a symlinked directory' do
      real = Dir.mktmpdir('woods_tree_scan_target')
      File.write(File.join(real, 'shared.rb'), 'x')
      link = File.join(root, 'app_link')
      File.symlink(real, link)

      expect(described_class.files(root: root, ignored: ignored))
        .to include(File.join(link, 'shared.rb'))
    ensure
      FileUtils.rm_rf(real)
    end

    it 'terminates when a link points at its own ancestor' do
      nested = File.join(root, 'app')
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, 'thing.rb'), 'x')
      File.symlink(root, File.join(nested, 'loop'))

      expect { described_class.files(root: root, ignored: ignored) }.not_to raise_error
    end

    # Outside the root, so the only routes to it are the two links. A target
    # that also lives inside the tree legitimately appears twice — once at its
    # real path, once through the link — and that is not what this guards.
    it 'yields a shared target once when two links point at it' do
      real = Dir.mktmpdir('woods_tree_scan_shared')
      File.write(File.join(real, 'thing.rb'), 'x')
      File.symlink(real, File.join(root, 'a_link'))
      File.symlink(real, File.join(root, 'b_link'))

      found = described_class.files(root: root, ignored: ignored)
      expect(found.count { |path| path.end_with?('thing.rb') }).to eq(1)
    ensure
      FileUtils.rm_rf(real)
    end

    it 'does not follow a link into an ignored directory' do
      real = File.join(root, 'node_modules')
      FileUtils.mkdir_p(real)
      File.write(File.join(real, 'dep.rb'), 'x')
      File.symlink(real, File.join(root, 'node_modules_link'))

      expect(described_class.files(root: root, ignored: %w[node_modules node_modules_link]))
        .to be_empty
    end

    it 'ignores a broken link without raising' do
      File.symlink(File.join(root, 'missing'), File.join(root, 'dangling'))

      expect { described_class.files(root: root, ignored: ignored) }.not_to raise_error
    end
  end
end
