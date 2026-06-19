# iroh-streams — Arquitectura de tres componentes

## Idea central

**syntrix-admin** es la única app nativa (Tauri/Rust). Embebe un servidor de streams HTTP. Los admins syncan entre sí vía iroh P2P.

**syntrix-client** es una web app (browser). Usa StreamDB (TanStack DB built-in) para queries + persistencia. Se conecta al servidor de streams del admin vía HTTP.

**iroh-streams** es el protocolo/server que une ambos mundos: HTTP streams hacia los clientes web, iroh P2P entre admins.

```
┌──────────────────────────────────────────────────────────────────┐
│                        iroh P2P network                          │
│                                                                  │
│  ┌─ Admin Sucursal A ──────────┐   ┌─ Admin Sucursal B ────────┐│
│  │                              │   │                            ││
│  │  syntrix-admin (Tauri/Rust)  │◄──►  syntrix-admin (Tauri)    ││
│  │  ┌────────────────────────┐  │   │  ┌──────────────────────┐  ││
│  │  │  iroh-streams server   │  │   │  │  iroh-streams server │  ││
│  │  │  (HTTP + P2P sync)     │  │   │  │  (HTTP + P2P sync)   │  ││
│  │  └────────┬───────────────┘  │   │  └────────┬─────────────┘  ││
│  └───────────┼──────────────────┘   └───────────┼────────────────┘│
│              │ HTTP                              │ HTTP            │
│              ▼                                   ▼                 │
│  ┌─ Web Clients LAN A ───────┐   ┌─ Web Clients LAN B ──────────┐│
│  │  Browser / PWA / Mobile    │   │  Browser / PWA / Mobile      ││
│  │  ┌──────────────────────┐ │   │  ┌──────────────────────┐    ││
│  │  │ StreamDB (TanStack DB)│ │   │  │ StreamDB (TanStack DB)│   ││
│  │  │ + OPFS persistence   │ │   │  │ + OPFS persistence   │    ││
│  │  └──────────────────────┘ │   │  └──────────────────────┘    ││
│  └───────────────────────────┘   └───────────────────────────────┘│
└──────────────────────────────────────────────────────────────────┘
```

---

## Componente 1: syntrix-admin (Tauri, Rust)

**Única app nativa.** Se instala una por sucursal/oficina. Funciones:

| Función | Descripción |
|---------|-------------|
| Crear org | Genera streams iniciales (control, operational, payroll, catalogs) |
| Gestionar dispositivos | Agregar/quitar miembros, asignar roles |
| Gestionar permisos | `members/<node_id>` con role + overrides en stream `control` |
| Servir streams HTTP | Embebe iroh-streams server, expone API REST en `localhost:4437` |
| Sync P2P | Conecta con otros admins vía iroh, sync de streams entre sucursales |
| Capabilities | Encripta y distribuye tickets de acceso a streams |

**Stack interno:**
```
syntrix-admin (Tauri)
├── iroh (P2P networking, relay, hole punching)
├── iroh-streams (stream server embebido)
│   ├── HTTP API (Durable Streams protocol)
│   └── P2P sync engine (gossip + set reconciliation entre admins)
└── redb/LMDB (storage local de streams)
```

**Endpoints HTTP que expone:**
```
PUT  /v1/stream/org_acme/control       ← crear stream
POST /v1/stream/org_acme/operational   ← append evento
GET  /v1/stream/org_acme/operational?offset=X&live=sse  ← leer + suscribir
HEAD /v1/stream/org_acme/operational   ← metadata
```

---

## Componente 2: syntrix-client (Web app, browser)

**Web app pura.** Corre en cualquier browser, PWA, o mobile web. Sin Tauri, sin Rust.

| Función | Descripción |
|---------|-------------|
| Autenticación | Recibe capabilities del admin (QR, link, invite) |
| UI del ERP | Facturas, productos, clientes, reportes (React + shadcn) |
| Queries | StreamDB con TanStack DB nativo (sin adapter) |
| Persistencia local | OPFS vía StreamDB (funciona offline) |
| Sync | HTTP SSE/long-poll al stream server del admin |
| Mutaciones | Optimistic writes → append al stream → confirmación |

**Stack interno:**
```
syntrix-client (Browser)
├── React + shadcn (UI)
├── StreamDB (@durable-streams/state/db)
│   ├── TanStack DB collections (nativo, 0 líneas de adapter)
│   ├── Zod schemas por collection
│   ├── useLiveQuery (differential dataflow, 0.7ms)
│   ├── Optimistic mutations (insert/update/delete)
│   └── OPFS persistence (offline-first)
├── @durable-streams/client (HTTP client para streams)
└── No Rust. No Tauri. No iroh.
```

**Conexión al admin:**
```typescript
const db = createStreamDB({
  streamOptions: {
    url: `http://192.168.1.100:4437/v1/stream/org_acme/operational`,
    contentType: "application/json",
  },
  live: "sse",
  state: schema,  // invoices, customers, products, etc.
})

await db.preload()  // carga historia, materializa estado, suscribe a live

