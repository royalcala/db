# Durable Streams ecosystem — análisis para Syntrix

## Stack completo de Durable Streams

Durable Streams es un **protocolo HTTP** para streams append-only con replay. Sobre él se construyen capas:

```
┌─────────────────────────────────────────────────────────────┐
│  StreamDB          ← type-safe reactive DB en un stream      │
│  (built-in TanStack DB integration, no custom adapter!)      │
├─────────────────────────────────────────────────────────────┤
│  Durable State     ← protocolo insert/update/delete sobre    │
│                      streams JSON (operaciones tipadas)      │
├─────────────────────────────────────────────────────────────┤
│  JSON mode         ← mensajes estructurados con boundaries   │
│  TypeScript client ← create, append, read, subscribe, live   │
├─────────────────────────────────────────────────────────────┤
│  Durable Streams   ← protocolo HTTP: streams append-only     │
│                      con offset-based replay + live tail     │
├─────────────────────────────────────────────────────────────┤
│  Stream server     ← Caddy plugin (production) o Node.js     │
│                      (dev). Servidor HTTP que hostea streams │
└─────────────────────────────────────────────────────────────┘

Integraciones:
  StreamFS  ← filesystem para agentes AI sobre streams
  Yjs       ← CRDT collaborative editing sobre streams
  TanStack AI / Vercel AI SDK ← AI token streaming
```

---

## Análisis por herramienta

### 1. CLI (`@durable-streams/cli`)

Línea de comandos para crear, leer, escribir y borrar streams. Conexión HTTP a cualquier servidor.

```
$ durable-stream create org_acme/invoices --json
$ durable-stream write org_acme/invoices '{"id":"inv-1","amount":100}' --json
$ durable-stream read org_acme/invoices
```

**Para Syntrix:** debugging y admin scripts. Crear streams de prueba, inspeccionar datos, scripts de migración. Complementario, no core.

### 2. TypeScript Client (`@durable-streams/client`)

Cliente HTTP con:
- `DurableStream` — create, append, read, close, delete
- `stream()` — fetch-like read con offset-based resume
- `IdempotentProducer` — exactly-once writes con batching + retry
- `subscribeJson()` — suscripción reactiva a nuevos mensajes
- Live modes: SSE, long-poll

```typescript
const handle = await DurableStream.create({
  url: "https://streams.syntrix.io/org_acme/operational",
  contentType: "application/json",
})

await handle.append(JSON.stringify({ type: "invoice.created", id: "inv-1", amount: 100 }))

const res = await handle.stream<Invoice>({ offset: lastOffset, live: true })
res.subscribeJson(async (batch) => {
  batch.items.forEach(item => processInvoice(item))
})
```

**Para Syntrix:** reemplaza `invoke("commit_event")` y `invoke("sync_pull")`. No necesita Rust/Tauri. Funciona en browser. La suscripción `subscribeJson` reemplaza Tauri events.

### 3. JSON mode

Cada `POST` = un mensaje JSON distinto. Un array JSON se descompone en mensajes individuales. `GET` con `?offset=N` devuelve el rango.

**Para Syntrix:** wire format directo para eventos. Cada entry de iroh-docs → un mensaje JSON en el stream. Sin serialización binaria, sin HLC, sin key encoding manual.

### 4. Durable State (`@durable-streams/state`)

Protocolo sobre JSON mode que define operaciones tipadas:

```json
{
  "type": "invoice",
  "key": "inv-1",
  "value": { "id": "inv-1", "amount": 100, "customer_id": "cust-5" },
  "headers": {
    "operation": "insert",
    "txid": "abc-123",
    "timestamp": "2026-01-15T10:30:00Z"
  }
}
```

Operaciones: `insert`, `update`, `delete`. Control: `snapshot-start`, `snapshot-end`, `reset`.

`MaterializedState` — key-value store en memoria que aplica eventos:
```typescript
const state = new MaterializedState()
state.apply({ type: "invoice", key: "inv-1", value: {...}, headers: { operation: "insert" }})
const invoice = state.get("invoice", "inv-1")
```

**Para Syntrix:** reemplaza el deserialize manual de entries de iroh-docs. Cada entry → un State Event. `MaterializedState` reconstruye el estado actual. Pero no tiene queries reactivas — para eso está StreamDB.

### 5. StreamDB (`@durable-streams/state/db`)

**ESTO ES LO QUE OCUPAMOS.** StreamDB = Durable State + TanStack DB integrado nativamente. No custom adapter.

```typescript
import { createStateSchema } from "@durable-streams/state"
import { createStreamDB } from "@durable-streams/state/db"

const schema = createStateSchema({
  invoices: {
    schema: z.object({ id: z.string(), amount: z.number(), customer_id: z.string(), ... }),
    type: "invoice",
    primaryKey: "id",
  },
  customers: {
    schema: z.object({ id: z.string(), name: z.string(), ... }),
    type: "customer",
    primaryKey: "id",
  },
})

const db = createStreamDB({
  streamOptions: { url: "https://streams.syntrix.io/org_acme/operational", ... },
  live: "sse",
  state: schema,
})

await db.preload()  // carga todo el stream, materializa estado, suscribe a live

// TanStack DB collections — directo, sin adapter!
const { data } = useLiveQuery((q) =>
  q.from({ inv: db.collections.invoices })
   .join({ cust: db.collections.customers }, eq(inv.customer_id, cust.id))
   .where(eq(inv.status, "open"))
)

// Mutaciones con optimistic state
await db.actions.addInvoice(newInvoice)  // optimistic local + append al stream
```

**Para Syntrix: esto reemplaza TODO.** Ya no necesitamos:
- `irohCollectionOptions` adapter custom (~200 líneas)
- `invoke("commit_event")` → `stream.append()`
- `invoke("sync_pull")` → `db.preload()`
- `listen("data-changed")` → `subscribeJson()` (manejado por StreamDB)
- Deserialización manual → schema Zod built-in

