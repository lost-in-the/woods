# frozen_string_literal: true

# The dummy app has no config/application.rb: `Rails::Application` is a
# singleton, so each booted spec constructs the application class itself. This
# file holds what a real app's config/application.rb would carry, so the booted
# specs configure one app rather than two.
module WoodsDummyConfig
  module_function

  # @param config [Rails::Application::Configuration]
  # @param root [String] the dummy app root this boot uses
  # @return [void]
  def apply(config, root)
    # Rails leaves app/views out of both autoload_paths and eager_load_paths.
    # An app that keeps components beside their templates opts the subtree into
    # autoloading only, which is exactly the shape B-184 was found in: the
    # class exists on disk and is reachable by name, but `descendants` has
    # never heard of it.
    config.autoload_paths << File.join(root, 'app', 'views')
  end
end
