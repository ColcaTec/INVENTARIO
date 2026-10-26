-- Recepción de compras, boletas y conteo aleatorio previo a ingresar stock.
-- Ejecutar después de 01_base_de_datos.sql desde Supabase SQL Editor.

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null
);

create table if not exists public.purchase_receipts (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid references public.suppliers(id) on delete set null,
  supplier_name text not null,
  document_number text,
  document_date date,
  image_path text,
  ocr_text text,
  status text not null default 'borrador' check (status in ('borrador','confirmada')),
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  audit_started_at timestamptz,
  confirmed_at timestamptz,
  check (length(trim(supplier_name)) > 0)
);
alter table public.purchase_receipts add column if not exists audit_started_at timestamptz;

create table if not exists public.purchase_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.purchase_receipts(id) on delete cascade,
  product_id uuid not null references public.products(id),
  location_id uuid not null references public.locations(id),
  expected_quantity numeric(12,3) not null default 0 check (expected_quantity >= 0),
  received_quantity numeric(12,3) not null default 0 check (received_quantity >= 0),
  unit_cost numeric(12,4) check (unit_cost is null or unit_cost >= 0),
  expiry_date date,
  reviewed boolean not null default false,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists purchase_receipt_lines_receipt on public.purchase_receipt_lines(receipt_id);

create table if not exists public.purchase_receipt_audits (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.purchase_receipts(id) on delete cascade,
  product_id uuid not null references public.products(id),
  location_id uuid not null references public.locations(id),
  expected_quantity numeric(12,3) not null check (expected_quantity >= 0),
  counted_quantity numeric(12,3) check (counted_quantity is null or counted_quantity >= 0),
  note text,
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(receipt_id, product_id, location_id)
);

alter table public.stock_movements
  add column if not exists receipt_id uuid references public.purchase_receipts(id);

alter table public.suppliers enable row level security;
alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipt_lines enable row level security;
alter table public.purchase_receipt_audits enable row level security;

drop policy if exists suppliers_read on public.suppliers;
create policy suppliers_read on public.suppliers for select to authenticated using (public.es_activo());
drop policy if exists suppliers_insert on public.suppliers;
create policy suppliers_insert on public.suppliers for insert to authenticated with check (public.es_activo());
drop policy if exists suppliers_update on public.suppliers;
create policy suppliers_update on public.suppliers for update to authenticated using (public.es_activo()) with check (public.es_activo());

drop policy if exists receipts_read on public.purchase_receipts;
create policy receipts_read on public.purchase_receipts for select to authenticated using (public.es_activo());
drop policy if exists receipts_insert on public.purchase_receipts;
create policy receipts_insert on public.purchase_receipts for insert to authenticated with check (public.es_activo() and created_by = auth.uid());
drop policy if exists receipts_update on public.purchase_receipts;
create policy receipts_update on public.purchase_receipts for update to authenticated using (public.es_activo() and status = 'borrador' and created_by = auth.uid()) with check (public.es_activo() and status = 'borrador' and created_by = auth.uid());

drop policy if exists receipt_lines_read on public.purchase_receipt_lines;
create policy receipt_lines_read on public.purchase_receipt_lines for select to authenticated using (public.es_activo());
drop policy if exists receipt_lines_insert on public.purchase_receipt_lines;
create policy receipt_lines_insert on public.purchase_receipt_lines for insert to authenticated with check (public.es_activo() and not exists (select 1 from public.purchase_receipt_audits a where a.receipt_id = purchase_receipt_lines.receipt_id) and exists (select 1 from public.purchase_receipts r where r.id = purchase_receipt_lines.receipt_id and r.status = 'borrador' and r.audit_started_at is null and r.created_by = auth.uid()));
drop policy if exists receipt_lines_update on public.purchase_receipt_lines;
create policy receipt_lines_update on public.purchase_receipt_lines for update to authenticated using (public.es_activo() and not exists (select 1 from public.purchase_receipt_audits a where a.receipt_id = purchase_receipt_lines.receipt_id) and exists (select 1 from public.purchase_receipts r where r.id = purchase_receipt_lines.receipt_id and r.status = 'borrador' and r.audit_started_at is null and r.created_by = auth.uid())) with check (public.es_activo() and not exists (select 1 from public.purchase_receipt_audits a where a.receipt_id = purchase_receipt_lines.receipt_id) and exists (select 1 from public.purchase_receipts r where r.id = purchase_receipt_lines.receipt_id and r.status = 'borrador' and r.audit_started_at is null and r.created_by = auth.uid()));
drop policy if exists receipt_lines_delete on public.purchase_receipt_lines;
create policy receipt_lines_delete on public.purchase_receipt_lines for delete to authenticated using (public.es_activo() and not exists (select 1 from public.purchase_receipt_audits a where a.receipt_id = purchase_receipt_lines.receipt_id) and exists (select 1 from public.purchase_receipts r where r.id = purchase_receipt_lines.receipt_id and r.status = 'borrador' and r.audit_started_at is null and r.created_by = auth.uid()));

