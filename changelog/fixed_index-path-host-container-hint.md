- When the Index Server is pointed at a directory that does not exist, it now says that this process sees nothing at
  that path, and that a server inside a container needs the container path while a host launch needs the host path,
  before the advice to run `woods:extract`.
  A host path given to a container launch used to send the developer to re-extract an index that already existed.
