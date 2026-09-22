# frozen_string_literal: true

first = FixtureCache.cache_key(:search, 'book', 'page')
second = FixtureCache.cache_key(:search, 'book', 'page')
raise 'cache keys must be deterministic' unless first == second
raise 'domains must be separate' if first == FixtureCache.cache_key(:metadata, 'book', 'page')
