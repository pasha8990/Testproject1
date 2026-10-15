-- =====================================================================
--  Shop Manager — Supabase schema (multi-tenant + RLS + RPC)
--  Run once in: Supabase Dashboard → SQL Editor (fresh project / fresh schema)
--
--  Roles (per shop):
--    owner   : everything, incl. Settings + Team + invites
--    manager : products, customers, suppliers, purchases, expenses, stock
--              adjustments, cancel orders, invite staff, reports
--    staff   : create orders, record payments, mark completed, customers
--              (add/edit), read products / stock / orders
--
--  Design rules
--    * Every business table has shop_id; RLS isolates shops from each other.
--    * One user belongs to exactly one shop (unique(user_id) on shop_members).
--    * Orders, payments, stock and purchases are changed ONLY through RPC
--      functions (security definer) so stock / totals / numbers can't drift.
--      The client has SELECT only on those tables.
--    * products.stock is kept in sync by a stock_movements ledger (trigger).
--      Editing stock in the Products grid is allowed for managers and is
--      logged automatically as a "Manual edit" movement.
-- =====================================================================

-- ---------------------------------------------------------------------
-- OPTIONAL RESET (development only!). Uncomment to wipe and re-run.
-- ---------------------------------------------------------------------
-- drop trigger if exists on_auth_user_created on auth.users;
-- drop trigger if exists on_auth_user_email_changed on auth.users;
-- drop schema if exists private cascade;
-- drop view if exists public.customer_summary, public.supplier_summary;
-- drop table if exists public.shop_counters, public.stock_movements, public.expenses,
--   public.purchase_order_items, public.purchase_orders, public.payments,
--   public.order_items, public.orders, public.suppliers, public.customers,
--   public.products, public.invitations, public.shop_members, public.profiles,
--   public.shops cascade;
-- drop type if exists public.member_role, public.order_status, public.payment_status,
--   public.purchase_status, public.payment_method cascade;

begin;

-- =====================================================================
-- 1. SCHEMA + ENUMS
-- =====================================================================
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create type public.member_role     as enum ('owner', 'manager', 'staff');
create type public.order_status    as enum ('pending', 'completed', 'cancelled');
create type public.payment_status  as enum ('unpaid', 'partial', 'paid');
create type public.purchase_status as enum ('ordered', 'received', 'cancelled');
create type public.payment_method  as enum ('cash', 'card', 'bank_transfer');

-- =====================================================================
-- 2. TABLES
-- =====================================================================

