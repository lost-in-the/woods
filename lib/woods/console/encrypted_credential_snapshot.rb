# frozen_string_literal: true

require 'active_support/encrypted_configuration'

module Woods
  module Console
    # A private, uncached Rails configuration for one credential-index build.
    # Unlike Rails' permissive configuration reader, a missing encrypted file
    # must raise during an explicit refresh rather than erase the last index.
    class EncryptedCredentialSnapshot < ActiveSupport::EncryptedConfiguration
      def read
        ActiveSupport::EncryptedFile.instance_method(:read).bind(self).call
      end
    end
  end
end
