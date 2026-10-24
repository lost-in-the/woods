# frozen_string_literal: true

require 'set'

module Woods
  module Extractors
    # Resolves relative partial names that depend on who renders the page.
    #
    # Rails looks `render "account_head"` up through the view prefixes of the
    # controller handling the request, not through the directory of the
    # template that names it. `shared/_navigation` therefore renders
    # `widgets/_account_head` on a widgets page and `ledgers/_account_head`
    # on a ledgers page. One template alone cannot say which, so this runs
    # over every view template unit after they are all extracted.
    #
    # A template's callers are the owners (controllers or mailers) of the
    # view directories that reach it: the owner of its own directory, the
    # owners whose layout it is, and the callers of every template that
    # renders it. Each caller resolves the name through its own prefixes, in
    # order. When all callers agree on one file, the render edge targets it.
    # Otherwise no edge is kept and the name is recorded under
    # `metadata[:unresolved_partials]` as
    # `{ kind: 'caller_prefix', name:, candidates: }`.
    # A template nothing reaches falls back to the `application` prefix.
    #
    # Callers found through a partial this pass resolves count too, so the
    # caller sets are grown to a fixed point before any name is decided.
    # Sets only grow, which makes the result independent of unit order.
    class CallerPrefixPartials
      KIND = 'caller_prefix'

      # Prefixes for a template no owner reaches.
      UNREACHED_PREFIXES = %w[application].freeze

      # @param owners [Hash{String => Hash}] view directory => `{ prefixes:, layout: }`
      #   for each directory a runtime class owns: its ordered view prefixes
      #   and the extension-less identifier of its layout (nil when unknown)
      # @param resolver [#call] `(renderer_identifier, prefixes, partial_name)`
      #   => identifier of the first existing partial, or nil
      def initialize(owners:, resolver:)
        @owners = owners
        @resolver = resolver
        @resolved = {}
      end

      # Rewrites the render edge of each pending partial in place.
      #
      # @param units [Array<ExtractedUnit>] every view template unit
      # @param pending [Hash{String => Array<Hash>}] template identifier =>
      #   `{ name:, target: }` per relative partial no file was found for,
      #   `target` being the placeholder its render edge carries
      # @return [void]
      def apply(units, pending)
        return if pending.empty?

        by_identifier = units.to_h { |unit| [unit.identifier, unit] }
        callers = settle(seed_callers(units), render_children(by_identifier), pending)
        pending.each do |identifier, entries|
          unit = by_identifier[identifier]
          rewrite(unit, entries, callers[identifier]) if unit
        end
      end

      private

      # @return [Hash{String => Set<String>}] template identifier => owner directories
      def seed_callers(units)
        layouts = Hash.new { |hash, key| hash[key] = [] }
        @owners.each { |directory, owner| layouts[owner[:layout]] << directory if owner[:layout] }

        units.each_with_object({}) do |unit, callers|
          directories = layouts.fetch(stem(unit.identifier), [])
          directories += [unit.namespace] if @owners.key?(unit.namespace)
          callers[unit.identifier] = directories.to_set if directories.any?
        end
      end

      # @return [String] "layouts/application" for "layouts/application.html.erb"
      def stem(identifier)
        directory, name = File.split(identifier)
        name = name[/\A[^.]+/].to_s
        directory == '.' ? name : "#{directory}/#{name}"
      end

      # @return [Hash{String => Array<String>}] template => templates it renders
      def render_children(by_identifier)
        by_identifier.transform_values do |unit|
          unit.dependencies.filter_map do |dep|
            dep[:target] if dep[:via] == :render && dep[:type] == :view_template && by_identifier.key?(dep[:target])
          end
        end
      end

      # Hands each template's callers to everything it renders until no set
      # grows. A template is revisited only when its own set grew.
      def settle(callers, children, pending)
        queue = callers.keys
        until queue.empty?
          identifier = queue.shift
          reached = callers[identifier]
          rendered = children.fetch(identifier, []) + pending_targets(identifier, pending[identifier], reached)
          rendered.each do |child|
            known = (callers[child] ||= Set.new)
            size = known.size
            known.merge(reached)
            queue << child if known.size > size
          end
        end
        callers
      end

      def pending_targets(identifier, entries, directories)
        return [] unless entries

        entries.flat_map { |entry| targets_for(identifier, entry[:name], directories) }
      end

      # @return [Array<String>] the file each caller resolves the name to, sorted
      def targets_for(identifier, name, directories)
        prefix_lists = if directories.nil? || directories.empty?
                         [UNREACHED_PREFIXES]
                       else
                         directories.map { |directory| @owners.fetch(directory)[:prefixes] }
                       end
        prefix_lists.uniq.filter_map { |prefixes| resolve(identifier, prefixes, name) }.uniq.sort
      end

      def resolve(identifier, prefixes, name)
        key = [identifier, prefixes, name]
        return @resolved[key] if @resolved.key?(key)

        @resolved[key] = @resolver.call(identifier, prefixes, name)
      end

      def rewrite(unit, entries, directories)
        entries.each do |entry|
          targets = targets_for(unit.identifier, entry[:name], directories)
          retarget_partial_renders(unit, entry, targets.size == 1 ? targets.first : nil)
          if targets.size == 1
            unit.dependencies = unit.dependencies.map do |dep|
              placeholder?(dep, entry) ? dep.merge(target: targets.first) : dep
            end
          else
            unit.dependencies = unit.dependencies.reject { |dep| placeholder?(dep, entry) }
            (unit.metadata[:unresolved_partials] ||= []) << { kind: KIND, name: entry[:name], candidates: targets }
          end
        end
        unit.dependencies = unit.dependencies.uniq { |dep| [dep[:type], dep[:target], dep[:via]] }
      end

      # A partial render published under +partial_renders+ follows its edge:
      # the resolved target, or none when the callers disagree (woods#798).
      def retarget_partial_renders(unit, entry, target)
        renders = unit.metadata[:partial_renders]
        return unless renders

        unit.metadata[:partial_renders] = renders.map do |render|
          render[:partial] == entry[:name] && render[:target] == entry[:target] ? render.merge(target: target) : render
        end
      end

      def placeholder?(dep, entry)
        dep[:via] == :render && dep[:type] == :view_template && dep[:target] == entry[:target]
      end
    end
  end
end
