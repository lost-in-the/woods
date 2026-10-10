# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extractors/config_read_scanner'

RSpec.describe Woods::Extractors::ConfigReadScanner do
  let(:settings_readers) { [] }
  let(:scanner) { Class.new { include Woods::Extractors::ConfigReadScanner }.new }

  before do
    configuration = double('Configuration',
                           config_file_paths: Woods::Extractors::ConfigFileExtractor::DEFAULT_PATHS,
                           settings_readers: settings_readers)
    allow(Woods).to receive(:configuration).and_return(configuration)
  end

  def targets(source)
    scanner.scan_config_dependencies(source).map { |edge| edge[:target] }
  end

  def edge(target)
    { type: :config_file, target: target, via: :reads_config }
  end

  describe 'config_for' do
    it 'links a symbol or string name to config/<name>.yml' do
      source = <<~RUBY
        class Ledger
          RATES = Rails.application.config_for(:rates)
          LIMITS = Rails.application.config_for "limits"
          NESTED = Rails.application.config_for('billing/plans')
        end
      RUBY

      expect(scanner.scan_config_dependencies(source)).to eq(
        [edge('config/billing/plans.yml'), edge('config/limits.yml'), edge('config/rates.yml')]
      )
    end

    it 'ignores a dynamic name' do
      expect(targets('Rails.application.config_for(name)')).to eq([])
      expect(targets('Rails.application.config_for("#{kind}_rates")')).to eq([]) # rubocop:disable Lint/InterpolationCheck
    end
  end

  describe 'YAML.load_file' do
    it 'links a literal path' do
      expect(targets('YAML.load_file("config/storage.yml")')).to eq(%w[config/storage.yml])
      expect(targets("YAML.safe_load_file 'app/data/surveys/nps.yml', aliases: true"))
        .to eq(%w[app/data/surveys/nps.yml])
      expect(targets('Psych.unsafe_load_file("config/cable.yml")')).to eq(%w[config/cable.yml])
    end

    it 'links a Rails.root.join literal path, in one or several segments' do
      expect(targets('YAML.load_file(Rails.root.join("app/data/surveys/nps.yml"))'))
        .to eq(%w[app/data/surveys/nps.yml])
      expect(targets("YAML.safe_load_file(Rails.root.join('config', 'settings', 'production.yml'))"))
        .to eq(%w[config/settings/production.yml])
    end

    it 'links an interpolated Rails.root prefix' do
      expect(targets('YAML.load_file("#{Rails.root}/config/storage.yml")')).to eq(%w[config/storage.yml]) # rubocop:disable Lint/InterpolationCheck
    end

    it 'ignores dynamic, parent-relative and unindexed paths' do
      expect(targets('YAML.load_file(path)')).to eq([])
      expect(targets('YAML.load_file("config/#{name}.yml")')).to eq([]) # rubocop:disable Lint/InterpolationCheck
      expect(targets('YAML.load_file("../shared/settings.yml")')).to eq([])
      expect(targets('YAML.load_file(Rails.root.join("config", name))')).to eq([])
      expect(targets('YAML.load_file("spec/fixtures/widgets.yml")')).to eq([])
    end

    it 'never links a secret-bearing file' do
      expect(targets('YAML.load_file("config/secrets.yml")')).to eq([])
      expect(targets('Rails.application.config_for(:credentials)')).to eq([])
    end
  end

  describe 'settings readers' do
    let(:settings_readers) do
      [{ constant: 'Settings', file: 'config/settings.yml' },
       { constant: 'Billing::Limits', file: 'config/limits.yml' }]
    end

    it 'links a read through a configured settings constant' do
      source = <<~RUBY
        class Shipment
          def host
            Settings.payments.api_host
          end

          def cap
            ::Billing::Limits[:daily]
          end
        end
      RUBY

      expect(targets(source)).to eq(%w[config/limits.yml config/settings.yml])
    end

    it 'ignores another constant ending in the same name, and a bare mention' do
      expect(targets('Widget::Settings.payments')).to eq([])
      expect(targets('WidgetSettings.payments')).to eq([])
      expect(targets('Settings = Class.new')).to eq([])
      expect(targets('Limits[:daily]')).to eq([])
    end

    it 'links nothing when no reader is configured' do
      allow(Woods.configuration).to receive(:settings_readers).and_return([])

      expect(targets('Settings.payments.api_host')).to eq([])
    end
  end

  it 'ignores reads inside comments' do
    source = <<~RUBY
      # Rails.application.config_for(:rates)
      class Ledger; end # YAML.load_file("config/storage.yml")
    RUBY

    expect(targets(source)).to eq([])
  end

  it 'returns each target once, sorted' do
    source = <<~RUBY
      Rails.application.config_for(:storage)
      YAML.load_file("config/storage.yml")
      Rails.application.config_for(:cable)
    RUBY

    expect(targets(source)).to eq(%w[config/cable.yml config/storage.yml])
  end
end
