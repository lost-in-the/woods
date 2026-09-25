# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/sql_validator'
require 'woods/console/embedded_executor'

RSpec.describe Woods::Console::SqlValidator, 'identifier syntax' do
  [nil, :postgres].each do |dialect|
    context "with dialect #{dialect.inspect}" do
      subject(:validator) { described_class.new(dialect: dialect) }

      ['SELECT U&"label" FROM reports', 'SELECT label FROM u&"reports"'].each do |sql|
        it "refuses unsupported escaped identifiers in #{sql}" do
          expect { validator.validate!(sql) }
            .to raise_error(Woods::Console::SqlValidationError, /escaped identifiers.*ordinary quoted identifiers/)
        end
      end

      [
        'SELECT "label" FROM "reports"',
        %q(SELECT 'U&"label"' AS label FROM reports),
        'SELECT label FROM reports /* U&"label" */',
        "SELECT label FROM reports -- U&\"label\"\n",
        'SELECT menu&"label" FROM reports'
      ].each do |sql|
        it "preserves supported SQL in #{sql.inspect}" do
          expect { validator.validate!(sql) }.not_to raise_error
        end
      end
    end
  end

  it 'preserves escaped-identifier text inside an ordinary PostgreSQL quoted identifier' do
    expect { described_class.new(dialect: :postgres).validate!('SELECT "U&""label""" FROM reports') }
      .not_to raise_error
  end

  it 'preserves PostgreSQL dollar-quoted literal contents' do
    expect { described_class.new(dialect: :postgres).validate!('SELECT $$U&"label"$$ AS label') }
      .not_to raise_error
  end

  it 'preserves MySQL bitwise expressions whose quoted operand is a string' do
    validator = described_class.new(dialect: :mysql, mysql_modes: { ansi_quotes: false, no_backslash_escapes: false })
    expect { validator.validate!('SELECT u&"label" FROM reports') }.not_to raise_error
  end
end

RSpec.describe Woods::Console::EmbeddedExecutor, 'unsupported SQL identifier refusal' do
  it 'returns a validation error before adapter query execution' do
    connection = double('connection', adapter_name: 'PostgreSQL', execute: nil)
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    safe_context = Woods::Console::SafeContext.new(connection: connection)
    validator = Woods::Console::ModelValidator.new(registry: {})
    executor = described_class.new(model_validator: validator, safe_context: safe_context,
                                   connection: connection, read_tools_enabled: true)
    expect(connection).not_to receive(:select_all)

    response = executor.send_request('tool' => 'sql', 'params' => { 'sql' => 'SELECT U&"label" FROM reports' })

    expect(response).to include('ok' => false, 'error_type' => 'validation')
    expect(response['error']).to include('escaped identifiers')
  end
end
