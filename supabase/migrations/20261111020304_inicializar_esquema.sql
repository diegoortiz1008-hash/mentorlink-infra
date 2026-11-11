-- =============================================================================
-- MentorLink · Migración: inicializar_esquema
-- Creada con: supabase migration new inicializar_esquema
-- Contenido: tipos, tablas (perfiles, sesiones, mensajes), índices, triggers
--            y políticas RLS.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. TIPOS ENUMERADOS
-- -----------------------------------------------------------------------------
create type public.rol_usuario as enum ('mentor', 'estudiante');

create type public.estado_sesion as enum ('pendiente', 'confirmada', 'completada', 'cancelada');

-- -----------------------------------------------------------------------------
-- 2. TABLAS
-- -----------------------------------------------------------------------------

-- perfiles: 1 a 1 con auth.users (Supabase Auth gestiona email/contraseña/OAuth)
create table public.perfiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  nombre      text not null check (char_length(trim(nombre)) between 2 and 100),
  bio         text check (char_length(bio) <= 1000),
  rol         public.rol_usuario not null default 'estudiante',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.perfiles is 'Datos públicos de cada usuario. id = auth.users.id';

-- sesiones: una mentoría agendada entre un mentor y un estudiante
create table public.sesiones (
  id             uuid primary key default gen_random_uuid(),
  mentor_id      uuid not null references public.perfiles (id) on delete cascade,
  estudiante_id  uuid not null references public.perfiles (id) on delete cascade,
  fecha          timestamptz not null,
  estado         public.estado_sesion not null default 'pendiente',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint sesiones_participantes_distintos check (mentor_id <> estudiante_id),
  -- un mentor no puede tener dos sesiones a la misma hora
  constraint sesiones_mentor_fecha_unica unique (mentor_id, fecha)
);

comment on table public.sesiones is 'Mentorías entre un mentor y un estudiante';

-- mensajes: chat dentro de una sesión (inmutables: no se editan ni borran)
create table public.mensajes (
  id            uuid primary key default gen_random_uuid(),
  sesion_id     uuid not null references public.sesiones (id) on delete cascade,
  remitente_id  uuid not null references public.perfiles (id) on delete cascade,
  contenido     text not null check (char_length(trim(contenido)) between 1 and 2000),
  created_at    timestamptz not null default now()
);

comment on table public.mensajes is 'Mensajes del chat de cada sesión';

-- -----------------------------------------------------------------------------
-- 3. ÍNDICES (FKs y columnas usadas por las políticas RLS)
-- -----------------------------------------------------------------------------
create index sesiones_mentor_id_idx     on public.sesiones (mentor_id);
create index sesiones_estudiante_id_idx on public.sesiones (estudiante_id);
create index sesiones_fecha_idx         on public.sesiones (fecha);
create index mensajes_sesion_id_idx     on public.mensajes (sesion_id, created_at);
create index mensajes_remitente_id_idx  on public.mensajes (remitente_id);

-- -----------------------------------------------------------------------------
-- 4. FUNCIONES Y TRIGGERS
-- -----------------------------------------------------------------------------

-- 4.1 Mantener updated_at
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger perfiles_set_updated_at
  before update on public.perfiles
  for each row execute function public.set_updated_at();

create trigger sesiones_set_updated_at
  before update on public.sesiones
  for each row execute function public.set_updated_at();

-- 4.2 Crear el perfil automáticamente al registrarse (email o Google).
--     Google envía "full_name"/"name" en raw_user_meta_data; el registro por
--     email puede enviar "nombre" en options.data. Nunca se acepta el rol
--     desde el cliente: siempre empieza como 'estudiante'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.perfiles (id, nombre)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'nombre'), ''),
      nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
      split_part(new.email, '@', 1)
    )
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 4.3 Validar que mentor_id sea mentor y estudiante_id sea estudiante
create or replace function public.validar_roles_sesion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.perfiles where id = new.mentor_id and rol = 'mentor') then
    raise exception 'mentor_id (%) no corresponde a un perfil con rol mentor', new.mentor_id;
  end if;
  if not exists (select 1 from public.perfiles where id = new.estudiante_id and rol = 'estudiante') then
    raise exception 'estudiante_id (%) no corresponde a un perfil con rol estudiante', new.estudiante_id;
  end if;
  return new;
