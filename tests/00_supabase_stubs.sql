-- Simulación mínima del entorno de Supabase para probar la migración en un
-- PostgreSQL "puro" (sin Docker). En Supabase real esto ya existe.
create role anon nologin;
create role authenticated nologin;

create schema auth;
grant usage on schema auth to anon, authenticated;

create table auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text unique,
  raw_user_meta_data  jsonb not null default '{}'::jsonb
);

-- Igual que en Supabase: auth.uid() lee el "sub" del JWT de la petición.
create function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

-- Supabase concede por defecto acceso a las tablas de public a anon/authenticated;
-- por eso la seguridad real depende de RLS.
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
