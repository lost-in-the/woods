# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/javascript_paths'

module JavascriptPathsSpecGlobs
  WITH_TESTS = [*Woods::JavascriptPaths::DEFAULT_GLOBS, 'app/javascript/**/*.test.ts',
                'app/javascript/**/__tests__/**/*.js', 'app/javascript/spec/**/*.js'].freeze
end

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

    it 'rejects JavaScript test files under the default roots' do
      %w[
        app/javascript/widgets/picker.test.ts
        app/javascript/widgets/picker.spec.js
        app/javascript/widgets/__tests__/picker.js
        app/javascript/widgets/__mocks__/api.ts
        app/javascript/spec/helpers/setup.js
        app/javascript/test/fixtures/ledger.js
        app/assets/javascripts/spec/support.js
      ].each { |path| expect(described_class.source?(path)).to be(false), path }
    end

    it 'keeps modules whose names merely contain test or spec' do
      %w[
        app/javascript/widgets/test_runner.js
        app/javascript/specs_panel/index.js
        app/javascript/widgets/contest.js
        app/javascript/widgets/inspector.ts
      ].each { |path| expect(described_class.source?(path)).to be(true), path }
    end

    it 'indexes test files only through a glob that names them' do
      Woods.configuration.javascript_paths = JavascriptPathsSpecGlobs::WITH_TESTS

      expect(described_class.source?('app/javascript/widgets/picker.test.ts')).to be(true)
      expect(described_class.source?('app/javascript/widgets/__tests__/picker.js')).to be(true)
      expect(described_class.source?('app/javascript/spec/helpers/setup.js')).to be(true)
      expect(described_class.source?('app/javascript/widgets/__mocks__/api.ts')).to be(false)
      expect(described_class.source?('app/javascript/widgets/picker.ts')).to be(true)
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

  describe '.shapes' do
    it 'pairs each glob directory with only the module extensions that glob accepts' do
      expect(described_class.shapes).to eq(
        [['app/assets/javascripts', %w[.js], false], ['app/javascript', %w[.js .ts .jsx .tsx .mjs], false]]
      )
    end

    it 'marks the globs that name test files' do
      Woods.configuration.javascript_paths = ['app/javascript/**/*.js', 'app/javascript/spec/**/*.js']

      expect(described_class.shapes).to eq([['app/javascript', %w[.js], false], ['app/javascript/spec', %w[.js], true]])
    end

    it 'accepts every module extension for a glob that names none, and skips globs that can match no module' do
      Woods.configuration.javascript_paths = ['frontend/src/**/*', 'legacy/**/*.coffee', '**/*.ts', 'lib/js/*.{ts,css}']

      expect(described_class.shapes)
        .to eq([['frontend/src', %w[.js .ts .jsx .tsx .mjs], false], ['lib/js', %w[.ts], false]])
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
