Database migrations for the Supabase project (apply in order: 001, 002, 003). No secrets here.
003 supersedes the place_order, set_order_status and track_order functions from 002.
002 contains seed data and a final demo cleanup statement; do not re-run on a live store.
The admin user must be added by hand: insert into public.admin_users the id of the admin auth user.
