# snapdragon-edge-ai-analysis — the analysis API wrapper image.
# Build + push to the mesh registry the deployment expects:
#   docker build -t registry.snapdragon.systems/snapdragon/edge-ai-analysis:main .
#   docker push  registry.snapdragon.systems/snapdragon/edge-ai-analysis:main
# Runs as non-root (uid 65532) with a read-only rootfs (the pod mounts an emptyDir at
# /tmp). Stateless; delegates all inference to the in-cluster edge-ai Ollama upstream.
FROM python:3.12-slim

# Pillow/imagehash need libjpeg/zlib at runtime; build deps are pip-wheel-resolved.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libjpeg62-turbo zlib1g \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

USER 65532:65532
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
