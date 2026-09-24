# frozen_string_literal: true

module Woods
  module Console
    # Adapter names differ from the SQL grammar and session settings they use.
    module AdapterFamily
      def self.for(connection)
        name = connection.adapter_name.to_s.downcase
        return :mysql if name.include?('mysql') || name == 'trilogy'
        return :postgres if name.include?('postgre')
        return :sqlite if name.include?('sqlite')

        nil
      end
    end
  end
end
