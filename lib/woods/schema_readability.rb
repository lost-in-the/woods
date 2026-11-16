# frozen_string_literal: true

module Woods
  # Whether a full extraction could read the database schema its models use,
  # published in each generation's manifest as `schema_readability`.
  #
  # Model columns, schema headers and table units come from the live
  # database, not from `db/schema.rb`. A checkout whose database is missing,
  # refuses the connection or was never migrated still extracts, and its index
  # describes models with no columns, or none at all, as if that were the
  # application. This summary says so, so readers can warn instead.
  #
  # State:
  # - `readable`: every writable database was listed, and each one a concrete
  #   model reads holds at least one table or view.
  # - `unreadable`: at least one database is `unreachable` (listing raised) or
  #   `empty` (a modeled database holding only the Rails bookkeeping tables).
  # - `not_applicable`: there is no database to ask (no Active Record, or no
  #   configured connection).
  # - `unknown`: the manifest predates the summary. Never warned about.
  #
  # Database configuration names and states only: a connection error can
  # name hosts, users and paths, so it goes to the log, never the index.
  module SchemaReadability
    VERSION = 1
    MANIFEST_KEY = 'schema_readability'

    UNREADABLE = 'unreadable'

    CAUSES = { 'unreachable' => 'could not connect', 'empty' => 'holds no tables' }.freeze

    module_function

    # Database names and states only. An incremental run carries the
    # baseline's summary, so it holds nothing an ordinary edit moves, such as
    # a per-database model count.
    #
    # @param databases [Array<Hash>] `{name:, state:}` per database, from
    #   {Extractors::TableCatalog.schema_readability}
    # @return [Hash] string-keyed, JSON-ready
    def build(databases)
      published = databases.map { |database| { 'name' => database[:name], 'state' => database[:state] } }
      state = if published.empty? then 'not_applicable'
              elsif published.all? { |database| database['state'] == 'readable' } then 'readable'
              else UNREADABLE
              end

      { 'version' => VERSION, 'state' => state, 'databases' => published }
    end

    # @param manifest [Hash, nil] a parsed manifest
    # @return [Hash] the published summary, or `{'state' => 'unknown'}`
    def from_manifest(manifest)
      summary = manifest.is_a?(Hash) ? manifest[MANIFEST_KEY] : nil
      return { 'state' => 'unknown' } unless summary.is_a?(Hash) && summary['version'] == VERSION

      summary
    end

    # The warning a task, the validator or a status report shows.
    #
    # @param summary [Hash] a {.build} or {.from_manifest} result
    # @return [String, nil] nil unless the schema was unreadable
    def warning(summary)
      return unless summary['state'] == UNREADABLE

      "The database schema could not be read when this index was extracted (#{causes(summary)}). " \
        'Models on those databases are missing or have no columns, and their table units are missing. ' \
        'Prepare the database (bin/rails db:prepare) and run woods:extract again, or seed this index ' \
        'from a checkout whose database is ready (rake "woods:seed[DIR]").'
    end

    # Why an incremental run cannot build on this index: it would keep every
    # model it does not touch as the unreadable run left it.
    #
    # @param summary [Hash] a {.build} or {.from_manifest} result
    # @return [String, nil] nil unless the schema was unreadable
    def incremental_problem(summary)
      return unless summary['state'] == UNREADABLE

      "an index extracted without a readable database schema (#{causes(summary)})"
    end

    # @param summary [Hash] a {.build} or {.from_manifest} result
    # @return [String] each unreadable database and why, as
    #   `primary: could not connect; billing: holds no tables`
    def causes(summary)
      Array(summary['databases']).filter_map do |database|
        cause = CAUSES[database['state']]
        "#{database['name'] || 'default'}: #{cause}" if cause
      end.join('; ')
    end
  end
end
