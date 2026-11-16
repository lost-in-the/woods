- Two extraction runs in one process no longer share a staging directory.
  Every run in a process finds the same held writer lock, and the stage was named after that lock's token alone.
  A direct `Extractor` call beside a locked writer therefore emptied the writer's stage and wrote into it.
  Whichever run published first then published a generation mixing both runs' files.
  Each run now stages as `payloads/.stage-<n>-<token>-<run>`.
  The run that publishes second is refused with `generation moved to <n> during publication` and removes its own
  stage.
- A child process forked while the parent holds the index writer lock no longer acts as its holder.
  The child inherited the lock object, its registry entry and its token, so it passed the publish fence.
  It could also delete the parent's live lock, for example by leaving a `with_lock` block after a `fork` without a
  block.
  Ownership is now bound to the process that acquired the lock.
  In a child, the lock is not found for the index, its fence refuses, its heartbeat does nothing, and its release
  leaves the lock file alone.
