# frozen_string_literal: true

require 'woods'
require_relative 'client'
require_relative 'rate_limiter'
require_relative 'document_builder'

module Woods
  module Unblocked
    # Orchestrates syncing Woods extraction data to an Unblocked collection.
    #
    # Reads extraction output from disk via IndexReader, converts units to
    # condensed Markdown documents, and pushes via the Unblocked Documents API.
    # All syncs are idempotent — documents are upserted by URI.
    #
    # @example
    #   exporter = Exporter.new(index_dir: "tmp/woods")
    #   stats = exporter.sync_all
    #   # => { synced: 940, skipped: 5060, errors: [] }
    #
    class Exporter
      MAX_ERRORS = 100

      # Unit types to sync, in priority order.
      # All units are synced for these types.
      FULL_SYNC_TYPES = %w[
        model controller service job mailer manager decorator concern serializer
        graphql graphql_type graphql_mutation graphql_resolver graphql_query
      ].freeze

      # Unit types where only the most-connected units are synced.
      # Each entry: [type, max_count]
      PARTIAL_SYNC_TYPES = [
        ['poro', 100],
        ['lib', 50]
      ].freeze

      # @param index_dir [String] Path to extraction output directory
      # @param config [Configuration] Woods configuration (default: global config)
      # @param client [Client, nil] Unblocked API client (auto-created from config if nil)
      # @param reader [Object, nil] IndexReader instance (auto-created if nil)
      # @param output [IO] Progress output stream (default: $stdout)
      # @raise [ConfigurationError] if required config is missing
      def initialize(index_dir:, config: Woods.configuration, client: nil, reader: nil, output: $stdout)
        @collection_id = config.unblocked_collection_id
        raise ConfigurationError, 'unblocked_collection_id is required' unless @collection_id

        repo_url = config.unblocked_repo_url
        raise ConfigurationError, 'unblocked_repo_url is required' unless repo_url

        api_token = config.unblocked_api_token
        raise ConfigurationError, 'unblocked_api_token is required' unless api_token

        budget = ENV.fetch('UNBLOCKED_DAILY_BUDGET', RateLimiter::DEFAULT_BUDGET).to_i
        limiter = RateLimiter.new(daily_budget: budget)

        @client = client || Client.new(api_token: api_token, rate_limiter: limiter)
        @reader = reader || build_reader(index_dir)
        @builder = DocumentBuilder.new(repo_url: repo_url)
        @output = output
      end

      # Sync all configured unit types to the Unblocked collection.
      #
      # @return [Hash] { synced: Integer, skipped: Integer, errors: Array<String> }
      def sync_all
        synced = 0
        skipped = 0
        errors = []

        FULL_SYNC_TYPES.each do |type|
          result = sync_type(type)
          synced += result[:synced]
          skipped += result[:skipped]
          errors.concat(result[:errors])
        end

        PARTIAL_SYNC_TYPES.each do |type, max_count|
          result = sync_type_partial(type, max_count)
          synced += result[:synced]
          skipped += result[:skipped]
          errors.concat(result[:errors])
        end

        { synced: synced, skipped: skipped, errors: cap_errors(errors) }
      end

      # Sync all units of a given type.
      #
      # @param type [String] Unit type (e.g. "model", "controller")
      # @return [Hash] { synced: Integer, skipped: Integer, errors: Array<String> }
      def sync_type(type)
        units = @reader.list_units(type: type)
        log "  #{type}: #{units.size} units"

        sync_units(units)
      end

      # Sync the top N most-connected units of a type (by dependent count).
      #
      # @param type [String] Unit type
      # @param max_count [Integer] Maximum units to sync
      # @return [Hash] { synced: Integer, skipped: Integer, errors: Array<String> }
      def sync_type_partial(type, max_count)
        units = @reader.list_units(type: type)
        return empty_stats if units.empty?

        # Load full data to sort by dependent count
        units_with_data = units.filter_map do |entry|
          data = @reader.find_unit(entry['identifier'])
          next unless data

          dep_count = (data['dependents'] || []).size
          { entry: entry, data: data, dep_count: dep_count }
        end

        top_units = units_with_data.sort_by { |u| -u[:dep_count] }.first(max_count)
        skipped_count = [units.size - max_count, 0].max

        log "  #{type}: #{top_units.size}/#{units.size} units (top by dependents)"

        result = sync_unit_data(top_units.map { |u| [u[:entry], u[:data]] })
        result[:skipped] += skipped_count
        result
      end

      private

      def sync_units(units)
        synced = 0
        skipped = 0
        errors = []

        units.each do |entry|
          unit_data = @reader.find_unit(entry['identifier'])
          unless unit_data
            skipped += 1
            next
          end

          push_document(unit_data)
          synced += 1
        rescue Woods::Error => e
          errors << "#{entry['identifier']}: #{e.message}"
          break if e.message.include?('daily budget exhausted')
        rescue StandardError => e
          errors << "#{entry['identifier']}: #{e.message}"
        end

        { synced: synced, skipped: skipped, errors: errors }
      end

      def sync_unit_data(entries_with_data)
        synced = 0
        skipped = 0
        errors = []

        entries_with_data.each do |entry, unit_data|
          push_document(unit_data)
          synced += 1
        rescue Woods::Error => e
          errors << "#{entry['identifier']}: #{e.message}"
          break if e.message.include?('daily budget exhausted')
        rescue StandardError => e
          errors << "#{entry['identifier']}: #{e.message}"
        end

        { synced: synced, skipped: skipped, errors: errors }
      end

      def push_document(unit_data)
        doc = @builder.build(unit_data)
        @client.put_document(
          collection_id: @collection_id,
          title: doc[:title],
          body: doc[:body],
          uri: doc[:uri]
        )
      end

      def build_reader(index_dir)
        require_relative '../mcp/index_reader'
        Woods::MCP::IndexReader.new(index_dir)
      end

      def empty_stats
        { synced: 0, skipped: 0, errors: [] }
      end

      def cap_errors(errors)
        return errors if errors.size <= MAX_ERRORS

        errors.first(MAX_ERRORS) + ["... and #{errors.size - MAX_ERRORS} more errors"]
      end

      def log(message)
        @output&.puts(message)
      end
    end
  end
end
