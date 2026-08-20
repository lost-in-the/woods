# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'fileutils'
require 'open3'

# `woods:incremental`'s three git-diff branches used to parse
# `git diff --name-only` with `output.lines.map(&:strip)`. That corrupts three
# cases at once: a path containing a newline splits into two; a non-ASCII path
# is octal-escaped inside quotes by git's default `core.quotePath` (and the
# dispatcher then can't match it to any rule); and a rename reports only the
# new path, so the old path's unit is never pruned. `woods_changed_paths_for_range`
# replaces all three call sites with one NUL-delimited, rename-decomposed parse.
RSpec.describe 'woods:incremental changed-path parsing' do
  before { load File.expand_path('../../lib/tasks/woods.rake', __dir__) }

  def run(dir, *args)
    out, status = Open3.capture2e(*args, chdir: dir)
    raise "command failed: #{args.join(' ')}\n#{out}" unless status.success?

    out.strip
  end

  def init_repo(dir)
    run(dir, 'git', 'init', '--quiet', '--initial-branch', 'main')
    run(dir, 'git', 'config', 'user.email', 'test@example.com')
    run(dir, 'git', 'config', 'user.name', 'Test')
    # The host's global config leaks into a fixture repo — a signer-required
    # commit.gpgsign=true hangs every commit below on a machine with a locked
    # agent. Pin the hermetic behaviour, same as spec/git_provenance_spec.rb.
    run(dir, 'git', 'config', 'commit.gpgsign', 'false')
  end

  it 'reaches both halves of a rename and an unescaped UTF-8 path' do
    Dir.mktmpdir('woods_incremental_git') do |dir|
      init_repo(dir)
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/foo.rb'), "class Foo; end\n")
      File.write(File.join(dir, 'app/models/héllo.rb'), 'hello')
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'initial')

      run(dir, 'git', 'mv', 'app/models/foo.rb', 'app/models/bar.rb')
      File.open(File.join(dir, 'app/models/héllo.rb'), 'a') { |f| f.write('!') }
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'rename and edit')

      changed = Dir.chdir(dir) { Object.new.send(:woods_changed_paths_for_range, 'HEAD~1..HEAD') }

      # Both halves of the rename reach the change set — the new path (so the
      # unit is re-extracted) and the old one (so its unit is pruned).
      expect(changed).to include('app/models/bar.rb')
      expect(changed).to include('app/models/foo.rb')

      # Unescaped, not the octal-quoted form core.quotePath produces by default.
      expect(changed).to include('app/models/héllo.rb')
      expect(changed.grep(/\\\d{3}/)).to be_empty
    end
  end

  it 'never returns a corrupted (blank or partial) entry' do
    Dir.mktmpdir('woods_incremental_git') do |dir|
      init_repo(dir)
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/user.rb'), "class User; end\n")
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'initial')

      File.write(File.join(dir, 'app/models/user.rb'), "class User\nend\n")
      run(dir, 'git', 'add', '-A')
      run(dir, 'git', 'commit', '--quiet', '-m', 'edit')

      changed = Dir.chdir(dir) { Object.new.send(:woods_changed_paths_for_range, 'HEAD~1..HEAD') }

      expect(changed).to eq(['app/models/user.rb'])
    end
  end
end