// TanStack DB YA FUNCIONANDO:
const { data } = useLiveQuery((q) =>
  q.from({ inv: db.collections.invoices })
   .join({ cust: db.collections.customers }, eq(inv.customer_id, cust.id))
   .where(eq(inv.status, "open"))
)
```

---

## Componente 3: iroh-streams (servidor de streams P2P)

**El protocolo/server que une todo.** Reemplaza iroh-docs. Es Durable Streams + iroh P2P.

### Qué es

Un server HTTP que implementa el [protocolo Durable Streams](https://github.com/durable-streams/durable-streams/blob/main/PROTOCOL.md) con dos backends de storage:

1. **Local** — LMDB o redb para persistencia en disco
2. **P2P** — sync de streams entre peers vía iroh gossip + set reconciliation

### API HTTP (compatible con Durable Streams)

```
PUT  /v1/stream/{path}           ← crear stream (idempotente)
POST /v1/stream/{path}           ← append datos
GET  /v1/stream/{path}?offset=X  ← leer desde offset (catch-up)
GET  /v1/stream/{path}?offset=X&live=sse      ← suscribir SSE
GET  /v1/stream/{path}?offset=X&live=long-poll ← long-poll
HEAD /v1/stream/{path}           ← metadata
DELETE /v1/stream/{path}         ← borrar stream
```

### P2P sync entre admins

Cuando dos admins están online, iroh-streams sync los streams automáticamente:

```
Admin A                           Admin B
───────                           ───────
POST /operational                 
  {"invoice":"inv-1"}             
  ──► almacenado en LMDB          
  ──► iroh gossip notifica ────►  recibe notificación
                                   ──► GET /operational?offset=X
                                   ──► almacena en LMDB local
                                   
                                   Clientes de B ven "inv-1" vía SSE
```

**Mecanismo:** iroh-streams usa iroh gossip para anunciar nuevos offsets. Los peers interesados hacen GET del rango nuevo. El set reconciliation de iroh asegura que no haya duplicados.

**Storage por stream:** cada stream se almacena como archivos de segmentos (como Caddy durable_streams) en `data_dir/<stream_path>/`. LMDB para metadata (offsets, producer state).

### Qué NO necesita iroh-streams (vs iroh-docs)

| iroh-docs tiene | iroh-streams NO necesita | Por qué |
|----------------|-------------------------|---------|
| Author signatures por entry | ❌ | El admin es el author. Los clientes son anónimos (autenticados por capability) |
| HLC (Hybrid Logical Clock) | ❌ | El offset del stream da ordenamiento total |
| `accept_cb` por NamespaceId | ✅ Simplificado | Auth por stream path + capability en HTTP header |
| Set reconciliation de entries | ✅ Simplificado | Sync de rangos de offsets (más simple que sync de keys individuales) |
| `doc.set_bytes(author, key, value)` | ❌ | `POST /stream {json}` con idempotent producer |
| `doc.getMany(prefix)` | ❌ | `GET /stream?offset=X` |
| redb como storage | ✅ (LMDB o redb) | LMDB es más simple, redb también sirve |

---

## Flujos completos

### Flujo 1: Admin crea org

```
1. Admin app → iroh-streams: PUT /v1/stream/org_acme/control
   PUT /v1/stream/org_acme/catalogs
   PUT /v1/stream/org_acme/operational
   PUT /v1/stream/org_acme/payroll

2. Admin app → POST /v1/stream/org_acme/control
   members/<admin_id>: { active: true, role: "admin" }
   roles/admin: { can_open: ["*"], can_write: ["*"] }

3. Admin app → genera capability tokens para los streams
   Las capabilities son JWT o tickets encriptados que el cliente
   envía como Authorization header
```

### Flujo 2: Admin agrega empleado

```
1. Admin app → POST /v1/stream/org_acme/control
   members/<bob_id>: { active: true, role: "sales" }
   roles/sales: { can_open: ["control", "catalogs", "operational"], can_write: ["operational"] }

2. Admin app → genera capability para Bob (JWT con claims):
   { sub: "bob_id", org: "acme", can_open: [...], can_write: [...] }

3. Admin app → comparte capability con Bob (QR, link, invite)

4. iroh-streams sync automático con otros admins vía P2P
```

### Flujo 3: Cliente web crea factura

```
1. Cliente → abre StreamDB con la capability de Bob
   db = createStreamDB({
     streamOptions: { url: "http://admin:4437/v1/stream/org_acme/operational" },
     headers: { Authorization: "Bearer <capability>" },
     state: schema,
   })

2. Cliente → db.actions.addInvoice({ customer_id: "5", amount: 100 })
   → optimistic: se ve instantáneo en UI
   → POST /v1/stream/org_acme/operational
     { type: "invoice", key: "inv-42", value: {...}, headers: { operation: "insert", txid: "..." } }

3. iroh-streams server:
   → valida capability (JWT: bob tiene can_write: ["operational"]?)
   → append al stream
   → notifica vía SSE a otros clientes de la misma LAN
   → iroh gossip notifica a otros admins

