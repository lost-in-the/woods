- Every class-based unit records an `:inheritance` dependency edge to its
  application-defined parent class, typed as the unit the parent's own
  extractor publishes: models (STI parents), Phlex and ViewComponent
  components, jobs, serializers, services, plain Ruby objects, policies,
  decorators, validators, managers, libraries, Action Cable channels and
  GraphQL types join controllers and mailers, which already carried it
  (LOS-124). The parent is the runtime superclass, never a parsed name. A
  framework or gem parent, an abstract Active Record base (which the model
  extractor never publishes) and any parent no extractor publishes record no
  edge, so the graph carries no edge to a missing unit.