-- ---- shops (Settings → Shop profile) --------------------------------
create table public.shops (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null check (length(trim(name)) > 0),
  currency            text not null default '$',
  tax_rate            numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  address             text,
  logo_path           text,                                  -- path inside storage bucket "shop-logos"
  low_stock_threshold integer not null default 10 check (low_stock_threshold >= 0),
  timezone            text not null default 'UTC',           -- e.g. 'America/Los_Angeles' (used by reports)
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ---- profiles (1:1 with auth.users) ---------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text not null default '',
  date_format text not null default 'mdy' check (date_format in ('mdy', 'dmy', 'iso')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---- team ------------------------------------------------------------
create table public.shop_members (
  shop_id    uuid not null references public.shops(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       public.member_role not null default 'staff',
  created_at timestamptz not null default now(),
  primary key (shop_id, user_id),
  unique (user_id)                      -- one shop per user (drop this to allow multi-shop)
);

create table public.invitations (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops(id) on delete cascade,
  email       text not null check (position('@' in email) > 1),
  full_name   text,
  role        public.member_role not null default 'staff' check (role <> 'owner'),
  token       text not null unique
              default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  invited_by  uuid references public.profiles(id) on delete set null default auth.uid(),
  expires_at  timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  accepted_by uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create unique index invitations_open_email_uidx
  on public.invitations (shop_id, lower(email)) where accepted_at is null;

-- ---- catalogue -------------------------------------------------------
create table public.products (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops(id) on delete cascade,
  sku           text not null default '',                   -- blank => auto "SKU-0001"
  name          text not null check (length(trim(name)) > 0),
  category      text not null default '',
  cost          numeric(12,2) not null default 0 check (cost >= 0),
  price         numeric(12,2) not null default 0 check (price >= 0),
  stock         integer not null default 0 check (stock >= 0),
  reorder_level integer not null default 0 check (reorder_level >= 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (shop_id, sku)
);

create table public.customers (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops(id) on delete cascade,
  name       text not null check (length(trim(name)) > 0),
  email      text,
  phone      text,
  address    text,
  notes      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops(id) on delete cascade,
  name       text not null check (length(trim(name)) > 0),
  email      text,
  phone      text,
  notes      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- sales -----------------------------------------------------------
create table public.orders (
  id              uuid primary key default gen_random_uuid(),
  shop_id         uuid not null references public.shops(id) on delete cascade,
  number          text not null,                            -- ORD-0001
  customer_id     uuid references public.customers(id) on delete set null,   -- null = walk-in
  customer_name   text,                                     -- snapshot (survives customer deletion)
  status          public.order_status   not null default 'pending',
  payment_status  public.payment_status not null default 'unpaid',   -- maintained by trigger
  payment_method  public.payment_method not null default 'cash',
  subtotal        numeric(12,2) not null default 0 check (subtotal >= 0),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  tax_rate        numeric(5,2)  not null default 0 check (tax_rate between 0 and 100),
  tax_amount      numeric(12,2) not null default 0 check (tax_amount >= 0),
  total           numeric(12,2) not null default 0 check (total >= 0),
  paid_amount     numeric(12,2) not null default 0 check (paid_amount >= 0),  -- maintained by trigger
  notes           text,
  created_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  completed_at    timestamptz,
  cancelled_at    timestamptz,
  unique (shop_id, number),
  check (discount_amount <= subtotal)
);

create table public.order_items (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id) on delete cascade,
  order_id     uuid not null references public.orders(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete restrict,
  product_name text not null,                               -- snapshots
  sku          text not null,
  qty          integer not null check (qty > 0),
  unit_price   numeric(12,2) not null check (unit_price >= 0),
  unit_cost    numeric(12,2) not null default 0 check (unit_cost >= 0),   -- cost at time of sale (profit reports)
  line_total   numeric(12,2) generated always as (round(qty * unit_price, 2)) stored
);

create table public.payments (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops(id) on delete cascade,
  order_id   uuid not null references public.orders(id) on delete cascade,
  amount     numeric(12,2) not null check (amount > 0),
  method     public.payment_method not null default 'cash',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---- purchasing ------------------------------------------------------
create table public.purchase_orders (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops(id) on delete cascade,
  number        text not null,                              -- PO-0001
  supplier_id   uuid references public.suppliers(id) on delete set null,
  supplier_name text,                                       -- snapshot
  status        public.purchase_status not null default 'ordered',
  total         numeric(12,2) not null default 0 check (total >= 0),
  notes         text,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  received_at   timestamptz,
  cancelled_at  timestamptz,
  unique (shop_id, number)
);

create table public.purchase_order_items (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id        uuid not null references public.products(id) on delete restrict,
  product_name      text not null,
  qty               integer not null check (qty > 0),
  unit_cost         numeric(12,2) not null check (unit_cost >= 0),
  line_total        numeric(12,2) generated always as (round(qty * unit_cost, 2)) stored
);

-- ---- money out -------------------------------------------------------
create table public.expenses (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops(id) on delete cascade,
  spent_on   date not null default current_date,
  category   text not null check (length(trim(category)) > 0),
  amount     numeric(12,2) not null check (amount > 0),
  notes      text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- inventory ledger ------------------------------------------------
create table public.stock_movements (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  delta      integer not null check (delta <> 0),
  reason     text not null default '',
  ref_type   text check (ref_type in ('order', 'purchase', 'manual')),
  ref_id     uuid,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---- per-shop number counters (ORD / PO / SKU) -----------------------
create table public.shop_counters (
  shop_id uuid not null references public.shops(id) on delete cascade,
  kind    text not null,
  value   integer not null default 0,
  primary key (shop_id, kind)
);

-- =====================================================================
-- 3. INDEXES
-- =====================================================================
create index products_shop_category_idx   on public.products (shop_id, category);
create index products_shop_name_idx       on public.products (shop_id, name);
create index customers_shop_name_idx      on public.customers (shop_id, name);
create index suppliers_shop_name_idx      on public.suppliers (shop_id, name);
create index orders_shop_created_idx      on public.orders (shop_id, created_at desc);
create index orders_shop_status_idx       on public.orders (shop_id, status);
create index orders_customer_idx          on public.orders (customer_id);
create index order_items_order_idx        on public.order_items (order_id);
create index order_items_product_idx      on public.order_items (product_id);
create index order_items_shop_idx         on public.order_items (shop_id);
create index payments_order_idx           on public.payments (order_id);
create index payments_shop_idx            on public.payments (shop_id);
create index purchase_orders_shop_idx     on public.purchase_orders (shop_id, created_at desc);
create index purchase_orders_supplier_idx on public.purchase_orders (supplier_id);
create index po_items_po_idx              on public.purchase_order_items (purchase_order_id);
create index po_items_product_idx         on public.purchase_order_items (product_id);
create index po_items_shop_idx            on public.purchase_order_items (shop_id);
create index expenses_shop_spent_idx      on public.expenses (shop_id, spent_on desc);
create index stock_mov_shop_created_idx   on public.stock_movements (shop_id, created_at desc);
create index stock_mov_product_idx        on public.stock_movements (product_id, created_at desc);
create index invitations_shop_idx         on public.invitations (shop_id);

-- =====================================================================
-- 4. PRIVATE HELPERS (not exposed through the API)
-- =====================================================================
create or replace function private.my_shop_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select m.shop_id from public.shop_members m where m.user_id = (select auth.uid()) limit 1
$$;

create or replace function private.my_role()
returns public.member_role language sql stable security definer set search_path = '' as $$
  select m.role from public.shop_members m where m.user_id = (select auth.uid()) limit 1
$$;

create or replace function private.is_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select m.role = 'owner' from public.shop_members m
                   where m.user_id = (select auth.uid())), false)
$$;

create or replace function private.is_manager()          -- owner or manager
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select m.role in ('owner', 'manager') from public.shop_members m
                   where m.user_id = (select auth.uid())), false)
$$;

create or replace function private.next_counter(p_shop uuid, p_kind text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
  insert into public.shop_counters (shop_id, kind, value) values (p_shop, p_kind, 1)
  on conflict (shop_id, kind) do update set value = public.shop_counters.value + 1
  returning value into v;
  return v;
end $$;

create or replace function private.fmt_number(p_prefix text, p_n integer)
returns text language sql immutable set search_path = '' as $$
  select p_prefix || '-' || case when p_n < 10000 then lpad(p_n::text, 4, '0') else p_n::text end
$$;

create or replace function private.create_shop_for(p_user uuid, p_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_shop uuid;
begin
  insert into public.shops (name) values (trim(p_name)) returning id into v_shop;
  insert into public.shop_members (shop_id, user_id, role) values (v_shop, p_user, 'owner');
  return v_shop;
end $$;

-- =====================================================================
-- 5. TRIGGERS
-- =====================================================================

-- ---- updated_at ------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger trg_shops_updated          before update on public.shops          for each row execute function private.set_updated_at();
create trigger trg_profiles_updated       before update on public.profiles       for each row execute function private.set_updated_at();
create trigger trg_products_updated       before update on public.products       for each row execute function private.set_updated_at();
create trigger trg_customers_updated      before update on public.customers      for each row execute function private.set_updated_at();
create trigger trg_suppliers_updated      before update on public.suppliers      for each row execute function private.set_updated_at();
create trigger trg_orders_updated         before update on public.orders         for each row execute function private.set_updated_at();
create trigger trg_purchase_orders_updated before update on public.purchase_orders for each row execute function private.set_updated_at();
create trigger trg_expenses_updated       before update on public.expenses       for each row execute function private.set_updated_at();

-- ---- auto SKU when blank --------------------------------------------
create or replace function private.fill_sku()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.sku := trim(coalesce(new.sku, ''));
  if new.sku = '' then
    loop
      new.sku := 'SKU-' || lpad(private.next_counter(new.shop_id, 'sku')::text, 4, '0');
      exit when not exists (select 1 from public.products p
                            where p.shop_id = new.shop_id and p.sku = new.sku);
    end loop;
  end if;
  return new;
end $$;
create trigger trg_products_sku before insert on public.products
  for each row execute function private.fill_sku();

-- ---- stock ledger: movement => product.stock --------------------------
create or replace function private.apply_stock_movement()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('app.skip_apply', true), '') = 'on' then
    return new;                                   -- manual edit already changed products.stock
  end if;
  perform set_config('app.stock_sync', 'on', true);
  update public.products set stock = stock + new.delta where id = new.product_id;
  perform set_config('app.stock_sync', 'off', true);
  return new;
end $$;
create trigger trg_stock_apply after insert on public.stock_movements
  for each row execute function private.apply_stock_movement();

-- ---- direct edits of products.stock are logged as movements -----------
create or replace function private.log_product_stock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_delta integer; v_reason text;
begin
  if tg_op = 'INSERT' then
    v_delta := new.stock; v_reason := 'Initial stock';
  elsif new.stock is distinct from old.stock
        and coalesce(current_setting('app.stock_sync', true), '') <> 'on' then
    v_delta := new.stock - old.stock; v_reason := 'Manual edit';
  else
    return null;
  end if;

  if v_delta <> 0 then
    perform set_config('app.skip_apply', 'on', true);
    insert into public.stock_movements (shop_id, product_id, delta, reason, ref_type, created_by)
    values (new.shop_id, new.id, v_delta, v_reason, 'manual', (select auth.uid()));
    perform set_config('app.skip_apply', 'off', true);
  end if;
  return null;
end $$;
create trigger trg_products_stock_ins after insert on public.products
  for each row execute function private.log_product_stock();
create trigger trg_products_stock_upd after update of stock on public.products
  for each row execute function private.log_product_stock();

-- ---- payments => orders.paid_amount / payment_status ------------------
create or replace function private.sync_order_payment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_order uuid; v_paid numeric(12,2);
begin
  v_order := coalesce(new.order_id, old.order_id);
  select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = v_order;
  update public.orders o
     set paid_amount    = v_paid,
         payment_status = case when v_paid <= 0       then 'unpaid'::public.payment_status
                               when v_paid >= o.total then 'paid'::public.payment_status
                               else 'partial'::public.payment_status end
   where o.id = v_order;
  return null;
end $$;
create trigger trg_payments_sync after insert or update or delete on public.payments
  for each row execute function private.sync_order_payment();

-- =====================================================================
-- 6. AUTH HOOKS: profile + shop / invite acceptance on sign-up
-- =====================================================================
-- signUp({ email, password, options: { data: {
--    full_name,
--    shop_name,       -- owner sign-up (creates a new shop)
--    invite_token     -- invited member (joins existing shop)
-- }}})
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_meta  jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_name  text  := coalesce(nullif(trim(v_meta->>'full_name'), ''), split_part(coalesce(new.email, ''), '@', 1));
  v_token text  := nullif(trim(v_meta->>'invite_token'), '');
  v_shop  text  := nullif(trim(v_meta->>'shop_name'), '');
  inv     public.invitations;
begin
  insert into public.profiles (id, email, full_name) values (new.id, new.email, v_name);

  if v_token is not null then
    select * into inv from public.invitations i
     where i.token = v_token and i.accepted_at is null and i.expires_at > now()
       and lower(i.email) = lower(coalesce(new.email, ''))
     for update;
    if not found then
      raise exception 'Invalid or expired invitation';   -- blocks the sign-up
    end if;
    insert into public.shop_members (shop_id, user_id, role) values (inv.shop_id, new.id, inv.role);
    update public.invitations set accepted_at = now(), accepted_by = new.id where id = inv.id;
  elsif v_shop is not null then
    perform private.create_shop_for(new.id, v_shop);
  end if;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end $$;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

-- =====================================================================
-- 7. ROW LEVEL SECURITY
-- =====================================================================
alter table public.shops                 enable row level security;
alter table public.profiles              enable row level security;
alter table public.shop_members          enable row level security;
alter table public.invitations           enable row level security;
alter table public.products              enable row level security;
alter table public.customers             enable row level security;
alter table public.suppliers             enable row level security;
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;
alter table public.payments              enable row level security;
alter table public.purchase_orders       enable row level security;
alter table public.purchase_order_items  enable row level security;
alter table public.expenses              enable row level security;
alter table public.stock_movements       enable row level security;
alter table public.shop_counters         enable row level security;   -- no policy = no access

-- ---- shops -----------------------------------------------------------
create policy shops_select on public.shops for select to authenticated
  using (id = (select private.my_shop_id()));
create policy shops_update on public.shops for update to authenticated
  using (id = (select private.my_shop_id()) and (select private.is_owner()))
  with check (id = (select private.my_shop_id()) and (select private.is_owner()));

-- ---- profiles --------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or exists (select 1 from public.shop_members m
               where m.user_id = profiles.id and m.shop_id = (select private.my_shop_id()))
  );
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ---- team ------------------------------------------------------------
create policy members_select on public.shop_members for select to authenticated
  using (shop_id = (select private.my_shop_id()));
create policy members_update on public.shop_members for update to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_owner()) and role <> 'owner')
  with check (shop_id = (select private.my_shop_id()) and (select private.is_owner()) and role <> 'owner');
create policy members_delete on public.shop_members for delete to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_owner()) and role <> 'owner');

create policy invitations_select on public.invitations for select to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy invitations_insert on public.invitations for insert to authenticated
  with check (
    shop_id = (select private.my_shop_id())
    and ( (select private.my_role()) = 'owner'
       or ((select private.my_role()) = 'manager' and role = 'staff') )
  );
create policy invitations_delete on public.invitations for delete to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));

