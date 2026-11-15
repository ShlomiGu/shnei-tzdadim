insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 12582912, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "upload into an existing wedding folder" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'photos' and public.wedding_exists((storage.foldername(name))[1]));;
