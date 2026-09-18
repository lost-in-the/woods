# frozen_string_literal: true

require 'base64'
require 'woods/generation'
require 'woods/source_inputs/verifier'

module Woods
  module SourceInputs
    # Shared CLI/hook/MCP reader. A caller serving an older immutable payload
    # passes its own directory and generation, never the newest marker's proof.
    class Status
      BUDGETS = { 'quick' => 0.25, 'deep' => 5.0 }.freeze

      def self.from_transport(encoded)
        raise ArgumentError, 'source status options are too large' if encoded.to_s.bytesize > 16_384

        options = encoded.nil? ? {} : JSON.parse(Base64.strict_decode64(encoded))
        unless options.is_a?(Hash) && (options.keys - %w[output root mode]).empty? && options.values.all?(String)
          raise ArgumentError, 'source status options must contain only output, root and mode strings'
        end

        new(output_dir: options.fetch('output', ENV.fetch('WOODS_OUTPUT', 'tmp/woods')),
            root: options['root'], mode: options.fetch('mode', 'quick')).call
      rescue JSON::ParserError
        raise ArgumentError, 'invalid source status options'
      end

      def initialize(output_dir:, payload_dir: nil, generation: nil, root: nil, mode: 'quick')
        raise ArgumentError, 'source status mode must be quick or deep' unless BUDGETS.key?(mode)

        @output = File.expand_path(output_dir.to_s)
        @root = root
        @mode = mode
        @generation = generation
        @payload = payload_dir
      end

      def call
        return unknown(@resolution_error || 'atomic_source_manifest_unavailable') unless resolve_payload

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        manifest = File.open(File.join(@payload, Manifest::FILE_NAME), flags) do |file|
          return unknown('invalid_source_manifest') unless file.stat.file?
          return unknown('source_manifest_too_large') if file.stat.size > Manifest::MAX_BYTES

          Manifest.parse(file.read(Manifest::MAX_BYTES + 1))
        end
        Verifier.new(manifest: manifest, output_dir: @output, root: @root,
                     generation: @generation, max_seconds: BUDGETS.fetch(@mode)).call.merge('check' => @mode)
      rescue Errno::ENOENT
        unknown('source_manifest_unavailable')
      rescue Manifest::Invalid, SystemCallError, IOError
        unknown('invalid_source_manifest')
      end

      private

      def resolve_payload
        generation = Generation.new(output_dir: @output)
        marker = if @payload
                   Generation::Marker.new(payload: @payload.to_s)
                 else
                   generation.current.tap { |current| @generation = current.number }
                 end
        return false unless marker.payload.is_a?(String)

        resolved = generation.payload_dir(marker)
        return false if resolved == generation.root

        @payload = resolved
        true
      rescue TypeError, NoMethodError
        @resolution_error = 'invalid_generation'
        false
      end

      def unknown(reason)
        { 'state' => 'unknown', 'mode' => 'content', 'check' => @mode, 'generation' => @generation,
          'checked_at' => Time.now.utc.iso8601, 'complete' => false, 'reasons' => [reason] }
      end
    end
  end
end