-- ---- products (read: all members | write: manager+) -------------------
create policy products_select on public.products for select to authenticated
  using (shop_id = (select private.my_shop_id()));
create policy products_insert on public.products for insert to authenticated
  with check (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy products_update on public.products for update to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()))
  with check (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy products_delete on public.products for delete to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));

-- ---- customers (read/add/edit: all members | delete: manager+) --------
create policy customers_select on public.customers for select to authenticated
  using (shop_id = (select private.my_shop_id()));
create policy customers_insert on public.customers for insert to authenticated
  with check (shop_id = (select private.my_shop_id()));
create policy customers_update on public.customers for update to authenticated
  using (shop_id = (select private.my_shop_id()))
  with check (shop_id = (select private.my_shop_id()));
create policy customers_delete on public.customers for delete to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));

-- ---- suppliers (manager+) ---------------------------------------------
create policy suppliers_select on public.suppliers for select to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy suppliers_insert on public.suppliers for insert to authenticated
  with check (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy suppliers_update on public.suppliers for update to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()))
  with check (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy suppliers_delete on public.suppliers for delete to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));

-- ---- sales: read-only for the client (writes go through RPC) ----------
create policy orders_select on public.orders for select to authenticated
  using (shop_id = (select private.my_shop_id()));
create policy order_items_select on public.order_items for select to authenticated
  using (shop_id = (select private.my_shop_id()));
