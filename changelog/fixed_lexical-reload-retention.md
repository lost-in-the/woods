- An explicit `reload` in lexical mode no longer keeps the corpus it replaced.
  The served retriever took only the new snapshot and kept the index, retriever and decoded units it had built itself,
  so it held two corpora until the next generation was built.
  A reload now installs the new build's whole state, and the next generation reuses the installed corpus.
