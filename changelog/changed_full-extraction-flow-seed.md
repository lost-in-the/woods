- A full extraction no longer seeds its private stage with the previous generation's `flows/` documents.
  The run writes every flow document and index again and sweeps the rest, or removes `flows/` when `precompute_flows`
  is off, so the hardlinks were made only to be replaced.
  On the large testbed app (3,266 flow files) this removes about 1 second from a full extraction over an existing
  index.
