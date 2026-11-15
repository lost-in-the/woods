# frozen_string_literal: true

# Included by a group that defines `connection` as a real Active Record
# connection established on ActiveRecord::Base. Every host transaction here
# is a plain joinable `transaction` block: a `joinable: false` outer, as in
# transactional fixtures, would already hand the Console a savepoint.
RSpec.shared_examples 'a Console transaction inside a host transaction' do
  let(:probe_table) { 'woods_console_tx_probe' }
  let(:context) { Woods::Console::SafeContext.new(connection: connection) }
  let(:pool_context) { Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool) }

  before do
    require 'woods/console/safe_context'
    connection.create_table(probe_table, force: true) { |table| table.string :label }
  end

  after { connection.drop_table(probe_table, if_exists: true) }

  def insert_label(label)
    connection.execute("INSERT INTO #{probe_table} (label) VALUES (#{connection.quote(label)})")
  end

  def labels
    connection.select_values("SELECT label FROM #{probe_table}").sort
  end

  it 'discards its write when no host transaction is open' do
    context.execute { insert_label('console') }
    expect(labels).to eq([])
  end

  it 'discards its write inside a host transaction that commits, keeping the host writes' do
    connection.transaction do
      insert_label('host before')
      context.execute { insert_label('console') }
      insert_label('host after')
    end
    expect(labels).to eq(['host after', 'host before'])
  end

  it 'discards its write on the leased pool connection inside ActiveRecord::Base.transaction' do
    ActiveRecord::Base.transaction do
      insert_label('host before')
      pool_context.execute { |leased| leased.execute("INSERT INTO #{probe_table} (label) VALUES ('console')") }
      insert_label('host after')
    end
    expect(labels).to eq(['host after', 'host before'])
  end

  it 'propagates an error from the block, discards its write and leaves the host transaction usable' do
    connection.transaction do
      insert_label('host before')
      expect do
        context.execute do
          insert_label('console')
          raise ArgumentError, 'block failed'
        end
      end.to raise_error(ArgumentError, 'block failed')
      insert_label('host after')
    end
    expect(labels).to eq(['host after', 'host before'])
  end

  it 'propagates a failed statement, discards its write and leaves the host transaction usable' do
    connection.transaction do
      insert_label('host before')
      expect do
        context.execute do
          insert_label('console')
          connection.select_value('SELECT missing_column FROM woods_console_missing_table')
        end
      end.to raise_error(ActiveRecord::StatementInvalid)
      insert_label('host after')
    end
    expect(labels).to eq(['host after', 'host before'])
  end

  it 'discards both writes when Console calls nest with no host transaction open' do
    context.execute do
      insert_label('console outer')
      context.execute { insert_label('console inner') }
    end
    expect(labels).to eq([])
  end

  it 'discards both writes when Console calls nest inside a host transaction' do
    connection.transaction do
      context.execute do
        insert_label('console outer')
        context.execute { insert_label('console inner') }
      end
      insert_label('host')
    end
    expect(labels).to eq(['host'])
  end

  it 'restores the leased-connection thread-local inside a host transaction, on return and on raise' do
    key = Woods::Console::SafeContext::LEASED_CONNECTION_KEY
    Thread.current[key] = :host_lease
    connection.transaction do
      context.execute { expect(Thread.current[key]).to be(connection) }
      expect(Thread.current[key]).to be(:host_lease)
      expect { context.execute { raise ArgumentError } }.to raise_error(ArgumentError)
      expect(Thread.current[key]).to be(:host_lease)
    end
  ensure
    Thread.current[key] = nil
  end
end

# Included by a PostgreSQL or MySQL group alongside the examples above.
# `read_timeout` returns the connection's current statement timeout setting.
RSpec.shared_examples 'a Console statement timeout inside a host transaction' do |read_timeout|
  let(:context) { Woods::Console::SafeContext.new(connection: connection, timeout_ms: 4321) }

  before { require 'woods/console/safe_context' }

  it 'applies its timeout inside the block and restores the host value after it' do
    connection.transaction do
      before_block = read_timeout.call(connection)
      inside = context.execute { read_timeout.call(connection) }
      expect(inside).not_to eq(before_block)
      expect(read_timeout.call(connection)).to eq(before_block)
    end
  end

  it 'restores the host value after a block that raises' do
    connection.transaction do
      before_block = read_timeout.call(connection)
      expect { context.execute { raise ArgumentError } }.to raise_error(ArgumentError)
      expect(read_timeout.call(connection)).to eq(before_block)
    end
  end
end
