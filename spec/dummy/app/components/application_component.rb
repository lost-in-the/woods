# frozen_string_literal: true

# Stands in for a Phlex base class. The dummy app does not bundle phlex, and
# PhlexExtractor treats a plain `ApplicationComponent` as the component base,
# so subclasses of this are what its discovery has to find.
class ApplicationComponent
  def self.component_name
    name.demodulize.underscore
  end
end
