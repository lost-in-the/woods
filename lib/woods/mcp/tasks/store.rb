# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require 'fileutils'
require_relative '../../atomic_file'

module Woods
  module MCP
    # The MCP Tasks extension (`io.modelcontextprotocol/tasks`).
    #
    # Distinct from {Woods::Tasks}, which is the rake-helper namespace — this is
    # the protocol extension for long-running operations.
    module Tasks
      # Durable registry for long-running tool invocations.
      #
      # The whole point of a task over a bare background thread is that the
      # handle outlives the thing that created it: a client may disconnect,
      # restart, and resume polling, and it must get a real answer. So records
      # live on disk rather than in a process-local hash.
      #
      # **Why this does not take `PipelineLock`.** Every other writer against the
      # index directory serializes on that lock, because they rewrite one shared
      # artifact set (units + dependency graph + generation) where each write is
      # individually atomic but the *set* is not. Task records share nothing:
      # one file per task, written whole via {AtomicFile}, never read as a set
      # that must agree. Taking the lock here would also deadlock outright —
      # `pipeline_extract` holds it for the duration of the run, which is
      # exactly when its task record needs updating.
      class Store
        # Subdirectory of the index directory holding one JSON file per task.
        DIRNAME = 'tasks'

        # How long a terminal record stays readable. Long enough that a client
        # which dropped mid-run can reconnect and still collect its result.
        DEFAULT_TTL_MS = 3_600_000 # 1 hour

        # Suggested client poll cadence. Extraction on a large host takes
        # minutes, so a tight poll buys nothing but load.
        DEFAULT_POLL_INTERVAL_MS = 2_000

        # Terminal states: "once reached, the task's state does not change".
        TERMINAL = %w[completed failed cancelled].freeze

        # A task id is minted by {SecureRandom} and only ever compared against
        # this, so anything that could escape the directory is not a task id.
        SAFE_ID = /\A[a-f0-9]{32}\z/

        # One task record.
        Task = Struct.new(
          :id, :tool, :status, :created_at, :updated_at, :ttl_ms,
          :poll_interval_ms, :status_message, :result, :error, :pid,
          keyword_init: true
        ) do
          def terminal?
            TERMINAL.include?(status)
          end

          # Wire shape for `CreateTaskResult` and `tasks/get`.
          #
          # @return [Hash]
          def to_h
            {
              taskId: id,
              status: status,
              ttlMs: ttl_ms,
              pollIntervalMs: poll_interval_ms,
              createdAt: created_at,
              statusMessage: status_message,
              result: result,
              error: error
            }.compact
          end

          # On-disk shape: every field, snake_case, so a record round-trips
          # without the wire shape's renaming and omissions.
          #
          # @return [Hash]
          def to_h_record
            each_pair.to_h.compact
          end
        end

        # @param index_dir [String, Pathname] the Woods index directory
        def initialize(index_dir)
          @dir = File.join(index_dir.to_s, DIRNAME)
        end

        # Create and durably persist a new task.
        #
        # @param tool [String] the tool whose invocation this represents
        # @param ttl_ms [Integer]
        # @param poll_interval_ms [Integer]
        # @return [Task]
        def create!(tool:, ttl_ms: DEFAULT_TTL_MS, poll_interval_ms: DEFAULT_POLL_INTERVAL_MS)
          sweep_expired!
          now = Time.now.utc.iso8601
          task = Task.new(
            id: SecureRandom.hex(16), tool: tool, status: 'working',
            created_at: now, updated_at: now, ttl_ms: ttl_ms,
            poll_interval_ms: poll_interval_ms, pid: Process.pid
          )
          write(task)
          task
        end

        # Read a task, resolving expiry and crashed owners along the way.
        #
        # @param id [String]
        # @return [Task, nil] nil when unknown, expired, or unreadable
        def get(id)
          task = read(id)
          return nil unless task
          return nil if expired?(task)

          adopt_orphan(task)
        end

        # @param id [String]
        # @param result [Hash] what the synchronous call would have returned
        # @return [Task, nil] the updated record, or nil if it was already terminal
        def complete!(id, result:)
          transition!(id, 'completed') { |t| t.result = result }
        end

        # @param id [String]
        # @param message [String]
        # @return [Task, nil] the updated record, or nil if it was already terminal
        def fail!(id, message:)
          transition!(id, 'failed') { |t| t.error = { 'message' => message.to_s } }
        end

        # Cancellation is cooperative: this records the intent and the runner
        # stops when it next checks. The work may still finish first, in which
        # case the terminal-state guard keeps whichever landed first.
        #
        # @param id [String]
        # @return [Task, nil] the updated record, or nil if it was already terminal
        def cancel!(id)
          transition!(id, 'cancelled')
        end

        # Attach a progress message without leaving `working`.
        #
        # @param id [String]
        # @param message [String]
        # @return [Task, nil] the updated record, or nil if unknown/terminal
        def note_progress!(id, message)
          task = read(id)
          return nil if task.nil? || task.terminal?

          task.status_message = message.to_s
          task.updated_at = Time.now.utc.iso8601
          write(task)
          task
        end

        # Has a cancellation been recorded? Polled by a running task so
        # cancellation can be honoured between units of work.
        #
        # @param id [String]
        # @return [Boolean]
        def cancelled?(id)
          read(id)&.status == 'cancelled'
        end

        private

        def path_for(id)
          return nil unless id.is_a?(String) && id.match?(SAFE_ID)

          File.join(@dir, "#{id}.json")
        end

        def read(id)
          path = path_for(id)
          return nil unless path && File.exist?(path)

          data = JSON.parse(Woods::AtomicFile.read(path))
          Task.new(
            id: data['id'], tool: data['tool'], status: data['status'],
            created_at: data['created_at'], updated_at: data['updated_at'],
            ttl_ms: data['ttl_ms'], poll_interval_ms: data['poll_interval_ms'],
            status_message: data['status_message'], result: data['result'],
            error: data['error'], pid: data['pid']
          )
        rescue JSON::ParserError, SystemCallError
          # A torn or unreadable record is indistinguishable from an absent one
          # for every caller here, and raising would take down a tool call.
          nil
        end

        # Persisted shape is the struct's own fields, not {Task#to_h} — that is
        # the wire shape, which drops `pid` and `tool` and renames the rest.
        def write(task)
          FileUtils.mkdir_p(@dir)
          Woods::AtomicFile.write(path_for(task.id), JSON.pretty_generate(task.to_h_record))
        end

        # @return [Task, nil] the updated record, or nil when the transition was
        #   refused — returning the record rather than a bare boolean means a
        #   caller that wants the new state does not have to re-read it.
        def transition!(id, status, &block)
          task = read(id)
          return nil if task.nil?
          # Terminal is terminal: a thread that finishes after the client
          # cancelled must not overwrite the state the client already saw.
          return nil if task.terminal?

          task.status = status
          task.updated_at = Time.now.utc.iso8601
          block&.call(task)
          write(task)
          task
        end

        # Only terminal records expire. An unfinished task must outlive its ttl
        # rather than vanish mid-run and strand a client that is still polling.
        def expired?(task)
          return false unless task.terminal?
          return false if task.ttl_ms.nil?

          Time.now.utc - Time.parse(task.updated_at) > (task.ttl_ms / 1000.0)
        rescue ArgumentError, TypeError
          false
        end

        # A `working` record whose owning process is gone describes work that
        # cannot still be happening. Resolve it to `failed` and persist, so
        # every later reader gets the same answer instead of re-deciding.
        def adopt_orphan(task)
          return task unless task.status == 'working'
          return task if task.pid && process_alive?(task.pid)

          task.status = 'failed'
          task.error = {
            'message' => "The process running this task did not survive (pid #{task.pid}). " \
                         'Re-run the tool; the index is unchanged unless the run had already committed.'
          }
          task.updated_at = Time.now.utc.iso8601
          write(task)
          task
        end

        def process_alive?(pid)
          Process.kill(0, Integer(pid))
          true
        rescue Errno::EPERM
          # The process exists, it just belongs to another user. Alive.
          true
        rescue Errno::ESRCH, ArgumentError, TypeError
          false
        end

        def sweep_expired!
          return unless Dir.exist?(@dir)

          Dir.glob(File.join(@dir, '*.json')).each do |path|
            id = File.basename(path, '.json')
            task = read(id)
            File.delete(path) if task.nil? || expired?(task)
          rescue SystemCallError
            # Another process swept it first; nothing to do.
            nil
          end
        end
      end
    end
  end
end
