# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/sql_validator'
require 'woods/console/table_gate'

RSpec.describe 'Compound table policy' do
  %i[postgres mysql sqlite].each do |dialect|
    [
      'SELECT b.message FROM (SELECT 1) AS a, blocked AS b',
      'SELECT b.message FROM allowed a JOIN (SELECT 1) AS x, blocked b',
      'SELECT c.message FROM allowed a JOIN allowed b ON (1=1), blocked c',
      'SELECT b.message FROM allowed AS "WHERE", blocked b',
      'SELECT b.message FROM allowed AS "ORDER", blocked b'
    ].each do |sql|
      it "enforces the #{dialect} blocked-table policy: #{sql}" do
        gate = Woods::Console::TableGate.new(blocked_tables: ['blocked'], model_tables: {})
        Woods::Console::SqlValidator.new(dialect: dialect).validate!(sql)
        expect { gate.check_sql!(sql, dialect: dialect) }.to raise_error(Woods::Console::TableGateError, /blocked/)
      end
    end
  end

  it 'keeps commas and parentheses inside quoted aliases from hiding later tables' do
    sql = 'SELECT b.message FROM allowed AS "(,", blocked b'
    expect(Woods::Console::SqlTableScanner.identifiers_in(sql, dialect: :postgres)).to include('blocked')
  end
end
