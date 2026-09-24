# frozen_string_literal: true

module Woods
  # Filesystem encoding tags follow the locale; published source paths use
  # UTF-8. Validate the original bytes without transcoding or replacing them.
  module SourcePathEncoding
    DIAGNOSTIC_BYTES = 256
    class Invalid < ArgumentError; end

    def self.utf8(path)
      string = path.to_s
      string = string.dup.force_encoding(Encoding::UTF_8) unless string.encoding == Encoding::UTF_8
      string if string.valid_encoding?
    end

    def self.utf8!(path)
      utf8(path) || raise(Invalid, 'source paths must contain valid UTF-8 bytes')
    end

    def self.expand(path)
      utf8!(File.expand_path(utf8!(path)))
    end

    # An escaped byte label, never a substituted filesystem path. Bound the
    # original bytes before escaping, so even malformed deep paths stay small.
    def self.diagnostic(path)
      bytes = path.to_s.b
      label = bytes.byteslice(0, DIAGNOSTIC_BYTES).inspect
      label += '...' if bytes.bytesize > DIAGNOSTIC_BYTES
      label
    end
  end
end
