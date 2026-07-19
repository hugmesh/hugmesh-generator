// tests/stack FIXTURE — replica of the upstream declaration shapes at the pinned
// GrapheneOS/AttestationServer commit 98b6c130 that the attestation-server
// Dockerfile's Patch 1 (DOMAIN) and Patch 2 (bind address) sed+grep gates
// target (specs/cluster/manifests/attestation-server/Dockerfile). The two
// TARGET lines replicate the exact upstream shapes the Dockerfile documents
// (confirmed by the real docker build 2026-07-19 — see the Dockerfile's STATUS
// header); the surrounding lines are synthetic context. Never compiled — this
// file is a sed/grep substrate for tests/stack/test-attestation-dockerfile-patches.sh.
package app.attestation.server;

import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;

public class AttestationServer {
    // Patch 1 target (upstream AttestationServer.java:89) — Origin-header CSRF
    // validation, the QR pairing payload and alert-email text all read DOMAIN.
    private static final String DOMAIN = "attestation.app";

    private static final int DEFAULT_VERIFY_INTERVAL = 4 * 60 * 60;

    public static void main(final String[] args) throws Exception {
        // Patch 2 target (upstream AttestationServer.java:895) — upstream binds
        // IPv6 LOOPBACK ONLY (it fronts the app with an nginx sidecar in the
        // same network namespace); our k8s Service topology must widen it.
        final HttpServer server = HttpServer.create(new InetSocketAddress("::1", 8080), 4096);
        server.start();
    }
}