4. Admin B (otra sucursal):
   → recibe gossip → GET /operational?offset=NEW → almacena
   → clientes de Admin B reciben update vía SSE

5. Contabilidad (cliente web en Admin B):
   → useLiveQuery se actualiza automáticamente
   → ve la factura de Bob en tiempo real
```

### Flujo 4: Cliente web offline

```
1. Cliente pierde conexión
   → StreamDB sigue funcionando con datos en OPFS
   → Nuevas mutaciones: optimistic local, encoladas para sync

2. Cliente vuelve online
   → StreamDB reconecta al stream server
   → POST de mutaciones pendientes (con idempotent producer, sin duplicados)
   → GET catch-up desde último offset conocido
   → Estado reconcileado
```

---

## Storage: qué persiste dónde

| Componente | Storage | Qué guarda |
|-----------|---------|-----------|
| **syntrix-admin** | LMDB/redb (disco) | Todos los streams de las orgs que administra |
| **syntrix-client** | OPFS (browser) | Cache local de streams que lee (StreamDB) |
| **iroh-streams server** | LMDB + segment files | Streams completos (append-only log + metadata) |

**El admin es el source of truth.** Los clientes son cachés con capacidad offline. Si un cliente pierde todos sus datos locales, reconecta y `preload()` reconstruye todo desde el stream server.

---

## Permisos con capabilities (simplificado vs iroh-docs)

En vez de `accept_cb` + `NamespaceRegistry` + tickets encriptados por dispositivo, usamos **JWT capabilities**:

```json
// Capability de Bob (sales):
{
  "sub": "bob_device_id",
  "org": "acme",
  "role": "sales",
  "can_open": ["control", "catalogs", "operational"],
  "can_write": ["operational"],
  "exp": 1735689600
}
```

El stream server valida:
- `Authorization: Bearer <jwt>` en cada request
- `can_open` para GET/HEAD
- `can_write` para POST/PUT/DELETE
- Firma del admin (el JWT está firmado por el admin)

**Ventaja sobre iroh-docs capabilities:**
- No requiere intercambio de claves públicas
- No requiere encriptación asimétrica
- El JWT se puede enviar por QR, link, email
- Revocación: el admin rota la signing key, los JWTs viejos expiran

---

## Comparación con el stack actual

| Capa | Stack actual | Stack propuesto |
|------|-------------|-----------------|
| Admin app | Tauri + iroh-docs | **Tauri + iroh-streams** |
| Client app | Tauri + iroh-docs | **Browser + StreamDB** |
| Sync | iroh-docs P2P | **iroh-streams (HTTP + P2P)** |
| Queries | invoke() → Rust | **StreamDB (TanStack DB nativo)** |
| Schemas | serde (Rust) | **Zod (TypeScript)** |
| Offline | redb local | **OPFS (StreamDB)** |
| Permisos | accept_cb + capabilities | **JWT capabilities** |
| Deploy client | Instalar app nativa | **Abrir URL en browser** |

---

## Plan de implementación

### Fase 1: iroh-streams server (Rust)

```
iroh-streams crate:
├── HTTP API (axum o warp)
│   ├── PUT /v1/stream/{path}
│   ├── POST /v1/stream/{path}
│   ├── GET /v1/stream/{path}
│   ├── HEAD /v1/stream/{path}
│   └── DELETE /v1/stream/{path}
├── Storage backend
│   ├── LMDB (metadata: offsets, producer state)
│   └── Segment files (append-only data)
├── JWT validation (capabilities)
├── P2P sync (iroh gossip + set reconciliation)
└── SSE/long-poll live modes
```

### Fase 2: syntrix-admin actualizado

```
syntrix-admin:
├── Embebe iroh-streams server
├── create_org() → PUT streams
├── add_device() → genera JWT capability
├── UI: misma interfaz actual
└── Sync P2P: automático vía iroh-streams
```

### Fase 3: syntrix-client-web (nuevo)

```
syntrix-client-web:
├── Vite + React + shadcn
├── StreamDB para datos
├── OPFS para persistencia offline
├── Recibe JWT capability (QR/link del admin)
├── Misma UI que el client actual
└── Funciona en: Chrome, Firefox, Safari, Edge, PWA, mobile web
```

---

## Resumen

| Componente | Tipo | Tecnología | Rol |
|-----------|------|-----------|-----|
| **syntrix-admin** | Nativa | Tauri + Rust | Gestión de org, embebe stream server, sync P2P |
| **syntrix-client** | Web | Browser + StreamDB | ERP UI, queries reactivas, offline-first |
| **iroh-streams** | Servidor | Rust crate | HTTP streams + P2P sync entre admins |

**Lo que ganamos:**
- Client web sin instalar nada (abrir URL)
- StreamDB = TanStack DB nativo (0 líneas de adapter)
- Sin iroh-docs (reemplazado por protocolo más simple)
- Sin HLC, sin author signatures, sin accept_cb
- Permisos vía JWT (más simple que capabilities asimétricas)
- Mismo P2P entre sucursales (iroh gossip)
- Offline en browser vía OPFS + StreamDB
