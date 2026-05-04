import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import motor.motor_asyncio
from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

load_dotenv()

MONGO_URI = os.getenv("MONGO_URI") or os.getenv("MONGO_URL")
MONGO_DB = os.getenv("MONGO_DB_COMPLIANCE", "UN_compliance_db")

mongo_client: Optional[motor.motor_asyncio.AsyncIOMotorClient] = None
audit_logs = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global mongo_client, audit_logs
    if MONGO_URI:
        mongo_client = motor.motor_asyncio.AsyncIOMotorClient(MONGO_URI)
        audit_logs = mongo_client[MONGO_DB].audit_logs
    yield
    if mongo_client is not None:
        mongo_client.close()


app = FastAPI(
    title="Compliance and Metrics API",
    version="2.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["*"],
)


class TenantStats:
    __slots__ = (
        "tenant_id",
        "total_conversations",
        "messages_user",
        "messages_bot",
        "successful_chats",
        "csat_sum",
        "csat_count",
    )

    def __init__(self, tenant_id: str) -> None:
        self.tenant_id = tenant_id
        self.total_conversations = 0
        self.messages_user = 0
        self.messages_bot = 0
        self.successful_chats = 0
        self.csat_sum = 0.0
        self.csat_count = 0


class DayBucket:
    __slots__ = (
        "date",
        "total_conversations",
        "messages_user",
        "messages_bot",
        "successful_chats",
        "csat_sum",
        "csat_count",
    )

    def __init__(self, date: str) -> None:
        self.date = date
        self.total_conversations = 0
        self.messages_user = 0
        self.messages_bot = 0
        self.successful_chats = 0
        self.csat_sum = 0.0
        self.csat_count = 0


tenant_stats: Dict[str, TenantStats] = {}
daily: Dict[str, Dict[str, DayBucket]] = {}


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _get_or_create_day_bucket(tenant_id: str, date: str) -> DayBucket:
    per_tenant = daily.setdefault(tenant_id, {})
    bucket = per_tenant.get(date)
    if bucket is None:
        bucket = DayBucket(date)
        per_tenant[date] = bucket
    return bucket


def _get_or_create_stats(tenant_id: str) -> TenantStats:
    stats = tenant_stats.get(tenant_id)
    if stats is None:
        stats = TenantStats(tenant_id)
        tenant_stats[tenant_id] = stats
    return stats


def _update_chat_stats(tenant_id: str, resolved: bool) -> None:
    stats = _get_or_create_stats(tenant_id)
    stats.total_conversations += 1
    stats.messages_user += 1
    stats.messages_bot += 1
    if resolved:
        stats.successful_chats += 1

    bucket = _get_or_create_day_bucket(tenant_id, _today())
    bucket.total_conversations += 1
    bucket.messages_user += 1
    bucket.messages_bot += 1
    if resolved:
        bucket.successful_chats += 1


def _record_csat(tenant_id: str, score: float) -> float:
    stats = _get_or_create_stats(tenant_id)
    stats.csat_sum += score
    stats.csat_count += 1
    average = stats.csat_sum / stats.csat_count if stats.csat_count else 0.0

    bucket = _get_or_create_day_bucket(tenant_id, _today())
    bucket.csat_sum += score
    bucket.csat_count += 1
    return average


class ChatRequest(BaseModel):
    message: str
    resolved: bool = False


class CsatRequest(BaseModel):
    score: int


class FeedbackV1(BaseModel):
    tenant_id: str
    score: int


class ComplianceLog(BaseModel):
    timestamp: str = Field(default_factory=_now_iso)
    level: str = "INFO"
    tenant_id: str
    component: str
    action: str
    metadata: Optional[Dict[str, Any]] = None


async def _save_audit(doc: Dict[str, Any]) -> None:
    if audit_logs is None:
        return
    try:
        await audit_logs.insert_one(doc)
    except Exception:
        pass


