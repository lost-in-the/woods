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
    #
    # Only the run's own queries count: those of the calling thread and of
    # threads started through {.thread}. The subscription also hears every
    # other thread of the process, and an application thread that queries a
    # pool, then holds its only connection, says nothing about whether the
    # run could read it.
    class ServedPools
      EVENT = 'sql.active_record'
      # The thread variable naming the tracker a thread's queries count for.
      THREAD_KEY = :woods_served_pools

      # Track the pools that answer the calling thread's queries while the block runs.
      #
      # @yieldparam served [ServedPools]
      # @return [Object] the block's value
      def self.during
        served = new
        return yield served unless defined?(ActiveSupport::Notifications)

        subscriber = ActiveSupport::Notifications.subscribe(EVENT) { |*event| served.note(event.last) }
        begin
          served.on_this_thread { yield served }
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end

      # Start a thread whose queries count for the run tracking the calling
      # thread, when one is.
      #
      # @yield the thread's work
      # @return [Thread]
      def self.thread(&work)
        served = Thread.current.thread_variable_get(THREAD_KEY)
        Thread.new { served ? served.on_this_thread(&work) : work.call }
      end

      def initialize
        @pools = {}.compare_by_identity
        @lock = Mutex.new
      end

      # Count the current thread's queries, in any of its fibers, while the block runs.
      #
      # @return [Object] the block's value
      def on_this_thread
        thread = Thread.current
        previous = thread.thread_variable_get(THREAD_KEY)
        thread.thread_variable_set(THREAD_KEY, self)
        begin
          yield
        ensure
          thread.thread_variable_set(THREAD_KEY, previous)
        end
      end

      # Record the pool behind one finished query of the run. A query that
      # raised served nothing, and another thread's query is not the run's.
      #
      # @param payload [Hash] the `sql.active_record` payload
      # @return [void]
      def note(payload)
        return unless payload.is_a?(Hash) && payload[:exception].nil?
        return unless Thread.current.thread_variable_get(THREAD_KEY).equal?(self)

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
