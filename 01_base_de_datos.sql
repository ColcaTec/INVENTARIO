-- =====================================================================
--  INVENTARIO · Fase 1 · Base de datos
--  Pegar TODO este texto en Supabase → SQL Editor → New query → Run.
--  Se puede ejecutar más de una vez sin romper nada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Personas que usan la app y su rol
--    El primer usuario que existe queda como dueño y activo.
--    Los demás entran como empleado DESACTIVADO hasta que el dueño
--    los active desde la app (Más → Equipo).
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text,
  role        text not null default 'empleado' check (role in ('dueno','empleado')),
  active      boolean not null default false,
  created_at  timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  es_primero boolean;
begin
  select not exists (select 1 from public.profiles) into es_primero;
  insert into public.profiles (id, email, full_name, role, active)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(new.email, '@', 1)),
    case when es_primero then 'dueno' else 'empleado' end,
    es_primero
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Si ya habías creado usuarios antes de correr este script, se registran ahora.
insert into public.profiles (id, email, full_name, role, active)
select
  u.id,
  u.email,
  split_part(u.email, '@', 1),
  case when rn = 1 and not exists (select 1 from public.profiles where role = 'dueno') then 'dueno' else 'empleado' end,
  (rn = 1 and not exists (select 1 from public.profiles where role = 'dueno'))
from (
  select au.*, row_number() over (order by au.created_at, au.id) as rn
  from auth.users au
  where not exists (select 1 from public.profiles p where p.id = au.id)
) u;

create or replace function public.es_activo()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select p.active from public.profiles p where p.id = auth.uid()), false)
$$;

create or replace function public.es_dueno()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select p.active and p.role = 'dueno' from public.profiles p where p.id = auth.uid()), false)
$$;

-- Nunca dejar el negocio sin un dueño activo.
create or replace function public.proteger_ultimo_dueno()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.role = 'dueno' and old.active
     and (new.role <> 'dueno' or not new.active)
     and not exists (
       select 1 from public.profiles p
       where p.id <> old.id and p.role = 'dueno' and p.active
     )
  then
    raise exception 'Debe quedar al menos un dueño activo';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_proteger_dueno on public.profiles;
create trigger profiles_proteger_dueno
  before update on public.profiles
  for each row execute function public.proteger_ultimo_dueno();

-- ---------------------------------------------------------------------
-- 2. Ubicaciones (estante y almacén)
-- ---------------------------------------------------------------------
create table if not exists public.locations (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique,
  kind  text not null check (kind in ('estante','almacen')),
  sort  int  not null default 0
);

insert into public.locations (name, kind, sort) values
  ('Estante', 'estante', 1),
  ('Almacén', 'almacen', 2)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 3. Productos
-- ---------------------------------------------------------------------
create sequence if not exists public.product_code_seq;

create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  internal_code text not null unique
                default ('P' || lpad(nextval('public.product_code_seq')::text, 5, '0')),
  barcode       text unique,
  name          text not null check (length(trim(name)) > 0),
  brand         text,
  category      text,
  unit          text not null default 'und',
  sale_price    numeric(12,2) not null default 0 check (sale_price >= 0),
  last_cost     numeric(12,4),
  has_expiry    boolean not null default true,
  returnable    boolean not null default false,
  min_stock     numeric(12,3) not null default 0 check (min_stock >= 0),
  active        boolean not null default true,
  created_by    uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  constraint products_barcode_no_vacio check (barcode is null or length(trim(barcode)) > 0)
);

-- ---------------------------------------------------------------------
-- 4. Stock por lote: producto + ubicación + fecha de vencimiento
-- ---------------------------------------------------------------------
create table if not exists public.stock_lots (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products(id),
  location_id  uuid not null references public.locations(id),
  expiry_date  date,
  quantity     numeric(12,3) not null check (quantity >= 0),
  unit_cost    numeric(12,4),
  updated_at   timestamptz not null default now()
);

create unique index if not exists stock_lots_unico
  on public.stock_lots (product_id, location_id, (coalesce(expiry_date, 'infinity'::date)));
create index if not exists stock_lots_producto on public.stock_lots (product_id);