drop policy if exists receipt_audits_read on public.purchase_receipt_audits;
create policy receipt_audits_read on public.purchase_receipt_audits for select to authenticated using (public.es_activo());
drop policy if exists receipt_audits_insert on public.purchase_receipt_audits;
create policy receipt_audits_insert on public.purchase_receipt_audits for insert to authenticated with check (public.es_activo() and created_by = auth.uid() and exists (select 1 from public.purchase_receipts r where r.id = receipt_id and r.status = 'borrador' and r.created_by = auth.uid()));
drop policy if exists receipt_audits_update on public.purchase_receipt_audits;
create policy receipt_audits_update on public.purchase_receipt_audits for update to authenticated using (public.es_activo() and exists (select 1 from public.purchase_receipts r where r.id = receipt_id and r.status = 'borrador' and r.created_by = auth.uid())) with check (public.es_activo() and exists (select 1 from public.purchase_receipts r where r.id = receipt_id and r.status = 'borrador' and r.created_by = auth.uid()));

revoke all on public.suppliers, public.purchase_receipts, public.purchase_receipt_lines, public.purchase_receipt_audits from anon, authenticated;
grant select, insert, update on public.suppliers to authenticated;
grant select, insert on public.purchase_receipts to authenticated;
grant update (image_path) on public.purchase_receipts to authenticated;
grant select, insert, update, delete on public.purchase_receipt_lines to authenticated;
grant select on public.purchase_receipt_audits to authenticated;
grant update (counted_quantity, note) on public.purchase_receipt_audits to authenticated;

-- Bucket privado. Las imágenes no se publican como URLs accesibles sin sesión.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('recepcion-boletas', 'recepcion-boletas', false, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists receipt_images_read on storage.objects;
create policy receipt_images_read on storage.objects for select to authenticated using (bucket_id = 'recepcion-boletas' and public.es_activo());
drop policy if exists receipt_images_insert on storage.objects;
create policy receipt_images_insert on storage.objects for insert to authenticated with check (bucket_id = 'recepcion-boletas' and public.es_activo() and (storage.foldername(name))[1] = auth.uid()::text);

create or replace function public.iniciar_control_recepcion(p_receipt uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_take integer;
  v_existing integer;
  v_started timestamptz;
  v_result jsonb;
begin
  if not public.es_activo() then raise exception 'Tu usuario no tiene acceso' using errcode = '42501'; end if;
  if not exists (select 1 from public.purchase_receipts where id = p_receipt and status = 'borrador' and created_by = auth.uid()) then
    raise exception 'La recepción no existe o ya fue confirmada';
  end if;
  if not exists (select 1 from public.purchase_receipt_lines where receipt_id = p_receipt) then raise exception 'Agrega y revisa productos antes del conteo aleatorio'; end if;
  if exists (select 1 from public.purchase_receipt_lines where receipt_id = p_receipt and not reviewed) then raise exception 'Revisa todas las líneas antes del conteo aleatorio'; end if;
  select audit_started_at into v_started from public.purchase_receipts where id = p_receipt;
  update public.purchase_receipts set audit_started_at = coalesce(audit_started_at, now()) where id = p_receipt;
  select count(*) into v_existing from public.purchase_receipt_audits where receipt_id = p_receipt;
  if v_existing = 0 and v_started is null then
    select count(*) into v_count from public.v_stock_producto p
    where p.total > 0 and not exists (select 1 from public.purchase_receipt_lines l where l.receipt_id = p_receipt and l.product_id = p.product_id);
    if v_count > 0 then
      v_take := least(v_count, 1 + floor(random() * least(3, v_count))::integer);
      insert into public.purchase_receipt_audits (receipt_id, product_id, location_id, expected_quantity)
      select p_receipt, sample.product_id, loc.id, coalesce(sum(sl.quantity), 0)
      from (
        select p.product_id from public.v_stock_producto p
        where p.total > 0 and not exists (select 1 from public.purchase_receipt_lines l where l.receipt_id = p_receipt and l.product_id = p.product_id)
        order by random() limit v_take
      ) sample
      cross join public.locations loc
      left join public.stock_lots sl on sl.product_id = sample.product_id and sl.location_id = loc.id
      group by sample.product_id, loc.id;
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'product_id', a.product_id, 'product_name', p.name, 'unit', p.unit, 'location_id', a.location_id, 'location_name', loc.name, 'expected_quantity', a.expected_quantity, 'counted_quantity', a.counted_quantity, 'note', a.note) order by p.name, loc.sort), '[]'::jsonb)
  into v_result
  from public.purchase_receipt_audits a join public.products p on p.id = a.product_id join public.locations loc on loc.id = a.location_id
  where a.receipt_id = p_receipt;
  return v_result;
