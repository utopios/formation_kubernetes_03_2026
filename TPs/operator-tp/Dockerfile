FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY operator.py .

# Kopf lance la boucle de réconciliation
CMD ["kopf", "run", "/app/operator.py", "--liveness=http://0.0.0.0:8080/healthz"]