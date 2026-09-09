# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'open3'

RSpec.describe 'lib/tasks/woods_checks.rake' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:rake_path) { File.join(root, 'lib/tasks/woods_checks.rake') }
  let(:railtie_source) { File.read(File.join(root, 'lib/woods/railtie.rb'), encoding: 'UTF-8') }

  describe 'task definitions' do
    around do |example|
      previous = Rake.application
      Rake.application = Rake::Application.new
      example.run
    ensure
      Rake.application = previous
    end

    it 'defines woods:check:moved_messages with from and to arguments and no Rails prerequisite' do
      previous_verbose = $VERBOSE
      $VERBOSE = nil
      load rake_path
      $VERBOSE = previous_verbose

      task = Rake::Task['woods:check:moved_messages']
      expect(task.arg_names).to eq(%i[from to])
      expect(task.prerequisites).to eq([])
    ensure
      $VERBOSE = previous_verbose
    end
  end

  describe 'the railtie loads it' do
    it 'loads woods_checks.rake alongside woods.rake' do
      expect(railtie_source).to include("load File.expand_path('../tasks/woods_checks.rake', __dir__)")
    end
  end

  # Runs the packaged task as a real subprocess against a two-generation
  # fixture built on disk, so Woods::PublishedIndex can open both generations
  # exactly as it would in a host app (#280 rulings: two-generation fixture
  # with manifests; the task itself must never boot Rails, so there is no
  # fake Rails module here at all: WOODS_OUTPUT is enough).
  describe 'running against two retained generations on disk' do
    def write_generation_pointer(dir, number)
      File.write(File.join(dir, 'generation.json'),
                 JSON.generate('number' => number, 'token' => 'tok', 'payload' => "payloads/gen-#{number}"))
    end

    def service_file_path(identifier)
      "app/services/#{identifier.downcase}.rb"
    end

    def write_service_unit(service_dir, identifier, methods)
      digest = Digest::SHA256.hexdigest(identifier)[0, 8]
      unit = { 'type' => 'service', 'identifier' => identifier, 'file_path' => service_file_path(identifier),
               'metadata' => { 'public_methods' => methods } }
      File.write(File.join(service_dir, "#{identifier}_#{digest}.json"), JSON.generate(unit))
    end

    def write_services(dir, methods_by_unit)
      service_dir = File.join(dir, 'services')
      FileUtils.mkdir_p(service_dir)

      index_entries = methods_by_unit.keys.map do |identifier|
        { 'identifier' => identifier, 'file_path' => service_file_path(identifier), 'namespace' => nil }
      end
      File.write(File.join(service_dir, '_index.json'), JSON.generate(index_entries))

      methods_by_unit.each { |identifier, methods| write_service_unit(service_dir, identifier, methods) }
    end

    def write_dependency_graph(dir, coverage)
      edges = coverage.each_with_object({}) do |(from, to), memo|
        memo[from] = [{ 'target' => to, 'via' => 'test_coverage' }]
      end
      File.write(File.join(dir, 'dependency_graph.json'), JSON.generate('edges' => edges))
    end

    # A minimal payload: one _index.json + one unit file per service
    # identifier, plus a dependency_graph.json carrying :test_coverage edges.
    def write_payload(dir, methods_by_unit:, coverage: {})
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'manifest.json'), JSON.generate('total_units' => methods_by_unit.size))
      write_services(dir, methods_by_unit)
      write_dependency_graph(dir, coverage)
    end

    def run_task(dir, task, env: {})
      rakefile = File.join(dir, 'Rakefile')
      File.write(rakefile, <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        load #{rake_path.inspect}
      RUBY

      Open3.capture3({ 'WOODS_OUTPUT' => dir }.merge(env), RbConfig.ruby, File.join(root, 'bin/rake'),
                     '--rakefile', rakefile, task, chdir: dir)
    end

    def build_two_generations(dir)
      write_payload(File.join(dir, 'payloads', 'gen-1'),
                    methods_by_unit: { 'Checkout' => %w[call total], 'Pricing' => %w[rate] },
                    coverage: { 'spec/checkout_spec.rb' => 'Checkout' })
      write_payload(File.join(dir, 'payloads', 'gen-2'),
                    methods_by_unit: { 'Checkout' => %w[call], 'Pricing' => %w[rate total] },
                    coverage: { 'spec/checkout_spec.rb' => 'Checkout' })
      write_generation_pointer(dir, 2)
    end

    it 'reports a candidate move, defaulting to the latest two published generations, with no Rails boot' do
      Dir.mktmpdir('woods-checks-task') do |dir|
        build_two_generations(dir)

        out, err, status = run_task(dir, 'woods:check:moved_messages')

        expect(status).to be_success, "#{out}\n#{err}"
        expect(out).to include('Comparing generation 1 to 2')
        expect(out).to include('candidate move')
        expect(out).to include('total')
        expect(out).to include('Checkout -> Pricing')
      end
    end

    it 'accepts explicit [from,to] rake arguments' do
      Dir.mktmpdir('woods-checks-task') do |dir|
        build_two_generations(dir)

        out, err, status = run_task(dir, 'woods:check:moved_messages[1,2]')

        expect(status).to be_success, "#{out}\n#{err}"
        expect(out).to include('Comparing generation 1 to 2')
      end
    end

    it 'exits 1 only under WOODS_CHECK_STRICT=1 when findings exist' do
      Dir.mktmpdir('woods-checks-task') do |dir|
        build_two_generations(dir)

        default_out, default_err, default_status = run_task(dir, 'woods:check:moved_messages')
        expect(default_status).to be_success, "#{default_out}\n#{default_err}"

        strict_out, strict_err, strict_status = run_task(dir, 'woods:check:moved_messages',
                                                         env: { 'WOODS_CHECK_STRICT' => '1' })
        expect(strict_status).not_to be_success, "#{strict_out}\n#{strict_err}"
      end
    end

    it 'reports cleanly when nothing moved' do
      Dir.mktmpdir('woods-checks-task') do |dir|
        write_payload(File.join(dir, 'payloads', 'gen-1'), methods_by_unit: { 'Checkout' => %w[call] })
        write_payload(File.join(dir, 'payloads', 'gen-2'), methods_by_unit: { 'Checkout' => %w[call] })
        write_generation_pointer(dir, 2)

        out, err, status = run_task(dir, 'woods:check:moved_messages')

        expect(status).to be_success, "#{out}\n#{err}"
        expect(out).to include('No candidate moves')
      end
    end

    it 'exits 1 with a guidance message when fewer than two generations are retained' do
      Dir.mktmpdir('woods-checks-task') do |dir|
        write_payload(File.join(dir, 'payloads', 'gen-1'), methods_by_unit: { 'Checkout' => %w[call] })
        write_generation_pointer(dir, 1)

        out, err, status = run_task(dir, 'woods:check:moved_messages')

        expect(status).not_to be_success, "#{out}\n#{err}"
        expect(err).to include('need two retained generations')
      end
    end

    it 'lets a corrupt generation pointer propagate with a clear task-level message' do
      Dir.mktmpdir('woods-checks-task') do |dir|
        File.write(File.join(dir, 'generation.json'), '{not valid json')

        _out, err, status = run_task(dir, 'woods:check:moved_messages')

        expect(status).not_to be_success
        expect(err).to include('woods:check:moved_messages')
        expect(err).to match(/CorruptPointerError|Unreadable generation pointer/)
      end
    end
  end
end
