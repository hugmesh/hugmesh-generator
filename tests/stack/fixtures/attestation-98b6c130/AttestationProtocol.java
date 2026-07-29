// tests/stack FIXTURE — replica of the upstream declaration shapes at the pinned
// GrapheneOS/AttestationServer commit 98b6c130 that the attestation-server
// Dockerfile's Patch 3 (fork-identity pin) sed+grep gates target
// (specs/cluster/manifests/attestation-server/Dockerfile). The LOAD-BEARING
// shapes, confirmed by the first real docker build (whose fail-loud grep gate
// caught the original single-line assumption — see the Dockerfile's Patch 3
// comment): AUDITOR_APP_PACKAGE_NAME_RELEASE keeps `= "literal"` on ONE line,
// but AUDITOR_APP_SIGNATURE_DIGEST_RELEASE is LINE-WRAPPED (`... =` newline
// `"990E04...";`, upstream AttestationProtocol.java:167-168) — which is why the
// Dockerfile's digest sed targets the unique stock digest LITERAL, not the
// declaration. The _PLAY/_DEBUG declarations are synthetic shape-context with
// SENTINEL values (deliberately not upstream's real pins): they exist to prove
// the seds repoint ONLY the RELEASE pin. Never compiled — this file is a
// sed/grep substrate for tests/stack/test-attestation-dockerfile-patches.sh.
package app.attestation.server;

class AttestationProtocol {
    private static final String AUDITOR_APP_PACKAGE_NAME_RELEASE = "app.attestation.auditor";
    private static final String AUDITOR_APP_PACKAGE_NAME_PLAY = "app.attestation.auditor.play";
    private static final String AUDITOR_APP_PACKAGE_NAME_DEBUG = "app.attestation.auditor.debug";
    private static final String AUDITOR_APP_SIGNATURE_DIGEST_RELEASE =
            "990E04F0864B19F14F84E0E432F7A393F297AB105A22C1E1B10B442A4A62C42C";
    private static final String AUDITOR_APP_SIGNATURE_DIGEST_PLAY =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0001";
    private static final String AUDITOR_APP_SIGNATURE_DIGEST_DEBUG =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0002";
}
