# frozen_string_literal: true

# Minimal Phlex-style component base for booted-app extraction tests.
# PhlexExtractor treats a non-ViewComponent ApplicationComponent as the
# component root (see PHLEX_BASES). app/views is an autoload path in the
# dummy app but — as in real Rails apps — NOT an eager load path, so
# subclasses here are only visible to descendants-based extraction if the
# extractor eager loads lazy roots itself.
class ApplicationComponent
  # PhlexExtractor introspects view_template presence on descendants;
  # defining it here also keeps the class non-empty for linting.
  def view_template; end
end
