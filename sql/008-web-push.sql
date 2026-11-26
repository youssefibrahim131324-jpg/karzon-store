-- Web Push groundwork. Sending is OFF until push_enabled is set to 'true' by the owner after wording approval.
create extension if not exists pg_net with schema extensions;
create table if not exists public.push_subs (id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade, endpoint text not null unique, p256dh text not null, auth text not null, created_at timestamptz default now());
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;
create table if not exists public.private_config (key text primary key, value text not null);
alter table public.private_config enable row level security;
revoke all on public.private_config from anon, authenticated;
insert into public.private_config(key, value) values ('push_secret', '<set-by-owner>'), ('push_enabled', 'false') on conflict (key) do update set value = excluded.value where public.private_config.key = 'push_secret';
create or replace function public.save_push_sub(p_endpoint text, p_p256dh text, p_auth text) returns void language plpgsql security definer set search_path = public as $f$
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if length(coalesce(p_endpoint,'')) < 20 or length(p_endpoint) > 600 or p_endpoint !~ '^https://' or length(coalesce(p_p256dh,'')) < 20 or length(coalesce(p_auth,'')) < 8 then raise exception 'bad_sub'; end if;
  if (select count(*) from push_subs where user_id = auth.uid()) >= 5 then delete from push_subs where id = (select min(id) from push_subs where user_id = auth.uid()); end if;
  insert into push_subs(user_id, endpoint, p256dh, auth) values (auth.uid(), p_endpoint, p_p256dh, p_auth) on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $f$;
create or replace function public.delete_push_sub(p_endpoint text) returns void language sql security definer set search_path = public as $f$
  delete from push_subs where endpoint = p_endpoint and user_id = auth.uid() $f$;
revoke execute on function public.save_push_sub(text,text,text), public.delete_push_sub(text) from anon, public;
grant execute on function public.save_push_sub(text,text,text), public.delete_push_sub(text) to authenticated;
create or replace function public.notify_push() returns trigger language plpgsql security definer set search_path = public, extensions as $f$
declare en text; sec text; subs jsonb;
begin
  select value into en from private_config where key = 'push_enabled';
  if coalesce(en, 'false') <> 'true' then return new; end if;
  select value into sec from private_config where key = 'push_secret';
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]'::jsonb) into subs from push_subs where user_id = new.user_id;
  if jsonb_array_length(subs) = 0 then return new; end if;
  perform net.http_post(url := 'https://nokydnzflqezuqsxlebf.supabase.co/functions/v1/push', headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', sec), body := jsonb_build_object('subs', subs, 'title', 'كار زون', 'body', new.title, 'url', '#/account'));
  return new;
exception when others then return new;
end $f$;
drop trigger if exists notifications_push on public.notifications;
create trigger notifications_push after insert on public.notifications for each row execute function public.notify_push();
