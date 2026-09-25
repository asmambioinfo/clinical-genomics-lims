# Dockerfile
#
# Containerizes the Streamlit LIMS frontend (frontend/app.py) and its
# Python dependencies (_scripts/core/database.py, requirements.txt). This
# is separate from the NGS pipeline's per-tool containers already defined
# in nextflow-run/nextflow.config -- Nextflow manages those on its own;
# this image has nothing to do with them.
#
# Credentials are never baked into this image -- see .dockerignore, which
# excludes .env.test/.env.prod. Pass them at container runtime as
# environment variables, or via Key Vault + Managed Identity once this
# actually runs on Azure.

# ---- Build stage: compile pymssql's dependency (FreeTDS), install packages ----
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        freetds-dev \
        gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# ---- Final stage: slim runtime image, no compiler or dev headers ----
FROM python:3.11-slim

# pymssql links against FreeTDS at runtime too, not just build time --
# freetds-bin (not freetds-dev) is the minimal runtime piece needed here.
RUN apt-get update && apt-get install -y --no-install-recommends \
        freetds-bin \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Bring over only the installed Python packages from the build stage, not
# the compiler/dev headers that produced them.
COPY --from=builder /root/.local /root/.local
ENV PATH=/root/.local/bin:$PATH
ENV PYTHONUNBUFFERED=1
ENV STREAMLIT_SERVER_HEADLESS=true

COPY frontend/ frontend/
COPY _scripts/ _scripts/
COPY db/ db/

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl --fail http://localhost:8501/_stcore/health || exit 1

ENTRYPOINT ["streamlit", "run", "frontend/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