end;
$$;

create trigger sesiones_validar_roles
  before insert or update of mentor_id, estudiante_id on public.sesiones
  for each row execute function public.validar_roles_sesion();

-- 4.4 Función auxiliar para RLS: ¿el usuario actual participa en la sesión?
--     SECURITY DEFINER evita evaluar RLS anidado y mejora el rendimiento.
create or replace function public.es_participante(p_sesion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.sesiones s
    where s.id = p_sesion_id
      and (select auth.uid()) in (s.mentor_id, s.estudiante_id)
  );
$$;

-- Las funciones de trigger no deben poder llamarse vía API (/rest/v1/rpc)
revoke execute on function public.handle_new_user()      from public, anon, authenticated;
revoke execute on function public.validar_roles_sesion() from public, anon, authenticated;
revoke execute on function public.es_participante(uuid)  from public, anon;
grant  execute on function public.es_participante(uuid)  to authenticated;

-- -----------------------------------------------------------------------------
-- 5. PRIVILEGIOS (defensa en profundidad, además de RLS)
-- -----------------------------------------------------------------------------
-- anon (sin sesión) no accede a nada
revoke all on public.perfiles, public.sesiones, public.mensajes from anon;

-- perfiles: solo se pueden editar nombre y bio (el rol NO, evita escalar privilegios)
revoke insert, update, delete on public.perfiles from authenticated;
grant  select on public.perfiles to authenticated;
grant  update (nombre, bio) on public.perfiles to authenticated;

-- sesiones: se crean y se actualizan fecha/estado; no se borran (se cancelan)
revoke update, delete on public.sesiones from authenticated;
grant  select, insert on public.sesiones to authenticated;
grant  update (fecha, estado) on public.sesiones to authenticated;

-- mensajes: solo lectura e inserción (historial inmutable)
revoke update, delete on public.mensajes from authenticated;
grant  select, insert on public.mensajes to authenticated;

-- -----------------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
--    Patrón (select auth.uid()) => Postgres lo evalúa una sola vez por consulta.
-- -----------------------------------------------------------------------------
alter table public.perfiles enable row level security;
alter table public.sesiones enable row level security;
alter table public.mensajes enable row level security;

-- ---------- perfiles ----------
-- Cualquier usuario autenticado puede ver perfiles (necesario para buscar mentores).
create policy "perfiles: autenticados pueden ver perfiles"
  on public.perfiles for select
  to authenticated
  using (true);

-- Cada usuario solo puede editar su propio perfil.
create policy "perfiles: el usuario edita su propio perfil"
  on public.perfiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- ---------- sesiones ----------
-- Solo los participantes (mentor o estudiante) ven la sesión.
create policy "sesiones: participantes pueden ver sus sesiones"
  on public.sesiones for select
  to authenticated
  using ((select auth.uid()) in (mentor_id, estudiante_id));

-- Un estudiante solo puede solicitar sesiones para sí mismo y en estado pendiente.
create policy "sesiones: el estudiante solicita su propia sesion"
  on public.sesiones for insert
  to authenticated
  with check (
    (select auth.uid()) = estudiante_id
    and estado = 'pendiente'
  );

-- Solo los participantes pueden modificar (reprogramar, confirmar, cancelar).
create policy "sesiones: participantes actualizan sus sesiones"
  on public.sesiones for update
  to authenticated
  using ((select auth.uid()) in (mentor_id, estudiante_id))
  with check ((select auth.uid()) in (mentor_id, estudiante_id));

-- ---------- mensajes ----------
-- Solo los participantes de la sesión leen sus mensajes.
create policy "mensajes: participantes leen los mensajes de su sesion"
  on public.mensajes for select
  to authenticated
  using (public.es_participante(sesion_id));

-- Solo se envía en nombre propio y dentro de una sesión en la que se participa.
create policy "mensajes: participantes envian mensajes en su sesion"
  on public.mensajes for insert
  to authenticated
  with check (
    (select auth.uid()) = remitente_id
    and public.es_participante(sesion_id)
  );
