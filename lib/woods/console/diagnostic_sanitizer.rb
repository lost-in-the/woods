# frozen_string_literal: true

require_relative 'credential_scanner'

module Woods
  module Console
    # Bounded, fail-closed credential protection for Woods-owned diagnostics.
    # Never slice an unscanned message: that could expose a partial credential.
    class DiagnosticSanitizer
      MAX_BYTES = 8192
      OMITTED = '[DIAGNOSTIC_OMITTED: message exceeds 8192 bytes]'
      FAILED = '[REDACTION_FAILED]'

      # @param scanner [#scan, nil] Prefer the server's registered scanner so
      #   credential rotation also updates diagnostic protection.
      def initialize(scanner: nil)
        @scanner = scanner || CredentialScanner.new
      end

      # @param value [Object] A diagnostic field, never a response payload.
      # @return [String] Scanned text or a content-free omission marker.
      def text(value)
        text = value.to_s
        return OMITTED if text.bytesize > MAX_BYTES
        return FAILED unless text.valid_encoding?

        scanned, = @scanner.scan(text)
        return FAILED unless scanned.is_a?(String) && scanned.valid_encoding?
        return OMITTED if scanned.bytesize > MAX_BYTES

        scanned
      rescue StandardError
        FAILED
      end
    end
  end
end
