# ---- Stage 1: build React (Vite -> frontend-v2/dist) ----
FROM node:20-slim AS frontend
WORKDIR /app/frontend-v2
COPY frontend-v2/package*.json ./
RUN npm ci
COPY frontend-v2/ ./
RUN npm run build

# ---- Stage 2: FastAPI runtime ----
FROM python:3.12-slim
WORKDIR /app/backend-v2
COPY backend-v2/requirements.txt ./
RUN python -m pip install --no-cache-dir -r requirements.txt
COPY backend-v2/ ./
# main.py serves the SPA from backend-v2/static
COPY --from=frontend /app/frontend-v2/dist ./static
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
