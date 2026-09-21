# frozen_string_literal: true

require 'base64'
require 'fileutils'
require_relative '../atomic_file'
require_relative 'plan'
require_relative 'recovery'

module Woods
  module AgentConfiguration
    # Atomic per-file replacement with a private recovery journal. Multiple
    # configuration files cannot be one filesystem transaction; interrupted
    # writes retain enough original bytes to explicitly recover without
    # overwriting concurrent edits.
    class Applier
      include Recovery

      def initialize(layout:, writer: Woods::AtomicFile.method(:write))
        @layout = layout
        @writer = writer
      end

      def apply(plan)
        plan.validate!(@layout)
        with_lock do
          refuse_pending!
          changes = plan.data.fetch('changes')
          return 'already_applied' if changes.all? { |change| current(change) == Plan.after_fingerprint(change) }

          journal = { 'schema_version' => 1, 'plan' => plan.data, 'originals' => originals(changes) }
          write_journal(journal)
          apply_changes(changes, journal)
          'applied'
        end
      end

      def recover
        with_lock do
          document = Document.new(journal_path)
          return 'nothing_to_recover' if document.content.nil?

          recover_journal(document.json)
          'recovered'
        end
      end

      private

      def journal_path
        "#{@layout.receipt_path}.pending"
      end

      def with_lock(paths = @layout.lock_paths, &operation)
        return operation.call if paths.empty?

        path, *remaining = paths
        Document.validate_path!(path)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600) do |lock|
          raise Conflict, "Not a regular lock file: #{path}" unless lock.stat.file?
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Conflict,
                  'Another Woods configuration operation is active; retry after it finishes'
          end

          with_lock(remaining, &operation)
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError => e
        raise Conflict, "Configuration write failed: #{e.message}"
      end

      def write_journal(journal)
        encoded = JSON.generate(journal)
        if encoded.bytesize > Document::MAX_BYTES
          raise Conflict, 'Recovery journal would exceed 8 MiB; reduce the selected configuration before applying'
        end

        @writer.call(journal_path, encoded, mode: 0o600)
      end

      def refuse_pending!
        return if Document.new(journal_path).content.nil?

        raise Conflict, "An interrupted operation needs explicit recovery first: #{journal_path}"
      end

      def current(change)
        Document.new(change.fetch('path')).fingerprint
      end

      def assert_snapshot!(actual, expected, path)
        return if actual == expected

        raise Conflict, "Changed since preview: #{path}; create a new plan without discarding the user's edits"
      end

      def replace(path, content, mode)
        Document.validate_path!(path)
        if content.nil?
          remove_file(path)
        else
          @writer.call(path, content, mode: mode)
        end
      end

      def remove_file(path)
        File.unlink(path)
      rescue Errno::ENOENT
        nil
      end

      def originals(changes)
        changes.map do |change|
          document = Document.new(change.fetch('path'))
          assert_snapshot!(document.fingerprint, change.fetch('before'), document.path)
          { 'path' => document.path, 'content' => document.content && Base64.strict_encode64(document.content),
            'mode' => document.mode }
        end
      end

      def apply_changes(changes, journal)
        changes.each do |change|
          assert_snapshot!(current(change), change.fetch('before'), change.fetch('path'))
          replace(change.fetch('path'), Plan.after_content(change), change.fetch('mode'))
        end
        File.unlink(journal_path)
      rescue StandardError => e
        recover_journal(journal)
        raise Conflict, "Apply failed and original files were restored: #{e.message}"
      end
    end
  end
end
