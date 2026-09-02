# frozen_string_literal: true

require 'digest'
require_relative '../ast/parser'
require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'callback_analyzer'

module Woods
  module Extractors
    # ModelExtractor handles ActiveRecord model extraction with:
    # - Inline concern resolution (concerns are embedded, not referenced)
    # - Full callback chain extraction
    # - Association mapping with target models
    # - Schema information as header comments
    # - Automatic chunking for large models
    #
    # This is typically the most important extractor as models represent
    # the core domain and have the most implicit behavior (callbacks, validations, etc.)
    #
    # @example
    #   extractor = ModelExtractor.new
    #   units = extractor.extract_all
    #   user_unit = units.find { |u| u.identifier == "User" }
    #
    class ModelExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Single combined regex for filtering AR-generated internal methods.
      # Replaces 5 separate patterns with one alternation for O(1) matching.
      AR_INTERNAL_METHOD_PATTERN = /\A(?:
        _                                         | # _run_save_callbacks, _validators, etc.
        autosave_associated_records_for_           | # autosave_associated_records_for_comments
        validate_associated_records_for_           | # validate_associated_records_for_comments
        (?:after|before)_(?:add|remove)_for_         # collection callbacks
      )/x

      # Warnings collected during extraction (skipped associations, failed models)
      attr_reader :warnings

      def initialize
        @concern_cache = {}
        @warnings = []
      end

      # Extract all ActiveRecord models in the application
      #
      # @return [Array<ExtractedUnit>] List of model units
      def extract_all
        discoverable_classes.map { |model| extract_model(model) }.compact
      end

      # The model classes this extractor would extract from the running app.
      #
      # Shared with the incremental path, which reconciles this set against
      # the identifiers already in the dependency graph to spot classes added
      # since the last extraction (#164). Keeping discovery in one method is
      # what makes that reconciliation exact rather than a re-guess.
      #
      # @return [Array<Class>]
      def discoverable_classes
        ActiveRecord::Base.descendants
                          .reject { |m| abstract_class?(m) }
                          .reject { |m| m.name.nil? } # Skip anonymous classes
                          .reject { |m| habtm_join_model?(m) }
      end

      # Extract a single model
      #
      # @param model [Class] The ActiveRecord model class
      # @return [ExtractedUnit] The extracted unit
      def extract_model(model)
        unit = ExtractedUnit.new(
          type: :model,
          identifier: model.name,
          file_path: source_file_for(model)
        )

        source_path = unit.file_path
        source = source_path && File.exist?(source_path) ? File.read(source_path) : nil

        unit.namespace = model.module_parent.name unless model.module_parent == Object
        inlined_source, inlined_concerns = build_model_source_with_concerns(model, source)
        unit.source_code = build_composite_source(model, inlined_source)
        unit.metadata = extract_metadata(model, source, inlined_concerns: inlined_concerns)
        unit.dependencies = extract_dependencies(model, source)

        # Enrich callbacks with side-effect analysis. The analyzer parses real
        # Ruby, so it gets the raw analysis composite — the display composite
        # comments concern bodies out, which Prism cannot see.
        enrich_callbacks_with_side_effects(unit, source, analysis_source: build_analysis_source(model, source))

        # Build semantic chunks for all models (summary, associations, callbacks, validations)
        unit.chunks = build_chunks(unit)

        unit
      rescue StandardError => e
        @warnings << "Failed to extract model #{model.name}: #{e.message}"
        Rails.logger.error("Failed to extract model #{model.name}: #{e.message}")
        nil
      end

      private

      # Is this an abstract AR base class? Guarded exactly like
      # {Woods::ModelNameCache#abstract_model?}: a descendant that raises on
      # the call (a half-loaded class under the NameError fallback) is kept
      # rather than dropped. An unguarded `.reject(&:abstract_class?)` here
      # let that raise escape {#discoverable_classes} and abort the whole
      # models phase (L1); per-class extraction failures are already handled
      # by {#extract_model}'s own rescue.
      #
      # @param klass [Class]
      # @return [Boolean] true when the class is an abstract AR base class
      def abstract_class?(klass)
        klass.respond_to?(:abstract_class?) && klass.abstract_class?
      rescue StandardError
        false
      end

      # Find the source file for a model, handling STI and namespacing.
      #
      # Uses convention path first (most reliable for models), then falls
      # back to introspection via {#resolve_source_location}, which prefers
      # app-owned locations and keeps a gem-owned class (an engine model) at
      # its real gem path rather than a synthesized app path.
      def source_file_for(model)
        convention_path = Rails.root.join("app/models/#{model.name.underscore}.rb").to_s
        return convention_path if File.exist?(convention_path)

        resolve_source_location(model, app_root: Rails.root.to_s, fallback: convention_path)
      end

      # Detect Rails-generated HABTM join models (e.g., Product::HABTM_Categories)
      #
      # @param model [Class] The ActiveRecord model class
      # @return [Boolean] true if the model is an auto-generated HABTM join class
      def habtm_join_model?(model)
        model.name.demodulize.start_with?('HABTM_')
      end

      # Build composite source with schema header and the concern-inlined
      # model source.
      #
      # @param model [Class] The ActiveRecord model class
      # @param inlined_source [String] Model source with concerns already
      #   inlined (see {#build_model_source_with_concerns})
      # @return [String]
      def build_composite_source(model, inlined_source)
        [build_schema_comment(model), inlined_source].compact.join("\n\n")
      end

      # Generate schema comment block with columns, indexes, and foreign keys
      def build_schema_comment(model)
        return nil unless model.table_exists?

        parts = []
        parts << '# == Schema Information'
        parts << '#'
        parts << "# Table: #{model.table_name}"
        parts << '#'
        parts << '# Columns:'
        parts.concat(format_columns_comment(model))
        parts << '#'

        indexes = format_indexes_comment(model)
        if indexes.any?
          parts << '# Indexes:'
          parts.concat(indexes)
          parts << '#'
        end

        foreign_keys = format_foreign_keys_comment(model)
        if foreign_keys.any?
          parts << '# Foreign Keys:'
          parts.concat(foreign_keys)
        end

        parts.join("\n")
      end

      def format_columns_comment(model)
        model.columns.map do |col|
          type_info = col.type.to_s
          type_info += "(#{col.limit})" if col.limit
          constraints = []
          constraints << 'NOT NULL' unless col.null
          constraints << "DEFAULT #{col.default.inspect}" if col.default
          constraints << 'PRIMARY KEY' if col.name == model.primary_key
          "#   #{col.name.ljust(25)} #{type_info.ljust(15)} #{constraints.join(' ')}"
        end
      end

      def format_indexes_comment(model)
        ActiveRecord::Base.connection.indexes(model.table_name).map do |idx|
          unique = idx.unique ? ' (unique)' : ''
          "#   #{idx.name}: [#{idx.columns.join(', ')}]#{unique}"
        end
      rescue StandardError
        []
      end

      def format_foreign_keys_comment(model)
        ActiveRecord::Base.connection.foreign_keys(model.table_name).map do |fk|
          "#   #{fk.from_table}.#{fk.column} → #{fk.to_table}"
        end
      rescue StandardError
        []
      end

      # Read model source and inline all included concerns.
      #
      # Concern code is inserted as '# '-prefixed comment lines right after
      # the model's class declaration, matching both nested (+class Book+)
      # and compact (+class Library::Book+) declaration styles. When no
      # declaration line can be found in unconventional source, the block is
      # appended at the end instead of being silently discarded, and a
      # warning naming the model is recorded.
      #
      # @param model [Class] The ActiveRecord model class
      # @param source [String, nil] Pre-read model source (read from disk when nil)
      # @return [Array(String, Array<String>)] The concern-inlined source and
      #   the demodulized names of the concerns actually inlined into it.
      #   Returning the pair keeps metadata[:inlined_concerns] truthful —
      #   it is derived from the insertion result, never recomputed
      #   independently of what the composite source carries.
      def build_model_source_with_concerns(model, source = nil)
        if source.nil?
          source_path = source_file_for(model)
          return ['', []] unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        concern_sources = resolved_concern_sources(model)
        return [source, []] if concern_sources.empty?

        [insert_concern_block(model, source, build_concern_block(concern_sources)),
         concern_sources.map { |name, _code| name.demodulize }]
      end

      # Resolve [name, code] pairs for every concern included in the model
      # whose source file can be located.
      #
      # @param model [Class] The ActiveRecord model class
      # @return [Array<Array(String, String)>]
      def resolved_concern_sources(model)
        extract_included_modules(model).filter_map { |mod| concern_source(mod) }
      end

      # Render concern sources as a '#'-commented display block showing
      # what's mixed in.
      #
      # @param concern_sources [Array<Array(String, String)>] [name, code] pairs
      # @return [String]
      def build_concern_block(concern_sources)
        concern_sources.map do |name, code|
          indented = code.lines.map { |l| "  # #{l.rstrip}" }.join("\n")
          <<~CONCERN
            # ┌─────────────────────────────────────────────────────────────────────┐
            # │ Included from: #{name.ljust(54)}│
            # └─────────────────────────────────────────────────────────────────────┘
            #{indented}
            # ─────────────────────────── End #{name} ───────────────────────────
          CONCERN
        end.join("\n\n")
      end

      # Insert the concern block after the model's class declaration line.
      #
      # Falls back to appending at end-of-source (recording a warning) when
      # no declaration matches — dropping the block silently would leave
      # source_code contradicting metadata[:inlined_concerns].
      #
      # @param model [Class] The ActiveRecord model class
      # @param source [String] The model source
      # @param concern_block [String] Commented concern block to insert
      # @return [String]
      def insert_concern_block(model, source, concern_block)
        pattern = class_declaration_pattern(model)
        return source.sub(pattern) { "#{::Regexp.last_match(1)}\n\n#{concern_block}" } if source.match?(pattern)

        @warnings << "[#{model.name}] No class declaration matched for concern inlining; " \
                     'appending inlined concern block at end of source'
        "#{source.chomp}\n\n#{concern_block}"
      end

      # Regexp matching the model's class declaration in either nested
      # (+class Book+) or compact (+class Library::Book+) style. The word
      # boundary stops +class BookmarkError+ from claiming model Book's
      # concern block; the +(?!::)+ lookahead stops a nested
      # +class Book::Error+ from claiming it either.
      #
      # @param model [Class] The ActiveRecord model class
      # @return [Regexp]
      def class_declaration_pattern(model)
        /(class\s+(?:[\w:]+::)?#{Regexp.escape(model.name.demodulize)}\b(?!::).*$)/
      end

      # Get modules included specifically in this model (not inherited)
      def extract_included_modules(model)
        app_root = Rails.root.to_s
        model.included_modules.select do |mod|
          next false unless mod.name

          # Skip obvious non-app modules (from gems/stdlib)
          if Object.respond_to?(:const_source_location)
            loc = Object.const_source_location(mod.name)
            next false if loc && !app_source?(loc.first, app_root)
          end

          # Include if it's in app/models/concerns or app/controllers/concerns
          mod.name.include?('Concerns') ||
            # Or if it's namespaced under the model's parent
            mod.name.start_with?("#{model.module_parent}::") ||
            # Or if it's defined within the application
            defined_in_app?(mod)
        end
      end

      # Get modules extended specifically in this model (not inherited).
      #
      # Extended modules live on the singleton class and add class-level methods.
      # Ruby builtins (Kernel, PP, etc.) are filtered out by comparing against
      # Object.singleton_class.included_modules.
      #
      # @param model [Class] The ActiveRecord model class
      # @return [Array<Module>] App-defined modules extended by this model
      def extract_extended_modules(model)
        app_root = Rails.root.to_s
        builtin_modules = Object.singleton_class.included_modules.map(&:name).compact.to_set

        model.singleton_class.included_modules.select do |mod|
          next false unless mod.name
          next false if builtin_modules.include?(mod.name)

          # Skip obvious non-app modules (from gems/stdlib)
          if Object.respond_to?(:const_source_location)
            loc = Object.const_source_location(mod.name)
            next false if loc && !app_source?(loc.first, app_root)
          end

          # Include if it's in app/models/concerns or app/controllers/concerns
          mod.name.include?('Concerns') ||
            # Or if it's namespaced under the model's parent
            mod.name.start_with?("#{model.module_parent}::") ||
            # Or if it's defined within the application
            defined_in_app?(mod)
        end
      end

      # Check if a module is defined within the Rails application
      #
      # @param mod [Module] The module to check
      # @return [Boolean] true if the module is defined within Rails.root
      def defined_in_app?(mod)
        app_root = Rails.root.to_s

        # Fast path: const_source_location is cheaper than iterating methods
        if mod.respond_to?(:const_source_location) || Object.respond_to?(:const_source_location)
          loc = Object.const_source_location(mod.name)
          return app_source?(loc.first, app_root) if loc
        end

        # Slow path: check instance method source locations
        mod.instance_methods(false).any? do |method|
          loc = mod.instance_method(method).source_location&.first
          app_source?(loc, app_root)
        end
      rescue StandardError
        false
      end

      # Get the source code for a concern, with caching
      def concern_source(mod)
        return @concern_cache[mod.name] if @concern_cache.key?(mod.name)

        path = concern_path_for(mod)
        return nil unless path && File.exist?(path)

        @concern_cache[mod.name] = [mod.name, File.read(path)]
      end

      # Find the file path for a concern
      def concern_path_for(mod)
        possible_paths = [
          Rails.root.join("app/models/concerns/#{mod.name.underscore}.rb"),
          Rails.root.join("app/controllers/concerns/#{mod.name.underscore}.rb"),
          Rails.root.join("lib/#{mod.name.underscore}.rb")
        ]
        possible_paths.find { |p| File.exist?(p) }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract comprehensive metadata for retrieval and filtering
      #
      # @param model [Class] The ActiveRecord model class
      # @param source [String, nil] The model source code
      # @param inlined_concerns [Array<String>, nil] Demodulized names of the
      #   concerns actually inlined into the unit's source_code (from
      #   {#build_model_source_with_concerns}). When nil, derived by running
      #   the same inlining — the metadata must never claim a concern the
      #   composite source does not carry.
      # @return [Hash]
      def extract_metadata(model, source = nil, inlined_concerns: nil)
        {
          # Core identifiers
          table_name: model.table_name,
          primary_key: model.primary_key,

          # Relationships and behaviors
          associations: extract_associations(model),
          validations: extract_validations(model),
          callbacks: extract_callbacks(model),
          scopes: extract_scopes(model, source),
          enums: extract_enums(model),
          inlined_concerns: inlined_concerns || build_model_source_with_concerns(model, source).last,

          # API surface
          class_methods: model.methods(false).sort,
          instance_methods: filter_instance_methods(model.instance_methods(false)).sort,

          # Inheritance
          sti_column: model.inheritance_column,
          is_sti_base: sti_base?(model),
          is_sti_child: sti_child?(model),
          parent_class: model.superclass.name,

          # Metrics for retrieval ranking
          loc: count_loc(model, source),
          callback_count: callback_count(model),
          association_count: model.reflect_on_all_associations.size,
          validation_count: model._validators.values.flatten.size,

          # Schema info
          table_exists: model.table_exists?,
          column_count: model.table_exists? ? model.columns.size : 0,
          column_names: model.table_exists? ? model.column_names : [],
          columns: if model.table_exists?
                     model.columns.map do |col|
                       { 'name' => col.name, 'type' => col.sql_type, 'null' => col.null, 'default' => col.default }
                     end
                   else
                     []
                   end,

          # ActiveStorage / ActionText
          active_storage_attachments: extract_active_storage_attachments(source),
          action_text_fields: extract_action_text_fields(source),
          variant_definitions: extract_variant_definitions(source),

          # Multi-database topology
          database_roles: extract_database_roles(source),
          shard_config: extract_shard_config(source)
        }
      end

      # Extract ActiveStorage attachment declarations from source.
      #
      # Scans for +has_one_attached+ and +has_many_attached+ declarations.
      #
      # @param source [String, nil] The model source code
      # @return [Array<Hash>] Attachment declarations with :name and :type
      def extract_active_storage_attachments(source)
        return [] unless source

        attachments = []
        source.scan(/has_one_attached\s+:(\w+)/) { |m| attachments << { name: m.first, type: :has_one_attached } }
        source.scan(/has_many_attached\s+:(\w+)/) { |m| attachments << { name: m.first, type: :has_many_attached } }
        attachments
      end

      # Extract ActionText rich text field declarations from source.
      #
      # Scans for +has_rich_text+ declarations.
      #
      # @param source [String, nil] The model source code
      # @return [Array<String>] Rich text field names
      def extract_action_text_fields(source)
        return [] unless source

        source.scan(/has_rich_text\s+:(\w+)/).flatten
      end

      # Extract ActiveStorage variant definitions from source.
      #
      # Scans for +variant+ declarations inside +with_attached+ blocks.
      #
      # @param source [String, nil] The model source code
      # @return [Array<Hash>] Variant declarations with :name and :options
      def extract_variant_definitions(source)
        return [] unless source

        source.scan(/variant\s+:(\w+),\s*(.+)/).map do |name, options|
          { name: name, options: options.strip }
        end
      end

      # Extract database role configuration from connects_to database: { ... }.
      #
      # Parses +connects_to database:+ declarations and returns a hash of
      # role names to database keys (e.g. +{ writing: :primary, reading: :replica }+).
      #
      # @param source [String, nil] The model source code
      # @return [Hash, nil] Database role map or nil when not configured
      def extract_database_roles(source)
        return nil unless source

        match = source.match(/connects_to\s+database:\s*\{([^}]+)\}/)
        return nil unless match

        parse_role_hash(match[1])
      end

      # Extract shard configuration from connects_to shards: { ... }.
      #
      # Parses +connects_to shards:+ declarations and returns a hash of
      # shard names to their nested database role maps.
      # Uses a nested-brace-aware pattern to capture the full shard hash.
      #
      # @param source [String, nil] The model source code
      # @return [Hash, nil] Shard config map or nil when not configured
      def extract_shard_config(source)
        return nil unless source

        # Pattern handles one level of inner braces: { shard: { role: :db }, ... }
        match = source.match(/connects_to\s+shards:\s*\{((?:[^{}]|\{[^}]*\})*)\}/)
        return nil unless match

        shards = {}
        match[1].scan(/(\w+):\s*\{([^}]+)\}/) do |shard_name, roles_str|
          shards[shard_name.to_sym] = parse_role_hash(roles_str)
        end
        shards.empty? ? nil : shards
      end

      # Parse a key: :value hash string into a symbol-keyed hash.
      #
      # @param hash_str [String] Contents of a Ruby hash literal
      # @return [Hash] Parsed key-value pairs as symbol keys
      def parse_role_hash(hash_str)
        result = {}
        hash_str.scan(/(\w+):\s*:(\w+)/) do |key, value|
          result[key.to_sym] = value.to_sym
        end
        result
      end

      # Extract all associations with full details.
      # Broken associations (e.g. missing class_name) are skipped with a warning
      # instead of aborting the entire model extraction.
      def extract_associations(model)
        model.reflect_on_all_associations.filter_map do |assoc|
          {
            name: assoc.name,
            type: assoc.macro, # :belongs_to, :has_many, :has_one, :has_and_belongs_to_many
            target: assoc.class_name,
            options: extract_association_options(assoc),
            through: assoc.options[:through],
            polymorphic: assoc.polymorphic?,
            foreign_key: assoc.foreign_key,
            inverse_of: assoc.inverse_of&.name
          }
        rescue NameError => e
          @warnings << "[#{model.name}] Skipping broken association #{assoc.name}: #{e.message}"
          nil
        end
      end

      def extract_association_options(assoc)
        assoc.options.slice(
          :dependent, :through, :source, :source_type,
          :foreign_key, :primary_key, :inverse_of,
          :counter_cache, :touch, :optional, :required,
          :class_name, :as, :foreign_type
        )
      end

      # Extract all validations
      def extract_validations(model)
        model._validators.flat_map do |attribute, validators|
          validators.map do |v|
            entry = {
              attribute: attribute,
              type: v.class.name.demodulize.underscore.sub(/_validator$/, ''),
              options: v.options.except(:if, :unless, :on),
              conditions: format_validation_conditions(v)
            }
            entry[:implicit_belongs_to] = true if implicit_belongs_to_validator?(model, v)
            entry
          end
        end
      end

      # Extract all callbacks with their full chain
      def extract_callbacks(model)
        callback_types = %i[
          before_validation after_validation
          before_save after_save around_save
          before_create after_create around_create
          before_update after_update around_update
          before_destroy after_destroy around_destroy
          after_commit after_rollback
          after_initialize after_find
          after_touch
        ]

        callback_types.flat_map do |type|
          callbacks = model.send("_#{type}_callbacks")
          callbacks.map do |cb|
            {
              type: type,
              filter: cb.filter.to_s,
              kind: cb.kind, # :before, :after, :around
              conditions: format_callback_conditions(cb)
            }
          end
        rescue StandardError
          # Widen beyond NoMethodError per CLAUDE.md — callback-chain
          # introspection can raise a variety of errors across Rails
          # versions (NameError, TypeError, LoadError for missing
          # concerns), and silently swallowing only NoMethodError left
          # the rest to crash extraction.
          []
        end.compact
      end

      # Extract scopes with their source if available.
      # Parses the full source with the AST layer to get accurate scope
      # boundaries, falling back to regex line-scanning on parse failure.
      #
      # @param model [Class]
      # @param source [String, nil]
      # @return [Array<Hash>]
      def extract_scopes(model, source = nil)
        if source.nil?
          source_path = source_file_for(model)
          return [] unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        lines = source.lines

        begin
          parser = Ast::Parser.new
          root = parser.parse(source)
          extract_scopes_from_ast(root, lines)
        rescue StandardError
          extract_scopes_by_regex(lines)
        end
      end

      # Extract scopes using AST node line spans for accurate boundaries.
      #
      # @param root [Ast::Node] Parsed AST root
      # @param lines [Array<String>] Source lines
      # @return [Array<Hash>]
      def extract_scopes_from_ast(root, lines)
        scope_nodes = root.find_all(:send).select { |n| n.method_name == 'scope' }

        scope_nodes.filter_map do |node|
          name = node.arguments&.first&.to_s&.delete_prefix(':')&.strip
          next if name.nil? || name.empty?

          if node.line && node.end_line
            start_idx = node.line - 1
            end_idx = node.end_line - 1
            scope_source = lines[start_idx..end_idx].join
          elsif node.line
            scope_source = lines[node.line - 1]
          else
            next
          end

          { name: name, source: scope_source }
        end
      end

      # Fallback: extract scopes by regex when AST parsing fails.
      #
      # @param lines [Array<String>] Source lines
      # @return [Array<Hash>]
      def extract_scopes_by_regex(lines)
        scopes = []
        lines.each do |line|
          scopes << { name: ::Regexp.last_match(1), source: line } if line =~ /\A\s*scope\s+:(\w+)/
        end
        scopes
      end

      # Extract enum definitions
      def extract_enums(model)
        return {} unless model.respond_to?(:defined_enums)

        model.defined_enums.transform_values(&:to_h)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract what this model depends on.
      #
      # Association reflections normally become a +:model+ edge labeled with
      # the association macro. Polymorphic associations are the exception:
      # `belongs_to :commentable, polymorphic: true` names an *interface*,
      # not a model — +AssociationReflection#class_name+ camelizes the
      # association name ("Commentable") without constantizing it, so the
      # NameError rescue never fires and the edge pointed at a nonexistent
      # node, or worse, at an unrelated real constant (an app's Commentable
      # concern) mislabeled as a +:belongs_to+ model edge (#199). Those
      # edges now carry +via: :polymorphic_interface+ instead of the macro:
      # the interface name stays visible in the graph but is distinguishable
      # from a resolvable model reference.
      def extract_dependencies(model, source = nil)
        # Associations point to other models
        deps = model.reflect_on_all_associations.filter_map do |assoc|
          via = polymorphic_reflection?(assoc) ? :polymorphic_interface : assoc.macro
          { type: :model, target: assoc.class_name, via: via }
        rescue NameError => e
          @warnings << "[#{model.name}] Skipping broken association dep #{assoc.name}: #{e.message}"
          nil
        end

        # Included concerns add instance-level behavior
        extract_included_modules(model).each do |mod|
          deps << { type: :concern, target: mod.name, via: :include }
        end

        # Extended modules add class-level behavior (not inlined into source)
        extract_extended_modules(model).each do |mod|
          deps << { type: :concern, target: mod.name, via: :extend }
        end

        # Parse source for service/mailer/job references
        if source.nil?
          source_path = source_file_for(model)
          source = File.read(source_path) if source_path && File.exist?(source_path)
        end

        if source
          deps.concat(scan_service_dependencies(source))
          deps.concat(scan_mailer_dependencies(source))
          deps.concat(scan_job_dependencies(source))

          # Other models (direct references in code, not already captured via association)
          scan_model_dependencies(source).each do |dep|
            next if dep[:target] == model.name

            deps << dep
          end
        end

        consolidate_dependencies(deps)
      end

      # Whether an association reflection declares a polymorphic interface.
      #
      # Guarded with +respond_to?+ because not every reflection type across
      # Rails versions exposes +#polymorphic?+ — a reflection without it is
      # treated as a plain (non-polymorphic) association.
      #
      # @param assoc [ActiveRecord::Reflection::AbstractReflection]
      # @return [Boolean]
      def polymorphic_reflection?(assoc)
        assoc.respond_to?(:polymorphic?) && assoc.polymorphic?
      end

      # Build a parse-friendly composite for callback side-effect analysis.
      #
      # The displayed source_code inlines concern code as comment lines — a
      # deliberate presentation choice — but Prism cannot see commented
      # code, so the standard idiom (a concern's +included do+ registering a
      # callback whose method is defined in the concern body) was invisible
      # to CallbackAnalyzer. This composite concatenates the raw model
      # source with each concern's raw module source: top-level modules
      # parse fine and the analyzer's method search walks the whole tree.
      #
      # @param model [Class] The ActiveRecord model class
      # @param source [String, nil] The raw model source
      # @return [String, nil] Concatenated raw sources, or +source+ when no
      #   concern source is resolvable
      def build_analysis_source(model, source)
        return source unless source

        concern_codes = resolved_concern_sources(model).map { |_name, code| code }
        return source if concern_codes.empty?

        ([source] + concern_codes).join("\n\n")
      end

      # Enrich callback metadata with side-effect analysis.
      #
      # Uses CallbackAnalyzer to find each callback's method body and
      # classify its side effects (column writes, job enqueues, etc.).
      # The analyzer parses real Ruby, so callers should hand it a
      # parse-friendly +analysis_source+ (raw model + raw concern code, see
      # {#build_analysis_source}) rather than the display composite whose
      # concern bodies are commented out. Falls back to +unit.source_code+
      # when no analysis source is given.
      #
      # @param unit [ExtractedUnit] The model unit with metadata[:callbacks] set
      # @param source [String, nil] The model source code
      # @param analysis_source [String, nil] Parse-friendly composite source
      def enrich_callbacks_with_side_effects(unit, source, analysis_source: nil)
        return unless source && unit.metadata[:callbacks]&.any?

        analyzer = CallbackAnalyzer.new(
          source_code: analysis_source || unit.source_code,
          column_names: unit.metadata[:column_names] || []
        )

        unit.metadata[:callbacks] = unit.metadata[:callbacks].map do |cb|
          analyzer.analyze(cb)
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Chunking (for large models)
      # ──────────────────────────────────────────────────────────────────────

      # Build semantic chunks for large models
      def build_chunks(unit)
        chunks = []

        add_chunk(chunks, :summary, unit, build_summary_chunk(unit), :overview)
        if unit.metadata[:associations].any?
          add_chunk(chunks, :associations, unit, build_associations_chunk(unit), :relationships)
        end
        add_chunk(chunks, :callbacks, unit, build_callbacks_chunk(unit), :behavior) if unit.metadata[:callbacks].any?
        if unit.metadata[:callbacks]&.any? { |cb| cb[:side_effects] }
          add_chunk(chunks, :callback_effects, unit, build_callback_effects_chunk(unit), :behavior_analysis)
        end
        if unit.metadata[:validations].any?
          add_chunk(chunks, :validations, unit, build_validations_chunk(unit), :constraints)
        end

        chunks
      end

      def add_chunk(chunks, type, unit, content, purpose)
        return if content.nil? || content.empty?

        chunks << {
          chunk_type: type,
          identifier: "#{unit.identifier}:#{type}",
          content: content,
          content_hash: Digest::SHA256.hexdigest(content),
          metadata: { parent: unit.identifier, purpose: purpose }
        }
      end

      def build_summary_chunk(unit)
        meta = unit.metadata

        <<~SUMMARY
          # #{unit.identifier} - Model Summary

          Table: #{meta[:table_name]}
          Primary Key: #{meta[:primary_key]}
          Columns: #{meta[:column_names].join(', ')}

          ## Associations (#{meta[:associations].size})
          #{meta[:associations].map { |a| "- #{a[:type]} :#{a[:name]} → #{a[:target]}" }.join("\n")}

          ## Key Behaviors
          - Callbacks: #{meta[:callback_count]}
          - Validations: #{meta[:validation_count]}
          - Scopes: #{meta[:scopes].size}

          ## Instance Methods
          #{meta[:instance_methods].first(10).join(', ')}#{'...' if meta[:instance_methods].size > 10}
        SUMMARY
      end

      def build_associations_chunk(unit)
        meta = unit.metadata

        lines = meta[:associations].map do |a|
          opts = a[:options].map { |k, v| "#{k}: #{v}" }.join(', ')
          "#{a[:type]} :#{a[:name]}, class: #{a[:target]}#{", #{opts}" unless opts.empty?}"
        end

        <<~ASSOC
          # #{unit.identifier} - Associations

          #{lines.join("\n")}
        ASSOC
      end

      def build_callbacks_chunk(unit)
        meta = unit.metadata

        grouped = meta[:callbacks].group_by { |c| c[:type] }

        sections = grouped.map do |type, callbacks|
          callback_lines = callbacks.map { |c| format_callback_line(c) }
          "#{type}:\n#{callback_lines.join("\n")}"
        end

        <<~CALLBACKS
          # #{unit.identifier} - Callbacks

          #{sections.join("\n\n")}
        CALLBACKS
      end

      # Format a single callback line with optional side-effect annotations.
      #
      # @param callback [Hash] Callback hash, optionally with :side_effects
      # @return [String]
      def format_callback_line(callback)
        line = "  #{callback[:filter]}"

        effects = callback[:side_effects]
        return line unless effects

        annotations = []
        annotations << "writes: #{effects[:columns_written].join(', ')}" if effects[:columns_written]&.any?
        annotations << "enqueues: #{effects[:jobs_enqueued].join(', ')}" if effects[:jobs_enqueued]&.any?
        annotations << "calls: #{effects[:services_called].join(', ')}" if effects[:services_called]&.any?
        annotations << "mails: #{effects[:mailers_triggered].join(', ')}" if effects[:mailers_triggered]&.any?
        annotations << "reads: #{effects[:database_reads].join(', ')}" if effects[:database_reads]&.any?

        return line if annotations.empty?

        "#{line} [#{annotations.join('; ')}]"
      end

      # Build a narrative chunk summarizing callback side effects by lifecycle phase.
      #
      # Groups callbacks with detected side effects by lifecycle event and
      # produces a numbered, human-readable summary of what each callback does.
      #
      # @param unit [ExtractedUnit]
      # @return [String]
      def build_callback_effects_chunk(unit)
        callbacks_with_effects = unit.metadata[:callbacks].select do |cb|
          effects = cb[:side_effects]
          effects && (
            effects[:columns_written]&.any? ||
            effects[:jobs_enqueued]&.any? ||
            effects[:services_called]&.any? ||
            effects[:mailers_triggered]&.any? ||
            effects[:database_reads]&.any?
          )
        end

        return '' if callbacks_with_effects.empty?

        grouped = callbacks_with_effects.group_by { |cb| callback_lifecycle_group(cb[:type]) }

        sections = grouped.map do |group_name, callbacks|
          lines = callbacks.map { |cb| describe_callback_effects(cb) }
          "## #{group_name}\n#{lines.join("\n")}"
        end

        <<~EFFECTS
          # #{unit.identifier} - Callback Side Effects

          #{sections.join("\n\n")}
        EFFECTS
      end

      # Map a callback type to a lifecycle group name.
      #
      # @param type [Symbol]
      # @return [String]
      def callback_lifecycle_group(type)
        case type
        when :before_validation, :after_validation
          'Validation'
        when :before_save, :after_save, :around_save
          'Save Lifecycle'
        when :before_create, :after_create, :around_create
          'Create Lifecycle'
        when :before_update, :after_update, :around_update
          'Update Lifecycle'
        when :before_destroy, :after_destroy, :around_destroy
          'Destroy Lifecycle'
        when :after_commit, :after_rollback
          'After Commit'
        when :after_initialize, :after_find, :after_touch
          'Initialization'
        else
          'Other'
        end
      end

      # Describe a single callback's side effects in natural language.
      #
      # @param callback [Hash]
      # @return [String]
      def describe_callback_effects(callback)
        effects = callback[:side_effects]
        parts = []
        parts << "writes #{effects[:columns_written].join(', ')}" if effects[:columns_written]&.any?
        parts << "enqueues #{effects[:jobs_enqueued].join(', ')}" if effects[:jobs_enqueued]&.any?
        parts << "calls #{effects[:services_called].join(', ')}" if effects[:services_called]&.any?
        parts << "triggers #{effects[:mailers_triggered].join(', ')}" if effects[:mailers_triggered]&.any?
        parts << "reads via #{effects[:database_reads].join(', ')}" if effects[:database_reads]&.any?

        "- #{callback[:kind]} #{callback[:type]}: #{callback[:filter]} → #{parts.join(', ')}"
      end

      def build_validations_chunk(unit)
        meta = unit.metadata

        grouped = meta[:validations].group_by { |v| v[:attribute] }

        sections = grouped.map do |attr, validations|
          types = validations.map { |v| v[:type] }.join(', ')
          "#{attr}: #{types}"
        end

        <<~VALIDATIONS
          # #{unit.identifier} - Validations

          #{sections.join("\n")}
        VALIDATIONS
      end

      # ──────────────────────────────────────────────────────────────────────
      # Condition & Filter Helpers
      # ──────────────────────────────────────────────────────────────────────

      # Build conditions hash from validator options, converting Procs to labels
      #
      # @param validator [ActiveModel::Validator]
      # @return [Hash]
      def format_validation_conditions(validator)
        conditions = {}
        conditions[:if] = Array(validator.options[:if]).map { |c| condition_label(c) } if validator.options[:if]
        if validator.options[:unless]
          conditions[:unless] = Array(validator.options[:unless]).map do |c|
            condition_label(c)
          end
        end
        conditions[:on] = validator.options[:on] if validator.options[:on]
        conditions
      end

      # Build conditions hash from callback ivars (not .options, which doesn't exist)
      #
      # @param callback [ActiveSupport::Callbacks::Callback]
      # @return [Hash]
      def format_callback_conditions(callback)
        conditions = {}

        if callback.instance_variable_defined?(:@if)
          if_conds = Array(callback.instance_variable_get(:@if))
          conditions[:if] = if_conds.map { |c| condition_label(c) } if if_conds.any?
        end

        if callback.instance_variable_defined?(:@unless)
          unless_conds = Array(callback.instance_variable_get(:@unless))
          conditions[:unless] = unless_conds.map { |c| condition_label(c) } if unless_conds.any?
        end

        conditions
      end

      # Detect Rails-generated implicit belongs_to presence validators.
      #
      # `belongs_to` (with belongs_to_required_by_default, Rails 5+)
      # registers an ActiveRecord PresenceValidator on the association
      # attribute. Reflection offers no declaration provenance — the
      # validator class and its #validate source_location are identical for
      # an explicit `validates :assoc, presence: true` — so this flags any
      # AR presence validator whose attributes are all belongs_to
      # association names. (The previous source_location heuristic matched
      # EVERY AR presence validator, since PresenceValidator#validate is
      # always defined in the gem, never under Rails.root.)
      #
      # @param model [Class] The ActiveRecord model class
      # @param validator [ActiveModel::Validator]
      # @return [Boolean]
      def implicit_belongs_to_validator?(model, validator)
        return false unless defined?(ActiveRecord::Validations::PresenceValidator)
        return false unless validator.is_a?(ActiveRecord::Validations::PresenceValidator)

        belongs_to_names = model.reflect_on_all_associations(:belongs_to).map { |r| r.name.to_sym }
        return false if belongs_to_names.empty?

        attributes = validator.respond_to?(:attributes) ? Array(validator.attributes) : []
        attributes.any? && attributes.all? { |a| belongs_to_names.include?(a.to_sym) }
      rescue StandardError
        false
      end

      # Filter out ActiveRecord-internal generated instance methods
      #
      # @param methods [Array<Symbol>]
      # @return [Array<Symbol>]
      def filter_instance_methods(methods)
        methods.reject do |method_name|
          AR_INTERNAL_METHOD_PATTERN.match?(method_name.to_s)
        end
      end

      # True STI base detection: requires both descends_from_active_record? AND
      # the inheritance column actually exists in the table
      #
      # @param model [Class]
      # @return [Boolean]
      def sti_base?(model)
        return false unless model.descends_from_active_record?
        return false unless model.table_exists?

        model.column_names.include?(model.inheritance_column)
      end

      # Detect STI child classes (superclass is a concrete AR model, not AR::Base)
      #
      # @param model [Class]
      # @return [Boolean]
      def sti_child?(model)
        return false if model.descends_from_active_record?

        model.superclass < ActiveRecord::Base && model.superclass != ActiveRecord::Base
      end

      # ──────────────────────────────────────────────────────────────────────
      # Helper methods
      # ──────────────────────────────────────────────────────────────────────

      def callback_count(model)
        %i[validation save create update destroy commit rollback].sum do |type|
          # CallbackChain includes Enumerable but defines no #size on any
          # supported Rails version — #size raises and the rescue would
          # zero the count. #count is the only correct API here.
          model.send("_#{type}_callbacks").count
        rescue StandardError
          0
        end
      end

      def count_loc(model, source = nil)
        if source
          source.lines.count { |l| l.strip.present? && !l.strip.start_with?('#') }
        else
          path = source_file_for(model)
          return 0 unless path && File.exist?(path)

          File.readlines(path).count { |l| l.strip.present? && !l.strip.start_with?('#') }
        end
      end
    end
  end
end
