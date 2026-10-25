# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/mcp/index_reader'
require 'woods/filename_utils'

# Identifier matches rank by match quality (exact, then prefix, then
# substring) independent of directory and summary order, and an in-process
# caller can size the deep-field scan budget per call.
RSpec.describe 'Index search ranking and per-call scan budget' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-search-ranking') }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }

  before { File.write(File.join(index_dir, 'manifest.json'), '{}') }
  after { FileUtils.remove_entry(index_dir) }

  def publish_units(type, rows, order: :given)
    directory = File.join(index_dir, Woods::MCP::IndexReader::TYPE_TO_DIR.fetch(type))
    FileUtils.mkdir_p(directory)
    units = rows.map do |identifier, source|
      unit = { identifier: identifier, type: type, source_code: source || 'unmatched', metadata: {} }
      File.write(File.join(directory, collision_safe_filename(identifier)), JSON.generate(unit))
      unit
    end
    units = units.reverse if order == :reversed
    File.write(File.join(directory, '_index.json'), JSON.generate(units.map { |unit| unit.slice(:identifier, :type) }))
  end

  def identifiers(result)
    result[:results].map { |row| row[:identifier] }
  end

  describe 'identifier ranking' do
    def publish_widgets(order)
      publish_units('controller', [['WidgetsController'], ['Admin::WidgetsController']], order: order)
      publish_units('model', [['BlueWidgetPart'], ['WidgetPart'], ['Widget'], ['Gadget::Widget'], ['Widgetry']],
                    order: order)
      publish_units('database_table', [['table:widgets'], ['table:widget_parts']], order: order)
    end

    it 'puts the exact identifier first, then prefixes, then substrings' do
      publish_widgets(:given)

      expect(identifiers(reader.search('Widget', limit: 50))).to eq(
        %w[Widget Gadget::Widget table:widgets Widgetry WidgetPart table:widget_parts WidgetsController
           Admin::WidgetsController BlueWidgetPart]
      )
    end

    it 'ranks a table by its name, so the table a name search asks for is not cut by the limit' do
      publish_widgets(:given)

      expect(identifiers(reader.search('widgets', limit: 2))).to eq(%w[table:widgets WidgetsController])
    end

    it 'answers the same order whatever order the summaries were published in' do
      publish_widgets(:given)
      given = identifiers(reader.search('Widget', limit: 50))
      FileUtils.rm_rf(Dir[File.join(index_dir, '*/')])
      publish_widgets(:reversed)

      expect(identifiers(Woods::MCP::IndexReader.new(index_dir).search('Widget', limit: 50))).to eq(given)
    end

    it 'ranks an escaped literal query as the literal it names' do
      publish_units('model', [['Widget::Part'], ['Widget::PartList'], ['OldWidget::Part']])

      expect(identifiers(reader.search(Regexp.escape('Widget::Part'), limit: 50)))
        .to eq(%w[Widget::Part Widget::PartList OldWidget::Part])
    end

    it 'ranks a route by its path, not by its HTTP verb' do
      publish_units('route', [['POST /logins'], ['GET /posts'], ['GET /posts/:id']])
      publish_units('controller', [['PostsController']])

      expect(identifiers(reader.search('post', limit: 50)))
        .to eq(['GET /posts', 'GET /posts/:id', 'PostsController', 'POST /logins'])
    end

    it 'keeps identifier matches ahead of deep-field matches' do
      publish_units('model', [['Gadget', 'widget here'], ['Widget']])

      result = reader.search('widget', fields: %w[identifier source_code], limit: 50)
      expect(result[:results].map { |row| [row[:identifier], row[:match_field]] })
        .to eq([%w[Widget identifier], %w[Gadget source_code]])
    end
  end

  describe 'max_scan:' do
    before do
      publish_units('model', Array.new(5) { |i| ["Thing#{i}", i == 4 ? 'needle' : 'hay'] })
    end

    it 'stops at the per-call budget and says how many candidates it read of how many' do
      result = reader.search('needle', fields: %w[source_code], max_scan: 2)

      expect(result[:results]).to eq([])
      expect(result[:completeness]).to include(status: 'partial', reason: 'scan_budget')
      expect(result[:scan]).to eq(scanned_units: 2, candidate_units: 5)
    end

    it 'overrides the environment budget for one call' do
      original = ENV.fetch('WOODS_SEARCH_MAX_SCAN', nil)
      ENV['WOODS_SEARCH_MAX_SCAN'] = '1'
      result = reader.search('needle', fields: %w[source_code], max_scan: 10)

      expect(identifiers(result)).to eq(['Thing4'])
      expect(result[:completeness]).to include(status: 'complete')
      expect(result[:scan]).to eq(scanned_units: 5, candidate_units: 5)
    ensure
      ENV['WOODS_SEARCH_MAX_SCAN'] = original
    end

    it 'refuses a budget that is not a positive integer' do
      [0, -1, 2.5, '10'].each do |budget|
        expect { reader.search('needle', fields: %w[source_code], max_scan: budget) }
          .to raise_error(ArgumentError, /max_scan/)
      end
    end

    it 'reports no scan counts for an identifier-only search' do
      expect(reader.search('Thing')).not_to have_key(:scan)
    end
  end
end
