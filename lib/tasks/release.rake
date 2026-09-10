# frozen_string_literal: true

require_relative '../woods/release/preflight'
require_relative '../woods/release/preparer'
require_relative '../woods/release/rake_support'

# The two version-state transitions on `main`, plus the guard that keeps
# publication in the dispatch workflow. See .claude/skills/release-flow/SKILL.md
# and the release section of CONTRIBUTING.md.
namespace :release do
  desc 'Advisory-only: check the live release environment, REQUIRED_CI_JOBS, and merge-multiple, without writing'
  task :preflight do
    puts Woods::Release::Preflight.report(root: Woods::Release::RakeSupport::ROOT)
  end

  desc 'Prepare a release commit: bump VERSION, fold the changelog, restate the docs'
  task :prepare, [:version] do |_task, args|
    Woods::Release::RakeSupport.run('release:prepare', args[:version]) do |root, version|
      result = Woods::Release::Preparer.prepare(root: root, version: version)
      # After the documentation edits, never before: the inventory records what
      # the docs claim. Only listed as changed when regenerating it actually
      # moved the bytes, so the reviewer's "Changed:" list matches the diff.
      inventory_path = File.join(root, Woods::Release::RakeSupport::SURFACE_INVENTORY_PATH)
      before_inventory = File.exist?(inventory_path) ? File.binread(inventory_path) : nil
      Rake::Task['release_v2:write_surface_inventory'].invoke
      after_inventory = File.exist?(inventory_path) ? File.binread(inventory_path) : nil
      # Advisory only: never blocks prepare on network access, and prints
      # before the report below so its tag and dispatch commands print last.
      Rake::Task['release:preflight'].invoke
      if after_inventory == before_inventory
        result
      else
        result.with_changed(Woods::Release::RakeSupport::SURFACE_INVENTORY_PATH)
      end
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
  description: 'BLOCKED: aborts, because nothing is published from a laptop; run release:prepare instead',
  message: 'rake release would tag and publish from this machine. Use bin/rake "release:prepare[<version>]", ' \
           'then tag the merge commit and trigger the dispatch workflow.'
)
Woods::Release::RakeSupport.block_task(
  'release:rubygem_push',
  description: 'BLOCKED: aborts, because the dispatch workflow publishes the gem; run release:prepare instead',
  message: 'nothing is published from a laptop. The dispatch workflow pushes the gem bytes CI tested.'
)
