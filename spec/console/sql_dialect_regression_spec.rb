# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/table_gate'
require 'woods/console/sql_validator'

RSpec.describe 'Console SQL dialect boundaries' do
  let(:gate) { Woods::Console::TableGate.new(blocked_tables: ['private.records'], model_tables: {}) }

  it 'does not hide a MySQL table behind adjacent subtraction operators' do
    expect { gate.check_sql!('SELECT 1--1 FROM private.records') }.to raise_error(Woods::Console::TableGateError)
  end

  ['private . records', 'private/**/./**/records', '"private" . "records"', '`private` . `records`'].each do |table|
    it "gates qualified table #{table}" do
      expect { gate.check_sql!("SELECT 1 FROM #{table}") }.to raise_error(Woods::Console::TableGateError)
      expect { gate.check_sql!("SELECT 1 FROM allowed JOIN #{table} ON true") }
        .to raise_error(Woods::Console::TableGateError)
    end
  end

  it 'does not interpret MySQL dollar identifiers as PostgreSQL quoted strings' do
    expect { gate.check_sql!('SELECT $tag$ FROM private.records WHERE $tag$ = 1', dialect: :mysql) }
      .to raise_error(Woods::Console::TableGateError)
  end

  it 'checks functions and semicolons after MySQL subtraction' do
    validator = Woods::Console::SqlValidator.new(dialect: :mysql)
    expect { validator.validate!('SELECT 1--1 + SLEEP(1)') }.to raise_error(Woods::Console::SqlValidationError)
    expect { validator.validate!('SELECT 1--1; SELECT 2') }.to raise_error(Woods::Console::SqlValidationError)
    expect { validator.validate!('SELECT 1--1') }.not_to raise_error
  end
end
