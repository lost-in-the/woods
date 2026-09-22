# frozen_string_literal: true

require 'tmpdir'
require 'json'

module FixtureOracles
  module_function

  def check(name, actual, expected)
    { name: name, passed: actual == expected, actual: actual, expected: expected }
  end

  def cache_arity(scope)
    cache = scope.const_get(:FixtureCache)
    pairs = [[[], ['']], [['a', 'b'], ['1:a1:b']], [['a' * 40, 'b' * 40], ["40:#{'a' * 40}40:#{'b' * 40}"]]]
    pairs.each_with_index.map do |(left, right), index|
      keys = [left, right].map { |parts| cache.cache_key(:search, *parts) }
      check("distinct_sequence_#{index}", keys.uniq.size, 2)
    end
  end

  def route_precedence(scope)
    names = %w[root download_report image_preview books]
    mapping = names.to_h { |name| [name, { controller: 'PagesController', action: name }] }
    routes = scope.const_get(:FixtureRoutes).new(mapping)
    checks = names.flat_map do |name|
      %w[path url].map do |suffix|
        check("named_#{name}_#{suffix}", routes.resolve_route_helper("#{name}_#{suffix}"), mapping.fetch(name))
      end
    end
    checks << check('unresolved_helper', routes.resolve_route_helper('asset_url'), nil)
  end

  def snapshot_retention(scope)
    ['{broken', '[]', 'null'].map do |bytes|
      Dir.mktmpdir('review-retention-oracle') do |directory|
        store = scope.const_get(:FixtureSnapshots).new(dir: directory, retention: 2)
        File.write(File.join(directory, 'bad123.json'), bytes)
        File.write(File.join(directory, 'notes.json'), 'leave untouched')
        Dir.mkdir(File.join(directory, 'ddd444.json'))
        store.capture('aaa111', '2026-02-01')
        store.capture('bbb222', '2026-01-01')
        check("retention_#{bytes}", Dir.children(directory).sort,
              %w[aaa111.json bbb222.json ddd444.json notes.json])
      end
    end
  end
end
