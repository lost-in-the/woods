# frozen_string_literal: true

require_relative 'credential_index'

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
          if scanner.indexed_secrets && scanner.indexed_secrets == @current_secrets
            scanner.replace_index!(@effective_index)
          end
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
          effective = retain_previous(index, scanners)
          scanners.each { |scanner| scanner.replace_index!(effective) }
          index
        end
      end

      private

      # Only a changed credential set advances the window. Build everything
      # before installing it so failed refreshes preserve the existing window.
      def retain_previous(index, scanners)
        current = @current_secrets || scanners.flat_map { |scanner| scanner.indexed_secrets.to_a }.to_set
        previous = index.secrets == current ? (@previous_secrets || Set.new) : current
        effective = CredentialIndex.new(secrets: (index.secrets | previous).to_a)
        @current_secrets = index.secrets
        @previous_secrets = previous.freeze
        @effective_index = effective
      end
    end
  end
end
