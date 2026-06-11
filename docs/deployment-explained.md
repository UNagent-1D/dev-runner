# Cómo se desplegó UNAgent y cómo funciona (explicación completa)

Compañera de `docs/gke-deployment.md` (que tiene las tablas y puertos para el
diagrama). Este documento cuenta la historia: qué desplegamos, cómo, y por qué
cada decisión. Actualizado 2026-06-10, ya en GKE (Railway eliminado).

---

## 1. Qué es lo que se despliega

UNAgent son **13 programas cooperando**: 8 servicios propios (chat-orch,
conversation-chat, agent-runtime, tenant, user-auth, hospital-mock, compliance,
email-send) + 5 almacenes de datos estándar (2 Postgres, 2 Mongo, Redis,
RabbitMQ — 6 contando ambos Mongo). Ninguno es "la aplicación" por sí solo: la
aplicación es la conversación entre ellos. El problema de despliegue es:
ejecutar 13 programas, conectarlos, mantenerlos vivos, y exponer al internet
exactamente **una puerta** por ambiente.

## 2. Empaquetado: del código a la imagen

Cada servicio tiene un `Dockerfile`: una receta que compila el código y lo
congela —con su runtime y dependencias— en una **imagen** (instantánea
inmutable y portable; la de chat-orch pesa ~89 MB y contiene el binario Rust
compilado). `make -C k8s gke-build TAG=<sha>` construye las 10 imágenes y las
sube a **Artifact Registry** (el almacén privado de imágenes de Google). El tag
es el hash del commit: todo contenedor corriendo es trazable al código exacto
que lo produjo, y "rollback" = desplegar el tag anterior.

Ejemplo ilustrativo, el Dockerfile del frontend (multi-stage):

```dockerfile
FROM node:22-alpine AS builder        # etapa 1: compila el SPA (solo en build)
FROM nginx:alpine AS runner           # etapa 2: la imagen final ES nginx
COPY --from=builder /app/dist /usr/share/nginx/html   # estáticos como archivos
COPY nginx.conf /etc/nginx/conf.d/default.conf        # reglas de ruteo
CMD ["nginx", "-g", "daemon off;"]    # único proceso del contenedor
```

Node existe solo durante la compilación; en producción no corre React ni Node:
corre **nginx** sirviendo archivos ya compilados y enrutando APIs.

## 3. El cluster: músculo alquilado + un bucle de reconciliación

`gcloud container clusters create unagent ...` alquiló **3 máquinas virtuales**
(e2-standard-2: 2 vCPU / 8 GB cada una) en `us-central1-a` y les instaló
Kubernetes. El trabajo de Kubernetes es un solo bucle: *tú declaras el estado
deseado; él hace que la realidad coincida*. Nunca arrancamos un programa a
mano — aplicamos YAML que dice "existan 2 pods de chat-orch" y el cluster los
crea, los reinicia si mueren, y los re-ubica si una VM falla. Un **pod** = un
contenedor corriendo + su propia IP. Las 3 VMs son intercambiables; Kubernetes
decide qué corre dónde.

Decisión clave: **Dataplane V2** — el networking del cluster es Cilium, y eso
hace que nuestras NetworkPolicies se **apliquen de verdad** (otros CNI las
ignoran en silencio).

## 4. Dos ambientes, un cluster

El cluster está partido en dos **namespaces**: `unagent-prod`
(unagent.site) y `unagent-dev` (dev.unagent.site). Compartimentos sellados:
los mismos 13 programas en cada uno, bases de datos separadas, URLs separadas,
cero estado compartido. Por eso dev es un respaldo real: prod puede quemarse y
dev ni se entera. El truco de costos: los gastos fijos de un solo cluster se
amortizan entre ambos.

## 5. El vocabulario de Kubernetes, mapeado a lo nuestro

Cada tipo de objeto responde una pregunta distinta:

