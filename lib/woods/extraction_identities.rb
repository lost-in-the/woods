# frozen_string_literal: true

require 'woods'

module Woods
  # A conflicting source owner must abort even before staged artifacts change.
  class IdentityCollisionError < ExtractionError; end

  # Shared source-ownership checks for full, incremental and refresh writers.
  module ExtractionIdentities
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

      reject_identity_collision!(unit, prior_path)
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
      !self.class::CLASS_BASED_DISCOVERY.key?(key) || @eager_load_complete
    end
  end
end
