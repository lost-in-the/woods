# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'Portable pre-push review fixtures' do
  let(:fixtures) { File.expand_path('../../../script/typesafe/fixtures', __dir__) }

  def run_fixture(script, *arguments, root: fixtures)
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(root, script), *arguments,
                                           unsetenv_others: true)
    expect(error).to eq('')
    [JSON.parse(output), status.exitstatus]
  end

  it 'executes six candidates and distinguishes three regressions from three valid changes' do
    report, status = run_fixture('evaluate.rb')

    expect(status).to eq(0)
    expect(report.fetch('cases').size).to eq(6)
    expect(report.fetch('cases').map { |row| row.fetch('status') }.uniq).to eq(['verified'])
    expect(report.fetch('cases').group_by { |row| row.fetch('observed') }.transform_values(&:size))
      .to eq('regression' => 3, 'satisfied' => 3)
    expect(report.fetch('cases').all? { |row| row.fetch('baseline_satisfied') }).to be(true)
    expect(report.fetch('cases').all? { |row| row.fetch('smoke_satisfied') }).to be(true)
  end

  it 'exports only one neutral review packet with nonempty before/after changes and complete smoke tests' do
    manifest = JSON.parse(File.read(File.join(fixtures, 'evaluator', 'cases.json')))
    manifest.fetch('cases').each do |row|
      packet, status = run_fixture('packet.rb', row.fetch('case_id'))
      expect(status).to eq(0)
      expect(packet.keys.sort).to eq(%w[case_id files schema_version task])
      expect(packet.fetch('files').keys.sort).to eq(%w[LICENSE.txt before.rb change.patch source.rb test.rb])
      expect(packet.fetch('files').fetch('LICENSE.txt')).to include('Copyright (c) 2024-2026 Leah Armstrong')
      expect(packet.fetch('files').fetch('before.rb')).not_to eq(packet.fetch('files').fetch('source.rb'))
      expect(packet.fetch('files').fetch('change.patch')).to include('--- a/source.rb', '+++ b/source.rb', '@@')
      expect(packet.fetch('files').fetch('test.rb')).to include('raise')
      expect(JSON.generate(packet)).not_to match(/expected|regression|buggy|fixed|github\.com|#38[26]|#390/i)
    end
  end

  it 'keeps paired candidates on the same baseline, task, and visible tests' do
    manifest = JSON.parse(File.read(File.join(fixtures, 'evaluator', 'cases.json')))
    manifest.fetch('cases').group_by { |row| row.fetch('family') }.each_value do |pair|
      packets = pair.map { |row| run_fixture('packet.rb', row.fetch('case_id')).first }
      expect(packets.map { |packet| packet.fetch('task') }.uniq.size).to eq(1)
      %w[before.rb test.rb].each do |name|
        expect(packets.map { |packet| packet.fetch('files').fetch(name) }.uniq.size).to eq(1)
      end
    end
  end

  it 'rejects unsupported cache domains while allowing punctuation inside components' do
    %w[7d43a9f1 9b0e27d4].each do |id|
      %w[before.rb source.rb].each do |filename|
        scope = Module.new
        path = File.join(fixtures, 'cases', id, filename)
        scope.module_eval(File.read(path), path)
        cache = scope.const_get(:FixtureCache)

        ['search:1:', :'search:1:', :unknown, 'search', nil].each do |domain|
          expect { cache.cache_key(domain) }.to raise_error(ArgumentError, 'unsupported cache domain')
        end
        search = cache.cache_key(:search, ':')
        metadata = cache.cache_key(:metadata, ':')
        expect(search).not_to eq(metadata)
      end
    end
  end

  it 'reports infrastructure failure separately while evaluating the remaining candidates' do
    Dir.mktmpdir('woods-review-fixtures') do |temporary|
      FileUtils.cp_r(fixtures, File.join(temporary, 'kit'))
      root = File.join(temporary, 'kit')
      manifest = JSON.parse(File.read(File.join(root, 'evaluator', 'cases.json')))
      id = manifest.fetch('cases').first.fetch('case_id')
      File.write(File.join(root, 'cases', id, 'source.rb'), 'def invalid(')

      report, status = run_fixture('evaluate.rb', root: root)
      expect(status).to eq(2)
      expect(report.fetch('cases').size).to eq(6)
      expect(report.fetch('cases').count { |row| row.fetch('status') == 'infrastructure_error' }).to eq(1)
      expect(report.fetch('cases').count { |row| row.fetch('status') == 'verified' }).to eq(5)
    end
  end

  it 'rejects an unknown packet ID without reading evaluator labels into the output' do
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(fixtures, 'packet.rb'), '../evaluator')
    expect(status.exitstatus).to eq(2)
    expect(JSON.parse(output).keys).to eq(['error'])
    expect(error).to eq('')
  end

  it 'returns a behavioral mismatch rather than an infrastructure failure for an incorrect expectation' do
    Dir.mktmpdir('woods-review-fixtures') do |temporary|
      FileUtils.cp_r(fixtures, File.join(temporary, 'kit'))
      root = File.join(temporary, 'kit')
      path = File.join(root, 'evaluator', 'cases.json')
      manifest = JSON.parse(File.read(path))
      manifest.fetch('cases').first['expected'] = 'satisfied'
      File.write(path, JSON.generate(manifest))

      report, status = run_fixture('evaluate.rb', root: root)
      expect(status).to eq(1)
      expect(report.fetch('cases').first.fetch('status')).to eq('unexpected_behavior')
      expect(report.fetch('cases').none? { |row| row.fetch('status') == 'infrastructure_error' }).to be(true)
    end
  end
end
