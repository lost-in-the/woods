# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

# CON-2. `console_sql` was validated twice: once by the ToolSpec handler with a
# dialect-blind `SqlValidator.new` (the conservative postgres+mysql union), and
# again inside {Woods::Console::EmbeddedExecutor#handle_sql} with
# `SqlValidator.new(dialect: sql_dialect)` — the dialect-aware validator the
# PR-248 round-2 work added. Because the handler runs first, on a MySQL host the
# union's PostgreSQL view of `\'` ended the literal early, exposed a `for
# update` that is prose inside a string, and rejected the statement before the
# executor could accept it. The dialect-aware path was therefore dead on both
# real transports (stdio and HTTP); only a direct `executor.send_request` call
# reached it.
#
# These examples drive the *registered* tool — the same DispatchPipeline the
# transports call — against a MySQL adapter stub. No Rails boot required: the
# executor's dialect comes from `connection.adapter_name`.
RSpec.describe 'console_sql dialect-aware validation through the dispatch pipeline' do
  let(:registry) { { 'Note' => %w[id body] } }
  let(:model_validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:model_tables) { { 'Note' => 'notes' } }

  # `\'` is an escaped apostrophe in MySQL's default mode, so `for update` here
  # is prose inside one string literal — valid, non-locking MySQL.
  let(:mysql_escaped_apostrophe) do
    "SELECT * FROM notes WHERE body = 'customer\\'s request for update'"
  end

  let(:result) { Struct.new(:columns, :rows).new(%w[id body], [[1, 'hi']]) }

  def connection_for(adapter_name)
    conn = double('Connection')
    allow(conn).to receive(:adapter_name).and_return(adapter_name)
    allow(conn).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(conn).to receive(:execute)
    # SafeContext reads the session statement timeout before overriding it on
    # MySQL, then restores it in an ensure.
    allow(conn).to receive(:select_value).and_return(0)
    allow(conn).to receive(:select_all).and_return(result)
    conn
  end

  def build_server(adapter_name)
    conn = connection_for(adapter_name)
    server = Woods::Console::Server.build_embedded(
      model_validator: model_validator,
      safe_context: Woods::Console::SafeContext.new(connection: conn),
      connection: conn,
      model_tables: model_tables,
      read_tools_enabled: true
    )
    [server, conn]
  end

  def call_console_sql(server, sql)
    tool = server.instance_variable_get(:@tools).fetch('console_sql')
    tool.call(sql: sql, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  around do |example|
    previous = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = previous
  end

  it 'accepts a MySQL escaped-apostrophe literal on a MySQL host' do
    server, conn = build_server('Mysql2')

    response = call_console_sql(server, mysql_escaped_apostrophe)

    expect(response.error?).to be_falsey, response_text(response)
    expect(conn).to have_received(:select_all).with(mysql_escaped_apostrophe)
  end

  it 'still refuses a genuine row-lock clause on a MySQL host' do
    server, conn = build_server('Mysql2')

    response = call_console_sql(server, 'SELECT * FROM notes FOR UPDATE')

    expect(response).to be_error
    expect(response_text(response)).to match(/row-lock|FOR UPDATE/i)
    expect(conn).not_to have_received(:select_all)
  end

  it 'still refuses DML through the pipeline' do
    server, conn = build_server('Mysql2')

    response = call_console_sql(server, 'DELETE FROM notes')

    expect(response).to be_error
    expect(conn).not_to have_received(:select_all)
  end

  it 'keeps the PostgreSQL reading of the same literal on a PostgreSQL host' do
    # Under PostgreSQL's standard_conforming_strings the backslash does not
    # escape the quote, so the literal ends at `\'` and `for update` really is
    # a row-lock clause. The dialect-aware validator must still refuse it.
    server, conn = build_server('PostgreSQL')

    response = call_console_sql(server, mysql_escaped_apostrophe)

    expect(response).to be_error
    expect(conn).not_to have_received(:select_all)
  end

  it 'keeps the conservative union for an unknown adapter' do
    server, conn = build_server('SomeFutureDB')

    response = call_console_sql(server, mysql_escaped_apostrophe)

    expect(response).to be_error
    expect(conn).not_to have_received(:select_all)
  end
end
