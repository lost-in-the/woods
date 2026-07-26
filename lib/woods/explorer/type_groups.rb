# frozen_string_literal: true

module Woods
  module Explorer
    # Maps the 30+ extracted unit types into eight visual families plus a
    # muted "other" bucket. The family list is ordered — each family occupies
    # one fixed categorical color slot in the frontend palette, and the order
    # is part of the palette's colorblind-safety contract (see
    # docs/EXPLORER.md). Every family also carries a single-letter glyph that
    # is drawn inside graph nodes so identity never rides on color alone.
    module TypeGroups
      # Ordered family definitions. :types lists the singular unit types that
      # belong to the family (as persisted in extraction output).
      FAMILIES = [
        { key: 'data', label: 'Models & data', glyph: 'M',
          types: %w[model migration database_view state_machine] },
        { key: 'http', label: 'Controllers & HTTP', glyph: 'C',
          types: %w[controller route action_cable_channel middleware engine
                    graphql_type graphql_mutation graphql_resolver graphql_query] },
        { key: 'view', label: 'Views & presentation', glyph: 'V',
          types: %w[view_template component view_component decorator serializer] },
        { key: 'domain', label: 'Services & domain', glyph: 'S',
          types: %w[service manager poro lib validator event] },
        { key: 'async', label: 'Jobs & mail', glyph: 'J',
          types: %w[job scheduled_job mailer] },
        { key: 'policy', label: 'Policies & auth', glyph: 'P',
          types: %w[policy pundit_policy] },
        { key: 'test', label: 'Tests & factories', glyph: 'T',
          types: %w[test_mapping factory] },
        { key: 'support', label: 'Concerns & support', glyph: 'X',
          types: %w[concern configuration rake_task caching i18n] }
      ].freeze

      # Catch-all family for framework sources and unknown types.
      OTHER = { key: 'other', label: 'Framework & other', glyph: '·', types: [] }.freeze

      # type (singular String) => family key
      TYPE_TO_GROUP = FAMILIES.each_with_object({}) do |family, map|
        family[:types].each { |type| map[type] = family[:key] }
      end.freeze

      # @param type [String] singular unit type
      # @return [String] family key ('data', 'http', ..., 'other')
      def self.group_for(type)
        TYPE_TO_GROUP.fetch(type.to_s, OTHER[:key])
      end

      # All families including the catch-all, in slot order.
      #
      # @return [Array<Hash>] frozen family definitions
      def self.all
        FAMILIES + [OTHER]
      end
    end
  end
end
