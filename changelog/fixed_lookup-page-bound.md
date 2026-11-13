- A `lookup` page is now at most its page limit, measured on the whole text sent.
  JSON pages were sized by each part's own text, without the indentation they are printed at or the
  escapes of a cut string, and text pages did not count their position lines, so a page could run well
  past the limit.
  Every part is now measured as it is printed beside the page's `lookup_page` object at its longest, and
  a long string is cut by its escaped length.
  A `max_chars` below 1,000, or (in JSON) one at which a single list item does not fit, is refused with
  `invalid_params` and `_meta.required_max_chars`.
  Pages are cut differently than before, so an `answer_id` from an earlier version is refused as stale.