create policy payments_select on public.payments for select to authenticated
  using (shop_id = (select private.my_shop_id()));

-- ---- purchasing: read-only for manager+ (writes via RPC) --------------
create policy purchase_orders_select on public.purchase_orders for select to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy po_items_select on public.purchase_order_items for select to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));

-- ---- expenses (manager+) ----------------------------------------------
create policy expenses_select on public.expenses for select to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy expenses_insert on public.expenses for insert to authenticated
  with check (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy expenses_update on public.expenses for update to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()))
  with check (shop_id = (select private.my_shop_id()) and (select private.is_manager()));
create policy expenses_delete on public.expenses for delete to authenticated
  using (shop_id = (select private.my_shop_id()) and (select private.is_manager()));

-- ---- stock ledger: read-only for the client ---------------------------
create policy stock_movements_select on public.stock_movements for select to authenticated
  using (shop_id = (select private.my_shop_id()));

-- =====================================================================
-- 8. RPC FUNCTIONS (the only way to create/change orders, stock, POs)
-- =====================================================================

-- ---- onboarding for users that have no shop (e.g. OAuth sign-in) ------
create or replace function public.create_shop(p_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if private.my_shop_id() is not null then raise exception 'You already belong to a shop'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Shop name is required'; end if;
  return private.create_shop_for((select auth.uid()), p_name);
end $$;

-- ---- signup page: look up an invite link (works before login) ---------
create or replace function public.get_invitation(p_token text)
returns table (org_name text, invitee_email text, invitee_name text, invitee_role public.member_role)
language sql stable security definer set search_path = '' as $$
  select s.name, i.email, i.full_name, i.role
  from public.invitations i
  join public.shops s on s.id = i.shop_id
  where i.token = p_token and i.accepted_at is null and i.expires_at > now()
$$;

-- ---- NEW ORDER --------------------------------------------------------
-- p_items = [{"product_id":"<uuid>","qty":2,"unit_price":19.90}, ...]
-- p_discount_mode: 'amount' | 'percent' ; p_payment: 'unpaid' | 'partial' | 'paid'
-- p_customer_id null => walk-in customer. Totals are recalculated server-side.
create or replace function public.create_order(
  p_customer_id    uuid,
  p_items          jsonb,
  p_discount_mode  text default 'amount',
  p_discount_value numeric default 0,
  p_tax_rate       numeric default null,
  p_payment        text default 'unpaid',
  p_paid           numeric default 0,
  p_payment_method public.payment_method default 'cash',
  p_notes          text default null
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  v_shop     uuid := private.my_shop_id();
  v_order    public.orders;
  v_line     record;
  v_prod     public.products;
  v_subtotal numeric(12,2);
  v_discount numeric(12,2);
  v_rate     numeric(5,2);
  v_tax      numeric(12,2);
  v_total    numeric(12,2);
  v_paid     numeric(12,2) := 0;
  v_cust     text;
begin
  if v_shop is null then raise exception 'You do not belong to a shop' using errcode = '42501'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'An order needs at least one item';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
             where (e->>'product_id') is null
                or coalesce((e->>'qty')::integer, 0) <= 0
                or coalesce((e->>'unit_price')::numeric, -1) < 0) then
    raise exception 'Every line needs a product, a quantity of 1 or more and a valid price';
  end if;

  select coalesce(sum(round((e->>'qty')::integer * (e->>'unit_price')::numeric, 2)), 0)
    into v_subtotal from jsonb_array_elements(p_items) e;

  if p_discount_mode = 'percent' then
    v_discount := round(v_subtotal * least(greatest(coalesce(p_discount_value, 0), 0), 100) / 100, 2);
  else
    v_discount := round(greatest(coalesce(p_discount_value, 0), 0), 2);
  end if;
  v_discount := least(v_discount, v_subtotal);

  select least(greatest(coalesce(p_tax_rate, s.tax_rate), 0), 100) into v_rate
    from public.shops s where s.id = v_shop;
  v_tax   := round((v_subtotal - v_discount) * v_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_tax;

  if p_payment = 'paid' then
    v_paid := v_total;
  elsif p_payment = 'partial' then
    if p_paid is null or p_paid <= 0 or p_paid > v_total then
      raise exception 'Paid amount must be greater than 0 and not more than the total (%)', v_total;
    end if;
    v_paid := round(p_paid, 2);
  elsif p_payment <> 'unpaid' then
    raise exception 'Invalid payment option: %', p_payment;
  end if;

  if p_customer_id is not null then
    select c.name into v_cust from public.customers c where c.id = p_customer_id and c.shop_id = v_shop;
    if not found then raise exception 'Customer not found'; end if;
  end if;

  insert into public.orders (shop_id, number, customer_id, customer_name, payment_method,
                             subtotal, discount_amount, tax_rate, tax_amount, total, notes, created_by)
  values (v_shop, private.fmt_number('ORD', private.next_counter(v_shop, 'order')),
          p_customer_id, v_cust, p_payment_method,
          v_subtotal, v_discount, v_rate, v_tax, v_total, nullif(trim(p_notes), ''), (select auth.uid()))
  returning * into v_order;

  -- lock products in a stable order (avoids deadlocks), check stock, write lines + ledger
  for v_line in
    select (e->>'product_id')::uuid as product_id,
           (e->>'qty')::integer     as qty,
           (e->>'unit_price')::numeric as unit_price
    from jsonb_array_elements(p_items) e
    order by 1
  loop
    select * into v_prod from public.products
     where id = v_line.product_id and shop_id = v_shop for update;
    if not found then raise exception 'Product not found'; end if;
    if not v_prod.active then raise exception '"%" is inactive', v_prod.name; end if;
    if v_prod.stock < v_line.qty then
      raise exception 'Not enough stock for "%" (% available)', v_prod.name, v_prod.stock;
    end if;

    insert into public.order_items (shop_id, order_id, product_id, product_name, sku, qty, unit_price, unit_cost)
    values (v_shop, v_order.id, v_prod.id, v_prod.name, v_prod.sku, v_line.qty, v_line.unit_price, v_prod.cost);

    insert into public.stock_movements (shop_id, product_id, delta, reason, ref_type, ref_id, created_by)
    values (v_shop, v_prod.id, -v_line.qty, 'Sale ' || v_order.number, 'order', v_order.id, (select auth.uid()));
  end loop;

  if v_paid > 0 then
    insert into public.payments (shop_id, order_id, amount, method, created_by)
    values (v_shop, v_order.id, v_paid, p_payment_method, (select auth.uid()));
  end if;

  select * into v_order from public.orders where id = v_order.id;   -- fresh (trigger-updated) row
  return v_order;
end $$;

-- ---- record a payment on an existing order ----------------------------
create or replace function public.record_payment(
  p_order_id uuid, p_amount numeric, p_method public.payment_method default 'cash'
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_shop uuid := private.my_shop_id(); v_order public.orders; v_balance numeric(12,2);
begin
  if v_shop is null then raise exception 'You do not belong to a shop' using errcode = '42501'; end if;
  select * into v_order from public.orders where id = p_order_id and shop_id = v_shop for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status = 'cancelled' then raise exception 'Cannot record a payment on a cancelled order'; end if;

  v_balance := v_order.total - v_order.paid_amount;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if p_amount > v_balance then raise exception 'Amount can''t exceed the balance due (%)', v_balance; end if;

  insert into public.payments (shop_id, order_id, amount, method, created_by)
  values (v_shop, v_order.id, round(p_amount, 2), p_method, (select auth.uid()));

  select * into v_order from public.orders where id = p_order_id;
  return v_order;
end $$;

-- ---- mark completed ---------------------------------------------------
create or replace function public.complete_order(p_order_id uuid)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  update public.orders
     set status = 'completed', completed_at = now()
   where id = p_order_id and shop_id = private.my_shop_id() and status = 'pending'
   returning * into v_order;
  if not found then raise exception 'Order not found or not pending'; end if;
  return v_order;
end $$;

-- ---- cancel (manager+), puts stock back -------------------------------
create or replace function public.cancel_order(p_order_id uuid)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare v_shop uuid := private.my_shop_id(); v_order public.orders; v_item record;
begin
  if not private.is_manager() then raise exception 'Only managers can cancel orders' using errcode = '42501'; end if;
  select * into v_order from public.orders where id = p_order_id and shop_id = v_shop for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status <> 'pending' then raise exception 'Only pending orders can be cancelled'; end if;

  for v_item in select product_id, qty from public.order_items where order_id = v_order.id order by product_id loop
    insert into public.stock_movements (shop_id, product_id, delta, reason, ref_type, ref_id, created_by)
    values (v_shop, v_item.product_id, v_item.qty, 'Cancelled ' || v_order.number, 'order', v_order.id, (select auth.uid()));
  end loop;

  update public.orders set status = 'cancelled', cancelled_at = now()
   where id = v_order.id returning * into v_order;
  return v_order;
end $$;

-- ---- inventory: manual adjustment with reason (manager+) --------------
create or replace function public.adjust_stock(p_product_id uuid, p_delta integer, p_reason text)
returns public.products language plpgsql security definer set search_path = '' as $$
declare v_shop uuid := private.my_shop_id(); v_prod public.products;
begin
  if not private.is_manager() then raise exception 'Only managers can adjust stock' using errcode = '42501'; end if;
  if p_delta is null or p_delta = 0 then raise exception 'Adjustment can''t be zero'; end if;
  select * into v_prod from public.products where id = p_product_id and shop_id = v_shop for update;
  if not found then raise exception 'Product not found'; end if;
  if v_prod.stock + p_delta < 0 then
    raise exception 'Stock can''t go below zero (current: %)', v_prod.stock;
  end if;

  insert into public.stock_movements (shop_id, product_id, delta, reason, ref_type, created_by)
  values (v_shop, v_prod.id, p_delta, coalesce(nullif(trim(p_reason), ''), 'Stock adjustment'), 'manual', (select auth.uid()));

  select * into v_prod from public.products where id = p_product_id;
  return v_prod;
end $$;

-- ---- purchases (manager+) ---------------------------------------------
-- p_items = [{"product_id":"<uuid>","qty":30,"unit_cost":8.20}, ...]
create or replace function public.create_purchase_order(p_supplier_id uuid, p_items jsonb, p_notes text default null)
returns public.purchase_orders language plpgsql security definer set search_path = '' as $$
declare
  v_shop uuid := private.my_shop_id(); v_po public.purchase_orders; v_sup text;
  v_total numeric(12,2); v_line record; v_name text;
begin
  if not private.is_manager() then raise exception 'Only managers can create purchases' using errcode = '42501'; end if;
  select s.name into v_sup from public.suppliers s where s.id = p_supplier_id and s.shop_id = v_shop;
  if not found then raise exception 'Supplier not found'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'A purchase needs at least one item';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
             where (e->>'product_id') is null
                or coalesce((e->>'qty')::integer, 0) <= 0
                or coalesce((e->>'unit_cost')::numeric, -1) < 0) then
    raise exception 'Every line needs a product, a quantity of 1 or more and a valid cost';
  end if;

  select coalesce(sum(round((e->>'qty')::integer * (e->>'unit_cost')::numeric, 2)), 0)
    into v_total from jsonb_array_elements(p_items) e;

  insert into public.purchase_orders (shop_id, number, supplier_id, supplier_name, total, notes, created_by)
  values (v_shop, private.fmt_number('PO', private.next_counter(v_shop, 'po')),
          p_supplier_id, v_sup, v_total, nullif(trim(p_notes), ''), (select auth.uid()))
  returning * into v_po;

  for v_line in
    select (e->>'product_id')::uuid as product_id, (e->>'qty')::integer as qty,
           (e->>'unit_cost')::numeric as unit_cost
    from jsonb_array_elements(p_items) e
  loop
    select p.name into v_name from public.products p where p.id = v_line.product_id and p.shop_id = v_shop;
    if not found then raise exception 'Product not found'; end if;
    insert into public.purchase_order_items (shop_id, purchase_order_id, product_id, product_name, qty, unit_cost)
    values (v_shop, v_po.id, v_line.product_id, v_name, v_line.qty, v_line.unit_cost);
  end loop;
  return v_po;
end $$;

create or replace function public.receive_purchase_order(p_po_id uuid)
returns public.purchase_orders language plpgsql security definer set search_path = '' as $$
declare v_shop uuid := private.my_shop_id(); v_po public.purchase_orders; v_item record;
begin
  if not private.is_manager() then raise exception 'Only managers can receive goods' using errcode = '42501'; end if;
  select * into v_po from public.purchase_orders where id = p_po_id and shop_id = v_shop for update;
  if not found then raise exception 'Purchase not found'; end if;
  if v_po.status <> 'ordered' then raise exception 'Only ordered purchases can be received'; end if;

  for v_item in select product_id, qty from public.purchase_order_items
                 where purchase_order_id = v_po.id order by product_id loop
    insert into public.stock_movements (shop_id, product_id, delta, reason, ref_type, ref_id, created_by)
    values (v_shop, v_item.product_id, v_item.qty, 'Received ' || v_po.number, 'purchase', v_po.id, (select auth.uid()));
  end loop;

  update public.purchase_orders set status = 'received', received_at = now()
   where id = v_po.id returning * into v_po;
  return v_po;
end $$;

create or replace function public.cancel_purchase_order(p_po_id uuid)
returns public.purchase_orders language plpgsql security definer set search_path = '' as $$
declare v_po public.purchase_orders;
begin
  if not private.is_manager() then raise exception 'Only managers can cancel purchases' using errcode = '42501'; end if;
  update public.purchase_orders set status = 'cancelled', cancelled_at = now()
   where id = p_po_id and shop_id = private.my_shop_id() and status = 'ordered'
   returning * into v_po;
  if not found then raise exception 'Purchase not found or not in "ordered" status'; end if;
  return v_po;
end $$;

-- =====================================================================
-- 9. DASHBOARD + REPORT FUNCTIONS (security invoker => RLS applies)
-- =====================================================================
-- "Sales" = orders that are not cancelled. Dates use the shop's timezone.

create or replace function public.dashboard_stats()
returns table (today_sales numeric, month_sales numeric, pending_orders bigint, low_stock_products bigint)
language sql stable set search_path = '' as $$
  with s as (select id, timezone from public.shops where id = (select private.my_shop_id()))
  select
    coalesce((select sum(o.total) from public.orders o join s on s.id = o.shop_id
               where o.status <> 'cancelled'
                 and (o.created_at at time zone s.timezone)::date = (now() at time zone s.timezone)::date), 0),
    coalesce((select sum(o.total) from public.orders o join s on s.id = o.shop_id
               where o.status <> 'cancelled'
                 and date_trunc('month', o.created_at at time zone s.timezone)
                     = date_trunc('month', now() at time zone s.timezone)), 0),
    (select count(*) from public.orders o join s on s.id = o.shop_id where o.status = 'pending'),
    (select count(*) from public.products p join s on s.id = p.shop_id
      where p.active and p.stock <= p.reorder_level)
$$;

create or replace function public.sales_by_day(p_from date, p_to date)
returns table (day date, revenue numeric, orders_count bigint)
language sql stable set search_path = '' as $$
  with s as (select id, timezone from public.shops where id = (select private.my_shop_id())),
  days as (select generate_series(p_from, p_to, interval '1 day')::date as d)
  select d.d, coalesce(sum(o.total), 0), count(o.id)
  from days d
  cross join s
  left join public.orders o
         on o.shop_id = s.id and o.status <> 'cancelled'
        and (o.created_at at time zone s.timezone)::date = d.d
  group by d.d
  order by d.d
$$;

create or replace function public.report_summary(p_from date, p_to date)
returns table (revenue numeric, orders_count bigint, units_sold bigint,
               gross_profit numeric, expenses_total numeric, net_profit numeric)
language sql stable set search_path = '' as $$
  with s as (select timezone from public.shops where id = (select private.my_shop_id())),
  o as (
    select ord.id, ord.total from public.orders ord cross join s
    where ord.status <> 'cancelled'
      and (ord.created_at at time zone s.timezone)::date between p_from and p_to
  ),
  li as (
    select coalesce(sum(oi.qty), 0)::bigint as units,
           coalesce(sum(oi.line_total - oi.qty * oi.unit_cost), 0) as profit
    from public.order_items oi join o on o.id = oi.order_id
  ),
  ex as (select coalesce(sum(e.amount), 0) as spent from public.expenses e where e.spent_on between p_from and p_to)
  select (select coalesce(sum(o.total), 0) from o), (select count(*) from o),
         li.units, li.profit, ex.spent, li.profit - ex.spent
  from li, ex
$$;

create or replace function public.product_sales(p_from date, p_to date)
returns table (product_id uuid, sku text, name text, category text,
               units_sold bigint, revenue numeric, gross_profit numeric, stock integer)
language sql stable set search_path = '' as $$
  with s as (select timezone from public.shops where id = (select private.my_shop_id())),
  x as (
    select oi.product_id, oi.qty, oi.line_total, oi.unit_cost
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    cross join s
    where o.status <> 'cancelled'
      and (o.created_at at time zone s.timezone)::date between p_from and p_to
  )
  select p.id, p.sku, p.name, p.category,
         coalesce(sum(x.qty), 0)::bigint,
         coalesce(sum(x.line_total), 0),
         coalesce(sum(x.line_total - x.qty * x.unit_cost), 0),
         p.stock
  from public.products p
  left join x on x.product_id = p.id
  group by p.id
  order by 6 desc, p.name
$$;   -- Best sellers = top rows; Slow movers = units_sold = 0 / lowest

create or replace function public.category_sales(p_from date, p_to date)
returns table (category text, units_sold bigint, revenue numeric)
language sql stable set search_path = '' as $$
  select coalesce(nullif(ps.category, ''), 'Uncategorized'), sum(ps.units_sold)::bigint, sum(ps.revenue)
  from public.product_sales(p_from, p_to) ps
  group by 1
  order by 3 desc
$$;

create or replace function public.payment_status_breakdown(p_from date, p_to date)
returns table (payment_status public.payment_status, orders_count bigint, total numeric, paid numeric, balance numeric)
language sql stable set search_path = '' as $$
  with s as (select timezone from public.shops where id = (select private.my_shop_id()))
  select o.payment_status, count(*), sum(o.total), sum(o.paid_amount), sum(o.total - o.paid_amount)
  from public.orders o cross join s
  where o.status <> 'cancelled'
    and (o.created_at at time zone s.timezone)::date between p_from and p_to
  group by o.payment_status
$$;

-- =====================================================================
-- 10. SUMMARY VIEWS (security_invoker => RLS of the caller applies)
-- =====================================================================
create view public.customer_summary with (security_invoker = true) as
select c.id as customer_id, c.shop_id,
       count(o.id) filter (where o.status <> 'cancelled')                         as orders_count,
       coalesce(sum(o.total) filter (where o.status <> 'cancelled'), 0)           as lifetime_spend,
       coalesce(sum(o.total - o.paid_amount) filter (where o.status <> 'cancelled'), 0) as outstanding,
       max(o.created_at)                                                          as last_order_at
from public.customers c
left join public.orders o on o.customer_id = c.id
group by c.id, c.shop_id;

create view public.supplier_summary with (security_invoker = true) as
select s.id as supplier_id, s.shop_id,
       coalesce(sum(po.total) filter (where po.status = 'received'), 0) as total_purchased,
       count(po.id) filter (where po.status = 'ordered')                as open_orders,
       max(po.created_at) filter (where po.status <> 'cancelled')       as last_purchase_at
from public.suppliers s
left join public.purchase_orders po on po.supplier_id = s.id
group by s.id, s.shop_id;

-- =====================================================================
-- 11. STORAGE: shop logo (bucket "shop-logos", path "<shop_id>/logo.png")
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('shop-logos', 'shop-logos', true)
on conflict (id) do nothing;

create policy "shop logos: public read" on storage.objects for select
  using (bucket_id = 'shop-logos');
create policy "shop logos: owner insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'shop-logos'
              and (storage.foldername(name))[1] = (select private.my_shop_id())::text
              and (select private.is_owner()));
create policy "shop logos: owner update" on storage.objects for update to authenticated
  using (bucket_id = 'shop-logos'
         and (storage.foldername(name))[1] = (select private.my_shop_id())::text
         and (select private.is_owner()));
create policy "shop logos: owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'shop-logos'
         and (storage.foldername(name))[1] = (select private.my_shop_id())::text
         and (select private.is_owner()));

