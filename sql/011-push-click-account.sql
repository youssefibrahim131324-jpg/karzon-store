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
select 'ok';
