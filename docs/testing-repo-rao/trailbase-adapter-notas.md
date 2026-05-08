# TrailBase Adapter - Notas de validacion

## Objetivo
Este documento resume todo lo revisado sobre el adapter de TrailBase en TanStack DB, incluyendo comportamiento real de sync, persistencia, carga por queries, traduccion de filtros y comportamiento al navegar entre pantallas.

## Resumen ejecutivo
- El adapter de TrailBase no persiste en disco por si solo: opera en memoria (estado de la coleccion en runtime).
- Hay dos modos de sync relevantes: `eager` y `on-demand`.
- En `on-demand`, cada subset solicitado por queries se incorpora a la coleccion compartida.
- El adapter tambien escucha stream global (`subscribe("*")`), por lo que pueden entrar cambios aunque una query puntual no se haya ejecutado.
- La traduccion de query de TanStack DB a API TrailBase existe, pero es parcial (principalmente comparaciones simples).
- Si desmontas una pagina/query y vuelves, normalmente se vuelve a solicitar snapshot/subset (no queda cacheado por query de forma persistente por el adapter).

## 1) Persistencia: memoria vs disco

### Que hace hoy
- El adapter sincroniza datos hacia el estado de la coleccion en TanStack DB.
- No implementa una capa de persistencia local (por ejemplo IndexedDB/SQLite/localStorage) en este paquete.

### Implicacion
- Si se reinicia la app o se recarga el runtime, el estado en memoria se pierde y debe resincronizarse.

## 2) Modos de sync

### `eager`
- Flujo: suscribe al stream y realiza carga inicial completa.
- Efecto: la coleccion se llena al inicio con todo el conjunto (segun lo que entregue la API), luego mantiene cambios en tiempo real.
- Conveniente para tablas pequenas/medianas o cuando necesitas respuestas locales rapidas despues de arrancar.

### `on-demand`
- Flujo: no carga todo por defecto; carga subsets cuando una suscripcion/query lo pide via `loadSubset`.
- Efecto: menor costo inicial, pero se hacen requests conforme las pantallas/queries demandan datos.
- Conveniente para tablas grandes y escenarios con paginacion/filtros.

## 3) En `on-demand`, los resultados se acumulan?

Si, con una precision importante:
- Los resultados cargados por cada `loadSubset` se escriben como inserts/updates/deletes sobre la coleccion compartida.
- No es un cache aislado por query; es estado compartido de la coleccion.
- Si una fila ya existe por key, nuevos eventos la actualizan/sobrescriben en el estado.

En la practica:
- Query A carga subset A -> entra al estado.
- Query B carga subset B -> tambien entra al mismo estado.
- La vista final de cada query sigue su propio filtro, pero la base de datos local en memoria va creciendo con lo ya visto/sincronizado.

## 4) Traduccion de queries hacia TrailBase API

El pipeline general es:
1. TanStack DB arma `LoadSubsetOptions` (where/orderBy/limit/cursor/offset).
2. El adapter convierte esos parametros a `recordApi.list(...)` de TrailBase.

### Soporte verificado
- `orderBy` por referencias simples se convierte a formato de TrailBase (`+campo` / `-campo`).
- Operadores de comparacion simples en `where`:
  - eq -> equal
  - ne -> notEqual
  - gt -> greaterThan
  - gte -> greaterThanEqual
  - lt -> lessThan
  - lte -> lessThanEqual
- Serializacion de valores por columna usando `config.serialize` cuando existe conversion.
- Booleanos se normalizan a `1/0`.

### Limites actuales
- No toda expresion compleja de `where` esta soportada.
- Cuando una clausula no soportada aparece, el adapter hace warning y puede terminar sin filtro server-side equivalente para esa parte.

## 5) Stream en tiempo real y su impacto

El adapter se suscribe a eventos globales (`subscribe("*")`).
Esto implica:
- Inserts/updates/deletes del backend pueden entrar a la coleccion aunque no hayas lanzado una query especifica para esas filas.
- En `on-demand`, el subset inicial depende de queries, pero el stream puede ampliar/modificar estado despues.

## 6) Navegacion entre paginas: vuelve a pedir o no?

### Caso comun (si)
Si la live query/subscription se desmonta al salir de la pagina:
- Al regresar, se crea una suscripcion nueva.
- Se vuelve a disparar `requestSnapshot`/`loadSubset` para esa consulta.
- Por lo tanto, normalmente hay nuevo request.

### Cuando podria NO volver a pedir
- Si la suscripcion nunca se desmonta (por ejemplo, vive en un layout/global store persistente), entonces puede reutilizarse estado ya activo en memoria.

### Nota TrailBase especifica
- El ciclo de suscripcion en core contempla `unloadSubset` al desuscribir.
- En este adapter no hay una implementacion propia de `unloadSubset` para mantener semantica de cache por subset entre montajes.
- Resultado practico: al remount, no se considera "ya fetchiada" de forma persistente por ese mecanismo.

## 7) Recomendaciones practicas para testing

1. Medir requests al navegar ida/vuelta
- Instrumenta `recordApi.list` (spy/log) y verifica si se invoca nuevamente al remount.

2. Probar diferencia entre mantener viva la query vs desmontarla
- Escenario A: componente se desmonta completamente.
- Escenario B: query en scope superior (layout/store) que no se desmonta.

