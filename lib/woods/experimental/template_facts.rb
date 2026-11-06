# frozen_string_literal: true

# Opt-in client pilot; cached source facts never leave process memory.
require 'digest'
require 'woods/extractors/view_template_extractor'
module Woods
  module Experimental
    module IncrementalReuse
      module TemplateFacts
        EngineRef = Struct.new(:name)
        QUERIES = %i[resolve_partial rendered_template view_owner resolve_navigation_candidates
                     navigation_references].freeze
        def self.active_cache
          IncrementalReuse.template_cache
        end

        def self.normal(value)
          case value
          when Class, Module then [value.name, value.object_id]
          when Hash then value.to_h { |k, v| [normal(k), normal(v)] }
          when Array then value.map { |v| normal(v) }
          else value
          end
        end

        class Cache
          attr_reader :counts, :bytes, :entries

          def initialize(max_entries: 10_000, max_bytes: 64 * 1024 * 1024)
            @max_entries = max_entries
            @max_bytes = max_bytes
            @entries = {}
            @bytes = 0
            @counts = Hash.new(0)
          end

          def prepare_inventory?(extractor)
            dirs = extractor.instance_variable_get(:@directories)
            engines = extractor.instance_variable_get(:@engines)
            return false unless supported_engines?(engines)

            files = template_files(dirs, engines)
            code = implementation_files.map { |path| [path, Digest::SHA256.file(path).hexdigest] }
            key = Marshal.dump([dirs.map(&:to_s), files, engines.map { |e| e.class.name }, code])
            if @inventory && @inventory != key
              @entries.clear
              @bytes = 0
              @counts[:inventory_invalidations] += 1
            end
            @inventory = key
            true
          end

          def template_files(dirs, engines)
            extensions = engines.flat_map(&:extensions).uniq
            dirs.flat_map { |dir| extensions.flat_map { |ext| Dir[dir.join("**/*#{ext}")] } }.uniq.sort
          end

          def supported_engines?(engines)
            supported = [Woods::Extractors::ViewEngines::Erb, Woods::Extractors::ViewEngines::Haml,
                         Woods::Extractors::ViewEngines::Jbuilder]
            engines.all? { |engine| supported.include?(engine.class) }
          end

          def implementation_files
            Dir[File.join(IncrementalReuse::SOURCE_ROOT,
                          'extractors/{view_template_extractor,route_helper_resolver,' \
                          'comment_blanking,view_engines/*}.rb')] +
              [__FILE__]
          end

          def fetch(path)
            blob = @entries[path]
            # Blobs are created only by put in this process, never read from disk or callers.
            Marshal.load(blob) if blob # rubocop:disable Security/MarshalLoad
          end

          def put(path, value)
            blob = Marshal.dump(value)
            old = @entries[path]&.bytesize.to_i
            if (!@entries.key?(path) && @entries.size >= @max_entries) || @bytes - old + blob.bytesize > @max_bytes
              @counts[:bounded_refusals] += 1
              return
            end
            @entries[path] = blob
            @bytes += blob.bytesize - old
            @counts[:stored] += 1
          end
        end

        module Hook
          def initialize(...)
            super
            @reuse_cache = TemplateFacts.active_cache
            begin
              @reuse_cache = nil unless @reuse_cache&.prepare_inventory?(self)
            rescue StandardError
              @reuse_cache.counts[:probe_errors] += 1
              @reuse_cache = nil
            end
          end

          # Keep the original per-file failure boundaries while replaying raw facts.
          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          def extract_view_template_file(path, pending: nil)
            return super unless pending && @reuse_cache

            key = File.expand_path(path.to_s)
            entry = nil
            begin
              entry = @reuse_cache.fetch(key)
            rescue StandardError
              @reuse_cache.counts[:probe_errors] += 1
            end
            valid = false
            if entry
              begin
                valid = entry[:source] == Woods::SourceFile.read(path)
                valid &&= entry[:queries].all? do |name, args, expected|
                  @reuse_cache.counts[:query_validations] += 1
                  current = send(name, *reuse_unpack(args))
                  TemplateFacts.normal(current) == expected
                end
              rescue StandardError => e
                # These are actual application inputs, not optional cache probes.
                # Preserve the original per-file failure path; never retry it away.
                Woods::SourceInputs::ConsumerErrors.log(self, "Failed to extract view template #{path}: #{e.message}")
                return nil
              end
            end
            if valid
              @reuse_cache.counts[:hits] += 1
              # Owned in-memory blobs captured below; no serialized external input is accepted.
              unit = Marshal.load(entry[:unit]) # rubocop:disable Security/MarshalLoad
              items = Marshal.load(entry[:pending]) # rubocop:disable Security/MarshalLoad
              pending[unit.identifier] = items if items
              begin
                engine = engine_for(path)
                apply_helper_calls(unit, engine, unit.source_code, unit.namespace)
                return apply_frontend_references(unit, unit.source_code)
              rescue StandardError => e
                Woods::SourceInputs::ConsumerErrors.log(self, "Failed to extract view template #{path}: #{e.message}")
                return nil
              end
            end
            @reuse_cache.counts[:misses] += 1
            @reuse_recording = true
            @reuse_queries = []
            @reuse_pending = pending
            @reuse_capture = nil
            unit = super
            begin
              @reuse_cache.put(key, @reuse_capture) if unit && @reuse_capture
            rescue StandardError
              @reuse_cache.counts[:probe_errors] += 1
            end
            unit
          ensure
            @reuse_recording = false
            @reuse_queries = @reuse_pending = @reuse_capture = nil
          end

          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

          private

          def reuse_pack(args)
            args.map { |v| v.is_a?(Woods::Extractors::ViewEngines::Base) ? EngineRef.new(v.class.name) : v }
          end

          def reuse_unpack(args)
            args.map do |value|
              next value unless value.is_a?(EngineRef)

              # Match the recorded class name, not the EngineRef object as a Class.
              @engines.find { |engine| engine.class.to_s == value.name } # rubocop:disable Style/ClassEqualityComparison
            end
          end

          def apply_helper_calls(unit, engine, source, namespace)
            if @reuse_recording
              begin
                @reuse_capture = { source: source, unit: Marshal.dump(unit),
                                   pending: Marshal.dump(@reuse_pending[unit.identifier]), queries: @reuse_queries }
              rescue StandardError
                @reuse_cache.counts[:probe_errors] += 1
              end
              @reuse_recording = false
            end
            super
          end
          QUERIES.each do |name|
            define_method(name) do |*args|
              record = @reuse_recording && !@reuse_query_depth
              return super(*args) unless record

              @reuse_query_depth = true
              begin
                value = super(*args)
                @reuse_queries << [name, reuse_pack(args), TemplateFacts.normal(value)]
                value
              ensure
                @reuse_query_depth = false
              end
            end
          end
        end

        def self.install!
          Woods::Extractors::ViewTemplateExtractor.prepend(Hook) unless Woods::Extractors::ViewTemplateExtractor < Hook
        end
      end
    end
  end
end
