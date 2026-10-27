# frozen_string_literal: true

require 'timeout'

module Woods
  module UpdateCheck
    module_function

    # Wait for an outstanding background probe, if any.
    #
    # @param timeout [Numeric, nil] seconds to wait; nil waits for completion
    # @return [void]
    def await_refresh(timeout: nil)
      BackgroundRefresh.await(timeout: timeout)
    end

    # Stop an outstanding background probe. Waits up to +timeout+ for it to
    # finish, then kills it. Safe to call when nothing is running.
    #
    # @param timeout [Numeric] seconds to let the probe finish
    # @return [void]
    def shutdown(timeout: 0)
      BackgroundRefresh.shutdown(timeout: timeout)
    end

    # --- internals -----------------------------------------------------------

    def cached_status_hash(current:, cache_path: default_cache_path, ttl: CACHE_TTL, now: Time.now,
                           fetcher: method(:fetch_latest_version))
      return status_payload(result(current, nil)) if disabled?

      entry = read_cache(cache_path)
      fresh = entry && fresh_entry?(entry, ttl, now)
      payload = status_payload(result(current, entry && entry['latest']))
      return payload if fresh

      BackgroundRefresh.start do
        Timeout.timeout(REFRESH_TIMEOUT) { refresh(cache_path, now, fetcher) }
      rescue Timeout::Error
        write_cache(cache_path, nil, now)
      end
      payload.merge(pending: true)
    end

    # Owns the single background thread that refreshes the update cache, so a
    # status call can answer from cache and never wait on the network.
    module BackgroundRefresh
      LOCK = Mutex.new
      private_constant :LOCK

      class << self
        # Run the block on a new thread unless a probe is already running.
        #
        # @yield the bounded probe
        # @return [void]
        def start(&block)
          LOCK.synchronize do
            next if @thread&.alive?

            @thread = Thread.new do
              Thread.current.report_on_exception = false
              block.call
            end
          end
          nil
        end

        # @param timeout [Numeric, nil] seconds to wait; nil waits for completion
        # @return [void]
        def await(timeout: nil)
          current&.join(timeout)
          nil
        end

        # Let the probe finish for +timeout+ seconds, then kill it.
        #
        # @param timeout [Numeric]
        # @return [void]
        def shutdown(timeout: 0)
          thread = current
          return unless thread

          thread.kill unless thread.join(timeout)
          thread.join
          LOCK.synchronize { @thread = nil if @thread.equal?(thread) }
          nil
        end

        private

        def current
          LOCK.synchronize { @thread }
        end
      end
    end
  end
end
