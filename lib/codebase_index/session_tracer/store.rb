# frozen_string_literal: true

module CodebaseIndex
  module SessionTracer
    # Abstract store interface for session trace data.
    #
    # Concrete implementations must define:
    # - `record(session_id, request_data)` — append a request record
    # - `read(session_id)` — return all requests for a session, ordered by timestamp
    # - `sessions(limit:)` — return recent session summaries
    # - `clear(session_id)` — remove a single session
    # - `clear_all` — remove all sessions
    #
    # @abstract Subclass and implement the required methods.
    class Store
      # Append a request record to a session.
      #
      # @param session_id [String] The session identifier
      # @param request_data [Hash] Request metadata to store
      # @return [void]
      def record(session_id, request_data)
        raise NotImplementedError, "#{self.class}#record must be implemented"
      end

      # Read all request records for a session, ordered by timestamp.
      #
      # @param session_id [String] The session identifier
      # @return [Array<Hash>] Request records, oldest first
      def read(session_id)
        raise NotImplementedError, "#{self.class}#read must be implemented"
      end

      # List recent session summaries.
      #
      # @param limit [Integer] Maximum number of sessions to return
      # @return [Array<Hash>] Session summaries with :session_id, :request_count, :first_request, :last_request
      def sessions(limit: 20)
        raise NotImplementedError, "#{self.class}#sessions must be implemented"
      end

      # Remove all data for a single session.
      #
      # @param session_id [String] The session identifier
      # @return [void]
      def clear(session_id)
        raise NotImplementedError, "#{self.class}#clear must be implemented"
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        raise NotImplementedError, "#{self.class}#clear_all must be implemented"
      end

      private

      # Sanitize a session ID for use in keys/filenames.
      #
      # @param session_id [String] Raw session identifier
      # @return [String] Sanitized identifier (alphanumeric, hyphens, underscores only)
      def sanitize_session_id(session_id)
        session_id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')
      end
    end
  end
end
