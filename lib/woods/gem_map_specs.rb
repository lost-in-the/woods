# frozen_string_literal: true

require 'pathname'
require 'prism'
require 'set'
require_relative 'ast/parser'
require_relative 'extracted_unit'

module Woods
  # Reference-only Ruby under spec/, including helpers; never publishes its body.
  class GemMapSpecs
    GLOBS = %w[spec/**/*.rb].freeze
    PATH = %r{\Aspec/.+\.rb\z}
    TREE_GLOB = %r{lib/(?:woods/)?\*\*}
    private_constant :PATH, :TREE_GLOB

    def self.spec?(relative)
      PATH.match?(relative)
    end

    def initialize(library: [], paths: [], diagnostics: [])
      @library = library.map { |path| { type: :ruby_file, target: "file:#{path}", via: :require } }
      @paths = (paths | library).to_set
      @diagnostics = diagnostics
    end

    def units(specs)
      specs.map do |relative, source|
        unit = ExtractedUnit.new(type: :ruby_file, identifier: "file:#{relative}", file_path: relative)
        unit.metadata = { static_kind: 'spec_file', executable: false }
        unit.dependencies = references(source, relative)
        unit
      end
    end

    private

    def references(source, path)
      parsed = Woods::ParseCache.parse(source)
      raise Woods::ExtractionError, 'Invalid spec Ruby' unless parsed.success?

      nodes = descendants(parsed.value)
      calls = nodes.grep(Prism::CallNode)
      result = constant_dependencies(nodes)
      result.concat(calls.flat_map { |call| required(call, File.dirname(path)) })
      result.concat(@library.map(&:dup)) if calls.any? { |call| tree_read?(call) }
      result.uniq
    rescue Woods::ExtractionError
      @diagnostics << { path: path, reason: 'parse_error' }
      []
    end

    def descendants(root)
      result = []
      stack = [root]
      until stack.empty?
        node = stack.pop
        result << node
        stack.concat(node.compact_child_nodes)
      end
      result
    end

    def constant_name(node)
      return node.name.to_s if node.is_a?(Prism::ConstantReadNode)
      return unless node.is_a?(Prism::ConstantPathNode)
      return "::#{node.name}" unless node.parent

      parent = constant_name(node.parent)
      "#{parent}::#{node.name}" if parent
    end

    def constant_dependencies(nodes)
      names = nodes.filter_map { |node| constant_name(node) }.select { |name| name.include?('::') }.uniq
      names.map { |name| { type: :ruby_class, target: name, via: :reference } }
    end

    def required(call, directory)
      return [] unless call.receiver.nil? && %i[require require_relative].include?(call.name)

      argument = call.arguments&.arguments&.first
      return [] unless argument.is_a?(Prism::StringNode)

      require_paths(argument.unescaped, directory, call.name).map do |path|
        { type: :ruby_file, target: "file:#{path}", via: :require }
      end
    end

    def require_paths(name, directory, kind)
      name = "#{name.delete_suffix('.rb')}.rb"
      return [Pathname.new(directory).join(name).cleanpath.to_s] if kind == :require_relative

      candidates = %w[lib spec].map { |base| Pathname.new(base).join(name).cleanpath.to_s }
      known = candidates.select { |path| @paths.include?(path) }
      known.empty? ? [candidates.first] : known
    end

    def tree_read?(call)
      constant_name(call.receiver)&.delete_prefix('::') == 'Dir' && %i[[] glob].include?(call.name) &&
        call.arguments&.arguments&.any? { |argument| argument.slice.match?(TREE_GLOB) }
    end
  end
end
