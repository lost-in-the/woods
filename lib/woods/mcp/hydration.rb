# frozen_string_literal: true

require 'time'

module Woods
  module MCP
    # Cache warm-up for a built Index MCP server, run off the request path.
    #
    # {Server.build} used to call `launch_reader.warmup!` and
    # `retriever.warmup!` before returning, so the transport could not answer
    # the MCP `initialize` handshake until every cache was populated. On an
    # index of ~11,000 units that is 9-13 seconds (the lexical corpus reads
    # every unit file), and a client that probes the server with a short
    # handshake timeout (Claude Code's version-negotiation probe gives up at
    # 5 seconds) records the server as rejecting `initialize` and connects
    # only on a later pass, after the agent has planned its first turn
    # without Woods.
    #
    # The work now runs on one background thread. It is armed by the first
    # successful `initialize` ({Dispatch#init}), and on stdio it starts only
    # after that response has been written and flushed
    # ({StdioTransport#send_response}), so the handshake never competes with
    # JSON parsing for the GVL. A client that skips the legacy handshake
    # (modern `server/discover`) starts it with its first tool call instead.
    #
    # **A tool call during warm-up is correct, not fast.** {Dispatch#call_tool}
    # waits for the warm-up to finish, up to {#wait_cap} seconds (default
    # {DEFAULT_WAIT_CAP}, `WOODS_MCP_HYDRATION_WAIT_SECONDS` overrides), and
    # then dispatches. After a failed warm-up the call answers from the cold
    # reader. Past the cap it is dispatched with {.past_cap?} set, and the
    # cap then bounds the whole call, not only the condition-variable wait:
    #
    # - Every reader-backed tool answers from the cold reader. Reader
    #   accessors are lazy and memoized, so the result is the same, only
    #   slower; the warm-up takes no reader lock a call needs for longer than
    #   one cache update, and its generation pins yield to a waiting reload or
    #   refresh ({IndexReader#yielding_to_drains}) instead of queueing every
    #   later call behind that waiter.
    # - `codebase_retrieve` in lexical mode needs the whole corpus, which is
    #   what the warm-up is building under the retriever's snapshot mutex. A
    #   cold answer would be a second full build of the same corpus, as slow
    #   as the warm-up and doubling its memory, so the call answers
    #   {Warming} instead: a structured, retryable, non-error result with no
    #   partial sources. A retry waits for the warm-up again, up to the cap.
    #
    # Nothing is ever answered from a partially built cache: the reader's own
    # locks (the generation pin, the cache mutex, the retriever's snapshot
    # mutex) order the two threads.
    #
    # An exception in the warm-up is captured into the `failed` state and
    # reported by `woods_status` under `hydration`; the server keeps serving.
    #
    # States:
    # - `pending`: built, not yet started (no handshake, no tool call yet)
    # - `warming`: the thread is running
    # - `ready`: warm-up finished (also the state of `warmup: false`, where
    #   there is nothing to warm, and of `:before_handshake` after a
    #   successful synchronous run)
    # - `failed`: the warm-up raised; {#error} carries the exception
    class Hydration
      STATES = %i[pending warming ready failed].freeze
      MODES = %i[after_handshake before_handshake none].freeze

      # Longest a tool call waits for an in-flight warm-up before answering
      # from the cold reader. Generous against the measured 9-13 s on a large
      # index, and well inside any MCP client's tool-call timeout.
      DEFAULT_WAIT_CAP = 30.0

      WAIT_CAP_ENV = 'WOODS_MCP_HYDRATION_WAIT_SECONDS'

      # Raised by a cache that cannot answer a {.past_cap?} call without
      # waiting on the warm-up (the lexical corpus); the tool answers it as a
      # retryable `warming` result, never as an error.
      class Warming < StandardError; end

      PAST_CAP_KEY = :woods_hydration_past_cap
      private_constant :PAST_CAP_KEY

      class << self
        # @return [Boolean] true while this thread answers a call whose
        #   hydration wait expired with the warm-up still running
        def past_cap?
          Thread.current[PAST_CAP_KEY] == true
        end

        # @yield the dispatch to run with {.past_cap?} set
        # @return [Object] the block's value
        def answering_past_cap
          previous = Thread.current[PAST_CAP_KEY]
          Thread.current[PAST_CAP_KEY] = true
          yield
        ensure
          Thread.current[PAST_CAP_KEY] = previous
        end
      end

      # Tools that answer during warm-up without waiting for it.
      # `woods_status` reports the warm-up state, so it must not block on it;
      # `reload` serializes on the reader's exclusive lock, and the warm-up
      # yields its generation pins to that lock instead of making it wait.
      NON_WAITING_TOOL_NAMES = %w[woods_status reload].freeze

      # @return [Symbol] one of {MODES}
      attr_reader :mode

      # @return [Exception, nil] what the warm-up raised, when `failed`
      attr_reader :error

      # @return [Time, nil]
      attr_reader :started_at, :finished_at

      # @param mode [Symbol] one of {MODES}
      # @param wait_cap [Float, nil] seconds a tool call waits; nil reads the
      #   environment, falling back to {DEFAULT_WAIT_CAP}
      # @yield the warm-up work; runs at most once
      def initialize(mode:, wait_cap: nil, &work)
        raise ArgumentError, "unknown hydration mode #{mode.inspect}" unless MODES.include?(mode)

        @mode = mode
        @work = work
        @wait_cap = wait_cap
        @mutex = Mutex.new
        @done = ConditionVariable.new
        @state = mode == :none ? :ready : :pending
        @armed = false
        @deferred = false
        @thread = nil
        @error = nil
        @started_at = nil
        @finished_at = nil
      end

      # @return [Symbol] one of {STATES}
      def state
        @mutex.synchronize { @state }
      end

      # @return [Boolean] true once the warm-up has finished, either way
      def done?
        @mutex.synchronize { finished? }
      end

      # @return [Float] seconds a tool call waits for an in-flight warm-up
      def wait_cap
        @wait_cap ||= begin
          raw = ENV.fetch(WAIT_CAP_ENV, '').to_s.strip
          value = raw.empty? ? DEFAULT_WAIT_CAP : Float(raw, exception: false)
          value&.positive? ? value : DEFAULT_WAIT_CAP
        end
      end

      # Record that the handshake has been answered. Starts the warm-up unless
      # a transport asked to start it itself once the response is on the
      # wire ({#defer_start_to_transport!}).
      #
      # @return [void]
      def handshake_answered!
        deferred = @mutex.synchronize do
          @armed = true
          @deferred
        end
        start! unless deferred
      end

      # The stdio transport writes responses itself, after the handler
      # returns; it calls this so {#handshake_answered!} only arms, and then
      # {#start_if_armed!} after the response is flushed.
      #
      # @return [void]
      def defer_start_to_transport!
        @mutex.synchronize { @deferred = true }
      end

      # @return [void]
      def start_if_armed!
        start! if @mutex.synchronize { @armed }
      end

      # Start the warm-up on a background thread. Idempotent: only a `pending`
      # hydration starts, every later call returns at once.
      #
      # @return [void]
      def start!
        @mutex.synchronize do
          return unless @state == :pending

          @state = :warming
          @started_at = Time.now
          @thread = Thread.new { run_work }
          @thread.name = 'woods-hydration'
          @thread.report_on_exception = false
        end
      end

      # Run the warm-up on the calling thread (`warmup: :before_handshake`).
      # Unlike {#start!}, an exception propagates to the caller after being
      # recorded, which is the behaviour the synchronous build always had.
      #
      # @return [void]
      # @raise [Exception] whatever the warm-up raised
      def run!
        @mutex.synchronize do
          return unless @state == :pending

          @state = :warming
          @started_at = Time.now
        end
        run_work
        raise @error if @error
      end

      # Wait for an in-flight warm-up, starting it when nothing has yet.
      #
      # @param timeout [Float] seconds; defaults to {#wait_cap}
      # @return [Symbol] the state after waiting: `ready`, `failed`, or still
      #   `warming` when the timeout elapsed first
      def wait(timeout: wait_cap)
        start!
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @mutex.synchronize do
          until finished?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @done.wait(@mutex, remaining)
          end
          @state
        end
      end

      # The `hydration` section of `woods_status`.
      #
      # @return [Hash]
      def to_h
        @mutex.synchronize do
          duration = @started_at && ((@finished_at || Time.now) - @started_at)
          {
            state: @state.to_s,
            warmup: @mode.to_s,
            started_at: @started_at&.utc&.iso8601(3),
            finished_at: @finished_at&.utc&.iso8601(3),
            duration_seconds: duration&.round(3),
            error: @error && { class: @error.class.name, message: @error.message }
          }
        end
      end

      # Prepended onto a built server's singleton class. Arms the warm-up on
      # the legacy handshake and gates tool calls and resource reads on it.
      module Dispatch
        # @return [Hydration]
        def woods_hydration
          @woods_hydration
        end

        private

        def init(params, session: nil)
          result = super
          @woods_hydration&.handshake_answered!
          result
        end

        def call_tool(request, **)
          hydration = @woods_hydration
          if hydration
            if Hydration::NON_WAITING_TOOL_NAMES.include?(request[:name])
              # The status tool is "call this first on cold connect"; a client
              # that never sent `initialize` still gets its warm-up started.
              hydration.start!
            elsif hydration.wait == :warming
              return Hydration.answering_past_cap { super }
            end
          end
          super
        end

        def read_resource_contents(request, **)
          return Hydration.answering_past_cap { super } if @woods_hydration&.wait == :warming

          super
        end
      end

      private

      # Callers hold `@mutex`.
      def finished?
        @state == :ready || @state == :failed
      end

      def run_work
        @work&.call
        finish(:ready, nil)
      rescue StandardError, ScriptError => e
        finish(:failed, e)
      rescue Exception => e # rubocop:disable Lint/RescueException -- record the terminal state, then let the thread die with it
        # Neither a StandardError nor a ScriptError (NoMemoryError,
        # SystemStackError, a signal, a custom Exception subclass): the
        # thread dies with it either way, but left unrecorded the state stayed
        # `warming` and every waiting call and woods_status never saw `failed`.
        finish(:failed, e)
        raise
      end

      def finish(state, error)
        @mutex.synchronize do
          @state = state
          @error = error
          @finished_at = Time.now
          @done.broadcast
        end
      end
    end
  end
end
