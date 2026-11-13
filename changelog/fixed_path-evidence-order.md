- The `path` tool's evidence no longer depends on hop order. A path whose weakest class is `static` read
  `at least static` whenever its first `static` hop came from a label two mechanisms share, even when a later
  hop was exactly `static`; it now reads `static` and names that exact hop as `weakest_hop`. A path is
  `at least` its class only when every hop of that class is.