end;
$$;

create or replace function public.confirmar_recepcion(p_receipt uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_receipt public.purchase_receipts%rowtype;
  v_line public.purchase_receipt_lines%rowtype;
  v_product public.products%rowtype;
  v_total integer;
begin
  if not public.es_activo() then raise exception 'Tu usuario no tiene acceso' using errcode = '42501'; end if;
  select * into v_receipt from public.purchase_receipts where id = p_receipt and created_by = auth.uid() for update;
  if not found or v_receipt.status <> 'borrador' then raise exception 'La recepción no existe o ya fue confirmada'; end if;
  if not exists (select 1 from public.purchase_receipt_lines where receipt_id = p_receipt) then raise exception 'Agrega al menos un producto'; end if;
  if v_receipt.audit_started_at is null then raise exception 'Inicia y completa el conteo aleatorio antes de confirmar'; end if;
  if exists (select 1 from public.purchase_receipt_lines where receipt_id = p_receipt and not reviewed) then raise exception 'Revisa todas las líneas antes de confirmar'; end if;
  if exists (select 1 from public.purchase_receipt_lines where receipt_id = p_receipt and received_quantity <> expected_quantity and length(trim(coalesce(note,''))) < 3) then raise exception 'Explica las diferencias entre la boleta y lo recibido'; end if;
  if exists (select 1 from public.purchase_receipt_audits where receipt_id = p_receipt and counted_quantity is null) then raise exception 'Completa el conteo aleatorio antes de confirmar'; end if;
  if exists (select 1 from public.purchase_receipt_audits where receipt_id = p_receipt and counted_quantity <> expected_quantity and length(trim(coalesce(note,''))) < 3) then raise exception 'Explica las diferencias del conteo aleatorio'; end if;
  perform 1 from public.purchase_receipt_lines where receipt_id = p_receipt for update;
  for v_line in select * from public.purchase_receipt_lines where receipt_id = p_receipt and received_quantity > 0 loop
    select * into v_product from public.products where id = v_line.product_id and active;
    if not found then raise exception 'Uno de los productos ya no está activo'; end if;
    if v_product.has_expiry and v_line.expiry_date is null then raise exception 'Falta un vencimiento para %', v_product.name; end if;
    if not exists (select 1 from public.locations where id = v_line.location_id) then raise exception 'Una ubicación no existe'; end if;
    insert into public.stock_lots (product_id, location_id, expiry_date, quantity, unit_cost)
    values (v_line.product_id, v_line.location_id, case when v_product.has_expiry then v_line.expiry_date else null end, v_line.received_quantity, v_line.unit_cost)
    on conflict (product_id, location_id, (coalesce(expiry_date, 'infinity'::date)))
    do update set quantity = public.stock_lots.quantity + excluded.quantity, unit_cost = coalesce(excluded.unit_cost, public.stock_lots.unit_cost), updated_at = now();
    insert into public.stock_movements (product_id, kind, location_id, expiry_date, quantity, unit_cost, note, receipt_id)
    values (v_line.product_id, 'entrada', v_line.location_id, case when v_product.has_expiry then v_line.expiry_date else null end, v_line.received_quantity, v_line.unit_cost, 'Recepción ' || coalesce(v_receipt.document_number, left(p_receipt::text,8)), p_receipt);
    if v_line.unit_cost is not null then update public.products set last_cost = v_line.unit_cost where id = v_line.product_id; end if;
  end loop;
  update public.purchase_receipts set status = 'confirmada', confirmed_at = now() where id = p_receipt;
  select count(*) into v_total from public.purchase_receipt_lines where receipt_id = p_receipt;
  return jsonb_build_object('ok', true, 'lineas', v_total);
end;
$$;

revoke all on function public.iniciar_control_recepcion(uuid) from public, anon, authenticated;
revoke all on function public.confirmar_recepcion(uuid) from public, anon, authenticated;
grant execute on function public.iniciar_control_recepcion(uuid) to authenticated;
grant execute on function public.confirmar_recepcion(uuid) to authenticated;

