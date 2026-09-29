-- BarberBook stores its current application state as one JSONB row.
-- Only the server's service-role key should access this table.
create table if not exists public.barberbook_state (
  key text primary key,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.barberbook_state enable row level security;
revoke all on table public.barberbook_state from anon, authenticated;
grant all on table public.barberbook_state to service_role;
