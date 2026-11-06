# frozen_string_literal: true

require 'woods/extractor'

module Woods
  module Experimental
    # Branch-only, explicitly enabled performance pilot. No index format changes.
    module IncrementalReuse
      SOURCE_ROOT = File.expand_path('..', __dir__).freeze
      CONTEXT_KEY = :woods_experimental_incremental_reuse
      @state_mutex = Mutex.new
      @pid = Process.pid
      @mutex = Mutex.new
      Context = Struct.new(:extractor, :session, :pending_graph, :published_marker, :incremental, keyword_init: true) do
        def graph?
          %i[combined graph].include?(session.mode)
        end
      end

      class Session
        attr_accessor :graph, :marker
        attr_reader :mode, :templates, :counts

        def initialize(mode, marker)
          @mode = mode
          @marker = marker
          @templates = TemplateFacts::Cache.new
          @counts = Hash.new(0)
          @graph = nil
        end

        def stats
          { mode: mode, generation: marker&.first, counts: counts.dup,
            templates: { counts: templates.counts.dup, entries: templates.entries.size, bytes: templates.bytes } }
        end
      end

      class << self
        def mode
          case ENV.fetch('WOODS_EXPERIMENTAL_INCREMENTAL_REUSE', nil)
          when nil, '', '0', 'off' then nil
          when '1', 'combined' then :combined
          when 'graph' then :graph
          when 'templates' then :templates
          else
            raise ArgumentError, 'WOODS_EXPERIMENTAL_INCREMENTAL_REUSE must be 0, combined, graph, or templates'
          end
        end

        def current
          process_state!
          Thread.current.thread_variable_get(CONTEXT_KEY)
        end

        def template_cache
          context = current
          context.session.templates if context && %i[combined templates].include?(context.session.mode)
        end

        def run(extractor)
          selected = mode
          return yield(nil) unless selected && Woods.configuration&.concurrent_extraction == false

          process_state!
          raise Woods::ExtractionError, 'Experimental reuse does not support nested extraction' if current

          @mutex.synchronize do
            select_session(extractor, selected)
            context = Context.new(extractor: extractor, session: @session, incremental: false)
            successful = false
            Thread.current.thread_variable_set(CONTEXT_KEY, context)
            begin
              result = yield(context)
              successful = extractor.instance_variable_get(:@publication_error).nil?
              result
            ensure
              Thread.current.thread_variable_set(CONTEXT_KEY, nil)
              finish(context, successful)
            end
          end
        end

        def stats
          return current.session.stats if current

          process_state!
          @mutex.synchronize { @session ? @session.stats : { mode: mode, generation: nil, counts: {}, templates: {} } }
        end

        def reset!
          process_state!
          raise Woods::ExtractionError, 'Reset experimental reuse between operations' if current

          @mutex.synchronize { @session = @key = nil }
        end

        private

        def select_session(extractor, selected)
          key = [File.realpath(Rails.root), canonical_output(extractor.output_dir)]
          before = marker_for(extractor)
          return if @session && @key == key && @session.mode == selected && @session.marker == before

          @key = key
          @session = Session.new(selected, before)
        end

        def process_state!
          return if @pid == Process.pid

          @state_mutex.synchronize do
            return if @pid == Process.pid

            @mutex = Mutex.new
            @session = @key = nil
            Thread.current.thread_variable_set(CONTEXT_KEY, nil)
            @pid = Process.pid
          end
        end

        def canonical_output(path)
          File.exist?(path) ? File.realpath(path) : File.expand_path(path)
        end

        def marker_for(extractor)
          marker = Generation.new(output_dir: extractor.output_dir).current
          [marker.number, marker.token, marker.payload]
        end

        def finish(context, successful)
          after = marker_for(context.extractor)
          if successful && context.published_marker == after
            context.session.graph = context.pending_graph
            context.session.marker = after
          elsif !successful || after != context.session.marker
            @session = @key = nil
          end
        rescue StandardError
          # Optional cache bookkeeping must never replace an application error.
          @session = @key = nil
        end
      end
    end
  end
end

require_relative 'template_facts'
require_relative 'graph_state'
require_relative 'reuse_hooks'

Woods::Extractor.prepend(Woods::Experimental::IncrementalReuse::ExtractorHook)
Woods::Experimental::IncrementalReuse::TemplateFacts.install!
