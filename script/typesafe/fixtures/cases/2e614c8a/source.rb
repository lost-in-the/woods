# frozen_string_literal: true

class FixtureRoutes
  IGNORED_HELPER_PREFIXES = %w[
    asset image stylesheet javascript font audio video file tmp base root log download
  ].freeze

  def initialize(routes)
    @route_helper_map = routes
  end

  def resolve_route_helper(helper_name)
    base = helper_name.sub(/_(path|url)\z/, '')
    return nil if IGNORED_HELPER_PREFIXES.any? { |prefix| base.start_with?("#{prefix}_") || base == prefix }

    @route_helper_map[base]
  end
end
