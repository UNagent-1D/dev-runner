# UNAgent — Guía de Pruebas de Rendimiento

## ¿Qué es k6?

[k6](https://k6.io) es una herramienta de pruebas de carga escrita en Go. Cada *Virtual User* (VU)
es una goroutine ligera que ejecuta el script en un loop continuo. El script
`performance/k6/chat-load-test.js` envía `POST /v1/chat` a **chat-orch** con mensajes de
agendamiento médico simulados, mide la latencia de extremo a extremo y registra métricas
personalizadas (`chat_e2e_latency_ms`, `chat_error_rate`, `chat_total_requests`).

El LLM externo (OpenRouter) es reemplazado por un **mock local** (`llm-mock`, Node.js/Express)
con un retardo fijo de 800 ms, eliminando la varianza de la red externa. Cualquier latencia
adicional sobre esos 800 ms es costo puro de la plataforma.

---

## Perfil de carga

| Etapa | Duración | VUs |
|---|---|---|
| Ramp → 10 | 1 min | 10 |
| Hold 10 | 1 min | 10 |
| Ramp → 50 | 1 min | 50 |
| Hold 50 | 1 min | 50 |
| Ramp → 100 | 1 min | 100 |
| Hold 100 | 1 min | 100 |
| Ramp → 200 | 1 min | 200 |
| Hold 200 | 1 min | 200 |
| Ramp → 500 | 1 min | 500 |
| Hold 500 | 1 min | 500 |
| Ramp → 750 | 1 min | 750 |
| Hold 750 | 1 min | 750 |
| Ramp → 1 000 | 1 min | 1 000 |
| Hold 1 000 | 1 min | 1 000 |
| Ramp → 2 000 | 1 min | 2 000 |
| Hold 2 000 | 1 min | 2 000 |
| **Total** | **16 min** | máx. 2 000 |

---

## Comandos para correr las pruebas

### 1. Levantar el stack completo con el mock LLM

```bash
sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml up -d --build
```

Espera ~30–60 s hasta que todos los servicios estén `healthy`. Verifica con:

```bash
sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml ps
# Smoke test
curl -s http://localhost:9999/health   # llm-mock
curl -s http://localhost:8000/health   # chat-orch
```

### 2. (Opcional) Limpiar sesiones acumuladas de MongoDB entre tandas

Si ya corriste el test antes y quieres empezar con una DB limpia:

```bash
sudo docker exec archsoft-email-mongo mongosh --quiet \
  --eval 'db.getSiblingDB("perf_conversatory").dropDatabase()'
```

> No borres el volumen de InfluxDB (`influxdb-perf-data`) — ahí quedan los datos
> de todas las tandas para generar las curvas después.

### 3. Lanzar k6

```bash
sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml \
  --profile k6 run --rm k6
```

El test dura **16 minutos**. Al terminar imprime un resumen en stdout y escribe
`performance/results/summary.json`.

Para ver cada request fallido en tiempo real agrega `K6_VERBOSE=1`:

```bash
K6_VERBOSE=1 sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml \
  --profile k6 run --rm k6
```

### 4. Bajar el stack (preservando volúmenes)

```bash
sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml down
```

Para borrar **también** los volúmenes de performance (InfluxDB, Grafana):

```bash
sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml down -v
```

---

## Ver resultados en Grafana (tiempo real)

Abre **[http://localhost:3001](http://localhost:3001)** durante o después del test.

| Campo | Valor |
|---|---|
| URL | http://localhost:3001 |
| Usuario | `admin` |
| Contraseña | `admin` |
| Dashboard | **UNAgent — k6 Chat Load Test** |

El dashboard se actualiza cada 5 segundos y muestra:

- VUs activos y throughput (req/s)
- Latencia P50 / P90 / P95 / P99
- Tasa de errores HTTP

---

## Generar la curva de rendimiento

El script `performance/generate_curve.py` consulta InfluxDB y produce una imagen PNG
con la curva **Latencia promedio vs. VUs** y el panel de **tasa de errores**.

### Requisitos

```bash
pip install requests matplotlib numpy
```

InfluxDB debe estar corriendo (`sudo docker compose ... up -d` incluye InfluxDB).

### Añadir el rango de tiempo de la nueva tanda

Después de cada test, anota los timestamps de inicio y fin de la tanda en InfluxDB y
agrégalos al diccionario `RUNS` en el script:

```python
# performance/generate_curve.py
RUNS = {
    ...
    8: (1779224665000000000, 1779225393000000000, "Tanda 8 — 16 min, max 2000 VUs"),
}
```

Los timestamps están en nanosegundos UTC. Puedes obtenerlos consultando InfluxDB:

```bash
curl -s "http://localhost:8086/query?db=k6&q=SELECT+FIRST(value)+FROM+vus+GROUP+BY+time(1h)" \
  | python3 -m json.tool | grep time
```

O usa el panel de Grafana — el borde izquierdo y derecho del gráfico de VUs dan los
tiempos de inicio y fin.

### Generar la curva

```bash
# Última tanda registrada en RUNS (default=7, ajusta al número actual)
python3 performance/generate_curve.py

# Tanda específica
python3 performance/generate_curve.py --run 8
```

La imagen se guarda en `performance/results/curva_rendimiento_run<N>.png` y se abre
automáticamente.

---

## Variables de entorno relevantes

| Variable | Default | Descripción |
|---|---|---|
| `LLM_MOCK_DELAY_MS` | `800` | Retardo fijo del mock LLM (ms) |
| `K6_VERBOSE` | `0` | `1` = loggear cada request fallido |

Ejemplo: test con mock más rápido (200 ms) para comparar overhead:

```bash
LLM_MOCK_DELAY_MS=200 sudo docker compose -f docker-compose.yml -f docker-compose.perf.yml \
  up -d --build
```

---

## Estructura de archivos relevantes

```
performance/
├── k6/
│   └── chat-load-test.js       Script k6 (rampa 10→2000 VUs, 16 min)
├── llm-mock/
│   └── server.js               Mock OpenAI-compatible (retardo configurable)
├── grafana/
│   ├── provisioning/           Auto-provisiona datasource InfluxDB
│   └── dashboards/             JSON del dashboard pre-cargado
├── results/
│   ├── summary.json            Salida JSON de la última ejecución k6
│   └── curva_rendimiento_run*.png   Curvas generadas por generate_curve.py
├── generate_curve.py           Script de análisis y visualización
└── PERFORMANCE.md              Análisis completo de resultados

docker-compose.perf.yml         Overlay: mock LLM + InfluxDB + k6 + Grafana
```
