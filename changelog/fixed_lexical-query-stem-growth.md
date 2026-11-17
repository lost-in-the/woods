- Lexical retrieval no longer keeps every new word a query contains.
  The index stemmed query terms through the same memo it fills while tokenizing the corpus, so each term no unit holds
  stayed in memory until the next generation was built, outside the token cache's budget.
  A long-lived lexical server grew by up to about 145 KB per maximum-size query of new words.
  The memo is now frozen once the index is built; query terms are stemmed without being kept, and matching is unchanged.
