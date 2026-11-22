- The Console guide has a "Turning the Console off" section.
  It covers the switch, the MCP client entry, a hand-written Rack mount, the token, the launcher file and processes.
  It ends with a check that quotes what a disabled Console prints.
  It also lists what differs on Woods 2.1 and 1.6.
  A new plugin skill, `woods-console-disable` (plugin 2.3.93), finds each of those places in an application.
  It shows the plan, asks before each edit, and verifies the Console is off.
  It never deletes a file, never prints a token value and leaves the Index Server entry alone.
  It opens only Ruby configuration files and removes MCP client entries from plain JSON by key.
  Every other change, the token always among them, is a manual step for the user.
  It removes a client entry only for a Console launcher or the Console URL the user confirms, host and port included.
  It asks about any other entry at or near the Console path.
