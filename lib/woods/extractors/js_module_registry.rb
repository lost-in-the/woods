# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'set'
require_relative '../atomic_file'
require_relative '../javascript_paths'
require_relative '../source_file'
require_relative 'js_module_facts'

module Woods
  module Extractors
    # Cross-file view of an app's JavaScript modules.
    #
    # Templates and components reference frontend code by NAME
    # (`x-data="dropdown"`, `data-controller="clipboard"`, `<x-shipment-card>`)
    # while a module is identified by its PATH. The registry closes that gap:
    # it resolves import specifiers to module paths and builds the
    # name-to-module map for one run.
    #
    # Precedence, per name:
    #
    # * Stimulus: an explicit `application.register` beats the
    #   `controllers/*_controller` filename convention.
    # * Alpine: `Alpine.data` beats a `window.name = function` global.
    # * Custom elements: Stencil `@Component({ tag })` and
    #   `customElements.define` share one tier.
    #
    # Two modules claiming one name at the winning tier resolve to nothing;
    # see {#ambiguous_names}. A registration whose value is imported resolves
    # to the defining module, otherwise to the registering module.
    #
    # The registry is a pure function of the file contents it is built from,
    # so a full and an incremental run of the same tree agree.
    #
    # @example
    #   registry = JsModuleRegistry.current
    #   registry.resolve('stimulus_controller', 'clipboard')
    #   # => "app/javascript/controllers/clipboard_controller.js"
    class JsModuleRegistry
      # Name kinds a component or template edge can target.
      CONSUMER_KINDS = %w[alpine_data custom_element stimulus_controller].freeze

      # Files larger than this are listed but not tokenized.
      MAX_ANALYZED_BYTES = 2 * 1024 * 1024

      # Directories whose `*_controller` files Stimulus loaders name by path.
      CONTROLLER_DIRECTORY = 'controllers'
      CONTROLLER_SUFFIXES = %w[_controller -controller].freeze

      # Extensions tried for an extensionless specifier, in order.
      RESOLUTION_EXTENSIONS = JavascriptPaths::EXTENSIONS

      # How many barrel re-exports a registration target is followed through.
      REEXPORT_DEPTH = 5

      MUTEX = Mutex.new
      UNIT_DIRECTORY = 'js_modules'

      class << self
        # The registry for the files on disk now. Rebuilt only when a module's
        # content, the file list or the configured globs change, so the
        # extractors of one run share a single tokenizing pass.
        #
        # @param root [String, Pathname] application root
        # @return [JsModuleRegistry]
        def current(root = Rails.root)
          root = root.to_s
          directories = JavascriptPaths.directories
          entries = JavascriptPaths.files(root).filter_map { |relative| read_entry(root, relative) }
          key = Digest::SHA256.hexdigest(JSON.generate([root, directories, entries.map { |e| e.values_at(0, 1) }]))

          MUTEX.synchronize do
            next @current if @current_key == key

            @current_key = key
            @current = new(cached_facts(entries), directories: directories, sizes: entries.to_h { |e| [e[0], e[2]] })
          end
        end

        # Build a registry from in-memory sources.
        #
        # @param sources [Hash{String => String}] root-relative path => contents
        # @param directories [Array<String>] roots bare specifiers resolve against
        # @return [JsModuleRegistry]
        def build(sources, directories: JavascriptPaths.directories)
          facts = sources.to_h { |path, source| [path, JsModuleFacts.parse(source)] }
          new(facts, directories: directories, sizes: sources.transform_values { |source| source.to_s.bytesize })
        end

        # The name map the published `js_module` units of a payload carry.
        #
        # @param payload_dir [String, Pathname] generation payload directory
        # @return [Hash{String => Hash{String => String}}] kind => name => module path
        def published_name_map(payload_dir)
          directory = Pathname(payload_dir).join(UNIT_DIRECTORY)
          return {} unless directory.directory?

          pairs = directory.glob('*.json').sort.flat_map { |path| published_names(path) }
          sorted_map(pairs)
        end

        # The published name map, read only when a change set touches a
        # module. An incremental run takes this snapshot before it rewrites
        # any unit, then compares it with {names_changed?}.
        #
        # @param payload_dir [String, Pathname] generation payload directory
        # @param relative_paths [Enumerable<String>] the run's changed paths
        # @return [Hash, nil] nil when no changed path is a module
        def published_names_for(payload_dir, relative_paths)
          published_name_map(payload_dir) if relative_paths.any? { |path| JavascriptPaths.source?(path) }
        end

        # Would a component or template resolve any name differently than it
        # did against the published index? Decides whether a JavaScript change
        # must re-run the extractors that reference modules by name.
        #
        # @param published [Hash, nil] a {published_name_map}; nil when unknown
        # @param root [String, Pathname] application root
        # @return [Boolean] true when the maps differ or the published one is unknown
        def names_changed?(published, root = Rails.root)
          published.nil? || published != current(root).name_map
        end

        # @param pairs [Array<Array(String, String, String)>] kind, name, module path
        # @return [Hash{String => Hash{String => String}}] sorted, consumer kinds only
        def sorted_map(pairs)
          pairs.select { |kind, _name, _path| CONSUMER_KINDS.include?(kind) }.sort
               .each_with_object({}) { |(kind, name, path), map| (map[kind] ||= {})[name] = path }
        end

        private

        # @return [Array(String, String, Integer, String), nil] path, digest, bytes, source
        def read_entry(root, relative)
          path = File.join(root, relative)
          size = File.size(path)
          return [relative, "omitted:#{size}", size, nil] if size > MAX_ANALYZED_BYTES

          source = SourceFile.read(path)
          [relative, Digest::SHA256.hexdigest(source), size, source]
        rescue SystemCallError
          nil
        end

        # Facts per file, reusing the previous build's parse for any file
        # whose content digest is unchanged. Callers hold {MUTEX}.
        def cached_facts(entries)
          previous = @facts_cache || {}
          @facts_cache = entries.to_h do |relative, digest, _size, source|
            cached_digest, cached = previous[relative]
            [relative, [digest, cached_digest == digest ? cached : (source && JsModuleFacts.parse(source))]]
          end
          @facts_cache.transform_values(&:last)
        end

        def published_names(path)
          return [] if path.basename.to_s == '_index.json'

          unit = JSON.parse(AtomicFile.read(path))
          return [] unless unit.is_a?(Hash) && unit['identifier'].is_a?(String)

          Array(unit.dig('metadata', 'registered_names')).filter_map do |entry|
            [entry['kind'], entry['name'], unit['identifier']] if entry.is_a?(Hash)
          end
        end
      end

      # @param facts [Hash{String => JsModuleFacts, nil}] per path; nil when analysis was skipped
      # @param directories [Array<String>] roots bare specifiers resolve against
      # @param sizes [Hash{String => Integer}] byte size per path
      def initialize(facts, directories:, sizes: {})
        @omitted = facts.select { |_path, value| value.nil? }.keys.to_set
        @facts = facts.transform_values { |value| value || JsModuleFacts.new([]) }
        @known = @facts.keys.to_set
        @directories = directories.sort
        @sizes = sizes
        @candidates = collect_candidates
        @winners, @ambiguous = pick_winners
      end

      # @return [Array<String>] module paths, sorted
      def paths
        @facts.keys.sort
      end

      # @param path [String]
      # @return [JsModuleFacts, nil]
      def facts(path)
        @facts[path]
      end

      # @param path [String]
      # @return [Integer, nil] file size in bytes
      def bytesize(path)
        @sizes[path]
      end

      # @param path [String]
      # @return [Boolean] whether the file was too large to tokenize
      def analysis_omitted?(path)
        @omitted.include?(path)
      end

      # @param kind [String] one of {CONSUMER_KINDS} or "alpine_store"
      # @param name [String]
      # @return [String, nil] module path, nil when unknown or ambiguous
      def resolve(kind, name)
        @winners.dig([kind.to_s, name.to_s], :path)
      end

      # @return [Hash{String => Hash{String => String}}] kind => name => path,
      #   sorted, {CONSUMER_KINDS} only
      def name_map
        self.class.sorted_map(@winners.map { |(kind, name), winner| [kind, name, winner[:path]] })
      end

      # @return [Array<Hash>] +{ kind:, name:, modules: }+ for names with no single owner
      def ambiguous_names
        @ambiguous.sort.map { |(kind, name), modules| { kind: kind, name: name, modules: modules } }
      end

      # Names this module is registered under.
      #
      # @param path [String]
      # @return [Array<Hash>] +{ kind:, name:, source: }+ sorted
      def registered_names(path)
        @winners.select { |_key, winner| winner[:path] == path }
                .map { |(kind, name), winner| { kind: kind, name: name, source: winner[:source] } }
                .sort_by { |entry| entry.values_at(:kind, :name) }
      end

      # Names this file registers for a different module.
      #
      # @param path [String]
      # @return [Array<Hash>] +{ kind:, name:, module: }+ sorted
      def registrations_in(path)
        @candidates.select { |candidate| candidate[:from] == path && candidate[:path] != path }
                   .map { |candidate| { kind: candidate[:kind], name: candidate[:name], module: candidate[:path] } }
                   .uniq.sort_by { |entry| entry.values_at(:kind, :name, :module) }
      end

      # @param path [String]
      # @return [String] stencil_component, custom_element, stimulus_controller, alpine_data or module
      def kind(path)
        names = registered_names(path)
        sources = names.map { |entry| entry[:source] }
        kinds = names.map { |entry| entry[:kind] }
        return 'stencil_component' if sources.include?('stencil') || stencil?(path)
        return 'custom_element' if kinds.include?('custom_element')
        return 'stimulus_controller' if stimulus?(path, kinds)
        return 'alpine_data' if kinds.include?('alpine_data') || kinds.include?('alpine_store')

        'module'
      end

      # @param path [String]
      # @return [Array<Hash>] +{ specifier:, resolved:, names:, kind: }+ sorted by specifier
      def resolved_imports(path)
        @facts.fetch(path).imports.map do |entry|
          { specifier: entry[:specifier], resolved: resolve_specifier(path, entry[:specifier]),
            names: entry[:names], kind: entry[:kind] }
        end
      end

      # @param from [String] importing module path
      # @param specifier [String]
      # @return [String, nil] module path, nil for a package or a missing file
      def resolve_specifier(from, specifier)
        if specifier.start_with?('./', '../') || %w[. ..].include?(specifier)
          return existing(File.expand_path(specifier, "/#{File.dirname(from)}").delete_prefix('/'))
        end

        bare = specifier.delete_prefix('@/').delete_prefix('~/')
        @directories.each do |directory|
          found = existing("#{directory}/#{bare}")
          return found if found
        end
        nil
      end

      private

      def existing(base)
        candidates = [base] + RESOLUTION_EXTENSIONS.map { |ext| "#{base}#{ext}" } +
                     RESOLUTION_EXTENSIONS.map { |ext| "#{base}/index#{ext}" }
        stem = RESOLUTION_EXTENSIONS.find { |ext| base.end_with?(ext) }
        candidates += RESOLUTION_EXTENSIONS.map { |ext| "#{base.delete_suffix(stem)}#{ext}" } if stem
        candidates.find { |candidate| @known.include?(candidate) }
      end

      # Every claim on a name: +{ kind:, name:, tier:, path:, from:, source: }+.
      def collect_candidates
        paths.flat_map do |path|
          facts = @facts.fetch(path)
          stimulus_candidates(path, facts) + alpine_candidates(path, facts) + element_candidates(path, facts)
        end
      end

      def stimulus_candidates(path, facts)
        explicit = facts.stimulus_registrations.map do |entry|
          candidate('stimulus_controller', entry[:name], 0, owner(path, entry[:target]) || path, path, 'registration')
        end
        explicit + convention_names(path).map do |name|
          candidate('stimulus_controller', name, 1, path, nil, 'filename')
        end
      end

      def alpine_candidates(path, facts)
        registered = facts.alpine_registrations.map do |entry|
          candidate(entry[:kind], entry[:name], 0, owner(path, entry[:target]) || path, path, 'registration')
        end
        registered + facts.globals.filter_map do |entry|
          target = owner(path, entry[:target])
          candidate('alpine_data', entry[:name], 1, target, path, 'global') if target
        end
      end

      def element_candidates(path, facts)
        facts.custom_elements.map do |entry|
          candidate('custom_element', entry[:tag], 0, owner(path, entry[:target]) || path, path, entry[:source])
        end
      end

      def candidate(kind, name, tier, path, from, source)
        { kind: kind, name: name, tier: tier, path: path, from: from, source: source }
      end

      # The module that defines an identifier used in +path+: the import it
      # is bound to, followed through barrel re-exports, or +path+ itself.
      #
      # @return [String, nil] nil when the identifier is bound to a package
      def owner(path, identifier)
        return path if identifier.nil?

        specifier, imported = @facts.fetch(path).bindings[identifier]
        return path if specifier.nil?

        follow_reexports(resolve_specifier(path, specifier), imported)
      end

      def follow_reexports(path, imported)
        REEXPORT_DEPTH.times do
          specifier, name = path && @facts.fetch(path).reexports[imported]
          forwarded = specifier && resolve_specifier(path, specifier)
          break unless forwarded

          path = forwarded
          imported = name
        end
        path
      end

      # Stimulus identifiers a loader derives from this file's path:
      # `controllers/ledgers/line_item_controller.js` => `ledgers--line-item`.
      def convention_names(path)
        stem = path.delete_suffix(File.extname(path))
        suffix = CONTROLLER_SUFFIXES.find { |candidate| stem.end_with?(candidate) }
        return [] unless suffix

        stem = stem.delete_suffix(suffix)
        controller_prefixes.filter_map do |prefix|
          stem.delete_prefix(prefix).gsub('/', '--').tr('_', '-') if stem.start_with?(prefix) && stem != prefix
        end.uniq
      end

      def controller_prefixes
        @controller_prefixes ||= begin
          under = [CONTROLLER_DIRECTORY] + @facts.each_value.flat_map { |f| f.stimulus_loaders.map { |l| l[:under] } }
          @directories.product(under.uniq.sort).map { |directory, name| "#{directory}/#{name}/" }
        end
      end

      # @return [Array(Hash, Hash)] winners and ambiguous claims, keyed by [kind, name]
      def pick_winners
        winners = {}
        ambiguous = {}
        @candidates.group_by { |c| c.values_at(:kind, :name) }.each do |key, claims|
          best = claims.select { |claim| claim[:tier] == claims.map { |c| c[:tier] }.min }
          owners = best.map { |claim| claim[:path] }.uniq.sort
          if owners.size == 1
            winners[key] = { path: owners.first, source: best.map { |claim| claim[:source] }.min }
          else
            ambiguous[key] = owners
          end
        end
        [winners, ambiguous]
      end

      def stencil?(path)
        @facts.fetch(path).custom_elements.any? { |entry| entry[:source] == 'stencil' }
      end

      def stimulus?(path, kinds)
        kinds.include?('stimulus_controller') || @facts.fetch(path).stimulus_controller_class?
      end
    end
  end
end
