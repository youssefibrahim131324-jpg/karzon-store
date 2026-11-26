create table if not exists public.admin_users (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.admin_users enable row level security;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from public.admin_users where user_id = auth.uid()) $$;
create table if not exists public.kv (key text primary key, value jsonb not null, updated_at timestamptz default now());
alter table public.kv enable row level security;
create policy kv_read on public.kv for select to anon, authenticated using (true);
create policy kv_write on public.kv for insert to authenticated with check (public.is_admin());
create policy kv_upd on public.kv for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy kv_del on public.kv for delete to authenticated using (public.is_admin());
create table if not exists public.orders (order_no text primary key, created_at timestamptz default now(), data jsonb not null, receipt_img text, pay_ref text, pay_state text, status text default 'new');
alter table public.orders enable row level security;
create policy orders_insert on public.orders for insert to anon, authenticated with check (status = 'new' and length(order_no) < 40 and length(coalesce(receipt_img,'')) < 400000);
create policy orders_admin_read on public.orders for select to authenticated using (public.is_admin());
create policy orders_admin_upd on public.orders for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy orders_admin_del on public.orders for delete to authenticated using (public.is_admin());
create or replace function public.track_order(p_no text, p_phone text) returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('no', order_no, 'status', status, 'pay_state', pay_state, 'data', data - 'addr') from public.orders where order_no = p_no and right(regexp_replace(coalesce(data->>'phone',''),'\D','','g'),8) = right(regexp_replace(coalesce(p_phone,''),'\D','','g'),8) limit 1 $$;
grant execute on function public.track_order(text,text) to anon, authenticated;
