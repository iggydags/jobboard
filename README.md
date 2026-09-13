# Job Board

Shared production tracker for a print / design shop, with a management overview.
Single-file front end (`index.html`) on Vercel, Postgres on Supabase.

## What's in it

| Piece | Purpose |
|---|---|
| `index.html` | The whole app: login, board, overview dashboard, activity feed. No build step. |
| `supabase/schema.sql` | Tables, triggers, audit log, row-level security, realtime. Idempotent. |
| `vercel.json` | Security headers (CSP locked to Supabase + jsDelivr), no-cache on the page. |

### Overview tab (management)
Hero number is overdue jobs. Tiles for open, due within 7 days, stalled (no stage movement for 5+ days), completed in the last 30 days vs the prior 30. A "needs attention" list ranks open jobs by severity (late, rush, idle, due soon, on hold). Workload per designer with overdue count, pipeline by furthest completed stage, completed per week, status mix. Every tile drills into the board pre-filtered.

### Board tab
Sortable columns, search across client / project / job number / notes, filters by status, priority, designer, overdue. Stage boxes toggle inline. Marking Ready sets the job to Completed. Late and idle jobs are flagged on the row. CSV export of everything.

### Activity tab
Every create, edit, and delete with who did it and what changed. Also shown per job inside the edit modal.

### Under the hood
- Job numbers come from a Postgres sequence, so two people adding jobs at once can't collide.
- `stage_changed_at`, `updated_at`, `updated_by`, and `date_completed` are maintained by a database trigger, not the browser.
- Writes are optimistic with rollback on failure. Supabase Realtime pushes every change to every open tab; the page also refetches when it regains focus or connectivity.
- Access: only signed-in users can read or write (RLS). The anon key in the page is public by design; it grants nothing without a session.

## Setup (about 10 minutes)

1. **Supabase project.** Create one at supabase.com. In the SQL editor, paste and run `supabase/schema.sql`.
2. **Users.** Authentication → Providers → Email: turn **off** "Allow new users to sign up" (so the login page is invite-only). Authentication → Users → Add user for each team member (email + password, "auto confirm").
3. **Keys.** Project Settings → API: copy the Project URL and the `anon public` key into the config block at the top of `index.html`. Optionally change `shopName`, `stalledAfterDays`, `dueSoonDays`.
4. **Deploy.** Push the folder to Vercel (static, no framework). Or drag the folder onto vercel.com/new.

## Changing the workflow
Stages live in three places: the boolean columns in `schema.sql`, the `tracked` array in the trigger, and `STAGE_KEYS` / `STAGE_SHORT` / `STAGE_FULL` / `FUNNEL_LABELS` at the top of the script in `index.html`. Add a column, add it to all four, redeploy.

## Backups
Supabase Pro includes daily backups. On the free tier, use the Export CSV button weekly or schedule `pg_dump` against the connection string.