-- =====================================================================
-- 12. GRANTS (defence in depth on top of RLS)
-- =====================================================================
revoke all on all tables in schema public from anon, authenticated;

-- read-only for the client (writes happen via RPC / triggers)
grant select on public.orders, public.order_items, public.payments,
                public.purchase_orders, public.purchase_order_items,
                public.stock_movements, public.shop_members to authenticated;

-- settings / account
grant select on public.shops, public.profiles to authenticated;
grant update (name, currency, tax_rate, address, logo_path, low_stock_threshold, timezone)
  on public.shops to authenticated;
grant update (full_name, date_format) on public.profiles to authenticated;

-- team
grant update (role) on public.shop_members to authenticated;
grant delete        on public.shop_members to authenticated;
grant select, delete on public.invitations to authenticated;
grant insert (shop_id, email, full_name, role) on public.invitations to authenticated;

-- editable data (RLS decides who)
grant select, insert, update, delete on public.products, public.customers,
                                         public.suppliers, public.expenses to authenticated;

-- views
grant select on public.customer_summary, public.supplier_summary to authenticated;

-- functions: nobody by default, then open what the app needs
revoke execute on all functions in schema public  from public, anon;
grant  execute on all functions in schema public  to authenticated;
grant  execute on function public.get_invitation(text) to anon;   -- signup page before login

