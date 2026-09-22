# frozen_string_literal: true

class FixtureRoutes
  def initialize(routes)
    @route_helper_map = routes
  end

  def resolve_route_helper(helper_name)
    base = helper_name.delete_suffix('_path').delete_suffix('_url')
    @route_helper_map[base]
  end
end
