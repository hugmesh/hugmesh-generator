# SPDX-License-Identifier: Apache-2.0
"""hugmesh-media-poisoner — serving entrypoint with OPTIONAL (m)TLS.

Default (no TLS env set) is byte-identical to the previous behaviour: plain
HTTP on 0.0.0.0:8080, single worker — the in-cluster ClusterIP posture where
the BFF reaches the worker over cluster DNS. When the deployment requires the
worker itself to terminate mTLS (instead of a sidecar/mesh), set the env knobs
below and uvicorn serves TLS and VERIFIES the client certificate against the
given CA (true mutual TLS, mirroring the BFF/gateway build-keystore + ESO
pattern used elsewhere in this repo — the PEMs arrive via an ESO-projected
Secret volume, never baked into the image).

Env knobs (all optional; unset => plain HTTP, backward compatible):

  POISON_BIND_HOST       bind address            (default 0.0.0.0)
  POISON_BIND_PORT       bind port               (default 8080)
  POISON_TLS_CERT        server certificate PEM path (leaf [+ chain])
  POISON_TLS_KEY         server private key PEM path
  POISON_TLS_CLIENT_CA   CA bundle PEM path used to VERIFY client certs.
                         Setting it enforces ssl.CERT_REQUIRED — a caller
                         without a valid client cert cannot even complete the
                         TLS handshake (mTLS).

FAIL-CLOSED contract: a PARTIAL TLS configuration (cert without key, key
without cert, or a client CA without a server cert+key) is a configuration
error and ABORTS startup with a clear message — the worker never silently
falls back to plaintext when the operator asked for TLS. Missing/unreadable
PEM files abort the same way.
"""

from __future__ import annotations

import logging
import os
import ssl
from typing import Any, Mapping

log = logging.getLogger("media-poisoner.serve")

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8080


class TlsConfigError(ValueError):
    """Raised for a partial/broken TLS env configuration (fail closed)."""


def _env_path(env: Mapping[str, str], key: str) -> str:
    """Read an env var as a stripped path ('' when unset/blank)."""
    return (env.get(key) or "").strip()


def tls_kwargs_from_env(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Resolve the POISON_TLS_* env into uvicorn ssl_* kwargs.

    Returns {} when no TLS env is set (plain HTTP — the backward-compatible
    default). Raises TlsConfigError on any partial or unusable configuration
    instead of degrading: an operator who configured TLS must get TLS or a
    loud startup failure, never a silent plaintext listener.
    """
    if env is None:
        env = os.environ
    cert = _env_path(env, "POISON_TLS_CERT")
    key = _env_path(env, "POISON_TLS_KEY")
    client_ca = _env_path(env, "POISON_TLS_CLIENT_CA")

    if not cert and not key and not client_ca:
        return {}  # TLS not requested — plain HTTP, identical to before.

    if not cert or not key:
        raise TlsConfigError(
            "partial TLS config: POISON_TLS_CERT and POISON_TLS_KEY must BOTH be set "
            f"(got cert={'set' if cert else 'MISSING'}, key={'set' if key else 'MISSING'}"
            f"{', client_ca=set' if client_ca else ''}) — refusing to start plaintext "
            "when TLS was requested."
        )

    checked: list[tuple[str, str]] = [("POISON_TLS_CERT", cert), ("POISON_TLS_KEY", key)]
    if client_ca:
        checked.append(("POISON_TLS_CLIENT_CA", client_ca))
    for name, path in checked:
        if not os.path.isfile(path):
            raise TlsConfigError(f"{name} points to a missing/unreadable file: {path}")

    kwargs: dict[str, Any] = {"ssl_certfile": cert, "ssl_keyfile": key}
    if client_ca:
        # True mTLS: the handshake itself REQUIRES a client certificate signed
        # by this CA. Without it, uvicorn's default is server-auth-only TLS.
        kwargs["ssl_ca_certs"] = client_ca
        kwargs["ssl_cert_reqs"] = ssl.CERT_REQUIRED
    return kwargs


def transport_mode(env: Mapping[str, str] | None = None) -> str:
    """Honest transport disclosure for /health: mtls | tls | plaintext | invalid.

    'invalid' is only reachable when the app is launched by some path that
    bypasses main() (e.g. a hand-run uvicorn CLI with a partial POISON_TLS_*
    env) — main() itself aborts on the same condition before serving.
    """
    try:
        kwargs = tls_kwargs_from_env(env)
    except TlsConfigError:
        return "invalid"
    if kwargs.get("ssl_cert_reqs") == ssl.CERT_REQUIRED:
        return "mtls"
    if kwargs:
        return "tls"
    return "plaintext"


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    import uvicorn  # deferred so config helpers are importable without uvicorn

    host = os.environ.get("POISON_BIND_HOST", DEFAULT_HOST)
    port = int(os.environ.get("POISON_BIND_PORT", str(DEFAULT_PORT)))
    try:
        kwargs = tls_kwargs_from_env()
    except TlsConfigError as exc:
        # Fail closed, loudly: a partial TLS config must never silently serve
        # plaintext. The pod CrashLoops with this message instead.
        log.error("TLS configuration error: %s", exc)
        raise SystemExit(2)

    mode = "mTLS (client certs REQUIRED)" if kwargs.get("ssl_cert_reqs") == ssl.CERT_REQUIRED \
        else ("TLS (server-auth only)" if kwargs else "plaintext HTTP (in-cluster ClusterIP default)")
    log.info("serving app.main:app on %s:%d — transport: %s", host, port, mode)

    # Single worker: the perturbation is the bottleneck and the Deployment caps
    # concurrency=1 for the CPU path (same contract as the previous CMD).
    uvicorn.run("app.main:app", host=host, port=port, workers=1, **kwargs)


if __name__ == "__main__":
    main()
