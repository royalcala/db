# Capa de datos: decisión de arquitectura

## La arquitectura base NO cambia

La arquitectura de permisos y sync definida en `syntrix-client/DESIGN.md` y `syntrix-admin/DESIGN.md` se mantiene intacta:

- **org_control** — define miembros, roles, permisos
- **accept_cb** — bloquea sync de peers inactivos o sin ticket
- **iroh-docs** — sync P2P entre dispositivos
- **Capabilities** — tickets encriptados por dispositivo/rol

Lo único que cambia es **la capa que consulta los datos desde el frontend React** y **cómo se organizan los namespaces de iroh-docs.**

---

## El problema: privacidad de datos entre roles

Con el modelo actual (1 solo `data_doc` por org), **todos los peers con ticket Write sincronizan TODAS las entries.** No importa si rechazás un write a nivel aplicación — los datos YA viajaron por la red.

```
Problema con 1 data_doc:

  Alice (sales) tiene ticket Write de data_doc
  → iroh-docs sync le manda payroll, datos de Bob, TODO
  → Alice recibe datos que su rol no debería ver
  → La app puede ignorarlos, pero YA los recibió por la red
```

Esto es inaceptable para datos sensibles como nómina. La única forma de evitar que un peer reciba datos que no debe ver es que esos datos vivan en un **namespace separado** al que el peer no tenga ticket.

---

## Análisis: opciones de arquitectura de namespaces

### Opción A: 1 data_doc (actual)

```
Org ACME:
  control_doc   ← Read/Write: todos
  data_doc      ← Read/Write: todos
```

| Privacidad | Complejidad | Namespaces |
|-----------|-------------|------------|
| ❌ Ninguna. Todos reciben todo. | Mínima | 2 por org |

La app valida escrituras con `can_write()`, pero los datos viajan igual. Solo sirve si **todos los roles pueden ver todos los datos.**

### Opción B: Namespace por escritor (decision.md original)

```
Org ACME:
  control_doc
  products            ← Write: admin, Read: todos
  customers           ← Write: admin, Read: todos
  invoices_alice      ← Write: alice, Read: admin, contabilidad
  invoices_bob        ← Write: bob, Read: admin, contabilidad
  sales_notes_alice   ← Write: alice, Read: admin, contabilidad
  sales_notes_bob     ← Write: bob, Read: admin, contabilidad
  payroll             ← Write: admin, Read: admin, HR, contabilidad
  user_alice          ← Write: alice, Read: alice, admin
  user_bob            ← Write: bob, Read: bob, admin
```

| Privacidad | Complejidad | Namespaces |
|-----------|-------------|------------|
| ✅ Máxima. Cada usuario solo recibe sus datos + catálogos. | Alta. N namespaces a crear, tickets individuales. | ~10+ por org (crece con usuarios) |

Problema: 5 empleados = 15+ namespaces. Cada nuevo empleado = +2 namespaces. Mucha gestión.

### Opción C: Namespaces por nivel de seguridad (recomendada)

```
Org ACME — 6 namespaces fijos, independientes del número de empleados:

  control         ← Write: admin, Read: todos los miembros activos
  catalogs        ← Write: admin, Read: todos
  operational     ← Write: cada empleado (key prefix), Read: admin + contabilidad + rol
  payroll         ← Write: admin, Read: admin + HR + contabilidad
  private_<user>  ← Write: usuario, Read: usuario + admin
```

| Privacidad | Complejidad | Namespaces |
|-----------|-------------|------------|
| ✅ Alta. Sales no recibe payroll. | Media. 6 namespaces fijos. | 6 por org (no crece con usuarios) |

**Dentro de `operational`**, la separación entre usuarios se hace con key prefixes (como ahora). Alice y Bob escriben al mismo doc pero con keys distintas. La privacidad ENTRE empleados del mismo nivel de seguridad no es necesaria — ventas necesita ver las facturas de todos en ventas. La privacidad es ENTRE niveles (ventas no ve nómina).

