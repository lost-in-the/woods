- Extract `.haml` templates under `app/views` as `view_template` units with
  partial, instance-variable, helper, controller, and navigation metadata.
  Scans follow HAML's comma-continued multi-line Ruby, skip silent-comment
  bodies, and read only the `#{...}` interpolations of non-Ruby filter bodies
  (`:javascript`, `:plain`, `:css`, ...). No HAML gem is loaded at extraction
  time.
