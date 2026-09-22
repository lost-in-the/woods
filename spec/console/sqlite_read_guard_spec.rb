# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/sql_validator'
require 'woods/console/table_gate'

RSpec.describe 'SQLite read grammar boundaries' do
  let(:validator) { Woods::Console::SqlValidator.new(dialect: :sqlite) }
  let(:gate) { Woods::Console::TableGate.new(blocked_tables: ['blocked'], model_tables: {}) }

  ["SELECT message FROM 'blocked'", 'SELECT message FROM [blocked]',
   'SELECT message FROM (blocked)', 'SELECT message FROM allowed, (blocked)',
   "SELECT message FROM main.'blocked'", 'SELECT message FROM allowed JOIN (blocked) ON 1=1',
   "SELECT 'load_extension'('ignored')", 'SELECT [load_extension](\'ignored\')'].each do |sql|
    it "refuses unsupported SQLite grammar: #{sql}" do
      expect { validator.validate!(sql) }.to raise_error(Woods::Console::SqlValidationError)
    end
  end

  ['SELECT message FROM allowed', 'SELECT count(*) FROM "allowed"',
   'SELECT message FROM `allowed`', "SELECT 'FROM [blocked]' AS message FROM allowed",
   'SELECT * FROM (SELECT message FROM allowed) AS result',
   'SELECT * FROM allowed a JOIN other b ON a.id = b.id'].each do |sql|
    it "retains supported SQLite reads: #{sql}" do
      expect { validator.validate!(sql) }.not_to raise_error
    end
  end

  it 'still checks canonical quoted and schema-qualified blocked tables' do
    ['SELECT * FROM "blocked"', 'SELECT * FROM `blocked`', 'SELECT * FROM main.blocked'].each do |sql|
      expect { gate.check_sql!(sql, dialect: :sqlite) }.to raise_error(Woods::Console::TableGateError)
    end
  end
end
