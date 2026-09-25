# frozen_string_literal: true

require 'woods'

module Woods
  # A conflicting source owner must abort even before staged artifacts change.
  class IdentityCollisionError < ExtractionError; end

  # Shared source-ownership checks for full, incremental and refresh writers.
  module ExtractionIdentities # rubocop:disable Metrics/ModuleLength -- keep replacement authority beside collision checks
    private

    def identity_source(path)
      File.expand_path(path.to_s, Rails.root) unless path.nil?
    end

    # Validate the complete batch before registering or writing any member.
    # Fresh claims survive removals within this run; only a retained baseline
    # owner may relocate after its old source is positively confirmed absent.
    def verify_identity_claims!(units)
      claims = (@identity_claims || {}).dup
      units.each do |unit|
        key = [unit.type, unit.identifier]
        path = identity_source(unit.file_path)
        if claims.key?(key)
          reject_identity_collision!(unit, claims.fetch(key)) unless claims[key] == path
        elsif !Array(@authoritative_replacement_types).include?(unit.type)
          verify_retained_owner!(unit, path)
        end
        claims[key] = path
      end
      @identity_claims = claims
    end

    def verify_retained_owner!(unit, path)
      prior = @dependency_graph.node(unit.identifier, type: unit.type)
      return unless prior

      prior_path = identity_source(prior[:file_path])
      return if prior_path == path || confirmed_source_move?(prior_path, path)
      return if confirmed_discovered_move?(unit, prior_path, path)

      reject_identity_collision!(unit, prior_path)
    end

    # A surviving file can release its old identity, but only after completed
    # discovery proves it absent. Fresh claims are still checked as one batch.
    def with_changed_path_ownership(batches)
      previous = @released_identity_owners
      @released_identity_owners = released_path_owners(batches)
      candidates = batches.flat_map { |_path, _rules, entries| entries.flat_map(&:last) }.compact
      verify_identity_claims!(candidates)
      yield
    ensure
      @released_identity_owners = previous
    end

    def released_path_owners(batches)
      return Set.new unless @eager_load_complete

      batches.each_with_object(Set.new) do |(path, rules, entries), released|
        next if entries.any? { |_rule, units| units.nil? }

        produced = entries.flat_map { |_rule, units| units }.to_set { |unit| [unit.identifier, unit.type] }
        released.merge(released_owners_for_path(path, rules.to_set(&:extractor_key), produced))
      end
    end

    def released_owners_for_path(path, covered, produced)
      @dependency_graph.units_for_path(path).filter_map do |identifier, type|
        key = self.class::TYPE_TO_EXTRACTOR_KEY[type]
        next if produced.include?([identifier, type]) || !covered.include?(key)
        next if @failed_consumers&.include?(key)

        [type, identifier, identity_source(path)]
      end
    end

    def confirmed_discovered_move?(unit, prior, current)
      return false unless @eager_load_complete
      return false unless prior && current && File.file?(current)
      return true if @released_identity_owners&.include?([unit.type, unit.identifier, prior])

      canonical_runtime_owner?(unit, current)
    end

    def canonical_runtime_owner?(unit, current)
      consumer = authoritative_runtime_consumer(unit.type)
      return false unless consumer && Object.respond_to?(:const_source_location)

      return false unless unique_runtime_owner?(unit, consumer)
      return false unless identity_source(Array(Object.const_source_location(unit.identifier)).first) == current

      complete_hybrid_owner?(unit, consumer, current)
    end

    def unique_runtime_owner?(unit, consumer)
      owners = consumer.discoverable_classes.select { |klass| klass.name == unit.identifier }.uniq
      return false if source_consumer_failed?(self.class::TYPE_TO_EXTRACTOR_KEY[unit.type], consumer)

      owners.size == 1 && owners.first.equal?(constant_for_identifier(unit.identifier))
    end

    def complete_hybrid_owner?(unit, consumer, current)
      return true unless self.class::CLASS_DISCOVERED_FALLBACK.key?(unit.type)

      # Runtime descendants alone cannot rule out a source-only duplicate in a
      # conventional directory. Require the full hybrid inventory before a
      # retained owner can move; the usual fresh-claim checks remain in force.
      key = self.class::TYPE_TO_EXTRACTOR_KEY.fetch(unit.type)
      units = checked_extraction(key, consumer) { consumer.extract_all }
      return false if source_consumer_failed?(key, consumer)

      claims = Array(units).select do |candidate|
        candidate.type == unit.type && candidate.identifier == unit.identifier
      end
      claims.any? && claims.all? { |candidate| identity_source(candidate.file_path) == current }
    end

    # GraphQL's runtime inventory cannot establish sole ownership. Job and
    # serializer inventories identify current runtime classes; fresh file-based
    # claims still pass the complete batch collision check before any write.
    def authoritative_runtime_consumer(type)
      key = self.class::TYPE_TO_EXTRACTOR_KEY[type]
      return unless authoritative_runtime_type?(type, key)

      consumer = extractor_for(key)
      return unless consumer.respond_to?(:discoverable_classes)
      return if @failed_consumers&.include?(key) || source_consumer_failed?(key, consumer)

      consumer
    end

    def authoritative_runtime_type?(type, key)
      return true if self.class::CLASS_DISCOVERED_FALLBACK.key?(type)

      spec = self.class::CLASS_BASED_DISCOVERY[key]
      spec && spec[:reconcile_removals] != false
    end

    def confirmed_source_move?(prior, current)
      return false unless prior && current && File.file?(current)

      File.lstat(prior)
      false
    rescue Errno::ENOENT
      true
    rescue SystemCallError
      false
    end

    def reject_identity_collision!(unit, prior_path)
      raise IdentityCollisionError, same_type_collision_message(unit.type, unit, prior_path)
    end

    # A complete replacement may relocate an old owner (e.g. a gem upgrade).
    # Partial runtime discovery keeps old nodes and cannot grant that authority.
    def with_replacement_ownership(key)
      previous = @authoritative_replacement_types
      @authoritative_replacement_types = if replacement_discovery_complete?(key)
                                           self.class::EXTRACTOR_KEY_TO_TYPES.fetch(key, [])
                                         else
                                           []
                                         end
      yield
    ensure
      @authoritative_replacement_types = previous
    end

    def replacement_discovery_complete?(key)
      runtime = self.class::CLASS_BASED_DISCOVERY.key?(key) || self.class::HYBRID_DISCOVERY_EXTRACTORS.include?(key)
      !runtime || @eager_load_complete
    end
  end
end
