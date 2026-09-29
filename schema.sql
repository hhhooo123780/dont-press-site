-- 「絶対に押すな」 shared stats backend for Supabase.
-- Run once in Supabase SQL Editor. The browser receives only the publishable/anon key.

create table if not exists public.click_events (
  id bigint generated always as identity primary key,
  visitor_id uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists click_events_created_at_idx on public.click_events (created_at desc);
create index if not exists click_events_visitor_created_idx on public.click_events (visitor_id, created_at desc);

create table if not exists public.click_rate_limits (
  visitor_id uuid primary key,
  last_batch_at timestamptz not null
);

alter table public.click_events enable row level security;
alter table public.click_rate_limits enable row level security;
revoke all on public.click_events from anon, authenticated;
revoke all on public.click_rate_limits from anon, authenticated;

-- Do not expose the click table. Clients may only call these narrow RPCs.
create or replace function public.record_clicks(p_visitor_id uuid, p_click_count integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
  v_last timestamptz;
  v_rare text := null;
  v_roll integer;
  v_personal bigint;
begin
  if p_visitor_id is null or p_click_count is null or p_click_count < 1 then
    raise exception 'Invalid click request';
  end if;
  v_count := least(p_click_count, 100);

  -- Serialize batches per browser ID and limit database writes to one batch/700ms.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_visitor_id::text, 0));
  select last_batch_at into v_last from public.click_rate_limits where visitor_id = p_visitor_id for update;
  if v_last is not null and v_last > pg_catalog.clock_timestamp() - interval '700 milliseconds' then
    return pg_catalog.jsonb_build_object('accepted', false);
  end if;

  insert into public.click_rate_limits(visitor_id, last_batch_at)
  values (p_visitor_id, pg_catalog.clock_timestamp())
  on conflict(visitor_id) do update set last_batch_at = excluded.last_batch_at;

  insert into public.click_events(visitor_id)
  select p_visitor_id from pg_catalog.generate_series(1, v_count);

  -- One server-side roll per accepted click. Only the strongest tier is announced per batch.
  for i in 1..v_count loop
    v_roll := floor(pg_catalog.random() * 10000)::integer;
    if v_roll = 0 then v_rare := '1/10,000';
    elsif v_roll < 10 and v_rare is distinct from '1/10,000' then v_rare := '1/1,000';
    elsif v_roll < 100 and v_rare is null then v_rare := '1/100';
    end if;
  end loop;

  select count(*) into v_personal from public.click_events where visitor_id = p_visitor_id;

  -- Send a small invalidation signal, never row data. Receivers fetch fresh aggregate counts via RPC.
  perform realtime.send(
    pg_catalog.jsonb_build_object('at', pg_catalog.clock_timestamp()),
    'click', 'global-clicks', false
  );

  return pg_catalog.jsonb_build_object(
    'accepted', true,
    'accepted_clicks', v_count,
    'personal_clicks', v_personal,
    'rare_event', v_rare
  );
end;
$$;

create or replace function public.get_click_stats(p_visitor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_total bigint;
  v_today bigint;
  v_week bigint;
  v_personal bigint;
  v_today_start timestamptz := pg_catalog.date_trunc('day', pg_catalog.now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
  v_week_start timestamptz := pg_catalog.date_trunc('week', pg_catalog.now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
  v_rankings jsonb;
begin
  select count(*) into v_total from public.click_events;
  select count(*) into v_today from public.click_events where created_at >= v_today_start;
  select count(*) into v_week from public.click_events where created_at >= v_week_start;
  select count(*) into v_personal from public.click_events where visitor_id = p_visitor_id;

  select pg_catalog.jsonb_build_object(
    'today', coalesce((select pg_catalog.jsonb_agg(x.row_data order by x.n desc, x.code) from (
      select pg_catalog.jsonb_build_object('visitor_code', '匿名-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(visitor_id::text,'-',''),1,8)), 'clicks', count(*)) row_data, count(*) n, visitor_id::text code
      from public.click_events where created_at >= v_today_start group by visitor_id order by count(*) desc, visitor_id limit 10
    ) x), '[]'::jsonb),
    'week', coalesce((select pg_catalog.jsonb_agg(x.row_data order by x.n desc, x.code) from (
      select pg_catalog.jsonb_build_object('visitor_code', '匿名-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(visitor_id::text,'-',''),1,8)), 'clicks', count(*)) row_data, count(*) n, visitor_id::text code
      from public.click_events where created_at >= v_week_start group by visitor_id order by count(*) desc, visitor_id limit 10
    ) x), '[]'::jsonb),
    'all', coalesce((select pg_catalog.jsonb_agg(x.row_data order by x.n desc, x.code) from (
      select pg_catalog.jsonb_build_object('visitor_code', '匿名-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(visitor_id::text,'-',''),1,8)), 'clicks', count(*)) row_data, count(*) n, visitor_id::text code
      from public.click_events group by visitor_id order by count(*) desc, visitor_id limit 10
    ) x), '[]'::jsonb)
  ) into v_rankings;

  return pg_catalog.jsonb_build_object(
    'total_clicks', v_total,
    'today_clicks', v_today,
    'week_clicks', v_week,
    'personal_clicks', v_personal,
    'visitor_code', '匿名-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(p_visitor_id::text,'-',''),1,8)),
    'rankings', v_rankings
  );
end;
$$;

revoke all on function public.record_clicks(uuid, integer) from public, anon, authenticated;
revoke all on function public.get_click_stats(uuid) from public, anon, authenticated;
grant execute on function public.record_clicks(uuid, integer) to anon;
grant execute on function public.get_click_stats(uuid) to anon;

-- This is a public broadcast topic by design; it carries only an invalidation ping.
-- Click data itself remains hidden behind get_click_stats() and table RLS.

-- Keep the API surface narrow if new functions are added in the future.
comment on table public.click_events is 'Anonymous click events for the public game. Read access is only through aggregate RPCs.';
