# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'active_job/railtie'
require 'woods'
require 'woods/extractor'
require 'woods/watch/daemon'

# A view-only application has no eligible Ruby source-reference owners. The
# controller variant proves the ordinary publication guard remains effective.
Dir.mktmpdir('woods-watch-publication-app') do |root|
  Dir.mktmpdir('woods-watch-publication-index') do |output|
    source = File.join(root, 'app/views/posts/show.html.erb')
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, '<p>before publication</p>')
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(File.join(root, 'config/application.rb'), '# Application configured by this fixture')
    File.write(File.join(root, 'config/routes.rb'), 'Rails.application.routes.draw {}')
    File.write(File.join(root, 'config/database.yml'), "test:\n  adapter: sqlite3\n  database: ':memory:'\n")
    reference = ARGV.fetch(1) == 'reference'
    if reference
      controller = File.join(root, 'app/controllers/publication_controller.rb')
      FileUtils.mkdir_p(File.dirname(controller))
      File.write(controller, "class PublicationController < ActionController::Base\n  def index; end\nend\n")
    end

    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = 'woods-watch-publication-fixture'
      config.hosts.clear
    end
    Object.const_set(:PublicationFixtureApplication, app)
    app.config.root = root
    app.initialize!
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    Rails.application.eager_load!
    Woods.configuration.concurrent_extraction = false

    baseline = Woods::Extractor.new(output_dir: output)
    baseline.extract_all
    baseline.raise_on_publication_failure!
    generation = Woods::Generation.new(output_dir: output)
    prior = generation.current.number
    extractor = Woods::Extractor.new(output_dir: output)
    boundary = ARGV.fetch(0).to_sym
    arrived = Queue.new
    resume = Queue.new
    original = extractor.method(boundary)
    extractor.define_singleton_method(boundary) do
      arrived << true
      resume.pop
      original.call
    end
    writer = Thread.new do
      extractor.extract_all
      extractor.raise_on_publication_failure!
      nil
    rescue Woods::ExtractionError => e
      e.message
    end
    Timeout.timeout(30) { arrived.pop }
    reference_paths = extractor.instance_variable_get(:@source_reference_paths).to_a
    raise 'incorrect reference-owner fixture' unless reference_paths.any? == reference

    capture = extractor.instance_variable_get(:@source_inputs).instance_variable_get(:@snapshot)
    timestamp = Time.at(capture.fetch('captured_at', Time.now.to_f).floor)
    File.write(source, '<p>edited during publication</p>')
    File.utime(timestamp, timestamp, source)
    resume << true
    error = Timeout.timeout(30) { writer.value }
    published = generation.current.number

    # The backend has no queued events: only startup reconciliation can find
    # the edit which preceded this daemon. The extractor itself remains real.
    watcher = Object.new
    def watcher.start; end
    def watcher.stop; end
    build = lambda do
      Woods::Watch::Daemon.new(root: root, output_dir: output, watcher: watcher, debounce: 0,
                               boot_snapshot: Woods::Watch::BootSnapshot.new(root: root))
    end
    result = build.call.run
    recovered = generation.current.number
    units = Dir[generation.payload_dir.join('view_templates/*.json')].filter_map do |path|
      data = JSON.parse(File.read(path))
      data if data.is_a?(Hash) && data['file_path'] == 'app/views/posts/show.html.erb'
    end
    build.call.run
    puts JSON.generate(prior: prior, published: published, recovered: recovered,
                       after_restart: generation.current.number, result: result, error: error,
                       reference: reference, units: units)
  ensure
    resume&.push(true)
    writer&.join(5) || writer&.kill&.join
  end
end
