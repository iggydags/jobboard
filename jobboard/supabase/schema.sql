-- Job Board schema for Supabase (Postgres)
-- Run this once in the Supabase SQL editor. Safe to re-run.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type job_priority as enum ('Low','Medium','High','Rush');
exception when duplicate_object then null; end $$;

do $$ begin
  create type job_status as enum ('Not Started','In Progress','On Hold','Completed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------------
create sequence if not exists job_no_seq start 1001;

create table if not exists public.jobs (
  id               uuid primary key default gen_random_uuid(),
  job_no           integer not null unique default nextval('job_no_seq'),
  client           text not null check (length(trim(client)) > 0),
  project          text not null check (length(trim(project)) > 0),
  quantity         text,
  due_date         date,
  designer         text,
  priority         job_priority not null default 'Medium',
  status           job_status   not null default 'In Progress',
  date_completed   date,
  notes            text,

  -- production stages
  proof_sent       boolean not null default false,
  client_approved  boolean not null default false,
  production       boolean not null default false,
  printing         boolean not null default false,
  finishing        boolean not null default false,
  ready            boolean not null default false,

  -- oversight fields (maintained by trigger)
  stage_changed_at timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  updated_by       text
);

create index if not exists jobs_status_idx      on public.jobs (status);
create index if not exists jobs_due_date_idx    on public.jobs (due_date);
create index if not exists jobs_designer_idx    on public.jobs (designer);
create index if not exists jobs_updated_at_idx  on public.jobs (updated_at desc);

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------
create table if not exists public.job_events (
  id          bigint generated always as identity primary key,
  job_id      uuid not null,   -- intentionally no FK: history survives deletion
  job_no      integer not null,
  action      text not null check (action in ('created','updated','deleted')),
  actor       text,
  changes     jsonb,          -- {field: {from, to}} for updates
  occurred_at timestamptz not null default now()
);
create index if not exists job_events_job_idx on public.job_events (job_id, occurred_at desc);
create index if not exists job_events_time_idx on public.job_events (occurred_at desc);

-- ---------------------------------------------------------------------------
-- Trigger: bookkeeping + audit
-- ---------------------------------------------------------------------------
create or replace function public.jobs_bookkeeping()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor  text := coalesce(auth.jwt() ->> 'email', 'system');
  diff   jsonb := '{}'::jsonb;
  k      text;
  oldj   jsonb;
  newj   jsonb;
  tracked text[] := array[
    'client','project','quantity','due_date','designer','priority','status',
    'date_completed','notes','proof_sent','client_approved','production',
    'printing','finishing','ready'
  ];
begin
  if tg_op = 'DELETE' then
    insert into job_events (job_id, job_no, action, actor)
      values (old.id, old.job_no, 'deleted', actor);
    return old;
  end if;

  new.updated_at := now();
  new.updated_by := actor;

  if tg_op = 'INSERT' then
    new.created_at := now();
    new.stage_changed_at := now();
    if new.status = 'Completed' and new.date_completed is null then
      new.date_completed := current_date;
    end if;
    return new;
  end if;

  -- UPDATE
  new.job_no := old.job_no;          -- immutable
  new.created_at := old.created_at;  -- immutable

  if (new.proof_sent, new.client_approved, new.production, new.printing, new.finishing, new.ready, new.status)
     is distinct from
     (old.proof_sent, old.client_approved, old.production, old.printing, old.finishing, old.ready, old.status)
  then
    new.stage_changed_at := now();
  end if;

  if new.status = 'Completed' and old.status <> 'Completed' and new.date_completed is null then
    new.date_completed := current_date;
  end if;
  if new.status <> 'Completed' and old.status = 'Completed' then
    new.date_completed := null;
  end if;

  oldj := to_jsonb(old); newj := to_jsonb(new);
  foreach k in array tracked loop
    if oldj -> k is distinct from newj -> k then
      diff := diff || jsonb_build_object(k, jsonb_build_object('from', oldj -> k, 'to', newj -> k));
    end if;
  end loop;

  if diff <> '{}'::jsonb then
    insert into job_events (job_id, job_no, action, actor, changes)
      values (new.id, new.job_no, 'updated', actor, diff);
  end if;
  return new;
end $$;

create or replace function public.jobs_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into job_events (job_id, job_no, action, actor)
    values (new.id, new.job_no, 'created', coalesce(auth.jwt() ->> 'email', 'system'));
  return new;
end $$;

drop trigger if exists jobs_bookkeeping_trg on public.jobs;
create trigger jobs_bookkeeping_trg
  before insert or update or delete on public.jobs
  for each row execute function public.jobs_bookkeeping();

drop trigger if exists jobs_after_insert_trg on public.jobs;
create trigger jobs_after_insert_trg
  after insert on public.jobs
  for each row execute function public.jobs_after_insert();

-- ---------------------------------------------------------------------------
-- Row level security: only signed-in team members, full access.
-- Create team accounts in Supabase Auth > Users (email + password).
-- Disable public sign-ups in Auth settings so the login page is invite-only.
-- ---------------------------------------------------------------------------
alter table public.jobs       enable row level security;
alter table public.job_events enable row level security;

drop policy if exists "team read jobs"   on public.jobs;
drop policy if exists "team write jobs"  on public.jobs;
drop policy if exists "team update jobs" on public.jobs;
drop policy if exists "team delete jobs" on public.jobs;
create policy "team read jobs"   on public.jobs for select to authenticated using (true);
create policy "team write jobs"  on public.jobs for insert to authenticated with check (true);
create policy "team update jobs" on public.jobs for update to authenticated using (true) with check (true);
create policy "team delete jobs" on public.jobs for delete to authenticated using (true);

drop policy if exists "team read events" on public.job_events;
create policy "team read events" on public.job_events for select to authenticated using (true);
-- events are written only by the trigger (security definer); no insert policy for clients.

revoke all on public.jobs, public.job_events from anon;
grant select, insert, update, delete on public.jobs to authenticated;
grant select on public.job_events to authenticated;
grant usage, select on sequence job_no_seq to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.jobs;
exception when duplicate_object then null; end $$;
alter table public.jobs replica identity full;
