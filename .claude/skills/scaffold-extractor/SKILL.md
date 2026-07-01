---
name: scaffold-extractor
description: Generates boilerplate for a new Woods extractor and its spec
argument-hint: "[extractor-name]"
allowed-tools: Read, Write, Glob, Grep
---
# Scaffold Extractor

Generate a new extractor and its RSpec spec following project conventions.

## Usage

`/scaffold-extractor [name]` where `[name]` is the extractor type (e.g., `query_object`, `graphql_type`).

If `$ARGUMENTS` is empty, ask the user what to name the extractor.

## Steps

1. **Read conventions** — Read `.claude/rules/extractors.md` for the interface contract.
2. **Check for conflicts** — Glob `lib/woods/extractors/*_extractor.rb` to ensure the name isn't taken.
3. **Create the extractor** at `lib/woods/extractors/$ARGUMENTS_extractor.rb` using the template below.
4. **Create the spec** at `spec/extractors/$ARGUMENTS_extractor_spec.rb` using the spec template below.
5. **Report** — Show the user what was created and what they need to do next (register in `extractor.rb`, add to CLAUDE.md if needed).

## Extractor Template

> **Scanning route helpers?** If the extractor will scan templates, views,
> mailers, or any source that uses `_path` / `_url` helpers, also
> `require_relative 'route_helper_resolver'`, include `RouteHelperResolver`
> below `SharedDependencyScanner`, call `build_route_helper_map` in
> `initialize`, and call `scan_navigation_dependencies(source)` /
> `scan_form_dependencies(source)` inside `extract_dependencies`. Leaving
> the `include` without the call is dead wiring — see
> `.claude/rules/extractors.md`.

```ruby
# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
# RouteHelperResolver wiring is a three-step commitment — if you uncomment
# the require below you MUST also uncomment the include AND the
# build_route_helper_map call in initialize AND call scan_navigation_dependencies
# (and/or scan_form_dependencies) inside extract_dependencies. Any one of
# the three missing turns the others into dead code. See
# .claude/rules/extractors.md for the canonical navigation-edge pattern.
# require_relative 'route_helper_resolver'  # uncomment if scanning nav/form helpers

module Woods
  module Extractors
    # {Name}Extractor extracts {description} from Rails applications.
    #
    # @example
    #   extractor = {Name}Extractor.new
    #   units = extractor.extract_all
    #
    class {Name}Extractor
      include SharedUtilityMethods
      include SharedDependencyScanner
      # include RouteHelperResolver  # uncomment if scanning nav/form helpers — REMEMBER build_route_helper_map + scan_navigation_dependencies

      APP_DIRECTORIES = %w[app].freeze

      def initialize
        @directories = APP_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
        # build_route_helper_map  # REQUIRED if you included RouteHelperResolver — do not skip
      end

      # Extract all {type} units.
      #
      # @return [Array<ExtractedUnit>] extracted units
      def extract_all
        return [] if @directories.empty?

        units = []
        @directories.each do |dir|
          Dir.glob(dir.join('**/*.rb')).sort.each do |file_path|
            result = extract_{type}_file(file_path)
            units << result if result
          end
        end
        units
      end

      # Extract a single {type} from a file.
      #
      # @param file_path [String] absolute path to the Ruby file
      # @return [ExtractedUnit, nil] extracted unit or nil if not a {type}
      def extract_{type}_file(file_path)
        source = File.read(file_path)
        relative = relative_path(file_path)

        # TODO: implement extraction logic

        nil
      end

      private

      # TODO: add private helper methods
    end
  end
end
```

## Spec Template

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/model_name_cache'
require 'woods/extractors/shared_utility_methods'
require 'woods/extractors/shared_dependency_scanner'
require 'woods/extractors/{type}_extractor'

RSpec.describe Woods::Extractors::{Name}Extractor do
  include_context 'extractor setup'

  describe '#initialize' do
    it 'handles missing app directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  describe '#extract_all' do
    it 'returns empty array for files without {type} patterns' do
      create_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to eq([])
    end

    # TODO: add happy path and edge case tests
  end
end
```

## Substitution Rules

- `{Name}` = PascalCase of the argument (e.g., `query_object` -> `QueryObject`)
- `{type}` = snake_case of the argument (e.g., `query_object`)
- `{description}` = ask the user for a one-line description, or infer from the name

## What NOT to Do

- Don't register the extractor in `extractor.rb` — that requires understanding the dispatch type (CLASS_BASED vs FILE_BASED). Tell the user to do this manually.
- Don't modify CLAUDE.md — tell the user to update the architecture tree and gotchas if needed.
- Don't add require statements to other files.
