# Capa de datos: decisión de arquitectura

## La arquitectura base NO cambia

La arquitectura de permisos y sync definida en `syntrix-client/DESIGN.md` y `syntrix-admin/DESIGN.md` se mantiene intacta:

- **Namespaces por escritor** — cada empleado escribe a su propio namespace de iroh-docs
- **Control doc** — `org_control` define roles, permisos, capabilities
- **accept_cb** — bloquea sync de peers inactivos
- **iroh-docs** — sync P2P entre dispositivos

Lo único que cambia es **la capa que consulta los datos desde el frontend React.**

---

## Módulos del ERP: todas las collections

El ERP tiene varios módulos. En iroh-docs, los datos están repartidos en múltiples namespaces. En TanStack DB, **cada tipo de dato es UNA collection que mergea todos los namespaces de ese tipo.**

| Módulo | TanStack DB collection | Namespaces que mergea | ¿Quién escribe? |
|--------|----------------------|----------------------|-----------------|
| Facturas | `invoicesCollection` | `org_acme/invoices_alice`, `org_acme/invoices_bob` | Cada empleado en su namespace |
| Productos | `productsCollection` | `org_acme/products` | Solo admin |
| Clientes | `customersCollection` | `org_acme/customers` | Solo admin |
| Plan de cuentas | `chartAccountsCollection` | `org_acme/chart_of_accounts` | Solo admin |
| Nómina | `payrollCollection` | `org_acme/payroll` | Solo admin |
| Notas de venta | `salesNotesCollection` | `org_acme/sales_notes_alice`, `org_acme/sales_notes_bob` | Cada empleado en su namespace |
| Gastos | `expensesCollection` | `org_acme/expenses_alice`, `org_acme/expenses_bob` | Cada empleado en su namespace |
| Usuarios | `usersCollection` | `org_acme/user_alice`, `org_acme/user_bob` | Cada empleado en su namespace |

**Patrón:** los catálogos (productos, clientes, plan de cuentas) tienen 1 namespace → 1 collection. Los transaccionales (facturas, notas de venta, gastos) tienen N namespaces → 1 collection.

---

## El merge: de N namespaces a 1 collection

Ejemplo con **facturas.** Alice y Bob escriben cada uno en su namespace. Contabilidad necesita ver todo junto.

### Cómo funciona

```
iroh-docs (redb):

  org_acme/invoices_alice/          org_acme/invoices_bob/
  ┌──────────────────────────┐      ┌──────────────────────────┐
  │ evt:001 → { id:"inv-1",  │      │ evt:001 → { id:"inv-2",  │
  │            customer:4,   │      │            customer:7,   │
  │            amount:100 }  │      │            amount:150 }  │
  │ evt:002 → { id:"inv-3",  │      │                          │
  │            customer:2,   │      │                          │
  │            amount:200 }  │      │                          │
  └──────────┬───────────────┘      └──────────┬───────────────┘
             │                                 │
             │    adapter.merge()              │
             │    lee entries de ambos         │
             │    namespaces y las mete        │
             │    en la misma collection       │
             │                                 │
             ▼                                 ▼
             ┌─────────────────────────────────────┐
             │  TanStack DB: invoicesCollection     │
             │                                     │
             │  [                                  │
             │    {id:"inv-1", customer:4,         │
             │     amount:100, _author:"alice"},   │
             │    {id:"inv-3", customer:2,         │
             │     amount:200, _author:"alice"},   │
             │    {id:"inv-2", customer:7,         │
             │     amount:150, _author:"bob"},     │
             │  ]                                  │
             │                                     │
             │  queries normales:                  │
             │  useLiveQuery((q) =>                │
             │    q.from({inv: invoicesCollection})│
             │     .where(eq(inv.status,'open'))   │
             │     .orderBy(inv.date, 'desc')      │
             │  )                                  │
             └─────────────────────────────────────┘
```

No hay `UNION ALL`. No hay SQL. Es un loop que lee entries de namespaces y las pasa a la misma collection.

### El adapter para facturas

```typescript
function createInvoicesCollection(orgId: string) {

  return createCollection(irohCollectionOptions({

    dataType: "invoices",
    schema: invoiceSchema,

    // ── Sync: carga entries de TODOS los namespaces de invoices ──
    sync: ({ begin, write, commit, markReady }) => {

      // Pregunta a org_control: ¿qué namespaces de invoices puede leer este rol?
      const namespaces = getReadableNamespaces(orgId, "invoices")
      // contabilidad → ["org_acme/invoices_alice", "org_acme/invoices_bob"]
      // alice       → ["org_acme/invoices_alice"]  (solo el suyo)

      begin()
      for (const ns of namespaces) {
        const entries = invoke("sync_pull", { namespace: ns })
        for (const entry of entries) {
          write({ type: "insert", value: deserializeEntry(entry, ns) })
        }
      }
      commit()
      markReady()

      // Tiempo real: nuevas entradas de peers
      return listen("data-changed", (event) => {
        begin()
        write({ type: "insert", value: deserializeEntry(event.entry, event.ns) })
        commit()
      })
    },

    // ── Mutaciones: siempre escribe a TU namespace ──
    onInsert: async ({ transaction }) => {
      const entry = transaction.mutations[0].modified
      await invoke("commit_event", {
        namespace: `org_${orgId}/invoices_${currentUser}`,
        event: { type: "invoice.created", payload: entry }
      })
    },
  }))
}
```

