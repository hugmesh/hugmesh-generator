# SPDX-License-Identifier: Apache-2.0
# snapdragon-media-poisoner — the OPTIONAL x86/GPU AI-cloak/poison worker.
#
# DEFAULT (lean) build: CPU-portable, Pillow+numpy perturbation only. Small image,
# runs on any node (including a CPU-only test node), so the BFF round-trip survival
# gate is exercisable end-to-end without a GPU. On the real x86 GPU node the worker
# reaches the host render devices via the /dev/dri hostPath the Deployment mounts
# (vendor-agnostic, same contract as snapdragon-games).
#
# GPU build (the documented follow-up, NOT built here): set POISON_VARIANT=gpu and
# add requirements-gpu.txt with a torch wheel from the CUDA or ROCm pytorch index.
# That enables the PGD-against-Stable-Diffusion-VAE backend (the OPEN PyTorch
# reference — NOT the SAND Lab Glaze/Nightshade binaries; see README LICENSE note).
#
# Built + pushed by GitLab CI in this repo (CI = GitLab only); the kustomization
# rewrites the image ref to the in-cluster registry like the other first-party apps.
FROM python:3.12-slim AS base

# Non-root, no shell escalation. readOnlyRootFilesystem is set in the Deployment;
# the app writes nothing to disk (perturbation is in-memory).
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install the lean baseline. (For a GPU image variant, COPY + pip install
# requirements-gpu.txt with the appropriate --index-url; left out of the default.)
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Drop to an unprivileged UID matching the Deployment securityContext (runAsUser 1000).
RUN useradd -u 1000 -m -s /usr/sbin/nologin poison
USER 1000

EXPOSE 8080

# app.serve wraps uvicorn on :8080 (the ClusterIP Service / probe port) with the
# SAME defaults as the previous direct-uvicorn CMD (0.0.0.0:8080, single worker —
# the perturbation is the bottleneck and the Deployment caps concurrency=1 for the
# CPU path so it cannot starve the control/data plane). Additionally it honours the
# OPTIONAL POISON_TLS_CERT / POISON_TLS_KEY / POISON_TLS_CLIENT_CA env for
# worker-terminated (m)TLS — unset (the default) it serves plain HTTP exactly as
# before; a PARTIAL TLS config aborts startup (fail-closed, never silent plaintext).
CMD ["python", "-m", "app.serve"]
