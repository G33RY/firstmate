---
name: decision-ledger
description: >-
  Agent-only contract for firstmate's per-project decision ledger: the durable record of captain-level calls firstmate makes on its own.
  Load whenever firstmate, working autonomously - away mode, a standing keep-going instruction, or a long run the captain is not watching turn by turn - answers a question that would otherwise be the captain's, overrules a worker or blocks delivery, or catches its own mistake including a correction to an earlier entry.
  Also load from /stow and from the away-mode return to check this session for any such call that was never logged.
user-invocable: false
metadata:
  internal: true
---

# decision-ledger

Autonomous work answers questions that would otherwise have been the captain's.
Left in the conversation, those answers are lost the moment the session ends.
The decision ledger is the durable record: what was asked, what was decided, and why, kept where a captain can audit it without re-reading a transcript.

This is not `captain-hold-lifecycle`'s primitive.
A held task is an open question blocking work until the captain answers it.
A ledger entry is the closed record of a call already made, most often one firstmate decided on its own without escalating at all.
The two are unrelated: a captain-hold's answer may be worth a ledger entry (see "overruled" below when the answer reverses a worker), but most ledger entries never touch the hold mechanism.

## One ledger per project, living across sessions

The ledger is keyed by project, never by session or by day.
A decision taken on a project in March appends to the same file as one taken in September.
Use the same project name used in `projects/` and `data/projects.md`; firstmate's own tooling decisions use the literal name `firstmate`.

- `data/decisions/<project>/ledger.md` - the durable record. Markdown, append-only: a correction is a new entry that references the earlier one, never an edit to it, so the ledger still shows what was actually decided at the time.
- `data/decisions/<project>/page.json` - that ledger's published-page identity, in whichever of the two shapes below applies. Never hand-edit it.

Both are created lazily on first use. A project that has never taken an autonomous decision gets no `data/decisions/<project>/` directory at all.

## Durable record first, published page second

Append to `ledger.md` immediately, every time, regardless of whether a page is ever published.
The file on disk is the record; the page is only how the captain reads it, and the record must be correct with no page ever having existed.

After appending, if `data/decisions/<project>/page.json` already exists, refresh that same page in the same turn so it is never stale.
If it does not exist yet, publish on the next explicit reason to (the captain asks to see it, or `/stow` or the away-mode return finds entries with no page yet) rather than publishing uninvited the first time a project takes its first decision.

Render the complete current `ledger.md` as one self-contained artifact - inline or CDN-only assets, no sibling local files - before either publish path below.
The `dataviz` and `lavish-axi design` guidance apply to how it looks; a `table`-shaped rendering of the ledger's entries is the natural fit.

### Two surfaces, never both for one project

A Claude artifact is the preferred surface: it is private to the captain's own account, needs no password relayed, and updates the same URL forever.
The hosted ht-ml.app page (`bin/fm-decision-ledger-page.sh`) exists only because a shell script cannot publish a Claude artifact; use it as the fallback when artifact publishing is not available in the current run.

1. **No record exists yet for this project.**
   If this session can publish a Claude artifact, publish the rendered ledger as one and write `data/decisions/<project>/page.json` yourself (plain file write, no script - the same reason appending markdown needs no script) with the artifact's URL and whatever identifier that tool needs to update the same artifact again, for example `{"url": "...", "artifact_id": "..."}`.
   Never write a `site_id`, `update_key`, or `password` field for an artifact record: those belong only to the hosted-page shape below and would misrepresent what this page actually is.
   Otherwise, fall back to the hosted page: `bin/fm-decision-ledger-page.sh publish <project> <path/to/rendered.html>` creates it and writes `data/decisions/<project>/page.json` itself in its own shape (`site_id`, `update_key`, `url`, `password`).
2. **A record already exists.**
   A record carrying a `site_id` field is the hosted-page shape; read and update it only through `bin/fm-decision-ledger-page.sh publish <project> <path/to/rendered.html>` - never hand-roll a second publish path or call `lavish-axi share` against it, since that recreates the page under a new URL, exactly the pile of orphaned links this contract exists to avoid.
   A record without one is an artifact record; update that same artifact directly and, if its identifier or URL changed, rewrite the sidecar yourself to match.
   Keep serving whichever surface the existing record already names, even after artifact publishing becomes available in a later run: moving an already-shared link strands the captain's copy of it, so a project's surface is chosen once, at first publish, and never switched later.

Read `bin/fm-decision-ledger-page.sh`'s header for the hosted path's exact mechanics and for why it calls the ht-ml.app API directly instead of `lavish-axi share` (that CLI command has no update path today).
Every hosted page is password-protected from first publish, since a project's ledger can carry internal reasoning the captain would not want fully public; whenever a hosted-page URL is given to the captain, give the password with it in the same message, since a link with no password relayed alongside it is useless.
A Claude artifact's URL needs no password relayed with it.

## Entry format

Append one section per entry, oldest first:

```markdown
## <YYYY-MM-DD> - <one-line title>

**Kind:** captain-call | overruled | mistake
**Question:** <the question as it actually arose>
**Answer:** <the call taken>
**Reasoning:** <why, in the captain's terms>
```

Write `Question`, `Answer`, and `Reasoning` in the captain's terms, never internal vocabulary; `AGENTS.md` section 9 owns that translation rule, apply it here rather than restating it.

Each `Kind` adds one more required field:

- `captain-call` - a product or policy call that is the captain's to confirm. Add `**Reversible:** yes | no` and `**Cost of changing:** <what changing it later would cost>`.
- `overruled` - firstmate overruled a worker or blocked delivery. Add `**Evidence:** <what showed the worker was wrong, or what the block prevented>`.
- `mistake` - firstmate's own mistake, including a correction to an earlier entry in this same ledger. Add `**Corrects:** <date and title of the entry being corrected, or "n/a" for a fresh mistake>`.

The `mistake` kind is required whenever it applies, not optional.
A ledger recording only good decisions is worthless as an audit; a correction that reverses firstmate's own earlier reasoning is exactly the kind of entry a captain most needs to see.

## Filing a decision you did not log at the time

At `/stow` and at the away-mode return, check this session for any captain-level call, override, or mistake that never got a ledger entry, and file it before moving on: append the entry to the right project's `ledger.md`, then refresh that project's page if one is already recorded.
