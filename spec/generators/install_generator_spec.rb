# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods/version'

# Test the generator template output without Rails generators framework
RSpec.describe 'Install generator template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/woods/templates/create_woods_tables.rb.erb', __dir__)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'template contains CreateWoodsTables class' do
    content = File.read(template_path)
    expect(content).to include('class CreateWoodsTables')
  end

  it 'template creates woods_units table' do
    content = File.read(template_path)
    expect(content).to include('create_table :woods_units')
  end

  it 'template creates woods_edges table' do
    content = File.read(template_path)
    expect(content).to include('create_table :woods_edges')
  end

  it 'template creates woods_embeddings table' do
    content = File.read(template_path)
    expect(content).to include('create_table :woods_embeddings')
  end

  it 'template includes indexes' do
    content = File.read(template_path)
    expect(content).to include('add_index :woods_units')
    expect(content).to include('add_index :woods_edges')
  end
end

RSpec.describe 'Install generator initializer template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/woods/templates/woods.rb.tt', __dir__)
  end
  # The template file has Unicode box-drawing characters in section headers
  # (── and em-dashes). Force UTF-8 so regex matches don't raise
  # "invalid byte sequence in US-ASCII" on environments where
  # Encoding.default_external is US-ASCII.
  let(:content) { File.read(template_path, encoding: 'UTF-8') }

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'template calls Woods.configure' do
    expect(content).to include('Woods.configure do |config|')
  end

  it 'template sets output_dir relative to Rails.root' do
    expect(content).to include('Rails.root.join')
    expect(content).to include('tmp/woods')
  end

  it 'template mentions configure_with_preset idiom' do
    expect(content).to include('configure_with_preset')
  end

  it 'template covers console_mcp options' do
    expect(content).to include('console_mcp_enabled')
    expect(content).to include('console_redacted_columns')
  end

  it 'template keeps console MCP disabled by default' do
    # The enable line must be commented out
    expect(content).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end

  it 'template mentions all three defense layers' do
    expect(content).to include('Layer 1')
    expect(content).to include('Layer 2')
    expect(content).to include('Layer 3')
  end

  # F8: TokenCounter is exact only with an injected, model-matched tokenizer;
  # nothing in the gem loads the `tokenizers` gem on its own.
  it 'does not promise exact token counts from installing the tokenizers gem' do
    expect(content).not_to match(/Install `gem "tokenizers"`/)
    expect(content).to include('estimates')
    expect(content).to include('Woods::Embedding::TokenCounter')
  end

  it 'has frozen_string_literal comment' do
    expect(content).to start_with('# frozen_string_literal: true')
  end
end

