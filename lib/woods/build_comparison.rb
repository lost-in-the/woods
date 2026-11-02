# frozen_string_literal: true

module Woods
  # The outcome of comparing the Woods build that wrote an index (recorded in
  # its manifest) with the build reading it. See {BuildIdentity}.
  #
  # `state` is one of:
  # - `same_build`: same version string and same revision.
  # - `same_version`: same version string; one side has no revision, so the
  #   builds cannot be told apart (a released gem on either side).
  # - `version_mismatch`: the version strings differ.
  # - `build_mismatch`: same version string, different revisions.
  # - `unknown`: the manifest records no usable writer version.
  BuildComparison = Struct.new(:state, :message, :writer_version, :writer_revision, :writer_dirty,
                               :reader_version, :reader_revision, :reader_dirty, keyword_init: true) do
    # @return [Boolean] whether the writer is known to be another build
    def mismatch?
      %w[version_mismatch build_mismatch].include?(state)
    end

    # @return [Hash] for `woods_status`
    def to_h
      { state: state, message: message,
        writer: { version: writer_version, revision: writer_revision, dirty: writer_dirty },
        reader: { version: reader_version, revision: reader_revision, dirty: reader_dirty } }
    end
  end

  class BuildComparison
    SHA = /\A\h{40,64}\z/

    class << self
      # @param manifest [Hash, nil]
      # @param reader [BuildIdentity]
      # @return [BuildComparison]
      def call(manifest, reader:)
        manifest = {} unless manifest.is_a?(Hash)
        fields = writer_fields(manifest).merge(reader_version: reader.version)
        state, message = verdict(fields, reader)
        new(state: state, message: message, **fields)
      end

      private

      def writer_fields(manifest)
        revision = manifest['woods_revision']
        { writer_version: manifest['woods_version'],
          writer_revision: revision.is_a?(String) && SHA.match?(revision) ? revision : nil,
          writer_dirty: manifest['woods_revision_dirty'] }
      end

      # Asks the reader for its revision (possibly a git call) only when the
      # writer recorded one to compare with.
      def verdict(fields, reader)
        version = fields[:writer_version]
        return ['unknown'] unless version.is_a?(String) && !version.empty?
        return ['version_mismatch', version_message(version, reader.version)] if version != reader.version
        return ['same_version'] unless fields[:writer_revision]

        fields.merge!(reader_revision: reader.revision, reader_dirty: reader.dirty)
        return ['same_version'] unless fields[:reader_revision]
        return ['same_build'] if fields[:writer_revision] == fields[:reader_revision]

        ['build_mismatch', build_message(fields)]
      end

      def version_message(writer, reader)
        "Index written by Woods #{writer}, this reader is #{reader}; run `woods:extract` or request a re-index."
      end

      def build_message(fields)
        "Index written by a different Woods build (#{label(fields[:writer_revision], fields[:writer_dirty])}); " \
          "this reader is #{label(fields[:reader_revision], fields[:reader_dirty])}, " \
          "both #{fields[:reader_version]}. Run `woods:extract` with this build or request a re-index."
      end

      def label(revision, dirty)
        "#{revision[0, 12]}#{'-dirty' if dirty}"
      end
    end
  end
end
