- Factory options are read from the parsed `factory` call: options on continuation lines, hash-rocket options (`:parent => :page`), and `aliases` combined with other options are all honored, and a `factory` inside a string or comment is no longer a definition.
  Factory units record `aliases`, and a parent named by alias links to the factory that owns the alias.
