- Keep column-only Console SQL queries available with unaliased `JOIN ... ON`
  and `JOIN ... USING` clauses under redaction. Clause keywords are no longer
  mistaken for relation aliases; whole-row values and column alias lists
  remain rejected.
