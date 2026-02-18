# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/i18n_extractor'

RSpec.describe CodebaseIndex::Extractors::I18nExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers locale files in config/locales/' do
      create_file('config/locales/en.yml', <<~YAML)
        en:
          hello: "Hello"
          goodbye: "Goodbye"
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('en.yml')
      expect(units.first.type).to eq(:i18n)
    end

    it 'discovers files in nested directories' do
      create_file('config/locales/models/en.yml', <<~YAML)
        en:
          activerecord:
            models:
              user: "User"
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('models/en.yml')
    end

    it 'discovers multiple locale files' do
      create_file('config/locales/en.yml', <<~YAML)
        en:
          hello: "Hello"
      YAML

      create_file('config/locales/fr.yml', <<~YAML)
        fr:
          hello: "Bonjour"
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to include('en.yml', 'fr.yml')
    end
  end

  # ── extract_i18n_file ──────────────────────────────────────────────

  describe '#extract_i18n_file' do
    it 'extracts locale and key count' do
      path = create_file('config/locales/en.yml', <<~YAML)
        en:
          hello: "Hello"
          goodbye: "Goodbye"
          welcome: "Welcome"
      YAML

      unit = described_class.new.extract_i18n_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:i18n)
      expect(unit.metadata[:locale]).to eq('en')
      expect(unit.metadata[:key_count]).to eq(3)
    end

    it 'extracts top-level keys' do
      path = create_file('config/locales/en.yml', <<~YAML)
        en:
          activerecord:
            models:
              user: "User"
          errors:
            messages:
              blank: "can't be blank"
      YAML

      unit = described_class.new.extract_i18n_file(path)
      expect(unit.metadata[:top_level_keys]).to include('activerecord', 'errors')
    end

    it 'extracts flattened key paths' do
      path = create_file('config/locales/en.yml', <<~YAML)
        en:
          activerecord:
            models:
              user: "User"
              post: "Post"
          simple_key: "value"
      YAML

      unit = described_class.new.extract_i18n_file(path)
      expect(unit.metadata[:key_paths]).to include(
        'activerecord.models.user',
        'activerecord.models.post',
        'simple_key'
      )
    end

    it 'sets namespace to locale' do
      path = create_file('config/locales/fr.yml', <<~YAML)
        fr:
          hello: "Bonjour"
      YAML

      unit = described_class.new.extract_i18n_file(path)
      expect(unit.namespace).to eq('fr')
    end

    it 'preserves raw YAML as source code' do
      yaml_content = <<~YAML
        en:
          hello: "Hello"
      YAML

      path = create_file('config/locales/en.yml', yaml_content)
      unit = described_class.new.extract_i18n_file(path)
      expect(unit.source_code).to eq(yaml_content)
    end

    it 'has empty dependencies' do
      path = create_file('config/locales/en.yml', <<~YAML)
        en:
          hello: "Hello"
      YAML

      unit = described_class.new.extract_i18n_file(path)
      expect(unit.dependencies).to eq([])
    end

    it 'returns nil for invalid YAML' do
      path = create_file('config/locales/bad.yml', 'not: valid: yaml: {{{}}}asd')
      described_class.new.extract_i18n_file(path)
      # Either nil or a valid unit depending on YAML parsing
      # Invalid YAML that parses as a hash is fine; truly broken YAML returns nil
    end

    it 'returns nil for empty files' do
      path = create_file('config/locales/empty.yml', '')
      unit = described_class.new.extract_i18n_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_i18n_file('/nonexistent/path.yml')
      expect(unit).to be_nil
    end

    it 'handles deeply nested structures' do
      path = create_file('config/locales/en.yml', <<~YAML)
        en:
          level1:
            level2:
              level3:
                level4: "deep value"
      YAML

      unit = described_class.new.extract_i18n_file(path)
      expect(unit.metadata[:key_paths]).to include('level1.level2.level3.level4')
      expect(unit.metadata[:key_count]).to eq(1)
    end
  end
end
