# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/model_name_cache'
require 'woods/extractors/package_extractor'

RSpec.describe Woods::Extractors::PackageExtractor do
  include_context 'extractor setup'

  def write_package(dir, yaml)
    create_file(dir == '.' ? 'package.yml' : File.join(dir, 'package.yml'), yaml)
  end

  describe '#initialize' do
    it 'handles an app with no package.yml gracefully' do
      extractor = described_class.new

      expect(extractor.extract_all).to eq([])
      expect(extractor.package_roots).to eq([])
      expect(extractor.package_for('app/models/user.rb')).to be_nil
    end
  end

  describe '#extract_all' do
    before do
      write_package('.', "enforce_dependencies: true\ndependencies:\n  - packs/billing\n")
      write_package('packs/billing', <<~YAML)
        enforce_dependencies: strict
        enforce_privacy: true
        layer: product
        public_path: app/public
        dependencies:
          - packs/accounts
          - .
        metadata:
          owner: billing-team
      YAML
      write_package('packs/accounts', "enforce_dependencies: false\n")
      write_package('node_modules/some-lib', "dependencies: []\n")
    end

    it 'produces one package unit per package.yml, skipping default packwerk excludes' do
      units = described_class.new.extract_all

      expect(units.map(&:type).uniq).to eq([:package])
      expect(units.map(&:identifier).sort).to eq(['.', 'packs/accounts', 'packs/billing'])
    end

    it 'records the package fields and a package_dependency edge per declared dependency' do
      billing = described_class.new.extract_all.find { |u| u.identifier == 'packs/billing' }

      expect(billing.file_path).to eq(File.join(tmp_dir, 'packs/billing/package.yml'))
      expect(billing.metadata).to include(
        name: 'packs/billing', dependencies: ['.', 'packs/accounts'], enforce_dependencies: 'strict',
        enforce_privacy: true, layer: 'product', public_path: 'app/public', owner: 'billing-team'
      )
      expect(billing.dependencies).to eq(
        [
          { type: :package, target: '.', via: :package_dependency },
          { type: :package, target: 'packs/accounts', via: :package_dependency }
        ]
      )
      expect(billing.source_code).to include('enforce_dependencies: strict')
    end

    it 'defaults enforce_dependencies to false and dependencies to an empty list' do
      accounts = described_class.new.extract_all.find { |u| u.identifier == 'packs/accounts' }

      expect(accounts.metadata).to include(enforce_dependencies: false, dependencies: [], layer: nil)
      expect(accounts.dependencies).to eq([])
    end

    it 'honors package_paths and exclude from packwerk.yml' do
      create_file('packwerk.yml', "package_paths:\n  - packs/*\nexclude:\n  - packs/accounts/**/*\n")

      units = described_class.new.extract_all

      expect(units.map(&:identifier)).to eq(['packs/billing'])
    end

    it 'skips a package.yml that is not a hash and logs the failure' do
      write_package('packs/broken', "- just\n- a list\n")

      units = described_class.new.extract_all

      expect(units.map(&:identifier)).not_to include('packs/broken')
    end
  end

  describe '#package_for' do
    before do
      write_package('.', "enforce_dependencies: true\n")
      write_package('packs/billing', "enforce_dependencies: true\n")
      write_package('packs/billing/nested', "enforce_dependencies: true\n")
    end

    it 'returns the longest matching package root for relative and absolute paths' do
      extractor = described_class.new

      expect(extractor.package_for('packs/billing/nested/app/models/x.rb')).to eq('packs/billing/nested')
      expect(extractor.package_for('packs/billing/app/models/invoice.rb')).to eq('packs/billing')
      expect(extractor.package_for(File.join(tmp_dir, 'packs/billing/app/models/invoice.rb'))).to eq('packs/billing')
      expect(extractor.package_for('app/models/user.rb')).to eq('.')
    end

    it 'returns nil for a path outside Rails.root' do
      expect(described_class.new.package_for('/gems/devise/lib/devise.rb')).to be_nil
    end

    it 'orders package_roots longest first with the root package last' do
      expect(described_class.new.package_roots).to eq(['packs/billing/nested', 'packs/billing', '.'])
    end
  end
end
