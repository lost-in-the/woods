# frozen_string_literal: true

require 'tmpdir'

Dir.mktmpdir('review-snapshots') do |directory|
  store = FixtureSnapshots.new(dir: directory, retention: 2)
  store.capture('aaa111', '2026-01-01')
  store.capture('bbb222', '2026-01-02')
  store.capture('ccc333', '2026-01-03')
  raise 'history count exceeds limit' unless Dir.children(directory).sort == %w[bbb222.json ccc333.json]
end
