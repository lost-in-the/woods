# frozen_string_literal: true

require 'active_support/lazy_load_hooks'

# Rails 7.0 deprecates legacy connection handling and warns once per boot for
# an application that does not opt out; 7.1 removed it. The booted specs
# avoid `load_defaults` to stay neutral across Rails versions, so every
# application they define opts out here, as `load_defaults 6.1` would. Only
# 7.0 defines the module-level setter: 6.x and 7.1+ keep their own defaults.
# Woods itself uses none of the legacy connection-handler APIs.
#
# Applies to applications defined in this process. Fixture boot scripts run
# in their own process and capture their output.
ActiveSupport.on_load(:before_configuration) do
  next unless defined?(ActiveRecord::Railtie) && ActiveRecord.respond_to?(:legacy_connection_handling=)

  config.active_record.legacy_connection_handling = false
end
