# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'woods/source_inputs/status'
require_relative '../support/source_input_app'

RSpec.describe 'Source manifest capacity with booted Rails', :booted_app do
  include SourceInputApp

  let(:root) { File.expand_path('../..', __dir__) }

  def run_command(app, *command, environment: {})
    # This disposable repository has its own history, not the enclosing CI PR's refs.
    isolated = %w[GITHUB_BASE_REF CI_COMMIT_BEFORE_SHA CI_COMMIT_SHA WOODS_GIT_DIR GIT_DIR GIT_WORK_TREE]
               .to_h { |key| [key, nil] }.merge(environment)
    out, err, status = Open3.capture3(isolated, *command, chdir: app)
    expect(status).to be_success, "#{out}\n#{err}"
    [out, err]
  end

  def git(app, *arguments)
    run_command(app, 'git', '-c', 'user.name=Woods Fixture', '-c', 'user.email=woods@example.test', *arguments)
  end

  it 'keeps explicit-file and Git incremental extraction usable after a bounded unavailable publication' do
    Dir.mktmpdir('woods-capacity-app') do |app|
      make_source_app(app)
      FileUtils.mkdir_p(File.join(app, 'config/initializers'))
      File.write(File.join(app, 'config/initializers/evidence_limit.rb'), <<~RUBY)
        require 'woods/source_inputs/manifest'
        Woods::SourceInputs::Manifest.send(:remove_const, :MAX_BYTES)
        Woods::SourceInputs::Manifest.const_set(:MAX_BYTES, 2000)
      RUBY
      File.write(File.join(app, '.gitignore'), "tmp/\nlog/\n*.sqlite3*\n")
      path = 'app/services/capacity_probe.rb'
      File.write(File.join(app, path), "class CapacityProbe; def call; :first; end; end\n")
      git(app, 'init', '--quiet')
      git(app, 'add', '.')
      git(app, 'commit', '--quiet', '-m', 'Initial fixture')
      rake = [RbConfig.ruby, File.join(root, 'bin/rake')]
      _, error = run_command(app, *rake, 'woods:extract')
      expect(error).to include('source_manifest_too_large')
      output = File.join(app, 'tmp/woods')
      generation = Woods::Generation.new(output_dir: output)
      previous = generation.current.number
      File.write(File.join(app, path), "class CapacityProbe; def call; :second; end; end\n")
      run_command(app, *rake, 'woods:incremental', environment: { 'CHANGED_FILES' => path })
      expect(generation.current.number).to be > previous
      previous = generation.current.number
      git(app, 'add', path)
      git(app, 'commit', '--quiet', '-m', 'Change probe')
      run_command(app, *rake, 'woods:incremental', environment: { 'CHANGED_FILES' => nil })
      expect(generation.current.number).to be > previous
      status = Woods::SourceInputs::Status.new(output_dir: output).call
      expect(status).to include('state' => 'unavailable', 'reasons' => ['source_manifest_too_large'])
      expect(status['recommendations']).not_to include('fresh_capture')
    end
  end
end
