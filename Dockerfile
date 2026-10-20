# syntax=docker/dockerfile:1
FROM node:24-bookworm-slim AS web
WORKDIR /build/web
COPY my-react-app/package.json my-react-app/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY my-react-app/ ./
# Leave empty to have the browser call the API on the same Railway domain.
ARG VITE_API_URL=""
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

FROM python:3.12-slim-bookworm AS runtime
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    TF_CPP_MIN_LOG_LEVEL=2 \
    TF_NUM_INTRAOP_THREADS=1 \
    TF_NUM_INTEROP_THREADS=1 \
    OMP_NUM_THREADS=1 \
    MPLCONFIGDIR=/tmp/matplotlib
WORKDIR /app/backend
COPY backend/requirements.txt backend/constraints.txt ./
RUN python -m pip install --only-binary=:all: -r requirements.txt \
    && python -m pip check
COPY backend/app/ ./app/
COPY backend/ml/ ./ml/
COPY backend/scripts/ ./scripts/
# These exact files must exist in the GitHub checkout. A missing model should
# fail the build clearly, rather than produce an app that cannot classify rice.
COPY backend/artifacts/model/rice_cnn_model.keras ./artifacts/model/rice_cnn_model.keras
COPY backend/artifacts/model/class_names.json ./artifacts/model/class_names.json
COPY backend/artifacts/model/metrics.json ./artifacts/model/metrics.json
COPY --from=web /build/web/dist/ ./static/
RUN groupadd --gid 10001 rice \
    && useradd --uid 10001 --gid rice --no-create-home rice \
    && mkdir -p storage/uploads \
    && chown -R rice:rice storage
USER rice
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('PORT', '8000') + '/ready', timeout=8)"
CMD ["python", "-m", "scripts.start_server"]
