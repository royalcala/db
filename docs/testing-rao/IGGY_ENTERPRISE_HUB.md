# Apache Iggy — Hub centralizado de eventos (Fase 3 / Enterprise)

## Qué es Iggy

Apache Iggy es un message streaming server escrito en Rust. Apache Incubating. 4.4k ⭐.

| Característica | Detalle |
|---------------|---------|
| Protocolos | QUIC, WebSocket, TCP, HTTP REST |
| Rendimiento | Millones de mensajes/segundo, latencia sub-ms |
| Deploy | Single binary (~20MB), sin dependencias externas |
| Storage | Append-only log en disco, segmentos configurables |
| Auth | Usuarios, roles, PAT tokens, permisos granulares |
| Multi-tenant | Streams → Topics → Partitions |
| Consumer groups | Offset tracking server-side, auto-commit |
| Backups | S3 archiving built-in |
| Integraciones | Connectors (Rust plugins): Source/Sink/Transform |
| AI | MCP server built-in (provee contexto a LLMs) |
| SDK | Rust, C#, Java, Python, Node.js, Go |
| Dashboard | Web UI + CLI interactiva |
| Clustering | En roadmap (Viewstamped Replication) |
| Licencia | Apache 2.0 |

---

## Rol en Syntrix

**Fase 3 / Enterprise.** Componente opcional. No reemplaza iroh-docs. Se agrega cuando se acepta infraestructura centralizada para backup, analytics, integraciones o AI.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Fase 1-2: P2P                                │
│                                                                     │
│  Sucursal A ◄──── iroh-docs P2P ────► Sucursal B                   │
│       │                                     │                       │
│       │ sync local                           │ sync local           │
│       ▼                                     ▼                       │
│  admin app (Tauri)                     admin app (Tauri)            │
│  web clients (browser)                 web clients (browser)        │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                        Fase 3: + Iggy (opcional)                    │
│                                                                     │
│  Sucursal A ──┐                                                     │
│  Sucursal B ──┼──►  Apache Iggy (VPS/cloud)                        │
│  Sucursal C ──┘       │                                             │
│                        ├──► S3 archiving (backup automático)        │
│                        ├──► BI dashboards (Metabase/Superset)       │
│                        ├──► Connectors → QuickBooks, SAP, SAT       │
│                        ├──► Webhooks → Slack, email, WhatsApp       │
│                        └──► MCP server → AI/LLM queries             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Casos de uso

### 1. Backup y archivo automático

Cada sucursal streamea sus eventos a Iggy. Iggy persiste en disco y archiva a S3.

```
Modelo Iggy:
  Stream:  syntrix_prod
    Topic: org_acme_operational    ← eventos de facturas, órdenes
    Topic: org_acme_payroll        ← eventos de nómina
    Topic: org_acme_catalogs       ← eventos de productos, clientes
    Topic: org_clientex_operational
    ...

Cada topic → N particiones (una por sucursal).
Consumer groups para lectores paralelos.

Retention: 365 días en disco, indefinido en S3.
```

**Zero code:** Iggy tiene S3 archiving en su config:

```toml
[backup]
enabled = true
type = "s3"
bucket = "syntrix-backups"
region = "us-east-1"
interval = "1h"
```

### 2. BI y analítica

Dashboards (Metabase, Superset, Grafana) consultan vía HTTP REST o connector dedicado.

```
Iggy HTTP API:
  GET /streams/syntrix_prod/topics/org_acme_operational/poll?consumer=bi&offset=0&count=100

→ JSON array de eventos
→ BI tool los agrega: ventas por mes, top productos, margen por sucursal
```

### 3. Integraciones con sistemas externos

Connectors (Rust plugins) empujan eventos a sistemas externos:

```toml
# Sink connector: facturas → QuickBooks
type = "sink"
key = "quickbooks"
path = "target/release/libiggy_connector_quickbooks"
[[streams]]
stream = "syntrix_prod"
topics = ["org_acme_operational"]

# Transform: filtrar solo invoices, mapear campos
[transforms.filter]
type = "invoice"

[transforms.map_fields]
customer_id = "qb_customer_ref"
amount = "total_amount"
```

**Conectores posibles:**
- QuickBooks / Xero / ContaMex (contabilidad)
- SAT (facturación electrónica México)
- SAP / Odoo (ERP enterprise)
- Email (notificaciones)
- Slack / WhatsApp (alertas)
- Webhook genérico (cualquier sistema)

### 4. AI / LLM context

Iggy tiene MCP server built-in. Un LLM puede consultar eventos del ERP:

```
Usuario: "¿Cuánto facturamos este mes vs el mes pasado?"

LLM → MCP client → Iggy MCP server
  → poll topic org_acme_operational
  → filtrar invoices del mes actual y anterior
  → agregar montos
  → responder: "$145,200 este mes vs $132,000 el pasado (+10%)"
```

El MCP server le da al LLM acceso tipado y seguro a los datos del ERP sin exponer la DB directamente.

