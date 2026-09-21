# frozen_string_literal: true

require_relative '../../lib/woods/published_index'
require_relative 'evidence'
require_relative 'graph_evidence'
require_relative 'extraction_receipt'

module WoodsDevelopment
  module TypeSafe
    # Offline review context, optionally checked against a local extraction receipt.
    # Physical files and indexed (possibly inlined) source stay distinct.
    class ReviewPacket
      MAX_PACKET_BYTES = 8_388_608

      # Read explicitly selected files and their typed graph context.
      #
      # @param root [String, Pathname] source root, without booting Rails
      # @param index_dir [String, Pathname] numbered, published Woods index
      # @param manifest [Hash] the schema accepted by Evidence.read
      # @param receipt [Hash, nil] optional trusted local ExtractionReceipt.capture result
      # @param producer_root [String, Pathname, nil] producer files declared by the receipt
      # @return [Hash] JSON-compatible evidence, index provenance and typed units
      # @raise [InvalidEvidence] for invalid evidence or an unreadable index
      def self.build(root:, index_dir:, manifest:, receipt: nil, producer_root: nil)
        files = Evidence.read(root: root, manifest: manifest)
        Woods::PublishedIndex.open(index_dir) do |index|
          arguments = { receipt: receipt, root: root, producer_root: producer_root, index: index, files: files }
          ExtractionReceipt.verify!(**arguments) if receipt
          packet = new(root, index).call(files)
          if receipt
            ExtractionReceipt.verify!(**arguments)
            packet = packet.merge('source_lineage' => 'recorded_extraction',
                                  'extraction_receipt' => JSON.parse(JSON.generate(receipt)))
            if JSON.generate(packet).bytesize > MAX_PACKET_BYTES
              raise InvalidEvidence, 'Review packet byte limit exceeded'
            end
          end
          packet
        end
      rescue SystemCallError, IOError, ArgumentError, TypeError, EncodingError, JSON::JSONError,
             Woods::PublishedIndex::CorruptPointerError
        raise InvalidEvidence, 'Cannot build review packet from the supplied evidence and index', cause: nil
      end

      # @param root [String, Pathname] source root
      # @param index [Woods::PublishedIndex] reader held open by the caller
      def initialize(root, index)
        raise InvalidEvidence, 'Review packets require a numbered generation' if index.generation_number.zero?

        @root = File.realpath(root)
        @index = index
        @graph_bytes = Woods::AtomicFile.read(index.payload_dir.join('dependency_graph.json'))
        @graph = GraphEvidence.new(JSON.parse(@graph_bytes))
      end

      # @param files [Array<Hash>] validated materialized evidence with content
      # @return [Hash] complete packet, with no truncation on overflow
      def call(files)
        units = {}
        evidence = files.map { |file| attach_units(file, units) }
        packet = {
          'schema_version' => 1, 'purpose' => 'woods_review_context',
          'source_lineage' => 'unverified', 'test_context' => 'explicit_files_only',
          'index' => index_provenance, 'evidence' => evidence,
          'units' => units.sort_by(&:first).map(&:last),
          'unmapped_paths' => evidence.select { |row| row.fetch('unit_keys').empty? }
                                      .map { |row| row.fetch('path') }.uniq
        }
        raise InvalidEvidence, 'Review packet byte limit exceeded' if JSON.generate(packet).bytesize > MAX_PACKET_BYTES

        packet
      end

      private

      def attach_units(file, units)
        keys = @graph.for_path(file.fetch('path'), root: @root).map do |record|
          key = record.values_at('identifier', 'type')
          units[key] ||= hydrate(record)
          key
        end
        file.merge('unit_keys' => keys)
      end

      def hydrate(record)
        identifier, type = record.values_at('identifier', 'type')
        # gem_source units use the rails_source directory in Woods' layout.
        locator_type = type == 'gem_source' ? 'rails_source' : type
        data = @index.unit(identifier, type: locator_type)
        if data && (!data.is_a?(Hash) || data.values_at('identifier', 'type') != [identifier, type])
          raise InvalidEvidence, 'Indexed unit identity disagrees with graph'
        end

        record.merge('unit_status' => data ? 'present' : 'unavailable', 'data' => data,
                     'data_sha256' => data && Digest::SHA256.hexdigest(JSON.generate(data)))
      end

      def index_provenance
        bytes = Woods::AtomicFile.read(@index.payload_dir.join('manifest.json'))
        {
          'generation' => @index.generation_number,
          'manifest' => JSON.parse(bytes),
          'manifest_sha256' => Digest::SHA256.hexdigest(bytes),
          'graph_sha256' => Digest::SHA256.hexdigest(@graph_bytes)
        }
      end
    end
  end
end
