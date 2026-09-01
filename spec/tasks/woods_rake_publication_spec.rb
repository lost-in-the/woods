# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'one-shot extraction task publication failures' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_task(task_name) # rubocop:disable Metrics/MethodLength -- builds a complete executable Rake fixture
    Dir.mktmpdir('woods-publication-task') do |dir|
      rakefile = File.join(dir, 'Rakefile')
      File.write(rakefile, <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        require 'woods'
        require 'woods/extractor'

        module Rails
          def self.version = '8.0.0'
          def self.root = Pathname.new(#{dir.inspect})
        end

        task :environment
        load #{File.join(root, 'lib/tasks/woods.rake').inspect}

        class Woods::Extractor
          def initialize(output_dir:); end
          def extract_all = {}
          def extract_changed(*) = ['User']
          def refresh(*) = { types: [:routes], touched: ['User'], unknown: [] }

          def raise_on_publication_failure!
            raise Woods::ExtractionError, 'generation publication failed'
          end
        end
      RUBY

      env = {
        'CHANGED_FILES' => 'app/models/user.rb',
        'WOODS_IGNORE_WATCH' => '1',
        'WOODS_OUTPUT' => File.join(dir, 'index')
      }
      Open3.capture3(env, RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', rakefile, task_name,
                     chdir: dir)
    end
  end

  {
    'woods:extract' => 'Extraction complete!',
    'woods:incremental' => 'Re-extracted',
    'woods:refresh[routes]' => 'Refreshed:',
    'woods:extract_framework' => 'Extracted 1 framework source unit'
  }.each do |task_name, success_message|
    it "makes #{task_name} fail before reporting success" do
      out, err, status = run_task(task_name)

      expect(status).not_to be_success
      expect("#{out}\n#{err}").to include('Woods::ExtractionError', 'generation publication failed')
      expect(out).not_to include(success_message)
    end
  end
end
