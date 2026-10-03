- Extract `.haml` templates under `app/views` as `view_template` units with
  partial, instance-variable, helper, controller, and navigation metadata.
  Scans follow HAML's comma-continued multi-line Ruby and skip non-Ruby filter
  and silent-comment bodies. No HAML gem is loaded at extraction time.
