# frozen_string_literal: true

require 'digest'
require_relative '../ast/parser'

module CodebaseIndex
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
      AR_INTERNAL_METHOD_PATTERNS = [
        /\A_/,                                    # _run_save_callbacks, _validators, etc.
        /\Aautosave_associated_records_for_/,     # autosave_associated_records_for_comments
        /\Avalidate_associated_records_for_/,     # validate_associated_records_for_comments
        /\Aafter_(?:add|remove)_for_/,            # collection callbacks
        /\Abefore_(?:add|remove)_for_/            # collection callbacks
      ].freeze

      def initialize
        @concern_cache = {}
      end

      # Extract all ActiveRecord models in the application
      #
      # @return [Array<ExtractedUnit>] List of model units
      def extract_all
        ActiveRecord::Base.descendants
                          .reject(&:abstract_class?)
                          .reject { |m| m.name.nil? } # Skip anonymous classes
                          .reject { |m| habtm_join_model?(m) }
                          .map { |model| extract_model(model) }
                          .compact
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
        unit.source_code = build_composite_source(model, source)
        unit.metadata = extract_metadata(model, source)
        unit.dependencies = extract_dependencies(model, source)

        # Build semantic chunks for all models (summary, associations, callbacks, validations)
        unit.chunks = build_chunks(unit)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract model #{model.name}: #{e.message}")
        nil
      end

      private

      # Find the source file for a model, handling STI and namespacing.
      #
      # Falls back to convention-based path when reflection points outside
      # the app (e.g., ActiveRecord::Core#initialize for models that don't
      # override initialize).
      def source_file_for(model)
        app_root = Rails.root.to_s
        convention_path = Rails.root.join("app/models/#{model.name.underscore}.rb").to_s

        # Tier 1: Instance methods defined directly on this model
        model.instance_methods(false).each do |method_name|
          loc = model.instance_method(method_name).source_location&.first
          return loc if loc&.start_with?(app_root)
        end

        # Tier 2: Class/singleton methods (catches models with only scopes)
        model.methods(false).each do |method_name|
          loc = model.method(method_name).source_location&.first
          return loc if loc&.start_with?(app_root)
        end

        # Tier 3: Convention path if file exists
        return convention_path if File.exist?(convention_path)

        # Tier 4: const_source_location (Ruby 3.0+)
        if Object.respond_to?(:const_source_location)
          loc = Object.const_source_location(model.name)&.first
          return loc if loc&.start_with?(app_root)
        end

        # Tier 5: Always return convention path — never a gem path
        convention_path
      rescue StandardError
        convention_path
      end

      # Detect Rails-generated HABTM join models (e.g., Product::HABTM_Categories)
      #
      # @param model [Class] The ActiveRecord model class
      # @return [Boolean] true if the model is an auto-generated HABTM join class
      def habtm_join_model?(model)
        model.name.demodulize.start_with?('HABTM_')
      end

      # Build composite source with schema header and inlined concerns
      def build_composite_source(model, source = nil)
        parts = []

        # Schema information as a header comment
        parts << build_schema_comment(model)

        # Main model source with concerns inlined
        parts << build_model_source_with_concerns(model, source)

        parts.compact.join("\n\n")
      end

      # Generate schema comment block with columns, indexes, and foreign keys
      def build_schema_comment(model)
        return nil unless model.table_exists?

        columns = model.columns.map do |col|
          type_info = col.type.to_s
          type_info += "(#{col.limit})" if col.limit
          constraints = []
          constraints << 'NOT NULL' unless col.null
          constraints << "DEFAULT #{col.default.inspect}" if col.default
          constraints << 'PRIMARY KEY' if col.name == model.primary_key

          "  #{col.name.ljust(25)} #{type_info.ljust(15)} #{constraints.join(' ')}"
        end

        indexes = begin
          ActiveRecord::Base.connection.indexes(model.table_name).map do |idx|
            unique = idx.unique ? ' (unique)' : ''
            "  #{idx.name}: [#{idx.columns.join(', ')}]#{unique}"
          end
        rescue StandardError
          []
        end

        foreign_keys = begin
          ActiveRecord::Base.connection.foreign_keys(model.table_name).map do |fk|
            "  #{fk.from_table}.#{fk.column} → #{fk.to_table}"
          end
        rescue StandardError
          []
        end

        parts = []
        parts << '# == Schema Information'
        parts << '#'
        parts << "# Table: #{model.table_name}"
        parts << '#'
        parts << '# Columns:'
        parts.concat(columns.map { |c| "# #{c}" })
        parts << '#'

        if indexes.any?
          parts << '# Indexes:'
          parts.concat(indexes.map { |i| "# #{i}" })
          parts << '#'
        end

        if foreign_keys.any?
          parts << '# Foreign Keys:'
          parts.concat(foreign_keys.map { |f| "# #{f}" })
        end

        parts.join("\n")
      end

      # Read model source and inline all included concerns
      def build_model_source_with_concerns(model, source = nil)
        if source.nil?
          source_path = source_file_for(model)
          return '' unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        # Find all included concerns and inline them
        included_modules = extract_included_modules(model)
        concern_sources = included_modules.filter_map { |mod| concern_source(mod) }

        if concern_sources.any?
          # Insert concern code as comments showing what's mixed in
          concern_block = concern_sources.map do |name, code|
            indented = code.lines.map { |l| "  # #{l.rstrip}" }.join("\n")
            <<~CONCERN
              # ┌─────────────────────────────────────────────────────────────────────┐
              # │ Included from: #{name.ljust(54)}│
              # └─────────────────────────────────────────────────────────────────────┘
              #{indented}
              # ─────────────────────────── End #{name} ───────────────────────────
            CONCERN
          end.join("\n\n")

          # Insert after class declaration line
          source.sub(/(class\s+#{Regexp.escape(model.name.demodulize)}.*$)/) do
            "#{::Regexp.last_match(1)}\n\n#{concern_block}"
          end
        else
          source
        end
      end

      # Get modules included specifically in this model (not inherited)
      def extract_included_modules(model)
        app_root = Rails.root.to_s
        model.included_modules.select do |mod|
          next false unless mod.name

          # Skip obvious non-app modules (from gems/stdlib)
          if Object.respond_to?(:const_source_location)
            loc = Object.const_source_location(mod.name)
            next false if loc && !loc.first&.start_with?(app_root)
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
        # Fast path: const_source_location is cheaper than iterating methods
        if mod.respond_to?(:const_source_location) || Object.respond_to?(:const_source_location)
          loc = Object.const_source_location(mod.name)
          return loc.first.start_with?(Rails.root.to_s) if loc
        end

        # Slow path: check instance method source locations
        mod.instance_methods(false).any? do |method|
          loc = mod.instance_method(method).source_location&.first
          loc&.start_with?(Rails.root.to_s)
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
      def extract_metadata(model, source = nil)
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
          column_names: model.table_exists? ? model.column_names : []
        }
      end

      # Extract all associations with full details
      def extract_associations(model)
        model.reflect_on_all_associations.map do |assoc|
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
            entry[:implicit_belongs_to] = true if implicit_belongs_to_validator?(v)
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
        rescue NoMethodError
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
          if line =~ /\A\s*scope\s+:(\w+)/
            scopes << { name: ::Regexp.last_match(1), source: line }
          end
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

      # Extract what this model depends on
      def extract_dependencies(model, source = nil)
        deps = []

        # Associations point to other models
        model.reflect_on_all_associations.each do |assoc|
          deps << { type: :model, target: assoc.class_name, via: :association }
        end

        # Parse source for service/mailer/job references
        if source.nil?
          source_path = source_file_for(model)
          source = File.read(source_path) if source_path && File.exist?(source_path)
        end

        if source
          # Service objects
          source.scan(/(\w+Service)(?:\.|::)/).flatten.uniq.each do |service|
            deps << { type: :service, target: service, via: :code_reference }
          end

          # Mailers
          source.scan(/(\w+Mailer)\./).flatten.uniq.each do |mailer|
            deps << { type: :mailer, target: mailer, via: :code_reference }
          end

          # Background jobs
          source.scan(/(\w+Job)\.perform/).flatten.uniq.each do |job|
            deps << { type: :job, target: job, via: :code_reference }
          end

          # Other models (direct references in code, not already captured via association)
          source.scan(ModelNameCache.model_names_regex).uniq.each do |model_name|
            next if model_name == model.name

            unless deps.any? { |d| d[:target] == model_name }
              deps << { type: :model, target: model_name, via: :code_reference }
            end
          end
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Chunking (for large models)
      # ──────────────────────────────────────────────────────────────────────

      # Build semantic chunks for large models
      def build_chunks(unit)
        chunks = []

        # Summary chunk: high-level overview for broad queries
        summary_content = build_summary_chunk(unit)
        chunks << {
          chunk_type: :summary,
          identifier: "#{unit.identifier}:summary",
          content: summary_content,
          content_hash: Digest::SHA256.hexdigest(summary_content),
          metadata: { parent: unit.identifier, purpose: :overview }
        }

        # Associations chunk
        if unit.metadata[:associations].any?
          assoc_content = build_associations_chunk(unit)
          chunks << {
            chunk_type: :associations,
            identifier: "#{unit.identifier}:associations",
            content: assoc_content,
            content_hash: Digest::SHA256.hexdigest(assoc_content),
            metadata: { parent: unit.identifier, purpose: :relationships }
          }
        end

        # Callbacks chunk
        if unit.metadata[:callbacks].any?
          cb_content = build_callbacks_chunk(unit)
          chunks << {
            chunk_type: :callbacks,
            identifier: "#{unit.identifier}:callbacks",
            content: cb_content,
            content_hash: Digest::SHA256.hexdigest(cb_content),
            metadata: { parent: unit.identifier, purpose: :behavior }
          }
        end

        # Validations chunk
        if unit.metadata[:validations].any?
          val_content = build_validations_chunk(unit)
          chunks << {
            chunk_type: :validations,
            identifier: "#{unit.identifier}:validations",
            content: val_content,
            content_hash: Digest::SHA256.hexdigest(val_content),
            metadata: { parent: unit.identifier, purpose: :constraints }
          }
        end

        chunks
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
          filters = callbacks.map { |c| c[:filter] }.join(', ')
          "#{type}: #{filters}"
        end

        <<~CALLBACKS
          # #{unit.identifier} - Callbacks

          #{sections.join("\n")}
        CALLBACKS
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

      # Human-readable label for a condition (Symbol, Proc, String, etc.)
      #
      # @param condition [Object] A proc, symbol, or other condition
      # @return [String]
      def condition_label(condition)
        case condition
        when Symbol then ":#{condition}"
        when Proc then 'Proc'
        when String then condition
        else condition.class.name
        end
      end

      # Build conditions hash from validator options, converting Procs to labels
      #
      # @param validator [ActiveModel::Validator]
      # @return [Hash]
      def format_validation_conditions(validator)
        conditions = {}
        conditions[:if] = Array(validator.options[:if]).map { |c| condition_label(c) } if validator.options[:if]
        conditions[:unless] = Array(validator.options[:unless]).map { |c| condition_label(c) } if validator.options[:unless]
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

      # Detect Rails-generated implicit belongs_to presence validators
      #
      # @param validator [ActiveModel::Validator]
      # @return [Boolean]
      def implicit_belongs_to_validator?(validator)
        if defined?(ActiveRecord::Validations::PresenceValidator)
          return false unless validator.is_a?(ActiveRecord::Validations::PresenceValidator)
        end

        loc = validator.class.instance_method(:validate).source_location&.first
        loc && !loc.start_with?(Rails.root.to_s)
      rescue StandardError
        false
      end

      # Filter out ActiveRecord-internal generated instance methods
      #
      # @param methods [Array<Symbol>]
      # @return [Array<Symbol>]
      def filter_instance_methods(methods)
        methods.reject do |method_name|
          name = method_name.to_s
          AR_INTERNAL_METHOD_PATTERNS.any? { |pattern| pattern.match?(name) }
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
          model.send("_#{type}_callbacks").size
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
