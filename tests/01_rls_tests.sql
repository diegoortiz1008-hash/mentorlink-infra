-- Pruebas de la migración y de las políticas RLS.
-- Cada bloque imprime "OK ..." o aborta con "FALLO ...".
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- Usuarios de prueba (el trigger crea sus perfiles)
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'mentora@test.com',  '{"full_name": "Ana Mentora"}'),   -- vía Google
  ('22222222-2222-2222-2222-222222222222', 'estu1@test.com',    '{"nombre": "Luis Estudiante"}'), -- vía email
  ('33333333-3333-3333-3333-333333333333', 'estu2@test.com',    '{}');                            -- sin nombre

update public.perfiles set rol = 'mentor' where id = '11111111-1111-1111-1111-111111111111';

-- Ayudante: actuar como un usuario autenticado
create function pg_temp.como(uid text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', uid, false);
$$;

do $$ begin
  assert (select count(*) from public.perfiles) = 3, 'FALLO: trigger no creó perfiles';
  assert (select nombre from public.perfiles where id = '11111111-1111-1111-1111-111111111111') = 'Ana Mentora';
  assert (select nombre from public.perfiles where id = '33333333-3333-3333-3333-333333333333') = 'estu2';
  raise notice 'OK 1  trigger handle_new_user crea perfiles (Google, email y fallback)';
end $$;

-- ===================== Como ESTUDIANTE 1 =====================
do $$ begin perform pg_temp.como('22222222-2222-2222-2222-222222222222'); end $$;
set role authenticated;

insert into public.sesiones (id, mentor_id, estudiante_id, fecha)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '2026-12-01 15:00+00');
do $$ begin raise notice 'OK 2  estudiante solicita su propia sesion'; end $$;

do $$ begin
  begin
    insert into public.sesiones (mentor_id, estudiante_id, fecha)
    values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '2026-12-02 15:00+00');
    raise exception 'FALLO: creó sesión a nombre de otro estudiante';
  exception when insufficient_privilege then
    raise notice 'OK 3  RLS impide crear sesiones a nombre de otro';
  end;
end $$;

do $$ begin
  begin
    insert into public.sesiones (mentor_id, estudiante_id, fecha, estado)
    values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '2026-12-03 15:00+00', 'confirmada');
    raise exception 'FALLO: creó sesión ya confirmada';
  exception when insufficient_privilege then
    raise notice 'OK 4  una sesion nueva debe nacer en estado pendiente';
  end;
end $$;

insert into public.mensajes (sesion_id, remitente_id, contenido)
values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Hola, quiero repasar SQL');

do $$ begin
  begin
    insert into public.mensajes (sesion_id, remitente_id, contenido)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Suplantando a la mentora');
    raise exception 'FALLO: envió mensaje suplantando a otro';
  exception when insufficient_privilege then
    raise notice 'OK 5  no se puede enviar mensajes en nombre de otro';
  end;
end $$;

do $$ begin
  begin
    update public.perfiles set rol = 'mentor' where id = '22222222-2222-2222-2222-222222222222';
    raise exception 'FALLO: estudiante se cambió el rol';
  exception when insufficient_privilege then
    raise notice 'OK 6  un usuario no puede cambiar su propio rol';
  end;
end $$;

update public.perfiles set bio = 'Me interesa backend' where id = '22222222-2222-2222-2222-222222222222';
do $$
declare n int;
begin
  update public.perfiles set bio = 'hackeado' where id = '11111111-1111-1111-1111-111111111111';
  get diagnostics n = row_count;
  assert n = 0, 'FALLO: editó el perfil de otro';
  raise notice 'OK 7  edita su bio, pero no la de otros (0 filas afectadas)';
end $$;

do $$ begin
  begin
    delete from public.mensajes;
    raise exception 'FALLO: pudo borrar mensajes';
  exception when insufficient_privilege then
    raise notice 'OK 8  los mensajes son inmutables (sin DELETE)';
  end;
