# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'timeout'

RSpec.describe 'explicit edit client adapters' do
  let(:hooks) { File.expand_path('../../plugin/hooks', __dir__) }
  let(:fixtures) { File.expand_path('../fixtures/hooks', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-adapter') do |root|
      @root = root
      @output = File.join(root, 'tmp/woods')
      FileUtils.mkdir_p(@output)
      File.write(File.join(@output, 'generation.json'), '{}')
      @record = File.join(root, 'batch.json')
      @rake = File.join(root, 'rake.sh')
      File.write(@rake, <<~SH)
        #!/bin/sh
        #{RbConfig.ruby} -rjson -rbase64 -e 'File.write(ARGV[1] + ".tmp", Base64.strict_decode64(ARGV[0].split("[", 2).last.delete_suffix("]"))); File.rename(ARGV[1] + ".tmp", ARGV[1])' "$1" "#{@record}"
      SH
      File.chmod(0o755, @rake)
      example.run
    end
  end

  def envelope(events)
    { version: 1, client: 'opencode', root: @root, events: events }
  end

  def invoke(events)
    Open3.capture3({ 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => @rake },
                   'bash', File.join(hooks, 'woods-refresh.sh'), 'opencode', stdin_data: JSON.generate(events))
  end

  def ruby_only_path
    bin = File.join(@root, 'restricted-bin')
    FileUtils.mkdir_p(bin)
    %w[cat head mktemp mkdir rmdir tr ruby date sleep touch stat mv rm wc].each do |tool|
      found = executable_on_path(tool)
      File.symlink(found, File.join(bin, tool)) if found
    end
    bash = executable_on_path('bash')
    [bin, bash]
  end

  def executable_on_path(tool)
    ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |part| File.join(part, tool) }
       .find { |path| File.executable?(path) && File.file?(path) }
  end

  def run_plugin(raw, environment = {})
    File.write(File.join(@root, 'event.json'), JSON.generate(raw))
    script = <<~JS
      import plugin from #{File.join(hooks, 'woods-opencode.mjs').to_json};
      import fs from 'node:fs';
      const raw = JSON.parse(fs.readFileSync(#{File.join(@root, 'event.json').to_json}));
      const hooks = await plugin({directory: #{@root.to_json}, worktree: #{@root.to_json}});
      await hooks['tool.execute.after'](raw.input, raw.output);
    JS
    Open3.capture3({ 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => @rake }.merge(environment),
                   'node', '--input-type=module', stdin_data: script)
  end

  it 'queues every mixed operation including both rename sides as one task batch' do
    events = [{ path: 'app/services/add.rb', operation: 'add' },
              { path: 'app/services/edit.rb', operation: 'update' },
              { path: 'app/services/gone.rb', operation: 'delete' },
              { path: 'app/services/old.rb', operation: 'delete' },
              { path: 'app/services/new.rb', operation: 'add' }]
    _, err, status = invoke(envelope(events))
    expect(status).to be_success, err
    expect(JSON.parse(File.read(@record))['events']).to match_array(JSON.parse(JSON.generate(events)))
    expect(Dir[File.join(@output, 'hook-pending/*.json')]).to eq([])
  end

  it 'rejects an entire event before queueing when any member escapes or crosses a symlink' do
    outside = Dir.mktmpdir('woods-foreign')
    FileUtils.mkdir_p(File.join(@root, 'app'))
    File.symlink(outside, File.join(@root, 'app/linked'))
    ['/other/worktree/app/services/x.rb', '../other.rb', 'app/linked/deleted.rb'].each do |path|
      _, err, = invoke(envelope([{ path: 'app/services/ok.rb', operation: 'add' },
                                 { path: path, operation: 'delete' }]))
      expect(err).to include('no refresh queued')
      expect(File.exist?(@record)).to be(false)
      expect(Dir[File.join(@output, 'hook-pending/*.json')]).to eq([])
    end
  ensure
    FileUtils.rm_rf(outside)
  end

  it 'keeps the complete multi-file group durable when the daemon defers the task' do
    File.write(@rake, "#!/bin/sh\nexit 75\n")
    events = [{ path: 'app/services/add.rb', operation: 'add' }, { path: 'config/routes.rb', operation: 'update' }]
    invoke(envelope(events))
    queued = Dir[File.join(@output, 'hook-pending/*.json')]
    expect(queued.size).to eq(1)
    expect(JSON.parse(File.read(queued.first))).to match_array(JSON.parse(JSON.generate(events)))
    expect(File.read(File.join(@output, 'hook.log'))).to include('status 75')
  end

  it 'runs the captured OpenCode callback through the actual plugin and shared shell entry point' do
    raw = JSON.parse(File.read(File.join(fixtures, 'opencode/apply_patch.json')))
    # Preserve the captured shape while placing its real file names under an
    # eligible fixture directory. No filename is reconstructed from patch text.
    raw = JSON.parse(JSON.generate(raw).gsub('/fixture/worktree/', "#{@root}/app/services/"))
    _, err, status = run_plugin(raw)
    expect(status).to be_success, err
    Timeout.timeout(10) { sleep 0.02 until File.exist?(@record) }
    actual = JSON.parse(File.read(@record))['events']
    expect(actual.map { |event| event['path'] }).to contain_exactly(
      'app/services/add.rb', 'app/services/update.rb', 'app/services/delete.rb',
      'app/services/move.rb', 'app/services/moved.rb'
    )
    expect(actual).to include('path' => 'app/services/move.rb', 'operation' => 'delete')
    expect(actual).to include('path' => 'app/services/moved.rb', 'operation' => 'add')
    expect(File.read(@record)).not_to include('patchText', 'diagnostics', 'sessionID', 'oldString')
  end

  it 'uses the pinned write and edit metadata contracts without carrying source text' do
    cases = [
      ['write', { filepath: "#{@root}/app/services/new.rb", exists: false }, 'add', 'new.rb'],
      ['write', { filepath: "#{@root}/app/services/existing.rb", exists: true }, 'update', 'existing.rb'],
      ['edit', { filediff: { file: "#{@root}/app/services/edit.rb", before: 'PRIVATE FIXTURE' } }, 'update', 'edit.rb']
    ]
    cases.each do |tool, metadata, operation, name|
      FileUtils.rm_f(@record)
      _, err, status = run_plugin(input: { tool: tool }, output: { metadata: metadata, output: 'PRIVATE FIXTURE' })
      expect(status).to be_success, err
      Timeout.timeout(10) { sleep 0.02 until File.exist?(@record) }
      expect(JSON.parse(File.read(@record))['events']).to eq(
        [{ 'path' => "app/services/#{name}", 'operation' => operation }]
      )
      expect(File.read(@record)).not_to include('PRIVATE FIXTURE', 'before')
    end
  end

  it 'keeps disabled or unsupported OpenCode tools quiet and sanitizes malformed edit metadata' do
    valid = { input: { tool: 'write' },
              output: { metadata: { filepath: "#{@root}/app/services/new.rb", exists: false } } }
    [run_plugin(valid, 'WOODS_HOOKS_ENABLED' => '0'), run_plugin(valid, 'WOODS_HOOKS_DISABLED' => '1'),
     run_plugin(input: { tool: 'bash' }, output: { metadata: {} })].each do |stdout, stderr, status|
      expect(status).to be_success
      expect(stdout).to eq('')
      expect(stderr).to eq('')
    end
    _, stderr, status = run_plugin(input: { tool: 'write' }, output: { metadata: { content: 'PRIVATE FIXTURE' } })
    expect(status).to be_success
    expect(stderr).to include('refresh not confirmed')
    expect(stderr).not_to include('PRIVATE FIXTURE', 'Error:')
    expect(File.exist?(@record)).to be(false)
  end

  it 'runs the captured Claude PostToolUse payload through the registered wrapper' do
    payload = File.read(File.join(fixtures, 'claude/write.json')).gsub('/fixture/worktree/', "#{@root}/app/services/")
    data = JSON.parse(payload).merge('cwd' => @root)
    _, err, status = Open3.capture3({ 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => @rake },
                                    'bash', File.join(hooks, 'woods-post-edit.sh'), stdin_data: JSON.generate(data))
    expect(status).to be_success, err
    expect(JSON.parse(File.read(@record))['events']).to eq(
      [{ 'path' => 'app/services/added.rb', 'operation' => 'update' }]
    )
  end

  it 'keeps jq and standalone Ruby normalization equivalent for lossless paths and duplicate operations' do
    events = [{ path: "app/services/with space,\n雪.rb", operation: 'add' },
              { path: 'app/services/old.rb', operation: 'delete' }]
    input = JSON.generate(envelope(events + events))
    ruby_out, ruby_err, ruby_status = Open3.capture3(RbConfig.ruby, File.join(hooks, 'adapters/normalize.rb'),
                                                     'opencode', stdin_data: input)
    jq_out, jq_err, jq_status = Open3.capture3('jq', '-c', '--arg', 'client', 'opencode', '-f',
                                               File.join(hooks, 'adapters/normalize.jq'), stdin_data: input)
    expect(ruby_status).to be_success, ruby_err
    expect(jq_status).to be_success, jq_err
    expect(JSON.parse(ruby_out)).to eq(JSON.parse(jq_out))
    expect(JSON.parse(ruby_out)['events'].size).to eq(2)
  end

  it 'keeps a malformed or unsupported event out of an already pending queue' do
    FileUtils.mkdir_p(File.join(@output, 'hook-pending'))
    pending = File.join(@output, 'hook-pending/existing.json')
    File.write(pending, JSON.generate(path: 'app/services/pending.rb', operation: 'update'))
    original = File.binread(pending)
    [{ version: 2 }, envelope([]), envelope([{ path: "bad\0path", operation: 'update' }])].each do |payload|
      _, err, = invoke(payload)
      expect(err).to include('no refresh queued')
      expect(File.binread(pending)).to eq(original)
      expect(File.exist?(@record)).to be(false)
    end
  end

  it 'rejects oversized UTF-8 input by bytes before either parser or queue runs' do
    bin, bash = ruby_only_path
    payload = JSON.generate(hook_event_name: 'PostToolUse', tool_name: 'Write', cwd: @root,
                            tool_input: { file_path: "#{@root}/app/services/large.rb", content: '雪' * 400_000 })
    expect(payload.bytesize).to be > 1_048_576
    expect(payload.length).to be < 1_048_576
    [ENV.fetch('PATH'), bin].each do |path|
      environment = { 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => @rake, 'PATH' => path }
      _, stderr, status = Open3.capture3(environment, bash, File.join(hooks, 'woods-post-edit.sh'), stdin_data: payload)
      expect(status).to be_success
      expect(stderr).to eq("[Woods hooks] Oversized edit event; no refresh queued.\n")
      expect(File.exist?(@record)).to be(false)
      expect(Dir[File.join(@output, 'hook-pending/*.json')]).to eq([])
    end
  end

  it 'sanitizes malformed and truncated JSON in the standalone Ruby adapter' do
    ['PRIVATE FIXTURE is not JSON', '{"tool_input":{"content":"PRIVATE FIXTURE'].each do |input|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(hooks, 'adapters/normalize.rb'), 'claude',
                                              stdin_data: input)
      expect(status).not_to be_success
      expect(stdout).to eq('')
      expect(stderr).to eq("[Woods hooks] Unsupported or malformed edit event; no refresh queued.\n")
      expect(stderr).not_to include('PRIVATE FIXTURE', 'ParserError', 'backtrace')
    end
  end

  it 'rejects raw NUL bytes without changing the path or leaving private input files' do
    bin, bash = ruby_only_path
    input_dir = File.join(@root, 'private-inputs')
    FileUtils.mkdir_p(input_dir)
    payload = JSON.generate(hook_event_name: 'PostToolUse', tool_name: 'Write', cwd: @root,
                            tool_input: { file_path: "#{@root}/app/services/a\0b.rb" }).gsub('\\u0000', "\0")
    [ENV.fetch('PATH'), bin].each do |path|
      environment = { 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => @rake,
                      'PATH' => path, 'TMPDIR' => input_dir }
      stdout, stderr, status = Open3.capture3(environment, bash, File.join(hooks, 'woods-post-edit.sh'),
                                              stdin_data: payload)
      expect(status).to be_success
      expect(stdout).to eq('')
      expect(stderr).to eq("[Woods hooks] Unsupported or malformed edit event; no refresh queued.\n")
      expect(File.exist?(@record)).to be(false)
      expect(Dir[File.join(@output, 'hook-pending/*.json')]).to eq([])
      expect(Dir.children(input_dir)).to eq([])
    end
  end

  it 'normalizes a trailing root slash before Ruby-only queue serialization without losing path bytes' do
    bin, bash = ruby_only_path
    relative = "app/services/with space,\n雪.rb"
    payload = envelope([{ path: "#{@root}/#{relative}", operation: 'add' }]).merge(root: "#{@root}/")
    environment = { 'WOODS_HOOKS_ENABLED' => '1', 'WOODS_HOOK_RAKE' => @rake, 'PATH' => bin }
    _, err, status = Open3.capture3(environment, bash, File.join(hooks, 'woods-refresh.sh'), 'opencode',
                                    stdin_data: JSON.generate(payload))
    expect(status).to be_success, err
    expect(JSON.parse(File.read(@record))['events']).to eq([{ 'path' => relative, 'operation' => 'add' }])
  end

  it 'rejects malformed registered-client events without logging their contents' do
    bad = { 'hook_event_name' => 'PostToolUse', 'tool_name' => 'Write', 'tool_input' => ['PRIVATE FIXTURE'] }
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(hooks, 'adapters/normalize.rb'), 'claude',
                                            stdin_data: JSON.generate(bad))
    expect(status).not_to be_success
    expect(stdout).to eq('')
    expect(stderr).to include('no refresh queued')
    expect(stderr).not_to include('PRIVATE FIXTURE', 'backtrace')
  end
end
