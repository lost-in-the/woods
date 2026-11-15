- `SECURITY.md` now says what counts as a vulnerability. A report that crosses a boundary Woods enforces
  (authentication, a disabled Console, a write or eval capability, code execution, another client's data) gets a
  private fix, a patch release and an advisory. Gaps in the Console's best-effort protections (redaction, the
  credential scanner, the SQL policy, rollback, result limits) are hardening: fixed in public, shipped in the next
  ordinary release, and not backported to 1.6.x. The supported versions table names 2.1.x as the current line.
