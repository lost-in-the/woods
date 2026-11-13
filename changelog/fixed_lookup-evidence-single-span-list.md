- A compact or outline `lookup` no longer sends every selected span twice.
  The evidence text already names each span's kind, lexical owner, name and published lines, so the records in
  `structuredContent.data.evidence.spans` now carry only `name`, `start_byte` and `end_byte`, plus `receiver` and
  `physical_location` when present.
  A 41-method outline drops from 15,928 to 8,851 characters sent.
  Unit-level provenance and `codebase_retrieve` evidence records are unchanged.
