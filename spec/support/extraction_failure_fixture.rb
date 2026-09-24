# frozen_string_literal: true

# Real orchestration/publication with two controlled whole-app consumers. Their
# non-reference inputs let these tests isolate failure reporting from the
# independent reference-baseline guard.
RSpec.shared_context 'published extraction failure fixture' do
  include_context 'isolated Woods runtime'

  let(:output_dir) { File.join(@app_root, 'index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output_dir) }
  let(:generation) { Woods::Generation.new(output_dir: output_dir) }
  let(:changed_paths) { %w[config/application.rb config/recurring.yml] }
  let(:middleware_consumer) { double('MiddlewareExtractor') }
  let(:schedule_consumer) { double('ScheduledJobExtractor') }
  let(:schedule_class) { double('ScheduledJobExtractorClass', new: schedule_consumer) }

  around do |example|
    Dir.mktmpdir('woods-failure-reporting') do |root|
      @app_root = root
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(@app_root), version: '8.1.0',
                                        logger: double('Logger').as_null_object,
                                        application: double('Application', eager_load!: nil)))
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.enable_snapshots = false
    Woods.configuration.output_dir = output_dir
    stub_const('Woods::Extractor::EXTRACTORS', {
                 middleware: double('MiddlewareExtractorClass', new: middleware_consumer),
                 scheduled_jobs: schedule_class
               })
    allow(middleware_consumer).to receive(:extract_all) {
      [fixture_unit(:middleware, 'Middleware', changed_paths.first)]
    }
    allow(schedule_consumer).to receive(:extract_all) {
      [fixture_unit(:scheduled_job, 'scheduled:fixture', changed_paths.last)]
    }
    write_inputs('baseline')
    extractor.extract_all
    extractor.raise_on_publication_failure!
    @previous_token = generation.current.token
    @previous_payload = payload_bytes
    write_inputs('changed')
  end

  def write_inputs(value)
    changed_paths.each do |relative|
      path = File.join(@app_root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# #{value}\n")
    end
  end

  def fixture_unit(type, identifier, path)
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: path).tap do |unit|
      unit.source_code = File.read(File.join(@app_root, path))
    end
  end

  def payload_bytes
    root = generation.payload_dir
    Dir[root.join('**/*')].select { |path| File.file?(path) }.to_h do |path|
      [Pathname.new(path).relative_path_from(root).to_s, File.binread(path)]
    end
  end

  def expect_previous_publication
    expect(generation.current.token).to eq(@previous_token)
    expect(payload_bytes).to eq(@previous_payload)
  end

  def expect_complete_retry
    expect(generation.current.token).not_to eq(@previous_token)
    reader = Woods::MCP::IndexReader.new(output_dir)
    expect(reader.find_unit('Middleware', type: 'middleware').fetch('source_code')).to eq("# changed\n")
    expect(reader.find_unit('scheduled:fixture', type: 'scheduled_job').fetch('source_code')).to eq("# changed\n")
  end
end
