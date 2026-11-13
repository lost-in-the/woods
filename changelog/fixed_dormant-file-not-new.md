- A file with no commit in the 365-day history window is published as `change_frequency: dormant`, not `new`.
  `new` now means the commit that created the file is inside the window.
  A long-committed file nobody touched for a year read as `commit_count: 0`, no contributors and `new`,
  which looked like a file that was never committed.
  Retrieval ranks such a unit as dormant; run a full `woods:extract` to replace labels already published.
