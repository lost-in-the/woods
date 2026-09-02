# frozen_string_literal: true

require 'json'
require 'date'
require 'securerandom'
require 'time'
require 'fileutils'
require 'open3'
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
        class CorruptRecordError < StandardError; end
        class ProducerIdentityError < IOError; end

        # Subdirectory of the index directory holding one JSON file per task.
        DIRNAME = 'tasks'

        # How long a terminal record stays readable. Long enough that a client
        # which dropped mid-run can reconnect and still collect its result.
        DEFAULT_TTL_MS = 3_600_000 # 1 hour

        # Suggested client poll cadence. Extraction on a large host takes
        # minutes, so a tight poll buys nothing but load.
        DEFAULT_POLL_INTERVAL_MS = 2_000

        JSON_RPC_INTERNAL_ERROR = -32_603

        # How long a `working` record minted by a producer this reader cannot
        # judge (foreign boot id or pid namespace) is believed on age alone.
        #
        # The pid-table check is unusable across boots and namespaces, so the
        # only two readings of a foreign identity on the SAME store are "this
        # machine rebooted while a run was in flight" (the producer is dead by
        # construction) and "another machine is writing this index over a
        # shared filesystem" (it may still be running). Nothing on disk tells
        # them apart, so age decides: wider than any plausible extraction or
        # embed run, narrow enough that a rebooted host stops answering
        # `working` forever.
        FOREIGN_PRODUCER_GRACE_SECONDS = 86_400 # 24 hours

        # Terminal states: "once reached, the task's state does not change".
        TERMINAL = %w[completed failed cancelled].freeze
        STATUSES = (%w[working input_required] + TERMINAL).freeze

        # A task id is minted by {SecureRandom} and only ever compared against
        # this, so anything that could escape the directory is not a task id.
        SAFE_ID = /\A[a-f0-9]{32}\z/
        LINUX_PROCESS_STATE = /\A[RSDZTtXxKWPI]\z/
        LINUX_NUMERIC_FIELD = /\A-?\d+\z/
        private_constant :LINUX_PROCESS_STATE, :LINUX_NUMERIC_FIELD

        # One task record.
        Task = Struct.new(
          :id, :tool, :status, :created_at, :updated_at, :ttl_ms,
          :poll_interval_ms, :status_message, :result, :error, :pid,
          :producer_identity, :input_requests,
          keyword_init: true
        ) do
          def terminal?
            TERMINAL.include?(status)
          end

          # Wire shape for `CreateTaskResult` and `tasks/get`.
          #
          # @return [Hash]
          def to_h
            wire = {
              taskId: id,
              status: status,
              pollIntervalMs: poll_interval_ms,
              createdAt: created_at,
              lastUpdatedAt: updated_at,
              statusMessage: status_message,
              result: result,
              error: error,
              inputRequests: input_requests
            }.compact
            wire[:ttlMs] = ttl_ms
            wire
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
          producer_identity = producer_identity_for(Process.pid)
          raise ProducerIdentityError, 'Could not establish producer process identity.' unless producer_identity

          now = Time.now.utc.iso8601
          task = Task.new(
            id: SecureRandom.hex(16), tool: tool, status: 'working',
            created_at: now, updated_at: now, ttl_ms: ttl_ms,
            poll_interval_ms: poll_interval_ms, pid: Process.pid,
            producer_identity: producer_identity
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
          transition!(id, 'failed') do |t|
            t.error = {
              'code' => JSON_RPC_INTERNAL_ERROR,
              'message' => message.to_s
            }
          end
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
          raise CorruptRecordError, "Invalid task record #{id}: schema mismatch" unless valid_record?(data, id)

          Task.new(
            id: data['id'], tool: data['tool'], status: data['status'],
            created_at: data['created_at'], updated_at: data['updated_at'],
            ttl_ms: data['ttl_ms'], poll_interval_ms: data['poll_interval_ms'],
            status_message: data['status_message'], result: data['result'],
            error: data['error'], pid: data['pid'],
            producer_identity: data['producer_identity'], input_requests: data['input_requests']
          )
        rescue JSON::ParserError, SystemCallError, TypeError => e
          raise CorruptRecordError, "Invalid task record #{id}: #{e.class}"
        end

        # Persisted shape is the struct's own fields, not {Task#to_h} — that is
        # the wire shape, which drops `pid` and `tool` and renames the rest.
        def write(task)
          FileUtils.mkdir_p(@dir)
          Woods::AtomicFile.write(path_for(task.id), JSON.pretty_generate(task.to_h_record))
        end

        def valid_record?(data, expected_id)
          return false unless data.is_a?(Hash)
          return false unless data['id'] == expected_id && data['id'].match?(SAFE_ID)
          return false unless data['tool'].is_a?(String) && !data['tool'].empty?
          return false unless STATUSES.include?(data['status'])
          return false unless valid_time?(data['created_at']) && valid_time?(data['updated_at'])
          return false unless data['ttl_ms'].nil? ||
                              (data['ttl_ms'].is_a?(Integer) && data['ttl_ms'] >= 0)
          return false unless data['poll_interval_ms'].nil? ||
                              (data['poll_interval_ms'].is_a?(Integer) && data['poll_interval_ms'].positive?)
          return false unless data['status_message'].nil? || data['status_message'].is_a?(String)

          valid_status_fields?(data)
        end

        def valid_status_fields?(data)
          case data['status']
          when 'working'
            valid_producer?(data) && absent?(data, 'result', 'error', 'input_requests')
          when 'input_required'
            valid_producer?(data) && absent?(data, 'result', 'error') && valid_input_requests?(data['input_requests'])
          when 'completed'
            data['result'].is_a?(Hash) && absent?(data, 'error', 'input_requests')
          when 'failed'
            valid_error?(data['error']) && absent?(data, 'result', 'input_requests')
          when 'cancelled'
            absent?(data, 'result', 'error', 'input_requests')
          else
            false
          end
        end

        def valid_producer?(data)
          data['pid'].is_a?(Integer) && data['pid'].positive? &&
            data['producer_identity'].is_a?(String) && !data['producer_identity'].empty?
        end

        def valid_error?(error)
          error.is_a?(Hash) && error['code'].is_a?(Integer) &&
            error['message'].is_a?(String) && !error['message'].empty?
        end

        def valid_input_requests?(requests)
          requests.is_a?(Hash) && !requests.empty? && requests.values.all? do |request|
            request.is_a?(Hash) && request['method'].is_a?(String) && request['params'].is_a?(Hash)
          end
        end

        def absent?(data, *keys)
          keys.all? { |key| data[key].nil? }
        end

        def valid_time?(value)
          return false unless value.is_a?(String)

          Time.iso8601(value)
          true
        rescue ArgumentError
          false
        end

        # @return [Task, nil] the updated record, or nil when the transition was
        #   refused — returning the record rather than a bare boolean means a
        #   caller that wants the new state does not have to re-read it.
        def transition!(id, status, &block)
          with_task_lock(id) do
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
        end

        def with_task_lock(id)
          path = path_for(id)
          return nil unless path

          FileUtils.mkdir_p(@dir)
          File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |file|
            file.flock(File::LOCK_EX)
            yield
          end
        end

        # Only terminal records expire. An unfinished task must outlive its ttl
        # rather than vanish mid-run and strand a client that is still polling.
        #
        # Measured from `updated_at` — the terminal transition itself — not
        # `created_at`. A pipeline that runs longer than ttl_ms would otherwise
        # be born expired: `complete!` writes the terminal record at the run's
        # end, and if expiry counted from the start, the very next `tasks/get`
        # would report it unknown before the client ever saw the result.
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
          return task if producer_alive?(task)

          task.status = 'failed'
          task.error = {
            'code' => JSON_RPC_INTERNAL_ERROR,
            'message' => "The process running this task did not survive (pid #{task.pid}). " \
                         'Re-run the tool; the index is unchanged unless the run had already committed.'
          }
          task.updated_at = Time.now.utc.iso8601
          write(task)
          task
        end

        def producer_alive?(task)
          # A foreign-boot producer identity (e.g. a task minted inside a
          # container) can't be judged by this reader's own pid table at all —
          # `task.pid` names a slot in a namespace this process doesn't share,
          # so `process_alive?` would be checking an unrelated, possibly
          # reused, host pid. Leave those tasks alone rather than risk failing
          # one that is still running — but only within
          # FOREIGN_PRODUCER_GRACE_SECONDS, or a rebooted host answers
          # `working` forever for a run that died in the reboot.
          return foreign_producer_within_grace?(task) if foreign_producer?(task.producer_identity)

          process_alive?(task.pid) && producer_identity_for(task.pid) == task.producer_identity
        end

        # Age backstop for an unjudgeable producer, measured from
        # `updated_at` (the last sign of life this record carries) exactly as
        # {#expired?} measures terminal TTL. An unparseable timestamp keeps the
        # conservative answer.
        def foreign_producer_within_grace?(task)
          Time.now.utc - Time.parse(task.updated_at) <= FOREIGN_PRODUCER_GRACE_SECONDS
        rescue ArgumentError, TypeError
          true
        end

        # A producer this reader cannot judge by its own pid table: minted
        # under another kernel boot, or (ordinary Docker on Linux, which
        # shares the host boot id) inside another pid namespace. `task.pid`
        # then names a slot in a namespace this process does not share, so
        # `process_alive?` would be checking an unrelated, possibly reused,
        # host pid.
        def foreign_producer?(producer_identity)
          boot = producer_identity[/\Aboot=([^;]+)/, 1]
          return false unless boot
          return true if boot != current_boot_identity

          namespace = producer_identity[/;ns=([^;]+)/, 1]
          return false if namespace.nil? || current_pid_namespace.nil?

          namespace != current_pid_namespace
        end

        # @return [String, nil] this process's pid namespace token
        #   (`pid:[4026531836]`), nil where /proc has none (Darwin)
        def current_pid_namespace
          return @current_pid_namespace if defined?(@current_pid_namespace)

          @current_pid_namespace = pid_namespace_for('self')
        end

        def pid_namespace_for(pid)
          File.readlink("/proc/#{pid}/ns/pid")
        rescue SystemCallError
          nil
        end

        def current_boot_identity
          return @current_boot_identity if defined?(@current_boot_identity)

          @current_boot_identity = if File.readable?('/proc/sys/kernel/random/boot_id')
                                     boot_id = File.read('/proc/sys/kernel/random/boot_id').strip
                                     boot_id.empty? ? nil : boot_id
                                   else
                                     darwin_boot_identity
                                   end
        rescue SystemCallError
          @current_boot_identity = nil
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

        def producer_identity_for(pid)
          pid = Integer(pid)
          return linux_process_identity(pid) if File.readable?('/proc/sys/kernel/random/boot_id')

          darwin_process_identity(pid)
        rescue SystemCallError, ArgumentError, TypeError
          nil
        end

        def linux_process_identity(pid)
          boot_id = File.read('/proc/sys/kernel/random/boot_id').strip
          start_ticks = linux_start_ticks(File.read("/proc/#{pid}/stat"))
          return if boot_id.empty? || start_ticks.nil?

          namespace = pid_namespace_for(pid)
          namespace ? "boot=#{boot_id};ns=#{namespace};start_ticks=#{start_ticks}" : "boot=#{boot_id};start_ticks=#{start_ticks}"
        rescue Errno::ENOENT
          nil
        end

        def linux_start_ticks(stat)
          boundary = stat.rindex(') ')
          return unless boundary && stat.match?(/\A\d+ \(/)

          fields = stat[(boundary + 2)..].split
          return unless fields.length >= 20
          return unless fields.first.match?(LINUX_PROCESS_STATE)

          numeric_fields = fields[1, 19]
          return unless numeric_fields.all? { |field| field.match?(LINUX_NUMERIC_FIELD) }

          start_ticks = numeric_fields.last
          start_ticks if start_ticks.match?(/\A\d+\z/)
        end

        def darwin_process_identity(pid)
          environment = { 'LC_ALL' => 'C', 'LANG' => 'C', 'TZ' => 'UTC' }
          started, ps_status = Open3.capture2(environment, '/bin/ps', '-o', 'lstart=', '-p', pid.to_s)
          return unless ps_status.success?

          start_epoch = DateTime.strptime(started.strip, '%a %b %e %H:%M:%S %Y').to_time.to_i
          boot_identity = darwin_boot_identity
          return unless boot_identity

          "boot=#{boot_identity};start=#{start_epoch}"
        rescue Date::Error
          nil
        end

        def darwin_boot_identity
          return @darwin_boot_identity if defined?(@darwin_boot_identity)

          booted, status = Open3.capture2('/usr/sbin/sysctl', '-n', 'kern.boottime')
          return unless status.success?

          boot_match = booted.match(/sec = (\d+), usec = (\d+)/)
          return unless boot_match

          @darwin_boot_identity = "#{boot_match[1]}.#{boot_match[2]}"
        end

        def sweep_expired!
          return unless Dir.exist?(@dir)

          Dir.glob(File.join(@dir, '*.json')).each do |path|
            id = File.basename(path, '.json')
            task = read(id)
            next unless task.nil? || expired?(task)

            File.delete(path)
            FileUtils.rm_f("#{path}.lock")
          rescue SystemCallError
            # Another process swept it first; nothing to do.
            nil
          rescue CorruptRecordError
            # Not a race — a valid record does not spontaneously fail schema
            # validation. This is a record that will never parse (a version
            # upgrade changed the schema, a hand-edited file, a torn write
            # that never got a follow-up write). Left alone, sweep_expired!
            # re-parses and re-fails on it every time it runs, forever. Delete
            # it once it's old enough that a torn write from a concurrent
            # create!/write would have long since finished; a record younger
            # than the default TTL is left alone in case it's mid-write.
            next unless corrupt_record_expired?(path)

            File.delete(path)
            FileUtils.rm_f("#{path}.lock")
          end
        end

        # Is a corrupt record old enough to delete outright?
        #
        # {#expired?} can't be used here — it reads +task.created_at+ from a
        # successfully parsed {Task}, which is exactly what a corrupt record
        # doesn't have. File mtime is the next best signal: {#write} rewrites
        # the whole file on every transition, so mtime tracks "how long ago
        # this record was last touched", which is what distinguishes a
        # permanently broken record from a write still in flight.
        #
        # @param path [String] the corrupt record's file path
        # @return [Boolean]
        def corrupt_record_expired?(path)
          Time.now.utc - File.mtime(path).utc > (DEFAULT_TTL_MS / 1000.0)
        rescue SystemCallError
          false
        end
      end
    end
  end
end
