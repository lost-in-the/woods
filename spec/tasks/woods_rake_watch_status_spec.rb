# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'socket'
require 'tmpdir'
require 'time'

RSpec.describe 'woods:watch_status root resolution' do
  let(:root) { File.expand_path('../..', __dir__) }

  def write_fixture(app_root, output_dir)
    File.write(File.join(app_root, 'Rakefile'), <<~RUBY)
      $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
      require 'rake'
      require 'woods'
      load #{File.join(root, 'lib/tasks/woods.rake').inspect}
    RUBY
    File.write(
      File.join(output_dir, 'watch_status.json'),
      JSON.generate(
        state: 'running', pid: Process.pid, host: Socket.gethostname,
        updated_at: Time.now.utc.iso8601
      )
    )
  end

  it 'finds the conventional output beside the loaded Rakefile when cwd differs, without booting Rails' do
    Dir.mktmpdir('woods-watch-status') do |dir|
      app_root = File.join(dir, 'app')
      foreign_cwd = File.join(dir, 'launcher')
      output_dir = File.join(app_root, 'tmp/woods')
      FileUtils.mkdir_p([output_dir, foreign_cwd])

      write_fixture(app_root, output_dir)

      out, err, status = Open3.capture3(
        RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', File.join(app_root, 'Rakefile'),
        'woods:watch_status',
        chdir: foreign_cwd
      )

      expect(status).to be_success, err
      expect(JSON.parse(out)).to include('state' => 'running', 'pid' => Process.pid)
      expect(err).to be_empty
    end
  end

  it 'keeps the application root when Rake discovers a relative Rakefile above a nested cwd' do
    Dir.mktmpdir('woods-watch-status') do |app_root|
      nested_cwd = File.join(app_root, 'tmp/launcher')
      output_dir = File.join(app_root, 'tmp/woods')
      FileUtils.mkdir_p([output_dir, nested_cwd])
      write_fixture(app_root, output_dir)

      out, err, status = Open3.capture3(
        RbConfig.ruby, File.join(root, 'bin/rake'), 'woods:watch_status', chdir: nested_cwd
      )

      expect(status).to be_success, err
      expect(JSON.parse(out)).to include('state' => 'running', 'pid' => Process.pid)
      expect(err).to match(/\A\(in .+\)\n\z/)
    end
  end
end
