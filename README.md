# 🌙 Moonloops

A cute handmade crochet shop: storefront + admin console in plain HTML, CSS and JavaScript,
with a Supabase database behind it.

## Files
- `index.html` – page shell
- `styles.css` – look and themes
- `app.js` – the shop (customer pages, cart, checkout, admin)
- `db.js` – talks to Supabase (products, orders, login, photos)
- `config.js` – your Supabase URL + publishable key (public by design)
- `supabase-setup.sql` – run once in the Supabase SQL Editor to create tables and security rules

## Setup (once)
1. Supabase → SQL Editor → paste `supabase-setup.sql` → Run.
2. Supabase → Authentication → Users → Add user (your admin email + a strong password, tick "Auto Confirm User").
3. SQL Editor → run:
   `insert into admins (user_id) select id from auth.users where email = 'YOUR-EMAIL' on conflict do nothing;`
4. Supabase → Authentication → Sign In / Providers → turn OFF "Allow new users to sign up".
5. Push to GitHub; GitHub Pages serves the site.

## Use
- Shop: your GitHub Pages address
- Admin: the same address + `#/admin` (log in with the admin email/password from step 2)

## Local demo mode
Set `url` and `key` in `config.js` to `''` and everything is stored in your own browser only.

## Never share
The Supabase `secret` / `service_role` key and your database password.
