# frozen_string_literal: true

require_relative '../../lib/woods/published_index'
require_relative 'receipt_schema'

module WoodsDevelopment
  module TypeSafe
    # Trusted, local before/after byte attestation over declared extraction inputs.
    # Not signed provenance, Git verification, or a complete runtime dependency closure.
    module ExtractionReceipt
      class << self
        # Separate explicit roots and path lists prevent accidental cross-root inventory reuse.
        # rubocop:disable-next Metrics/ParameterLists
        def capture(root:, source_paths:, producer_root:, producer_paths:, producer_revision:, index_dir:, &block)
          ReceiptSchema.revision(producer_revision)
          check(!File.exist?(index_dir) || (File.directory?(index_dir) && Dir.empty?(index_dir)),
                'Extraction output must be absent or empty')
          inputs = {
            'source' => { 'files' => ReceiptInventory.new(root).fingerprint(source_paths) },
            'producer' => { 'revision' => producer_revision, 'files' =>
              ReceiptInventory.new(producer_root).fingerprint(producer_paths) }
          }
          run_extraction(block)
          Woods::PublishedIndex.open(index_dir) do |index|
            receipt = inputs.merge('schema_version' => 1, 'attestation' => 'trusted_local_capture_declared_inputs',
                                   'index' => index_snapshot(index))
            verify!(receipt: receipt, root: root, producer_root: producer_root, index: index)
            receipt
          end
        rescue InvalidEvidence
          raise
        rescue StandardError
          raise InvalidEvidence, 'Cannot capture extraction receipt', cause: nil
        end

        def verify!(receipt:, root:, producer_root:, index:, files: [])
          ReceiptSchema.validate(receipt)
          check_inventory(root, receipt.fetch('source').fetch('files'))
          check_inventory(producer_root, receipt.fetch('producer').fetch('files'))
          check(index_snapshot(index) == receipt.fetch('index'), 'Receipt index generation or artifact bytes changed')
          verify_selected(receipt.fetch('source').fetch('files'), files)
          true
        rescue InvalidEvidence
          raise
        rescue StandardError
          raise InvalidEvidence, 'Cannot verify extraction receipt', cause: nil
        end

        private

        def run_extraction(block)
          check(block && block.call == true, 'Capture requires an explicitly successful extraction')
        rescue StandardError
          raise InvalidEvidence, 'Capture requires an explicitly successful extraction', cause: nil
        end

        def check_inventory(root, entries)
          current = ReceiptInventory.new(root).fingerprint(entries.map { |entry| entry.fetch('path') })
          check(current == entries.sort_by { |entry| entry.fetch('path') }, 'Declared extraction input bytes changed')
        end

        def index_snapshot(index)
          check(index.generation_number.positive?, 'Receipt requires a numbered generation')
          reader = ReceiptInventory.new(index.index_dir)
          before = pointer(reader, index)
          artifacts = ReceiptInventory.new(index.payload_dir).artifacts
          check(pointer(reader, index) == before, 'Index generation changed during receipt verification')
          before.merge('artifacts' => artifacts)
        end

        def pointer(reader, index)
          data = JSON.parse(reader.read('generation.json', 16_384))
          check(data.is_a?(Hash) && data['number'] == index.generation_number, 'Receipt index generation mismatch')
          expected = "payloads/gen-#{index.generation_number}"
          check(data['payload'] == expected && File.realpath(index.index_dir.join(expected)) ==
                File.realpath(index.payload_dir), 'Receipt index generation payload mismatch')
          { 'generation' => data['number'], 'token' => data['token'], 'payload' => expected }
        end

        def verify_selected(entries, files)
          by_path = entries.to_h { |entry| [entry.fetch('path'), entry] }
          files.each do |file|
            expected = by_path[file.fetch('path')]
            check(expected && expected.fetch('sha256') == file.fetch('sha256'),
                  'Receipt does not cover selected evidence')
          end
        end

        def check(condition, message)
          ReceiptInventory.check(condition, message)
        end
      end
    end
  end
end
