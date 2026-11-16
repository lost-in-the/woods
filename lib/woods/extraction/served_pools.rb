# frozen_string_literal: true

module Woods
  module Extraction
    # The connection pools that answered a query during one extraction run.
    #
    # A schema read that timed out waiting for a pool means something only
    # with this beside it: a pool that served another read in the same run is
    # a database the run could read, so an empty result from it is a gap, not
    # a database without tables. A pool that answered nothing all run is one
    # the run could not reach, which a full run publishes and warns about.
    class ServedPools
      EVENT = 'sql.active_record'

      # Track the pools that answer queries while the block runs.
      #
      # @yieldparam served [ServedPools]
      # @return [Object] the block's value
      def self.during
        served = new
        return yield served unless defined?(ActiveSupport::Notifications)

        subscriber = ActiveSupport::Notifications.subscribe(EVENT) { |*event| served.note(event.last) }
        begin
          yield served
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end

      def initialize
        @pools = {}.compare_by_identity
        @lock = Mutex.new
      end

      # Record the pool behind one finished query. A query that raised served nothing.
      #
      # @param payload [Hash] the `sql.active_record` payload
      # @return [void]
      def note(payload)
        return unless payload.is_a?(Hash) && payload[:exception].nil?

        pool = pool_for(payload)
        @lock.synchronize { @pools[pool] = true } if pool
      end

      # @param pool [Object] a connection pool
      # @return [Boolean] whether the pool answered a query during the run
      def served?(pool)
        @lock.synchronize { @pools.key?(pool) }
      end

      private

      # The payload's connection when it carries one; otherwise (Rails 6.0)
      # the pool holding the connection the payload names by object id.
      def pool_for(payload)
        connection = payload[:connection]
        return connection.pool if connection.respond_to?(:pool)

        id = payload[:connection_id]
        id && pool_holding(id)
      rescue StandardError
        nil
      end

      def pool_holding(connection_id)
        return unless defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connection_handler)

        ActiveRecord::Base.connection_handler.connection_pool_list.find do |pool|
          pool.connections.any? { |connection| connection.object_id == connection_id }
        end
      end
    end
  end
end
