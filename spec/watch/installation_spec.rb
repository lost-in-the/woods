# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'woods/watch/installation'

RSpec.describe Woods::Watch::Installation do
  around do |example|
    Dir.mktmpdir('woods installation ') do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, 'bin'))
      FileUtils.mkdir_p(File.join(root, 'config'))
      File.write(File.join(root, 'Gemfile'), "source 'https://rubygems.org'\n")
      File.write(File.join(root, 'bin/rails'), "#!/usr/bin/env ruby\n")
      File.chmod(0o755, File.join(root, 'bin/rails'))
      File.write(File.join(root, 'bin/dev'), "#!/bin/sh\nexec bin/rails server\n")
      File.write(File.join(root, 'Procfile.dev'), "web: bin/rails server\ncss: bin/css\n")
      File.write(File.join(root, 'config/puma.rb'), "threads 3, 3\n")
      example.run
    end
  end

  let(:probe) { instance_double(described_class::Probe, call: true) }

  def installer(**options)
    described_class.new(root: @root, mode: 'procfile',
                        manager_command: %w[foreman start -f Procfile.dev], probe: probe, **options)
  end

  def read(path)
    File.read(File.join(@root, path))
  end

  def tree
    Dir.glob(File.join(@root, '**/*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{@root}/"), [File.binread(path), File.stat(path).mode & 0o777]] }
  end

  def legacy_puma_setup(prefix: "threads 3, 3\n", suffix: '', newline: "\n")
    path = File.join(@root, 'config/puma.rb')
    prefix ? File.write(path, prefix) : File.unlink(path)
    installer(mode: 'puma').apply
    receipt = JSON.parse(read('.woods-watch.json'))
    separator = prefix.to_s.empty? || prefix.end_with?(newline) ? '' : newline
    block = separator + ['# woods:watch:managed:start', 'plugin :woods if Gem.loaded_specs.key?("woods")',
                         '# woods:watch:managed:end', ''].join(newline)
    receipt.fetch('sections').fetch('config/puma.rb')['owned_text'] = block
    File.write(path, prefix.to_s + block + suffix)
    File.write(File.join(@root, '.woods-watch.json'), "#{JSON.pretty_generate(receipt)}\n")
    block
  end

  it 'previews without changing any file or creating runtime locks' do
    before = tree
    plan = installer.plan

    expect(plan.summary.fetch('changes').map { |change| change.fetch('action') }).to all(eq('write'))
    expect(tree).to eq(before)
    expect(probe).to have_received(:call)
  end

  it 'preserves normal startup and unrelated services while installing an executable wrapper' do
    before_dev = read('bin/dev')
    installer.apply

    expect(read('bin/dev')).to eq(before_dev)
    expect(read('Procfile.dev')).to start_with("web: bin/rails server\ncss: bin/css\n")
    expect(read('Procfile.dev')).to include('woods: bin/woods-watch')
    expect(File.stat(File.join(@root, 'bin/woods-watch')).mode & 0o777).to eq(0o755)
    expect(read('bin/woods-watch')).to include("Gem.bin_path('woods', 'woods-watch')", 'Gem.ruby')
    expect(read('.woods-watch.json')).not_to include(@root)
  end

  it 'is idempotent and does not change another service added after setup' do
    installer.apply
    File.open(File.join(@root, 'Procfile.dev'), 'a') { |file| file.puts('worker: bin/jobs') }
    before = tree

    expect(installer.apply).to eq('already_applied')
    expect(tree).to eq(before)
  end

  it 'requires explicit update to switch mode and removes only its previous entry' do
    installer.apply
    expect { installer(mode: 'puma').apply }.to raise_error(described_class::Conflict, /update/)

    installer(mode: 'puma', operation: 'update').apply
    expect(read('Procfile.dev')).to eq("web: bin/rails server\ncss: bin/css\n")
    expect(read('config/puma.rb')).to include('plugin :woods if Gem.loaded_specs["woods"]&.full_require_paths')
    expect(read('bin/dev')).to include('exec bin/rails server')
  end

  ["\n", "\r\n"].product([true, false]).each do |newline, trailing_newline|
    it "updates an old Puma guard in place with newline=#{newline.inspect}, trailing_newline=#{trailing_newline}" do
      prefix = "# application#{newline}threads 3, 3#{newline if trailing_newline}"
      suffix = "\n# user appended this with LF\n"
      old_block = legacy_puma_setup(prefix: prefix, suffix: suffix, newline: newline)
      before = tree

      expect(installer(mode: 'puma').apply).to eq('already_applied')
      expect(tree).to eq(before)
      installer(mode: 'puma', operation: 'update').apply

      block = JSON.parse(read('.woods-watch.json')).fetch('sections').fetch('config/puma.rb').fetch('owned_text')
      expect(block).not_to eq(old_block)
      expect(block).to include('puma/plugin/woods.rb')
      first_line = block.delete_prefix(trailing_newline ? '' : newline).lines.first
      expect(first_line).to eq("# woods:watch:managed:start#{newline}")
      expect(block.lines).to all(end_with(newline))
      expect(read('config/puma.rb')).to eq(prefix + block + suffix)
      expect(installer(mode: 'puma', operation: 'update').apply).to eq('already_applied')
      installer(operation: 'remove').apply
      expect(read('config/puma.rb')).to eq(prefix + suffix)
    end
  end

  it 'upgrades and removes a legacy owned setup copied to a different worktree' do
    legacy_puma_setup
    Dir.mktmpdir('woods legacy clone ') do |clone|
      files = Dir.glob(File.join(@root, '*'), File::FNM_DOTMATCH)
                 .reject { |path| %w[. .. tmp].include?(File.basename(path)) }
      FileUtils.cp_r(files, clone)
      old_root = @root
      @root = clone

      installer(mode: 'puma', operation: 'update').apply
      expect(read('config/puma.rb')).to include('puma/plugin/woods.rb')
      expect(read('.woods-watch.json')).not_to include(old_root, clone)
      installer(operation: 'remove').apply
      expect(read('config/puma.rb')).to eq("threads 3, 3\n")
    ensure
      @root = old_root
    end
  end

  it 'refuses an edited legacy guard without changing files during update' do
    legacy_puma_setup
    File.write(File.join(@root, 'config/puma.rb'), read('config/puma.rb').sub('plugin :woods', 'plugin :custom'))
    before = tree

    expect { installer(mode: 'puma', operation: 'update').apply }
      .to raise_error(described_class::Conflict, /edited/)
    expect(tree).to eq(before)
  end

  ['', "threads 5, 5\n"].each do |suffix|
    it "retains created-file ownership after upgrading, with user suffix #{suffix.inspect}" do
      legacy_puma_setup(prefix: nil, suffix: suffix)

      installer(mode: 'puma', operation: 'update').apply
      expect(read('config/puma.rb')).to include('puma/plugin/woods.rb')
      installer(operation: 'remove').apply

      if suffix.empty?
        expect(File.exist?(File.join(@root, 'config/puma.rb'))).to be(false)
      else
        expect(read('config/puma.rb')).to eq(suffix)
      end
    end
  end

  it 'removes its setup without probing a now broken application or changing unrelated content' do
    installer.apply
    File.open(File.join(@root, 'Procfile.dev'), 'a') { |file| file.puts('worker: bin/jobs') }
    File.unlink(File.join(@root, 'Gemfile'))
    allow(probe).to receive(:call).and_raise('must not boot or probe on removal')

    installer(operation: 'remove').apply

    expect(read('Procfile.dev')).to eq("web: bin/rails server\ncss: bin/css\nworker: bin/jobs\n")
    expect(File.exist?(File.join(@root, 'bin/woods-watch'))).to be(false)
    expect(File.exist?(File.join(@root, '.woods-watch.json'))).to be(false)
  end

  it 'refuses edited owned sections before making any change' do
    installer.apply
    File.write(File.join(@root, 'Procfile.dev'), read('Procfile.dev').sub('woods: bin/woods-watch', 'woods: custom'))
    before = tree

    expect { installer(operation: 'remove').apply }.to raise_error(described_class::Conflict, /edited/)
    expect(tree).to eq(before)
  end

  it 'refuses changed executable permissions as an ownership conflict' do
    installer.apply
    File.chmod(0o644, File.join(@root, 'bin/woods-watch'))

    expect { installer(operation: 'update').apply }.to raise_error(described_class::Conflict, /edited/)
  end

  it 'does not overwrite an unowned wrapper or Woods process entry' do
    File.write(File.join(@root, 'bin/woods-watch'), 'custom launcher')
    expect { installer.apply }.to raise_error(described_class::Conflict, /unowned/i)
    File.unlink(File.join(@root, 'bin/woods-watch'))
    File.open(File.join(@root, 'Procfile.dev'), 'a') { |file| file.puts('woods: custom') }
    expect { installer.apply }.to raise_error(described_class::Conflict, /unowned/i)
  end

  it 'refuses an existing Puma plugin directive including parenthesized Ruby calls' do
    File.write(File.join(@root, 'config/puma.rb'), "threads 3, 3\nplugin(:woods)\n")
    before = tree

    expect { installer(mode: 'puma').apply }.to raise_error(described_class::Conflict, /Unowned Woods startup/)
    expect(tree).to eq(before)
  end

  it 'refuses an environment-specific Puma config that would bypass its generated directive' do
    FileUtils.mkdir_p(File.join(@root, 'config/puma'))
    File.write(File.join(@root, 'config/puma/development.rb'), "threads 1, 1\n")
    before = tree

    expect { installer(mode: 'puma').apply }
      .to raise_error(described_class::Conflict, %r{selects config/puma/development.rb})
    expect(tree).to eq(before)
  end

  it 'requires supported Puma from the selected bundle before writing its configuration' do
    allow(probe).to receive(:call).with(root: @root, child_command: %w[bin/rails woods:watch],
                                        manager_command: nil, puma: true)
                                  .and_raise(described_class::Conflict, 'Puma is unavailable')
    before = tree

    expect { installer(mode: 'puma').apply }.to raise_error(described_class::Conflict, /Puma is unavailable/)
    expect(tree).to eq(before)
  end

  it 'refuses a stale preview and retains an edit made after preview' do
    installation = installer
    plan = installation.plan
    File.open(File.join(@root, 'Procfile.dev'), 'a') { |file| file.puts('worker: bin/jobs') }

    expect { installation.apply(plan) }.to raise_error(described_class::Conflict, /Changed since preview/)
    expect(read('Procfile.dev')).to end_with("worker: bin/jobs\n")
    expect(File.exist?(File.join(@root, 'bin/woods-watch'))).to be(false)
  end

  it 'updates and removes committed setup from a different worktree without the original path' do
    installer.apply
    Dir.mktmpdir('woods cloned ') do |clone|
      FileUtils.cp_r(Dir.glob(File.join(@root, '*'), File::FNM_DOTMATCH).reject do |path|
        %w[. .. tmp].include?(File.basename(path))
      end, clone)
      old_root = @root
      @root = clone
      installer(operation: 'update', mode: 'puma').apply
      expect(read('.woods-watch.json')).not_to include(old_root, clone)
      installer(operation: 'remove').apply
      expect(read('config/puma.rb')).to eq("threads 3, 3\n")
      expect(File.exist?(File.join(clone, 'bin/woods-watch'))).to be(false)
    ensure
      @root = old_root
    end
  end

  it 'keeps external setup separate from managed supervision' do
    before_procfile = read('Procfile.dev')
    installation = installer(mode: 'external')
    installation.apply

    expect(read('Procfile.dev')).to eq(before_procfile)
    expect(installation.handoff).to include('bin/rails woods:watch', 'external supervisor')
    expect(File.exist?(File.join(@root, 'bin/woods-watch'))).to be(false)
  end

  it 'refuses an unverified Procfile workflow instead of changing plain Rails bin/dev' do
    before = tree
    expect { installer(manager_command: nil).apply }.to raise_error(described_class::Conflict, /Foreman.*Puma/m)
    expect(tree).to eq(before)
  end

  it 'rejects a different selected Procfile and refuses shell operators' do
    expect { installer(manager_command: %w[foreman start -f Procfile.other]).apply }
      .to raise_error(described_class::Conflict, /Procfile/)
    expect { installer(manager_command: ['foreman', 'start', ';', 'touch', 'oops']).apply }
      .to raise_error(described_class::Conflict, /Foreman/)
  end

  it 'rejects managed idle shutdown before writing files, but allows it in external mode' do
    before = tree
    expect { installer(environment: { 'WOODS_WATCH_IDLE_TIMEOUT' => '0' }).apply }
      .to raise_error(described_class::Conflict, /IDLE_TIMEOUT/)
    expect(tree).to eq(before)
    expect { installer(mode: 'external', environment: { 'WOODS_WATCH_IDLE_TIMEOUT' => '10' }).apply }.not_to raise_error
  end

  ['', " \t "].each do |blank|
    it "accepts a blank managed idle TTL #{blank.inspect}" do
      expect { installer(environment: { 'WOODS_WATCH_IDLE_TIMEOUT' => blank }).apply }.not_to raise_error
    end
  end

  it 'does not follow a symlink target outside the application' do
    File.unlink(File.join(@root, 'Procfile.dev'))
    File.symlink(File::NULL, File.join(@root, 'Procfile.dev'))
    expect { installer.apply }.to raise_error(described_class::Conflict, /Symlink/)
  end

  it 'rejects forged ownership paths before applying any removal' do
    installer.apply
    receipt = JSON.parse(read('.woods-watch.json'))
    receipt['sections']['../outside'] = receipt['sections'].values.first
    File.write(File.join(@root, '.woods-watch.json'), JSON.generate(receipt))
    before = tree

    expect { installer(operation: 'remove').apply }.to raise_error(described_class::Conflict, /Invalid owned/)
    expect(tree).to eq(before)
  end

  it 'preserves custom task arguments as literal argv and locates the app when launched elsewhere' do
    installer(child_command: ['bin/rails', '-f', 'tasks with spaces.rb', 'woods:watch']).apply
    fake = File.join(@root, 'capture.rb')
    File.write(fake, "require 'json'; puts JSON.generate(argv: ARGV, cwd: Dir.pwd)\n")
    interception = File.join(@root, 'gem_path.rb')
    File.write(interception, <<~RUBY)
      module WoodsExecCapture
        def bin_path(name, executable, *)
          return #{fake.inspect} if name == 'woods' && executable == 'woods-watch'
          super
        end
      end
      Gem.singleton_class.prepend(WoodsExecCapture)
    RUBY
    environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => File.join(@root, 'Gemfile'),
                                              'BUNDLE_LOCKFILE' => File.join(@root, 'Gemfile.lock'))
    stdout, stderr, status = Open3.capture3(environment, Gem.ruby, '-r', interception,
                                            File.join(@root, 'bin/woods-watch'), '--boot-timeout', '45',
                                            chdir: '/', unsetenv_others: true)
    expect(status.success?).to be(true), stderr
    expect(JSON.parse(stdout)).to eq('cwd' => @root,
                                     'argv' => ['--root', @root, '--boot-timeout', '45', '--',
                                                'bin/rails', '-f', 'tasks with spaces.rb', 'woods:watch'])
  end

  it 'preserves a custom application edit made to a generated Puma file' do
    File.unlink(File.join(@root, 'config/puma.rb'))
    installer(mode: 'puma').apply
    File.open(File.join(@root, 'config/puma.rb'), 'a') { |file| file.puts('threads 5, 5') }

    installer(operation: 'remove').apply
    expect(read('config/puma.rb')).to eq("threads 5, 5\n")
  end

  it 'restores all original bytes when writing the final receipt fails' do
    before = tree
    raised = false
    allow(Woods::AtomicFile).to receive(:write).and_wrap_original do |original, path, *arguments, **keywords|
      if path == File.join(@root, '.woods-watch.json') && !raised
        raised = true
        raise IOError, 'simulated write failure'
      end
      original.call(path, *arguments, **keywords)
    end

    expect { installer.apply }.to raise_error(described_class::Conflict, /original files were restored/)
    expect(tree.reject { |path, _value| path.start_with?('tmp/') }).to eq(before)
  end

  def interrupted_installation
    installation = installer
    plan = installation.plan
    originals = plan.data.fetch('changes').map do |change|
      document = Woods::AgentConfiguration::Document.new(change.fetch('path'))
      { 'path' => document.path, 'content' => document.content && Base64.strict_encode64(document.content),
        'mode' => document.mode }
    end
    path = File.join(@root, 'tmp/woods-watch-install/transaction.pending')
    Woods::AtomicFile.write(path, JSON.generate('plan' => plan.data, 'originals' => originals))
    change = plan.data.fetch('changes').first
    Woods::AtomicFile.write(change.fetch('path'), Woods::AgentConfiguration::Plan.after_content(change),
                            mode: change.fetch('mode'))
    [path, change]
  end

  it 'previews and recovers an interrupted transaction without probing a broken application' do
    before = tree
    journal, = interrupted_installation
    File.unlink(File.join(@root, 'Gemfile'))
    allow(probe).to receive(:call).and_raise('must not probe recovery')
    partial = tree

    expect(installer.recover(pretend: true)).to eq('recovery_preview_verified')
    expect(tree).to eq(partial)
    expect(installer.recover).to eq('recovered')
    expect(File.exist?(journal)).to be(false)
    expect(tree.reject { |path, _value| path.start_with?('tmp/') }).to eq(before.except('Gemfile'))
  end

  it 'retains a recovery journal rather than overwriting a concurrent application edit' do
    journal, change = interrupted_installation
    File.write(change.fetch('path'), 'user edited during interrupted apply')

    expect { installer.recover }.to raise_error(described_class::Conflict, /Concurrent edit prevents recovery/)
    expect(File.read(change.fetch('path'))).to eq('user edited during interrupted apply')
    expect(File.exist?(journal)).to be(true)
  end

  it 'recovers from a standalone bundled Ruby process without loading the broken Rails environment' do
    journal, = interrupted_installation
    File.write(File.join(@root, 'config/environment.rb'), "raise 'application must not boot during recovery'\n")
    repo = File.expand_path('../..', __dir__)
    environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => File.join(repo, 'Gemfile'),
                                              'BUNDLE_LOCKFILE' => File.join(repo, 'Gemfile.lock'))
    script = <<~RUBY
      require 'bundler/setup'
      require 'woods/watch/installation'
      abort 'Rails was loaded' if defined?(Rails)
      puts Woods::Watch::Installation.new(root: Dir.pwd).recover
    RUBY
    stdout, stderr, status = Open3.capture3(environment, Gem.ruby, '-I', File.join(repo, 'lib'),
                                            '-e', script, chdir: @root, unsetenv_others: true)

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq('recovered')
    expect(File.exist?(journal)).to be(false)
  end
end