**Dentro de `catalogs`**, solo admin escribe. Todos leen. Productos y clientes no son sensibles entre empleados de la misma org.

### Opción D: Content-addressed (por tipo de dato)

```
Org ACME:
  control
  products       ← 1 doc por catálogo
  customers      ← 1 doc por catálogo
  invoices       ← 1 doc, key prefix por usuario
  orders         ← 1 doc, key prefix por usuario
  payroll        ← 1 doc sensible
```

| Privacidad | Complejidad | Namespaces |
|-----------|-------------|------------|
| ✅ Similar a C. | Similar a C. | ~7 por org |

Difiere de C solo en granularidad (products separado de customers). La decisión es cuántos docs vs. cuántos key prefixes dentro de un doc.

### Comparativa

| Dimensión | A: 1 doc | B: por escritor | C: por seguridad | D: por tipo |
|-----------|----------|----------------|-----------------|-------------|
| Privacidad entre roles | ❌ | ✅ | ✅ | ✅ |
| Privacidad entre pares | ❌ | ✅ | ❌ (key prefix) | ❌ (key prefix) |
| Gestión de tickets | 2 | ~15+ | 6 | ~7 |
| Escala con empleados | No | Sí (lineal) | No | No |
| Complejidad de creación | Baja | Alta | Media | Media |
| accept_cb granularity | Doc-level | Doc-level | Doc-level | Doc-level |

---

## Recomendación: Opción C — Namespaces por nivel de seguridad

6 namespaces fijos por org. No crecen con la cantidad de empleados. La privacidad se garantiza a nivel de ticket de iroh-docs (no a nivel aplicación).

```
Org ACME:

  ┌─ control ─────────────────────────────────────────────┐
  │  members/<node_id>: { active, role }                   │
  │  roles/<name>: { can_open: [...], can_write: [...] }   │
  │  namespaces/: { status, writers, readers, capabilities }│
  │  Tickets: Read para todos los miembros activos          │
  └────────────────────────────────────────────────────────┘

  ┌─ catalogs ────────────────────────────────────────────┐
  │  products/: { name, sku, price }                       │
  │  customers/: { name, tax_id, address }                 │
  │  chart_of_accounts/: { code, name, type }              │
  │  Tickets: Read → todos, Write → admin                  │
  └────────────────────────────────────────────────────────┘

  ┌─ operational ─────────────────────────────────────────┐
  │  invoices/alice/evt:...  ← key prefix por usuario      │
  │  invoices/bob/evt:...                                  │
  │  orders/alice/evt:...                                  │
  │  sales_notes/bob/evt:...                               │
  │  Tickets: Read → admin + contabilidad + sales,         │
  │           Write → todos los roles con can_write        │
  └────────────────────────────────────────────────────────┘

  ┌─ payroll ─────────────────────────────────────────────┐
  │  payroll/evt:...                                       │
  │  Tickets: Read → admin + HR + contabilidad,            │
  │           Write → admin                                │
  └────────────────────────────────────────────────────────┘

  ┌─ private_alice ───────────────────────────────────────┐
  │  settings, preferences                                 │
  │  Tickets: Read → alice + admin, Write → alice          │
  └────────────────────────────────────────────────────────┘
```

**Por qué no B (namespace por escritor):**
- 5 empleados = 15+ namespaces. 50 empleados = 100+ namespaces.
- Cada nuevo empleado requiere crear 2+ docs, generar tickets, distribuirlos.
- La privacidad entre pares del mismo rol (Alice no ve facturas de Bob) no es un requisito real — en una empresa, ventas necesita ver las facturas de todo el equipo.

**Por qué no A (1 doc):**
- Sin privacidad. Sales recibe payroll por la red. Inaceptable.

---

## Implementación: qué cambia en el código

### Admin: `create_org()` crea 6 docs en vez de 2

