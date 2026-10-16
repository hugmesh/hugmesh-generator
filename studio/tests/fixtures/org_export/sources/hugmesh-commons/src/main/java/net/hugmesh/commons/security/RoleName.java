package net.hugmesh.commons.security;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonValue;

/**
 * Typed, closed enumeration of the four HugMesh <em>base</em> role
 * tokens — the lowercase on-the-wire strings {@code "user"},
 * {@code "mod"}, {@code "admin"}, and {@code "superadmin"} that Casdoor
 * stores and the converter upper-cases into Spring authority strings.
 *
 * <h2>Responsibility</h2>
 *
 * <p>Applies the code-convention principle that a fixed, closed set of
 * security-critical string constants should be an enum. The raw
 * {@code "admin"} / {@code "superadmin"} string literals were previously
 * scattered across every BFF as arguments to:
 * <ul>
 *   <li>{@code CasdoorAdminClient.ensureUser(..., List<String> roles)}
 *       — which upper-cases each token into the Casdoor role
 *       {@code ADMIN} / {@code ROLE_ADMIN}.</li>
 *   <li>{@code UsageService.record(actor, List<String> roles, action)}
 *       — which compares the list against {@code "admin"} to mark
 *       admin-initiated events.</li>
 * </ul>
 *
 * <p>This enum is the single source of truth for those tokens and
 * prevents a typo ({@code "admim"}) from silently granting or denying
 * an incorrect role.
 *
 * <h2>Wire contract — do NOT change the serialized value</h2>
 *
 * <p>The {@link #value()} returned by each constant (and emitted via
 * {@link JsonValue}) is the IDENTICAL lowercase string that Casdoor /
 * the gateway have always seen. It is a live contract with three systems:
 *
 * <ul>
 *   <li><b>Casdoor</b> — upper-cases each token to produce the Casdoor
 *       role name ({@code "admin"} becomes {@code ADMIN} /
 *       {@code ROLE_ADMIN}). The token MUST stay lowercase so that
 *       upper-casing reproduces the existing Casdoor role
 *       byte-for-byte.</li>
 *   <li><b>The gateway / {@link CasdoorAuthorities} converter</b> —
 *       derives the Spring authority {@code ROLE_<UPPER>} from the same
 *       role name read out of the JWT.</li>
 *   <li><b>JSON / DB</b> — wherever these tokens are serialized into
 *       event logs, usage records, or API payloads.</li>
 * </ul>
 *
 * <p>Changing a {@code value()} (e.g. to upper-case) is a privilege /
 * authorisation bug: it would silently rename or drop a Casdoor role
 * grant. The enum CONSTANT names are upper-case (Java convention); the
 * wire token is always the lowercase {@link #value()} — never confuse
 * the two.
 *
 * <h2>Scope — base roles only (a genuinely closed set)</h2>
 *
 * <p>This enum deliberately does <em>not</em> model:
 * <ul>
 *   <li>Per-domain dynamic tenant scopes ({@code DOMAIN_<brand>}) — an
 *       open set keyed on the validated token issuer; see
 *       {@link CasdoorAuthorities} and {@link DomainRegistry}.</li>
 *   <li>Service / capability roles ({@code matrix}, {@code mastodon},
 *       {@code games}, {@code image-builder}, the
 *       {@code *-domainlocked} / {@code *-external-client} variants,
 *       etc.) — an extensible set granted independently that must remain
 *       free-form strings.</li>
 *   <li>Reserved authority prefixes ({@code ROLE_} / {@code DOMAIN_} /
 *       {@code MFA_SATISFIED}) — handled by {@link Roles} and
 *       {@link CasdoorAuthorities}.</li>
 * </ul>
 *
 * <p>This enum <em>complements</em> {@link Roles}: {@code Roles} answers
 * "does this principal hold role X / which domain is it in" at the
 * authority-string level; {@code RoleName} names the lowercase
 * write-boundary tokens passed to Casdoor and usage recording.
 *
 * <h2>Consumers</h2>
 *
 * <ul>
 *   <li>{@code hugmesh-admin-bff-api} — Casdoor role-assignment
 *       calls</li>
 *   <li>{@code hugmesh-federation-api} — usage service role
 *       recording</li>
 *   <li>{@code hugmesh-superadmin-service-catalog-ui} — service-catalog
 *       role grants</li>
 * </ul>
 *
 * @see Roles
 * @see CasdoorAuthorities
 * @see DomainRegistry
 * @since hugmesh-commons initial extraction from per-repo copies
 */
