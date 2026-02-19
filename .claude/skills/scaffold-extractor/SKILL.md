---
name: scaffold-extractor
description: Generates boilerplate for a new CodebaseIndex extractor and its spec
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
2. **Check for conflicts** — Glob `lib/codebase_index/extractors/*_extractor.rb` to ensure the name isn't taken.
3. **Create the extractor** at `lib/codebase_index/extractors/$ARGUMENTS_extractor.rb` using the template below.
4. **Create the spec** at `spec/extractors/$ARGUMENTS_extractor_spec.rb` using the spec template below.
5. **Report** — Show the user what was created and what they need to do next (register in `extractor.rb`, add to CLAUDE.md if needed).

## Extractor Template

```ruby
# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
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

      APP_DIRECTORIES = %w[app].freeze

      def initialize
        @directories = APP_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
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
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/shared_utility_methods'
require 'codebase_index/extractors/shared_dependency_scanner'
require 'codebase_index/extractors/{type}_extractor'

RSpec.describe CodebaseIndex::Extractors::{Name}Extractor do
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
