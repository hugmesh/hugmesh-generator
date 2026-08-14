# hugmesh-edge-ai-tts — the CPU-default Piper TTS image (VN voice feature, B3).
# Build + push to the mesh registry the deployment expects (manifests = follow-up PR):
#   docker build -t registry.hugmesh.net/hugmesh/edge-ai-tts:main .
#   docker push  registry.hugmesh.net/hugmesh/edge-ai-tts:main
# CPU-ONLY: python:3.12-slim + onnxruntime (CPU). No nvidia base, no CUDA. Piper is
# real-time on CPU for short VN lines; a GPU variant is a later optional flag.
# Runs as non-root (uid 65532) and is read-only-rootfs friendly (the pod mounts an
# emptyDir at /tmp; /models is read-only — voice baked in here, extras via a PVC).

# ── stage 1: fetch the default voice (network at BUILD time only) ─────────────
# Bundling ONE en_US voice keeps the runtime image self-contained and offline at
# request time. download_voices writes "<voice>.onnx" + "<voice>.onnx.json", which is
# exactly what app.py's _voice_paths() expects under /models.
FROM python:3.12-slim AS voices
ARG DEFAULT_VOICE=en_US-amy-medium
WORKDIR /models
RUN pip install --no-cache-dir piper-tts==1.4.2 \
    && python -m piper.download_voices --download-dir /models "${DEFAULT_VOICE}" \
    && test -f "/models/${DEFAULT_VOICE}.onnx" \
    && test -f "/models/${DEFAULT_VOICE}.onnx.json"

# ── stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.12-slim

# onnxruntime + the bundled espeak-ng (espeakbridge.so) need libgomp at runtime;
# libstdc++6 ships in the slim base. No espeak-ng apt package — the wheel bundles it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py visemes.py ./

# Baked-in default voice (read-only). Extra voices mount over/under /models via a PVC.
COPY --from=voices /models /models

ENV TTS_MODEL_DIR=/models \
    TTS_DEFAULT_VOICE=en_US-amy-medium

USER 65532:65532
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
