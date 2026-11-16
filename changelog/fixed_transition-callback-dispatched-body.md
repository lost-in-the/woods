- State machine `transition_callbacks` now describe the method body Ruby runs, as model callbacks do.
  The method was found by name in the model file, so a method defined twice reported the discarded definition.
  A same-named method in a class earlier in the file could be read in place of the machine's.
  A prepended module was not read at all, so its override reported the class's own body.
  The loaded class's `source_location` now picks the definition, and a `super` in it continues into the next body.
  A prepended `app/models` concern now joins the analysis source.
  A body outside the model file and its concerns gives `unanalysed: not defined in the model or its concerns`.
  A class that is not loaded gives the new reason `class not loaded`.
