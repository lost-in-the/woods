# frozen_string_literal: true

require_relative '../woods/release/preparer'
require_relative '../woods/release/rake_support'

# The two version-state transitions on `main`, plus the guard that keeps
# publication in the dispatch workflow. See .claude/skills/release-flow/SKILL.md
# and the release section of CONTRIBUTING.md.
namespace :release do
  desc 'Prepare a release commit: bump VERSION, fold the changelog, restate the docs'
  task :prepare, [:version] do |_task, args|
    Woods::Release::RakeSupport.run('release:prepare', args[:version]) do |root, version|
      result = Woods::Release::Preparer.prepare(root: root, version: version)
      Rake::Task['release_v2:write_surface_inventory'].invoke
      result
    end
  end

  desc 'Reopen development after a release: set the next X.Y.Z.alpha and restore the alpha docs'
  task :reopen, [:version] do |_task, args|
    Woods::Release::RakeSupport.run('release:reopen', args[:version]) do |root, version|
      Woods::Release::Preparer.reopen(root: root, version: version)
    end
  end
end

# `bundler/gem_tasks` defines a `release` entry point that tags and pushes to
# RubyGems from wherever it runs. Nothing is published from a laptop: the
# repository_dispatch workflow publishes the exact bytes CI tested.
Woods::Release::RakeSupport.block_task(
  'release',
  'rake release would tag and publish from this machine. Use bin/rake "release:prepare[<version>]", ' \
  'then tag the merge commit and trigger the dispatch workflow.'
)
Woods::Release::RakeSupport.block_task(
  'release:rubygem_push',
  'nothing is published from a laptop. The dispatch workflow pushes the gem bytes CI tested.'
)
