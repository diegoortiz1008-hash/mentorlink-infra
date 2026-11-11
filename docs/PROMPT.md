# Prompt de IA utilizado

Texto exacto enviado al asistente de IA (Claude) para generar el SQL de la migración y las políticas RLS.

```text
## ROL
Actúa como Arquitecto de Bases de Datos Senior especializado en PostgreSQL 15+ y Supabase
(Auth, RLS, CLI). Escribes SQL de producción: seguro por defecto, idempotente donde aplique
y comentado en español.

## CONTEXTO
Proyecto: "MentorLink", plataforma que conecta mentores expertos en tecnología con estudiantes.
- La autenticación la gestiona Supabase Auth (Email/Password y Google OAuth); los usuarios
  viven en auth.users.
- El SQL se guardará en una migración creada con `supabase migration new inicializar_esquema`
  y se aplicará con `supabase db push`.
- Presupuesto limitado: nada de extensiones de pago ni servicios externos.

## TAREA
Genera UN script SQL que cree:
1. perfiles (id, nombre, bio, rol): id es PK y FK a auth.users(id) ON DELETE CASCADE.
   rol es un ENUM ('mentor', 'estudiante') con valor por defecto 'estudiante'.
2. sesiones (id, mentor_id, estudiante_id, fecha, estado): mentor_id y estudiante_id son FK a
   perfiles. estado es un ENUM ('pendiente', 'confirmada', 'completada', 'cancelada').
3. mensajes (id, sesion_id, remitente_id, contenido): FK a sesiones y a perfiles.

## REQUISITOS TÉCNICOS
- Tipos óptimos: uuid con gen_random_uuid(), timestamptz para fechas, text con CHECK de longitud.
- Restricciones: NOT NULL donde corresponda, CHECK mentor_id <> estudiante_id, UNIQUE
  (mentor_id, fecha) para evitar choques de horario y contenido de mensajes no vacío (máx. 2000).
- Índices en todas las FK y en las columnas que usan las políticas RLS.
- created_at/updated_at con un trigger que mantenga updated_at.
- Trigger en auth.users que cree el perfil automáticamente al registrarse, tomando el nombre de
  raw_user_meta_data ('nombre' para email, 'full_name' o 'name' para Google). El rol NUNCA
  se toma del cliente.
- Trigger que valide que mentor_id tenga rol 'mentor' y estudiante_id rol 'estudiante'.
- Todas las funciones SECURITY DEFINER deben usar `set search_path = ''`.

## SEGURIDAD (RLS)
Habilita RLS en las 3 tablas y crea políticas para el rol `authenticated`:
- perfiles: SELECT para cualquier autenticado (directorio de mentores); UPDATE solo del propio
  perfil. El usuario NO puede cambiar su rol (usa privilegios de columna).
- sesiones: SELECT/UPDATE solo si auth.uid() es mentor_id o estudiante_id. INSERT solo si
  auth.uid() = estudiante_id y estado = 'pendiente'. Sin DELETE (se cancelan).
- mensajes: SELECT solo para participantes de la sesión; INSERT solo si auth.uid() = remitente_id
  y es participante. Sin UPDATE ni DELETE (historial inmutable).
- El rol `anon` no debe tener acceso a ninguna tabla.
- Usa el patrón `(select auth.uid())` por rendimiento y una función auxiliar
  `es_participante(sesion_id)` SECURITY DEFINER para no anidar RLS.

## FORMATO DE SALIDA
- Un único bloque de código SQL listo para pegar en el archivo de migración, dividido en secciones
  comentadas: 1) Tipos, 2) Tablas, 3) Índices, 4) Funciones y triggers, 5) Privilegios, 6) RLS.
- Nombres de políticas descriptivos en español.
- Después del bloque, una tabla Markdown: | Tabla | Operación | Quién puede | Política |.
- No expliques conceptos básicos ni añadas texto fuera de esas dos partes.
```

## Iteración

Primero revisé el SQL que generó la IA y luego lo **probé en PostgreSQL 16** con 16 pruebas automáticas ([`tests/01_rls_tests.sql`](../tests/01_rls_tests.sql)). En la prueba de "sesión consigo mismo", el trigger de roles rechazaba la fila antes que el `CHECK`. Lo dejé así porque la fila queda bloqueada igual, y ajusté la prueba para aceptar cualquiera de los dos errores.