# The generator runs in a child process, as spec/generators/watch_generator_spec.rb
# does: loading a partial Rails constant in the default suite changes unrelated
# MCP runtime detection. The repository bundle carries railties but not Active
# Record, which is exactly the host the default install path must work on
# (#618); the legacy migration needs Active Record and runs under a Rails
# appraisal row (`WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_8.1.gemfile`).
RSpec.describe 'Install generator' do
  around do |example|
    Dir.mktmpdir('woods install generator ') do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  def generate(*arguments, behavior: 'invoke')
    repo = File.expand_path('../..', __dir__)
    gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', 'Gemfile'), repo)
    environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => gemfile, 'BUNDLE_LOCKFILE' => "#{gemfile}.lock")
    script = <<~SCRIPT
      require 'bundler/setup'
      require 'generators/woods/install_generator'
      root, behavior = ARGV.shift(2)
      Woods::Generators::InstallGenerator.start(ARGV, destination_root: root, behavior: behavior.to_sym)
      puts "active_record_loaded=\#{defined?(ActiveRecord) ? 'yes' : 'no'}"
    SCRIPT
    Open3.capture3(environment, Gem.ruby, '-I', File.join(repo, 'lib'), '-e', script,
                   @root, behavior, *arguments, unsetenv_others: true)
  end

  def active_record_in_bundle?
    _, _, status = generate('--pretend', '--legacy-migration')
    status.success?
  end

  def written_files
    Dir.glob('**/*', base: @root).select { |path| File.file?(File.join(@root, path)) }.sort
  end

  it 'writes only the initializer by default, without loading Active Record' do
    stdout, stderr, status = generate

    expect(status.success?).to be(true), stderr
    expect(written_files).to eq(['config/initializers/woods.rb'])
    expect(stdout).to include('active_record_loaded=no')
    initializer = File.read(File.join(@root, 'config/initializers/woods.rb'), encoding: 'UTF-8')
    expect(initializer).to include('Woods.configure do |config|')
    expect(initializer).to include("blob/v#{Woods::VERSION}/docs/")
  end

  it 'leaves an identical initializer alone on a repeat run' do
    _, stderr, status = generate
    expect(status.success?).to be(true), stderr
    before = File.read(File.join(@root, 'config/initializers/woods.rb'), encoding: 'UTF-8')

    stdout, stderr, status = generate

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('identical')
    expect(File.read(File.join(@root, 'config/initializers/woods.rb'), encoding: 'UTF-8')).to eq(before)
    expect(written_files).to eq(['config/initializers/woods.rb'])
  end

  it 'writes nothing under --pretend' do
    stdout, stderr, status = generate('--pretend')

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('config/initializers/woods.rb')
    expect(written_files).to be_empty
  end

  it 'preserves existing application migrations during skipped legacy and pretend installs', :booted_app do
    skip 'the legacy migration needs Active Record in the bundle' unless active_record_in_bundle?

    migration = File.join(@root, 'db/migrate/20200101000000_create_woods_tables.rb')
    FileUtils.mkdir_p(File.dirname(migration))
    existing_source = "# An existing host application migration\n"
    File.write(migration, existing_source)

    [[], ['--pretend'], []].each do |arguments|
      stdout, stderr, status = generate('--legacy-migration', '--skip', *arguments)

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(%r{skip\s+db/migrate/\d+_create_woods_tables\.rb})
      expect(File.read(migration)).to eq(existing_source)
      expect(written_files).to eq(['config/initializers/woods.rb', 'db/migrate/20200101000000_create_woods_tables.rb'])
    end
  end

  it 'refuses --legacy-migration before writing anything when Active Record is not available' do
    skip 'Active Record is in this bundle; the refusal needs a railties-only bundle' if active_record_in_bundle?

    _, stderr, status = generate('--legacy-migration')

    expect(status.success?).to be(false)
    expect(stderr).to include('--legacy-migration needs Active Record')
    expect(written_files).to be_empty
  end

  it 'writes the legacy migration once, and only on --legacy-migration', :booted_app do
    skip 'the legacy migration needs Active Record in the bundle' unless active_record_in_bundle?

    _, stderr, status = generate('--legacy-migration')
    expect(status.success?).to be(true), stderr

    migrations = Dir.glob('db/migrate/*_create_woods_tables.rb', base: @root)
    expect(migrations.size).to eq(1)
    migration = File.read(File.join(@root, migrations.first), encoding: 'UTF-8')
    expect(migration).to match(/class CreateWoodsTables < ActiveRecord::Migration\[\d+\.\d+\]/)
    expect(migration).to include('create_table :woods_units')

    _, stderr, status = generate('--legacy-migration')
    expect(status.success?).to be(true), stderr
    expect(Dir.glob('db/migrate/*_create_woods_tables.rb', base: @root).size).to eq(1)

    _, stderr, status = generate
    expect(status.success?).to be(true), stderr
    expect(written_files.grep(%r{\Adb/migrate/}).size).to eq(1)
  end

  # A committed .mcp.json must work unchanged in every checkout and worktree,
  # on every machine: no absolute path and no `cwd`.
  describe 'the MCP client entry' do
    def mcp_path
      File.join(@root, '.mcp.json')
    end

    def mcp_json
      JSON.parse(File.read(mcp_path))
    end

    def strings_in(value)
      case value
      when Hash then value.values.flat_map { |item| strings_in(item) }
      when Array then value.flat_map { |item| strings_in(item) }
      else [value]
      end
    end

    # Claude Code sets CLAUDE_PROJECT_DIR only in the server's environment
    # and rewrites `${...}` in args from its own, so the entry reads it in sh.
    let(:project_dir) { 'if [ -n "$CLAUDE_PROJECT_DIR" ]; then cd "$CLAUDE_PROJECT_DIR" || exit 1; fi; ' }
    let(:launch) { 'bundle exec woods-mcp-start --checkout --await-index' }
    # What the client's checkout is, with no path: worktree kind, HEAD, branch.
    let(:client_identity) do
      'id="$(test -f "$(git rev-parse --show-toplevel 2>/dev/null)/.git" && echo linked || echo main)' \
        ':$(git rev-parse --verify -q HEAD 2>/dev/null):$(git branch --show-current 2>/dev/null)"; '
    end
    let(:host_entry) { { 'type' => 'stdio', 'command' => 'sh', 'args' => ['-c', "#{project_dir}exec #{launch}"] } }

    it 'prints the host entry and writes no .mcp.json by default' do
      stdout, stderr, status = generate

      expect(status.success?).to be(true), stderr
      expect(File.exist?(mcp_path)).to be(false)
      printed = JSON.parse(stdout[/^\{\n  "mcpServers".*?^\}$/m])
      expect(printed.dig('mcpServers', 'woods')).to eq(host_entry)
    end

    it 'writes the host entry with --mcp-config, with no absolute path and no cwd' do
      stdout, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(/create\s+\.mcp\.json/)
      entry = mcp_json.dig('mcpServers', 'woods')
      expect(entry).to eq(host_entry)
      expect(strings_in(entry).grep(%r{\A/})).to be_empty
      expect(strings_in(entry).join).not_to include('${', @root)
    end

    it 'writes the container entry for --mcp-service, handing over the session directory and any mount map' do
      _, stderr, status = generate('--mcp-config', '--mcp-service', 'web')

      expect(status.success?).to be(true), stderr
      entry = mcp_json.dig('mcpServers', 'woods')
      expect(entry).to eq(
        'type' => 'stdio', 'command' => 'sh',
        'args' => ['-c', "#{project_dir}#{client_identity}exec docker compose exec -T " \
                         '-e WOODS_MCP_CLIENT_ROOT_MAP="$WOODS_MCP_CLIENT_ROOT_MAP" web ' \
                         "#{launch} --client-root \"$PWD\" --client-identity \"$id\""]
      )
      expect(entry).not_to have_key('cwd')
      expect(strings_in(entry).join).not_to include('${')
    end

    it 'refuses a service name that is not a plain Compose service name' do
      _, stderr, status = generate('--mcp-config', '--mcp-service', 'web; rm -r .')

      expect(status.success?).to be(false)
      expect(stderr).to include('--mcp-service')
      expect(File.exist?(mcp_path)).to be(false)
    end

    it 'adds the woods entry to an existing .mcp.json and keeps every other server' do
      File.write(mcp_path, JSON.pretty_generate('mcpServers' => { 'other' => { 'command' => 'other-server' } }))

      stdout, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(/merge\s+\.mcp\.json/)
      expect(mcp_json['mcpServers']).to eq('other' => { 'command' => 'other-server' }, 'woods' => host_entry)
    end

    it 'leaves an identical entry alone' do
      generate('--mcp-config')
      before = File.read(mcp_path)

      stdout, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(/identical\s+\.mcp\.json/)
      expect(File.read(mcp_path)).to eq(before)
    end

    {
      'a different woods entry' => JSON.pretty_generate('mcpServers' => { 'woods' => { 'command' => 'custom' } }),
      'malformed JSON' => '{"mcpServers": ',
      'a non-object mcpServers' => JSON.generate('mcpServers' => [])
    }.each do |label, content|
      it "never overwrites #{label}, and says what to add" do
        File.write(mcp_path, content)

        stdout, stderr, status = generate('--mcp-config')

        expect(status.success?).to be(true), stderr
        expect(stdout).to match(/skip\s+\.mcp\.json/)
        expect(stdout).to include('woods-mcp-start --checkout --await-index')
        expect(File.read(mcp_path)).to eq(content)
      end
    end

    it 'skips a .mcp.json that exists but cannot be read, and says what to add' do
      FileUtils.mkdir_p(mcp_path)

      stdout, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(/skip\s+\.mcp\.json \(it cannot be read: /)
      expect(stdout).to include('woods-mcp-start --checkout --await-index')
      expect(File.directory?(mcp_path)).to be(true)
    end

    it 'leaves a .mcp.json managed by woods-agent-config to that tool' do
      content = JSON.pretty_generate('mcpServers' => {})
      File.write(mcp_path, content)
      File.write(File.join(@root, '.woods-agent-config.json'), '{}')

      stdout, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(/skip\s+\.mcp\.json/)
      expect(stdout).to include('woods-agent-config')
      expect(File.read(mcp_path)).to eq(content)
    end

    it 'adds .mcp.json on a re-run with --skip, leaving an edited initializer alone' do
      generate
      initializer = File.join(@root, 'config/initializers/woods.rb')
      File.write(initializer, "# edited by the application\n")

      stdout, stderr, status = generate('--mcp-config', '--skip')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(%r{skip\s+config/initializers/woods\.rb})
      expect(File.read(initializer)).to eq("# edited by the application\n")
      expect(mcp_json.dig('mcpServers', 'woods')).to eq(host_entry)
    end

    it 'leaves .mcp.json to woods-agent-config when its receipt exists, even with no .mcp.json yet' do
      File.write(File.join(@root, '.woods-agent-config.json'), '{}')

      stdout, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      expect(stdout).to match(/skip\s+\.mcp\.json/)
      expect(File.exist?(mcp_path)).to be(false)
    end

    it 'hands the index location of an application below its checkout root to a container launch' do
      checkout = @root
      FileUtils.mkdir_p(File.join(checkout, '.git'))
      @root = File.join(checkout, 'apps', 'my web')
      FileUtils.mkdir_p(@root)

      _, stderr, status = generate('--mcp-config', '--mcp-service', 'web')

      expect(status.success?).to be(true), stderr
      entry = mcp_json.dig('mcpServers', 'woods')
      expect(entry.dig('args', 1)).to include('-e WOODS_OUTPUT=apps/my\\ web/tmp/woods web ')
      expect(entry.dig('args', 1)).to include('cd "$(git rev-parse --show-toplevel)"/apps/my\\ web || exit 1; ')
      expect(entry).not_to have_key('env')
    end

    it 'notes that --checkout needs a git checkout when the application is not in one yet' do
      stdout, stderr, status = generate

      expect(status.success?).to be(true), stderr
      expect(stdout).to include('not inside a git checkout')
    end

    it 'writes nothing under --pretend, and nothing on destroy' do
      _, stderr, status = generate('--mcp-config', '--pretend')
      expect(status.success?).to be(true), stderr
      expect(File.exist?(mcp_path)).to be(false)

      File.write(mcp_path, JSON.pretty_generate('mcpServers' => { 'other' => { 'command' => 'x' } }))
      before = File.read(mcp_path)
      _, stderr, status = generate('--mcp-config', behavior: 'revoke')

      expect(status.success?).to be(true), stderr
      expect(File.read(mcp_path)).to eq(before)
    end

    it 'names the index of an application below its checkout root without an absolute path' do
      checkout = @root
      FileUtils.mkdir_p(File.join(checkout, '.git'))
      @root = File.join(checkout, 'apps', 'web')
      FileUtils.mkdir_p(@root)

      _, stderr, status = generate('--mcp-config')

      expect(status.success?).to be(true), stderr
      # Bundler looks for the Gemfile up from the working directory, never
      # down, so the launch changes into the application from the checkout root.
      into_application = 'cd "$(git rev-parse --show-toplevel)"/apps/web || exit 1; '
      expect(mcp_json.dig('mcpServers', 'woods'))
        .to eq('type' => 'stdio', 'command' => 'sh',
               'args' => ['-c', "#{project_dir}#{into_application}exec #{launch}"],
               'env' => { 'WOODS_OUTPUT' => 'apps/web/tmp/woods' })
    end

    def generate_with_output_dir(output_dir, *arguments)
      repo = File.expand_path('../..', __dir__)
      gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', 'Gemfile'), repo)
      environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => gemfile, 'BUNDLE_LOCKFILE' => "#{gemfile}.lock")
      script = <<~SCRIPT
        require 'bundler/setup'
        require 'woods'
        require 'generators/woods/install_generator'
        root, output_dir = ARGV.shift(2)
        Woods.configuration.output_dir = output_dir
        Woods::Generators::InstallGenerator.start(ARGV, destination_root: root)
      SCRIPT
      Open3.capture3(environment, Gem.ruby, '-I', File.join(repo, 'lib'), '-e', script,
                     @root, output_dir, *arguments, unsetenv_others: true)
    end

    it 'follows a configured output_dir inside the application, and says why it cannot outside it' do
      FileUtils.mkdir_p(File.join(@root, '.git'))

      _, stderr, status = generate_with_output_dir(File.join(@root, 'var', 'index'), '--mcp-config')
      expect(status.success?).to be(true), stderr
      expect(mcp_json.dig('mcpServers', 'woods', 'env')).to eq('WOODS_OUTPUT' => 'var/index')

      FileUtils.rm(mcp_path)
      stdout, stderr, status = generate_with_output_dir('/srv/shared-index', '--mcp-config')
      expect(status.success?).to be(true), stderr
      expect(stdout).to include('output_dir /srv/shared-index is outside the checkout')
      expect(mcp_json.dig('mcpServers', 'woods')).not_to have_key('env')
    end

    # A checkout root resolves symlinks, so the application root and the
    # output_dir are compared resolved too: reached through a link, an index
    # inside the checkout is still inside it.
    it 'follows an output_dir inside the checkout when the application is reached through a symlink' do
      real = File.join(@root, 'real')
      FileUtils.mkdir_p(File.join(real, '.git'))
      link = File.join(@root, 'link')
      File.symlink(real, link)
      @root = link

      ['var/index', File.join(link, 'var', 'index')].each do |output_dir|
        FileUtils.rm_f(mcp_path)
        stdout, stderr, status = generate_with_output_dir(output_dir, '--mcp-config')

        expect(status.success?).to be(true), stderr
        expect(stdout).not_to include('outside the checkout')
        expect(mcp_json.dig('mcpServers', 'woods', 'env')).to eq('WOODS_OUTPUT' => 'var/index')
      end
    end

    it 'writes the same bytes in two checkouts and a linked worktree' do
      roots = [File.join(@root, 'one'), File.join(@root, 'two')]
      roots.each do |root|
        FileUtils.mkdir_p(root)
        _, status = Open3.capture2e('git', 'init', '-q', root)
        expect(status.success?).to be(true)
      end
      Open3.capture2e('git', '-C', roots.first, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com',
                      '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'init')
      worktree = File.join(@root, 'one-topic')
      _, status = Open3.capture2e('git', '-C', roots.first, 'worktree', 'add', '-q', '-b', 'topic', worktree)
      expect(status.success?).to be(true)

      outputs = [*roots, worktree].map do |root|
        @root = root
        _, stderr, status = generate('--mcp-config')
        expect(status.success?).to be(true), stderr
        File.read(mcp_path)
      end

      expect(outputs.uniq.size).to eq(1)
    end
  end
end

# An unreadable file is not an absent one: the generator never creates over it.
RSpec.describe 'Woods::Generators::McpConfiguration.skip_reason' do
  it 'names a read the file system refuses, distinct from an absent file' do
    require 'generators/woods/mcp_configuration'
    Dir.mktmpdir('woods mcp configuration ') do |root|
      path = File.join(root, '.mcp.json')
      File.write(path, '{}')
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(path).and_raise(Errno::EACCES, path)

      reason = Woods::Generators::McpConfiguration.skip_reason(root, path, {})

      expect(reason).to start_with('it cannot be read: ').and include('Permission denied')
      expect(Woods::Generators::McpConfiguration.skip_reason(root, File.join(root, 'absent.json'), {}))
        .to eq(:absent)
    end
  end
end
