Ahora tengo el cuadro completo. Tres propuestas sobre la mesa:

- **Doc 3 (original tuyo):** iroh-docs + TanStack DB adapter, namespaces por nivel de seguridad (Opción C), sin cambiar el sync layer
- **Doc 1 (DeepSeek análisis):** exploración de Durable Streams como alternativa
- **Doc 2 (DeepSeek arquitectura):** `iroh-streams` como crate nuevo que tú escribes

Mi respuesta directa: **el Doc 3 es la base correcta. Con un cambio.**

---

## Por qué Doc 3 gana

**Resuelve el problema real.** El problema que motivó todo este análisis era privacidad entre roles — sales viendo payroll por la red. La Opción C lo resuelve a nivel de ticket de iroh-docs, que es el único nivel donde se puede resolver de verdad. Eso es arquitectura correcta.

**No inventa dependencias.** iroh-docs existe, tiene mantenimiento, tienes PR merged, conoces sus internals. Todo el stack (redb, iroh, TanStack DB) es conocido.

**El adapter es el único costo real.** ~200 LOC para mapear namespaces → collections es trabajo de 1-2 días, no semanas. Y lo controlas tú — no dependes de que Durable Streams soporte OPFS en Safari o de que StreamDB implemente un feature que necesitas.

**La Opción C de namespaces es elegante.** 6 namespaces fijos que no crecen con empleados, extensibles cuando el negocio lo requiere, privacidad garantizada a nivel protocolo. El diseño de roles con overrides por `members/<node_id>` es flexible sin ser complejo.

---

## El cambio que haría

**Eliminaría el namespace `private_<user>`.** Es el único que rompe la propiedad "6 namespaces fijos que no crecen con empleados" — necesitas crear uno por usuario en `add_device()`, que es exactamente lo que hacía la Opción B que descartaste.

Para preferencias de usuario (settings, UI preferences, theme) no necesitas un doc iroh con ticket propio. Eso va en `localStorage`/`IndexedDB` del dispositivo — es data del dispositivo, no de la org. Si el usuario quiere que sus preferencias viajen entre dispositivos, eso es un problema diferente que no necesita solución en el MVP.

Si hay datos genuinamente privados por usuario que deben sincronizarse entre sus dispositivos (ej: borradores de documentos), los agregas en Fase 2 como `private_*` con wildcards en los grants. Por ahora: 5 namespaces fijos en el MVP.

---

## Lo que descartaría definitivamente

**Doc 2 (`iroh-streams`):** construir un servidor de streams distribuido desde cero para evitar escribir 200 LOC de adapter es una inversión negativa. El ratio esfuerzo/beneficio es terrible.

**Doc 1 (StreamDB como reemplazo):** válido como opción futura si en algún momento Syntrix pivota a modelo server-first con clientes web puros. Guárdalo como referencia para esa conversación, no para ahora.

---

## Stack que armaría yo, simple

```
iroh-docs (P2P sync, storage redb)
  ↓
5 namespaces: control, catalogs, operational, payroll + private en Fase 2
  ↓
adapter ~200 LOC (namespaces → TanStack DB collections, filtro por key prefix)
  ↓
TanStack DB (queries reactivas, differential dataflow)
  ↓
React + TanStack Router + shadcn
```

El adapter hace exactamente una cosa: cuando un entry llega de iroh-docs, lee el key prefix (`invoices/`, `orders/`, `products/`...) y lo inserta en la collection correcta. El schema Zod vive en el adapter, no en iroh. `can_write()` se valida antes de llamar `doc.set_bytes()`. Nada más.

Lo que ya tienes en Doc 3 es esencialmente esto. El único trabajo pendiente es escribir el adapter y eliminar el namespace `private_*` del MVP.