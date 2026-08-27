# frozen_string_literal: true

# Rails version matrix for CI. The gem declares `railties >= 6.0`; these
# appraisals exercise the supported Rails releases against the booted-app
# extraction path (spec/integration/booted_extraction_spec.rb). The unit suite
# stubs Rails and runs once on the base Gemfile (the `test` job), not per row.
#
# The gemfiles under gemfiles/ are hand-maintained, not generated from this
# file: `bundle exec appraisal generate` can't produce them, because it has
# no way to express the base Gemfile's conditional ENV['WOODS_SQLITE3_REQ']
# logic, and running it anyway clobbers the WOODS_SQLITE3_REQ and
# concurrent-ruby pins each gemfile carries for its Rails row. Edit this file
# to record which Rails version a row targets, then hand-edit the matching
# gemfiles/rails_X.Y.gemfile to match — see any existing gemfile's own header
# comment for the pins it must keep.
#
# Install and run a single row:
#   BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle install
#   BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle exec rake spec
#
# Notes:
# - `sqlite3` is intentionally NOT re-declared here. The base Gemfile pins
#   `sqlite3 >= 1.4`; Rails' own transitive constraint (`~> 1.4` on 6.0–7.0)
#   narrows it to the 1.x line on old Rails and the latest 2.x on 7.1+.
# - Rails < 7.1 boots against `concurrent-ruby < 1.3.5`: 1.3.5 dropped the
#   implicit `require "logger"` that those releases rely on, so they raise a
#   NameError on `Logger` under Ruby 3.x without the pin.
# - Invalid Ruby x Rails pairs (e.g. Rails 6.0 on Ruby 3.2+) are excluded in
#   the CI matrix, not here — Appraisals is Ruby-version-agnostic.

appraise 'rails-6.0' do
  gem 'rails', '~> 6.0.0'
  gem 'concurrent-ruby', '< 1.3.5'
end

appraise 'rails-6.1' do
  gem 'rails', '~> 6.1.0'
  gem 'concurrent-ruby', '< 1.3.5'
end

appraise 'rails-7.0' do
  gem 'rails', '~> 7.0.0'
  gem 'concurrent-ruby', '< 1.3.5'
end

appraise 'rails-7.1' do
  gem 'rails', '~> 7.1.0'
end

appraise 'rails-7.2' do
  gem 'rails', '~> 7.2.0'
end

appraise 'rails-8.0' do
  gem 'rails', '~> 8.0.0'
end

appraise 'rails-8.1' do
  gem 'rails', '~> 8.1.0'
end
