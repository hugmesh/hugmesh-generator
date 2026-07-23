// Golden.java — JVM-derived golden canonical-bytes vector for the domain-registry export
// signature path. MANUAL REGEN TOOL ONLY (not wired into CI — generator CI is GitLab + has no JDK).
//
// This is a genuine SECOND implementation of the canonical encoding, INDEPENDENT of the bash
// reconstruction in specs/usr/lib/hugmesh/domain-verify.sh:domain_canonical_bytes. The
// canonicalBytes byte-layout below is copied VERBATIM from the authoritative admin-bff signer
//   hugmesh-admin-bff-api:
//   src/main/java/systems/hugmesh/adminbff/domainregistry/DomainRegistryExportService.java
//   static byte[] canonicalBytes(DomainExportBody) (the merged #118 version)
// and the DomainEntry record shape from DomainExportModels.java. It builds the EXACT fixture the
// offline test tests/domain-registry/test-domain-reconcile-verify.sh Case 0 uses (canon_ref()),
// then prints the canonical bytes as lowercase hex — that hex is committed as canonical-golden.hex.
//
// Single-file source launch (Java 11+): `java tests/domain-registry/Golden.java`
//
// REGENERATE canonical-golden.hex from this tool ONLY IF the admin-bff
// DomainRegistryExportService.canonicalBytes contract changes; then the implementation in
// domain-verify.sh and this golden must be updated together, and the offline test re-run.
import java.nio.charset.StandardCharsets;

public final class Golden {

    // ── DomainEntry record — VERBATIM field shape from DomainExportModels.java ─────────
    record DomainEntry(
            String clusterDomain,
            String brand,
            String org,
            String caRef,
            String nsPrefix,
            String casdoorOrg,
            String meshTag,
            boolean caProvisioned,
            boolean appsetRegistered,
            long generation) {
    }

    record DomainExportBody(
            String node,
            long generation,
            java.util.List<DomainEntry> entries) {
    }

    // ── canonicalBytes — copied VERBATIM from DomainRegistryExportService.canonicalBytes ──
    static byte[] canonicalBytes(DomainExportBody body) {
        StringBuilder sb = new StringBuilder();
        sb.append("v1-domain\n");
        sb.append("node=").append(nz(body.node())).append('\n');
        sb.append("generation=").append(body.generation()).append('\n');
        for (DomainEntry e : body.entries()) {
            sb.append("dom=").append(nz(e.clusterDomain()))
              .append('\t').append("brand=").append(nz(e.brand()))
              .append('\t').append("org=").append(nz(e.org()))
              .append('\t').append("ca=").append(nz(e.caRef()))
              .append('\t').append("ns=").append(nz(e.nsPrefix()))
              .append('\t').append("casdoor=").append(nz(e.casdoorOrg()))
              .append('\t').append("mesh=").append(nz(e.meshTag()))
              .append('\t').append("ca_prov=").append(e.caProvisioned())
              .append('\t').append("appset=").append(e.appsetRegistered())
              .append('\t').append("gen=").append(e.generation())
              .append('\n');
        }
        return sb.toString().getBytes(StandardCharsets.UTF_8);
    }

    private static String nz(String s) {
        return s == null ? "" : s;
    }

    public static void main(String[] args) {
        // ── The EXACT Case 0 fixture from test-domain-reconcile-verify.sh ────────────────
        //   NODE="mkey:abc"; GEN=7; one registered-not-provisioned acme entry.
        final String node = "mkey:abc";
        final long gen = 7L;
        DomainEntry entry = new DomainEntry(
                "acme.test",   // clusterDomain
                "acme",        // brand
                "Acme-Inc",    // org
                "generate",    // caRef
                "acme",        // nsPrefix
                "acme-org",    // casdoorOrg
                "tag:acme",    // meshTag
                false,         // caProvisioned
                false,         // appsetRegistered
                gen);          // generation
        DomainExportBody body = new DomainExportBody(node, gen, java.util.List.of(entry));

        byte[] canonical = canonicalBytes(body);
        StringBuilder hex = new StringBuilder(canonical.length * 2);
        for (byte b : canonical) {
            hex.append(String.format("%02x", b & 0xff));
        }
        System.out.println(hex);
    }
}
