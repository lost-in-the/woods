# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'woods'

RSpec.describe 'woods:validate writer-version warnings (#323)' do
  it 'prints a major-version warning without failing a structurally valid index' do
    Dir.mktmpdir('woods-validate-version') do |app_root|
      root = File.expand_path('../..', __dir__)
      writer = "#{Gem::Version.new(Woods::VERSION).segments.first + 1}.0.0"
      File.write(File.join(app_root, 'manifest.json'), JSON.generate(counts: {}, woods_version: writer))
      File.write(File.join(app_root, 'dependency_graph.json'), JSON.generate(nodes: {}, edges: []))
      File.write(File.join(app_root, 'Rakefile'), <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        require 'pathname'
        require 'woods'
        module Rails
          def self.root
            Pathname.new(#{app_root.inspect})
          end
        end
        task :environment
        load #{File.join(root, 'lib/tasks/woods.rake').inspect}
      RUBY

      out, err, status = Open3.capture3(
        { 'WOODS_OUTPUT' => app_root }, RbConfig.ruby, File.join(root, 'bin/rake'),
        'woods:validate', chdir: app_root
      )
      expect(status).to be_success, "#{out}\n#{err}"
      expect(out).to include("Index last published by Woods #{writer}", 'Run a full woods:extract',
                             'Index is valid with 1 warning(s)')
    end
  end
end
