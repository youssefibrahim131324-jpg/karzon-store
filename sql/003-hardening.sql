
create table if not exists public.stock (product_id int primary key, qty int not null check (qty >= 0));
alter table public.stock enable row level security;
drop policy if exists stock_read on public.stock;
create policy stock_read on public.stock for select to anon, authenticated using (true);
revoke all on public.stock from anon, authenticated; grant select on public.stock to anon, authenticated;
insert into public.stock(product_id, qty) select (e->>'id')::int, (e->>'stock')::int from public.kv, jsonb_array_elements(value) e where key = 'products' on conflict (product_id) do nothing;
create table if not exists public.rl (k text not null, ts timestamptz not null default now());
create index if not exists rl_k_ts on public.rl (k, ts);
alter table public.rl enable row level security; revoke all on public.rl from anon, authenticated;
create or replace function public.rl_check(p_k text, p_lim int) returns void language plpgsql security definer set search_path = public as $f$
begin
  delete from rl where ts < now() - interval '1 hour';
  if (select count(*) from rl where k = p_k and ts > now() - interval '10 minutes') >= p_lim then raise exception 'rate_limited'; end if;
  insert into rl(k) values (p_k);
end $f$;
revoke execute on function public.rl_check(text, int) from anon, authenticated, public;
create or replace function public.client_ip() returns text language sql stable as $f$ select coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', 'unknown') $f$;
update public.kv set value = jsonb_set(jsonb_set(value, '{wallet}', 'false'), '{card}', 'false') where key = 'settings';
create or replace function public.admin_set_stock(p_id int, p_qty int) returns void language plpgsql security definer set search_path = public as $f$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_qty < 0 or p_qty > 100000 then raise exception 'bad_qty'; end if;
  insert into stock(product_id, qty) values (p_id, p_qty) on conflict (product_id) do update set qty = excluded.qty;
end $f$;
grant execute on function public.admin_set_stock(int, int) to authenticated; revoke execute on function public.admin_set_stock(int, int) from anon, public;
create or replace function public.place_order(p jsonb, img text default null) returns jsonb language plpgsql security definer set search_path = public as $fn$
declare prods jsonb; sett jsonb; coups jsonb; it jsonb; pr jsonb; sub numeric := 0; disc numeric := 0; ship numeric := 0; tot numeric; code text; cp jsonb; fs boolean := false; pay text := p->>'pay'; ono text; items jsonb := '[]'; nc jsonb; q int; ex jsonb; rec jsonb; cid text := p->>'cid'; ref text := nullif(trim(coalesce(p->>'ref','')),''); ok boolean; left_q int;
begin
  if cid is null or length(cid) < 8 or length(cid) > 64 then raise exception 'bad_request'; end if;
  select data into ex from orders where data->>'cid' = cid;
  if ex is not null then return ex; end if;
  perform public.rl_check('o:' || public.client_ip(), 12);
  if length(trim(coalesce(p->>'name',''))) < 3 or length(p->>'name') > 80 then raise exception 'bad_name'; end if;
  if coalesce(p->>'phone','') !~ '^01[0-9]{9}$' then raise exception 'bad_phone'; end if;
  if length(trim(coalesce(p->>'addr',''))) < 8 or length(p->>'addr') > 300 then raise exception 'bad_addr'; end if;
  if length(trim(coalesce(p->>'city',''))) < 2 or length(p->>'city') > 40 then raise exception 'bad_city'; end if;
  select value into prods from kv where key = 'products';
  select value into sett from kv where key = 'settings';
  select value into coups from kv where key = 'coupons' for update;
  if prods is null or sett is null then raise exception 'store_not_ready'; end if;
  if pay = 'cod' then ok := coalesce((sett->>'cod')::boolean, false);
  elsif pay = 'vodafone' then ok := coalesce((sett->>'wallet')::boolean, false);
  elsif pay = 'instapay' then ok := coalesce((sett->>'card')::boolean, false);
  else ok := false; end if;
  if not ok then raise exception 'pay_disabled'; end if;
  if pay <> 'cod' then
    if ref is null or length(ref) < 6 or length(ref) > 40 then raise exception 'bad_ref'; end if;
    if img is null or img !~ '^data:image/(jpeg|png|webp);base64,' or length(img) > 380000 or length(img) < 500 then raise exception 'bad_receipt'; end if;
  else ref := null; img := null; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') < 1 or jsonb_array_length(p->'items') > 30 then raise exception 'bad_items'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    q := (it->>1)::int;
    if q < 1 or q > 20 then raise exception 'bad_qty'; end if;
    select e into pr from jsonb_array_elements(prods) e where (e->>'id')::int = (it->>0)::int;
    if pr is null or not coalesce((pr->>'active')::boolean, false) then raise exception 'unavailable'; end if;
    update stock set qty = qty - q where product_id = (pr->>'id')::int and qty >= q returning qty into left_q;
    if not found then raise exception 'out_of_stock:%', pr->>'id'; end if;
    sub := sub + (pr->>'price')::numeric * q;
    items := items || jsonb_build_array(jsonb_build_array((pr->>'id')::int, q, (pr->>'price')::numeric));
  end loop;
  code := upper(trim(coalesce(p->>'coupon','')));
  if code <> '' then
    select e into cp from jsonb_array_elements(coalesce(coups,'[]'::jsonb)) e where e->>'code' = code;
    if cp is null or not coalesce((cp->>'active')::boolean, false) or sub < coalesce((cp->>'min')::numeric, 0) then raise exception 'bad_coupon'; end if;
    if cp->>'type' = 'pct' then disc := round(sub * (cp->>'value')::numeric / 100);
    elsif cp->>'type' = 'fixed' then disc := least((cp->>'value')::numeric, sub);
    else fs := true; end if;
    nc := (select jsonb_agg(case when e->>'code' = code then jsonb_set(e, '{uses}', to_jsonb(coalesce((e->>'uses')::int,0) + 1)) else e end) from jsonb_array_elements(coups) e);
    update kv set value = nc where key = 'coupons';
  end if;
  if not (sub >= (sett->>'freeFrom')::numeric or fs) then ship := (sett->>'shipping')::numeric; end if;
  tot := sub - disc + ship;
  loop
    ono := 'CZ-' || upper(substr(md5(random()::text || clock_timestamp()::text || cid), 1, 8));
    exit when not exists (select 1 from orders where order_no = ono);
  end loop;
  rec := jsonb_build_object('no', ono, 'ts', (extract(epoch from now()) * 1000)::bigint, 'name', trim(p->>'name'), 'phone', p->>'phone', 'city', trim(p->>'city'), 'addr', trim(p->>'addr'), 'items', items, 'sub', sub, 'disc', disc, 'ship', ship, 'total', tot, 'coupon', code, 'pay', pay, 'status', 'new', 'cid', cid);
  if ref is not null then rec := rec || jsonb_build_object('ref', ref, 'payState', 'pending'); end if;
  insert into orders(order_no, data, receipt_img, pay_ref, pay_state, status) values (ono, rec, img, ref, case when ref is null then null else 'pending' end, 'new');
  return rec;
