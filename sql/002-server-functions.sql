insert into public.kv(key,value) values ('products','[{"id":1,"name":"إطار كونتكت سبورت ⁦205/55 R16⁩","cat":"الإطارات والجنوط","price":4850,"list":5600,"stock":34,"active":true,"img":"tire"},{"id":2,"name":"جنط ألومنيوم رياضي 17 بوصة","cat":"الإطارات والجنوط","price":6900,"list":8200,"stock":12,"active":true,"img":"wheel"},{"id":3,"name":"شامبو غسيل فائق اللمعان 750 مل","cat":"العناية والتنظيف","price":240,"list":320,"stock":120,"active":true,"img":"shampoo"},{"id":4,"name":"زيت محرك تخليقي 5W-30","cat":"العناية والتنظيف","price":1150,"list":1350,"stock":58,"active":true,"img":"oil"},{"id":5,"name":"كاميرا تابلوه مزدوجة 4K","cat":"الإلكترونيات","price":2750,"list":3400,"stock":22,"active":true,"img":"dashcam"},{"id":6,"name":"شاشة ملاحة أندرويد 9 بوصة","cat":"الإلكترونيات","price":5990,"list":7200,"stock":9,"active":true,"img":"screen"},{"id":7,"name":"شاحن سيارة سريع 48 واط","cat":"الإلكترونيات","price":420,"list":550,"stock":210,"active":true,"img":"charger"},{"id":8,"name":"حامل موبايل مغناطيسي للفتحات","cat":"الإلكترونيات","price":350,"list":480,"stock":140,"active":true,"img":"holder"},{"id":9,"name":"طقم فرش مقاعد جلد مبطّن","cat":"إكسسوارات داخلية","price":4400,"list":5500,"stock":15,"active":true,"img":"seats"},{"id":10,"name":"دواسات أرضية 3D مطاط","cat":"إكسسوارات داخلية","price":1650,"list":2100,"stock":40,"active":true,"img":"mats"},{"id":11,"name":"غطاء طارة جلد بخياطة حمراء","cat":"إكسسوارات داخلية","price":520,"list":700,"stock":85,"active":true,"img":"steering"},{"id":12,"name":"إضاءة داخلية LED بألوان متغيرة","cat":"إكسسوارات داخلية","price":680,"list":900,"stock":4,"active":true,"img":"ambient"},{"id":13,"name":"زوج كشافات LED مقاس H4","cat":"الإضاءة","price":1480,"list":1900,"stock":48,"active":true,"img":"led"},{"id":14,"name":"شاحن بطارية محمول (جامب ستارتر)","cat":"العدد والطوارئ","price":3200,"list":3850,"stock":18,"active":true,"img":"jump"},{"id":15,"name":"منفاخ إطارات رقمي محمول","cat":"العدد والطوارئ","price":1250,"list":1600,"stock":60,"active":true,"img":"inflator"},{"id":16,"name":"طقم عدّة 46 قطعة","cat":"العدد والطوارئ","price":2350,"list":2900,"stock":26,"active":true,"img":"tools"}]'::jsonb),('settings','{"name":"كار زون","phone":"01012345678","email":"support@karzon.eg","announcement":"الجمعة الصفراء: خصم ١٠٪ بكود KARZON10 وشحن مجاني فوق ٥٬٠٠٠ ج.م","shipping":90,"freeFrom":5000,"cod":true,"card":true,"wallet":true}'::jsonb),('coupons','[{"code":"KARZON10","type":"pct","value":10,"min":0,"active":true,"uses":0,"note":"خصم ١٠٪ على كل الطلبات"},{"code":"WELCOME50","type":"fixed","value":50,"min":500,"active":true,"uses":0,"note":"خصم ٥٠ ج.م للطلب الأول فوق ٥٠٠ ج.م"},{"code":"FREESHIP","type":"ship","value":0,"min":1000,"active":true,"uses":0,"note":"شحن مجاني فوق ١٬٠٠٠ ج.م"},{"code":"WINTER20","type":"pct","value":20,"min":3000,"active":false,"uses":0,"note":"خصم ٢٠٪ فوق ٣٬٠٠٠ ج.م (موقوف)"}]'::jsonb) on conflict (key) do nothing;
create sequence if not exists public.order_seq start 30500;
create unique index if not exists orders_cid on public.orders ((data->>'cid'));
drop policy if exists orders_insert on public.orders;
revoke insert on public.orders from anon, authenticated;
revoke all on public.admin_users from anon, authenticated;
create or replace function public.place_order(p jsonb, img text default null) returns jsonb language plpgsql security definer set search_path = public as $fn$
declare prods jsonb; sett jsonb; coups jsonb; it jsonb; pr jsonb; sub numeric := 0; disc numeric := 0; ship numeric := 0; tot numeric; code text; cp jsonb; fs boolean := false; pay text := p->>'pay'; ono text; items jsonb := '[]'; np jsonb := '[]'; nc jsonb := '[]'; q int; ex jsonb; rec jsonb; cid text := p->>'cid'; ref text := nullif(trim(coalesce(p->>'ref','')),''); ok boolean;
begin
  if cid is null or length(cid) < 8 or length(cid) > 64 then raise exception 'bad_request'; end if;
  select data into ex from orders where data->>'cid' = cid;
  if ex is not null then return ex; end if;
  if length(trim(coalesce(p->>'name',''))) < 3 or length(p->>'name') > 80 then raise exception 'bad_name'; end if;
  if coalesce(p->>'phone','') !~ '^01[0-9]{9}$' then raise exception 'bad_phone'; end if;
  if length(trim(coalesce(p->>'addr',''))) < 8 or length(p->>'addr') > 300 then raise exception 'bad_addr'; end if;
  if length(trim(coalesce(p->>'city',''))) < 2 or length(p->>'city') > 40 then raise exception 'bad_city'; end if;
  select value into prods from kv where key = 'products' for update;
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
  np := prods;
  for it in select * from jsonb_array_elements(p->'items') loop
    q := (it->>1)::int;
    if q < 1 or q > 20 then raise exception 'bad_qty'; end if;
    select e into pr from jsonb_array_elements(np) e where (e->>'id')::int = (it->>0)::int;
    if pr is null or not coalesce((pr->>'active')::boolean, false) then raise exception 'unavailable'; end if;
    if (pr->>'stock')::int < q then raise exception 'out_of_stock:%', pr->>'id'; end if;
    sub := sub + (pr->>'price')::numeric * q;
    items := items || jsonb_build_array(jsonb_build_array((pr->>'id')::int, q, (pr->>'price')::numeric));
    np := (select jsonb_agg(case when (e->>'id')::int = (pr->>'id')::int then jsonb_set(e, '{stock}', to_jsonb((e->>'stock')::int - q)) else e end) from jsonb_array_elements(np) e);
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
  update kv set value = np where key = 'products';
  ono := 'CZ-' || nextval('order_seq');
  rec := jsonb_build_object('no', ono, 'ts', (extract(epoch from now()) * 1000)::bigint, 'name', trim(p->>'name'), 'phone', p->>'phone', 'city', trim(p->>'city'), 'addr', trim(p->>'addr'), 'items', items, 'sub', sub, 'disc', disc, 'ship', ship, 'total', tot, 'coupon', code, 'pay', pay, 'status', 'new', 'cid', cid);
  if nullif(p->>'email','') is not null then rec := rec || jsonb_build_object('email', left(p->>'email', 80)); end if;
  if ref is not null then rec := rec || jsonb_build_object('ref', ref, 'payState', 'pending'); end if;
  insert into orders(order_no, data, receipt_img, pay_ref, pay_state, status) values (ono, rec, img, ref, case when ref is null then null else 'pending' end, 'new');
  return rec;
