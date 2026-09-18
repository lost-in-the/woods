# frozen_string_literal: true

module Woods
  module MCP
    # Equivalent evidence for all text renderers; JSON retains the same records.
    module TraversalEvidenceText
      def self.lines(explanation)
        return [] unless explanation

        lines = ['', "Recorded relationships (original source -> target; traversal: #{value(explanation, :direction)}):",
                 "Root identity: #{identity(value(explanation, :root))}"]
        value(explanation, :edges).each do |id, edge|
          attributes = TraversalEvidenceIndex::ATTRIBUTES.map do |attribute|
            stored = value(edge, attribute)
            "#{attribute}=#{stored.nil? ? 'unknown' : stored}"
          end
          lines << "#{id}: #{identity(value(edge, :source))} -> #{identity(value(edge, :target))}; #{attributes.join('; ')}"
        end
        lines << 'Witnesses: direct = recorded root relationship; transitive = inferred reachability, not observed execution.'
        value(explanation, :witnesses).each do |identifier, witness|
          lines << witness_line(identifier, witness)
        end
        lines
      end

      def self.identity(endpoint)
        type = value(endpoint, :type)
        label = if type
                  type
                else
                  candidates = value(endpoint, :candidate_types) || []
                  "#{value(endpoint, :resolution)}; candidate types: #{candidates.empty? ? 'none' : candidates.join(', ')}"
                end
        "#{value(endpoint, :identifier)} (#{label})"
      end

      def self.witness_line(identifier, witness)
        parent = value(witness, :parent) || 'none'
        edge = value(witness, :edge_id) || 'none'
        complete = value(witness, :typed_path_complete) ? 'yes' : 'no'
        context = value(witness, :context) ? 'yes' : 'no'
        "#{identifier}: #{value(witness, :impact)}; parent=#{parent}; edge=#{edge}; " \
          "typed path complete=#{complete}; context only=#{context}"
      end

      def self.value(hash, key)
        hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]
      end
      private_class_method :identity, :witness_line, :value
    end
  end
end
