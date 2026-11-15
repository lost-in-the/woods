- The Console now rolls back its own work even when the request's connection is already inside an open transaction,
  for example one opened by a host middleware or test harness. `SafeContext` opens a savepoint there and rolls back
  to it, so the Console's writes are discarded while the host's own writes are left for the host to commit or roll
  back. Before, the Console joined the open transaction and its rollback was ignored. The PostgreSQL statement
  timeout no longer stays set for the rest of the host transaction, and a failed Console statement no longer aborts
  the host transaction.
