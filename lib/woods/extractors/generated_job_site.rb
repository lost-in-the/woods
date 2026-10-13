# frozen_string_literal: true

require 'prism'
require 'active_support/core_ext/string/inflections'
require_relative '../source_file'
require_relative 'shared_utility_methods'

module Woods
  module Extractors
    # Where a generated job class is declared.
    #
    # A class built with `Class.new` and bound with `const_set` has no
    # declaration in any file. `Object.const_source_location` reports the line
    # that bound the constant, which is the generator's own `const_set` call
    # when a class macro (`async_method :sync_now`) built the class. The line a
    # reader wants is the one that called the macro: it is looked up in the
    # file of the constant's owner, by the generator's name and an argument
    # the constant's name starts with. When no such call is found the binding
    # line itself is the site.
    #
    # Syntax is read with Prism; no pattern matching is involved.
    #
    # @example
    #   site = GeneratedJobSite.new(app_root: Rails.root.to_s).call(Widget::SyncNowWorker)
    #   site.source       # => "  async_method :sync_now\n"
    #   site.generated_by # => "async_method"
    class GeneratedJobSite
      include SharedUtilityMethods

      # @!attribute file_path [String] absolute path of the declaring file
      # @!attribute line [Integer] first declaring line, 1-based
      # @!attribute source [String] the declaring line(s)
      # @!attribute generated_by [String, nil] the generator method's name
      Site = Struct.new(:file_path, :line, :source, :generated_by, keyword_init: true)

      # @param app_root [String] the application root
      def initialize(app_root:)
        @app_root = app_root.to_s
        @files = {}
      end

      # @param klass [Class]
      # @return [Site, nil] nil for an anonymous class, a class its file
      #   declares, or one bound outside the application
      def call(klass)
        name = klass.name
        path, line = name && Object.const_source_location(name)
        return nil unless line && app_file?(path)

        file = parsed(path)
        return nil if file.nil? || declares_class?(file[:source], name)

        generator = enclosing_method(file[:tree], line)
        return bound_site(path, line, file) unless generator

        call_site(name, generator) || site(path, line, line, file, generator)
      rescue NameError, SystemCallError
        nil
      end

      private

      def app_file?(path)
        app_source?(path, @app_root) && File.file?(path)
      end

      # @return [Hash, nil] `{ source:, lines:, tree: }` for a parseable file
      def parsed(path)
        return @files[path] if @files.key?(path)

        source = SourceFile.read(path)
        result = Prism.parse(source)
        @files[path] = result.success? ? { source: source, lines: source.lines, tree: result.value } : nil
      end

      def site(path, first, last, file, generated_by)
        Site.new(file_path: path, line: first, source: file[:lines][(first - 1)..(last - 1)].join,
                 generated_by: generated_by)
      end

      # The binding line is the declaration: a constant assignment, or a
      # generator called directly from a class body.
      def bound_site(path, line, file)
        call = calls_in(file[:tree]).find do |node|
          node.location.start_line == line && node.receiver.nil? && node.name != :const_set
        end
        return site(path, line, line, file, nil) unless call

        site(path, line, declaration_end(call), file, call.name.to_s)
      end

      # @return [String, nil] name of the innermost method containing +line+
      def enclosing_method(tree, line)
        innermost = nil
        walk(tree) do |node|
          next unless node.is_a?(Prism::DefNode)
          next unless line.between?(node.location.start_line, node.location.end_line)

          innermost = node
        end
        innermost&.name&.to_s
      end

      # The owner's call of the generator whose argument names the constant.
      def call_site(name, generator)
        owner, _, basename = name.rpartition('::')
        path = owner.empty? ? nil : Object.const_source_location(owner)&.first
        return nil unless app_file?(path)

        file = parsed(path)
        return nil unless file

        call = best_call(file[:tree], generator, basename)
        call && site(path, call.location.start_line, declaration_end(call), file, generator)
      end

      # The longest matching argument wins, so `:sync_now` is preferred over
      # `:sync` for `SyncNowWorker`; the earliest line breaks a tie.
      def best_call(tree, generator, basename)
        matches = calls_in(tree).filter_map do |node|
          next unless node.name.to_s == generator && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))

          length = literal_arguments(node).flat_map { |text| spellings(text) }
                                          .filter_map { |text| prefix_length(basename, text) }.max
          [node, length] if length
        end
        matches.min_by { |node, length| [-length, node.location.start_line] }&.first
      end

      def literal_arguments(node)
        Array(node.arguments&.arguments).filter_map do |argument|
          argument.unescaped if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
        end
      end

      # The argument as written, and as a generator that classifies it would
      # spell it: `:send_new_emails` names `SendNewEmailWorker`.
      def spellings(text)
        [text, text.to_s.classify].uniq
      end

      # @return [Integer, nil] how much of +basename+ the argument spells,
      #   when it spells whole leading words of it
      def prefix_length(basename, text)
        compact = text.to_s.delete('_').downcase
        return nil if compact.empty? || !basename.downcase.start_with?(compact)

        following = basename[compact.length]
        compact.length if following.nil? || following != following.downcase
      end

      # Last line of the call's own text: its arguments, not a block body.
      def declaration_end(call)
        last = call.arguments&.location&.end_line || call.location.start_line
        closing = call.closing_loc&.end_line
        [last, closing].compact.max
      end

      def calls_in(tree)
        calls = []
        walk(tree) { |node| calls << node if node.is_a?(Prism::CallNode) }
        calls
      end

      def walk(node, &block)
        stack = [node]
        until stack.empty?
          current = stack.pop
          yield current
          stack.concat(current.compact_child_nodes.reverse)
        end
      end
    end
  end
end
