import os
from dotenv import load_dotenv
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
from datetime import datetime
import motor.motor_asyncio

# Cargamos las variables del archivo .env
load_dotenv()

# Inicializamos la API
app = FastAPI(title="Compliance and Metrics API", version="2.0")

# --- CONEXIÓN A MONGODB ATLAS ---
MONGO_URL = os.getenv("MONGO_URL") 
client = motor.motor_asyncio.AsyncIOMotorClient(MONGO_URL)
# Especificamos el nombre exacto de la BD para evitar el ConfigurationError
db = client["UN_complaince_db"] 
collection = db.audit_logs

# --- MEMORIA PARA EL FRONTEND (Métricas temporales) ---
kpi_data = {
    "total_conversations": 0,
    "csat_scores": []
}

# --- MODELOS DE DATOS ---
class Feedback(BaseModel):
    tenant_id: str
    score: int

class ComplianceLog(BaseModel):
    timestamp: str = Field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")
    level: str = "INFO"
    tenant_id: str
    component: str
    action: str
    metadata: Optional[Dict[str, Any]] = {}

# --- FUNCIONES AUXILIARES ---
async def save_log_to_mongo(log_data: dict):
    """
    Función envoltorio asíncrona. 
    Asegura que motor (Mongo) corra en el Event Loop principal y no en un Worker Thread.
    """
    await collection.insert_one(log_data)

# --- ENDPOINTS ---

@app.post("/v1/feedback")
async def submit_feedback(data: Feedback):
    """Guarda la calificación temporalmente para el dashboard."""
    kpi_data["csat_scores"].append(data.score)
    return {"status": "ok", "message": "Feedback recibido"}

@app.post("/v1/event")
async def register_event(log: ComplianceLog, background_tasks: BackgroundTasks):
    """
    Recibe el evento universal, lo manda a Mongo en segundo plano,
    y actualiza las métricas en memoria.
    """
    # 1. Convertimos el modelo a un diccionario de Python
    log_dict = log.model_dump() # model_dump() es la forma moderna de dict() en Pydantic v2
    
    # 2. Guardamos en BD usando la función asíncrona (¡Aquí estaba el fix!)
    background_tasks.add_task(save_log_to_mongo, log_dict)

    # 3. Actualizamos métricas si es un chat nuevo
    if log.action == "CHAT_STARTED":
        kpi_data["total_conversations"] += 1
        
    return {"status": "ok", "message": "Log registrado en Compliance"}

@app.get("/stats/kpis")
async def get_kpis():
    """Endpoint para que el FrontEnd dibuje las gráficas."""
    scores = kpi_data["csat_scores"]
    avg_csat = sum(scores) / len(scores) if scores else 0.0
    
    return {
        "total_conversations": kpi_data["total_conversations"],
        "average_csat": round(avg_csat, 2),
        "total_reviews": len(scores)
    }