- When the Puma launcher stops unexpectedly, Puma's log now says that maintenance is inactive until Puma restarts,
  and that restarting Puma resumes it.
  It no longer tells the developer to fix the launcher configuration, which sent them looking for a fault that was
  usually not there (a killed launcher prints the same message); it points at any error the launcher printed instead.
