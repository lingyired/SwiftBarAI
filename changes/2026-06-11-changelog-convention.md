# 2026-06-11: Introduce Changes directory and recording rule

- **Type:** chore
- **Scope:** docs
- **Author(s):** lingyired, Trae AI (co-author)
- **Commit(s):** TBD
- **Status:** in-progress

## Summary
Introduce a `changes/` directory and a CLAUDE.md rule that requires every non-trivial change to be recorded there. The directory ships with its own `README.md` spec, plus this entry as the first record.

## Motivation
As AI takes over project maintenance, we need a lightweight, structured way to track *what* changed, *why*, and *how it was verified* — both for human review and for future AI sessions picking up the work. The existing docs/ tree covers architecture; `changes/` covers the history of edits on top of that architecture.

## Changes
- `changes/README.md`: full specification of the directory layout, naming, file template, lifecycle, and AI-assistant rules.
- `changes/2026-06-11-changelog-convention.md`: this file — the first record.
- `CLAUDE.md`: new top-level section "变更记录规则（changes/）" describing the rule and linking back to `changes/README.md`.

## Impact
- All future non-trivial commits will include an additional markdown file in `changes/`.
- `CLAUDE.md` now references `changes/README.md`.
- No code or runtime behavior changes.

## Testing
- Verified all three file paths resolve under the project root.
- Verified `CLAUDE.md` still links to the existing `docs/*.md` files and the new `changes/README.md`.
- Verified the new section is reachable from the table of contents (implicit, since CLAUDE.md has no TOC).

## Related
- See [`changes/README.md`](README.md) for the full spec.
- Mirrors the spirit of [Keep a Changelog](https://keepachangelog.com/) but on a per-change basis.
