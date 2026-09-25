# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/mcp/index_reader'
require 'woods/filename_utils'
require 'woods/extracted_unit'

RSpec.describe 'Index search completeness' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-search-completeness') }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }

  before { File.write(File.join(index_dir, 'manifest.json'), '{}') }
  after { FileUtils.remove_entry(index_dir) }

  def publish_units(type, rows)
    directory = File.join(index_dir, Woods::MCP::IndexReader::TYPE_TO_DIR.fetch(type))
    FileUtils.mkdir_p(directory)
    units = rows.map do |identifier, source, metadata|
      unit = { identifier: identifier, type: type, source_code: source || 'unmatched', metadata: metadata || {} }
      File.write(File.join(directory, collision_safe_filename(identifier)), JSON.generate(unit))
      unit
    end
    File.write(File.join(directory, '_index.json'), JSON.generate(units.map { |unit| unit.slice(:identifier, :type) }))
  end

  it 'does not read units for unscoped or typed identifier searches with typed summaries' do
    publish_units('rails_source', [%w[FrameworkOne needle], %w[FrameworkTwo hay]])
    expect(reader).not_to receive(:load_search_unit)

    [nil, ['rails_source']].each do |types|
      result = reader.search('Framework', types: types)
      expect(result[:results].size).to eq(2)
      expect(result[:completeness]).to include(status: 'complete', total_matches: 2)
    end
  end

  it 'does not inspect an unrelated corrupt legacy family unit for identifier search' do
    publish_units('model', [%w[Needle hay]])
    publish_units('rails_source', [%w[Framework hay]])
    File.write(File.join(index_dir, 'rails_source', '_index.json'), JSON.generate([{ identifier: 'Framework' }]))
    File.write(File.join(index_dir, 'rails_source', collision_safe_filename('Framework')), '{broken')

    result = reader.search('Needle')
    expect(result[:results].map { |row| row[:identifier] }).to eq(['Needle'])
    expect(result[:completeness]).to include(status: 'complete', total_matches: 1)
  end

  it 'retains other deep matches and marks unreadable unit coverage partial' do
    publish_units('rails_source', [%w[Broken needle], %w[Readable needle]])
    File.write(File.join(index_dir, 'rails_source', collision_safe_filename('Broken')), '{broken')

    result = reader.search('needle', fields: ['source_code'])
    expect(result[:results].map { |row| row[:identifier] }).to eq(['Readable'])
    expect(result[:completeness]).to include(status: 'partial', reason: 'unreadable_or_corrupt_source',
                                             has_more: nil, total_matches: nil, matched_lower_bound: 1)
  end

  def with_scan_budget(budget)
    original = ENV.fetch('WOODS_SEARCH_MAX_SCAN', nil)
    ENV['WOODS_SEARCH_MAX_SCAN'] = budget.to_s
    yield
  ensure
    ENV['WOODS_SEARCH_MAX_SCAN'] = original
  end

  %w[identifier source_code metadata].each do |field|
    [0, 1, 2, 3].each do |count|
      it "reports #{count} #{field} matches at limit 2 without inventing a total" do
        rows = Array.new(count) do |i|
          [field == 'identifier' ? "Needle#{i}" : "Record#{i}",
           field == 'source_code' ? 'needle' : nil,
           field == 'metadata' ? { purpose: 'needle' } : nil]
        end
        publish_units('model', rows)

        result = reader.search('needle', fields: [field], limit: 2)

        expect(result[:results].size).to eq([count, 2].min)
        expect(result.fetch(:completeness)).to eq(
          status: count > 2 ? 'partial' : 'complete', reason: count > 2 ? 'result_limit' : 'exhausted',
          has_more: count > 2, total_matches: count > 2 ? nil : count, matched_lower_bound: count
        )
        expect(result[:partial]).to eq(count > 2 ? true : nil)
      end
    end
  end

  it 'looks past nonmatches to distinguish an exact-size deep page from truncation' do
    publish_units('model', [%w[First needle], %w[Second needle], %w[Other hay], %w[Last needle]])

    result = reader.search('needle', fields: ['source_code'], limit: 2)

    expect(result.fetch(:completeness)).to include(reason: 'result_limit', has_more: true,
                                                   total_matches: nil, matched_lower_bound: 3)
    expect(result[:results].map { |row| row[:identifier] }).to eq(%w[First Second])
  end

  it 'does not claim another match when a full page reaches the deep scan budget' do
    publish_units('model', [%w[First needle], %w[Second needle], %w[Last hay]])

    result = with_scan_budget(2) { reader.search('needle', fields: ['source_code'], limit: 2) }

    expect(result.fetch(:completeness)).to eq(status: 'partial', reason: 'scan_budget', has_more: nil,
                                              total_matches: nil, matched_lower_bound: 2)
  end

  it 'is complete when the final candidate exactly consumes the scan budget' do
    publish_units('model', [%w[First needle], %w[Second needle]])

    result = with_scan_budget(2) { reader.search('needle', fields: ['source_code'], limit: 2) }

    expect(result.fetch(:completeness)).to include(status: 'complete', reason: 'exhausted',
                                                   has_more: false, total_matches: 2)
  end

  it 'shares the file budget with lookahead and stops loading after one extra match' do
    publish_units('model', Array.new(8) { |i| ["Record#{i}", 'needle'] })
    loaded = []
    allow(reader).to receive(:load_unit).and_wrap_original do |method, *args|
      loaded << args
      method.call(*args)
    end

    result = with_scan_budget(5) { reader.search('needle', fields: ['source_code'], limit: 2) }

    expect(loaded.size).to eq(3)
    expect(result.fetch(:completeness)).to include(reason: 'result_limit', matched_lower_bound: 3)
  end

  it 'keeps identifier priority and scans deep candidates across types fairly' do
    publish_units('model', [%w[NeedleModel needle], %w[First hay], %w[Second needle]])
    publish_units('service', [%w[NeedleService hay], %w[Worker needle]])

    result = with_scan_budget(2) { reader.search('needle', fields: %w[identifier source_code], limit: 2) }

    expect(result[:results].map { |row| row[:identifier] }).to eq(%w[NeedleModel NeedleService])
    expect(result.fetch(:completeness)).to include(reason: 'result_limit', has_more: true, matched_lower_bound: 3)
  end

  it 'searches each queued type instead of the last unit sharing its identifier' do
    publish_units('model', [['Shared', 'model needle']])
    publish_units('service', [['Shared', 'service hay']])

    result = reader.search('needle', fields: ['source_code'], limit: 2)

    expect(result[:results]).to eq([{ identifier: 'Shared', type: 'model', match_field: 'source_code' }])
    expect(result.fetch(:completeness)).to include(total_matches: 1, status: 'complete')
  end

  it 'counts shared identifiers in different types as distinct matches' do
    publish_units('model', [%w[Shared needle]])
    publish_units('service', [%w[Shared needle]])

    result = reader.search('needle', fields: ['source_code'], limit: 1)

    expect(result[:results]).to eq([{ identifier: 'Shared', type: 'model', match_field: 'source_code' }])
    expect(result.fetch(:completeness)).to include(reason: 'result_limit', matched_lower_bound: 2)
  end

  it 'deduplicates the same typed unit matching several fields or repeated type filters' do
    publish_units('model', [['Needle', 'needle', { purpose: 'needle' }]])

    result = reader.search('needle', types: %w[model model], fields: %w[identifier source_code metadata], limit: 1)

    expect(result[:results].size).to eq(1)
    expect(result.fetch(:completeness)).to include(status: 'complete', total_matches: 1)
  end

  it 'measures completeness only inside the requested literal and type filters' do
    publish_units('model', [['Admin::One', 'needle'], ['Other', 'needle']])
    publish_units('service', [['Admin::Two', 'needle']])

    result = reader.search('needle', types: ['model'], fields: ['source_code'], exact_prefix: 'Admin::', limit: 1)

    expect(result[:results].map { |row| row[:identifier] }).to eq(['Admin::One'])
    expect(result.fetch(:completeness)).to include(status: 'complete', total_matches: 1)
  end

  it 'reports a detected corrupt source instead of claiming a complete search' do
    publish_units('model', [%w[First needle]])
    File.write(File.join(index_dir, 'models', collision_safe_filename('First')), '{broken')

    expect(reader.search('needle', fields: ['source_code'])[:completeness]).to include(
      status: 'partial', reason: 'unreadable_or_corrupt_source', total_matches: nil
    )
  end

  it 'reports a missing source even when the returned page is already full' do
    publish_units('model', [%w[First needle], %w[Second needle]])
    File.unlink(File.join(index_dir, 'models', collision_safe_filename('Second')))

    expect(reader.search('needle', fields: ['source_code'], limit: 1)[:completeness]).to include(
      status: 'partial', reason: 'unreadable_or_corrupt_source', total_matches: nil, matched_lower_bound: 1
    )
  end

  it 'searches real gem-source units sharing the framework directory with their actual typed identities' do
    unit = Woods::ExtractedUnit.new(type: :gem_source, identifier: 'gems/widget/lib/widget.rb',
                                    file_path: '/gems/widget/lib/widget.rb')
    unit.source_code = 'module Widget; needle; end'
    publish_units('rails_source', [[unit.identifier, unit.source_code]])
    File.write(File.join(index_dir, 'rails_source', collision_safe_filename(unit.identifier)), JSON.generate(unit.to_h))
    File.write(File.join(index_dir, 'rails_source', '_index.json'), JSON.generate([{ identifier: unit.identifier }]))

    result = reader.search('needle', types: ['rails_source'], fields: ['source_code'])

    expect(result[:results]).to eq([{ identifier: unit.identifier, type: 'gem_source', match_field: 'source_code' }])
    expect(result[:completeness]).to include(status: 'complete', total_matches: 1)
    expect(reader.each_unit.to_a.first).to include('identifier' => unit.identifier, 'type' => 'gem_source')
  end

  %w[service gem_source].each do |wrong_type|
    it "rejects a #{wrong_type} payload in the model directory" do
      publish_units('model', [%w[Shared needle]])
      path = File.join(index_dir, 'models', collision_safe_filename('Shared'))
      File.write(path, JSON.generate(identifier: 'Shared', type: wrong_type, source_code: 'needle'))

      expect(reader.search('needle', fields: ['source_code'])[:completeness]).to include(
        status: 'partial', reason: 'unreadable_or_corrupt_source', total_matches: nil, matched_lower_bound: 0
      )
    end
  end

  it 'rejects duplicate index identifiers instead of manufacturing an exact total' do
    publish_units('model', [%w[Needle needle]])
    File.write(File.join(index_dir, 'models', '_index.json'), JSON.generate([{ identifier: 'Needle' }] * 2))

    expect { reader.search('needle') }.to raise_error(IOError, /duplicate unit identifier/)
  end

  it 'rejects malformed index entries instead of manufacturing an exact total' do
    publish_units('model', [])
    File.write(File.join(index_dir, 'models', '_index.json'), JSON.generate([{}]))

    expect { reader.search('needle') }.to raise_error(IOError, /invalid or duplicate unit identifier/)
  end

  def timeout_on(text)
    stub_const('Regexp::TimeoutError', Class.new(StandardError))
    pattern = double('bounded pattern')
    allow(pattern).to receive(:match?) do |value|
      raise Regexp::TimeoutError if value == text

      /needle/i.match?(value)
    end
    allow(reader).to receive(:compile_search_pattern).and_return(pattern)
  end

  it 'retains a full page but keeps remaining-match knowledge unknown when lookahead times out' do
    publish_units('model', [%w[First needle], %w[Last timeout]])
    timeout_on('timeout')

    result = reader.search('needle', fields: ['source_code'], limit: 1)

    expect(result[:results].map { |row| row[:identifier] }).to eq(['First'])
    expect(result.fetch(:completeness)).to include(reason: 'regex_timeout', has_more: nil,
                                                   total_matches: nil, matched_lower_bound: 1)
  end

  it 'retains identifier matches when a later type times out' do
    publish_units('model', [['Needle']])
    publish_units('service', [['timeout']])
    timeout_on('timeout')

    result = reader.search('needle', limit: 1)

    expect(result[:results].map { |row| row[:identifier] }).to eq(['Needle'])
    expect(result.fetch(:completeness)).to include(reason: 'regex_timeout', matched_lower_bound: 1)
  end

  it 'reports a timeout during broad-pattern diagnostics as incomplete' do
    publish_units('model', [['timeout'], ['Needle']])
    timeout_on('timeout')

    result = reader.search('needle')

    expect(result.fetch(:completeness)).to include(status: 'partial', reason: 'regex_timeout',
                                                   total_matches: nil, matched_lower_bound: 0)
  end

  it 'keeps lookahead and completeness on one generation when publication advances during a read' do
    publish_units('model', [%w[First needle], %w[Second needle]])
    first = File.join(index_dir, 'payloads', 'gen-1')
    second = File.join(index_dir, 'payloads', 'gen-2')
    [first, second].each do |path|
      FileUtils.mkdir_p(path)
      FileUtils.cp_r(File.join(index_dir, 'models'), path)
      FileUtils.cp(File.join(index_dir, 'manifest.json'), path)
    end
    changed_unit = File.join(second, 'models', collision_safe_filename('Second'))
    File.write(changed_unit, JSON.generate(identifier: 'Second', type: 'model', source_code: 'hay'))
    generation = Woods::Generation.new(output_dir: index_dir)
    generation.bump!(reason: 'full', payload: 'payloads/gen-1')
    advanced = false
    allow(reader).to receive(:load_unit).and_wrap_original do |method, *args|
      unless advanced
        generation.bump!(reason: 'incremental', payload: 'payloads/gen-2')
        advanced = true
      end
      method.call(*args)
    end

    first_result = reader.search('needle', fields: ['source_code'], limit: 1)
    second_result = reader.search('needle', fields: ['source_code'], limit: 1)

    expect(first_result.fetch(:completeness)).to include(reason: 'result_limit', has_more: true)
    expect(second_result.fetch(:completeness)).to include(status: 'complete', total_matches: 1)
  end
end
