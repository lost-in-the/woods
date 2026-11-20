- A job whose queue comes from a block (`queue_as { ... }`) no longer publishes the block's
  `#<Proc:0x... path:line>` text as its `queue` metadata.
  That text held a process address and a host file path, so two full extractions of the same app differed.
  The class-discovery path now applies the rule generated jobs already follow:
  a queue stated as a string or symbol is kept by name, and a computed one is left out.
