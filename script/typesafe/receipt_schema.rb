# frozen_string_literal: true

require_relative 'receipt_inventory'

module WoodsDevelopment
  module TypeSafe
    # Exact local attestation format. Revision identity is supplied by the caller.
    module ReceiptSchema
      class << self
        def validate(receipt)
          fields(receipt, %w[schema_version attestation source producer index])
          check(receipt['schema_version'].is_a?(Integer) && receipt['schema_version'] == 1,
                'Unsupported extraction receipt schema')
          check(receipt['attestation'] == 'trusted_local_capture_declared_inputs', 'Invalid receipt attestation')
          fields(receipt['source'], %w[files])
          fields(receipt['producer'], %w[revision files])
          revision(receipt['producer']['revision'])
          inventory(receipt['source']['files'])
          inventory(receipt['producer']['files'])
          index(receipt['index'])
          receipt
        end

        def revision(value)
          check(value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/), 'Expected full producer revision')
        end

        private

        def index(value)
          fields(value, %w[generation token payload artifacts])
          check(value['generation'].is_a?(Integer) && value['generation'].positive?, 'Invalid receipt generation')
          check(value['token'].is_a?(String) && value['token'].bytesize.between?(1, 256), 'Invalid receipt token')
          check(value['payload'] == "payloads/gen-#{value['generation']}", 'Invalid receipt payload')
          inventory(value['artifacts'])
        end

        def inventory(entries)
          check(entries.is_a?(Array) && entries.length.between?(1, ReceiptInventory::MAX_FILES),
                'Invalid receipt inventory size')
          paths = entries.map { |entry| inventory_entry(entry) }
          check(paths.uniq.length == paths.length, 'Duplicate receipt inventory paths')
          check(entries.sum { |entry| entry['bytes'] } <= ReceiptInventory::MAX_TOTAL_BYTES,
                'Receipt inventory byte limit exceeded')
        end

        def inventory_entry(entry)
          fields(entry, %w[path sha256 bytes])
          ReceiptInventory.validate_path(entry['path'])
          check(entry['sha256'].is_a?(String) && entry['sha256'].match?(/\A[0-9a-f]{64}\z/), 'Invalid receipt digest')
          check(entry['bytes'].is_a?(Integer) && entry['bytes'].between?(0, ReceiptInventory::MAX_FILE_BYTES),
                'Invalid receipt byte count')
          entry['path']
        end

        def fields(value, keys)
          check(value.is_a?(Hash) && value.keys.sort == keys.sort, 'Invalid extraction receipt fields')
        end

        def check(condition, message)
          ReceiptInventory.check(condition, message)
        end
      end
    end
  end
end
