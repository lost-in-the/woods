# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/javascript_paths'

RSpec.describe Woods::JavascriptPaths do
  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  describe '.source?' do
    it 'accepts the default roots and extensions' do
      %w[
        app/javascript/controllers/clipboard_controller.js
        app/javascript/widgets/picker.ts
        app/javascript/widgets/picker.tsx
        app/javascript/widgets/picker.jsx
        app/javascript/entry.mjs
        app/assets/javascripts/legacy/ledger.js
      ].each { |path| expect(described_class.source?(path)).to be(true), path }
    end

    it 'rejects other roots, other extensions, and typescript outside app/javascript' do
      %w[
        lib/assets/ledger.js
        app/javascript/styles/site.css
        app/javascript/setup.rb
        app/assets/javascripts/legacy/ledger.ts
        app/views/widgets/show.js.erb
      ].each { |path| expect(described_class.source?(path)).to be(false), path }
    end

    it 'rejects vendored, generated, minified and declaration files' do
      %w[
        app/javascript/vendor/chart.js
        app/javascript/node_modules/pkg/index.js
        app/javascript/public/embed.js
        app/javascript/dist/bundle.js
        app/javascript/build/bundle.js
        app/assets/javascripts/builds/application.js
        app/javascript/widgets/picker.min.js
        app/javascript/widgets/components.d.ts
      ].each { |path| expect(described_class.source?(path)).to be(false), path }
    end

    it 'follows configured globs' do
      Woods.configuration.javascript_paths = ['frontend/**/*.{ts,tsx}']

      expect(described_class.source?('frontend/widgets/shipment-card.tsx')).to be(true)
      expect(described_class.source?('app/javascript/entry.js')).to be(false)
    end
  end

  describe '.files' do
    it 'lists matching files sorted and root-relative' do
      Dir.mktmpdir do |root|
        %w[
          app/javascript/b.js app/javascript/a/z.ts app/javascript/vendor/x.js
          app/javascript/readme.md app/assets/javascripts/old.js
        ].each do |relative|
          FileUtils.mkdir_p(File.join(root, File.dirname(relative)))
          File.write(File.join(root, relative), '')
        end

        expect(described_class.files(root))
          .to eq(%w[app/assets/javascripts/old.js app/javascript/a/z.ts app/javascript/b.js])
      end
    end
  end

  describe '.directories' do
    it 'returns the static prefix of each glob' do
      expect(described_class.directories).to eq(%w[app/assets/javascripts app/javascript])
      Woods.configuration.javascript_paths = ['frontend/src/**/*.ts', '**/*.js']
      expect(described_class.directories).to eq(%w[frontend/src])
    end
  end

  describe 'configuration' do
    it 'defaults to the two conventional roots, frozen' do
      expect(Woods.configuration.javascript_paths).to eq(described_class::DEFAULT_GLOBS)
      expect(Woods.configuration.javascript_paths).to be_frozen
    end

    it 'accepts an empty list, which disables the extractor' do
      Woods.configuration.javascript_paths = []

      expect(described_class.source?('app/javascript/entry.js')).to be(false)
    end

    it 'rejects a non-Array, absolute, empty and parent-escaping globs, keeping the previous value' do
      ['app/**/*.js', ['/abs/**/*.js'], [''], ['app/../../x/*.js'], [:js]].each do |value|
        expect { Woods.configuration.javascript_paths = value }
          .to raise_error(Woods::ConfigurationError, /javascript_paths/)
      end
      expect(Woods.configuration.javascript_paths).to eq(described_class::DEFAULT_GLOBS)
    end
  end
end
