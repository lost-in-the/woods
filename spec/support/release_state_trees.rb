# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require 'woods/release/preparer'

require_relative 'release_repository'

# Generates the three states a checked-in tree is ever in (the alpha
# development marker, a prerelease, a final release) from the release fixture,
# once per suite run.
#
# The release contract used to be asserted against whichever state this
# checkout happened to be in, so the release commit that moved the tree out of
# the alpha state could not pass its own specs. Building all three here proves
# the contract in every state in one run, whatever state the checkout is in.
module ReleaseStateTrees
  extend ReleaseRepositoryHelper

  BASE_VERSION = '2.0.0'
  ALPHA_VERSION = "#{BASE_VERSION}.alpha".freeze
  BETA_VERSION = "#{BASE_VERSION}.beta1".freeze
  DATE = Date.new(2026, 9, 10)
  STATES = %w[alpha beta1 final].freeze

  class << self
    # @return [Hash{String => String}] state name to a tree checked in at it
    def roots
      @roots ||= build
    end

    private

    def build
      workspace = Dir.mktmpdir('woods-release-states')
      at_exit { FileUtils.remove_entry(workspace, true) }
      work = build_release_repository(File.join(workspace, 'work'), version: ALPHA_VERSION)

      roots = { 'alpha' => snapshot(workspace, 'alpha', work) }
      roots['beta1'] = release(workspace, 'beta1', work, BETA_VERSION)
      roots['final'] = release(workspace, 'final', work, BASE_VERSION)
      roots.freeze
    end

    def release(workspace, name, work, version)
      Woods::Release::Preparer.prepare(root: work, version: version, date: DATE)
      commit_release_repository_changes(work, message: "release #{version}")
      snapshot(workspace, name, work)
    end

    def snapshot(workspace, name, work)
      target = File.join(workspace, name)
      FileUtils.cp_r(work, target)
      target
    end
  end
end