```rust
// admin.rs — create_org actualizado
pub async fn create_org(state: &mut AppState, name: &str) -> anyhow::Result<()> {
    let api = state.api().clone();
    let author = state.author();

    // Crear los 6 namespaces
    let control_doc    = api.create().await?;
    let catalogs_doc   = api.create().await?;
    let operational_doc = api.create().await?;
    let payroll_doc    = api.create().await?;
    // private docs se crean por usuario en add_device()

    // Escribir metadata en control
    control_doc.set_bytes(author, format!("members/{}", node_id_hex), device_json).await?;
    control_doc.set_bytes(author, b"roles/admin", admin_role).await?;
    control_doc.set_bytes(author, b"org", org_json).await?;

    // Registrar namespaces en el registry para accept_cb
    state.map_namespace(control_doc.id(), name);
    state.map_namespace(catalogs_doc.id(), name);
    state.map_namespace(operational_doc.id(), name);
    state.map_namespace(payroll_doc.id(), name);

    state.add_org(name, control_doc, catalogs_doc, operational_doc, payroll_doc);
    Ok(())
}
```

### Admin: `add_device()` comparte tickets selectivos

```rust
// admin.rs — add_device actualizado
pub async fn add_device(state: &mut AppState, org: &str, node_id: &str, role: &str) {
    let org = state.get_org(org);
    let author = state.author();

    // Escribir member en control doc
    org.control_doc.set_bytes(author, format!("members/{}", node_id), device_json).await?;

    // Según el rol, compartir tickets de los namespaces que puede leer
    let grants = default_role_grants(role);

    // Tickets de lectura: solo los namespaces que can_open permite
    if grants.can_open.contains(&"catalogs".into()) {
        let ticket = org.catalogs_doc.share(ShareMode::Read, ...).await?;
        send_ticket_to_device(node_id, "catalogs", ticket);
    }
    if grants.can_open.contains(&"operational".into()) {
        let ticket = org.operational_doc.share(ShareMode::Write, ...).await?;
        send_ticket_to_device(node_id, "operational", ticket);
    }
    // payroll: solo admin, HR, contabilidad
    if grants.can_open.contains(&"payroll".into()) {
        let ticket = org.payroll_doc.share(ShareMode::Read, ...).await?;
        send_ticket_to_device(node_id, "payroll", ticket);
    }
    // control doc: siempre Read para todos los miembros activos
    let control_ticket = org.control_doc.share(ShareMode::Read, ...).await?;
    send_ticket_to_device(node_id, "control", control_ticket);

    // Crear namespace privado para el usuario
    let private_doc = api.create().await?;
    state.map_namespace(private_doc.id(), org);
    let private_ticket = private_doc.share(ShareMode::Write, ...).await?;
    send_ticket_to_device(node_id, "private", private_ticket);
}
```

### Client: `commit_event()` escribe al namespace correcto

```rust
// events.rs — actualizado para namespaces
pub fn commit_event(
    state: &AppState, event_type: &str, payload: &str,
) -> anyhow::Result<String> {
    let org = state.get_org(active_org)?;
    let node_id = state.node_id();

    // Elegir namespace según el tipo de evento
    let doc = match event_type {
        "invoice.created" | "invoice.updated" | "order.created" | "sales_note.created"
            => &org.operational_doc,

        "product.created" | "customer.created"
            => &org.catalogs_doc,

        "payroll.created"
            => &org.payroll_doc,

        _ => return Err(anyhow::anyhow!("unknown event_type: {}", event_type)),
    };

    // Validar permiso de escritura (registry ya tiene can_write)
    let can = state.registry().read().unwrap()
        .can_write(&org_id.into(), &node_id, namespace_name);
    if !can {
        return Err(anyhow::anyhow!("Write denied: role cannot write to this namespace"));
    }

    // Escribir con key prefix del usuario
    let key = format!("{}/{}/{}/{}", event_type.split('.').next().unwrap(), node_id_hex, hlc.to_key_prefix(), event_type);
    doc.set_bytes(author, key, value).await?;
    Ok(key)
}
```

