# Optionales Container-Image (die native Installation auf dem Pi ist der empfohlene Weg).
# Mehrstufig: Frontend wird im Build-Container gebaut, das Laufzeit-Image enthält nur Python + dist.

FROM node:22-bookworm-slim AS frontend
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

FROM python:3.11-slim-bookworm
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    AWC_DATA_DIR=/data AWC_FRONTEND_DIST=/app/frontend/dist
RUN apt-get update && apt-get install -y --no-install-recommends iw && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 1000 --home /data allwheel && mkdir -p /data && chown allwheel /data
WORKDIR /app/backend
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/app ./app
COPY --from=frontend /src/frontend/dist /app/frontend/dist
USER allwheel
EXPOSE 8080
VOLUME ["/data"]
CMD ["python", "-m", "app"]
