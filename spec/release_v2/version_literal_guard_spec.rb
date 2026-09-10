# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/version_state'

# The beta1 dispatch taught that a spec written against "the current version"
# survives exactly one release: `gemspec_spec.rb` asserted `.alpha`, and
# `release_notes_spec.rb`/`release_changelog_spec.rb` assumed an alpha tree,
# so the first `release:prepare` run broke three files at once (see
# .superpowers/sdd/2026-09-08-woods-graph-layers/progress.md, "Beta cut
# attempt 1"). Those were fixed by deriving state from the checkout instead
# of a literal. This spec catches the narrower relapse: a spec file that
# pins the *value* of the current version as a bare literal, so the next
# version bump (beta1 to beta2, beta to rc, rc to final) leaves a stale
# string behind instead of a computed one.
# Directories that exist specifically to hold multiple version states
# (including the current one) side by side, so a literal there is the point,
# not a relapse. See spec/support/release_repository.rb and
# spec/support/release_state_trees.rb.
VERSION_LITERAL_GUARD_EXCLUDED_PREFIXES = %w[spec/fixtures/ spec/support/].freeze
VERSION_LITERAL_GUARD_SELF_PATH = 'spec/release_v2/version_literal_guard_spec.rb'

RSpec.describe 'no hard-coded current-version literals in spec/' do
  let(:root) { File.expand_path('../..', __dir__) }

  # Three shapes the beta cut's own history could plausibly reintroduce:
  # an exact-requirement literal ('= 2.0.0'), a literal-content assertion
  # with a trailing newline ("2.0.0\n"), and a gem_version hash literal.
  # Built from the live base version, never a copy-pasted string.
  def literal_pattern(base)
    escaped = Regexp.escape(base)
    # No backreferences: Regexp.union copies each alternative's source
    # verbatim, so a `\1` inside one alternative would resolve against the
    # combined pattern's group numbering instead of its own, matching the
    # wrong (or an unset) group. Requiring *a* quote on each side, without
    # forcing them to match, is close enough for this guard's purpose.
    Regexp.union(
      /['"]=\s*#{escaped}['"]/,
      /['"]#{escaped}\\n['"]/,
      /(?:['"]gem_version['"]\s*=>|gem_version:)\s*['"]#{escaped}['"]/
    )
  end

  def excluded?(relative_path)
    VERSION_LITERAL_GUARD_EXCLUDED_PREFIXES.any? { |prefix| relative_path.start_with?(prefix) } ||
      relative_path == VERSION_LITERAL_GUARD_SELF_PATH
  end

  def offenses(root, base)
    pattern = literal_pattern(base)
    Dir.glob(File.join(root, 'spec/**/*.rb')).flat_map do |path|
      relative = path.delete_prefix("#{root}/")
      next [] if excluded?(relative)

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end
    end
  end

  it 'recognizes each documented literal shape, so the guard below is not vacuous' do
    pattern = literal_pattern('2.0.0')

    expect("expect(requirement.to_s).to eq('= 2.0.0')").to match(pattern)
    expect('expect(File.read(version_path)).to eq("2.0.0\n")').to match(pattern)
    expect("metadata = { gem_version: '2.0.0' }").to match(pattern)
    expect("metadata = { 'gem_version' => '2.0.0' }").to match(pattern)
    expect("expect(Woods::VERSION).to eq('2.0.0.beta1')").not_to match(pattern)
    expect("expect(other_gem_version).to be < Gem::Version.new('2.0.0')").not_to match(pattern)
  end

  it 'has no literal pinning the exact current version outside fixtures and support' do
    base = Woods::Release::VersionState.parse(Woods::VERSION).base
    found = offenses(root, base)

    expect(found).to be_empty,
                     "hard-coded literal(s) for the current version #{base.inspect}; " \
                     "derive it from Woods::VERSION instead:\n#{found.join("\n")}"
  end
end
