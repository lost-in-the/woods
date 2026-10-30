# frozen_string_literal: true

require 'open3'
require 'set'
require_relative 'git_command'

module Woods
  # The specs a change to the Woods source can reach, read off the static
  # self-map (#926).
  #
  # Spec files are mapped by the qualified constants they name and the
  # library files they require ({GemMapSource#spec_units}). A change seeds
  # the constants its files define, then follows reverse edges outward.
  # Edges point at constants, so each hop continues from the owner of a
  # dependent method. A namespace every file reopens (`module Woods`) would
  # reach every spec; such hubs are reported, not expanded, so the caller
  # knows a broader run is due.
  #
  # Static by construction: a spec reached only through runtime dispatch,
  # metaprogramming or `described_class` alone is not found. An empty answer
  # means "nothing proven", never "nothing affected".
  class GemMapAffectedSpecs
    # Hops from a changed constant to the specs that name its dependents.
    DEFAULT_DEPTH = 3
    # Dependents above which a constant is a hub and is not expanded.
    DEFAULT_HUB_LIMIT = 150
    SPEC_PREFIX = 'file:spec/'
    private_constant :SPEC_PREFIX

    # Paths changed against the merge base with origin/main, committed or
    # not, relative to the root. Without that base, only uncommitted work.
    #
    # @param root [String] gem root
    # @param base [String] branch the change will merge into
    # @return [Array<String>]
    def self.changed_paths(root, base: 'origin/main')
      merge_base, _error, status = Open3.capture3(*GitCommand.argv(root, 'merge-base', base, 'HEAD'))
      # Without the base fetched, the uncommitted work is all that is known.
      since = status.success? ? merge_base.strip : 'HEAD'
      committed, = Open3.capture2(*GitCommand.argv(root, 'diff', '--name-only', since))
      untracked, = Open3.capture2(*GitCommand.argv(root, 'ls-files', '--others', '--exclude-standard'))
      (committed.lines + untracked.lines).map(&:strip).reject(&:empty?).uniq.sort
    end

    # @param index [PublishedIndex] an open self-map generation
    # @param depth [Integer] reverse-edge hops to follow
    # @param hub_limit [Integer] dependents above which a constant is not expanded
    def initialize(index, depth: DEFAULT_DEPTH, hub_limit: DEFAULT_HUB_LIMIT)
      @index = index
      @depth = depth
      @hub_limit = hub_limit
    end

    # @param paths [Array<String>] changed paths, relative to the gem root
    # @return [Hash] `specs:` sorted spec paths, `seeds:` the constants and
    #   files the change defines, `hubs:` constants reached but not expanded
    def for(paths)
      paths = paths.map { |path| path.to_s.delete_prefix('./') }
      specs = paths.select { |path| path.start_with?('spec/') && path.end_with?('_spec.rb') }.to_set
      seeds, hubs = seeds_for(paths)
      walk(seeds, specs, hubs)
      { specs: specs.sort, seeds: seeds.sort, hubs: hubs.sort }
    end

    private

    def walk(seeds, specs, hubs)
      seen = seeds.to_set
      frontier = seeds
      @depth.times do
        break if frontier.empty?

        next_frontier = []
        frontier.flat_map { |identifier| @index.dependents_of(identifier) }.each do |dependent|
          if dependent.start_with?(SPEC_PREFIX)
            specs.add(dependent.delete_prefix('file:'))
            next
          end

          owner = owner_of(dependent)
          next unless seen.add?(owner)

          hub?(owner) ? hubs.add(owner) : next_frontier << owner
        end
        frontier = next_frontier
      end
    end

    # Each changed file's own unit, plus the constants it defines. A module
    # body that only wraps other definitions (`module Woods` around a class)
    # defines nothing of its own here.
    def seeds_for(paths)
      changed = paths.to_set
      seeds = Set.new
      hubs = Set.new
      @index.units.each do |listed|
        next unless changed.include?(listed['file_path'])

        identifier = definition_for(listed)
        next unless identifier

        hub?(identifier) ? hubs.add(identifier) : seeds.add(identifier)
      end
      [seeds.to_a, hubs]
    end

    def definition_for(listed)
      case listed['type']
      when 'ruby_file' then listed['identifier']
      when 'ruby_method' then listed['namespace']
      when 'ruby_class', 'ruby_module'
        unit = @index.unit(listed['identifier'], type: listed['type'])
        canonical = unit&.dig('metadata', 'canonical_identifier') || listed['identifier']
        wrapper?(listed, unit) ? nil : canonical
      end
    end

    def wrapper?(listed, unit)
      listed['type'] == 'ruby_module' && unit &&
        unit.dig('metadata', 'method_count').to_i.zero? && Array(unit.dig('metadata', 'constants')).empty?
    end

    def owner_of(identifier)
      return identifier if identifier.start_with?('file:')

      identifier.sub(/ \[[^\]]*\]\z/, '').split(/[#.]/).first
    end

    def hub?(identifier)
      @index.dependents_of(identifier).size > @hub_limit
    end
  end
end
