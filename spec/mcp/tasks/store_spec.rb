# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/mcp/tasks/store'

RSpec.describe Woods::MCP::Tasks::Store do
  around do |example|
    Dir.mktmpdir { |dir| @index_dir = dir and example.run }
  end

  let(:store) { described_class.new(@index_dir) }

  describe '#create!' do
    subject(:task) { store.create!(tool: 'pipeline_extract') }

    it 'returns a task in the working state' do
      expect(task.status).to eq('working')
    end

    it 'mints a unique id' do
      expect(task.id).not_to eq(store.create!(tool: 'pipeline_extract').id)
    end

    it 'records the originating tool' do
      expect(task.tool).to eq('pipeline_extract')
    end

    it 'records the owning process so a crash can be detected later' do
      expect(task.pid).to eq(Process.pid)
    end

    it 'records a durable identity for the owning process' do
      expect(task.producer_identity).to be_a(String)
      expect(task.producer_identity).not_to be_empty
    end

    it 'establishes the same absolute identity with an empty PATH and changed TZ' do
      original_path = ENV.fetch('PATH', nil)
      original_tz = ENV.fetch('TZ', nil)
      first = store.send(:producer_identity_for, Process.pid)
      ENV['PATH'] = ''
      ENV['TZ'] = 'Pacific/Honolulu'

      expect(store.send(:producer_identity_for, Process.pid)).to eq(first)
      expect(store.create!(tool: 'pipeline_extract').producer_identity).to eq(first)
    ensure
      ENV['PATH'] = original_path
      ENV['TZ'] = original_tz
    end

    it 'fails before persistence when the OS identity cannot be established' do
      allow(store).to receive(:producer_identity_for).and_return(nil)
      allow(SecureRandom).to receive(:hex)

      expect { store.create!(tool: 'pipeline_extract') }
        .to raise_error(described_class::ProducerIdentityError)
      expect(SecureRandom).not_to have_received(:hex)
      expect(Dir.glob(File.join(@index_dir, described_class::DIRNAME, '*.json'))).to be_empty
    end

    # "The task must be durably created before sending the response" — otherwise
    # a client can receive a taskId the server has no record of.
    it 'persists the task before returning' do
      expect(File.exist?(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json"))).to be true
    end

    it 'writes nothing outside its own subdirectory' do
      task
      expect(Dir.children(@index_dir)).to contain_exactly(described_class::DIRNAME)
    end
  end

  describe 'producer identity' do
    def linux_stat(comm:, state: 'S', numeric_fields: (4..21).map(&:to_s), start_ticks: '987654')
      stat_fields = [state] + numeric_fields
      "123 (#{comm}) #{(stat_fields + [start_ticks, '23']).join(' ')}"
    end

    it 'parses Linux starttime structurally after a comm containing spaces and a closing parenthesis' do
      stat = linux_stat(comm: 'worker ) queue')

      expect(store.send(:linux_start_ticks, stat)).to eq('987654')
    end

    it 'rejects an invalid or multi-character Linux process state' do
      malformed = ['?', 'SS'].map { |state| linux_stat(comm: 'worker', state: state) }

      expect(malformed.map { |stat| store.send(:linux_start_ticks, stat) }).to eq([nil, nil])
    end

    it 'rejects a nonnumeric intermediate field before starttime' do
      fields = (4..21).map(&:to_s)
      fields[7] = 'not-numeric'

      expect(store.send(:linux_start_ticks, linux_stat(comm: 'worker', numeric_fields: fields))).to be_nil
    end

    it 'rejects a record truncated before field 22' do
      stat = "123 (worker) S #{(4..21).to_a.join(' ')}"

      expect(store.send(:linux_start_ticks, stat)).to be_nil
    end

    it 'rejects a negative or nonnumeric starttime' do
      malformed = %w[-1 not-an-integer].map { |start| linux_stat(comm: 'worker', start_ticks: start) }

      expect(malformed.map { |stat| store.send(:linux_start_ticks, stat) }).to eq([nil, nil])
    end

    it 'rejects content without a valid pid and parenthesized comm boundary' do
      malformed = ['123 worker S 1 2 3', 'pid (worker) S 1 2 3']

      expect(malformed.map { |stat| store.send(:linux_start_ticks, stat) }).to eq([nil, nil])
    end

    it 'reads the actual current Linux process identity when procfs is available' do
      skip 'procfs is unavailable on this platform' unless File.readable?('/proc/sys/kernel/random/boot_id')

      identity = store.send(:producer_identity_for, Process.pid)

      expect(identity).to match(/\Aboot=[^;]+;(?:ns=pid:\[\d+\];)?start_ticks=\d+\z/)
    end

    it 'caches the invariant Darwin boot identity across repeated process checks' do
      success = instance_double(Process::Status, success?: true)
      sysctl_calls = 0
      allow(Open3).to receive(:capture2) do |*arguments|
        if arguments.first == '/usr/sbin/sysctl'
          sysctl_calls += 1
          ["{ sec = 1700000000, usec = 123456 } Thu Jan  1 00:00:00 1970\n", success]
        else
          ["Thu Aug 20 03:00:00 2026\n", success]
        end
      end

      first = store.send(:darwin_process_identity, Process.pid)
      second = store.send(:darwin_process_identity, Process.pid)

      expect(second).to eq(first)
      expect(sysctl_calls).to eq(1)
      expect(Open3).to have_received(:capture2)
        .with({ 'LC_ALL' => 'C', 'LANG' => 'C', 'TZ' => 'UTC' }, '/bin/ps', '-o', 'lstart=', '-p', Process.pid.to_s)
        .twice
    end
  end

  describe '#get' do
    it 'round-trips a task through disk' do
      created = store.create!(tool: 'pipeline_embed')
      reloaded = described_class.new(@index_dir).get(created.id)

      expect(reloaded.id).to eq(created.id)
      expect(reloaded.tool).to eq('pipeline_embed')
      expect(reloaded.status).to eq('working')
    end

    it 'returns nil for an unknown id' do
      expect(store.get('nope')).to be_nil
    end

    # Task ids reach the store from client input, so the lookup must not be
    # able to address anything outside the task directory.
    it 'refuses to traverse out of the task directory' do
      expect(store.get('../../etc/passwd')).to be_nil
    end

    it 'refuses an id containing a separator' do
      expect(store.get('a/b')).to be_nil
    end

    it 'raises a stable error for malformed JSON' do
      task = store.create!(tool: 'pipeline_extract')
      File.write(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json"), 'not json{')

      expect { store.get(task.id) }.to raise_error(described_class::CorruptRecordError, /Invalid task record/)
    end

    it 'raises a stable error for records missing required fields' do
      task = store.create!(tool: 'pipeline_extract')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      File.write(path, JSON.generate('id' => task.id))

      expect { store.get(task.id) }.to raise_error(described_class::CorruptRecordError, /Invalid task record/)
    end

    it 'returns nil when a record has malformed timestamps' do
      task = store.create!(tool: 'pipeline_extract')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path))
      raw['created_at'] = 'not-a-timestamp'
      File.write(path, JSON.generate(raw))

      expect { store.get(task.id) }.to raise_error(described_class::CorruptRecordError, /Invalid task record/)
    end

    it 'returns nil when a record timestamp is not a string' do
      task = store.create!(tool: 'pipeline_extract')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path))
      raw['created_at'] = 123
      File.write(path, JSON.generate(raw))

      expect { store.get(task.id) }.to raise_error(described_class::CorruptRecordError, /Invalid task record/)
    end

    it 'rejects records whose status contradicts official task fields' do
      invalid = {
        'working' => { 'result' => {} },
        'completed' => { 'result' => nil },
        'failed' => { 'error' => 'boom' },
        'input_required' => { 'input_requests' => [] },
        'cancelled' => { 'result' => {} }
      }

      invalid.each do |status, changes|
        task = store.create!(tool: 'pipeline_extract')
        path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
        record = JSON.parse(File.read(path)).merge('status' => status).merge(changes)
        File.write(path, JSON.generate(record))

        expect { store.get(task.id) }.to raise_error(described_class::CorruptRecordError, /Invalid task record/)
      end
    end

    it 'accepts official completed, failed, and input_required field shapes' do
      shapes = {
        'completed' => { 'result' => { 'content' => [] } },
        'failed' => { 'error' => { 'code' => -32_603, 'message' => 'failed' } },
        'input_required' => {
          'input_requests' => {
            'approval' => { 'method' => 'elicitation/create', 'params' => { 'message' => 'Approve?' } }
          }
        }
      }

      shapes.each do |status, changes|
        task = store.create!(tool: 'pipeline_extract')
        path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
        record = JSON.parse(File.read(path)).merge('status' => status).merge(changes)
        File.write(path, JSON.generate(record))

        expect(store.get(task.id).status).to eq(status)
      end
    end
  end

  describe 'terminal transitions' do
    let(:task) { store.create!(tool: 'pipeline_extract') }

    it 'records a completed result' do
      store.complete!(task.id, result: { 'content' => [{ 'type' => 'text', 'text' => 'done' }] })
      reloaded = store.get(task.id)

      expect(reloaded.status).to eq('completed')
      expect(reloaded.result.dig('content', 0, 'text')).to eq('done')
    end

    it 'records a failure with its message' do
      store.fail!(task.id, message: 'boom')
      expect(store.get(task.id).error['message']).to eq('boom')
    end

    it 'records a JSON-RPC error code for failures' do
      store.fail!(task.id, message: 'boom')
      expect(store.get(task.id).error['code']).to eq(described_class::JSON_RPC_INTERNAL_ERROR)
    end

    it 'marks a failure as failed' do
      store.fail!(task.id, message: 'boom')
      expect(store.get(task.id).status).to eq('failed')
    end

    # Terminal states never regress after a late producer update.
    it 'refuses to move a task out of a terminal state' do
      store.complete!(task.id, result: { 'ok' => true })
      store.fail!(task.id, message: 'too late')

      expect(store.get(task.id).status).to eq('completed')
    end

    # Returning the record rather than a bare boolean means a caller that wants
    # the new state does not have to re-read it.
    it 'returns the updated record when the transition applies' do
      expect(store.complete!(task.id, result: {})).to have_attributes(status: 'completed')
    end

    it 'returns nil when the transition is refused' do
      store.complete!(task.id, result: {})
      expect(store.fail!(task.id, message: 'late')).to be_nil
    end
  end

  # The crash-resilience claim. Today a pipeline_extract thread dies with its
  # process and the agent is left polling a run that no longer exists; a task
  # whose owner is gone must resolve to a terminal state instead of `working`
  # forever.
  describe 'orphan detection' do
    let(:task) { store.create!(tool: 'pipeline_extract') }

    before do
      raw = JSON.parse(File.read(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")))
      raw['pid'] = 2**30 # a pid that cannot be running
      File.write(File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json"), JSON.generate(raw))
    end

    it 'reports a working task whose process is gone as failed' do
      expect(store.get(task.id).status).to eq('failed')
    end

    it 'uses stable JSON-RPC error metadata when the producer process died' do
      expect(store.get(task.id).error).to include('code' => described_class::JSON_RPC_INTERNAL_ERROR)
    end

    it 'explains why it failed' do
      expect(store.get(task.id).error['message']).to match(/did not survive/i)
    end

    it 'persists the transition so the answer is stable across readers' do
      store.get(task.id)
      expect(described_class.new(@index_dir).get(task.id).status).to eq('failed')
    end

    it 'leaves a task owned by a live process alone' do
      live = store.create!(tool: 'pipeline_embed')
      expect(store.get(live.id).status).to eq('working')
    end

    # A task that already finished carries no live pid and must not be
    # retroactively reinterpreted as a crash.
    it 'does not touch an already-terminal task' do
      done = store.create!(tool: 'pipeline_embed')
      store.complete!(done.id, result: {})
      path = File.join(@index_dir, described_class::DIRNAME, "#{done.id}.json")
      raw = JSON.parse(File.read(path))
      raw['pid'] = 2**30
      File.write(path, JSON.generate(raw))

      expect(store.get(done.id).status).to eq('completed')
    end

    it 'does not mistake an unrelated live process with a reused pid for the producer' do
      live = store.create!(tool: 'pipeline_embed')
      path = File.join(@index_dir, described_class::DIRNAME, "#{live.id}.json")
      raw = JSON.parse(File.read(path))
      raw['producer_identity'] = 'different-process-start'
      File.write(path, JSON.generate(raw))

      expect(store.get(live.id).status).to eq('failed')
    end

    it 'keeps the same live producer working across store restarts' do
      live = store.create!(tool: 'pipeline_embed')

      expect(described_class.new(@index_dir).get(live.id).status).to eq('working')
    end

    # A task minted in a different boot/pid namespace (e.g. a container) can't
    # be judged by this reader's own pid table at all: a host-side reader would
    # otherwise see a namespaced pid as "not running" and fail a task that is
    # actually still working. pid 2**30 stands in for "would read as dead if
    # the process table were consulted" to prove the boot check short-circuits
    # before it gets there. The leave-alone is bounded by
    # FOREIGN_PRODUCER_GRACE_SECONDS — see the aged case below.
    it 'leaves a recent task alone when its producer identity records a foreign boot' do
      allow(store).to receive(:producer_identity_for).and_return('boot=test-boot;start_ticks=1')
      live = store.create!(tool: 'pipeline_embed')
      path = File.join(@index_dir, described_class::DIRNAME, "#{live.id}.json")
      raw = JSON.parse(File.read(path))
      raw['producer_identity'] = 'boot=not-this-hosts-boot;start_ticks=1'
      raw['pid'] = 2**30
      File.write(path, JSON.generate(raw))

      expect(store.get(live.id).status).to eq('working')
    end

    # MCP-4: the overwhelmingly common source of a boot-id mismatch on the SAME
    # store is "this machine rebooted", in which the producer is dead by
    # construction — the crash-resilience headline. Without an age backstop the
    # client polls `working` forever. The window is wide enough that a genuine
    # cross-machine producer (the NFS reading the conservatism protects) is
    # never failed mid-run.
    it 'fails a foreign-boot working record once it is older than the grace window' do
      allow(store).to receive(:producer_identity_for).and_return('boot=test-boot;start_ticks=1')
      live = store.create!(tool: 'pipeline_embed')
      path = File.join(@index_dir, described_class::DIRNAME, "#{live.id}.json")
      raw = JSON.parse(File.read(path))
      raw['producer_identity'] = 'boot=not-this-hosts-boot;start_ticks=1'
      raw['pid'] = 2**30
      aged = Time.now.utc - described_class::FOREIGN_PRODUCER_GRACE_SECONDS - 60
      raw['updated_at'] = aged.iso8601
      File.write(path, JSON.generate(raw))

      task = store.get(live.id)
      expect(task.status).to eq('failed')
      expect(task.error['message']).to include('did not survive')
    end

    it 'leaves a task alone when its producer identity records another pid namespace on this boot' do
      allow(store).to receive_messages(producer_identity_for: 'boot=test-boot;ns=pid:[1];start_ticks=1',
                                       current_boot_identity: 'test-boot',
                                       current_pid_namespace: 'pid:[1]')
      live = store.create!(tool: 'pipeline_embed')
      path = File.join(@index_dir, described_class::DIRNAME, "#{live.id}.json")
      raw = JSON.parse(File.read(path))
      raw['producer_identity'] = 'boot=test-boot;ns=pid:[4026532000];start_ticks=1'
      raw['pid'] = 2**30
      File.write(path, JSON.generate(raw))

      expect(store.get(live.id).status).to eq('working')
    end

    it 'still judges a same-boot, same-namespace producer by its pid' do
      allow(store).to receive_messages(producer_identity_for: 'boot=test-boot;ns=pid:[1];start_ticks=1',
                                       current_boot_identity: 'test-boot',
                                       current_pid_namespace: 'pid:[1]')
      live = store.create!(tool: 'pipeline_embed')
      path = File.join(@index_dir, described_class::DIRNAME, "#{live.id}.json")
      raw = JSON.parse(File.read(path))
      raw['pid'] = 2**30
      File.write(path, JSON.generate(raw))

      expect(store.get(live.id).status).to eq('failed')
    end

    it 'marks a task failed after its exact producer process dies' do
      child = Process.spawn('/bin/sleep', '30')
      identity = store.send(:producer_identity_for, child)
      task = store.create!(tool: 'pipeline_embed')
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path)).merge('pid' => child, 'producer_identity' => identity)
      File.write(path, JSON.generate(raw))
      Process.kill('TERM', child)
      Process.wait(child)

      expect(described_class.new(@index_dir).get(task.id).status).to eq('failed')
    ensure
      if child
        begin
          Process.kill('KILL', child)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(child)
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  describe 'expiry' do
    it 'drops a record older than its ttl' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 0)
      store.complete!(task.id, result: {})

      expect(store.get(task.id)).to be_nil
    end

    it 'sweeps expired records off disk when a new task is created' do
      old = store.create!(tool: 'pipeline_extract', ttl_ms: 0)
      store.complete!(old.id, result: {})
      store.create!(tool: 'pipeline_embed')

      expect(File.exist?(File.join(@index_dir, described_class::DIRNAME, "#{old.id}.json"))).to be false
    end

    # An unfinished task must outlive its ttl rather than vanish mid-run and
    # strand a client that is still polling it.
    it 'keeps a still-working task past its ttl' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 0)
      expect(store.get(task.id)).not_to be_nil
    end

    # A pipeline that runs longer than its own ttl (the default is 1h) must not
    # have its result evaporate the instant complete! writes it: ttl for a
    # terminal record measures from the transition itself, not from creation.
    it 'measures terminal task ttl from the last update rather than creation' do
      allow(store).to receive(:producer_identity_for).and_return('boot=test-boot;start_ticks=1')
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 10_000)
      path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
      raw = JSON.parse(File.read(path))
      raw['created_at'] = (Time.now.utc - 3600).iso8601
      File.write(path, JSON.generate(raw))

      store.complete!(task.id, result: {})

      expect(store.get(task.id)).not_to be_nil
    end

    describe 'sweeping a corrupt record' do
      # A corrupt record is not a race between two sweepers — a valid record
      # does not spontaneously fail schema validation. It is (almost always)
      # permanent: a version upgrade, a hand-edit. Left alone it gets
      # re-parsed and re-fails on every sweep forever, so age is the signal
      # sweep_expired! uses to tell "permanently broken" from "a write still
      # in flight" (which would also read as corrupt for the brief window
      # between truncate and rename).
      def corrupt_a_record(ttl_ms: 10_000)
        task = store.create!(tool: 'pipeline_extract', ttl_ms: ttl_ms)
        path = File.join(@index_dir, described_class::DIRNAME, "#{task.id}.json")
        File.write(path, 'not json{')
        path
      end

      it 'deletes a corrupt record older than the default expiry window' do
        path = corrupt_a_record
        old_time = Time.now - (described_class::DEFAULT_TTL_MS / 1000.0) - 60
        File.utime(old_time, old_time, path)

        store.send(:sweep_expired!)

        expect(File.exist?(path)).to be false
      end

      it 'leaves a corrupt record younger than the default expiry window untouched' do
        path = corrupt_a_record

        store.send(:sweep_expired!)

        expect(File.exist?(path)).to be true
      end

      it 'does not raise when sweeping a directory holding only a corrupt record' do
        corrupt_a_record

        expect { store.send(:sweep_expired!) }.not_to raise_error
      end
    end
  end

  describe 'concurrent polling' do
    it 'returns the same durable result to concurrent readers' do
      task = store.create!(tool: 'pipeline_extract')
      store.complete!(task.id, result: { 'ok' => true })

      results = 12.times.map { Thread.new { described_class.new(@index_dir).get(task.id)&.to_h } }.map(&:value)

      expect(results).to all(eq(results.first))
      expect(results.first[:result]).to eq('ok' => true)
    end
  end

  describe 'the wire shape' do
    it 'matches the CreateTaskResult fields the extension advertises' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: 1000, poll_interval_ms: 250)
      expect(task.to_h).to include(
        taskId: task.id,
        status: 'working',
        ttlMs: 1000,
        pollIntervalMs: 250,
        createdAt: task.created_at,
        lastUpdatedAt: task.updated_at
      )
    end

    it 'emits required ttlMs when the value is explicitly null' do
      task = store.create!(tool: 'pipeline_extract', ttl_ms: nil)

      expect(task.to_h).to include(ttlMs: nil)
    end

    it 'omits result and error while still working' do
      expect(store.create!(tool: 'pipeline_extract').to_h.keys).not_to include(:result, :error)
    end

    it 'carries the result once completed' do
      task = store.create!(tool: 'pipeline_extract')
      store.complete!(task.id, result: { 'ok' => true })
      expect(store.get(task.id).to_h[:result]).to eq({ 'ok' => true })
    end
  end
end
