create or replace function public.save_push_sub(p_endpoint text, p_p256dh text, p_auth text) returns void language plpgsql security definer set search_path = public as $f$
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if length(coalesce(p_endpoint,'')) < 20 or length(p_endpoint) > 600 or p_endpoint !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[A-Za-z0-9_./~%?=&:-]+$' or length(coalesce(p_p256dh,'')) < 20 or length(p_p256dh) > 200 or length(coalesce(p_auth,'')) < 8 or length(p_auth) > 100 then raise exception 'bad_sub'; end if;
  if (select count(*) from push_subs where user_id = auth.uid()) >= 5 then delete from push_subs where id = (select min(id) from push_subs where user_id = auth.uid()); end if;
  insert into push_subs(user_id, endpoint, p256dh, auth) values (auth.uid(), p_endpoint, p_p256dh, p_auth) on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $f$;
delete from public.push_subs where endpoint !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/';
select 'ok';
