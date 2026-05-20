# UNAgent — Performance Testing

## Estructura

```
performance/
├── llm-mock/           Node.js mock OpenAI-compatible (800 ms fijo)
├── k6/
│   └── chat-load-test.js   Script k6, rampa 10→50→100→200→500 VUs, 10 min
├── grafana/
│   ├── provisioning/   Auto-provisiona datasource InfluxDB + dashboard
│   └── dashboards/     JSON del dashboard "UNAgent — k6 Chat Load Test"
└── results/            Salida JSON de cada ejecución (gitignored)

docker-compose.perf.yml   Overlay: redirige LLM calls al mock + agrega
                          InfluxDB, k6, provisioning de Grafana.
```

## Cómo correr las pruebas

### 1. Levantar el stack con el mock

```bash
# Desde la raíz del repo
docker compose -f docker-compose.yml -f docker-compose.perf.yml up -d --build
```

Esto:
- Construye e inicia todos los servicios de producción.
- Reemplaza `OPENAI_BASE_URL` en **chat-orch**, **agent-runtime** y
  **conversation-chat** para que apunten al `llm-mock` local en vez de
  OpenRouter.
- Levanta InfluxDB (`:8086`) y Grafana (`:3001`) con el dashboard
  pre-aprovisionado.

### 2. Verificar que los servicios estén listos

```bash
docker compose -f docker-compose.yml -f docker-compose.perf.yml ps
```

Todos los servicios deben estar en estado `healthy` o `running`. Espera
~30-60 segundos después del primer boot.

```bash
# Smoke test manual
curl -s http://localhost:9999/health    # llm-mock
curl -s http://localhost:8000/health   # chat-orch
```

### 3. Ejecutar el test de carga

```bash
docker compose -f docker-compose.yml -f docker-compose.perf.yml \
  --profile k6 run --rm k6
```

k6 imprime un resumen al final en stdout y escribe
`performance/results/summary.json`.

### 4. Ver la curva en tiempo real

Abre **http://localhost:3001** → usuario `admin` / contraseña `admin`
→ dashboard **"UNAgent — k6 Chat Load Test"**.

El dashboard se refresca cada 5 segundos y muestra:
- VUs activos y throughput (req/s)
- P50 / P90 / P95 / P99 de `chat_e2e_latency_ms`
- Tasa de errores HTTP

### 5. Limpiar

```bash
# Detener sin borrar volúmenes (preserva datos de InfluxDB/Grafana)
docker compose -f docker-compose.yml -f docker-compose.perf.yml down

# Borrar también los volúmenes de perf
docker compose -f docker-compose.yml -f docker-compose.perf.yml down -v
```

---

## Configuración avanzada

| Variable de entorno | Default | Descripción |
|---|---|---|
| `LLM_MOCK_DELAY_MS` | `800` | Latencia fija simulada del LLM (ms) |
| `K6_VERBOSE`        | `0`   | Ponlo en `1` para loggear cada request fallido |

Ejemplo para probar con 400 ms:
```bash
LLM_MOCK_DELAY_MS=400 docker compose -f docker-compose.yml -f docker-compose.perf.yml up -d --build
```

---

## Perfil de carga

| Etapa | Duración | VUs objetivo |
|---|---|---|
| Ramp 1 | 1 min | 10 |
| Hold 1 | 1 min | 10 |
| Ramp 2 | 1 min | 50 |
| Hold 2 | 1 min | 50 |
| Ramp 3 | 1 min | 100 |
| Hold 3 | 1 min | 100 |
| Ramp 4 | 1 min | 200 |
| Hold 4 | 1 min | 200 |
| Ramp 5 | 1 min | 500 |
| Hold 5 | 1 min | 500 |
| **Total** | **10 min** | — |

---

## Umbrales (thresholds)

El test falla si:
- Tasa de errores HTTP > 5 %
- `http_req_duration` P95 > 5 000 ms
- `chat_e2e_latency_ms` P95 > 5 000 ms

Con el mock de 800 ms el P95 esperado es ~1 000–1 200 ms en condiciones normales.
Latencias por encima indican contención en algún servicio del stack.

---

## Notas sobre el mock LLM

El mock devuelve respuestas sin `tool_calls`, por lo que el loop de
herramientas de `chat-orch` termina en la primera ronda. Esto mantiene
el comportamiento determinista y evita side-effects en `hospital-mock`
durante las pruebas de rendimiento.

Para probar el path con llamadas a herramientas, modifica `server.js`
para devolver un `tool_calls` apuntando a `list_doctors`.
