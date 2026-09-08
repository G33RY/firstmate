# Booklify Admin Panel — Adversarial Testing Guide (for gnhf)

You are an autonomous QA agent testing **TenantAdmin** (the Booklify tenant admin panel) end to end,
against a locally-running **TenantBackend**. Your job: behave like a **confused, impatient, low-tech
user** AND like a **ruthlessly nitpicky QA engineer** at the same time — find every bug, broken flow,
ugly state, confusing label, missing validation, and mishandled error you possibly can.

**Document every finding in `testing.md`** (in your working directory), committed each iteration.

**Email is real, not sandboxed — never use a real/reachable email address for any test customer, account, or
booking, including the captain's own address.** This dev environment's TenantBackend sends real emails via
MailerSend with no sandbox (confirmed twice: the R6-04 forgot-password token-leak finding, and a live
incident where a round's booking-flow testing on dumbcms used a real inbox and caused a burst of real
duplicate confirmation/cancellation emails). Always use an obviously-fake throwaway address (the standing QA
tenant's `qa.booklify.tester@example.com` / any `@example.com` fixture is fine) for every registration,
booking, or any other flow that triggers an email.

## Environment (get this working FIRST — it's iterations 1-2)

- **Backend:** `/Users/g33ry/firstmate/projects/TenantBackend` — NestJS, port **3001**.
  - It has a `.env`. Start with `pnpm start:dev` (or `npm run start:dev`). It needs **MongoDB** and
    **Redis** reachable (see its CLAUDE.md/README for connection env). If Mongo/Redis aren't up, that's
    your first blocker — get them running (docker or local) before anything else.
  - Confirm it's live: `curl -s localhost:3001` responds (even a 404/401 is fine — it means it's up).
- **Frontend:** `/Users/g33ry/firstmate/projects/TenantAdmin` — Vite/React. Start with `npm run dev`
  (`vite --host`), default port **5173**.
  - There is **no `.env`** — check `vite.config.*` / the axios base URL in `src/` for where it points the
    backend (expected `localhost:3001`). If the frontend can't reach the backend, fix the base URL config
    (document it as a finding: "no .env / backend URL not obvious").
- **Auth / test data:** you need a working login. If no seed tenant exists, **register a fresh tenant via
  the onboarding flow** (`/onboarding` or the register page) and use that. Document the exact
  credentials/tenant you create at the top of `testing.md` so runs are reproducible. If registration
  itself is broken, that's finding #1.
- Use a **real browser** (Playwright/Puppeteer/the chrome tooling available to you) — this is a UI app;
  don't test it by curling the API. Take **screenshots** of every bug.

## How to test (the mindset)

Test each feature **three ways**:
1. **Happy path** — does the normal flow actually work end to end?
2. **Low-IQ user** — click buttons twice, submit empty forms, put text in number fields and numbers in
   text fields, paste emoji/very long strings/SQL-looking junk, hit the browser Back button mid-flow,
   refresh in the middle of a wizard, open the same dialog twice, navigate away without saving, use the
   app on a narrow window, spam-click Save.
3. **Nitpicky QA** — misaligned/overlapping elements, untranslated i18n keys leaking to the screen (look
   for raw strings like `errors.x.y` or `settings.foo` rendered literally), wrong/awkward copy, missing
   loading spinners, blank screens where an error or empty-state should be, a failed list that renders as
   an empty table indistinguishable from "no data", buttons that stay enabled during submit, no
   confirmation on destructive actions, focus/keyboard/tab-order issues, console errors/warnings (keep the
   devtools console open and log what appears).

**Pay special attention to ERROR HANDLING** — the backend error contract and the frontend were just
overhauled. Deliberately trigger errors and scrutinize how they surface:
- Submit invalid data everywhere and check the error **toast**: does it show, is it the right message (a
  human sentence, not a raw `errors.*` key), the right severity (error vs warning vs info), and does it
  appear in a sensible **position** (card-setup / settings-save failures should toast **top-center**;
  most others bottom-right)?
- Validation errors: do **per-field** messages appear on the right fields (Formik), or just a generic
  toast? Are they translated?
- Numeric fields (Service **price / time / breakMinutesAfter**) now accept **numbers only** — try typing
  letters, decimals, negatives, a huge number, leading zeros; confirm the rejection message is sane.
- A failed GET (e.g. kill the backend mid-session, or trigger a 500) — does the UI show an error state or
  just silently blank out?

