---
paths:
  - "docs/**/*.md"
---
# Documentation Conventions

All major layers are implemented. These docs are reference material for users and contributors — not planning documents.

Rules:
- All configuration examples must show both MySQL and PostgreSQL variants. Never default to one database over the other. MySQL examples should appear first or alongside PostgreSQL, never buried at the bottom.
- Code examples use Ruby with realistic class/method names from the project (`CodebaseIndex::`, `ExtractedUnit`, `Retriever`, etc.)
- SQL examples must be valid for the stated database. Mark adapter-specific syntax clearly.
- When adding a new backend option, update `docs/BACKEND_MATRIX.md` with the detailed analysis.
- Keep the `docs/README.md` index current when adding new documents.
- Use tables for comparison data, prose for explanations. Avoid bullet-point-heavy sections.