### Role grants actualizados

```rust
fn default_role_grants(role: &str) -> RoleGrants {
    match role {
        "admin" => RoleGrants {
            can_open: vec!["control", "catalogs", "operational", "payroll", "private_*"],
            can_write: vec!["catalogs", "operational", "payroll"],
        },
        "sales" => RoleGrants {
            can_open: vec!["control", "catalogs", "operational", "private_*"],
            can_write: vec!["operational"],
        },
        "contabilidad" => RoleGrants {
            can_open: vec!["control", "catalogs", "operational", "payroll", "private_*"],
            can_write: vec![],  // solo lectura
        },
        "hr" => RoleGrants {
            can_open: vec!["control", "catalogs", "payroll", "private_*"],
            can_write: vec!["payroll"],
        },
        _ => RoleGrants { can_open: vec![], can_write: vec![] },
    }
}
```

---

## Módulos del ERP: mapeo namespaces → collections de TanStack DB

Con la Opción C, cada namespace de iroh-docs alimenta una o más collections de TanStack DB:

| Namespace iroh-docs | TanStack DB collection | Entradas |
|---------------------|----------------------|----------|
| `catalogs` | `productsCollection` | `products/...` |
| `catalogs` | `customersCollection` | `customers/...` |
| `catalogs` | `chartAccountsCollection` | `chart_of_accounts/...` |
| `operational` | `invoicesCollection` | `invoices/<user>/...` de todos los usuarios |
| `operational` | `ordersCollection` | `orders/<user>/...` de todos los usuarios |
| `operational` | `salesNotesCollection` | `sales_notes/<user>/...` de todos los usuarios |
| `payroll` | `payrollCollection` | `payroll/...` |
| `private_<user>` | `userSettingsCollection` | settings, preferences |

**El adapter ya no mergea múltiples namespaces** para transactional data. En vez de `invoices_alice` + `invoices_bob`, ahora es UN solo namespace `operational` con key prefixes. El adapter solo filtra por key prefix dentro del namespace.

---

## Resumen visual final

```
Org ACME:

  iroh-docs (redb)                         TanStack DB (memoria)
  ────────────────                         ────────────────────

  control ───────────────────────────►     (no es collection)

  catalogs ─┬────────────────────────►     productsCollection
            ├────────────────────────►     customersCollection
            └────────────────────────►     chartAccountsCollection

  operational ─┬─────────────────────►     invoicesCollection
               ├─────────────────────►     ordersCollection
               └─────────────────────►     salesNotesCollection

  payroll ───────────────────────────►     payrollCollection

  private_alice ─────────────────────►     userSettingsCollection
  private_bob   ─────────────────────►     userSettingsCollection

  6 namespaces fijos. No crecen con empleados.
  Privacidad a nivel de ticket iroh-docs.
  Separación entre usuarios vía key prefix dentro del namespace.
```

---

## Resumen

| Capa | Tecnología | ¿Cambió? |
|------|-----------|----------|
| Sync P2P | iroh-docs | No |
| Storage | redb | No |
| **Namespaces** | **6 por org (nivel de seguridad)** | **Sí (antes 2)** |
| Capabilities | syntrix-docs (encrypt/decrypt) | No |
| accept_cb | Bloquea por namespace + active | No |
| **Query layer** | **TanStack DB + adapter** | **Sí (antes LiveStore)** |
| Validación | Zod schema por collection | Nuevo |
| Migraciones | deserializeEntry() | Nuevo |

**El merge ya no es N namespaces → 1 collection, sino 1 namespace → 1+ collections con filtro por key prefix.** El adapter itera las keys del namespace y las distribuye en las collections correspondientes según el prefix. Sin SQL, sin WASM, sin Effect-TS. Y con privacidad real entre roles gracias a tickets selectivos de iroh-docs.
