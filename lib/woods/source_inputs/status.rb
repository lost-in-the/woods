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
        options = transport_options(encoded)
        new(output_dir: options.fetch('output', ENV.fetch('WOODS_OUTPUT', 'tmp/woods')),
            root: options.fetch('root', Dir.pwd), mode: options.fetch('mode', 'quick')).call
          .merge('root_source' => options.key?('root') ? 'explicit' : 'working_directory')
      end

      def self.transport_options(encoded)
        raise ArgumentError, 'source status options are too large' if encoded.to_s.bytesize > 16_384

        options = encoded.nil? ? {} : JSON.parse(Base64.strict_decode64(encoded))
        unless options.is_a?(Hash) && (options.keys - %w[output root mode]).empty? && options.values.all?(String)
          raise ArgumentError, 'source status options must contain only output, root and mode strings'
        end

        options
      rescue JSON::ParserError
        raise ArgumentError, 'invalid source status options'
      end

      private_class_method :transport_options

      def initialize(output_dir:, payload_dir: nil, generation: nil, root: nil, mode: 'quick')
        raise ArgumentError, 'source status mode must be quick or deep' unless BUDGETS.key?(mode)

        @output = SourcePathEncoding.expand(output_dir)
        @root = SourcePathEncoding.expand(root) if root
        @mode = mode
        @generation = generation
        @payload = SourcePathEncoding.utf8!(payload_dir) if payload_dir
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
        result = Verifier.new(manifest: manifest, output_dir: @output, root: @root,
                              generation: @generation, max_seconds: BUDGETS.fetch(@mode)).call
        result.merge('check' => @mode, 'recommendations' => recommendations(result, manifest))
      rescue Errno::ENOENT
        unknown('source_manifest_unavailable')
      rescue Manifest::Invalid, SystemCallError, IOError
        unknown('invalid_source_manifest')
      rescue EncodingError, SourcePathEncoding::Invalid
        unknown('undecodable_source_path')
      end

      private

      def recommendations(result, manifest)
        return ['inspect_source_limits'] if result['state'] == 'unavailable'

        advice = []
        reader_reasons = result.fetch('verification_reasons', result.fetch('reasons'))
        if @mode == 'quick' && reader_reasons.include?('scan_time_budget')
          advice << 'deep_check'
          reader_reasons -= ['scan_time_budget']
        end
        advice << 'inspect_source_scan' unless reader_reasons.empty?
        advice << 'fresh_capture' if incomplete_capture?(manifest)
        advice
      end

      def incomplete_capture?(manifest)
        !manifest.comparison_complete? || !manifest.data['boot_verified'] ||
          !manifest.data.fetch('errors').empty? || !manifest.data.fetch('unverified_scopes').empty?
      end

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
          'checked_at' => Time.now.utc.iso8601, 'complete' => false, 'reasons' => [reason],
          'recorded_root' => nil, 'checked_root' => @root, 'root_source' => @root ? 'explicit' : 'recorded',
          'recommendations' => ['fresh_capture'] }
      end
    end
  end
end
