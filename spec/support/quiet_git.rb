# frozen_string_literal: true

require 'fileutils'
require 'open3'

# Keeps a throwaway git repository still once a git command has returned, and
# copies one without assuming it is.
#
# `git commit` can leave work running after it exits: auto maintenance and
# auto gc detach, take `.git/objects/maintenance.lock` or `gc.pid`, and delete
# them when they finish. A copy or a cleanup that listed the lock and then
# reached for it fails with Errno::ENOENT or Errno::ENOTEMPTY.
module QuietGit
  # Every setting that lets git write to a repository in the background.
  SETTINGS = {
    'maintenance.auto' => 'false',
    'maintenance.autoDetach' => 'false',
    'gc.auto' => '0',
    'gc.autoDetach' => 'false',
    'core.fsmonitor' => 'false'
  }.freeze

  module_function

  # @param root [String] a repository that `git init` has already created
  # @param env [Hash] extra environment for the git commands
  # @return [void]
  def configure(root, env: {})
    SETTINGS.each do |key, value|
      output, status = Open3.capture2e(env, 'git', 'config', key, value, chdir: root)
      raise "git config #{key} failed: #{output}" unless status.success?
    end
  end

  # Copy a directory tree into +target+, skipping any entry that disappears
  # between being listed and being copied. Only the tree itself must exist.
  #
  # @param source [String] directory to copy
  # @param target [String] directory to create or fill
  # @return [void]
  def copy_tree(source, target)
    names = Dir.children(source)
    FileUtils.mkdir_p(target)
    names.each { |name| copy_entry(File.join(source, name), File.join(target, name)) }
  end

  def copy_entry(from, to)
    stat = File.lstat(from)
    if stat.symlink?
      File.symlink(File.readlink(from), to)
    elsif stat.directory?
      copy_tree(from, to)
    else
      FileUtils.copy_file(from, to)
    end
  rescue Errno::ENOENT
    nil
  end
  private_class_method :copy_entry
end
