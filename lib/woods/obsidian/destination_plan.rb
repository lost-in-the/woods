# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'errors'

module Woods
  module Obsidian
    # Preflight every output before changing the vault. The receipt deliberately
    # covers only the fixed machine assets; Markdown retains its public marker.
    # This is not a transaction against concurrent external editors.
    class DestinationPlan
      RECEIPT = '_woods/ownership.json'
      ASSETS = %w[_woods/manifest.json _woods/dependency_graph.json _woods/graph_analysis.json
                  .obsidian/app.json .obsidian/types.json .obsidian/graph.json Units.base].freeze
      MAX_RECEIPT_BYTES = 4096

      def initialize(vault, files, managed_note:)
        @vault = vault
        @files = files
        @managed_note = managed_note
      end

      def commit
        previous = read_receipt
        files = @files.dup
        digests = files.filter_map do |path, content|
          rel = relative(path)
          [rel, Digest::SHA256.hexdigest(content)] if ASSETS.include?(rel)
        end.to_h
        digests = previous.merge(digests)
        files[@vault.join(RECEIPT)] = "#{JSON.pretty_generate('schema_version' => 1, 'files' => digests.sort.to_h)}\n"
        snapshots = files.to_h do |path, content|
          current = existing_bytes(path)
          rel = relative(path)
          permitted = current.nil? || current == content.b ||
                      (path.extname == '.md' && @managed_note.call(path)) ||
                      (ASSETS.include?(rel) && previous[rel] == Digest::SHA256.hexdigest(current)) ||
                      rel == RECEIPT
          refuse(rel) unless permitted
          [path, current]
        end
        files.each do |path, content|
          refuse(relative(path), 'changed after preflight') unless existing_bytes(path) == snapshots[path]
          AtomicFile.write(path, content)
        end
      end

      private

      def read_receipt
        bytes = existing_bytes(@vault.join(RECEIPT))
        return {} unless bytes

        refuse(RECEIPT, 'invalid ownership receipt') if bytes.bytesize > MAX_RECEIPT_BYTES
        data = JSON.parse(bytes)
        valid = data.is_a?(Hash) && data.keys.sort == %w[files schema_version] &&
                data['schema_version'] == 1 && data['files'].is_a?(Hash) &&
                data['files'].all? do |path, digest|
                  ASSETS.include?(path) && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
                end
        refuse(RECEIPT, 'invalid ownership receipt') unless valid
        data['files']
      rescue JSON::ParserError
        refuse(RECEIPT, 'invalid ownership receipt')
      end

      # Reject child symlinks, directories and special files before any read,
      # including a FIFO at the receipt path. The vault root itself can be a
      # symlink, as can ancestors such as macOS /tmp.
      def existing_bytes(path)
        rel = relative(path)
        cursor = @vault
        parts = Pathname.new(rel).each_filename.to_a
        parts.each_with_index do |part, index|
          cursor = cursor.join(part)
          next unless cursor.exist? || cursor.symlink?

          refuse(rel, 'symlink destination') if cursor.symlink?
          expected = index == parts.size - 1 ? cursor.file? : cursor.directory?
          refuse(rel, 'not a regular destination') unless expected
        end
        path.exist? ? File.binread(path) : nil
      end

      def relative(path)
        rel = path.relative_path_from(@vault).to_s
        refuse(rel, 'outside the vault') if Pathname.new(rel).each_filename.include?('..')
        rel
      end

      def refuse(path, reason = 'unmanaged or modified destination')
        raise ExportError, "refusing #{path}: #{reason}; no sweep performed. " \
                           'Inspect and back up the conflicting file, then move it aside or export to a new directory.'
      end
    end
  end
end
