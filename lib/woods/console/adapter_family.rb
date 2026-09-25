# frozen_string_literal: true

module Woods
  module Console
    # Adapter names differ from the SQL grammar and session settings they use.
    module AdapterFamily
      # Classify a live connection by adapter ancestry, database configuration,
      # then its display name. Unknown families remain nil: SQL callers must
      # refuse rather than silently omit dialect-specific safeguards.
      # @param connection [Object] Active Record connection or compatible adapter
      # @return [Symbol, nil] :postgres, :mysql, :sqlite, or unknown
      def self.for(connection)
        ancestry = connection.class.ancestors.filter_map(&:name)
        return :postgres if ancestry.include?('ActiveRecord::ConnectionAdapters::PostgreSQLAdapter')
        return :mysql if ancestry.any? { |name| name.match?(/::(?:AbstractMysql|Mysql2|Trilogy)Adapter\z/) }
        return :sqlite if ancestry.include?('ActiveRecord::ConnectionAdapters::SQLite3Adapter')

        from_name(configured_adapter(connection)) || from_name(connection.adapter_name)
      end

      def self.configured_adapter(connection)
        return unless connection.respond_to?(:pool) && connection.pool.respond_to?(:db_config)

        connection.pool.db_config.adapter
      end
      private_class_method :configured_adapter

      def self.from_name(value)
        name = value.to_s.downcase
        return :mysql if name.include?('mysql') || %w[trilogy mariadb].include?(name)
        return :postgres if name.include?('postgre') || %w[postgis cockroachdb redshift].include?(name)
        return :sqlite if name.include?('sqlite')

        nil
      end
      private_class_method :from_name
    end
  end
end
