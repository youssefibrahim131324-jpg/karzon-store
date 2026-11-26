-- Order snapshots keep product names; admin-assisted password reset (no email service needed).
create or replace function public.place_order(p jsonb, img text default null) returns jsonb language plpgsql security definer set search_path = public as $fn$
declare prods jsonb; sett jsonb; coups jsonb; it jsonb; pr jsonb; sub numeric := 0; disc numeric := 0; ship numeric := 0; tot numeric; code text; cp jsonb; fs boolean := false; pay text := p->>'pay'; ono text; items jsonb := '[]'; nc jsonb; q int; ex jsonb; rec jsonb; cid text := p->>'cid'; ref text := nullif(trim(coalesce(p->>'ref','')),''); ok boolean; left_q int; nm jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if cid is null or length(cid) < 8 or length(cid) > 64 then raise exception 'bad_request'; end if;
  select data into ex from orders where data->>'cid' = cid and user_id = auth.uid();
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
    nm := nm || jsonb_build_object(pr->>'id', pr->>'name');
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
  rec := jsonb_build_object('no', ono, 'ts', (extract(epoch from now()) * 1000)::bigint, 'name', trim(p->>'name'), 'phone', p->>'phone', 'city', trim(p->>'city'), 'addr', trim(p->>'addr'), 'items', items, 'names', nm, 'sub', sub, 'disc', disc, 'ship', ship, 'total', tot, 'coupon', code, 'pay', pay, 'status', 'new', 'cid', cid, 'email', coalesce(auth.jwt()->>'email',''));
  if ref is not null then rec := rec || jsonb_build_object('ref', ref, 'payState', 'pending'); end if;
  insert into orders(order_no, data, receipt_img, pay_ref, pay_state, status, user_id) values (ono, rec, img, ref, case when ref is null then null else 'pending' end, 'new', auth.uid());
  insert into notifications(user_id, order_no, title, body) values (auth.uid(), ono, 'تم استلام طلبك ' || ono, 'إجمالي الطلب ' || tot::text || ' ج.م. سنُبلغك هنا عند تغيّر حالته.');
  return rec;
end $fn$;
create or replace function public.admin_reset_password(p_user uuid, p_pw text) returns void language plpgsql security definer set search_path = public, auth, extensions as $f$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if length(coalesce(p_pw,'')) < 8 or length(p_pw) > 72 then raise exception 'weak'; end if;
  if exists (select 1 from public.admin_users where user_id = p_user) then raise exception 'forbidden'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_pw, extensions.gen_salt('bf')), updated_at = now() where id = p_user;
  if not found then raise exception 'not_found'; end if;
end $f$;
revoke execute on function public.admin_reset_password(uuid, text) from anon, public;
grant execute on function public.admin_reset_password(uuid, text) to authenticated;
