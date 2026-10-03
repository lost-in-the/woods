- Parse and chunk large sources in one pass. The AST layer split the whole
  file into lines once per definition, and the chunker recounted the line
  breaks before every slice and the characters of every slice in progress.
  A 1 MB file with 35,000 methods took minutes to parse and now takes under
  a second; splitting a 1 MB chunk into 64-character slices drops from 14s
  to 0.3s. Output is unchanged.
