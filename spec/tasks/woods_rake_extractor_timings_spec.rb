# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# The extraction tasks end with one line naming the families that paid for
# the run (LOS-130), read from the extractor that just ran, so a field run
# can say which family is slow without a profiler.
RSpec.describe 'extractor timings in the extraction task output' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_task(task_name, timings:) # rubocop:disable Metrics/MethodLength -- builds a complete executable Rake fixture
    Dir.mktmpdir('woods-timings-task') do |dir|
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
          def raise_on_publication_failure! = nil
          def extractor_timings = #{timings.inspect}
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

  let(:timings) do
    { 'models' => 1.25, 'view_templates' => 12.4, 'js_modules' => 9.8, 'routes' => 0.02, 'controllers' => 2.0,
      'jobs' => 0.5, 'mailers' => 0.4, 'services' => 0.3, 'libs' => 0.2, 'docs' => 0.1 }
  end
  let(:expected_line) do
    'Extractor timings (top 8 of 10, total 27.0s): view_templates 12.4s, js_modules 9.8s, controllers 2.0s, ' \
      'models 1.3s, jobs 0.5s, mailers 0.4s, services 0.3s, libs 0.2s'
  end

  { 'woods:extract' => 'Extraction complete!', 'woods:incremental' => 'Re-extracted',
    'woods:refresh[routes]' => 'Refreshed:' }.each do |task_name, success_message|
    it "prints the sorted summary after #{task_name} reports success" do
      out, err, status = run_task(task_name, timings: timings)

      expect(status).to be_success, err
      expect(out).to include(success_message)
      expect(out.index(expected_line)).to be > out.index(success_message)
    end

    it "prints no timing line from #{task_name} when nothing was timed" do
      out, _err, status = run_task(task_name, timings: {})

      expect(status).to be_success
      expect(out).to include(success_message)
      expect(out).not_to include('Extractor timings')
    end
  end
end