| Objeto | Pregunta que responde | En UNAgent |
|---|---|---|
| **Deployment** | "¿corre N copias sin identidad?" | los 11 workloads de aplicación (copias desechables) |
| **StatefulSet** | "¿pods con identidad y disco propio?" | las bases de datos (`email-mongo-0` siempre es el 0, siempre con SU disco) |
| **PVC** | "¿disco que sobrevive al pod?" | 7 por namespace — por eso los datos sobreviven reinicios |
| **Job** | "¿correr una vez hasta terminar?" | rs-init del Mongo, migraciones SQL, seed del tenant demo (idempotentes) |
| **Service** | "¿nombre estable + balanceo sobre pods que cambian?" | `http://tenant:8080` siempre funciona aunque el pod renazca con otra IP (descubrimiento por DNS, patrón #2) |
| **Ingress** | "¿puerta desde internet?" | ordena a Google construir el GCLB con TLS administrado |
| **HPA** | "¿vigilar CPU y escalar copias?" | solo conversation-chat (2–6), porque su estado vive afuera de él |
| **ConfigMap/Secret** | "¿config fuera de la imagen?" | misma imagen en prod y dev; solo cambian estos valores |
| **NetworkPolicy** | "¿firewall entre pods?" | default-deny + 11 reglas que recrean las redes del compose |

## 6. "El front" son dos cosas (la confusión clásica)

1. **La página (SPA React, archivos estáticos)** vive **afuera**, en el
   **Cloudflare Worker**, replicada en ~300 datacenters del edge. A archivos
   estáticos no se les hace load balancing en Kubernetes: no son un proceso.
2. **El pod `frontend` (nginx) adentro del cluster** no es "la página": es el
   **gateway de APIs** — recibe del GCLB todas las peticiones y las enruta por
   path al backend correcto. (Trae una copia del SPA adentro por herencia del
   compose local, pero en producción la página la sirve Cloudflare.)

Es el **único nginx** del sistema: el Ingress de GKE NO es "NGINX Ingress
Controller" (lo implementa el GCLB de Google, fuera del cluster) y Cloudflare
tampoco es nginx (es un Worker JS).

**¿Cómo alcanza el GCLB —que está afuera— a un pod de adentro?** Tres piezas:
(1) el cluster es VPC-native → las IPs de los pods son IPs reales de la red de
Google; (2) el Ingress es el contrato: un controlador de GKE le ordena a Google
construir el balanceador; (3) el **NEG** (Network Endpoint Group, activado por
la anotación `cloud.google.com/neg` en el Service del frontend) es la lista
viva de IPs:puerto de los pods destino, sincronizada automáticamente cuando los
pods nacen o mueren. El LB externo le pega directo al pod (:80), sin NodePorts.

## 7. Por qué cada número de réplicas (la arquitectura hablando)

La palabra "réplica" significa cosas distintas según dónde viva el estado:

- **conversation-chat 2–6 (HPA)** — réplicas de **cómputo**: clones
  intercambiables atendiendo a la vez (su memoria es Redis, su historia Mongo,
  su cola RabbitMQ). Patrones #3 cluster + #4 load balancer.
- **email-mongo ×3** — réplicas de **datos**: replica set con PRIMARY +
  2 SECONDARY y **elección por quórum** si muere el primary (3 = mínimo para
  mayoría; `make failover` lo demuestra). Patrón #1 replicación.
- **chat-orch ×2** — **activo/standby**: sus sesiones viven en RAM, así que el
  Service fija todo el tráfico a un pod (`sessionAffinity: ClientIP`) y el
  segundo es repuesto caliente.
- **chat-orch-telegram ×1** — Telegram permite UN poller por token de bot (dos
  producen 409 Conflict; lo vimos en vivo).
- **agent-runtime ×1** — parece stateless pero su registro de jobs de Telegram
  es memoria del proceso; con 2 réplicas el registro se parte (bug visto y
  corregido).
- **redis ×2** — datos primary/replica (`redis-1 --replicaof redis-0`),
  clientes fijados al primary.

**Lección:** los conteos de réplicas no son perillas de tuning — son
consecuencias de dónde vive el estado.

## 8. El viaje de un mensaje

**Web** (con puertos):

```
Navegador ──443──▶ Cloudflare Worker (sirve SPA; proxy de APIs)
          ──443──▶ GCLB api[-dev].unagent.site (termina TLS; IP estática)
          ──80───▶ pod frontend nginx (router por path)
          ──3000─▶ chat-orch ──▶ OpenRouter (DeepSeek, :443)
                              ├─▶ hospital-mock :8080 ──▶ hospital-postgres :5432
                              └─▶ respuesta por el stream SSE abierto + contador en compliance :8091
```

El navegador mantiene abierto `GET /v1/chat/stream` (SSE): por eso las
respuestas "aparecen" sin recargar. El `BackendConfig` del GCLB sube su timeout
a 86400 s para que ese stream no muera a los 30 s.

**Telegram:** nadie puede llamar *hacia* un bot, así que `chat-orch-telegram`
hace **long-poll** a Telegram (¿hay algo nuevo?). Primer contacto → puerta OTP:
user-auth registra contra tenant-postgres y email-send envía el código por
SendGrid (expira en 15 min). Verificado, cada mensaje se vuelve un **job**:
RabbitMQ `chat_requests` → lo consume la réplica libre de conversation-chat
(consumidores en competencia = round-robin real) → mismo loop LLM+tools →
respuesta de vuelta al chat. Si pide humano, la sesión pasa a
`operator_active`, aparece en el Operator Panel (cola en Redis) y las
respuestas del operador drenan a Telegram vía un poll de 2 s.

## 9. Configuración y secretos

`.env.prod` / `.env.dev` en tu máquina son la fuente de verdad.
`scripts/gke-secrets.sh <env>` los traduce al **Secret** de cada namespace
(reconstruyendo las URLs de bases contra el DNS del cluster) y los manifiestos
los inyectan como variables de entorno. Las imágenes contienen **cero**
credenciales; rotar una llave = re-ejecutar el script + reiniciar pods. La
config no-secreta (modelo, flags) vive en el **ConfigMap** — por eso "cambiar
todo a DeepSeek" fue un solo valor.

## 10. La cebolla de seguridad

De afuera hacia adentro: TLS de Cloudflare → TLS del GCLB (certificados
administrados por Google, auto-renovables) → solo el puerto 80 del nginx
admitido al cluster → **9 zonas de NetworkPolicy** adentro (default-deny; cada
pod solo alcanza su zona; `make netcheck` lo prueba: 3 ALLOW + 3 DENY) →
**canal seguro AES-256-GCM** envolviendo cada payload backend↔backend (HTTP y
RabbitMQ: un espía dentro del cluster vería cifrado) → JWT en las APIs → OTP
por email para Telegram → **rate limits** en cada superficie de abuso:

| Superficie | Presupuesto |
|---|---|
| Login | 5 + 1/30 s por IP (429 + Retry-After, auditado a Compliance) |
| OTP enviar/reenviar | 3 + 1/min por IP+email |
| OTP verificar | 5 + 1/30 s por IP+email (un código de 6 dígitos queda estadísticamente a salvo) |
| Telegram | 5 msgs + 1 cada 2 s por chat (aviso "⏳" máx. 1/30 s) |
| Chat web | 20 + 1/s por tenant |

## 11. Cómo se publica un cambio (y cómo se revierte)

Sin CI/CD, por decisión — tres comandos supervisados por un humano:

```bash
make -C k8s gke-build  TAG=$(git rev-parse --short HEAD)  # código → imágenes → registry
make -C k8s gke-deploy ENV=dev  TAG=<sha>                 # probar en dev
make -C k8s gke-deploy ENV=prod TAG=<sha>                 # promover
# cambios de UI además:  cd FrontEnd && npm run build
#                        cd cloudflare-worker && npx wrangler deploy --env dev|prod
```

`gke-deploy` renderiza el overlay del ambiente (base compartida
`k8s/platform/` + parches de `k8s/overlays/gke-<env>`), corre aserciones de
seguridad, fija el tag y aplica. Kubernetes hace **rolling update**: pods
nuevos arrancan, pasan health checks, los viejos se drenan — sin ventana de
caída. Rollback = redesplegar el tag anterior.

## 12. La versión de una línea

> *Congelamos cada servicio en una imagen inmutable, la subimos a un registro,
> y le declaramos a un cluster Kubernetes de 3 máquinas el estado deseado de
> dos ambientes aislados — que él aplica continuamente: servicios sin estado
> replicados y auto-escalados donde su estado lo permite, bases de datos en
> discos persistentes con replicación real donde importa, el tráfico entrando
> por exactamente una puerta TLS por ambiente, y todo lo de adentro
> segmentado, cifrado y con límites de tasa — y publicar es solo declarar un
> tag de imagen nuevo.*
