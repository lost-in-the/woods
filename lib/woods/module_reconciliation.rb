# frozen_string_literal: true

module Woods
  # Keeps callable app/models modules under one extractor owner as model
  # inclusions change. Partial runtime discovery cannot establish removals.
  module ModuleReconciliation # rubocop:disable Metrics/ModuleLength -- one ownership/provenance policy across writers
    private

    # @param affected_types [Set<Symbol>] extractor keys requiring index updates
    # @return [Set<String>] added, migrated or removed module identifiers
    def reconcile_model_mixins(affected_types)
      concerns = extractor_for(:concerns)
      return Set.new unless concerns.respond_to?(:runtime_model_mixins)

      live = concerns.runtime_model_mixins
      live_names = live.values.flatten.to_set(&:name)
      known = @dependency_graph.units_of_type(:concern).to_set
      added = newly_claimed_concerns(concerns, live, known)
      touched = register_and_write(:concerns, added, affected_types)
      touched.merge(remove_claimed_standalone_modules(live_names, affected_types))
      touched.merge(remove_unclaimed_concerns(concerns, known - live_names, affected_types)) if @eager_load_complete
      touched.merge(add_standalone_modules(affected_types))
    end

    def newly_claimed_concerns(concerns, live, known)
      live.flat_map do |path, modules|
        next [] if modules.all? { |mod| known.include?(mod.name) }

        checked_extraction(:concerns, concerns) do
          Array(concerns.extract_model_mixin_file(path)).reject { |unit| known.include?(unit.identifier) }
        end || []
      end
    end

    def remove_claimed_standalone_modules(live_names, affected_types)
      live_names.each_with_object(Set.new) do |identifier, touched|
        next unless standalone_module_identity?(identifier)

        touched.add(identifier) if remove_unit(identifier, affected_types, type: :poro)
      end
    end

    def remove_unclaimed_concerns(concerns, stale, affected_types)
      stale.each_with_object(Set.new) do |identifier, touched|
        path = @dependency_graph.node(identifier, type: :concern)[:file_path]
        next if concerns.conventional_concern_path?(path)

        touched.add(identifier) if remove_unit(identifier, affected_types, type: :concern)
      end
    end

    def runtime_model_mixin_file?(extractor, type, path)
      type == :concern && extractor.respond_to?(:extract_model_mixin_file) &&
        extractor.respond_to?(:conventional_concern_path?) && !extractor.conventional_concern_path?(path)
    end

    def add_standalone_modules(affected_types)
      poros = extractor_for(:poros)
      return Set.new unless poros.respond_to?(:standalone_modules)

      discovered = checked_extraction(:poros, poros) { poros.standalone_modules }
      return Set.new unless discovered

      added = discovered.values.flatten.reject do |unit|
        @dependency_graph.node(unit.identifier, type: :poro) ||
          @dependency_graph.node(unit.identifier, type: :concern)
      end
      register_and_write(:poros, added, affected_types)
    end

    def standalone_module_identity?(identifier)
      return false unless @dependency_graph.node(identifier, type: :poro)

      path = payload_dir.join('poros', collision_safe_filename(identifier))
      return false unless path.file?

      JSON.parse(AtomicFile.read(path)).fetch('metadata', {})['ruby_kind'] == 'module'
    end

    # A missing includer during fallback boot does not transfer its previously
    # published concern to the PORO extractor. Filter fresh candidates too.
    def authoritative_module_units(units)
      return units if @eager_load_complete

      units.reject do |unit|
        unit.type == :poro && unit.metadata[:ruby_kind] == 'module' &&
          @dependency_graph.node(unit.identifier, type: :concern)
      end
    end

    # @param identifier [String] published typed identity
    # @param type [Symbol] current owner
    # @return [Boolean] whether incomplete loading requires retaining this unit
    def retain_partial_module?(identifier, type)
      return false if @eager_load_complete

      return false unless runtime_module_identity?(identifier, type)
      return false if type == :poro && live_concern_identity?(identifier)

      verify_retained_module_source!(identifier, type)
      true
    end

    def runtime_module_identity?(identifier, type)
      return standalone_module_identity?(identifier) if type == :poro
      return false unless type == :concern

      concerns = extractor_for(:concerns)
      path = @dependency_graph.node(identifier, type: type)[:file_path]
      concerns.respond_to?(:conventional_concern_path?) && !concerns.conventional_concern_path?(path)
    end

    def live_concern_identity?(identifier)
      concerns = extractor_for(:concerns)
      concerns.respond_to?(:runtime_model_mixins) &&
        concerns.runtime_model_mixins.values.any? { |modules| modules.any? { |mod| mod.name == identifier } }
    end

    # Cache identities predate every consumption update in this run. A freshly
    # written shared-file sibling must not certify retained module metadata as
    # having consumed changed source during incomplete eager loading.
    def verify_retained_module_source!(identifier, type)
      return unless @source_inputs

      path = @dependency_graph.node(identifier, type: type)[:file_path]
      relative = File.expand_path(path, Rails.root).delete_prefix("#{File.expand_path(Rails.root)}/")
      before = @source_reference_baseline&.dig('files', relative, 'identity')
      return if before && before == @source_inputs.source_identity(path)

      raise SourceReferences::RebuildRequired,
            "Cannot refresh retained #{type}:#{identifier} after incomplete eager loading. " \
            'Retry in a fresh Rails process with a complete eager load; the previous generation remains active.'
    end

    def consume_module_aware_refresh(key, units)
      if !@eager_load_complete && %i[poros concerns].include?(key)
        @source_inputs&.unverified("extractor:#{key}")
      else
        @source_inputs&.consume_extractor(key, units)
      end
    end

    # These formerly file-only families now retain runtime-discovered modules
    # on a partial boot, so their replacement authority follows the same gate.
    def replacement_discovery_complete?(key)
      return @eager_load_complete if %i[poros concerns].include?(key)

      super
    end
  end
end