-- ---------------------------------------------------------------------
-- 5. Historial de movimientos (solo se agrega, nunca se edita)
-- ---------------------------------------------------------------------
create table if not exists public.stock_movements (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  user_id      uuid references public.profiles(id) on delete set null default auth.uid(),
  product_id   uuid not null references public.products(id),
  kind         text not null check (kind in ('entrada','salida','merma','traslado','ajuste')),
  location_id  uuid not null references public.locations(id),
  expiry_date  date,
  quantity     numeric(12,3) not null,        -- + entra, - sale
  unit_cost    numeric(12,4),
  reason       text,
  note         text,
  shortfall    numeric(12,3) not null default 0, -- lo que se pidió y no había en el sistema
  batch_id     uuid                            -- une las dos mitades de un traslado
);

create index if not exists stock_movements_fecha on public.stock_movements (created_at desc);
create index if not exists stock_movements_producto on public.stock_movements (product_id, created_at desc);

-- ---------------------------------------------------------------------
-- 6. Funciones: la ÚNICA forma de cambiar el stock
-- ---------------------------------------------------------------------

-- Entrada: llega mercadería
create or replace function public.registrar_entrada(
  p_product   uuid,
  p_location  uuid,
  p_qty       numeric,
  p_expiry    date default null,
  p_unit_cost numeric default null,
  p_note      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prod  public.products%rowtype;
begin
  if not public.es_activo() then
    raise exception 'Tu usuario no tiene acceso' using errcode = '42501';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'La cantidad debe ser mayor que 0';
  end if;
  select * into v_prod from public.products where id = p_product and active;
  if not found then
    raise exception 'El producto no existe o está desactivado';
  end if;
  if not exists (select 1 from public.locations where id = p_location) then
    raise exception 'La ubicación no existe';
  end if;
  if v_prod.has_expiry and p_expiry is null then
    raise exception 'Este producto vence: falta la fecha de vencimiento';
  end if;
  if not v_prod.has_expiry then
    p_expiry := null;
  end if;

  insert into public.stock_lots (product_id, location_id, expiry_date, quantity, unit_cost)
  values (p_product, p_location, p_expiry, p_qty, p_unit_cost)
  on conflict (product_id, location_id, (coalesce(expiry_date, 'infinity'::date)))
  do update set
    quantity   = public.stock_lots.quantity + excluded.quantity,
    unit_cost  = coalesce(excluded.unit_cost, public.stock_lots.unit_cost),
    updated_at = now();

  insert into public.stock_movements (product_id, kind, location_id, expiry_date, quantity, unit_cost, note)
  values (p_product, 'entrada', p_location, p_expiry, p_qty, p_unit_cost, nullif(trim(p_note), ''));

  if p_unit_cost is not null then
    update public.products set last_cost = p_unit_cost where id = p_product;
  end if;

  return jsonb_build_object(
    'ok', true,
    'stock_total', (select coalesce(sum(quantity), 0) from public.stock_lots where product_id = p_product)
  );
end;
$$;

-- Salida o merma: descuenta primero del lote que vence antes (FEFO).
-- Si pides más de lo que el sistema tiene, descuenta lo que hay y deja
-- anotado el faltante en el historial (no bloquea la venta).
create or replace function public.registrar_salida(
  p_product  uuid,
  p_location uuid,
  p_qty      numeric,
  p_kind     text default 'salida',
  p_reason   text default null,
  p_note     text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot   record;
  v_rem   numeric;
  v_take  numeric;
  v_batch uuid := gen_random_uuid();
begin
  if not public.es_activo() then
    raise exception 'Tu usuario no tiene acceso' using errcode = '42501';
  end if;
  if p_kind not in ('salida', 'merma') then
    raise exception 'Tipo de salida no válido';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'La cantidad debe ser mayor que 0';
  end if;
  if not exists (select 1 from public.products where id = p_product and active) then
    raise exception 'El producto no existe o está desactivado';
  end if;
  if not exists (select 1 from public.locations where id = p_location) then
    raise exception 'La ubicación no existe';
  end if;

  v_rem := p_qty;
  for v_lot in
    select id, expiry_date, quantity
    from public.stock_lots
    where product_id = p_product and location_id = p_location and quantity > 0
    order by expiry_date asc nulls last, id
    for update
  loop
    exit when v_rem <= 0;
    v_take := least(v_lot.quantity, v_rem);
    update public.stock_lots
       set quantity = quantity - v_take, updated_at = now()
     where id = v_lot.id;
    insert into public.stock_movements
      (product_id, kind, location_id, expiry_date, quantity, reason, note, batch_id)
    values
      (p_product, p_kind, p_location, v_lot.expiry_date, -v_take, nullif(trim(p_reason), ''), nullif(trim(p_note), ''), v_batch);
    v_rem := v_rem - v_take;
  end loop;

  if v_rem > 0 then
    insert into public.stock_movements
      (product_id, kind, location_id, expiry_date, quantity, shortfall, reason, note, batch_id)
    values
      (p_product, p_kind, p_location, null, 0, v_rem, nullif(trim(p_reason), ''),
       coalesce(nullif(trim(p_note), ''), 'Salida sin stock suficiente en el sistema'), v_batch);
  end if;

  return jsonb_build_object(
    'ok', true,
    'descontado', p_qty - v_rem,
    'faltante', v_rem,
    'stock_total', (select coalesce(sum(quantity), 0) from public.stock_lots where product_id = p_product)
  );
end;
$$;

-- Traslado: mover de una ubicación a otra (ej. reponer el estante desde el almacén)
create or replace function public.trasladar(
  p_product uuid,
  p_from    uuid,
  p_to      uuid,
  p_qty     numeric,
  p_note    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot       record;
  v_rem       numeric;
  v_take      numeric;
  v_batch     uuid := gen_random_uuid();
  v_available numeric;
begin
  if not public.es_activo() then
    raise exception 'Tu usuario no tiene acceso' using errcode = '42501';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'La cantidad debe ser mayor que 0';
  end if;
  if p_from = p_to then
    raise exception 'El origen y el destino deben ser distintos';
  end if;
  if not exists (select 1 from public.products where id = p_product and active) then
    raise exception 'El producto no existe o está desactivado';
  end if;
  if not exists (select 1 from public.locations where id = p_to) then
    raise exception 'La ubicación de destino no existe';
  end if;

  select coalesce(sum(quantity), 0) into v_available
    from public.stock_lots where product_id = p_product and location_id = p_from;
  if v_available < p_qty then
    raise exception 'Solo hay % en el origen según el sistema', trim_scale(v_available)::text;
  end if;

  v_rem := p_qty;
  for v_lot in
    select id, expiry_date, quantity, unit_cost
    from public.stock_lots
    where product_id = p_product and location_id = p_from and quantity > 0
    order by expiry_date asc nulls last, id
    for update
  loop
    exit when v_rem <= 0;
    v_take := least(v_lot.quantity, v_rem);

    update public.stock_lots
       set quantity = quantity - v_take, updated_at = now()
     where id = v_lot.id;

    insert into public.stock_lots (product_id, location_id, expiry_date, quantity, unit_cost)
    values (p_product, p_to, v_lot.expiry_date, v_take, v_lot.unit_cost)
    on conflict (product_id, location_id, (coalesce(expiry_date, 'infinity'::date)))
    do update set quantity = public.stock_lots.quantity + excluded.quantity, updated_at = now();

    insert into public.stock_movements
      (product_id, kind, location_id, expiry_date, quantity, note, batch_id)
    values
      (p_product, 'traslado', p_from, v_lot.expiry_date, -v_take, nullif(trim(p_note), ''), v_batch),
      (p_product, 'traslado', p_to,   v_lot.expiry_date,  v_take, nullif(trim(p_note), ''), v_batch);

    v_rem := v_rem - v_take;
  end loop;

  return jsonb_build_object('ok', true, 'trasladado', p_qty);
end;
$$;

-- Ajuste: corregir una cantidad contada. Solo el dueño y siempre con motivo.
create or replace function public.ajustar_stock(
  p_product  uuid,
  p_location uuid,
  p_expiry   date,
  p_new_qty  numeric,
  p_reason   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old  numeric;
  v_diff numeric;
begin
  if not public.es_dueno() then
    raise exception 'Solo el dueño puede ajustar el stock' using errcode = '42501';
  end if;
  if p_new_qty is null or p_new_qty < 0 then
    raise exception 'La cantidad contada no puede ser negativa';
  end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Escribe el motivo del ajuste';
  end if;
  if not exists (select 1 from public.products where id = p_product) then
    raise exception 'El producto no existe';
  end if;
  if not exists (select 1 from public.locations where id = p_location) then
    raise exception 'La ubicación no existe';
  end if;

  select quantity into v_old
    from public.stock_lots
   where product_id = p_product and location_id = p_location
     and coalesce(expiry_date, 'infinity'::date) = coalesce(p_expiry, 'infinity'::date)
   for update;
  v_old := coalesce(v_old, 0);
  v_diff := p_new_qty - v_old;

  if v_diff = 0 then
    return jsonb_build_object('ok', true, 'diferencia', 0);
  end if;

  insert into public.stock_lots (product_id, location_id, expiry_date, quantity)
  values (p_product, p_location, p_expiry, p_new_qty)
  on conflict (product_id, location_id, (coalesce(expiry_date, 'infinity'::date)))
  do update set quantity = excluded.quantity, updated_at = now();

  insert into public.stock_movements (product_id, kind, location_id, expiry_date, quantity, reason)
  values (p_product, 'ajuste', p_location, p_expiry, v_diff, trim(p_reason));

  return jsonb_build_object('ok', true, 'diferencia', v_diff);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Vista de stock por producto (respeta los permisos de quien consulta)
-- ---------------------------------------------------------------------
create or replace view public.v_stock_producto
with (security_invoker = true) as
select
  p.id as product_id,
  p.internal_code,
  p.barcode,
  p.name,
  p.brand,
  p.category,
  p.unit,
  p.sale_price,
  p.last_cost,
  p.has_expiry,
  p.returnable,
  p.min_stock,
  p.active,
  coalesce(sum(l.quantity), 0)                                          as total,
  coalesce(sum(l.quantity) filter (where loc.kind = 'estante'), 0)      as en_estante,
  coalesce(sum(l.quantity) filter (where loc.kind = 'almacen'), 0)      as en_almacen,
  min(l.expiry_date) filter (where l.quantity > 0)                      as proximo_vencimiento
from public.products p
left join public.stock_lots l on l.product_id = p.id
left join public.locations loc on loc.id = l.location_id
group by p.id;

-- ---------------------------------------------------------------------
-- 8. Permisos: quién puede ver y hacer qué
-- ---------------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.locations       enable row level security;
alter table public.products        enable row level security;
alter table public.stock_lots      enable row level security;
alter table public.stock_movements enable row level security;

-- profiles
-- Cada persona ve su propio perfil; los usuarios activos ven los nombres del equipo
drop policy if exists profiles_ver on public.profiles;
create policy profiles_ver on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.es_activo());

drop policy if exists profiles_editar on public.profiles;
create policy profiles_editar on public.profiles
  for update to authenticated
  using (public.es_dueno())
  with check (public.es_dueno());

-- locations
drop policy if exists locations_ver on public.locations;
create policy locations_ver on public.locations
  for select to authenticated using (public.es_activo());

drop policy if exists locations_crear on public.locations;
create policy locations_crear on public.locations
  for insert to authenticated with check (public.es_dueno());

drop policy if exists locations_editar on public.locations;
create policy locations_editar on public.locations
  for update to authenticated using (public.es_dueno()) with check (public.es_dueno());

-- products: cualquiera activo ve y crea; solo el dueño edita
drop policy if exists products_ver on public.products;
create policy products_ver on public.products
  for select to authenticated using (public.es_activo());

drop policy if exists products_crear on public.products;
create policy products_crear on public.products
  for insert to authenticated
  with check (public.es_activo() and created_by = auth.uid());

drop policy if exists products_editar on public.products;
create policy products_editar on public.products
  for update to authenticated using (public.es_dueno()) with check (public.es_dueno());

-- stock y movimientos: solo lectura directa; se cambian con las funciones
drop policy if exists stock_lots_ver on public.stock_lots;
create policy stock_lots_ver on public.stock_lots
  for select to authenticated using (public.es_activo());

drop policy if exists stock_movements_ver on public.stock_movements;
create policy stock_movements_ver on public.stock_movements
  for select to authenticated using (public.es_activo());

-- Quitar todo permiso por defecto y dar solo lo necesario
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant usage on schema public to authenticated;

grant select on public.locations, public.products,
                public.stock_lots, public.stock_movements, public.v_stock_producto
  to authenticated;
-- De los perfiles se pueden leer el nombre y el rol, pero no el correo
grant select (id, full_name, role, active, created_at) on public.profiles to authenticated;
grant insert on public.products to authenticated;
grant insert, update on public.locations to authenticated;
grant update on public.products to authenticated;
grant update (full_name, role, active) on public.profiles to authenticated;
grant usage on sequence public.product_code_seq to authenticated;

grant execute on function public.es_activo()   to authenticated;
grant execute on function public.es_dueno()    to authenticated;
grant execute on function public.registrar_entrada(uuid, uuid, numeric, date, numeric, text) to authenticated;
grant execute on function public.registrar_salida(uuid, uuid, numeric, text, text, text)    to authenticated;
grant execute on function public.trasladar(uuid, uuid, uuid, numeric, text)                 to authenticated;
grant execute on function public.ajustar_stock(uuid, uuid, date, numeric, text)             to authenticated;

-- Listo.