3. Validar push-down de filtros
- Construye casos con `eq/ne/gt/gte/lt/lte` y confirma que el backend recibe filtros.
- Agrega un caso con expresion compleja para observar warning/fallback.

4. Confirmar impacto del stream global
- Inserta/actualiza registros desde otra sesion y valida entrada en la coleccion local aun sin relanzar cierta query.

## 8) Decision guide rapido

Usa `eager` cuando:
- dataset manejable,
- UX requiere disponibilidad local inmediata,
- menos roundtrips durante navegacion.

Usa `on-demand` cuando:
- dataset grande,
- filtros/paginacion dominan el flujo,
- aceptas requests al entrar en vistas y/o al remount.

## 9) Conclusiones finales
- El adapter actual esta orientado a sincronizacion en memoria + stream en tiempo real.
- `on-demand` reduce carga inicial pero no equivale a "cache eterna por query".
- La traduccion de query a TrailBase funciona bien en casos simples; para expresiones avanzadas hay que validar push-down caso por caso.

## 10) Como usarlo en conjunto con TanStack DB (bases)

Esta seccion es una guia practica para implementarlo de forma correcta desde cero.

### 10.1 Setup minimo de una coleccion

```ts
import { createCollection } from '@tanstack/db'
import { trailBaseCollectionOptions } from '@tanstack/trailbase-db-collection'
import { initClient } from 'trailbase'

type Todo = {
  id: string
  title: string
  done: boolean
  createdAt: Date
}

type TodoRecord = {
  id: string
  title: string
  done: number
  createdAt: string
}

const client = initClient('http://localhost:4000')
const todosApi = client.records<TodoRecord>('todos')

export const todosCollection = createCollection(
  trailBaseCollectionOptions<Todo, TodoRecord>({
    id: 'todos',
    recordApi: todosApi,
    getKey: (item) => item.id,
    startSync: true,
    syncMode: 'on-demand', // o 'eager'
    parse: {
      done: (v) => Boolean(v),
      createdAt: (v) => new Date(v),
    },
    serialize: {
      done: (v) => (v ? 1 : 0),
      createdAt: (v) => v.toISOString(),
    },
  }),
)
```

Puntos base de esta configuracion:
- `parse` transforma del tipo TrailBase al tipo de app.
- `serialize` transforma del tipo de app al tipo de TrailBase.
- `getKey` debe ser estable y unico.
- `startSync: true` inicia sync apenas hay suscripciones.

### 10.2 Elegir modo de sync desde el diseno

Usa `eager` cuando:
- Quieres datos completos en memoria al inicio.
- El volumen es manejable.
- Priorizas UX inmediata tras arranque.

Usa `on-demand` cuando:
- El volumen es grande.
- Tu UI navega por subsets (filtros/paginacion).
- Aceptas requests al entrar/remontar vistas.

Regla simple:
- Si la tabla podria crecer mucho, empieza con `on-demand`.
- Si siempre necesitas casi todo para operar, `eager` suele ser mas simple.

### 10.3 Patron recomendado en UI

1. Deja la coleccion en un modulo singleton.
2. Crea live queries por pantalla.
3. Evita desmontar/montar en bucle una query pesada si no hace falta.
4. Si necesitas retener estado entre rutas, sube la query a un scope persistente (layout/store superior).

Esto reduce refetches por remount en `on-demand`.

### 10.4 Mutaciones correctas (insert/update/delete)

El adapter ya hace el flujo optimista + confirmacion por stream:
- Inserta/actualiza/elimina en TrailBase.
- Espera el evento de suscripcion para confirmar en estado local.

Recomendacion:
- Usa siempre las mutaciones de la coleccion (no mezclar writes directos al estado local por fuera del flujo).

### 10.5 Filtros y push-down: que si y que no

Para aprovechar `on-demand`:
- Prioriza filtros simples comparativos (`eq/ne/gt/gte/lt/lte`).
- Prioriza `orderBy` por campos directos.

Evita asumir que:
- Cualquier expresion compleja se convertira 1:1 al backend.

Si agregas expresiones complejas:
- Verifica logs/warnings.
- Asegura tests que inspeccionen parametros enviados a `recordApi.list`.

### 10.6 Checklist base para produccion

1. Definir `syncMode` por tabla (no una sola regla para todo).
2. Confirmar conversiones `parse/serialize` de fechas, booleans, bigint, json, ids.
3. Instrumentar requests de `list` para detectar refetches inesperados.
4. Testear navegacion ida/vuelta para vistas clave.
5. Testear comportamiento ante eventos externos por stream.
6. Documentar que la persistencia local no viene incluida en este adapter.
7. Si necesitas offline real, combinar con una estrategia de persistencia local adicional.

### 10.7 Errores comunes

- Pensar que `on-demand` cachea por query para siempre.
- No serializar correctamente tipos (especialmente `Date`, `boolean`, `bigint`, `json`).
- Esperar push-down completo con where complejos sin testear.
- Hacer `preload` de coleccion esperando comportamiento de carga total en `on-demand`.

### 10.8 Con esta base, que ya queda claro?

Si: para usar TrailBase adapter con TanStack DB en escenarios reales, este documento ya cubre las bases tecnicas y operativas.

Para cerrar al 100% en tu proyecto solo faltaria:
- decidir por tabla `eager` vs `on-demand`,
- formalizar tests de refetch/navegacion,
- definir si necesitas una capa de persistencia local aparte.
