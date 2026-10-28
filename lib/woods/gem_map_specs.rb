# frozen_string_literal: true

require 'pathname'
require_relative 'extracted_unit'

module Woods
  # Spec files in the static self-map (#926), as what they reference only:
  # the qualified constants they name and the library files they require.
  # Their own classes, helpers and source stay out of the map.
  class GemMapSpecs
    # Spec files the self-map reads.
    GLOBS = %w[spec/**/*_spec.rb].freeze
    PATH = %r{\Aspec/.+_spec\.rb\z}
    # A qualified constant can only start where a token of word characters
    # and colons starts, so the source is split into tokens and each one is
    # matched from its start only: one pass, and no input can make the scan
    # try a start position twice.
    TOKEN = /[\w:]+/
    QUALIFIED_CONSTANT = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)+/
    REQUIRE = /^\s*require(_relative)?[\s(]+['"]([^'"]+)['"]/
    # A spec that globs the library reads every file in it.
    TREE_GLOB = %r{lib/(?:woods/)?\*\*}
    private_constant :PATH, :TOKEN, :QUALIFIED_CONSTANT, :REQUIRE, :TREE_GLOB

    # @param relative [String] path relative to the gem root
    # @return [Boolean]
    def self.spec?(relative)
      PATH.match?(relative)
    end

    # @param library [Array<String>] root-relative paths of the mapped library files
    def initialize(library: [])
      @library = library.map { |path| { type: :ruby_file, target: "file:#{path}", via: :require } }
    end

    # @param specs [Hash{String => String}] root-relative path => source
    # @return [Array<ExtractedUnit>] one `file:spec/...` unit per spec file
    def units(specs)
      specs.map do |relative, source|
        unit = ExtractedUnit.new(type: :ruby_file, identifier: "file:#{relative}", file_path: relative)
        unit.metadata = { static_kind: 'spec_file', executable: false }
        unit.dependencies = references(source, File.dirname(relative))
        unit.dependencies.concat(@library.map(&:dup)) if source.match?(TREE_GLOB)
        unit
      end
    end

    private

    def references(source, directory)
      constants = source.scan(TOKEN).filter_map { |token| token[QUALIFIED_CONSTANT]&.delete_prefix('::') }.uniq
      required = source.scan(REQUIRE).map do |relative, name|
        library = relative ? Pathname.new(directory).join(name).cleanpath.to_s : File.join('lib', name)
        "file:#{library.delete_suffix('.rb')}.rb"
      end
      constants.map { |name| { type: :ruby_class, target: name, via: :reference } } +
        required.uniq.map { |target| { type: :ruby_file, target: target, via: :require } }
    end
  end
end