**Lo que StreamDB ya trae:**
- TanStack DB collections nativas (sin adapter)
- Schema Zod/Valibot/ArkType por collection
- Live queries con differential dataflow (0.7ms)
- Optimistic mutations con rollback
- Joins entre collections
- Preload + live sync automático
- Transaction IDs para confirmación

### 6. StreamFS (`@durable-streams/stream-fs`)

Filesystem distribuido sobre streams. Archivos, directorios, metadata, watchers.

**Para Syntrix:** no es core para ERP. Útil si más adelante necesitamos adjuntar archivos a facturas (PDFs, imágenes). No es prioridad MVP.

### 7. Yjs (`@durable-streams/y-durable-streams`)

CRDT para edición colaborativa (texto enriquecido, TipTap, CodeMirror). Sync vía HTTP sin WebSocket.

**Para Syntrix:** no es core. Útil si el ERP necesita edición colaborativa de documentos (ej: notas en facturas, descripciones de productos). No es prioridad MVP.

### 8. TanStack AI / Vercel AI SDK

Streaming de tokens de IA con resume. No aplica a ERP.

---

## Comparación: iroh-docs vs Durable Streams

| Dimensión | iroh-docs + redb | Durable Streams + StreamDB |
|-----------|-----------------|---------------------------|
| **Protocolo** | QUIC P2P (gossip + set reconciliation) | HTTP (REST + SSE/long-poll) |
| **Topología** | Peer-to-peer, sin servidor | **Client-server, necesita stream server** |
| **Storage** | redb (Rust embedded KV) | Server-side (Caddy + filesystem o memoria) |
| **Clientes** | Solo Rust (Tauri) | **TypeScript, Python, Go, Rust, Swift, etc.** |
| **Web app** | ❌ No (necesita Tauri) | ✅ Sí (browser nativo) |
| **Offline** | ✅ Nativo (local-first) | ❌ Necesita servidor para persistir |
| **Sync** | P2P automático (gossip) | Polling SSE/long-poll al servidor |
| **Queries** | Requiere adapter manual | **StreamDB = TanStack DB nativo** |
| **Schemas** | Manual (serde en Rust) | **Zod/Valibot/ArkType nativo** |
| **Peso cliente** | ~50 KB (TanStack DB) + adapter | ~50 KB (TanStack DB nativo en StreamDB) |
| **Dependencias** | Rust/Tauri + iroh stack | **Solo npm (sin Rust)** |
| **Permisos** | accept_cb + capabilities (custom) | Auth headers + server-side ACL |
| **Namespaces** | Separación por doc + tickets | Separación por stream URL + auth |
| **Multi-device** | ✅ Sync P2P | ✅ Resume desde offset |

---

## El tradeoff: P2P sin servidor vs Web sin Rust

| | iroh-docs | Durable Streams |
|---|---|---|
| **Fortaleza** | P2P sin servidor, offline-first | Web nativo, TypeScript, sin Rust |
| **Debilidad** | Solo Rust/Tauri, no web | Necesita stream server |

Son soluciones para **problemas distintos**. La pregunta no es cuál es mejor, sino cuál necesitamos nosotros.

### ¿Realmente necesitamos P2P sin servidor?

**Sí lo necesitamos si:**
- Las sucursales están en zonas sin internet estable
- No queremos depender de infraestructura externa
- Queremos que los datos vivan solo en los dispositivos

**No lo necesitamos si:**
- Siempre hay conexión a internet
- Podemos hostear un stream server (Caddy, ~20MB binary)
- Aceptamos que el server es el hub de sync

---

## Opción híbrida: stream server local + relaying P2P

Una posibilidad: cada peer corre un mini stream server embebido. Los peers se descubren vía iroh relay y se syncan los streams entre sí. Esto combina:
- **Web nativo** (StreamDB en browser, stream server local en Rust via Tauri)
- **P2P sync** (los stream servers se pasan datos entre sí via iroh)

Pero agrega complejidad: un stream server corriendo localmente + protocolo de sync entre servidores.

---

## Recomendaciones

### Para Syntrix P2P sin servidor: iroh-docs + TanStack DB adapter

El requerimiento original es P2P sin servidores. iroh-docs sigue siendo la opción correcta para el **sync layer.** El adapter de TanStack DB (que ya analizamos) es la capa de queries.

### Si el requerimiento cambia (se acepta servidor): StreamDB directamente

Si en el futuro decidimos hostear un stream server (ej: en el relay propio, o Electric Cloud, o self-hosted Caddy), **StreamDB reemplaza TODO el stack de sync + queries.** Ya no necesitamos iroh-docs, ni redb, ni Rust para las queries, ni adapter custom:

```
Browser/React → StreamDB (TanStack DB built-in) → HTTP → stream server
```

StreamDB ya incluye TanStack DB. El adapter es CERO líneas. Las queries, schemas, optimistic mutations y live sync vienen incluidos.

### Resumen

| Stack | Sync | Queries | Web? | Offline? | Servidor? |
|-------|------|---------|------|----------|-----------|
| iroh-docs + TanStack DB adapter | iroh-docs P2P | adapter custom (~200 loc) | Solo Tauri | ✅ | No |
| **StreamDB** | HTTP + stream server | **Nativo (0 loc)** | ✅ Browser | Con server | Sí |

**StreamDB es objetivamente mejor como query layer** — no necesita adapter, TanStack DB ya está integrado. La decisión se reduce a: ¿aceptamos tener un stream server?

Mientras el requerimiento sea P2P sin servidor, iroh-docs es la respuesta. Si cambia, StreamDB simplifica todo radicalmente.