revoke execute on all functions in schema private from public, anon;
grant  execute on all functions in schema private to authenticated;  -- needed by RLS policies

commit;

-- =====================================================================
-- CLIENT CHEAT-SHEET (supabase-js v2)
-- =====================================================================
-- Owner sign-up:
--   supabase.auth.signUp({ email, password, options: { data: { full_name, shop_name } } })
-- Invited sign-up (token = ?invite= from the link; email must match the invite):
--   const { data } = await supabase.rpc('get_invitation', { p_token: token })   // org_name, invitee_email, invitee_role
--   supabase.auth.signUp({ email, password, options: { data: { full_name, invite_token: token } } })
-- Create invite (Settings → Team):
--   const { data } = await supabase.from('invitations')
--        .insert({ shop_id, email, full_name, role }).select('token').single()
--   link = `${location.origin}/signup.html?invite=${data.token}`
-- New order:
--   supabase.rpc('create_order', { p_customer_id, p_items: [{product_id, qty, unit_price}],
--        p_discount_mode: 'percent', p_discount_value: 10, p_tax_rate: 8.5,
--        p_payment: 'partial', p_paid: 50, p_payment_method: 'cash', p_notes })
-- Orders drawer:
--   supabase.from('orders').select('*, customers(name,email,phone), order_items(*), payments(*)')
-- Order actions:   rpc('record_payment', {p_order_id, p_amount, p_method})
--                  rpc('complete_order', {p_order_id})   rpc('cancel_order', {p_order_id})
-- Inventory:       rpc('adjust_stock', {p_product_id, p_delta, p_reason})
--                  from('stock_movements').select('*, products(name,sku), profiles(full_name)')
-- Purchases:       rpc('create_purchase_order', {p_supplier_id, p_items:[{product_id,qty,unit_cost}]})
--                  rpc('receive_purchase_order', {p_po_id})
-- Dashboard:       rpc('dashboard_stats'), rpc('sales_by_day', {p_from:'2026-10-01', p_to:'2026-10-15'})
-- Reports:         rpc('report_summary' | 'product_sales' | 'category_sales' | 'payment_status_breakdown', {p_from, p_to})
-- Customers/suppliers lists with totals: from('customer_summary'), from('supplier_summary')