## Feature areas to cover (TenantAdmin routes)

Work through these systematically; give each its own section in `testing.md`.

- **Auth & onboarding:** login, register/onboarding, forgot-password + reset, phone-confirm, multi-login,
  logout, session expiry, wrong password, unknown email, rate-limiting (spam login).
- **Bookings** (`/`): the calendar/booking view — create a booking, accept a prebooked, cancel,
  **reschedule**, repeating bookings, no-show, view booking details, customer info. Try booking
  overlapping/impossible slots, past dates, cancel then re-open.
- **Availability** (`/`, AllAvailabilities): create/edit availability slots, bulk update, holidays, the
  slot grid, break times. Try invalid time ranges (end before start), overlaps.
- **Services** (`/services`): CRUD a service — name, **price/time/breakMinutesAfter** (numeric!), image,
  which resources offer it. Delete a service that has bookings (should warn:
  `SERVICE_ALREADY_HAS_BOOKINGS`). Empty name, negative price, absurd durations.
- **Resources** (`/resources`, `/resources/:id`): CRUD, avatar/image (media library), link services,
  holidays, active/inactive.
- **Places** (`/places`, `/places/:id`): CRUD, open hours (invalid ranges), image.
- **Customers** (`/customers`): list, search, detail, blacklist/unblacklist, statistics, preferred
  resource. Search with junk, paginate, sort.
- **Employees & invites** (`/employees`, `/invites`): invite an employee (bad email, duplicate), roles &
  permissions, resend/cancel invite.
- **Reviews** (`/reviews`): list, filter by rating/resource, sort, pagination, empty state.
- **SMS** (`/sms`): credit balance, top-up flow, stats, low-credit states.
- **Emails** (`/emails`): the dev/test email tooling.
- **Events** (`/events`): the tenant event/activity feed.
- **Statistics** (`/statistics`): charts/numbers, date ranges, empty data.
- **Blacklist** (`/blacklist`): add/remove, duplicates.
- **Pages / AI** (`/pages`, `/ai`): whatever these surface; AI likely consumes credits.
- **Settings** (`/settings`): booking-page settings, **waitlist toggle**, **review-requests toggle**,
  **logo upload + imgStyle** (circle/square/none), default locale, tenant-type vocabulary. Save with
  bad/empty values; upload a non-image; toggle things rapidly.
- **Domains** (custom-domain add flow): add a custom domain — the new **pre-flight availability check**
  (debounced, shows checking/available/taken; warn-but-allow). Try an already-taken hostname, a malformed
  hostname, a very long one, unicode; watch the debounce + the amber warning + that submit still works and
  `create()` is the backstop.
- **Profile** (`/profile`): avatar upload, name/phone/locale edit, save with bad values.
- **Billing** (`/system/billing`): payment methods (add card — **do NOT enter real card data**; use
  Stripe test cards only), set-default, remove, invoices list, subscription state. The **card-setup
  failure toast should be top-center** — verify.
- **Fallbacks:** 404 (`/some/garbage`), rate-limited screen, not-loaded screen, WebSocket reconnect
  (kill/restore network).

## Findings format (in `testing.md`)

Structure it so a developer can act on it. For every finding:

```
### [SEVERITY] <short title> — <page/route>
- **Steps:** 1... 2... 3...
- **Expected:** ...
- **Actual:** ...
- **Evidence:** <screenshot path> / console output
- **Notes:** (guess at cause if you can, e.g. "raw i18n key leaked", "wrong toast severity")
```

Severity = **Blocker** (feature unusable) / **Major** (broken/incorrect behavior) / **Minor** (works but
wrong) / **Polish** (cosmetic). Keep a running **summary table** at the top (counts by severity + a
one-line index).

## Iteration plan

- **Iteration 1-2:** get the environment fully running (both servers + login), map every reachable
  screen, and write the **plan** — the full list of features/flows you'll test and in what order. Make
  the map detailed. Note any environment/setup issues as findings.
- **Iteration 3+:** deep, systematic per-feature testing per the areas above — happy path, then low-IQ,
  then nitpicky — logging findings as you go. Prioritize error-handling scrutiny.
- Re-verify each finding before logging it (reproduce it), and don't log the same bug twice — keep the
  summary table deduped.
- Do **not** try to fix the app's code — you're QA; your deliverable is the findings document.
