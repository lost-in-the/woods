# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'active_support'
require 'active_support/core_ext/time'
require 'woods/extractor'

RSpec.describe 'Configuration source Git filtering' do
  include_context 'extractor setup'

  let(:source_paths) do
    %w[config/settings.local.yml config/routes.rb config/routes/admin.rb Gemfile Rakefile
       config/boot.rb config/environment.rb config/deploy.rb config/deploy/production.rb
       config/initializers/local.rb config/environments/test.rb db/seeds.rb
       lib/generators/widget/widget_generator.rb]
  end

  before do
    allow(Woods::Extractors::BehavioralProfile).to receive(:new).and_return(double(extract: nil))
    allow(Rails.application.routes).to receive(:routes).and_return([])
    source_paths.each do |path|
      source = if path.end_with?('.yml')
                 "local_secret_key: withheld\n"
               elsif path.start_with?('lib/')
                 "class WidgetGenerator < Rails::Generators::Base; end\n"
               else
                 "# configuration source\n"
               end
      create_file(path, source)
    end
  end

  def git(*args)
    _out, err, status = Open3.capture3(*Woods::GitCommand.argv(tmp_dir, *args))
    raise err unless status.success?
  end

  def source_units
    [Woods::Extractors::ConfigFileExtractor, Woods::Extractors::ConfigurationExtractor,
     Woods::Extractors::RouteExtractor, Woods::Extractors::LibExtractor].flat_map { |klass| klass.new.extract_all }
  end

  def check_omitted(reason)
    expect(source_units).to be_empty
    check_single_files_omitted
    check_report(reason)
    check_dispatch_omitted
  end

  def create_file_path(relative)
    File.join(tmp_dir, relative)
  end

  def check_single_files_omitted
    yaml = Woods::Extractors::ConfigFileExtractor.new
    expect(yaml.extract_config_file(create_file_path(source_paths.first))).to be_nil
    configuration = Woods::Extractors::ConfigurationExtractor.new
    expect(configuration.extract_configuration_file(create_file_path('Gemfile'))).to be_nil
    lib = Woods::Extractors::LibExtractor.new
    expect(lib.extract_lib_file(create_file_path(source_paths.last))).to be_nil
  end

  def check_report(reason)
    report = Woods::SkippedFiles.new(root: tmp_dir).build([])
    expect(report.fetch('files')).to include(*source_paths.map { |path| { 'path' => path, 'reason' => reason } })
  end

  def check_dispatch_omitted
    dispatcher = Woods::PathDispatcher.new
    policy = Woods::ReloadPolicy.new
    source_paths.each do |path|
      expect(dispatcher.file_rules_for(path)).to be_empty
      expect(dispatcher.whole_app_keys_for(path)).to be_empty
      expect(dispatcher.relevant?(path)).to be(false)
      expect(policy.classify(path)).to eq(:ignore)
    end
  end

  it 'omits ignored sources, including files tracked before they were ignored' do
    git('init', '--quiet')
    git('add', '.')
    create_file('.gitignore', source_paths.join("\n"))
    check_omitted('git_ignored')
  end

  it 'omits untracked sources' do
    git('init', '--quiet')
    check_omitted('untracked')
  end

  it 'indexes tracked sources without requiring a commit' do
    git('init', '--quiet')
    git('add', '.')
    expect(source_units.map { |unit| unit.file_path.to_s.delete_prefix("#{tmp_dir}/") }).to match_array(source_paths)
  end

  it 'indexes all sources when the Git executable is unavailable, probing availability once per filter' do
    git('init', '--quiet')
    allow(Open3).to receive(:capture3).and_call_original
    allow(Open3).to receive(:capture3).with('git', '--version').and_raise(Errno::ENOENT)
    filter = Woods::GitSourceFilter.new(root: tmp_dir)
    source_paths.each { |path| expect(filter.skip_reason(path)).to be_nil }
    expect(Open3).to have_received(:capture3).with('git', '--version').once
    expect(filter.available?).to be(false)
    expect(source_units.map { |unit| unit.file_path.to_s.delete_prefix("#{tmp_dir}/") }).to match_array(source_paths)
  end

  it 'indexes sources without Git and records the unavailable filter once on the manifest' do
    expect(source_units.map { |unit| unit.file_path.to_s.delete_prefix("#{tmp_dir}/") }).to match_array(source_paths)
    extractor = Woods::Extractor.new(output_dir: File.join(tmp_dir, 'index'))
    allow(Time).to receive(:current).and_return(Time.now)
    allow(Rails).to receive(:version).and_return('8.0.0')
    allow(extractor).to receive(:payload_dir).and_return(Pathname.new(tmp_dir))
    allow(extractor).to receive(:schema_sha).and_return(nil)
    extractor.send(:write_manifest)
    manifest = JSON.parse(File.read(File.join(tmp_dir, 'manifest.json')))
    expect(manifest.fetch('metadata')).to eq('git_filter' => 'unavailable')
  end
end
