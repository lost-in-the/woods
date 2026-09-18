# frozen_string_literal: true

# Offline experiment only. No retriever option, config, or MCP capability.
require 'digest'
require 'woods/retrieval/context_assembler'

module OwnerOverlap
  class Origins
    def initialize(sources)
      @sources = sources.to_h { |path, bytes| [path.dup.freeze, bytes.b.dup.freeze] }.freeze
    end

    # Published display paths alone are not provenance. Only a unique exact span
    # in an explicitly supplied immutable source snapshot establishes an origin.
    def for(unit)
      return unless unit
      path = unit[:file_path] || unit['file_path']
      source = unit[:source_code] || unit['source_code']
      original = @sources[path]
      return unless original && source && !source.rstrip.empty?
      bytes = source.b
      start = original.index(bytes)
      return unless start && !original.index(bytes, start + 1)

      { path: path, file_sha256: Digest::SHA256.hexdigest(original),
        source_sha256: Digest::SHA256.hexdigest(bytes), start_byte: start,
        end_byte: start + source.rstrip.bytesize }
    end
  end

  class Assembler < Woods::Retrieval::ContextAssembler
    def initialize(origins:, policy:, recorder: nil, **options)
      super(**options)
      @origins, @policy, @recorder = origins, policy, recorder
    end

    private

    def assemble_request(**options)
      raise ArgumentError, 'Owner experiment compares full rendering only' unless options.fetch(:evidence, 'full') == 'full'
      classification = options.fetch(:classification)
      @exact = classification.intent == :locate || classification.scope == :pinpoint
      @trace = []
      result = super
      @recorder&.call(@trace)
      result
    end

    def add_candidate_section(sections, sources, section_name, candidates, budget)
      @section_name = section_name
      super
    end

    # Keep the production appender, truncation and section budget behavior.
    # Only the next candidate can change; original scores and identities cannot.
    def assemble_section(candidates, budget)
      pending = candidates.sort_by { |candidate| -candidate.score }
      origins = pending.to_h { |candidate| [candidate.identifier, @origins.for(@unit_cache[candidate.identifier])] }
      known_owners = origins.values.compact.map { |origin| owner(origin) }.uniq
      enabled = @policy && !@exact && known_owners.size > 1
      coverage = []
      parts, sources, used = [], [], 0
      until pending.empty?
        position = enabled ? next_position(pending, origins, coverage) : 0
        deferred = pending.take(position).map(&:identifier)
        candidate = pending.delete_at(position)
        origin = origins[candidate.identifier]
        reason = position.positive? ? 'complement_before_covered_span' : baseline_reason(enabled, origin)
        before = sources.size
        next_used = append_candidate(parts, sources, candidate, budget, used)
        added = sources.size > before
        truncated = added && sources.last[:truncated]
        coverage << origin if added && !truncated && origin
        @trace << { section: @section_name, identifier: candidate.identifier, score: candidate.score,
                    type: unit_field(@unit_cache[candidate.identifier] || {}, :type), reason: reason, deferred: deferred,
                    origin: origin, budget: budget, remaining_before: budget - used,
                    admitted: added, truncated: !!truncated }
        if next_used.nil?
          pending.each do |skipped|
            @trace << { section: @section_name, identifier: skipped.identifier, score: skipped.score,
                        type: unit_field(@unit_cache[skipped.identifier] || {}, :type),
                        reason: 'section_budget_exhausted', origin: origins[skipped.identifier],
                        budget: budget, admitted: false, truncated: false }
          end
          break
        end
        used = next_used
      end
      [parts.join("\n\n"), sources]
    end

    def baseline_reason(enabled, origin)
      return 'baseline_policy' unless @policy
      return 'exact_target_bypass' if @exact
      return 'unknown_origin' unless origin
      enabled ? 'relevance_order' : 'single_owner_bypass'
    end

    def next_position(pending, origins, coverage)
      return 0 unless covered?(origins[pending.first.identifier], coverage)
      pending.each_with_index do |candidate, position|
        origin = origins[candidate.identifier]
        return 0 unless origin # Unknown provenance is an ordering barrier.
        return position unless covered?(origin, coverage)
      end
      0
    end

    def owner(origin)
      [origin.fetch(:path), origin.fetch(:file_sha256)]
    end

    def covered?(origin, coverage)
      return false unless origin
      cursor = origin.fetch(:start_byte)
      coverage.select { |span| owner(span) == owner(origin) }.sort_by { |span| span[:start_byte] }.each do |span|
        break if span[:start_byte] > cursor
        cursor = [cursor, span[:end_byte]].max
        return true if cursor >= origin.fetch(:end_byte)
      end
      false
    end
  end
end
