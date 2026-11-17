# frozen_string_literal: true

require 'spec_helper'
require 'woods/schema_readability'

RSpec.describe Woods::SchemaReadability do
  def database(name, state, error: nil)
    { name: name, state: state, error: error }
  end

  describe '.build' do
    it 'is readable when every database a model reads was read' do
      summary = described_class.build([database('primary', 'readable')])

      expect(summary).to eq('version' => 1, 'state' => 'readable',
                            'databases' => [{ 'name' => 'primary', 'state' => 'readable' }])
    end

    it 'is unreadable when any database is unreachable or empty, and keeps the others' do
      summary = described_class.build([database('billing', 'empty'), database('primary', 'readable')])

      expect(summary['state']).to eq('unreadable')
      expect(summary['databases'].map { |db| db['state'] }).to eq(%w[empty readable])
    end

    it 'is not applicable when no model reads a database' do
      expect(described_class.build([])).to eq('version' => 1, 'state' => 'not_applicable', 'databases' => [])
    end

    it 'never publishes the connection error, which can name hosts, users and paths' do
      error = 'PG::ConnectionBad: host db.internal'
      summary = described_class.build([database('primary', 'unreachable', error: error)])

      expect(JSON.generate(summary)).not_to include('db.internal')
    end
  end

  describe '.from_manifest' do
    it 'returns the published summary' do
      published = described_class.build([database('primary', 'readable')])

      expect(described_class.from_manifest('schema_readability' => published)).to eq(published)
    end

    it 'is unknown for a manifest written before the summary, or none' do
      expect(described_class.from_manifest({})).to eq('state' => 'unknown')
      expect(described_class.from_manifest(nil)).to eq('state' => 'unknown')
    end

    it 'is unknown for a summary version this reader does not know' do
      expect(described_class.from_manifest('schema_readability' => { 'version' => 2, 'state' => 'unreadable' }))
        .to eq('state' => 'unknown')
    end
  end

  describe '.warning' do
    it 'names each unreadable database, what the index lacks and both fixes' do
      summary = described_class.build([database('billing', 'empty'), database('primary', 'unreachable'),
                                       database('reporting', 'readable')])

      warning = described_class.warning(summary)

      expect(warning).to include('billing: holds no tables', 'primary: could not connect')
      expect(warning).not_to include('reporting')
      expect(warning).to include('db:prepare', 'woods:extract', 'woods:seed')
    end

    it 'says nothing for a readable, not applicable or unknown schema' do
      expect(described_class.warning(described_class.build([database('primary', 'readable')]))).to be_nil
      expect(described_class.warning(described_class.build([]))).to be_nil
      expect(described_class.warning(described_class.from_manifest(nil))).to be_nil
    end
  end

  describe '.incremental_problem' do
    it 'asks for a full extraction over an unreadable schema' do
      summary = described_class.build([database('primary', 'empty')])

      expect(described_class.incremental_problem(summary))
        .to eq('an index extracted without a readable database schema (primary: holds no tables)')
    end

    it 'has no problem with any other state' do
      expect(described_class.incremental_problem(described_class.build([database('primary', 'readable')]))).to be_nil
      expect(described_class.incremental_problem(described_class.from_manifest(nil))).to be_nil
    end
  end
end
