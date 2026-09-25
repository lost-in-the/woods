# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/adapter_family'

RSpec.describe Woods::Console::AdapterFamily do
  %w[PostGIS CockroachDB Redshift Custom].each do |name|
    it "uses PostgreSQL ancestry before the #{name} adapter label" do
      parent = Class.new
      stub_const('ActiveRecord::ConnectionAdapters::PostgreSQLAdapter', parent)
      connection = Class.new(parent).new
      connection.define_singleton_method(:adapter_name) { name }
      expect(described_class.for(connection)).to eq(:postgres)
    end
  end

  { 'PostgreSQL' => :postgres, 'Mysql2' => :mysql, 'Trilogy' => :mysql,
    'SQLite' => :sqlite, 'OtherAdapter' => nil }.each do |name, family|
    it "classifies the #{name} label conservatively" do
      expect(described_class.for(double(adapter_name: name))).to eq(family)
    end
  end

  it 'uses the database configuration when a wrapper provides no known ancestry' do
    connection = double(adapter_name: 'Custom', pool: double(db_config: double(adapter: 'postgresql')))
    expect(described_class.for(connection)).to eq(:postgres)
  end
end
