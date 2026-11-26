create unique index if not exists orders_user_cid_uniq on public.orders (user_id, (data->>'cid')) where user_id is not null;
create or replace function public.orders_rate_limit() returns trigger language plpgsql security definer set search_path = public as $f$
begin
  if new.user_id is not null and (select count(*) from public.orders where user_id = new.user_id and created_at > now() - interval '1 hour') >= 8 then
    raise exception 'rate_limited';
  end if;
  return new;
end $f$;
drop trigger if exists orders_rate_limit_trg on public.orders;
create trigger orders_rate_limit_trg before insert on public.orders for each row execute function public.orders_rate_limit();
select (select string_agg(product_id||':'||qty, ',' order by qty) from (select * from public.stock order by qty limit 4) s) lowstock;
