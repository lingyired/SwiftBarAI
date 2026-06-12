# Changes Directory

This directory records every non-trivial change to the SwiftBar project. It is the single source of truth for "what changed, why, and how it was verified" — for both human reviewers and future AI sessions picking up the work.

## When to record

Record a change whenever you:

- Add a new feature
- Modify or remove an existing feature
- Fix a bug
- Refactor code or project structure
- Change the build, CI, or release process
- Update documentation that affects user-visible behavior

Trivial changes (typo fixes, comment-only edits, formatting) do not need a record.

## File naming

`YYYY-MM-DD-<short-slug>.md`

- `YYYY-MM-DD` — ISO 8601 date of the change.
- `<short-slug>` — lowercase, hyphen-separated, 3-5 words describing the change.

Examples:

- `2026-06-11-code-wiki-documentation.md`
- `2026-06-11-changelog-convention.md`
- `2026-06-12-fix-shell-quoting-bug.md`

If multiple unrelated changes happen on the same day, append `-2`, `-3`, … to disambiguate. Related changes can share one slug (e.g. one record covering a multi-commit feature).

## File template

```markdown
# YYYY-MM-DD: <Title>

- **Type:** feat | fix | docs | refactor | perf | chore | test
- **Scope:** <affected module/area>     (optional)
- **Author(s):** <name(s)>
- **Commit(s):** <short SHA(s), comma-separated>
- **Status:** in-progress | done

## Summary
One paragraph describing what changed.

## Motivation
Why this change was made. What problem does it solve? Reference any user requests, bugs, or design notes.

## Changes
- `path/to/file1.swift`: description
- `path/to/file2.md`: description
- `path/to/file3.swift:LL-LL`: description (use line ranges for surgical changes)

## Impact
- Backward compatibility
- New API surface (public types, functions, URL hosts, env vars, …)
- User-visible behavior changes (menu rendering, new tabs, default values, …)

## Testing
How was this change verified? Manual steps, unit tests, integration tests, etc.

## Related
- Issue / PR links
- Cross-references to other change records (`changes/2026-06-10-…`)
- External docs / xbar references
```

## Lifecycle

1. **Create the record** with `Status: in-progress` *before* or *alongside* the code change.
2. **Commit the code and the record together** in a single commit (or a tightly coupled follow-up commit referencing the same change).
3. **Update the record** with the final commit SHA(s) and flip the status to `done`.

If the change is abandoned, leave the record in place with `Status: in-progress` and a note in **Summary** explaining why it was dropped.

## Conventions

- **Use English for content** so the records can be aggregated into GitHub release notes without translation.
- **One change per file** — do not bundle unrelated work.
- **Do not delete old records.** If the directory grows too large, move older entries to `changes/archive/`. Session-scoped debug iterations (e.g. p12 → p27 chasing the same icon-rendering bug) belong in a single per-session subdirectory under `archive/` so the chronology is preserved without polluting the top-level `changes/`.
- For multi-commit or branch-based work, use one record with a list of commit SHAs.
- For purely visual / documentation changes inside `docs/`, a `docs:` type record is still required so the rule has no exceptions.

## For AI assistants

When you make any non-trivial change to this project, you **MUST** create a record in `changes/` as part of the same commit. Read this `README.md` first to understand the format, then add the file before pushing.