public enum RoleName {

    /**
     * The authenticated-user floor role — every logged-in principal holds
     * at least this role. Wire token: {@code "user"}.
     */
    USER("user"),

    /**
     * The per-domain moderator role — may moderate content within the
     * caller's own brand. Wire token: {@code "mod"}.
     */
    MOD("mod"),

    /**
     * The per-domain administrator role — manages users, services, and
     * configuration within the caller's own brand.
     * Wire token: {@code "admin"}.
     */
    ADMIN("admin"),

    /**
     * The cross-domain infra super-role — unscoped access across every
     * brand; the infra control-plane operator.
     * Wire token: {@code "superadmin"}.
     */
    SUPERADMIN("superadmin");

    /** The lowercase on-the-wire token for this role name. */
    private final String value;

    RoleName(final String wireValue) {
        this.value = wireValue;
    }

    /**
     * The exact lowercase on-the-wire role token (e.g. {@code "admin"}).
     *
     * <p>This is the string Casdoor / usage recording / JSON
     * serialization have always seen. It is emitted as the Jackson
     * serialization of this enum via {@link JsonValue}. Never returns the
     * upper-case Java constant name ({@code ADMIN}) — always the
     * lower-case wire form.
     *
     * @return the lowercase wire token for this role name
     */
    @JsonValue
    public String value() {
        return value;
    }

    /**
     * Resolves a wire token to its {@link RoleName}, or {@code null}
     * when the token is not one of the four closed base roles.
     *
     * <p>Designed to be fail-closed and tolerant:
     * <ul>
     *   <li>A {@code null}, blank, or unknown token (e.g. a dynamic
     *       {@code "matrix"} or {@code "DOMAIN_*"} string) is NOT a
     *       base role and returns {@code null} rather than throwing —
     *       the caller keeps the original string for the open-set
     *       service-role cases.</li>
     *   <li>Matching is case-insensitive and whitespace-trimmed on read
     *       only; the canonical stored and emitted form is always the
     *       lowercase {@link #value()}.</li>
     * </ul>
     *
     * <p>This method is also the Jackson {@link JsonCreator}, so
     * deserializing an unknown role token yields {@code null}
     * (fail-closed) instead of an {@link IllegalArgumentException} that
     * would widen the closed set at runtime.
     *
     * @param token the wire token to resolve (may be {@code null})
     * @return the matching {@link RoleName}, or {@code null} for any
     *         token outside the closed set
     */
    @JsonCreator
    public static RoleName fromWire(final String token) {
        if (token == null) {
            return null;
        }
        String t = token.trim();
        if (t.isEmpty()) {
            return null;
        }
        // Linear scan over 4 constants — sufficient for this closed set.
        for (RoleName r : values()) {
            if (r.value.equalsIgnoreCase(t)) {
                return r;
            }
        }
        return null;
    }

    /**
     * Strict variant of {@link #fromWire(String)}: resolves a token that
     * the caller asserts is a base role, throwing
     * {@link IllegalArgumentException} on any token outside the closed
     * set.
     *
     * <p>Use where an unknown base-role token is a programming error
     * rather than an expected dynamic / open-set value (e.g. validating
     * a role string that came from internal configuration rather than
     * user input).
     *
     * @param token the wire token to resolve; must not be {@code null}
     *              and must be a recognised base-role name
     * @return the matching {@link RoleName}
     * @throws IllegalArgumentException if {@code token} is not one of
     *                                  the four base role names
     */
    public static RoleName require(final String token) {
        RoleName r = fromWire(token);
        if (r == null) {
            throw new IllegalArgumentException(
                    "not a closed base role name: " + token);
        }
        return r;
    }

    /**
     * Returns {@code true} iff {@code token} is one of the four closed
     * base role names (case-insensitive, whitespace-trimmed). Dynamic
     * service-role or domain-scope tokens return {@code false}.
     *
     * @param token the token to test (may be {@code null})
     * @return {@code true} iff {@code token} resolves to a
     *         {@link RoleName}
     */
    public static boolean isBaseRole(final String token) {
        return fromWire(token) != null;
    }

    /**
     * Returns the lowercase wire token — identical to {@link #value()}.
     *
     * <p>Provided so callers that already hold a {@link RoleName} can
     * interpolate it into strings naturally (e.g.
     * {@code "role: " + roleName}). Never returns the upper-case Java
     * constant name.
     *
     * @return the lowercase wire token for this role name
     */
    @Override
    public String toString() {
        return value;
    }
}
