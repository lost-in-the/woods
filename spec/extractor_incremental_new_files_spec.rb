# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

# Incremental extraction of brand-new files (files with no file_map entry).
#
# extract_changed resolves changed files through the persisted graph's
# file_map; a file added since the last full extraction has no entry, so it
# used to be dropped silently — every file added between full extracts was
# invisible to the index. New files are now detected, classified by path
# (NEW_FILE_TYPE_PATTERNS), and extracted as fresh units; files that can't
# be mapped to any unit are reported via #unhandled_changed_files instead
# of vanishing.
RSpec.describe Woods::Extractor, 'incremental new-file extraction' do
  let(:tmpdir) { Dir.mktmpdir('woods_new_files_test') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:output_dir) { File.join(tmpdir, 'output') }
  let(:extractor) { described_class.new(output_dir: output_dir) }

  before do
    require 'woods'
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new

    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  def touch(relative)
    path = File.join(tmpdir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    path
  end

  # ── detect_new_file_type ─────────────────────────────────────────────

  describe '#detect_new_file_type' do
    {
      'app/models/sprout.rb' => :model,
      'app/models/concerns/auditable.rb' => :concern,
      'app/controllers/concerns/secured.rb' => :concern,
      'app/controllers/sprouts_controller.rb' => :controller,
      'app/services/grow_service.rb' => :service,
      'app/interactors/grow.rb' => :service,
      'app/operations/grow.rb' => :service,
      'app/commands/grow.rb' => :service,
      'app/use_cases/grow.rb' => :service,
      'app/components/leaf_component.rb' => :component,
      'app/views/components/leaf_component.rb' => :component,
      'app/views/canopy/rendering/form.rb' => :component,
      'app/jobs/grow_job.rb' => :job,
      'app/workers/grow_worker.rb' => :job,
      'app/mailers/grow_mailer.rb' => :mailer,
      'app/graphql/types/sprout_type.rb' => :graphql_type,
      'app/serializers/sprout_serializer.rb' => :serializer,
      'app/blueprinters/sprout_blueprint.rb' => :serializer,
      'app/decorators/sprout_decorator.rb' => :decorator,
      'app/presenters/sprout_presenter.rb' => :decorator,
      'app/form_objects/sprout_form.rb' => :decorator,
      'app/policies/sprout_policy.rb' => :policy,
      'app/validators/height_validator.rb' => :validator,
      'app/channels/growth_channel.rb' => :action_cable_channel,
      'app/views/sprouts/show.html.erb' => :view_template,
      'db/migrate/20260716000000_create_sprouts.rb' => :migration,
      'spec/models/sprout_spec.rb' => :test_mapping,
      'lib/forestry/pruner.rb' => :lib
    }.each do |relative, expected_type|
      it "maps #{relative} to :#{expected_type}" do
        expect(extractor.send(:detect_new_file_type, File.join(tmpdir, relative))).to eq(expected_type)
      end
    end

    it 'returns nil for files with no extractable type' do
      expect(extractor.send(:detect_new_file_type, File.join(tmpdir, 'db/structure.sql'))).to be_nil
      expect(extractor.send(:detect_new_file_type, File.join(tmpdir, 'Gemfile.lock'))).to be_nil
      expect(extractor.send(:detect_new_file_type, File.join(tmpdir, 'config/routes.rb'))).to be_nil
    end

    it 'returns nil for paths outside Rails.root' do
      expect(extractor.send(:detect_new_file_type, '/somewhere/else/app/models/user.rb')).to be_nil
    end
  end

  # ── extract_new_file ─────────────────────────────────────────────────

  describe '#extract_new_file' do
    it 'extracts a FILE_BASED unit (migration) and persists it' do
      path = touch('db/migrate/20260716000000_create_sprouts.rb')

      unit = Woods::ExtractedUnit.new(
        type: :migration, identifier: '20260716000000_CreateSprouts', file_path: path
      )
      fake_instance = double('MigrationExtractor', extract_migration_file: unit)
      fake_class = double('MigrationExtractorClass', new: fake_instance)
      stub_const('Woods::Extractor::EXTRACTORS', { migrations: fake_class })

      affected_types = Set.new
      result = extractor.send(:extract_new_file, path, affected_types: affected_types)

      expect(result).to eq(unit)
      expect(fake_instance).to have_received(:extract_migration_file).with(path)
      expect(affected_types).to include(:migrations)

      # Registered in the graph so a follow-up run sees it as tracked
      expect(extractor.dependency_graph.node_exists?('20260716000000_CreateSprouts')).to be true

      # Persisted to the type dir with a normalized (relative) file_path
      written = Dir[File.join(output_dir, 'migrations', '*.json')]
      expect(written.size).to eq(1)
      data = JSON.parse(File.read(written.first))
      expect(data['identifier']).to eq('20260716000000_CreateSprouts')
      expect(data['file_path']).to eq('db/migrate/20260716000000_create_sprouts.rb')
    end

    it 'extracts a CLASS_BASED unit (model) by resolving the constant via Zeitwerk' do
      path = touch('app/models/sprout.rb')

      sprout_class = Class.new
      sprout_class.define_singleton_method(:name) { 'Sprout' }

      loader = double('Zeitwerk::Loader')
      allow(loader).to receive(:respond_to?).with(:cpath_expected_at).and_return(true)
      allow(loader).to receive(:cpath_expected_at).with(path).and_return('Sprout')
      allow(Rails).to receive(:autoloaders).and_return(double('Autoloaders', main: loader))
      stub_const('Sprout', sprout_class)

      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Sprout', file_path: path)
      fake_instance = double('ModelExtractor', extract_model: unit)
      fake_class = double('ModelExtractorClass', new: fake_instance)
      stub_const('Woods::Extractor::EXTRACTORS', { models: fake_class })

      result = extractor.send(:extract_new_file, path)

      expect(result).to eq(unit)
      expect(fake_instance).to have_received(:extract_model).with(sprout_class)
    end

    it 'returns nil when a CLASS_BASED constant cannot be resolved' do
      path = touch('app/models/ghost.rb')

      loader = double('Zeitwerk::Loader')
      allow(loader).to receive(:respond_to?).with(:cpath_expected_at).and_return(true)
      allow(loader).to receive(:cpath_expected_at).and_raise(StandardError, 'not managed')
      allow(Rails).to receive(:autoloaders).and_return(double('Autoloaders', main: loader))

      fake_class = double('ModelExtractorClass')
      stub_const('Woods::Extractor::EXTRACTORS', { models: fake_class })

      expect(extractor.send(:extract_new_file, path)).to be_nil
    end

    it 'returns nil for unmappable files' do
      path = touch('db/structure.sql')
      expect(extractor.send(:extract_new_file, path)).to be_nil
    end

    it 'rescues extractor errors and returns nil' do
      path = touch('db/migrate/20260716000000_boom.rb')

      fake_instance = double('MigrationExtractor')
      allow(fake_instance).to receive(:extract_migration_file).and_raise(StandardError, 'boom')
      fake_class = double('MigrationExtractorClass', new: fake_instance)
      stub_const('Woods::Extractor::EXTRACTORS', { migrations: fake_class })

      expect { expect(extractor.send(:extract_new_file, path)).to be_nil }.not_to raise_error
    end
  end

  # ── extract_new_files ────────────────────────────────────────────────

  describe '#extract_new_files' do
    it 'extracts every mappable new file and records the rest in unhandled_changed_files' do
      migration_path = touch('db/migrate/20260716000000_create_sprouts.rb')
      structure_path = touch('db/structure.sql')
      deleted_path = File.join(tmpdir, 'app/models/removed.rb') # never created

      unit = Woods::ExtractedUnit.new(
        type: :migration, identifier: '20260716000000_CreateSprouts', file_path: migration_path
      )
      fake_instance = double('MigrationExtractor', extract_migration_file: unit)
      fake_class = double('MigrationExtractorClass', new: fake_instance)
      stub_const('Woods::Extractor::EXTRACTORS', { migrations: fake_class })

      extracted = extractor.send(
        :extract_new_files,
        [migration_path, structure_path, deleted_path],
        affected_types: Set.new
      )

      expect(extracted).to eq(['20260716000000_CreateSprouts'])
      # Deleted files can't be extracted and have no unit to update — only
      # existing-but-unmappable files are reported.
      expect(extractor.unhandled_changed_files).to eq([structure_path])
    end

    it 'skips files already tracked in the graph file_map' do
      path = touch('app/models/tracked.rb')
      tracked = Woods::ExtractedUnit.new(type: :model, identifier: 'Tracked', file_path: path)
      extractor.dependency_graph.register(tracked)

      extracted = extractor.send(:extract_new_files, [path], affected_types: Set.new)

      expect(extracted).to be_empty
      expect(extractor.unhandled_changed_files).to be_empty
    end
  end

  # ── DependencyGraph#tracks_file? ─────────────────────────────────────

  describe 'DependencyGraph#tracks_file?' do
    it 'reflects file_map registration' do
      graph = Woods::DependencyGraph.new
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: '/app/models/user.rb')

      expect(graph.tracks_file?('/app/models/user.rb')).to be false
      graph.register(unit)
      expect(graph.tracks_file?('/app/models/user.rb')).to be true
    end
  end
end
