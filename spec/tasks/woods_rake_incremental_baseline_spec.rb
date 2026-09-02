# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# CORE-2: `woods:incremental` over an output directory with no baseline (a
# failed CI cache restore, a typo'd WOODS_OUTPUT, a first run on a fresh
# runner) must refuse instead of silently publishing a near-empty index as
# generation 1. The git range resolves fine in that state, so the failed-range
# guard never fires; the refusal has to come from the extractor's own
# baseline check.
RSpec.describe 'woods:incremental without a baseline index' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_incremental(dir) # rubocop:disable Metrics/MethodLength -- builds a complete executable Rake fixture
    rakefile = File.join(dir, 'Rakefile')
    File.write(rakefile, <<~RUBY)
      $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
      require 'rake'
      require 'logger'
      require 'woods'
      require 'woods/extractor'

      module Rails
        def self.version = '8.0.0'
        def self.root = Pathname.new(#{dir.inspect})
        def self.logger = @logger ||= Logger.new(File::NULL)
        def self.application = nil
      end

      task :environment
      load #{File.join(root, 'lib/tasks/woods.rake').inspect}
    RUBY

    FileUtils.mkdir_p(File.join(dir, 'app/models'))
    File.write(File.join(dir, 'app/models/user.rb'), 'class User; end')

    env = {
      'CHANGED_FILES' => 'app/models/user.rb',
      'WOODS_IGNORE_WATCH' => '1',
      'WOODS_OUTPUT' => File.join(dir, 'index')
    }
    Open3.capture3(env, RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', rakefile,
                   'woods:incremental', chdir: dir)
  end

  it 'exits non-zero naming woods:extract, and publishes nothing' do
    Dir.mktmpdir('woods-baseline-task') do |dir|
      out, err, status = run_incremental(dir)

      expect(status).not_to be_success
      expect("#{out}\n#{err}").to include('No baseline index found')
      expect("#{out}\n#{err}").to include('woods:extract')
      expect(File.exist?(File.join(dir, 'index', 'generation.json'))).to be(false)
    end
  end
end
