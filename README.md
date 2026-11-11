# MentorLink · Infraestructura con Supabase e IA

Infraestructura de base de datos y autenticación de **MentorLink**, una plataforma que conecta mentores expertos en tecnología con estudiantes. El SQL se generó con IA a partir de un prompt estructurado y se probó en PostgreSQL con 16 pruebas automáticas de RLS.

## 📄 Documento de entrega

**[docs/ENTREGA.md](docs/ENTREGA.md)** reúne los 4 entregables:

1. **Scripts SQL**: tablas `perfiles`, `sesiones` y `mensajes`, con FKs, restricciones, triggers y políticas RLS.
2. **Prompt de IA**: texto exacto usado (también en [docs/PROMPT.md](docs/PROMPT.md)).
3. **Log de Supabase CLI**: `supabase init`, `supabase migration new inicializar_esquema` y los comandos para aplicar los cambios (`link`, `db push`).
4. **Guía de Auth**: Email/Password y Google OAuth en 3 pasos.

## Estructura

```text
mentorlink-infra/
├── docs/
│   ├── ENTREGA.md          # Documento principal de entrega
│   ├── PROMPT.md           # Prompt exacto usado con la IA
│   ├── cli-log.txt         # Salida real de la CLI de Supabase
│   └── test-log.txt        # Resultado de las pruebas RLS
├── supabase/
│   ├── config.toml         # Generado por `supabase init` (Auth: email + Google)
│   └── migrations/
│       └── 20261111020304_inicializar_esquema.sql
├── tests/
│   ├── 00_supabase_stubs.sql   # Simula auth.users / auth.uid() en Postgres puro
│   └── 01_rls_tests.sql        # 16 pruebas de seguridad
└── .env.example            # Variables para Google OAuth (local)
```

## Aplicar a un proyecto de Supabase

```bash
npx supabase login
npx supabase link --project-ref <PROJECT_REF>
npx supabase db push
```
