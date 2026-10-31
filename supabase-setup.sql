-- =====================================================================
-- Moonloops database setup  (run ONCE in Supabase: SQL Editor -> New query -> paste -> Run)
-- Safe to run again: it re-creates the rules without deleting your data.
-- =====================================================================

-- 1. Who is a shop admin ------------------------------------------------
create table if not exists admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table admins enable row level security;   -- no policies = nobody can read it directly

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

-- 2. Tables ---------------------------------------------------------------
create table if not exists products (
  id bigint primary key,
  name text not null,
  price numeric(10,2) not null check (price >= 0),
  cat text not null,
  emoji text not null default '🧶',
  descr text not null default '',
  stock int not null default 0 check (stock >= 0),
  active boolean not null default true,
  feat boolean not null default false,
  tags jsonb not null default '[]',
  cross_ids jsonb not null default '[]',
  up bigint,
  imgs jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- shop-wide settings, promotions and bundles live here as small JSON documents
create table if not exists shop_data (key text primary key, value jsonb not null);

create table if not exists orders (
  id text primary key,
  user_id uuid,
  phone text not null,
  status text not null default 'New',
  data jsonb not null,
  created_at timestamptz not null default now()
);

create table if not exists product_views (pid bigint primary key, n bigint not null default 0);
create table if not exists co_views (a bigint, b bigint, n bigint not null default 0, primary key (a, b));
create sequence if not exists order_seq start 1001;

-- 3. Row level security: who can see / change what -----------------------
alter table products enable row level security;
alter table shop_data enable row level security;
alter table orders enable row level security;
alter table product_views enable row level security;
alter table co_views enable row level security;

drop policy if exists "anyone reads active products" on products;
create policy "anyone reads active products" on products for select using (active or is_admin());
drop policy if exists "admin writes products" on products;
create policy "admin writes products" on products for all using (is_admin()) with check (is_admin());

drop policy if exists "anyone reads shop data" on shop_data;
create policy "anyone reads shop data" on shop_data for select using (true);
drop policy if exists "admin writes shop data" on shop_data;
create policy "admin writes shop data" on shop_data for all using (is_admin()) with check (is_admin());

-- orders: ONLY the admin can read or change them directly (customers go through the functions below)
drop policy if exists "admin manages orders" on orders;
create policy "admin manages orders" on orders for all using (is_admin()) with check (is_admin());

-- 4. Safe functions customers can call -------------------------------------
-- Place an order. Prices and stock come from the database, not from the browser.
create or replace function place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  it jsonb; pr products%rowtype; items jsonb := '[]'::jsonb; lst numeric := 0; q int;
  nm text; ph text; ad text; sv numeric; dc numeric; fe numeric; tt numeric; oid_ text; ts text; ord jsonb;
begin
  nm := trim(coalesce(p->>'name','')); ph := trim(coalesce(p->>'phone','')); ad := trim(coalesce(p->>'addr',''));
  if nm = '' or ph = '' or ad = '' then raise exception 'Please fill in name, phone and address'; end if;
  if length(nm) > 100 or length(ph) > 40 or length(ad) > 500 then raise exception 'Details are too long'; end if;
  if coalesce(jsonb_typeof(p->'items'), '') <> 'array' or jsonb_array_length(p->'items') = 0 or jsonb_array_length(p->'items') > 50 then
    raise exception 'Your cart is empty';
  end if;
  for it in select value from jsonb_array_elements(p->'items') loop
    q := (it->>'q')::int;
    if q is null or q < 1 or q > 99 then raise exception 'Bad quantity'; end if;
    select * into pr from products where id = (it->>'id')::bigint for update;
    if not found or not pr.active then raise exception 'An item is no longer available'; end if;
    if pr.stock < q then raise exception 'Not enough stock for %', pr.name; end if;
    update products set stock = stock - q where id = pr.id;
    lst := lst + pr.price * q;
    items := items || jsonb_build_array(jsonb_build_object(
      'id', pr.id, 'name', pr.name, 'q', q, 'price', pr.price, 'bq', coalesce((it->>'bq')::int, 0)));
  end loop;
  sv := greatest(coalesce((p->>'sav')::numeric, 0), 0);
  dc := greatest(coalesce((p->>'disc')::numeric, 0), 0);
  fe := greatest(coalesce((p->>'fee')::numeric, 0), 0);
  if sv + dc > lst then raise exception 'Invalid discount'; end if;
  tt := lst - sv - dc + fe;
  oid_ := 'ML' || nextval('order_seq');
  ts := to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI') || ' UTC';
  ord := jsonb_build_object(
    'id', oid_, 'date', ts, 'name', nm, 'phone', ph, 'addr', ad,
    'zone', left(coalesce(p->>'zone',''), 100), 'items', items,
    'list', lst, 'sav', sv, 'sub', lst - sv, 'fee', fe, 'disc', dc,
    'coupon', left(coalesce(p->>'coupon',''), 40),
    'deals', coalesce(p->'deals', '[]'::jsonb), 'bundles', coalesce(p->'bundles', '[]'::jsonb),
    'total', tt, 'status', 'New', 'email', '',
    'log', jsonb_build_array(jsonb_build_object('s','New','t',ts,'note','Order placed')));
  insert into orders (id, user_id, phone, status, data) values (oid_, auth.uid(), ph, 'New', ord);
  return jsonb_build_object('id', oid_, 'total', tt);
end $$;

-- Track an order: needs the order number AND the phone number.
create or replace function track_order(order_no text, phone_no text) returns jsonb
language sql stable security definer set search_path = public as $$
  select o.data || jsonb_build_object('status', o.status)
  from orders o
  where lower(o.id) = lower(trim(order_no)) and trim(o.phone) = trim(phone_no)
  limit 1
$$;

-- A customer may cancel an order while it is still "New". Items go back in stock.
create or replace function cancel_order(order_no text, phone_no text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype; it jsonb; ts text;
begin
  select * into o from orders where lower(id) = lower(trim(order_no)) and trim(phone) = trim(phone_no) for update;
  if not found then raise exception 'Order not found'; end if;
  if o.status <> 'New' then raise exception 'This order can no longer be cancelled'; end if;
  for it in select value from jsonb_array_elements(o.data->'items') loop
    update products set stock = stock + (it->>'q')::int where id = (it->>'id')::bigint;
  end loop;
  ts := to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI') || ' UTC';
  update orders set status = 'Cancelled',
    data = o.data || jsonb_build_object('status', 'Cancelled',
      'log', coalesce(o.data->'log', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('s','Cancelled','t',ts,'note','Cancelled by customer')))
  where id = o.id;
  return jsonb_build_object('ok', true);
end $$;

-- Count a product view (used for "trending" and "people also viewed").
create or replace function bump_view(p_id bigint, p_prevs bigint[]) returns void
language plpgsql security definer set search_path = public as $$
declare x bigint;
begin
  if not exists (select 1 from products where id = p_id and active) then return; end if;
  insert into product_views (pid, n) values (p_id, 1) on conflict (pid) do update set n = product_views.n + 1;
  foreach x in array coalesce(p_prevs, '{}'::bigint[]) loop
    if x <> p_id then
      insert into co_views (a, b, n) values (p_id, x, 1) on conflict (a, b) do update set n = co_views.n + 1;
      insert into co_views (a, b, n) values (x, p_id, 1) on conflict (a, b) do update set n = co_views.n + 1;
    end if;
  end loop;
end $$;

-- Sales + browsing totals (no personal details) for trending / also-bought.
create or replace function shop_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'sold', coalesce((
      select jsonb_object_agg(pid, q) from (
        select (i.value->>'id') as pid, sum((i.value->>'q')::int) as q
        from orders o, jsonb_array_elements(o.data->'items') i
        where o.status <> 'Cancelled' group by 1) s), '{}'::jsonb),
    'bought', coalesce((
      select jsonb_object_agg(a, m) from (
        select a, jsonb_object_agg(b, n) as m from (
          select (x.value->>'id') as a, (y.value->>'id') as b, count(*) as n
          from orders o, jsonb_array_elements(o.data->'items') x, jsonb_array_elements(o.data->'items') y
          where o.status <> 'Cancelled' and (x.value->>'id') <> (y.value->>'id')
          group by 1, 2) t
        group by a) u), '{}'::jsonb),
    'views', coalesce((select jsonb_object_agg(pid::text, n) from product_views), '{}'::jsonb),
    'co', coalesce((
      select jsonb_object_agg(a, m) from (
        select a::text as a, jsonb_object_agg(b::text, n) as m from co_views group by a) z), '{}'::jsonb))
$$;

grant execute on function is_admin() to anon, authenticated;
grant execute on function place_order(jsonb) to anon, authenticated;
grant execute on function track_order(text, text) to anon, authenticated;
grant execute on function cancel_order(text, text) to anon, authenticated;
grant execute on function bump_view(bigint, bigint[]) to anon, authenticated;
grant execute on function shop_stats() to anon, authenticated;

-- 5. Photo storage ----------------------------------------------------------
insert into storage.buckets (id, name, public) values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists "admin uploads photos" on storage.objects;
create policy "admin uploads photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and is_admin());
drop policy if exists "admin changes photos" on storage.objects;
create policy "admin changes photos" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and is_admin());
drop policy if exists "admin deletes photos" on storage.objects;
create policy "admin deletes photos" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and is_admin());

-- =====================================================================
-- 6. LAST STEP (after you create your admin user in Authentication -> Users):
--    replace YOUR-EMAIL with the email of that user, then run just this line.
--
--    insert into admins (user_id) select id from auth.users where email = 'YOUR-EMAIL'
--    on conflict do nothing;
-- =====================================================================
