# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'error'

module Woods
  module AgentConfiguration
    # Reads bounded regular files and rejects symlink components before writes.
    # Preview/apply snapshots include exact bytes and permissions, so edits made
    # after preview cannot be overwritten by a stale plan.
    class Document
      MAX_BYTES = 8 * 1024 * 1024

      class UniqueObject < Hash
        def []=(key, value)
          raise Conflict, "Duplicate JSON key #{key.inspect}; resolve the ambiguous configuration" if key?(key)

          super
        end
      end

      attr_reader :path, :content, :mode

      def initialize(path)
        @path = File.expand_path(path)
        self.class.validate_path!(@path)
        @content = nil
        @mode = 0o600
        return unless File.exist?(@path)

        File.open(@path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          stat = file.stat
          raise Conflict, "Expected a regular file: #{@path}" unless stat.file?
          raise Conflict, "Configuration file exceeds #{MAX_BYTES} bytes: #{@path}" if stat.size > MAX_BYTES

          read_content(file)
          @mode = stat.mode & 0o777
        end
      rescue SystemCallError => e
        raise Conflict, "Cannot read configuration #{@path}: #{e.message}"
      end

      def self.validate_path!(path)
        current = File.expand_path(path)
        loop do
          raise Conflict, "Symlink target or parent is unsupported: #{current}" if File.symlink?(current)

          parent = File.dirname(current)
          break if parent == current

          current = parent
        end
      end

      def fingerprint
        { 'sha256' => content && Digest::SHA256.hexdigest(content), 'mode' => mode, 'exists' => !content.nil? }
      end

      def json
        return {} if content.nil?

        value = JSON.parse(content, object_class: UniqueObject)
        raise Conflict, "Expected a JSON object: #{path}" unless value.is_a?(Hash)

        plain_value(value)
      rescue JSON::ParserError => e
        raise Conflict, "Malformed JSON in #{path}: #{e.message}"
      end

      def encode_json(value)
        return content if !content.nil? && json == value

        return JSON.generate(value) if content && !content.include?("\n")

        JSON.pretty_generate(value, indent: json_indent).gsub("\n", newline) + newline
      end

      private

      def read_content(file)
        @content = (file.read(MAX_BYTES + 1) || String.new).force_encoding(Encoding::UTF_8)
        raise Conflict, "Invalid UTF-8 configuration: #{@path}" unless @content.valid_encoding?
        raise Conflict, "Configuration file too large: #{@path}" if @content.bytesize > MAX_BYTES
      end

      def newline
        content&.include?("\r\n") ? "\r\n" : "\n"
      end

      def json_indent
        match = content&.match(/\n([ \t]+)"/)
        match ? match[1] : '  '
      end

      def plain_value(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), hash| hash[key] = plain_value(item) }
        when Array then value.map { |item| plain_value(item) }
        else value
        end
      end
    end
  end
end
