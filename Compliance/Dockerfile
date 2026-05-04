# Usamos una versión ligera de Python 3.12
FROM python:3.12-slim

# Creamos la carpeta de trabajo dentro del contenedor
WORKDIR /app

# Copiamos primero la lista de dependencias
COPY requirements.txt .

# Instalamos las librerías (FastAPI, uvicorn, motor, etc.)
RUN pip install --no-cache-dir -r requirements.txt

# Copiamos todo el resto del código (main.py, etc.)
COPY . .

# Exponemos el puerto que usa tu API
EXPOSE 8091

# El comando para encender el servidor dentro de Docker
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8091"]