end $fn$;
grant execute on function public.place_order(jsonb, text) to anon, authenticated;
create or replace function public.set_order_status(p_no text, p_status text) returns jsonb language plpgsql security definer set search_path = public as $fn$
declare o orders%rowtype; it jsonb; sign int := 0; q int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('new','processing','shipped','delivered','cancelled') then raise exception 'bad_status'; end if;
  select * into o from orders where order_no = p_no for update;
  if not found then raise exception 'not_found'; end if;
  if o.status = p_status then return o.data; end if;
  if p_status = 'cancelled' then sign := 1; elsif o.status = 'cancelled' then sign := -1; end if;
  if sign <> 0 then
    for it in select * from jsonb_array_elements(o.data->'items') loop
      q := (it->>1)::int;
      update stock set qty = qty + sign * q where product_id = (it->>0)::int and qty + sign * q >= 0;
      if not found and sign < 0 then raise exception 'out_of_stock'; end if;
    end loop;
  end if;
  update orders set status = p_status, data = jsonb_set(data, '{status}', to_jsonb(p_status)) where order_no = p_no returning * into o;
  return o.data;
end $fn$;
grant execute on function public.set_order_status(text, text) to authenticated; revoke execute on function public.set_order_status(text, text) from anon, public;
create or replace function public.track_order(p_no text, p_phone text) returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb;
begin
  perform public.rl_check('t:' || public.client_ip(), 15);
  select jsonb_build_object('no', order_no, 'status', status, 'pay_state', pay_state, 'data', data - 'addr' - 'cid') into r from orders where order_no = upper(trim(p_no)) and right(regexp_replace(coalesce(data->>'phone',''),'\D','','g'),8) = right(regexp_replace(coalesce(p_phone,''),'\D','','g'),8) limit 1;
  return r;
end $f$;
grant execute on function public.track_order(text, text) to anon, authenticated;
update public.kv set value = jsonb_set(value, '{announcement}', to_jsonb('نسخة تجريبية: المتجر قيد التجهيز والطلبات للتجربة فقط ولن تُنفّذ'::text)) where key = 'settings';