### El mismo patrón para todos los módulos

```typescript
// Facturas — N namespaces, 1 collection
const invoices = createInvoicesCollection("acme")

// Productos — 1 namespace, 1 collection
const products = createCollection(
  irohCollectionOptions({ dataType: "products", ... })
)

// Clientes — 1 namespace, 1 collection
const customers = createCollection(
  irohCollectionOptions({ dataType: "customers", ... })
)

// Notas de venta — N namespaces, 1 collection
const salesNotes = createCollection(
  irohCollectionOptions({ dataType: "sales_notes", ... })
)
```

Todas usan el mismo `irohCollectionOptions`. La única diferencia es `dataType` — el adapter internamente consulta `org_control` para saber qué namespaces pertenecen a ese tipo de dato.

### Queries con joins entre collections

Como son collections separadas, TanStack DB permite hacer joins entre ellas:

```typescript
// Factura con nombre del cliente (join invoices + customers)
const { data } = useLiveQuery((q) =>
  q.from({ inv: invoices })
   .join({ cust: customers },
     ({ inv, cust }) => eq(inv.customer_id, cust.id), "inner")
   .where(({ inv }) => eq(inv.status, "open"))
   .select(({ inv, cust }) => ({
     id: inv.id,
     amount: inv.amount,
     customerName: cust.name,    // del catálogo
     author: inv._author,
   }))
)
```

---

## Resumen visual: mapeo namespaces → collections

```
iroh-docs (redb)                         TanStack DB (memoria)
────────────────                         ────────────────────

org_acme/
  ├── control ──────────────────────►    (no es collection, es metadata)
  │
  ├── invoices_alice ───┐
  ├── invoices_bob   ───┼──────────►    invoicesCollection
  │                      │              (3 entradas mergeadas)
  │                      │
  ├── products ──────────┼──────────►    productsCollection
  │                      │              (500 productos)
  ├── customers ─────────┼──────────►    customersCollection
  │                      │              (200 clientes)
  ├── payroll ───────────┼──────────►    payrollCollection
  │                      │              (10 empleados)
  ├── sales_notes_alice ─┤
  └── sales_notes_bob ───┼──────────►    salesNotesCollection
                         │              (merge de ambos)
                         │
                    EL ADAPTER
                  (~200 líneas de JS)

Cada collection:
  - schema Zod que valida al insertar
  - useLiveQuery para consultas reactivas
  - insert/update/delete con optimistic state
```

---

## Validación y migraciones

**Validación:** schema Zod en cada collection:

```typescript
const invoiceSchema = z.object({
  id: z.string(),
  amount: z.number().positive(),
  status: z.enum(["draft", "open", "paid", "cancelled"]),
  customer_id: z.string(),
  date: z.string().transform(s => new Date(s)),
})
```

**Migraciones:** se aplican al deserializar, sin tocar los datos en redb:

```typescript
function deserializeEntry(raw: RawEntry, namespace: string): Invoice {
  const v = JSON.parse(raw.value)

  // v1 → v2: campo tax_rate no existía, default 0.16
  if (!("tax_rate" in v)) v.tax_rate = 0.16

  // v2 → v3: el campo "client" pasó a ser "customer_id"
  if ("client" in v) { v.customer_id = v.client; delete v.client }

  return invoiceSchema.parse({ ...v, _namespace: namespace, _author: raw.author })
}
```

---

## Resumen

| Capa | Tecnología | ¿Cambió? |
|------|-----------|----------|
| Sync P2P | iroh-docs | No |
| Storage | redb | No |
| Permisos | org_control + accept_cb | No |
| Capabilities | syntrix-docs (encrypt/decrypt) | No |
| **Query layer** | **TanStack DB + adapter** | **Sí (antes LiveStore)** |
| Validación | Zod schema por collection | Nuevo |
| Migraciones | deserializeEntry() | Nuevo |

**El merge ES un loop, no un UNION ALL.** El adapter itera los namespaces que el rol puede leer y mete todas las entradas en la misma collection. Una collection por tipo de dato. Queries y joins normales de TanStack DB. Sin SQL, sin WASM, sin Effect-TS.
