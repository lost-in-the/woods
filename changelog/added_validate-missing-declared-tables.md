- `woods:validate` warns once per table a declared external consumer names
  that the live schema did not have at extraction time, read from each
  `external_consumer` unit's `tables_missing`. Advisory: the index stays valid.
