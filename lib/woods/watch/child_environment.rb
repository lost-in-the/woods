# frozen_string_literal: true

module Woods
  module Watch
    # Restore Bundler's original environment while preserving the selected
    # application Gemfile. Each child must resolve the current lockfile anew.
    module ChildEnvironment
      NIL_VALUE = 'BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL'
      ACTIVATION_KEYS = %w[BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLE_LOCKFILE].freeze

      # @param env [Hash] complete intended application environment
      # @param root [String] application working directory
      # @return [Hash] independent environment for exec with unsetenv_others
      def self.build(env, root:)
        result = env.dup
        gemfile = result['BUNDLE_GEMFILE']
        ACTIVATION_KEYS.each { |key| result.delete(key) }
        env.each do |key, value|
          next unless key.start_with?('BUNDLER_ORIG_')

          original = key.delete_prefix('BUNDLER_ORIG_')
          value == NIL_VALUE ? result.delete(original) : result[original] = value
          result.delete(key)
        end
        result['BUNDLE_GEMFILE'] = File.expand_path(gemfile, root) if gemfile && !gemfile.empty?
        result
      end
    end
  end
end
