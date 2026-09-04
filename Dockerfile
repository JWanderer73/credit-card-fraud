# syntax=docker/dockerfile:1
#
# Multi-stage build. The point of the split is that the training stack
# (scikit-learn, xgboost, pandas) never enters the final image: ONNX Runtime
# executes the serialized graph on its own, so only requirements.txt ships.
#
# Architecture-agnostic on purpose -- no --platform, no arch-specific wheel
# URLs. onnxruntime and numpy both publish manylinux wheels for aarch64 and
# x86_64, so this same file builds native arm64 locally and linux/amd64 on
# GitHub's x86 runners. Platform is the builder's choice, not the file's.

ARG PYTHON_VERSION=3.12-slim

# ---------------------------------------------------------------------------
# Stage 1: builder -- resolve dependencies into a self-contained venv.
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# Runtime requirements ONLY. No compilers are installed and none are needed --
# every wheel here is manylinux, which is what keeps this stage cheap.
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt \
    # sympy (74MB) and its mpmath dependency are pulled in by onnxruntime, but
    # only for symbolic shape inference -- a model-authoring and optimization
    # tool, not part of executing a session. Verified rather than assumed:
    # sympy is absent from sys.modules after importing onnxruntime, after
    # creating the InferenceSession, and after running inference, and the full
    # test suite passes without it in the `test` stage below. It is 30% of the
    # venv, so dropping it is the single largest win available.
    #
    # The trade-off: onnxruntime still DECLARES sympy as a dependency, so
    # `pip check` will report the metadata as inconsistent. That is the price
    # of the size, and the test stage is what keeps it honest -- if any ORT
    # code path we actually use ever needs sympy, the build fails there rather
    # than the container failing in production.
    && /opt/venv/bin/pip uninstall -y sympy mpmath \
    # Bytecode caches from install time; PYTHONDONTWRITEBYTECODE keeps them
    # from being regenerated into the image layers at runtime.
    && find /opt/venv -type d -name __pycache__ -prune -exec rm -rf {} + \
    && find /opt/venv -type f -name '*.pyc' -delete

# ---------------------------------------------------------------------------
# Stage 2: base -- the actual application layers, shared by test and runtime.
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION} AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Non-root. Created before the COPYs so ownership is set in one pass.
RUN useradd --create-home --uid 10001 appuser

WORKDIR /srv

# Only the venv crosses over from the builder: no pip cache, no build
# toolchain, no training libraries.
COPY --from=builder /opt/venv /opt/venv

COPY --chown=appuser:appuser app/ ./app/
COPY --chown=appuser:appuser models/ ./models/

USER appuser

# ---------------------------------------------------------------------------
# Stage 3: test -- runs the suite against the layers that actually ship.
#
# This is the gate that closes the arm64-local / amd64-CI gap. The amd64 image
# is never built on the developer's machine, so it has to be exercised where it
# IS built. Because this stage derives FROM base, the code, model artifacts and
# interpreter under test are byte-for-byte the ones in the runtime image --
# only pytest and the test files are added, and they are added HERE, so they
# never reach the shipped image.
#
#   docker build --target test .
#
# The RUN below fails the build if any test fails.
# ---------------------------------------------------------------------------
FROM base AS test

USER root
RUN pip install --no-cache-dir pytest==8.3.4 httpx==0.28.1
COPY --chown=appuser:appuser tests/ ./tests/
USER appuser

RUN python -m pytest -v

# ---------------------------------------------------------------------------
# Stage 4: runtime -- the shipped image. Last stage, so it is the default
# target and a plain `docker build .` cannot accidentally ship the test stage.
# ---------------------------------------------------------------------------
FROM base AS runtime

EXPOSE 8000

# No curl in python:*-slim, and installing it just for this would add a package
# to the runtime image. urllib is already there.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status==200 else 1)"

# Shell form so ${WORKERS} is expanded at container start rather than baked in
# at build time -- the same image can then be tuned per task size.
#
# `exec` is load-bearing, not stylistic. Without it the shell stays alive as
# PID 1 and uvicorn runs as its child, so the SIGTERM that ECS sends to stop a
# task lands on /bin/sh and is never forwarded: the container ignores the
# shutdown, waits out the 30s stop timeout and gets SIGKILLed, dropping
# in-flight requests on every deploy and every scale-in. `exec` replaces the
# shell with uvicorn, making it PID 1 so it receives the signal and drains.
CMD exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${WORKERS:-2}
