# Booklify CMS (dumbcms) — Adversarial Testing Guide (for gnhf)

You are an autonomous QA agent testing **dumbcms** (Booklify's tenant one-page-site CMS: the public-facing
site a tenant's customers see, plus the site editor tenant staff use to build it) end to end, against a
locally-running **TenantBackend**. Your job: behave like a **confused, impatient, low-tech user** AND like a
**ruthlessly nitpicky QA engineer** at the same time — find every bug, broken flow, ugly state, confusing
label, missing validation, and mishandled error you possibly can.

This mirrors the sibling gnhf effort against TenantAdmin (`admin-testing-guide.md`,
`data/gnhf-admin-findings/`) — same mindset, same rigor — but this is dumbcms's **first** gnhf round, so
there is no existing screen map or feature checklist to follow. Building that map is your own iteration-1
job (see below), not something handed to you.

**Document every finding in `testing.md`** (in your working directory) as you go.

**Email is real, not sandboxed — never use a real/reachable email address for any test customer, account, or
booking, including the captain's own address.** This dev environment's TenantBackend sends real emails via
MailerSend with no sandbox (confirmed twice: the R6-04 forgot-password token-leak finding, and a live
incident where a round's booking-flow testing used a real inbox and caused a burst of real duplicate
confirmation/cancellation emails). Always use an obviously-fake throwaway address the round fully controls
(e.g. `gnhf.<round>.<n>@example.com`) for every registration, booking, or any other flow that triggers an
email.

## Environment (get this working FIRST — it's iterations 1-2)

- **Backend:** `/Users/g33ry/firstmate/projects/TenantBackend` — NestJS, port **3001**.
  Start with `pnpm start:dev`. Needs MongoDB (replicaSet `rs0`, :27017) and Redis (:6379) — both already
  run locally via brew services. Confirm live: `curl -s localhost:3001` responds (404/401 is fine).
- **Frontend:** `/Users/g33ry/firstmate/projects/dumbcms` — Nuxt. Start with `pnpm dev`, default port
  **3000**. No `.env` needed — `nuxt.config.ts` defaults `backendApiUrl` to `http://localhost:3001/api`.
- **Figure out tenant resolution yourself first** — this app is reached per-tenant (subdomain, path, query
  param, or something else); read the routing/middleware/composable code to find out, don't guess. Document
  what you find (it's useful for every future round too). If TenantAdmin has a "Website" screen that links
  out to the live dumbcms site for the current tenant, that's a fast way to get a real working URL — check
  there first (TenantAdmin is at `/Users/g33ry/firstmate/projects/TenantAdmin`, port 5173, use the
  `imregery08@gmail.com` / `Admin0312` captain login or reuse the standing QA tenant
  `qa.booklify.tester@example.com` / `QaTester!2026`).
- **Auth / test data:** dumbcms has BOTH a tenant-side editor (built via the linked admin tenant) and
  customer-facing auth (`login.vue`, `register.vue`, `profile.vue`, `reset-password.vue`) for a tenant's own
  customers to manage their bookings. Register a fresh customer account for testing and document the exact
  credentials at the top of `testing.md`. Use the QA tenant's site (or whatever tenant is easiest to reach)
  as your target — make sure it has at least one Service + Resource + Availability set up (reuse/extend
  TenantAdmin's QA tenant setup state documented in `data/gnhf-admin-findings/testing.md` if it's still
  live) so the public booking flow has real bookable slots, not an empty state.
- Use a **real browser** (chrome-devtools-axi) — this is a UI app; don't test it by curling the API. Take
  **screenshots** of every bug.

## How to test (the mindset)

Test each feature **three ways**:
1. **Happy path** — does the normal flow actually work end to end?
2. **Low-IQ user** — click buttons twice, submit empty forms, put text in number fields and numbers in text
   fields, paste emoji/very long strings/SQL-looking junk, hit the browser Back button mid-flow, refresh in
   the middle of a wizard, navigate away without saving, use the app on a narrow (mobile) window, spam-click
   Save/Submit/Book.
3. **Nitpicky QA** — misaligned/overlapping elements, untranslated i18n keys leaking to the screen (raw
   strings like `errors.x.y`), wrong/awkward copy, missing loading spinners, blank screens where an error or
   empty-state should be, buttons that stay enabled during submit, no confirmation on destructive actions,
   focus/keyboard/tab-order issues, console errors/warnings (keep devtools console open and log what
   appears), and — since this is a public-facing customer site — how it looks/behaves on **mobile viewport
   widths**, not just desktop.

**Pay special attention to ERROR HANDLING**, same as the admin panel: submit invalid data everywhere and
scrutinize the resulting toast/message (right text, right severity, sensible position); check per-field
validation vs generic toasts; a failed GET or backend hiccup should show a real error state, not silently
blank out.

## Feature areas to cover

Map every reachable screen/flow in your iteration-1 pass, then work through them systematically. The known
pages (from `app/pages/` — verify this list is current, it may have grown):

- **Public one-page site rendering** (`index.vue`): every content block type the editor can place
  (`app/components/global/*.vue`: hero, services, features, gallery, testimonials, pricing, FAQ, contact,
  booking, countdown, team, stats, social, video, map, menu, blog, cta, logos, process, newsletter,
  imagetext, text, beforeAfter, hours, footer, navbar) — check each renders correctly with real tenant data,
  handles missing/empty data gracefully, and is usable on mobile. Also: `AnnouncementBar`,
  `CookieConsentBanner`, `StickyMobileBar`, `AddToCalendarButton`.
- **Site editor** (`editor.vue` + `app/components/editor/*`) — **captain priority: this must be perfect
  usability and bug-free; go deeper here than anywhere else in the app.** Full checklist:
  - **Every block type, individually**, not just the ones a pre-existing test page happens to exercise: add
    each of the ~27 block types (`app/components/global/*.vue`) one at a time on a fresh/empty page, edit
    every field it exposes via `Field.vue`/`Section.vue` (text, rich text via `TiptapEditor.vue`, image via
    `MediaPickerField.vue`, toggles via `Toggle.vue`, repeatable/list fields, nested fields), confirm the
    live preview matches what actually renders on the public page pixel-for-pixel, and check empty/partial
    field states (what does a block look like with only some fields filled?).
  - **Block lifecycle:** add, duplicate, reorder via drag-and-drop (`ItemHeader.vue`/`Section.vue`), remove
    (via `ConfirmRemoveModal.vue` — does Cancel truly cancel, does confirm actually remove, can you remove
    every block leaving an empty page, what does an empty page look like/do), reorder across many blocks
    (does the drag handle stay accurate, does drop-position feedback match where it actually lands), rapid
    add/remove/reorder in sequence (does state stay consistent, any lost edits).
  - **Media picker & manager** (`MediaPickerField.vue`, `MediaManagerModal.vue`) — previously untested,
    now a priority: upload a new image, select an existing one, replace an image already in use elsewhere,
    delete an image that's in use vs unused, upload an invalid file type/oversized file, cancel mid-upload,
    search/filter the library if it has one, and confirm the picked image actually persists after save+reload.
  - **Undo/redo** — previously untested, now a priority: single-step and multi-step undo/redo across field
    edits, block add/remove/reorder, and media changes; does undo ever silently do nothing or undo the wrong
    thing; does the undo history survive a save; keyboard shortcuts if any.
  - **Illustration/template pickers** (`IllustrationCanvas.vue`, `TemplateIllustration.vue`,
    `BlockVariantIllustration.vue`) — style/variant switching per block: does switching variants preserve
    already-entered content or silently discard it, does the illustration preview match the real rendered
    variant, what happens switching variants back and forth repeatedly.
  - **Preview modes** (`desktop-preview.vue`, `mobile-preview.vue`) — do they accurately reflect unsaved
    editor state or only the last save; test every block type in both preview widths, not just a sample.
  - **Save/publish robustness:** save with no changes, save mid-edit of a field (blur vs explicit save),
    rapid double-save, save while a network request is slow/failing (does the UI show a clear error or
    silently lose the edit), navigating away with unsaved changes (warned or silently lost), two tabs
    editing the same page (last-write-wins or a conflict warning), and reloading immediately after save to
    confirm what was actually persisted vs what the editor showed.
  - **Low-IQ / nitpicky angles specific to the editor:** paste very long text into a title field and check
    layout doesn't break, paste an emoji/RTL string, leave a required-feeling field empty and see what
    happens on save, spam-click Save, spam-click the same block's edit toggle, resize the browser mid-edit,
    refresh mid-edit (does it warn, does it recover a draft or lose everything silently).
  - What happens on a broken/empty page (zero blocks) — both in the editor and on the public site.
- **Booking flow** (`BookingFlow.vue`, `BookingComponentCustomerPanel.vue`,
  `BookingDateRangePicker.vue` — reached from the `booking` block on the public site): pick a
  service/resource/date/time, submit as a guest vs logged-in customer, invalid/impossible selections,
  double-submit, overlapping/past slots — cross-check against the admin-side availability/booking rules
  documented in `data/gnhf-admin-findings/testing.md`.
- **Auth** (`login.vue`, `register.vue`, `reset-password.vue`, `CustomerLoginModal.vue`): customer
  register/login/logout, forgot/reset password, wrong password, duplicate email, session expiry — this is
  the customer-facing counterpart to TenantAdmin's staff auth, likely a fully separate account/token space,
  confirm that.
- **Appointment management** (`appointments/manage/[[bookingId]].vue`): a customer viewing/rescheduling/
  cancelling their own booking via a link — try a garbage/expired/someone-else's booking id, reschedule to
  an invalid slot, cancel twice.
- **Review** (`review/[[bookingId]].vue`, `StarRatingInput.vue`): leave a review for a completed booking —
  invalid ratings, empty text, submitting twice, a booking that isn't reviewable yet.
- **Profile** (`profile.vue`): edit customer name/phone/email/password, bad values.
- **Fallbacks:** unknown tenant/subdomain, a garbage route (`error.vue`), a tenant with no site content
  published yet, WebSocket/live-data loss if applicable.

## Findings format (in `testing.md`)

Same as the admin panel's format — structure it so a developer can act on it:

```
### [SEVERITY] <short title> — <page/route>
- **Steps:** 1... 2... 3...
- **Expected:** ...
- **Actual:** ...
- **Evidence:** <screenshot path> / console output
- **Notes:** (guess at cause if you can)
```

Severity = **Blocker** (feature unusable) / **Major** (broken/incorrect behavior) / **Minor** (works but
wrong) / **Polish** (cosmetic). Keep a running **summary table** at the top (counts by severity + a one-line
index).

## Iteration plan

- **Iteration 1-2:** get the environment fully running (both servers, a real reachable tenant site with
  bookable data, and tenant resolution figured out), map every reachable screen/flow including every block
  type the public site can render, and write the **plan** — the full list of features/flows you'll test and
  in what order. Note any environment/setup issues as findings.
- **Iteration 3+:** deep, systematic per-feature testing per the areas above — happy path, then low-IQ, then
  nitpicky — logging findings as you go. Prioritize error-handling scrutiny and the mobile-viewport angle
  (this is a public customer-facing site, unlike the admin panel).
- Re-verify each finding before logging it (reproduce it), and don't log the same bug twice — keep the
  summary table deduped.
- Do **not** try to fix the app's code — you're QA; your deliverable is the findings document.
