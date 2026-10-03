# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe QuietGit do
  def git(root, *args)
    output, status = Open3.capture2e('git', *args, chdir: root)
    raise output unless status.success?

    output.strip
  end

  it 'turns off every background writer in the release fixture repository' do
    with_release_repository do |root|
      settings = described_class::SETTINGS.keys.to_h { |key| [key, git(root, 'config', '--local', '--get', key)] }

      expect(settings).to eq('maintenance.auto' => 'false', 'maintenance.autoDetach' => 'false',
                             'gc.auto' => '0', 'gc.autoDetach' => 'false', 'core.fsmonitor' => 'false')
    end
  end

  describe '.copy_tree' do
    around { |example| Dir.mktmpdir('woods-quiet-git') { |dir| (@dir = dir) && example.run } }

    let(:source) { File.join(@dir, 'work') }
    let(:target) { File.join(@dir, 'snapshot') }
    let(:objects) { File.join(source, '.git', 'objects') }

    before do
      FileUtils.mkdir_p(File.join(objects, 'pack'))
      File.write(File.join(source, 'CHANGELOG.md'), "# Changelog é\n")
      File.write(File.join(objects, 'pack', 'widget.pack'), 'packed')
      File.write(File.join(source, 'run'), "#!/bin/sh\n", perm: 0o755)
      File.symlink('CHANGELOG.md', File.join(source, 'LATEST'))
    end

    def tree(root)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.to_h do |path|
        full = File.join(root, path)
        next [path, [:link, File.readlink(full)]] if File.symlink?(full)

        [path, File.directory?(full) ? :directory : [File.binread(full), File.stat(full).mode & 0o777]]
      end
    end

    it 'copies files, modes, links and dot directories into a new target' do
      described_class.copy_tree(source, target)

      expect(tree(target)).to eq(tree(source))
      expect(tree(target)).to include('.git/objects/pack/widget.pack' => ['packed', 0o644],
                                      'run' => ["#!/bin/sh\n", 0o755], 'LATEST' => [:link, 'CHANGELOG.md'])
    end

    it 'skips a lock file that git removes between the listing and the copy' do
      lock = File.join(objects, 'maintenance.lock')
      File.write(lock, '')
      allow(Dir).to receive(:children).and_wrap_original do |original, directory|
        original.call(directory).tap { FileUtils.rm_f(lock) if directory == objects }
      end

      described_class.copy_tree(source, target)

      expect(tree(target).keys).to include('.git/objects/pack/widget.pack', 'CHANGELOG.md')
      expect(tree(target).keys).not_to include('.git/objects/maintenance.lock')
    end

    it 'skips a directory that git removes between the listing and the descent' do
      scratch = File.join(objects, 'incoming-widget')
      FileUtils.mkdir_p(scratch)
      allow(Dir).to receive(:children).and_wrap_original do |original, directory|
        original.call(directory).tap { FileUtils.rm_rf(scratch) if directory == objects }
      end

      described_class.copy_tree(source, target)

      expect(tree(target).keys).to include('.git/objects/pack/widget.pack')
      expect(tree(target).keys).not_to include('.git/objects/incoming-widget')
    end

    it 'still raises when the tree to copy does not exist' do
      expect { described_class.copy_tree(File.join(@dir, 'absent'), target) }.to raise_error(Errno::ENOENT)
    end
  end

  it 'snapshots every release state as a clean repository' do
    ReleaseStateTrees.roots.each do |state, root|
      expect(git(root, 'status', '--porcelain')).to eq(''), state
      expect(git(root, 'config', '--local', '--get', 'maintenance.auto')).to eq('false'), state
    end
  end
end