### 5. Auditoría y compliance

Todos los eventos de todas las sucursales en un solo lugar. Inmutable (append-only). Con timestamps. Con trazabilidad de qué dispositivo escribió qué.

```
Auditor: "¿Quién modificó la factura INV-1042?"

→ Iggy consumer lee topic org_acme_operational
→ Busca evento: { type: "invoice.updated", key: "INV-1042", headers: { author: "bob_device_id" } }
→ Respuesta: Bob (dispositivo laptop) el 15-jun-2026 14:32
```

---

## Por qué Iggy y no Kafka

| | Kafka | Iggy |
|---|---|---|
| Lenguaje | Java/Scala | **Rust** (mismo que todo Syntrix) |
| Deploy | JVM + Zookeeper/KRaft | **Single binary, 0 deps** |
| Peso | GBs de RAM | MBs de RAM |
| Latencia | ms | **sub-ms (io_uring)** |
| QUIC nativo | No | **Sí** (mismo protocolo que iroh) |
| SDK Rust | Librería externa | **SDK oficial en el repo** |
| Licencia | Apache 2.0 | Apache 2.0 |
| Connectors | Kafka Connect (Java) | **Rust plugins nativos** |

Para una PyME con un VPS de $10/mes, Iggy corre sin problema. Kafka necesitaría mínimo 4GB RAM.

---

## Arquitectura de deployment

```
┌─ VPS ($10-20/mes) ─────────────────────────────────────┐
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Apache Iggy (single binary, ~20MB)               │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐       │   │
│  │  │ QUIC     │  │ TCP      │  │ HTTP     │       │   │
│  │  │ :8090    │  │ :8090    │  │ :3000    │       │   │
│  │  └──────────┘  └──────────┘  └──────────┘       │   │
│  │                                                    │   │
│  │  Streams:                                          │   │
│  │    syntrix_prod/                                   │   │
│  │      ├── org_acme_operational (N partitions)       │   │
│  │      ├── org_acme_payroll                          │   │
│  │      ├── org_clientex_operational                  │   │
│  │      └── ...                                       │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌─ S3 archiving ─┐  ┌─ Connectors ─┐  ┌─ MCP ───────┐ │
│  │ backups diarios │  │ QuickBooks   │  │ AI context  │ │
│  └─────────────────┘  │ Slack notif  │  └─────────────┘ │
│                       └──────────────┘                  │
└──────────────────────────────────────────────────────────┘
```

Cada admin app (Tauri) tiene un **Iggy producer** que streamea eventos locales al hub central. Es fire-and-forget: si el hub está offline, los eventos se acumulan localmente y se envían cuando vuelve.

---

## Integración con el stack actual

```
syntrix-admin (Tauri, Rust)
├── iroh-docs (P2P sync entre sucursales)
├── TanStack DB adapter (queries locales)
└── Iggy producer (opcional, Fase 3)
    └── stream_events_to_hub()
        └── events de operational, payroll, catalogs
        └── idempotent producer (sin duplicados)
        └── fire-and-forget (no bloquea operación local)
```

Código conceptual en Rust:

```rust
// En syntrix-admin, después de commit_event():
pub async fn stream_to_hub(state: &AppState, event: &Event) {
    if let Some(hub) = &state.iggy_hub {
        let producer = hub.producer("syntrix_prod", &format!("org_{}_operational", event.org_id))?;
        producer.send(IggyMessage::from_str(&serde_json::to_string(event)?)).await?;
    }
}
```

---

## Cuándo activarlo

| Fase | Gatillo |
|------|---------|
| Fase 1-2 (MVP) | No se necesita. P2P cubre todo. |
| Fase 3 (Crecimiento) | 5+ sucursales, necesitan backup central y dashboards |
| Fase 4 (Enterprise) | Integraciones con SAP/QuickBooks, auditoría regulatoria, AI assistant |

---

## Costo estimado

| Componente | Costo mensual |
|-----------|---------------|
| VPS 2 vCPU, 4GB RAM (Hetzner/DigitalOcean) | ~$12 |
| S3 backup (100GB, infrequent access) | ~$2 |
| **Total** | **~$14/mes** |

Comparado con Kafka (mínimo $40/mes en VPS por los requisitos de RAM + JVM + Zookeeper).

---

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|-----------|
| Iggy es centralizado → SPOF | Fire-and-forget. Si el hub cae, eventos se acumulan localmente. No bloquea operaciones. |
| Iggy clustering en roadmap (no production-ready aún) | Para Fase 3-4 ya debería estar estable. Si no, single-node con backups a S3. |
| Latencia de red al hub | QUIC nativo (mismo protocolo que iroh). Misma latencia que sync P2P. |
| Costo de tráfico | Solo eventos nuevos. Compresión. Batching configurable. |

---

## Estado: documentado, no implementado

Este documento es referencia para Fase 3/4. No hay código que implementar hoy. Cuando el proyecto crezca a 5+ sucursales o requiera backup central / BI / integraciones, se retoma.
