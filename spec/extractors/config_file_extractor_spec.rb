# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods'
require 'woods/extractors/config_file_extractor'

RSpec.describe Woods::Extractors::ConfigFileExtractor do
  include_context 'extractor setup'

  let(:paths) { described_class::DEFAULT_PATHS }
  let(:store_values) { false }

  before do
    configuration = double('Configuration', config_file_paths: paths, config_file_values: store_values)
    allow(Woods).to receive(:configuration).and_return(configuration)
  end

  def unit_for(relative)
    described_class.new.extract_all.find { |unit| unit.identifier == relative }
  end

  def serialized(unit)
    JSON.generate(unit.to_h)
  end

  describe '#extract_all' do
    it 'emits one config_file unit per YAML file under the default globs' do
      create_file('config/settings.yml', "payments:\n  api_host: ledger.example\n")
      create_file('config/settings/production.yml', "payments:\n  api_host: live.example\n")
      create_file('app/data/surveys/nps.yml', "title: Score\nquestions:\n  - id: q1\n")

      units = described_class.new.extract_all

      expect(units.map(&:type).uniq).to eq([:config_file])
      expect(units.map(&:identifier)).to eq(
        %w[app/data/surveys/nps.yml config/settings.yml config/settings/production.yml]
      )
      expect(units.map(&:file_path)).to all(start_with(tmp_dir))
    end

    it 'leaves locale files to the i18n extractor' do
      create_file('config/locales/en.yml', "en:\n  hello: Hello\n")
      create_file('config/cable.yml', "production:\n  adapter: redis\n")

      expect(described_class.new.extract_all.map(&:identifier)).to eq(%w[config/cable.yml])
    end

    it 'ignores YAML outside the configured globs' do
      create_file('.github/workflows/ci.yml', "name: ci\n")
      create_file('spec/fixtures/widgets.yml', "one:\n  name: Widget\n")
      create_file('deploy/chart/values.yml', "replicas: 2\n")

      expect(described_class.new.extract_all).to be_empty
    end

    it 'follows config.config_file_paths' do
      create_file('config/settings.yml', "a: 1\n")
      create_file('data/ledgers/rates.yaml', "standard: 5\n")
      allow(Woods.configuration).to receive(:config_file_paths).and_return(%w[data/**/*.yaml])

      expect(described_class.new.extract_all.map(&:identifier)).to eq(%w[data/ledgers/rates.yaml])
    end

    it 'returns no units when no directory exists' do
      expect(described_class.new.extract_all).to eq([])
    end
  end

  describe 'metadata' do
    it 'records top-level keys, environments and per-environment keys' do
      create_file('config/storage.yml', <<~YAML)
        default: &default
          adapter: disk
          root: storage
        development:
          <<: *default
        production:
          <<: *default
          bucket: widgets
        shared:
          region: north
      YAML

      metadata = unit_for('config/storage.yml').metadata

      expect(metadata[:root_type]).to eq('mapping')
      expect(metadata[:top_level_keys]).to eq(%w[default development production shared])
      expect(metadata[:environments]).to eq(%w[development production])
      expect(metadata[:environment_keys]).to eq(
        'development' => %w[adapter root], 'production' => %w[adapter root bucket]
      )
      expect(metadata[:key_paths]).to include('default.adapter', 'production.bucket', 'shared.region')
      expect(metadata[:key_paths]).not_to include('production.<<')
      expect(metadata[:parse_error]).to be(false)
    end

    it 'descends into sequences of mappings and names a top-level sequence' do
      create_file('config/blocked_words.yml', "- alpha\n- beta\n")
      create_file('app/data/surveys/nps.yml', "questions:\n  - id: q1\n    label: How?\n")

      expect(unit_for('config/blocked_words.yml').metadata).to include(
        root_type: 'sequence', entry_count: 2, top_level_keys: [], key_paths: []
      )
      expect(unit_for('app/data/surveys/nps.yml').metadata[:key_paths])
        .to eq(%w[questions questions[].id questions[].label])
    end

    it 'keeps symbol-style keys as written' do
      create_file('config/sidekiq.yml', ":concurrency: 5\n:queues:\n  - default\n")

      expect(unit_for('config/sidekiq.yml').metadata[:top_level_keys]).to eq(%w[:concurrency :queues])
    end

    it 'records ERB use and the environment variables it names without evaluating it' do
      create_file('config/settings.yml', <<~YAML)
        <% if ENV["WIDGET_MODE"] %>
        payments:
          api_host: <%= ENV.fetch("LEDGER_HOST") { raise "evaluated" } %>
          timeout: <%= 2 + 3 %>
        <% end %>
      YAML

      metadata = unit_for('config/settings.yml').metadata

      expect(metadata[:erb]).to be(true)
      expect(metadata[:env_vars]).to eq(%w[LEDGER_HOST WIDGET_MODE])
      expect(metadata[:key_paths]).to eq(%w[payments payments.api_host payments.timeout])
    end

    it 'falls back to a top-level key scan when the YAML cannot be parsed' do
      create_file('config/settings.yml', "payments:\n  api_host: [unclosed\nledger:\n  rate: 1\n")

      metadata = unit_for('config/settings.yml').metadata

      expect(metadata[:parse_error]).to be(true)
      expect(metadata[:top_level_keys]).to eq(%w[payments ledger])
    end

    it 'caps the recorded key paths on an alias expansion bomb' do
      layers = (1..9).map { |n| "l#{n}: &l#{n}\n#{(1..9).map { |k| "  k#{k}: *l#{n - 1}\n" }.join}" }
      create_file('config/settings.yml', "l0: &l0\n  leaf: 1\n#{layers.join}")

      metadata = unit_for('config/settings.yml').metadata

      expect(metadata[:key_paths].size).to be <= described_class::MAX_KEY_PATHS
      expect(metadata[:key_paths_truncated]).to be(true)
    end

    it 'does not read a file over the size limit' do
      path = create_file('config/settings.yml', "a: 1\n")
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(path).and_return(described_class::MAX_BYTES + 1)
      allow(File).to receive(:read).and_call_original

      metadata = unit_for('config/settings.yml').metadata

      expect(File).not_to have_received(:read).with(path, any_args)
      expect(metadata).to include(oversized: true, key_paths: [])
    end

    it 'produces identical output on repeat runs' do
      create_file('config/settings.yml', "b: 1\na:\n  c: 2\n")

      first, second = Array.new(2) { serialized(unit_for('config/settings.yml')) }

      expect(first).to eq(second)
    end
  end

  describe 'secret exclusion' do
    secret_files = %w[
      config/credentials.yml.enc config/credentials.yml config/credentials/production.yml
      config/credentials/production.key config/master.key config/secrets.yml
      config/secrets.yml.enc config/widget_secrets.yml config/settings/credentials.production.yml
    ]

    secret_files.each do |relative|
      it "never opens #{relative}" do
        allow(Woods.configuration).to receive(:config_file_paths).and_return(%w[config/**/*])
        path = create_file(relative, "token: plaintext-marker\n")
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:open).and_call_original
        extractor = described_class.new

        units = extractor.extract_all
        direct = extractor.extract_config_file(path)

        expect(units).to be_empty
        expect(direct).to be_nil
        expect(File).not_to have_received(:read).with(path, any_args)
        expect(File).not_to have_received(:open).with(path, any_args)
      end
    end

    it 'stores key paths only, never a value or a comment' do
      create_file('config/database.yml', <<~YAML)
        # rotate plaintext-comment-marker monthly
        production:
          adapter: mysql2
          password: plaintext-password-marker
          url: mysql2://ledger:plaintext-url-marker@db.example/ledger
      YAML

      unit = unit_for('config/database.yml')

      expect(unit.metadata[:values_stored]).to be(false)
      expect(unit.metadata[:key_paths]).to include('production.password')
      expect(serialized(unit)).not_to include('marker')
      expect(serialized(unit)).not_to include('mysql2')
    end

    it 'redacts a key that is itself shaped like a credential' do
      create_file('config/settings.yml', "tokens:\n  sk_live_#{'a1B2' * 8}: enabled\n")

      unit = unit_for('config/settings.yml')

      expect(unit.metadata[:key_paths]).to eq(['tokens', 'tokens.[REDACTED]'])
      expect(serialized(unit)).not_to include('sk_live_')
    end

    context 'with config.config_file_values enabled' do
      let(:store_values) { true }

      it 'stores scalar values but never one under a credential-named key' do
        create_file('config/settings.yml', <<~YAML)
          payments:
            api_host: ledger.example
            api_key: plaintext-key-marker
            webhook:
              signing_secret: plaintext-nested-marker
            oauth:
              client:
                password_hint:
                  text: plaintext-descendant-marker
          session_token: plaintext-token-marker
        YAML

        unit = unit_for('config/settings.yml')

        expect(unit.metadata[:values_stored]).to be(true)
        expect(unit.source_code).to include('payments.api_host = ledger.example')
        expect(unit.source_code).to include('payments.api_key = [REDACTED]')
        expect(unit.source_code).to include('payments.oauth.client.password_hint.text = [REDACTED]')
        expect(serialized(unit)).not_to include('marker')
      end

      it 'redacts a credential-shaped value under an innocent key' do
        create_file('config/settings.yml', <<~YAML)
          ledger:
            endpoint: postgres://ledger:plaintext-url-marker@db.example/ledger
            label: sk_live_#{'a1B2' * 8}
        YAML

        unit = unit_for('config/settings.yml')

        expect(unit.source_code).to include('ledger.endpoint = [REDACTED]')
        expect(serialized(unit)).not_to include('marker')
        expect(serialized(unit)).not_to include('sk_live_')
      end

      it 'never stores ERB source as a value' do
        create_file('config/settings.yml', "ledger:\n  host: <%= \"plaintext-erb-marker\" %>\n")

        unit = unit_for('config/settings.yml')

        expect(unit.source_code).to include('ledger.host = [ERB]')
        expect(serialized(unit)).not_to include('marker')
      end
    end
  end

  describe '#extract_config_file' do
    it 'returns nil for a path outside the configured globs' do
      path = create_file('spec/fixtures/widgets.yml', "one: 1\n")

      expect(described_class.new.extract_config_file(path)).to be_nil
    end

    it 'returns the unit for a matching path' do
      path = create_file('config/cable.yml', "production:\n  adapter: redis\n")

      unit = described_class.new.extract_config_file(path)

      expect(unit.identifier).to eq('config/cable.yml')
      expect(unit.namespace).to eq('config')
      expect(unit.dependencies).to eq([])
      expect(unit.source_code).to include('production.adapter')
    end
  end

  describe '.config_file_path?' do
    it 'is a static function of the path and configuration' do
      expect(described_class.config_file_path?('config/settings.yml')).to be(true)
      expect(described_class.config_file_path?('config/locales/en.yml')).to be(false)
      expect(described_class.config_file_path?('config/secrets.yml')).to be(false)
      expect(described_class.config_file_path?('config/settings.rb')).to be(false)
    end
  end
end
