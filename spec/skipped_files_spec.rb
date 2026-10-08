# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'json'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractor'
require 'woods/skipped_files'

RSpec.describe Woods::SkippedFiles do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = original
  end

  before do
    stub_const('SkipFixture', Module.new)
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: []))
  end

  let(:report) { described_class.new(root: rails_root.to_s).build(unit_paths) }
  let(:unit_paths) { [] }

  def reason_for(relative)
    report.fetch('files').find { |entry| entry['path'] == relative }&.fetch('reason')
  end

  it 'reports a namespace-only file' do
    create_file('app/models/skip_fixture/billing.rb', "module SkipFixture\n  module Billing; end\nend\n")
    expect(reason_for('app/models/skip_fixture/billing.rb')).to eq('namespace_only')
  end

  it 'does not call a module with a block hook namespace-only' do
    create_file('app/helpers/kit.rb', "module SkipFixture::Kit\n  included do\n    x\n  end\nend\n")
    expect(reason_for('app/helpers/kit.rb')).to eq('not_owned')
  end

  it 'reports a file that declares no class or module' do
    create_file('app/lib/boot_hook.rb', "Rails.logger.info('booted')\n")
    expect(reason_for('app/lib/boot_hook.rb')).to eq('no_declaration')
  end

  it 'reports an unloaded constant assignment file as not_owned' do
    create_file('app/models/skip_fixture/patterns.rb', "SkipFixture::Unloaded = /x/\n")
    expect(reason_for('app/models/skip_fixture/patterns.rb')).to eq('not_owned')
  end

  it 'reports a parse error' do
    create_file('app/lib/broken.rb', "class SkipFixture::Broken\n  def call(\nend\n")
    expect(reason_for('app/lib/broken.rb')).to eq('parse_error')
  end

  it 'calls a namespace-only file under an owned directory namespace_only' do
    stub_const('SkipFixture::Admin', Module.new)
    stub_const('SkipFixture::Admin::Application', Class.new)
    create_file('app/serializers/skip_fixture/admin.rb', "module SkipFixture\n  module Admin; end\nend\n")
    expect(reason_for('app/serializers/skip_fixture/admin.rb')).to eq('namespace_only')
  end

  it 'names the owning extractor when a claimed file yields no unit' do
    create_file('app/services/skip_fixture/helper.rb', "class SkipFixture::Helper\nend\n")
    expect(reason_for('app/services/skip_fixture/helper.rb')).to eq('rejected_by:services')
  end

  it 'names the class family when a class-discovered extractor declines a class' do
    stub_const('ActionController::Base', Class.new)
    path = create_file('app/controllers/skip_fixture/base_controller.rb',
                       "class SkipFixture::BaseController < ActionController::Base\nend\n")
    load path
    expect(reason_for('app/controllers/skip_fixture/base_controller.rb')).to eq('rejected_by:controllers')
  end

  it 'reports a declaration whose ownership cannot be proven as not_owned' do
    create_file('app/lib/skip_fixture/unloaded.rb', "module SkipFixture::Unloaded\n  def call = nil\nend\n")
    expect(reason_for('app/lib/skip_fixture/unloaded.rb')).to eq('not_owned')
  end

  context 'with units already covering some files' do
    let(:unit_paths) do
      [File.join(rails_root.to_s, 'app/helpers/date_helper.rb'), 'app/models/value.rb', nil]
    end

    it 'lists only files no unit names, accepting absolute and relative unit paths' do
      create_file('app/helpers/date_helper.rb', "module DateHelper\n  def d = 1\nend\n")
      create_file('app/models/value.rb', "class Value\nend\n")
      create_file('app/models/billing.rb', "module Billing; end\n")
      expect(report.fetch('files').map { |entry| entry['path'] }).to eq(['app/models/billing.rb'])
    end
  end

  it 'never lists assets, javascript, non-Ruby files, or paths outside the globs' do
    create_file('app/assets/config/manifest.rb', "module Billing; end\n")
    create_file('app/javascript/setup.rb', "module Billing; end\n")
    create_file('app/helpers/notes.txt', 'text')
    create_file('lib/billing.rb', "module Billing; end\n")
    expect(report.fetch('files')).to eq([])
  end

  context 'with GraphQL operation documents' do
    before { hide_const('GraphQL') if defined?(GraphQL) }

    it 'reports an uncovered document as graphql_unavailable when the gem is not loaded' do
      create_file('app/javascript/widgets/widget_list.graphql', 'query WidgetList { widgets { id } }')
      expect(reason_for('app/javascript/widgets/widget_list.graphql')).to eq('graphql_unavailable')
    end

    it 'never lists a document a unit covers, one under node_modules, or one outside the roots' do
      create_file('app/javascript/widgets/covered.graphql', 'query Covered { widgets { id } }')
      create_file('app/javascript/node_modules/pkg/vendored.graphql', 'query Vendored { widgets { id } }')
      create_file('docs/outside.graphql', 'query Outside { widgets { id } }')
      report = described_class.new(root: rails_root.to_s)
                              .build([File.join(rails_root.to_s, 'app/javascript/widgets/covered.graphql')])
      expect(report.fetch('files')).to eq([])
    end

    it 'sorts documents and Ruby files together by path' do
      create_file('app/models/zed.rb', "module Zed; end\n")
      create_file('app/javascript/a.graphql', 'query A { widgets { id } }')
      expect(report.fetch('files').map { |entry| entry['path'] }).to eq(%w[app/javascript/a.graphql app/models/zed.rb])
    end
  end

  it 'summarises counts by reason, sorted by path' do
    create_file('app/models/b.rb', "module B; end\n")
    create_file('app/models/a.rb', "module A; end\n")
    create_file('app/lib/c.rb', "puts 1\n")
    expect(report).to eq(
      'total' => 3,
      'counts' => { 'namespace_only' => 2, 'no_declaration' => 1 },
      'files' => [{ 'path' => 'app/lib/c.rb', 'reason' => 'no_declaration' },
                  { 'path' => 'app/models/a.rb', 'reason' => 'namespace_only' },
                  { 'path' => 'app/models/b.rb', 'reason' => 'namespace_only' }]
    )
  end

  it 'round-trips through the payload directory' do
    payload = Pathname.new(create_file('payload/.keep', '')).dirname
    data = { 'total' => 1, 'counts' => { 'no_declaration' => 1 },
             'files' => [{ 'path' => 'app/lib/c.rb', 'reason' => 'no_declaration' }] }
    described_class.write(payload, data, durable: false)
    expect(described_class.read(payload)).to eq(data)
    expect(described_class.read(payload.join('missing'))).to be_nil
  end
end
