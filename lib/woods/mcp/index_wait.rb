# frozen_string_literal: true

require 'json'
require 'mcp'
require 'time'
require_relative '../generation'
require_relative '../index_artifact'
require_relative '../resolved_config'
require_relative 'index_reader_pinning'
require_relative 'served_identity'
require_relative 'worktree_routing'

module Woods
  module MCP
    # A server started before its index exists (`woods-mcp-start
    # --await-index`, `WOODS_MCP_AWAIT_INDEX=1`).
    #
    # Without it a missing index is a failed launch: the server exits before
    # `initialize`, so the agent has no tools and nothing that says why. With
    # it the server completes the handshake and registers the tools it always
    # does. `woods_status` reports what it is waiting for ({#status}); every
    # other tool answers a non-error, retryable `building` result, shaped as
    # the hydration `warming` result is; a resource read is refused with
    # `index_building`.
    #
    # The first readable generation ends the wait: the next call goes through
    # to the reader, whose freshness check adopts it as it adopts any newly
    # published generation. The wait is a latch, so damage to a later
    # generation is reported as damage, never as `building`. A marker that
    # exists but cannot identify a generation is damage already
    # (`corrupt_artifact`), as it is to a strict launch.
    #
    # A strict launch refuses an index another checkout recorded before the
    # server starts; an awaiting one could not, since nothing was recorded
    # yet. So every call is checked the same way, with the same override,
    # against the generation that call reads ({#mismatch_for}, {Judge}).
    class IndexWait
      ENV_NAME = 'WOODS_MCP_AWAIT_INDEX'

      # Written by an external launcher that started the first extraction.
      BOOTSTRAP_FILE = '.bootstrap.json'

      # The bootstrap file is untrusted: bytes read at most, the fields
      # reported, and the characters kept of each.
      MAX_BOOTSTRAP_BYTES = 4096
      BOOTSTRAP_FIELDS = %w[started_at command state].freeze
      MAX_BOOTSTRAP_FIELD_CHARS = 256

      # `retry_after_seconds` of a `building` answer. A first extraction takes
      # seconds to minutes, so a retry sooner than this learns nothing.
      RETRY_AFTER_SECONDS = 5

      # The one tool that answers while waiting.
      STATUS_TOOL = 'woods_status'

      # @param env [Hash]
      # @return [Boolean]
      def self.requested?(env = ENV)
        ServedIdentity.env_flag?(ENV_NAME, env)
      end

      # @return [String] ISO 8601 time the server started waiting
      attr_reader :since

      # @param index_dir [String, Pathname] the directory an index is awaited in
      # @param reader [#manifest_present?] the server's launch reader
      # @param boot [Hash] what startup wired: `snapshots:` and `retriever:`
      #   (booleans), for {#restart_recommended}
      def initialize(index_dir:, reader:, boot: {})
        @index_dir = index_dir.to_s
        @reader = reader
        @boot = boot
        @since = Time.now.utc.iso8601
        @ready = false
      end

      # @return [Symbol] `:ready` once a published index has been readable
      #   (a latch), `:unusable` for a marker that exists but cannot identify
      #   a generation, else `:building`
      def phase
        return :ready if @ready
        return :unusable if unusable_marker?

        @ready = @reader.manifest_present?
        @ready ? :ready : :building
      end

      # @return [Boolean]
      def ready?
        phase == :ready
      end

      # Why the generation +reader+ serves is refused: it records another
      # checkout than the client's, and the mismatch is not allowed. Judged
      # inside a generation pin, from the pinned marker and manifest, so the
      # generation judged is the one the caller then reads. Nested in a pin
      # the caller already holds, it rides that pin's generation.
      #
      # @param reader [IndexReader] the server's launch reader
      # @return [String, nil] the refusal message, or nil to serve it
      def mismatch_for(reader)
        reader.with_pinned_generation do
          identity = ServedIdentity.pinned(@index_dir, reader: reader, manifest: pinned_manifest(reader))
          identity.refusal_message if identity.client_matches == false && !ServedIdentity.allow_mismatch?
        end
      end

      # Capabilities startup could not wire that the index directory now
      # supports. Startup chooses the snapshot store and the semantic
      # retriever once, so only a restart adds them.
      #
      # @return [Array<Hash>]
      def restart_recommended
        list = []
        if !@boot[:snapshots] && snapshots_available?
          list << { feature: 'snapshots', reason: 'snapshot tools become available after a restart' }
        end
        if !@boot[:retriever] && embedding_config?
          list << { feature: 'semantic_retrieval', reason: 'semantic retrieval becomes available after a restart' }
        end
        list
      end

      # @param tool [String]
      # @param message [String] from {#mismatch}
      # @return [Hash] a serialized, non-retryable tool result
      def mismatch_response(tool, message)
        ::MCP::Tool::Response.new(
          [{ type: 'text', text: message }], error: true,
                                             structured_content: { text: message },
                                             meta: { error_code: :index_checkout_mismatch, retryable: false,
                                                     tool: tool }
        ).to_h
      end

      # The `index` section of `woods_status` while waiting.
      #
      # @return [Hash]
      def status
        {
          state: 'awaiting_index',
          diagnostic: "No Woods index is published in #{@index_dir} yet: it is being built or has not been " \
                      'started. This server serves the first one on the next call, with no restart.',
          watching: @index_dir,
          awaiting_since: @since,
          bootstrap: bootstrap,
          counts: {}
        }
      end

      # The result of any tool but `woods_status` while waiting.
      #
      # @param tool [String]
      # @return [Hash] a serialized tool result
      def building_response(tool)
        message = "Not answered yet: no Woods index is published in #{@index_dir} yet. This is not an empty " \
                  'result and nothing failed. The server serves the first index on the next call, with no ' \
                  'restart. Call woods_status to see what it is waiting for, then retry this call.'
        data = { status: 'building', retryable: true, retry_after_seconds: RETRY_AFTER_SECONDS, tool: tool,
                 index: status }
        ::MCP::Tool::Response.new(
          [{ type: 'text', text: message }],
          structured_content: { text: message, data: data },
          meta: { index: 'building', retryable: true, retry_after_seconds: RETRY_AFTER_SECONDS }
        ).to_h
      end

      # What the launcher-written bootstrap file says, reduced to the fields
      # this server reports, or nil when there is none.
      #
      # @return [Hash, nil]
      def bootstrap
        bytes = read_bootstrap_bytes
        return if bytes.nil?
        return { readable: false, reason: 'malformed' } if bytes.empty?
        return { readable: false, reason: 'too_large' } if bytes.bytesize > MAX_BOOTSTRAP_BYTES

        data = JSON.parse(bytes.force_encoding(Encoding::UTF_8).scrub)
        return { readable: false, reason: 'malformed' } unless data.is_a?(Hash)

        BOOTSTRAP_FIELDS.each_with_object({ readable: true }) do |field, fields|
          value = data[field]
          fields[field.to_sym] = value.dup.force_encoding(Encoding::UTF_8).scrub[0, MAX_BOOTSTRAP_FIELD_CHARS] if
            value.is_a?(String)
        end
      rescue JSON::ParserError
        { readable: false, reason: 'malformed' }
      end

      # Prepended onto a built server's singleton class, outermost, so a call
      # made while waiting takes no generation pin and waits for no warm-up.
      module Dispatch
        private

        def call_tool(request, **)
          wait = @woods_index_wait
          name = request[:name]
          return super if wait.nil? || name == STATUS_TOOL || !tools.key?(name)

          case wait.phase
          when :building then wait.building_response(name)
          when :unusable then IndexReaderPinning.corrupt_marker_response(name)
          else super
          end
        end

        def read_resource_contents(request, **)
          wait = @woods_index_wait
          return super if wait.nil?

          return super unless wait.phase == :building

          IndexWait.refuse_resource(request, 'No Woods index is published yet; call woods_status and retry.',
                                    'index_building', retryable: true)
        end
      end

      # Prepended inside the generation pin (see {Server.build}), so a call
      # is judged against the generation it reads. Routed calls describe
      # another worktree and are not judged against this one.
      module Judge
        private

        def call_tool(request, **)
          wait = @woods_index_wait
          name = request[:name]
          return super if wait.nil? || name == STATUS_TOOL || !tools.key?(name) ||
                          Thread.current[WorktreeRouting::THREAD_KEY]

          refusal = wait.mismatch_for(@woods_index_reader)
          refusal ? wait.mismatch_response(name, refusal) : super
        end

        def read_resource_contents(request, **)
          wait = @woods_index_wait
          refusal = wait&.mismatch_for(@woods_index_reader)
          return super unless refusal

          IndexWait.refuse_resource(request, refusal, 'index_checkout_mismatch', retryable: false)
        end
      end

      # @raise [MCP::Server::RequestHandlerError]
      def self.refuse_resource(request, message, code, retryable:)
        raise ::MCP::Server::RequestHandlerError.new(
          message, request,
          error_type: :internal_error, error_code: ::JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
          error_data: { uri: request[:uri], error_code: code, retryable: retryable }
        )
      end

      private

      # Opens without following a symlink and without blocking on a FIFO,
      # then reads only from a regular file, at most one byte past the cap.
      #
      # @return [String, nil] nil when there is no regular file to report
      def read_bootstrap_bytes
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(File.join(@index_dir, BOOTSTRAP_FILE), flags) do |file|
          next unless file.stat.file?

          file.binmode
          file.read(MAX_BOOTSTRAP_BYTES + 1) || +''
        end
      rescue SystemCallError, IOError
        nil
      end

      # A marker that exists and cannot identify a generation: malformed, or
      # naming a payload outside the index directory. A payload that is not
      # there yet is a first generation still being written, not damage.
      def unusable_marker?
        generation = Woods::Generation.new(output_dir: @index_dir)
        return false unless File.exist?(generation.path)

        marker = generation.current!
        name = marker.payload
        return false if name.nil? || name.empty?

        unusable_payload?(generation.root, name)
      rescue Woods::Generation::InvalidMarker
        true
      end

      # A payload pointer whose target is outside the index directory, or
      # exists and is not a directory. A target not written yet is not damage.
      def unusable_payload?(root, name)
        lexical = File.expand_path(name, root.to_s)
        return true unless lexical.start_with?("#{File.expand_path(root.to_s)}#{File::SEPARATOR}")

        candidate = root.join(name)
        return false unless candidate.exist? || candidate.symlink?
        return true unless candidate.realpath.to_s.start_with?("#{root.realpath}#{File::SEPARATOR}")

        !candidate.directory?
      rescue SystemCallError
        true
      end

      def pinned_manifest(reader)
        reader.manifest
      rescue StandardError
        nil
      end

      def snapshots_available?
        File.exist?(File.join(@index_dir, 'woods.sqlite3')) ||
          (ENV['WOODS_SNAPSHOTS'] == 'true' && File.directory?(@index_dir))
      end

      # A config a restarted server would accept: parseable, and passing the
      # schema check a semantic boot makes. A damaged or refused one is no
      # reason to restart.
      def embedding_config?
        config = Woods::IndexArtifact.new(@index_dir).read_config
        return false unless config.is_a?(Hash)

        Woods::ResolvedConfig.from_hash(config)
        true
      rescue StandardError
        false
      end
    end
  end
end