@app.post("/conversation/chat")
async def legacy_chat(
    body: ChatRequest,
    background_tasks: BackgroundTasks,
    x_tenant_id: Optional[str] = Header(default=None, alias="X-Tenant-ID"),
):
    if not x_tenant_id:
        raise HTTPException(status_code=400, detail="X-Tenant-ID header is required")
    _update_chat_stats(x_tenant_id, body.resolved)
    background_tasks.add_task(
        _save_audit,
        {
            "timestamp": _now_iso(),
            "level": "INFO",
            "tenant_id": x_tenant_id,
            "component": "metricas-legacy",
            "action": "CHAT_TURN",
            "metadata": {"message": body.message, "resolved": body.resolved},
        },
    )
    return {
        "session_id": "n/a",
        "reply": "Mensaje procesado correctamente",
        "bot_resolved": body.resolved,
    }


@app.post("/feedback/csat")
async def legacy_csat(
    body: CsatRequest,
    background_tasks: BackgroundTasks,
    x_tenant_id: Optional[str] = Header(default=None, alias="X-Tenant-ID"),
):
    if not x_tenant_id:
        raise HTTPException(status_code=400, detail="X-Tenant-ID header is required")
    average = _record_csat(x_tenant_id, float(body.score))
    background_tasks.add_task(
        _save_audit,
        {
            "timestamp": _now_iso(),
            "level": "INFO",
            "tenant_id": x_tenant_id,
            "component": "metricas-legacy",
            "action": "CSAT",
            "metadata": {"score": body.score},
        },
    )
    return {"status": "feedback received", "current_avg": average}


@app.get("/stats/kpis")
async def get_kpis():
    rows: List[Dict[str, Any]] = []
    for stats in tenant_stats.values():
        avg_csat = stats.csat_sum / stats.csat_count if stats.csat_count else 0.0
        res_rate = (
            stats.successful_chats / stats.total_conversations * 100
            if stats.total_conversations
            else 0.0
        )
        total_msgs = stats.messages_user + stats.messages_bot
        avg_msgs = total_msgs / stats.total_conversations if stats.total_conversations else 0.0
        rows.append(
            {
                "tenant_id": stats.tenant_id,
                "total_conversations": stats.total_conversations,
                "messages_user": stats.messages_user,
                "messages_bot": stats.messages_bot,
                "average_csat": avg_csat,
                "avg_messages_per_conv": avg_msgs,
                "resolution_rate_percent": res_rate,
            }
        )
    return {"data": rows}


@app.get("/stats/timeseries")
async def get_timeseries(tenant_id: Optional[str] = None, days: int = 7):
    if days < 1:
        days = 1
    if days > 30:
        days = 30
    today = datetime.now(timezone.utc).date()
    dates = [(today - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(days - 1, -1, -1)]
    out: List[Dict[str, Any]] = []
    for d in dates:
        total_conv = msgs_u = msgs_b = succ = csat_count = 0
        csat_sum = 0.0
        if tenant_id:
            bucket = daily.get(tenant_id, {}).get(d)
            buckets = [bucket] if bucket else []
        else:
            buckets = [m[d] for m in daily.values() if d in m]
        for b in buckets:
            total_conv += b.total_conversations
            msgs_u += b.messages_user
            msgs_b += b.messages_bot
            succ += b.successful_chats
            csat_sum += b.csat_sum
            csat_count += b.csat_count
        avg_csat = csat_sum / csat_count if csat_count else 0.0
        out.append(
            {
                "date": d,
                "total_conversations": total_conv,
                "messages_user": msgs_u,
                "messages_bot": msgs_b,
                "successful_chats": succ,
                "avg_csat": avg_csat,
            }
        )
    return {"data": out}


@app.post("/v1/feedback")
async def submit_feedback_v1(data: FeedbackV1):
    _record_csat(data.tenant_id, float(data.score))
    return {"status": "ok", "message": "Feedback recibido"}


@app.post("/v1/event")
async def register_event(log: ComplianceLog, background_tasks: BackgroundTasks):
    log_dict = log.model_dump()
    background_tasks.add_task(_save_audit, log_dict)
    if log.action == "CHAT_STARTED":
        _update_chat_stats(log.tenant_id, resolved=False)
    return {"status": "ok", "message": "Log registrado en Compliance"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {"service": "compliance", "version": "2.0"}
