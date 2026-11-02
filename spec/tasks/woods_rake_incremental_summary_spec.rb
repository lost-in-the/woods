# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# The incremental task's summary names the units it wrote and the blast
# radius it walked: wholesale re-runs re-derive units the written count never
# includes, so the written count alone reads as the run's whole cost (#966).
RSpec.describe 'the incremental task summary' do
  let(:root) { File.expand_path('../..', __dir__) }

  def run_incremental(radius:) # rubocop:disable Metrics/MethodLength -- builds a complete executable Rake fixture
    Dir.mktmpdir('woods-incremental-summary') do |dir|
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
          def extract_changed(*) = %w[User Post]
          def last_blast_radius_size = #{radius.inspect}
          def raise_on_publication_failure! = nil
          def extractor_timings = {}
        end
      RUBY

      env = {
        'CHANGED_FILES' => 'app/models/user.rb',
        'WOODS_IGNORE_WATCH' => '1',
        'WOODS_OUTPUT' => File.join(dir, 'index')
      }
      Open3.capture3(env, RbConfig.ruby, File.join(root, 'bin/rake'), '--rakefile', rakefile, 'woods:incremental',
                     chdir: dir)
    end
  end

  it 'names the blast radius beside the units written' do
    out, err, status = run_incremental(radius: 7254)

    expect(status).to be_success, err
    expect(out).to include('Re-extracted 2 affected units (blast radius: 7254 units).')
  end

  it 'keeps the plain line when the extractor reports no radius' do
    out, err, status = run_incremental(radius: nil)

    expect(status).to be_success, err
    expect(out).to include('Re-extracted 2 affected units.')
  end
end
