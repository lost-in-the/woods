- A task spec that describes a rake namespace (`describe "ledger"`) now links to every `ledger:*` task and records `rake_namespace`, and one that describes a task links to that `rake_task` unit.
  A task-shaped describe that names neither is kept as the description, with no edge to a unit that does not exist.
