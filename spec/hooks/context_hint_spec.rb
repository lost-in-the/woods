# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/hooks/context_hint'

RSpec.describe Woods::Hooks::ContextHint do
  let(:root) { Dir.mktmpdir('woods-context-app') }
  let(:output) { File.join(root, 'tmp/woods') }
  let(:event) do
    { 'hook_event_name' => 'PostToolUse', 'tool_name' => 'Edit', 'session_id' => 'test-session',
      'cwd' => root, 'tool_input' => { 'file_path' => File.join(root, 'app/models/post.rb') } }
  end
  let(:graph) { JSON.parse(File.read(File.expand_path('../fixtures/woods/dependency_graph.json', __dir__))) }

  before do
    FileUtils.mkdir_p(File.join(root, 'app/models'))
    File.write(File.join(root, 'app/models/post.rb'), 'class Post; end')
    publish(1)
  end
  after { FileUtils.remove_entry(root) }

  def publish(number)
    payload = File.join(output, "payloads/gen-#{number}")
    FileUtils.mkdir_p(payload)
    File.write(File.join(payload, 'manifest.json'), JSON.generate(total_units: 3))
    File.write(File.join(payload, 'dependency_graph.json'), JSON.generate(graph))
    Woods::Generation.new(output_dir: output).bump!(payload: "payloads/gen-#{number}")
  end

  def hint(input = event)
    described_class.new(event: input, output_dir: output).call
  end

  it 'reports typed direct candidates, unknown legacy labels and pre-refresh uncertainty' do
    text = hint.fetch(:context)
    expect(text).to include('generation 1', 'pre-refresh', 'Comment (model)', 'PostsController (controller)',
                            'direct candidate', 'via=unknown', 'source freshness: unknown', 'not proof')
    expect(text).not_to include(root)
  end

  it 'keeps unavailable source evidence explicit in orientation and edit context' do
    key = Woods::SourceInputs::PrivateKey.new(output_dir: output, create: true)
    capture = Woods::SourceInputs::Scanner.new(root: root, output_dir: output, key: key).call
    capture['metrics']['padding'] = 'x' * 4000
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 2000)
    manifest = Woods::SourceInputs::Manifest.build(snapshot: capture, scopes: {}, boot_verified: true, generation: 1)
    payload = Woods::Generation.new(output_dir: output).payload_dir
    File.write(payload.join('source_inputs.json'), JSON.generate(manifest.data))

    [event, event.merge('hook_event_name' => 'SessionStart')].each do |input|
      text = hint(input).fetch(:context)
      expect(text).to include('source freshness: unavailable', 'source_manifest_too_large',
                              "#{manifest.data.dig('unavailable', 'size_bytes')} bytes", 'limit 2000')
      expect(text).not_to include('woods-extract full', 'source freshness: current')
    end
  end

  it 'distinguishes downstream inference and test suggestions from direct relationships' do
    graph['nodes']['CommentSpec'] = { 'type' => 'test_mapping', 'file_path' => 'spec/comment_spec.rb' }
    graph['edges']['CommentSpec'] = [{ 'target' => 'Comment', 'via' => 'test_coverage' }]
    graph['reverse']['Comment'] = ['CommentSpec']
    publish(2)
    expect(hint.fetch(:context)).to include('transitive candidate', 'test suggestion', 'via=test_coverage')
  end

  it 'does not call an unresolved path no-impact' do
    event['tool_input']['file_path'] = File.join(root, 'app/models/removed.rb')
    expect(hint.fetch(:context)).to include('unresolved', 'verify with search', 'generation 1')
    expect(hint.fetch(:context)).not_to include('no impact')
  end

  it 'reports colliding roots without assigning the wrong target type' do
    graph['variants'] =
      [{ 'identifier' => 'Post', 'type' => 'service', 'file_path' => 'app/models/post.rb', 'edges' => [] }]
    publish(2)
    expect(hint.fetch(:context)).to include('ambiguous', 'Post (model)', 'Post (service)')
    expect(hint.fetch(:context)).not_to include('direct candidate')
  end

  it 'caps graph work and whole response bytes without cutting an identity' do
    200.times do |i|
      name = "Caller#{i}"
      graph['nodes'][name] = { 'type' => 'service' }
      graph['edges'][name] = [{ 'target' => 'Post', 'via' => 'calls' }]
      graph['reverse']['Post'] << name
    end
    publish(2)
    result = hint
    expect(result.fetch(:context)).to include('truncated: yes', 'nodes<=10', 'edges<=100')
    expect(Woods::Hooks::ContextOutput.new('PostToolUse').encode(result.fetch(:context)).bytesize).to be <= 2048
  end

  it 'returns a short orientation without loading Rails or a provider' do
    text = hint(event.merge('hook_event_name' => 'SessionStart')).fetch(:context)
    expect(text).to include('generation 1', 'woods_status', 'lookup', 'dependents')
    expect(text).not_to include('direct candidate')
  end

  it 'ignores unrelated edits and rejects traversal or external symlink paths' do
    expect(hint(event.merge('tool_input' => { 'file_path' => 'README.md' }))).to be_nil
    expect(hint(event.merge('tool_input' => { 'file_path' => '../outside.rb' }))).to be_nil
    File.symlink('/etc/passwd', File.join(root, 'app/models/external.rb'))
    expect(hint(event.merge('tool_input' => { 'file_path' => 'app/models/external.rb' }))).to be_nil
  end

  it 'changes suppression evidence for same-file same-size rewrites and new generations' do
    first = hint.fetch(:identity)
    original_stat = File.stat(File.join(root, 'app/models/post.rb'))
    File.write(File.join(root, 'app/models/post.rb'), 'class Lost; end')
    File.utime(original_stat.atime, original_stat.mtime, File.join(root, 'app/models/post.rb'))
    second = hint.fetch(:identity)
    publish(2)
    third = hint.fetch(:identity)
    expect([first, second, third].uniq.size).to eq(3)
  end

  it 'never calls a flat or missing index a complete snapshot' do
    FileUtils.rm_f(File.join(output, 'generation.json'))
    expect(hint.fetch(:context)).to include('unavailable', 'woods_status')
  end

  it 'keeps one generation when publication occurs between freshness and graph reads' do
    allow(Woods::SourceInputs::Status).to receive(:new).and_wrap_original do |original, **options|
      checker = original.call(**options)
      allow(checker).to receive(:call).and_wrap_original do |check|
        value = check.call
        graph['reverse']['Post'] = []
        publish(2)
        value
      end
      checker
    end
    expect(hint.fetch(:context)).to include('generation 1', 'Comment (model)')
  end

  it 'fails closed on oversized, corrupt or non-object graph artifacts' do
    file = File.join(output, 'payloads/gen-1/dependency_graph.json')
    %w[[] null broken].each do |bytes|
      File.write(file, bytes)
      expect(hint.fetch(:context)).to include('unavailable')
    end
    File.truncate(file, described_class::MAX_ARTIFACT_BYTES + 1)
    expect(hint.fetch(:context)).to include('unavailable')
  end

  it 'omits an oversized identity row rather than silently shortening it' do
    identifier = 'VeryLong' * 1000
    graph['nodes'][identifier] = { 'type' => 'service' }
    graph['edges'][identifier] = ['Post']
    graph['reverse']['Post'] = [identifier]
    publish(2)
    text = hint.fetch(:context)
    expect(text).to include('truncated: yes')
    expect(text).not_to include('VeryLong')
  end
end
