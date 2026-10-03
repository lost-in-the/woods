# frozen_string_literal: true

# Route-set doubles for extractor specs that read `Rails.application.routes`
# without booting Rails.
module RouteDoubles
  # @return [RSpec::Mocks::Double] a stand-in for ActionDispatch::Journey::Route
  def route_double(verb:, path:, controller:, action:, name: nil, constraints: {})
    spec = double('PathSpec', to_s: "#{path}(.:format)")
    double('Route', verb: verb, path: double('Path', spec: spec), name: name, constraints: constraints,
                    defaults: { controller: controller, action: action })
  end

  # Replace the Rails double with one whose application serves +routes+.
  #
  # @param routes [Array<RSpec::Mocks::Double>]
  # @param root [Pathname] Rails.root for the double
  # @param logger [Object] Rails.logger for the double
  # @return [void]
  def stub_route_set(routes, root:, logger:)
    named = routes.select(&:name).to_h { |route| [route.name, route] }
    route_set = double('RouteSet', routes: routes, named_routes: named)
    stub_const('Rails', double('Rails', root: root, logger: logger, application: double('App', routes: route_set)))
  end
end

RSpec.configure { |config| config.include RouteDoubles }
