# frozen_string_literal: true

require 'json'
require_relative '../atomic_file'
require_relative 'registry'

module Woods
  module SourceReferences
    # Generation-local candidate evidence and the edges this pass added. Source
    # bytes never belong here. Replacing the file must not mutate a hardlinked
    # seed belonging to the previously published generation.
    # Keep the closed schema beside its I/O boundary: neither half may accept a
    # cache that the other half cannot safely publish or replay.
    class Cache # rubocop:disable Metrics/ClassLength
      class Invalid < StandardError; end

      # Older JSON parsers pass pairs through #[]=; newer ones must also use
      # allow_duplicate_key: false before constructing custom objects. A plain
      # builder avoids optimized Hash writes and returns ordinary consumer data.
      class UniqueObject
        attr_reader :data

        def initialize
          @data = {}
        end

        def []=(key, value)
          raise Invalid, 'Source reference cache contains a duplicate JSON key' if @data.key?(key)

          @data[key] = unwrap(value)
        end

        def unwrap(value)
          case value
          when UniqueObject then value.data
          when Array then value.map { |item| unwrap(item) }
          else value
          end
        end
      end
      private_constant :UniqueObject

      FILE_NAME = 'source_references.json'
      VERSION = 3
      MAX_BYTES = 64 * 1024 * 1024
      MAX_FILES = 100_000
      MAX_OWNERS = 200_000
      MAX_RECORDS = 1_000_000
      MAX_NESTING = 128
      MAX_STRING_BYTES = 4096
      MAX_LINE = 1_000_000_000
      IDENTITY = /\A[0-9a-f]{64}\z/
      TYPES = Registry::TYPES.map(&:to_s).freeze
      SKIP_REASONS = %w[dynamic_declaration dynamic_superclass dynamic_constant_path unowned_reference
                        dynamic_singleton_scope dynamic_method_owner].freeze

      class << self
        # @param path [String, Pathname] cache in one generation payload
        # @return [Hash, nil] validated evidence, or nil only when absent
        # @raise [Invalid] unreadable, unsupported or invalid cache
        def read(path)
          return unless regular_file?(path)

          data = JSON.parse(read_bytes(path), object_class: UniqueObject, allow_duplicate_key: false)
          data = data.data if data.is_a?(UniqueObject)
          validate!(data)
          data
        rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
          raise Invalid, "Cannot read source reference cache: #{e.class}"
        end

        # @param path [String, Pathname] destination within the new payload
        # @param data [Hash] versioned candidate and pass-owned edge evidence
        # @return [void]
        # @raise [Invalid] unsupported or invalid cache; previous bytes survive
        def write(path, data)
          validate!(data)
          bytes = JSON.generate(data)
          raise Invalid, 'Source reference cache exceeds size limit' if bytes.bytesize > MAX_BYTES

          regular_file?(path)
          AtomicFile.write(path, bytes)
        rescue JSON::GeneratorError, EncodingError => e
          raise Invalid, "Cannot encode source reference cache: #{e.class}"
        end

        private

        def regular_file?(path)
          stat = File.lstat(path)
          raise Invalid, 'Source reference cache must be a regular file, not a symlink' unless stat.file?

          true
        rescue Errno::ENOENT
          false
        end

        def read_bytes(path)
          flags = File::RDONLY | File::NONBLOCK
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags) do |file|
            raise Invalid, 'Source reference cache must be a regular file' unless file.stat.file?
            raise Invalid, 'Source reference cache exceeds size limit' if file.stat.size > MAX_BYTES

            bytes = (file.read(MAX_BYTES + 1) || '').force_encoding(Encoding::UTF_8)
            raise Invalid, 'Source reference cache exceeds size limit' if bytes.bytesize > MAX_BYTES
            raise Invalid, 'Source reference cache is not UTF-8' unless bytes.valid_encoding?

            bytes
          end
        end

        def validate!(data)
          shape!(data, %w[version files owners])
          require!(data['version'].instance_of?(Integer) && data['version'] == VERSION, 'unsupported version')
          files = data['files']
          require!(files.is_a?(Hash) && files.size <= MAX_FILES, 'invalid files or file limit')
          records = 0
          files.each { |path, record| records = bounded_count(records + file!(path, record)) }
          owners!(data['owners'], files, records)
        end

        def file!(path, record)
          path!(path)
          shape!(record, %w[identity analysis])
          require!(record['identity'].is_a?(String) && IDENTITY.match?(record['identity']), 'invalid identity')
          analysis!(record['analysis'])
        end

        def analysis!(analysis)
          shape!(analysis, %w[declarations references skipped parse_error])
          declarations = records!(analysis['declarations'])
          references = records!(analysis['references'])
          skipped = records!(analysis['skipped'])
          total = declarations.size + references.size + skipped.size
          require!(total <= MAX_RECORDS, 'candidate record limit exceeded')
          declarations.each { |record| declaration!(record) }
          references.each { |record| reference!(record) }
          skipped.each { |record| skipped!(record) }
          parse_error!(analysis['parse_error'], total)
          total
        end

        def declaration!(record)
          shape!(record, %w[owner name kind nesting enclosing_nesting line end_line], %w[singleton_depth constructor])
          lexical_record!(record)
          if record.key?('constructor')
            require!(record['kind'] == 'class' && %w[Struct ::Struct Data ::Data].include?(record['constructor']),
                     'invalid value-class constructor')
          end
          require!(%w[class module].include?(record['kind']), 'invalid declaration kind')
          nesting!(record['enclosing_nesting'])
          line!(record['end_line'])
          require!(record['end_line'] >= record['line'], 'invalid declaration range')
        end

        def reference!(record)
          shape!(record, %w[owner name nesting line], %w[singleton_depth])
          lexical_record!(record)
        end

        def lexical_record!(record)
          constant!(record['owner'])
          constant!(record['name'], rooted: true)
          nesting!(record['nesting'])
          require!(record['nesting'].first == record['owner'], 'owner disagrees with lexical nesting')
          line!(record['line'])
          return unless record.key?('singleton_depth')

          depth = record['singleton_depth']
          require!(depth.instance_of?(Integer) && depth.between?(0, MAX_NESTING), 'invalid singleton depth')
        end

        def skipped!(record)
          shape!(record, %w[reason owner line])
          require!(SKIP_REASONS.include?(record['reason']), 'invalid skip reason')
          constant!(record['owner']) unless record['owner'].nil?
          line!(record['line'])
        end

        def parse_error!(error, total)
          return if error.nil?

          shape!(error, %w[message line])
          string!(error['message'])
          line!(error['line'])
          require!(total.zero?, 'parse failure contains partial records')
        end

        def owners!(owners, files, count)
          require!(owners.is_a?(Array) && owners.size <= MAX_OWNERS, 'invalid owners or owner limit')
          seen = {}
          owners.each do |owner|
            count = bounded_count(count + owner!(owner, files))
            identity = owner.values_at('type', 'identifier')
            require!(!seen.key?(identity), 'duplicate owner identity')
            seen[identity] = true
          end
        end

        def owner!(owner, files)
          shape!(owner, %w[type identifier file_path added], %w[file_paths])
          type!(owner['type'])
          constant!(owner['identifier'])
          path!(owner['file_path'])
          require!(files.key?(owner['file_path']), 'owner source is absent from files')
          contributor_paths!(owner, files) if owner.key?('file_paths')
          edges = records!(owner['added'])
          edges.each { |edge| edge!(edge) }
          require!(edges.uniq.size == edges.size, 'duplicate pass-owned edge')
          edges.size
        end

        def contributor_paths!(owner, files)
          paths = owner['file_paths']
          require!(paths.is_a?(Array) && paths.size > 1 && paths.uniq == paths &&
                   paths.first == owner['file_path'], 'invalid owner contributors')
          paths.each do |path|
            path!(path)
            require!(files.key?(path), 'owner contributor is absent from files')
          end
        end

        def edge!(edge)
          shape!(edge, %w[type target via])
          type!(edge['type'])
          constant!(edge['target'])
          require!(edge['via'] == 'code_reference', 'invalid pass-owned edge label')
        end

        def type!(type)
          require!(TYPES.include?(type), 'invalid constant-owned unit type')
        end

        def shape!(value, required, optional = [])
          require!(value.is_a?(Hash), 'invalid record shape')
          require!((required - value.keys).empty? && (value.keys - required - optional).empty?, 'invalid record keys')
        end

        def records!(value)
          require!(value.is_a?(Array) && value.size <= MAX_RECORDS, 'invalid candidate array or record limit')
          value
        end

        def bounded_count(count)
          require!(count <= MAX_RECORDS, 'candidate record limit exceeded')
          count
        end

        def nesting!(value)
          require!(value.is_a?(Array) && value.size <= MAX_NESTING, 'invalid lexical nesting')
          value.each { |name| constant!(name) }
        end

        def constant!(value, rooted: false)
          string!(value)
          valid = RuntimeLookup::CONSTANT.match?(value) && (rooted || !value.start_with?('::'))
          require!(valid, 'invalid constant name')
        end

        def path!(value)
          string!(value)
          segments = value.split('/', -1)
          valid = %w[app lib].include?(segments.first) && segments.size >= 2 && value.end_with?('.rb') &&
                  !value.include?('\\') && segments.none? { |part| part.empty? || %w[. ..].include?(part) }
          require!(valid, 'unsafe source path')
        end

        def string!(value)
          require!(value.is_a?(String) && value.valid_encoding? && !value.empty? &&
                   value.bytesize <= MAX_STRING_BYTES && !value.match?(/[\x00-\x1f\x7f]/), 'invalid evidence string')
        end

        def line!(value)
          require!(value.instance_of?(Integer) && value.between?(1, MAX_LINE), 'invalid source line')
        end

        def require!(condition, message)
          raise Invalid, "Invalid source reference cache: #{message}" unless condition
        end
      end
    end
  end
end
