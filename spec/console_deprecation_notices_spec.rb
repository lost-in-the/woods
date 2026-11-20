# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'tmpdir'

RSpec.describe 'Console MCP deprecation notices' do
  let(:root) { File.expand_path('..', __dir__) }

  def read(path)
    File.read(File.join(root, path), encoding: Encoding::UTF_8)
  end

  it 'opens docs/CONSOLE_MCP_SETUP.md with the deprecation, the removal release and what to use instead' do
    head = read('docs/CONSOLE_MCP_SETUP.md').lines.first(14).join

    expect(head).to match(/\*\*Deprecated\.\*\*/)
    expect(head).to include('Woods 3.0', 'Index Server', 'bin/rails runner')
  end

  %w[README.md docs/README.md SECURITY.md CLAUDE.md docs/MCP_SERVERS.md
     plugin/skills/woods-mcp-config/SKILL.md plugin/skills/woods-setup/SKILL.md].each do |path|
    it "marks the Console deprecated in #{path}, naming the removal release" do
      expect(read(path)).to match(/Console[^\n]*deprecated[^\n]*3\.0|deprecated[^\n]*Console[^\n]*3\.0/i)
    end
  end

  it 'gives the Console guide a "What to use instead" section for other pages to link to' do
    expect(read('docs/CONSOLE_MCP_SETUP.md')).to match(/^## What to use instead$/)
  end

  %w[docs/AGENT_SETUP.md docs/GETTING_STARTED.md docs/INTERNALS.md docs/MCP_SERVERS.md docs/DOCKER_SETUP.md
     docs/FAQ.md docs/README.md README.md].each do |path|
    it "limits the Console to existing setups in #{path} and links the alternatives" do
      text = read(path)

      expect(text).to include('Existing setups keep working; new setups should not enable it.')
      expect(text).to match(/CONSOLE_MCP_SETUP\.md#what-to-use-instead/)
    end
  end

  it 'marks the Console section of the install template deprecated and tells new setups to leave it off' do
    section = read('lib/generators/woods/templates/woods.rb.tt')[/# ── Console MCP.*?(?=# ── )/m]

    expect(section).to include('DEPRECATED', 'Woods 3.0', 'New setups')
    expect(section).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end

  describe 'turning the Console off' do
    let(:guide) { read('docs/CONSOLE_MCP_SETUP.md') }
    let(:section) { guide[/^## Turning the Console off$.*?(?=^## )/m] }
    let(:skill) { read('plugin/skills/woods-console-disable/SKILL.md') }
    let(:disabled_line) do
      read('exe/woods-console')[/unless Woods\.configuration\.console_mcp_enabled\n\s*warn (.*?)\n\s*exit 1/m, 1]
        .scan(/'([^']*)'/).join
    end
    let(:deprecated_line) do
      require 'woods/console/deprecation_notice'
      "[woods] DEPRECATED: #{Woods::Console::DEPRECATION_MESSAGE}"
    end

    it 'has a section in the Console guide that names the skill' do
      expect(section).to include('woods-console-disable')
    end

    it 'quotes, in the guide and the skill, exactly the lines a disabled Console prints' do
      expect(disabled_line).to start_with('Woods Console MCP is disabled.')
      [section, skill].each { |text| expect(text).to include(disabled_line, deprecated_line) }
    end

    it 'covers every place the Console can be switched on or reached' do
      %w[console_mcp_enabled .mcp.json Woods::Console::RackMiddleware WOODS_CONSOLE_MCP_TOKEN
         WOODS_CONSOLE_CONFIG ~/.woods/console.yml woods:console woods-console-mcp].each do |place|
        expect([section, skill]).to all(include(place))
      end
    end

    it 'keeps the skill to its safety rules and the alternatives' do
      expect(skill).to include('Never delete a file.', 'Never print a value.', 'Leave the Index Server alone.',
                               'Ask before every edit.', 'Name keys, not values,', 'bin/rails runner', 'Woods 3.0',
                               'CONSOLE_MCP_SETUP.md#turning-the-console-off')
    end

    it 'decides what the skill may open by the class of file, which a clean secret check never raises' do
      expect(skill).to include('## File classes', 'A clean check never', 'config/initializers/*.rb',
                               '.vscode/mcp.json', '.env.example', 'config/master.key')
    end
  end

  describe 'a clean secret check grants no access' do
    define_method(:granting_sentences) do |text|
      text.split(/(?<=[.;!?])\s+|\n/).grep_v(/\b(?:never|not)\b|n't\b/i).select do |s|
        s.match?(/\b(?:open|read|edit|print)/i) && s.match?(/\b(?:check|scan|output)\b/i) &&
          s.match?(/\b(?:no output|no match(?:es)?|pass(?:es|ed)?|clean)\b/i)
      end
    end

    it 'recognizes each way of granting access on a clean result' do
      granting = ['Open a file only after the secret check passes for it.',
                  'A file with no output may be opened and edited.',
                  'For another client file, edit it only if the secret check passed for it.',
                  'When the scan is clean, the file is safe to read.']

      expect(granting.map { |sentence| granting_sentences(sentence) }).to all(be_any)
    end

    it 'has no such rule in the skill or the guide section' do
      skill = read('plugin/skills/woods-console-disable/SKILL.md')
      section = read('docs/CONSOLE_MCP_SETUP.md')[/^## Turning the Console off$.*?(?=^## )/m]

      expect(granting_sentences(skill) + granting_sentences(section)).to eq([])
    end
  end

  describe 'inventory commands print names and locations, never values' do
    marker = 'FAKE-SECRET-MARKER-7f3a'
    value_printing = {
      'a pager or cat' => /(?:\A|[\s|;(])(?:cat|less|more|head|tail|bat)\s/,
      'an environment dump' => /(?:\A|[\s|;(])(?:env|printenv|set|export -p)\s*(?:\||\z)|\bprintenv\b/,
      'a resolved Compose configuration' => /docker[- ]compose\b[^|]*\sconfig\b/,
      'Claude Code list or get' => /\bclaude mcp (?:list|get)\b/,
      'a diff with content' => /\bgit diff\b(?!\s+--stat)/,
      'grep that prints whole lines' => /\bgrep\b(?!\s+-[a-zA-Z]*[loc])/,
      'jq that prints env or header values' =>
        %r{\.(?:env|headers)\b(?!\*|\.(?:example|sample|template)\b|\s*//\s*\{\}\)\s*\|\s*keys)},
      'rails runner beyond the switch' => /\brails runner\b(?!\z| 'p Woods\.configuration\.console_mcp_enabled')/
    }

    define_method(:commands) do |text|
      fenced = text.scan(/^[ \t]*```bash\n(.*?)^[ \t]*```/m).flatten.flat_map do |block|
        block.gsub(/\\\n\s*/, ' ').lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
      end
      inline = text.scan(/`([^`\n]+)`/).flatten.grep(%r{\A(?:bin/|grep|jq|awk|cat|env|printenv|curl|claude|docker)})
      fenced + inline
    end

    define_method(:value_printing_commands) do |text|
      commands(text).flat_map do |command|
        value_printing.filter_map { |shape, pattern| "#{shape}: #{command}" if command.match?(pattern) }
      end
    end

    it 'recognizes each value-printing command shape' do
      bad = ['cat .env', 'env | grep WOODS', "jq '.mcpServers[] | .env' .mcp.json", 'grep -rn TOKEN .',
             'docker compose config', 'claude mcp get woods-console', 'git diff .mcp.json',
             "bin/rails runner 'p Woods.configuration'"]
      flagged = bad.map { |command| value_printing_commands("```bash\n#{command}\n```\n") }

      expect(flagged).to all(be_any)
    end

    it 'does not take the names of skipped env files for a value-printing jq program' do
      names_only = ["grep -rnoE NAME --exclude='.env*' .", 'grep -HnoE NAME .env.example .env.sample .env.template']

      expect(value_printing_commands("```bash\n#{names_only.join("\n")}\n```\n")).to eq([])
    end

    it 'gives no value-printing command in the skill or the guide section' do
      skill = read('plugin/skills/woods-console-disable/SKILL.md')
      section = read('docs/CONSOLE_MCP_SETUP.md')[/^## Turning the Console off$.*?(?=^## )/m]

      expect(value_printing_commands(skill) + value_printing_commands(section)).to eq([])
    end

    it 'runs jq only inside the key-only helpers that the fixture runs' do
      skill = read('plugin/skills/woods-console-disable/SKILL.md')
      section = read('docs/CONSOLE_MCP_SETUP.md')[/^## Turning the Console off$.*?(?=^## )/m]
      helpers = /^(woods_mcp_(?:entries|remove))\(\) \{\n.*?^\}$/m

      expect(skill.scan(helpers).flatten).to contain_exactly('woods_mcp_entries', 'woods_mcp_remove')
      [skill, section].each { |text| expect(commands(text.gsub(helpers, '')).grep(/\bjq\b/)).to eq([]) }
    end

    context 'when run against an application holding fake secrets' do
      around do |example|
        Dir.mktmpdir('woods-console-inventory') do |dir|
          @app = File.join(dir, 'app')
          @home = File.join(dir, 'home')
          write_fixture(dir)
          example.run
        end
      end

      before { skip 'jq is not installed' unless system('jq --version', out: File::NULL, err: File::NULL) }

      let(:mcp_servers) do
        {
          'woods' => { command: 'bundle', args: %w[exec woods-mcp-start], env: { 'OPENAI_API_KEY' => marker } },
          'rails-console' => { command: 'docker', args: ['exec', '-e', "TOKEN=#{marker}", 'app', 'bin/rake',
                                                         'woods:console'] },
          'console-http' => { type: 'streamable-http', url: "https://u:#{marker}@host/mcp/console?t=#{marker}",
                              headers: { 'Authorization' => "Bearer #{marker}" } },
          'bridge' => { command: 'npx', args: ['mcp-remote', 'http://localhost:3000/mcp/console/'] },
          'console-metrics' => { type: 'http', url: 'https://example.invalid/mcp/console-metrics',
                                 headers: { 'Authorization' => "Bearer #{marker}" } },
          'metrics' => { type: 'http', url: 'https://example.invalid/mcp/metrics?next=/mcp/console' },
          'status-task' => { command: 'bin/rake', args: ['woods:console_status'] }
        }
      end
      let(:user_client) do
        { projects: { '/srv/app' => { mcpServers: {
          'woods-console' => { command: 'woods-console-mcp', env: { 'WOODS_CONSOLE_CONFIG' => marker } }
        } } } }
      end
      let(:fixture_files) do
        {
          'app/config/initializers/woods.rb' => <<~RUBY,
            Woods.configure do |config|
              config.console_mcp_enabled = true
              config.console_mcp_token = '#{marker}'
              config.notion_api_token = "#{marker}"
            end
          RUBY
          'app/config/initializers/woods_env.rb' => "Woods.configuration.console_mcp_token = ENV.fetch('X')\n",
          'app/config/application.rb' => "config.middleware.use Woods::Console::RackMiddleware\n",
          'app/.env' => "WOODS_CONSOLE_MCP_TOKEN=#{marker}\n",
          'app/.env.example' => "WOODS_CONSOLE_MCP_TOKEN=\n",
          'app/config/credentials/production.key' => "console_mcp_token #{marker}\n",
          'app/Procfile.dev' => "console: WOODS_CONSOLE_MCP_TOKEN=#{marker} bin/rake woods:console\n",
          'app/compose.yml' => "services:\n  web:\n    environment:\n      WOODS_CONSOLE_MCP_TOKEN: #{marker}\n",
          'app/.mcp.json' => JSON.generate(mcpServers: mcp_servers),
          'home/.woods/console.yml' => "mode: ssh\nhost: example.test\ncommand: env TOKEN=#{marker} bin/rake\n",
          'home/.zshrc' => "export WOODS_CONSOLE_MCP_TOKEN=#{marker}\n",
          'home/.claude.json' => JSON.generate(user_client)
        }
      end

      define_method(:write_fixture) do |root|
        fixture_files.each do |relative, content|
          path = File.join(root, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end
      end

      define_method(:run_inventory) do |console_url: 'https://host/mcp/console'|
        skill = read('plugin/skills/woods-console-disable/SKILL.md')
        find = skill[/^## 1\. Find every place$.*?(?=^## 2\.)/m]
        blocks = find.scan(/^```bash\n(.*?)^```/m).flatten + [<<~BASH]
          woods_mcp_entries "$HOME/.claude.json"
          woods_secret_lines config/initializers/*.rb config/application.rb .mcp.json Procfile.dev compose.yml
        BASH
        guide = read('docs/CONSOLE_MCP_SETUP.md')[/^## Turning the Console off$.*?(?=^## )/m]
        blocks += guide.scan(/^```bash\n(.*?)^```/m).flatten
        env = { 'HOME' => @home, 'WOODS_CONSOLE_MCP_TOKEN' => marker, 'BUNDLE_GEMFILE' => nil, 'RUBYOPT' => nil,
                'CONSOLE_URL' => console_url, 'CONSOLE_PATH' => nil }
        Open3.capture3(env, 'bash', '-c', blocks.join("\n"), chdir: @app)
      end

      define_method(:kinds) do |out, scope = 'mcpServers'|
        out.lines.map { |line| line.split("\t") }.select { |row| row[0] == scope }.to_h { |row| row[1, 2] }
      end

      it 'keeps every fake secret out of the output' do
        out, err, = run_inventory

        expect(out + err).not_to include(marker)
      end

      it 'still reports each place by file, line and key name' do
        out, = run_inventory

        expect(out).to include('config/initializers/woods.rb:2:console_mcp_enabled',
                               'config/application.rb:1:Woods::Console::RackMiddleware',
                               'Procfile.dev:1:woods:console', 'WOODS_CONSOLE_MCP_TOKEN is set',
                               'console.yml keys: mode,host,command', '.zshrc:1:WOODS_CONSOLE_MCP_TOKEN')
        expect(out).to match(/^mcpServers\twoods\tindex\tfields=args,command,env\tenv=OPENAI_API_KEY\theaders=$/)
        expect(out).to match(/^mcpServers\trails-console\tconsole\t/)
        expect(out).to match(/^mcpServers\tconsole-http\tconsole\t.*\theaders=Authorization$/)
        expect(out).to match(%r{^local /srv/app\twoods-console\tconsole\t.*env=WOODS_CONSOLE_CONFIG})
      end

      it 'labels an entry console only for a Console launcher or the complete confirmed endpoint' do
        out, = run_inventory

        expect(kinds(out)).to eq('woods' => 'index', 'rails-console' => 'console', 'console-http' => 'console',
                                 'bridge' => 'unclear', 'console-metrics' => 'unclear', 'metrics' => 'other',
                                 'status-task' => 'unclear')
      end

      it 'labels the bridge console when its endpoint is the confirmed one, and the other host unclear' do
        out, = run_inventory(console_url: 'http://LOCALHOST:3000/mcp/console')

        expect(kinds(out)).to include('bridge' => 'console', 'console-http' => 'unclear')
      end

      it 'labels every HTTP entry unclear when only the Console path is known' do
        [nil, '/mcp/console'].each do |path_only|
          out, = run_inventory(console_url: path_only)

          expect(kinds(out)).to include('console-http' => 'unclear', 'bridge' => 'unclear',
                                        'rails-console' => 'console')
          expect(kinds(out, 'local /srv/app')).to eq('woods-console' => 'console')
        end
      end

      it 'lists key names in an env-file template, and never searches .env or credentials files' do
        out, = run_inventory

        expect(out).to include('.env.example:1:WOODS_CONSOLE_MCP_TOKEN')
        expect(out).not_to match(%r{(?:\A|/|\n)\.env:})
        expect(out).not_to include('credentials')
      end

      it 'flags the lines that hold a credential, and not a token read from ENV' do
        out, = run_inventory
        flagged = out.lines.map(&:strip).grep(%r{\A[\w./]+:\d+\z})

        expect(flagged).to include('config/initializers/woods.rb:3', 'config/initializers/woods.rb:4',
                                   'Procfile.dev:1', 'compose.yml:4')
        expect(flagged.grep(/\A\.mcp\.json:/)).not_to be_empty
        expect(flagged.grep(/woods_env\.rb/)).to be_empty
      end
    end

    context 'when the helper removes a client entry by key' do
      around do |example|
        Dir.mktmpdir('woods-console-remove') do |dir|
          @dir = dir
          example.run
        end
      end

      before { skip 'jq is not installed' unless system('jq --version', out: File::NULL, err: File::NULL) }

      let(:client) do
        { 'inputs' => [{ 'id' => 'key', 'type' => 'promptString' }],
          'servers' => {
            'woods' => { 'command' => 'bundle', 'args' => %w[exec woods-mcp-start],
                         'env' => { 'OPENAI_API_KEY' => marker } },
            'rails-console' => { 'type' => 'http', 'url' => "https://host/mcp/console?t=#{marker}",
                                 'headers' => { 'Authorization' => "Bearer #{marker}" } },
            'console-metrics' => { 'type' => 'http', 'url' => 'https://example.invalid/mcp/console-metrics',
                                   'headers' => { 'Authorization' => "Bearer #{marker}" } },
            'metrics' => { 'type' => 'http', 'url' => 'https://example.invalid/mcp/metrics' }
          } }
      end
      let(:pretty) { "#{JSON.pretty_generate(client)}\n" }

      define_method(:write_client) do |name, content|
        path = File.join(@dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end

      define_method(:remove) do |*args, env: { 'CONSOLE_URL' => 'https://host/mcp/console' }|
        helpers = read('plugin/skills/woods-console-disable/SKILL.md').scan(/^woods_mcp_\w+\(\) \{\n.*?^\}$/m)
        script = "#{helpers.join("\n")}\nwoods_mcp_remove #{args.map { |arg| Shellwords.escape(arg) }.join(' ')}"
        clean = { 'BUNDLE_GEMFILE' => nil, 'RUBYOPT' => nil, 'CONSOLE_URL' => nil, 'CONSOLE_PATH' => nil }
        Open3.capture3(clean.merge(env), 'bash', '-c', script, chdir: @dir)
      end

      it 'removes only that entry, keeps the layout and the mode, and prints names only' do
        path = write_client('.vscode/mcp.json', pretty)
        File.chmod(0o644, path)

        out, err, status = remove('.vscode/mcp.json', 'servers', 'rails-console')

        expect(status).to be_success
        expect(out + err).not_to include(marker)
        expect(out).to include('servers.rails-console', 'keeps: console-metrics,metrics,woods')
        kept = client.merge('servers' => client['servers'].except('rails-console'))
        expect(File.read(path)).to eq("#{JSON.pretty_generate(kept)}\n")
        expect(File.stat(path).mode & 0o777).to eq(0o644)
        expect(Dir.children(File.dirname(path))).to eq(['mcp.json'])
      end

      it 'hands the edit off, changing nothing, when jq would reformat the file' do
        compact = JSON.generate(client)
        path = write_client('.mcp.json', compact)

        out, err, status = remove('.mcp.json', 'servers', 'rails-console')

        expect(status).not_to be_success
        expect(out).to include('ask the user')
        expect(out + err).not_to include(marker)
        expect(File.read(path)).to eq(compact)
        expect(Dir.children(@dir)).to eq(['.mcp.json'])
      end

      it 'reformats only after the user agrees' do
        path = write_client('.mcp.json', JSON.generate(client))

        out, err, status = remove('.mcp.json', 'servers', 'rails-console',
                                  env: { 'CONSOLE_URL' => 'https://host/mcp/console', 'WOODS_REFORMAT_OK' => '1' })

        expect(status).to be_success
        expect(out + err).not_to include(marker)
        expect(JSON.parse(File.read(path))['servers'].keys).to eq(%w[woods console-metrics metrics])
      end

      {
        'a file with comments' => [->(dir, json) { File.write(File.join(dir, 'c.json'), "// note\n#{json}") },
                                   'c.json', 'rails-console'],
        'a symbolic link' => [->(dir, _json) { File.symlink('real.json', File.join(dir, 'link.json')) },
                              'link.json', 'rails-console'],
        'an entry that is not there' => [->(_dir, _json) {}, 'real.json', 'missing'],
        'a neighbouring HTTP server whose path only starts with the Console path' =>
          [->(_dir, _json) {}, 'real.json', 'console-metrics'],
        'an HTTP server elsewhere' => [->(_dir, _json) {}, 'real.json', 'metrics'],
        'the Index Server' => [->(_dir, _json) {}, 'real.json', 'woods']
      }.each do |form, (setup, name, entry)|
        it "hands the edit off, changing nothing, for #{form}" do
          write_client('real.json', pretty)
          setup.call(@dir, pretty)
          before = Dir.children(@dir).sort.to_h { |child| [child, File.lstat(File.join(@dir, child)).size] }

          out, err, status = remove(name, 'servers', entry)

          expect(status).not_to be_success
          expect(out).to include('make this a manual step')
          expect(out + err).not_to include(marker)
          expect(File.read(File.join(@dir, 'real.json'))).to eq(pretty)
          expect(Dir.children(@dir).sort.to_h { |child| [child, File.lstat(File.join(@dir, child)).size] })
            .to eq(before)
        end
      end

      context 'when two applications serve the Console path on different hosts' do
        let(:client) do
          { 'servers' => {
            'app-a' => { 'type' => 'http', 'url' => 'https://app-a.example/mcp/console' },
            'app-b' => { 'type' => 'http', 'url' => 'https://app-b.example/mcp/console' }
          } }
        end
        let(:app_a) { { 'CONSOLE_URL' => 'https://app-a.example/mcp/console' } }

        it 'removes the confirmed application and keeps the other registered' do
          path = write_client('.mcp.json', pretty)

          out, _, status = remove('.mcp.json', 'servers', 'app-a', env: app_a)

          expect(status).to be_success
          expect(out).to include('keeps: app-b')
          expect(JSON.parse(File.read(path))['servers']).to eq('app-b' => client['servers']['app-b'])
        end

        it 'refuses the other application, changing nothing' do
          path = write_client('.mcp.json', pretty)

          out, _, status = remove('.mcp.json', 'servers', 'app-b', env: app_a)

          expect(status).not_to be_success
          expect(out).to include('make this a manual step')
          expect(File.read(path)).to eq(pretty)
        end
      end

      {
        'the confirmed endpoint' =>
          ['https://app-a.example/mcp/console', 'https://app-a.example/mcp/console', true],
        'the default port, host case and a trailing slash written out' =>
          ['https://app-a.example/mcp/console', 'https://App-A.example:443/mcp/console/', true],
        'a default port in the confirmed URL, and a query on the entry' =>
          ['http://app-a.example:80/mcp/console', 'http://app-a.example/mcp/console?x=1', true],
        'another host at the same path' =>
          ['https://app-a.example/mcp/console', 'https://app-b.example/mcp/console', false],
        'the same host on another port' =>
          ['http://localhost:3000/mcp/console', 'http://localhost:3001/mcp/console', false],
        'the same host over another scheme' =>
          ['https://app-a.example/mcp/console', 'http://app-a.example/mcp/console', false],
        'a confirmed Console path with no host' =>
          ['/mcp/console', 'https://app-a.example/mcp/console', false],
        'no confirmed Console URL' =>
          [nil, 'https://app-a.example/mcp/console', false]
      }.each do |form, (confirmed, url, removed)|
        it "#{removed ? 'removes' : 'refuses'} an HTTP entry for #{form}" do
          path = write_client('.mcp.json', "#{JSON.pretty_generate('servers' => { 'app' => { 'url' => url } })}\n")

          _, _, status = remove('.mcp.json', 'servers', 'app', env: { 'CONSOLE_URL' => confirmed })

          expect(status.success?).to be(removed)
          expect(JSON.parse(File.read(path))['servers'].key?('app')).to be(!removed)
        end
      end
    end
  end

  describe 'plugin skill frontmatter' do
    Dir[File.expand_path('../plugin/skills/*/SKILL.md', __dir__)].each do |path|
      skill = File.basename(File.dirname(path))

      it "names #{skill} after its directory and gives it a description" do
        frontmatter = File.read(path, encoding: Encoding::UTF_8)[/\A---\n(.*?)\n---\n/m, 1]

        expect(frontmatter).to match(/^name: #{Regexp.escape(skill)}$/)
        expect(frontmatter).to match(/^description: \S/)
      end
    end
  end
end
