-- Public bucket for product photos; only admins may write.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists pi_admin_ins on storage.objects;
drop policy if exists pi_admin_upd on storage.objects;
drop policy if exists pi_admin_del on storage.objects;
create policy pi_admin_ins on storage.objects for insert to authenticated with check (bucket_id = 'product-images' and public.is_admin());
create policy pi_admin_upd on storage.objects for update to authenticated using (bucket_id = 'product-images' and public.is_admin()) with check (bucket_id = 'product-images' and public.is_admin());
create policy pi_admin_del on storage.objects for delete to authenticated using (bucket_id = 'product-images' and public.is_admin());