end $fn$;
grant execute on function public.place_order(jsonb, text) to anon, authenticated;
create or replace function public.set_order_status(p_no text, p_status text) returns jsonb language plpgsql security definer set search_path = public as $fn$
declare o orders%rowtype; prods jsonb; it jsonb; sign int := 0; np jsonb; q int; pr jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('new','processing','shipped','delivered','cancelled') then raise exception 'bad_status'; end if;
  select * into o from orders where order_no = p_no for update;
  if not found then raise exception 'not_found'; end if;
  if o.status = p_status then return o.data; end if;
  if p_status = 'cancelled' then sign := 1; elsif o.status = 'cancelled' then sign := -1; end if;
  if sign <> 0 then
    select value into prods from kv where key = 'products' for update; np := prods;
    for it in select * from jsonb_array_elements(o.data->'items') loop
      q := (it->>1)::int;
      select e into pr from jsonb_array_elements(np) e where (e->>'id')::int = (it->>0)::int;
      if pr is not null then
        if sign < 0 and (pr->>'stock')::int < q then raise exception 'out_of_stock'; end if;
        np := (select jsonb_agg(case when (e->>'id')::int = (it->>0)::int then jsonb_set(e, '{stock}', to_jsonb((e->>'stock')::int + sign * q)) else e end) from jsonb_array_elements(np) e);
      end if;
    end loop;
    update kv set value = np where key = 'products';
  end if;
  update orders set status = p_status, data = jsonb_set(data, '{status}', to_jsonb(p_status)) where order_no = p_no returning * into o;
  return o.data;
end $fn$;
grant execute on function public.set_order_status(text, text) to authenticated;
revoke execute on function public.set_order_status(text, text) from anon, public;
