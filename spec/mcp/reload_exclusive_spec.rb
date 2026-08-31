# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'timeout'
require 'woods'
require 'woods/mcp/index_reader'
require 'woods/mcp/server'

RSpec.describe 'Index MCP exclusive reload contract' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:index_dir) { Dir.mktmpdir('woods-mcp-exclusive-reload') }
  let(:manifest_path) { File.join(index_dir, 'manifest.json') }
  let(:generation) { Woods::Generation.new(output_dir: index_dir) }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }
  let(:reloader_entered) { Queue.new }
  let(:finish_reloader) { Queue.new }
  let(:retriever_reloader) do
    Class.new do
      def initialize(entered, finish, reader, swap_attempted, commit_entered, commit_release)
        @entered = entered
        @finish = finish
        @reader = reader
        @swap_attempted = swap_attempted
        @commit_entered = commit_entered
        @commit_release = commit_release
      end

      # Mimic the real transaction shape (M7): candidate build WITHOUT the
      # exclusive lock, then the commit phase under it. The signals are owned
      # by this double (an explicit spec seam) rather than by wrapping reader
      # methods, and the commit section blocks until released so specs can
      # hold the exclusive lock open deterministically.
      def call(_reader)
        @entered << true
        @finish.pop
        @swap_attempted << true
        @reader.with_exclusive_generation do
          @commit_entered << true
          @commit_release.pop
          { vectors: 22, metadata: 22, graph: 1 }
        end
      end
    end.new(reloader_entered, finish_reloader, reader, swap_attempted, commit_entered, commit_release)
  end
  let(:swap_attempted) { Queue.new }
  let(:commit_entered) { Queue.new }
  let(:commit_release) { Queue.new }
  let(:server) do
    allow(Woods::MCP::IndexReader).to receive(:new).with(index_dir).and_return(reader)
    Woods::MCP::Server.build(
      index_dir: index_dir,
      response_format: :json,
      warmup: false,
      retriever_reloader: retriever_reloader
    )
  end

  before do
    FileUtils.cp_r("#{fixture_dir}/.", index_dir)
    write_manifest(total_units: 1)
    generation.bump!(reason: 'initial')
  end

  after { FileUtils.rm_rf(index_dir) }

  it 'allows ordinary reader tool handlers to overlap' do
    server
    entered = Queue.new
    release = Queue.new
    original_manifest = reader.method(:manifest)
    allow(reader).to receive(:manifest) do
      value = original_manifest.call
      if Thread.current[:block_structure_manifest]
        entered << true
        release.pop
      end
      value
    end

    tools = 2.times.map do
      Thread.new do
        Thread.current[:block_structure_manifest] = true
        dispatch_tool('structure')
      end
    end
    2.times { Timeout.timeout(1) { entered.pop } }
    overlapping = tools.all?(&:alive?)
    2.times { release << true }
    totals = tools.map { |thread| thread.value.dig('structuredContent', 'data', 'manifest', 'total_units') }

    expect(overlapping).to be(true)
    expect(totals).to eq([1, 1])
  ensure
    2.times { release << true } if tools&.any?(&:alive?)
    tools&.each { |thread| thread.join(1) }
  end

  it 'makes reload wait for an active production tool handler' do
    server
    active_entered = Queue.new
    release_active = Queue.new
    original_manifest = reader.method(:manifest)
    allow(reader).to receive(:manifest) do
      value = original_manifest.call
      if Thread.current[:active_structure]
        active_entered << true
        release_active.pop
      end
      value
    end

    active = Thread.new do
      Thread.current[:active_structure] = true
      dispatch_tool('structure')
    end
    active_entered.pop

    # The transactional reload (M7) builds candidate stores WITHOUT the
    # exclusive lock, then commits under it. Prove each phase separately:
    # the build phase entered (reloader_entered), the commit phase reached
    # the exclusive lock attempt (swap_attempted), and a bounded
    # non-completion proves the commit is blocked specifically on the pin —
    # no sleep duration to get wrong. The signal comes from the reloader
    # double itself, which owns the seam (no reader method wrapping).

    reload = Thread.new { dispatch_tool('reload') }
    reloader_entered.pop
    finish_reloader << true
    Timeout.timeout(1) { swap_attempted.pop }
    waited_for_tool = !reload.join(0.05)

    release_active << true
    active_response = active.value
    commit_release << true
    reload_response = reload.value

    expect(waited_for_tool).to be(true)
    expect(active_response.dig('structuredContent', 'data', 'manifest', 'total_units')).to eq(1)
    expect(reload_response.dig('structuredContent', 'data', 'reloaded')).to be(true)
    expect(reload_response.dig('structuredContent', 'data', 'retriever', 'vectors')).to eq(22)
  ensure
    finish_reloader << true if reload&.alive?
    release_active << true if active&.alive?
    commit_release << true if reload&.alive?
    [active, reload].compact.each { |thread| thread.join(1) }
  end

  it 'keeps a later production tool behind an active reload' do
    # The commit phase holds the exclusive generation lock; a structure tool
    # dispatched while it is held must wait for it. The swap_attempted signal
    # comes from the reloader double itself.

    reload = Thread.new { dispatch_tool('reload') }
    reloader_entered.pop
    finish_reloader << true
    Timeout.timeout(1) { swap_attempted.pop }
    Timeout.timeout(1) { commit_entered.pop }

    later_entered = Queue.new
    original_manifest = reader.method(:manifest)
    allow(reader).to receive(:manifest) do
      later_entered << true if Thread.current[:later_structure]
      original_manifest.call
    end
    # Proves the later thread reached its own pin attempt before we ask
    # whether it got past the exclusive reload: replaces a fixed sleep with
    # a signal tied to the actual code path under test.
    later_attempted = Queue.new
    allow(reader).to receive(:with_pinned_generation).and_wrap_original do |original, *args, &block|
      later_attempted << true if Thread.current[:later_structure]
      original.call(*args, &block)
    end

    later = Thread.new do
      Thread.current[:later_structure] = true
      dispatch_tool('structure')
    end
    Timeout.timeout(1) { later_attempted.pop }
    completed_early = later.join(0.05)
    entered_during_reload = completed_early || !later_entered.empty?

    commit_release << true
    reload_response = reload.value
    later_response = later.value

    expect(entered_during_reload).to be(false)
    expect(reload_response.dig('structuredContent', 'data', 'reloaded')).to be(true)
    expect(later_response.dig('structuredContent', 'data', 'manifest', 'total_units')).to eq(1)
  ensure
    finish_reloader << true if reload&.alive?
    commit_release << true if reload&.alive?
    [reload, later].compact.each { |thread| thread.join(1) }
  end

  it 'keeps every reader access in one tool response on one cached generation' do
    server
    reader.dependency_graph
    reader.raw_graph_data
    original_dependency_graph = reader.method(:dependency_graph)
    published = false
    allow(reader).to receive(:dependency_graph) do
      graph = original_dependency_graph.call
      if Thread.current[:publish_during_pagerank] && !published
        published = true
        publish_graph(node_type: 'new_generation')
      end
      graph
    end

    Thread.current[:publish_during_pagerank] = true
    response = dispatch_tool('pagerank')
    post_type = response.dig('structuredContent', 'data', 'results')
                        .find { |row| row['identifier'] == 'Post' }
                        .fetch('type')

    expect(post_type).to eq('model')
  ensure
    Thread.current[:publish_during_pagerank] = nil
  end

  it 'releases a production tool pin when the handler raises' do
    server
    allow(reader).to receive(:find_unit).and_raise(RuntimeError, 'handler exploded')

    failed = dispatch_rpc('tools/call', { name: 'lookup', arguments: { identifier: 'Post' } })
    reload = Thread.new { dispatch_tool('reload') }
    entered_after_failure = !Timeout.timeout(1) { reloader_entered.pop }.nil?
    finish_reloader << true
    commit_release << true

    expect(failed).to have_key('error')
    expect(entered_after_failure).to be(true)
    expect(reload.value.dig('structuredContent', 'data', 'reloaded')).to be(true)
  ensure
    finish_reloader << true if reload&.alive?
    commit_release << true if reload&.alive?
    reload&.join(1)
  end

  it 'pins each server to its own reader without leaking across instances' do
    first_reader = Woods::MCP::IndexReader.new(index_dir, auto_refresh: false)
    second_reader = Woods::MCP::IndexReader.new(index_dir, auto_refresh: false)
    allow(Woods::MCP::IndexReader).to receive(:new).with(index_dir).and_return(first_reader, second_reader)
    first_server = Woods::MCP::Server.build(
      index_dir: index_dir, response_format: :json, warmup: false
    )
    second_server = Woods::MCP::Server.build(
      index_dir: index_dir, response_format: :json, warmup: false
    )
    exclusive_entered = Queue.new
    release_exclusive = Queue.new
    exclusive = Thread.new do
      first_reader.with_exclusive_reload do
        exclusive_entered << true
        release_exclusive.pop
      end
    end
    exclusive_entered.pop

    # `.alive?` alone is a race (nothing stops the thread finishing between
    # the check and its use elsewhere), and a fixed sleep before it proves
    # nothing about *why* it's still running. The barrier proves first_tool
    # reached its own pin attempt; the bounded join is the atomic proof it
    # hadn't finished within that window.
    first_attempted = Queue.new
    allow(first_reader).to receive(:with_pinned_generation).and_wrap_original do |original, *args, &block|
      first_attempted << true
      original.call(*args, &block)
    end

    first_tool = Thread.new { dispatch_tool('structure', target: first_server) }
    second_tool = Thread.new { dispatch_tool('structure', target: second_server) }
    second_result = Timeout.timeout(1) { second_tool.value }
    Timeout.timeout(1) { first_attempted.pop }
    first_waited = !first_tool.join(0.05)

    release_exclusive << true

    expect(first_waited).to be(true)
    expect(second_result.dig('structuredContent', 'data', 'manifest', 'total_units')).to eq(1)
    expect(first_tool.value.dig('structuredContent', 'data', 'manifest', 'total_units')).to eq(1)
  ensure
    release_exclusive << true if exclusive&.alive?
    [exclusive, first_tool, second_tool].compact.each { |thread| thread.join(1) }
  end

  it 'leaves unknown tools and Tasks methods outside the reader gate' do
    isolated_reader = Woods::MCP::IndexReader.new(index_dir, auto_refresh: false)
    allow(Woods::MCP::IndexReader).to receive(:new).with(index_dir).and_return(isolated_reader)
    isolated_server = Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false)
    exclusive_entered = Queue.new
    release_exclusive = Queue.new
    exclusive = Thread.new do
      isolated_reader.with_exclusive_reload do
        exclusive_entered << true
        release_exclusive.pop
      end
    end
    exclusive_entered.pop

    unknown = Thread.new do
      dispatch_rpc('tools/call', { name: 'not_a_tool', arguments: {} }, target: isolated_server)
    end
    task = Thread.new do
      dispatch_rpc(
        'tasks/cancel',
        { taskId: 'a' * 32, _meta: request_meta(tasks: true) },
        target: isolated_server,
        include_meta: false
      )
    end
    completed_outside_gate = [unknown, task].all? { |thread| thread.join(1) }
    release_exclusive << true

    expect(completed_outside_gate).to be(true)
    expect(unknown.value).to have_key('error')
    expect(task.value).to have_key('error')
  ensure
    release_exclusive << true if exclusive&.alive?
    [exclusive, unknown, task].compact.each { |thread| thread.join(1) }
  end

  # A previous version of the pin wrapper covered only 14 of 28 non-reload
  # tools via a hand-maintained allowlist, so `pipeline_status` — like every
  # other operator/feedback/snapshot tool — ran concurrently with an active
  # exclusive reload. Coverage is now derived from every registered tool
  # (see Woods::MCP::IndexReaderPinning), so a pipeline tool waits behind an
  # exclusive reload the same way a reader tool like `structure` does.
  it 'gates a pipeline tool behind an active exclusive reload, now that pin coverage includes it' do
    isolated_reader = Woods::MCP::IndexReader.new(index_dir, auto_refresh: false)
    allow(Woods::MCP::IndexReader).to receive(:new).with(index_dir).and_return(isolated_reader)
    reporter = Class.new do
      def report
        { state: 'idle' }
      end
    end.new
    operator = {
      status_reporter: reporter, pipeline_guard: nil, pipeline_lock: nil, error_escalator: nil
    }
    isolated_server = Woods::MCP::Server.build(
      index_dir: index_dir, operator: operator, response_format: :json, warmup: false
    )
    exclusive_entered = Queue.new
    release_exclusive = Queue.new
    exclusive = Thread.new do
      isolated_reader.with_exclusive_reload do
        exclusive_entered << true
        release_exclusive.pop
      end
    end
    exclusive_entered.pop

    status = Thread.new { dispatch_tool('pipeline_status', target: isolated_server) }
    still_blocked =
      begin
        Timeout.timeout(0.3) { status.join }
        false
      rescue Timeout::Error
        true
      end

    release_exclusive << true

    expect(still_blocked).to be(true)
    expect(status.value.dig('structuredContent', 'data', 'state')).to eq('idle')
  ensure
    release_exclusive << true if exclusive&.alive?
    [exclusive, status].compact.each { |thread| thread.join(1) }
  end

  it 'holds resource and template pins through response serialization' do
    server
    allow(JSON).to receive(:pretty_generate).and_wrap_original do |original, *arguments|
      barrier = Thread.current[:resource_serialization_barrier]
      if barrier
        barrier.fetch(:entered) << true
        barrier.fetch(:release).pop
      end
      original.call(*arguments)
    end

    # Captured once, outside the loop: the exclusive-generation wrap is only
    # added a single time, so each iteration's swap_attempted signal comes
    # from the reloader double's own seam, not from a stub layered over the
    # previous iteration's stub.

    waited = ['codebase://manifest', 'codebase://unit/Post'].map do |uri|
      serialization_entered = Queue.new
      release_serialization = Queue.new
      resource = Thread.new do
        Thread.current[:resource_serialization_barrier] = {
          entered: serialization_entered, release: release_serialization
        }
        dispatch_rpc('resources/read', { uri: uri })
      end
      serialization_entered.pop
      reload = Thread.new { dispatch_tool('reload') }
      reloader_entered.pop
      finish_reloader << true
      Timeout.timeout(1) { swap_attempted.pop }
      reload_waited = !reload.join(0.05)

      release_serialization << true
      resource.value
      commit_release << true
      reload.value
      reload_waited
    ensure
      release_serialization << true if resource&.alive?
      finish_reloader << true if reload&.alive?
      commit_release << true if reload&.alive?
      [resource, reload].compact.each { |thread| thread.join(1) }
    end

    expect(waited).to eq([true, true])
  end

  def write_manifest(total_units:)
    File.write(
      manifest_path,
      JSON.generate(
        'extracted_at' => '2026-08-20T00:00:00Z',
        'total_units' => total_units,
        'counts' => { 'models' => total_units }
      )
    )
  end

  def publish_graph(node_type:)
    graph = JSON.parse(File.read(File.join(fixture_dir, 'dependency_graph.json')))
    graph.fetch('nodes').each_value { |node| node['type'] = node_type }
    File.write(File.join(index_dir, 'dependency_graph.json'), JSON.generate(graph))
    generation.bump!(reason: 'graph_update')
  end

  def dispatch_tool(name, arguments = {}, target: server)
    dispatch_rpc('tools/call', { name: name, arguments: arguments }, target: target).fetch('result')
  end

  def dispatch_rpc(method, params = {}, target: server, include_meta: true)
    params = params.merge(_meta: request_meta) if include_meta
    request = {
      jsonrpc: '2.0',
      id: 1,
      method: method,
      params: params
    }
    JSON.parse(target.handle_json(JSON.generate(request)))
  end

  def request_meta(tasks: false)
    capabilities = {}
    if tasks
      capabilities['extensions'] = {
        Woods::MCP::Tasks::Extension::EXTENSION_ID => {}
      }
    end
    {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { 'name' => 'reload-spec', 'version' => '1.0' },
      'io.modelcontextprotocol/clientCapabilities' => capabilities
    }
  end
end
