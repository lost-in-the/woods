# frozen_string_literal: true

require 'spec_helper'
require 'active_support/core_ext/object/blank' # count_loc uses present?
require 'woods/extractors/model_extractor'
require 'tmpdir'
require 'fileutils'

# Who defines a model (#995): `metadata[:origin]`, read from the file that
# first defines the class's constant through SourceOrigin. Every fixture is a
# real constant loaded from a real file, so Ruby itself reports each site.
#
# | The constant was first defined in                 | origin      |
# |---------------------------------------------------|-------------|
# | a file under the application root                 | `app`       |
# | an installed Rails gem (`activerecord-x.y.z`)     | `framework` |
# | another installed gem                             | `gem`       |
# | `vendor/…/gems/<name>-<version>/` in the app      | `gem`       |
# | another file under `vendor/` in the app           | `unknown`   |
# | a file outside the app, the bundle and stdlib     | `unknown`   |
# | C (no source site)                                | `unknown`   |
# | a pending autoload, the constant or its namespace | `unknown`   |
# | nothing: the name now resolves to another class   | `unknown`   |
#
# A gem model the application reopens keeps `gem`, while its `file_path`
# names the application file. The reverse, an application model a gem
# file reopens, stays `app`.
RSpec.describe 'Model origin from the defining file (#995)' do
  let(:origin) { Woods::Extractors::SourceOrigin }

  around do |example|
    Dir.mktmpdir('woods_model_origin') do |base|
      @base = base
      @root = File.join(base, 'app_root')
      FileUtils.mkdir_p(@root)
      Object.const_set(:OriginFixtures, Module.new)
      example.run
    ensure
      Object.send(:remove_const, :OriginFixtures) if Object.const_defined?(:OriginFixtures, false)
    end
  end

  # Write a Ruby file below +dir+ and load it, so the constants it defines
  # report this file as their source location.
  def define_in(path, source, load_now: true)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    load path if load_now
    path
  end

  def app_file(relative) = File.join(@root, relative)
  def installed_gem_file(gem_dir, relative) = File.join(@base, 'bundle/ruby/3.3.0/gems', gem_dir, relative)

  def origin_of(klass)
    origin.constant_origin(klass, root: @root)
  end

  describe 'SourceOrigin.constant_origin' do
    it 'reads app for a class first defined under the application root' do
      define_in(app_file('app/models/origin_fixtures/post.rb'), "class OriginFixtures::Post; end\n")

      expect(origin_of(OriginFixtures::Post)).to eq('app')
    end

    it 'reads framework for a class first defined in a Rails gem' do
      define_in(installed_gem_file('activerecord-7.1.6', 'lib/active_record/schema_migration.rb'),
                "class OriginFixtures::SchemaMigration; end\n")

      expect(origin_of(OriginFixtures::SchemaMigration)).to eq('framework')
    end

    it 'reads gem for a class first defined in another installed gem' do
      define_in(installed_gem_file('catalog_kit-0.3.0', 'lib/catalog_kit/listing.rb'),
                "class OriginFixtures::Listing; end\n")

      expect(origin_of(OriginFixtures::Listing)).to eq('gem')
    end

    it 'follows SourceOrigin under vendor/: an installed gem layout is gem, any other file unknown' do
      define_in(app_file('vendor/bundle/ruby/3.3.0/gems/vendored_kit-1.0.0/lib/vendored_kit/part.rb'),
                "class OriginFixtures::VendoredPart; end\n")
      define_in(app_file('vendor/models/loose_record.rb'), "class OriginFixtures::LooseRecord; end\n")

      expect(origin_of(OriginFixtures::VendoredPart)).to eq('gem')
      expect(origin_of(OriginFixtures::LooseRecord)).to eq('unknown')
    end

    it 'reads unknown for a class first defined outside the app, the bundle and the standard library' do
      define_in(File.join(@base, 'elsewhere/stray_record.rb'), "class OriginFixtures::StrayRecord; end\n")

      expect(origin_of(OriginFixtures::StrayRecord)).to eq('unknown')
    end

    it 'reads unknown for a class Ruby defines in C, which has no source site' do
      expect(origin_of(String)).to eq('unknown')
    end

    it 'keeps the first definition when the application reopens a gem class' do
      define_in(installed_gem_file('catalog_kit-0.3.0', 'lib/catalog_kit/item.rb'), "class OriginFixtures::Item; end\n")
      define_in(app_file('app/models/origin_fixtures/item.rb'), "class OriginFixtures::Item\n  def extra; end\nend\n")

      expect(OriginFixtures::Item.instance_method(:extra).source_location.first).to start_with(@root)
      expect(origin_of(OriginFixtures::Item)).to eq('gem')
    end

    it 'keeps app when a gem file reopens a class the application defined first (near miss)' do
      define_in(app_file('app/models/origin_fixtures/order.rb'), "class OriginFixtures::Order; end\n")
      define_in(installed_gem_file('catalog_kit-0.3.0', 'lib/catalog_kit/order_ext.rb'),
                "class OriginFixtures::Order\n  def ext; end\nend\n")

      expect(origin_of(OriginFixtures::Order)).to eq('app')
    end

    it 'reads unknown for a pending autoload without loading it' do
      marker = File.join(@base, 'loaded')
      path = define_in(app_file('app/models/origin_fixtures/pending.rb'),
                       "File.write(#{marker.inspect}, '')\nclass OriginFixtures::Pending; end\n", load_now: false)
      OriginFixtures.autoload(:Pending, path)
      stale = Class.new
      stale.define_singleton_method(:name) { 'OriginFixtures::Pending' }

      expect(origin_of(stale)).to eq('unknown')
      expect(File).not_to exist(marker)
      expect(OriginFixtures.autoload?(:Pending, false)).to eq(path)
    end

    it 'reads unknown when the namespace is a pending autoload, without loading the namespace' do
      marker = File.join(@base, 'loaded')
      path = define_in(app_file('app/models/origin_fixtures/lazy.rb'),
                       "File.write(#{marker.inspect}, '')\nmodule OriginFixtures::Lazy; class Thing; end; end\n",
                       load_now: false)
      OriginFixtures.autoload(:Lazy, path)
      stale = Class.new
      stale.define_singleton_method(:name) { 'OriginFixtures::Lazy::Thing' }

      expect(origin_of(stale)).to eq('unknown')
      expect(File).not_to exist(marker)
    end

    it 'reads unknown when the name now resolves to a different class' do
      define_in(app_file('app/models/origin_fixtures/replaced.rb'), "class OriginFixtures::Replaced; end\n")
      stale = Class.new
      stale.define_singleton_method(:name) { 'OriginFixtures::Replaced' }

      expect(origin_of(OriginFixtures::Replaced)).to eq('app')
      expect(origin_of(stale)).to eq('unknown')
    end

    it 'reads unknown for a class with no name' do
      expect(origin_of(Class.new)).to eq('unknown')
    end
  end

  describe 'ModelExtractor#extract_model' do
    let(:extractor) { Woods::Extractors::ModelExtractor.new }

    before do
      stub_const('Rails', double('Rails', root: Pathname.new(@root), logger: double('Logger').as_null_object))
    end

    # A real class under its real constant, answering the Active Record
    # reflection extract_model reads: no table, associations, validators or
    # callbacks. Singleton methods leave the constant's definition site alone.
    def bare_model(klass)
      superclass = double('Superclass', name: 'ApplicationRecord')
      answers = {
        table_name: 'items', primary_key: 'id', module_parent: Object, reflect_on_all_associations: [],
        _validators: {}, inheritance_column: 'type', descends_from_active_record?: true,
        superclass: superclass, table_exists?: false
      }
      %i[validation save create update destroy commit rollback before_commit initialize find touch].each do |event|
        answers[:"_#{event}_callbacks"] = []
      end
      answers.each { |name, value| klass.define_singleton_method(name) { value } }
      klass
    end

    it 'publishes gem for a reopened gem model while file_path names the application file' do
      define_in(installed_gem_file('catalog_kit-0.3.0', 'lib/catalog_kit/item.rb'), "class OriginFixtures::Item; end\n")
      app_path = define_in(app_file('app/models/origin_fixtures/item.rb'),
                           "class OriginFixtures::Item\n  def extra; end\nend\n")

      unit = extractor.extract_model(bare_model(OriginFixtures::Item))

      expect(extractor.warnings).to be_empty
      expect(unit.file_path).to eq(app_path)
      expect(unit.metadata[:origin]).to eq('gem')
    end

    it 'publishes app for an application model at its convention path' do
      app_path = define_in(app_file('app/models/origin_fixtures/post.rb'), "class OriginFixtures::Post; end\n")

      unit = extractor.extract_model(bare_model(OriginFixtures::Post))

      expect(unit.file_path).to eq(app_path)
      expect(unit.metadata[:origin]).to eq('app')
    end

    it 'publishes gem for a gem model with no application file, at its gem path' do
      gem_path = define_in(installed_gem_file('catalog_kit-0.3.0', 'lib/catalog_kit/listing.rb'),
                           "class OriginFixtures::Listing; end\n")

      unit = extractor.extract_model(bare_model(OriginFixtures::Listing))

      expect(unit.file_path).to eq(gem_path)
      expect(unit.metadata[:origin]).to eq('gem')
    end

    it 'publishes unknown, and keeps the unit, for a model defined outside every known root' do
      define_in(File.join(@base, 'elsewhere/stray_record.rb'), "class OriginFixtures::StrayRecord; end\n")

      unit = extractor.extract_model(bare_model(OriginFixtures::StrayRecord))

      expect(unit).not_to be_nil
      expect(unit.metadata[:origin]).to eq('unknown')
    end
  end
end