end $$;

reset role;

-- ===================== Como ESTUDIANTE 2 (ajeno a la sesión) =====================
do $$ begin perform pg_temp.como('33333333-3333-3333-3333-333333333333'); end $$;
set role authenticated;

do $$ begin
  assert (select count(*) from public.sesiones) = 0, 'FALLO: ve sesiones ajenas';
  assert (select count(*) from public.mensajes) = 0, 'FALLO: ve mensajes ajenos';
  assert (select count(*) from public.perfiles) = 3, 'FALLO: no ve el directorio de perfiles';
  raise notice 'OK 9  un tercero NO ve sesiones ni mensajes ajenos (si ve perfiles)';
end $$;

do $$ begin
  begin
    insert into public.mensajes (sesion_id, remitente_id, contenido)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Me cuelo');
    raise exception 'FALLO: escribió en sesión ajena';
  exception when insufficient_privilege then
    raise notice 'OK 10 no puede escribir en sesiones donde no participa';
  end;
end $$;

do $$
declare n int;
begin
  update public.sesiones set estado = 'cancelada';
  get diagnostics n = row_count;
  assert n = 0, 'FALLO: canceló sesión ajena';
  raise notice 'OK 11 no puede modificar sesiones ajenas';
end $$;

do $$ begin
  begin
    insert into public.sesiones (mentor_id, estudiante_id, fecha)
    values ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', '2026-12-05 10:00+00');
    raise exception 'FALLO: aceptó un estudiante como mentor';
  exception when raise_exception then
    if sqlerrm like 'FALLO%' then raise; end if;
    raise notice 'OK 12 trigger valida que mentor_id tenga rol mentor';
  end;
end $$;

reset role;

-- ===================== Como MENTORA =====================
do $$ begin perform pg_temp.como('11111111-1111-1111-1111-111111111111'); end $$;
set role authenticated;

do $$ begin
  assert (select count(*) from public.sesiones) = 1, 'FALLO: mentora no ve su sesión';
  assert (select count(*) from public.mensajes) = 1, 'FALLO: mentora no ve mensajes';
  raise notice 'OK 13 la mentora ve su sesion y sus mensajes';
end $$;

update public.sesiones set estado = 'confirmada' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into public.mensajes (sesion_id, remitente_id, contenido)
values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Confirmado, nos vemos!');
do $$ begin raise notice 'OK 14 la mentora confirma la sesion y responde'; end $$;

reset role;

-- ===================== Como ANÓNIMO (sin sesión) =====================
do $$ begin perform pg_temp.como(''); end $$;
set role anon;
do $$ begin
  begin
    perform 1 from public.perfiles;
    raise exception 'FALLO: anon leyó perfiles';
  exception when insufficient_privilege then
    raise notice 'OK 15 usuarios anonimos no acceden a ninguna tabla';
  end;
end $$;
reset role;

-- ===================== Restricciones (CHECK / UNIQUE) =====================
do $$ begin
  begin
    insert into public.sesiones (mentor_id, estudiante_id, fecha)
    values ('11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', '2026-12-09 10:00+00');
    raise exception 'FALLO: sesión consigo mismo';
  exception when check_violation or raise_exception then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
  begin
    insert into public.sesiones (mentor_id, estudiante_id, fecha)
    values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '2026-12-01 15:00+00');
    raise exception 'FALLO: mentor con dos sesiones a la misma hora';
  exception when unique_violation then null;
  end;
  begin
    insert into public.mensajes (sesion_id, remitente_id, contenido)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '   ');
    raise exception 'FALLO: mensaje vacío';
  exception when check_violation then null;
  end;
  raise notice 'OK 16 CHECK y UNIQUE: sin auto-sesiones, sin choque de horario, sin mensajes vacios';
end $$;

do $$ begin raise notice '=== TODAS LAS PRUEBAS PASARON ==='; end $$;
