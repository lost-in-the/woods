# frozen_string_literal: true

module Woods
  module Console
    # Coordinates scanner construction and rotation without retaining servers
    # after their transports release them. Requests keep their own index snapshot.
    class CredentialScannerRegistry
      def initialize
        @scanners = ObjectSpace::WeakMap.new
        @mutex = Mutex.new
      end

      def register
        @mutex.synchronize do
          scanner = yield
          # Older Ruby WeakMap implementations validate the value's liveness
          # when enumerating. Keep the scanner in both weak positions so an
          # immortal sentinel cannot make an abandoned scanner look live.
          @scanners[scanner] = scanner
          scanner
        end
      end

      def rebuild
        @mutex.synchronize do
          scanners = @scanners.values
          return nil if scanners.empty?

          index = yield
          scanners.each { |scanner| scanner.replace_index!(index) }
          index
        end
      end
    end
  end
end
