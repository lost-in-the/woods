- Only if you ran a 2.2 prerelease: `metadata.methods` entries change kind or visibility for always-private
  methods such as `initialize`, for `module_function :name` written after the definitions, and for
  `private_class_method`/`public_class_method`. Woods 2.1 published no method table.
  Run a full `woods:extract` after upgrading: an incremental run rewrites the table only on the units it
  re-extracts with changed content, so unchanged units keep the old entries until then.
