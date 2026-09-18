Keep credential scanner refresh snapshots limited to live weakly referenced
scanners on older Ruby versions, avoiding unsafe receiver access after garbage
collection while preserving updates to every live Console server.
