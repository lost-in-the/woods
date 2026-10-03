- Serializer extraction finds runtime descendants of application-defined
  bases (any class it admits from `app/serializers` or `app/blueprinters`), so
  method-only and DSL-only subclasses are indexed at any depth. Standalone
  classes under `app/serializers` named `*Serializer` are admitted without a
  superclass. Serializer units now record `metadata[:parent_class]`.
