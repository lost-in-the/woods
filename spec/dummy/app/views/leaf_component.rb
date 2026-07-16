# frozen_string_literal: true

# A component that is never referenced during boot — it only loads if the
# extractor eager loads app/views (Rails excludes it from eager loading).
class LeafComponent < ApplicationComponent
  def view_template; end
end
