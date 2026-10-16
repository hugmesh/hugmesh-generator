package net.hugmesh.commons.web;

import org.springframework.http.HttpStatus;

/**
 * Application-level HTTP exception carrying an {@link HttpStatus} and a
 * human-readable message that the BFF exception handler renders as
 * {@code {"error": "<message>"}} in the response body.
 *
 * <h2>Responsibility</h2>
 *
 * <p>Thrown by BFF controllers for session / application-level checks
 * (authorisation failures, missing resources, state conflicts, etc.) and
 * caught by each repo's reactive {@code @ControllerAdvice} /
 * {@code WebExceptionHandler}, which maps it directly to the HTTP status
 * and JSON error body the Angular UIs expect.
 *
 * <p>This is the canonical, shared form of the class. Earlier per-repo
 * copies were logically identical but diverged in which factory methods
 * they declared; this version carries the union of all factory methods so
 * every BFF can depend on a single type.
 *
 * <h2>Consumers</h2>
 *
 * <p>Used as a thrown / caught exception in:
 * <ul>
 *   <li>{@code hugmesh-admin-bff-api} — controller / service layer
 *       checks</li>
 *   <li>{@code hugmesh-federation-api} — federation controller session
 *       checks</li>
 *   <li>{@code hugmesh-user-bff-api} — user console session checks</li>
 *   <li>{@code hugmesh-owncast-bff-api} — streaming service session
 *       checks</li>
 *   <li>{@code hugmesh-forum-bff-api} — forum BFF session checks</li>
 * </ul>
 *
 * <h2>Usage pattern</h2>
 *
 * <pre>{@code
 *   if (!principal.hasDomain(targetDomain)) {
 *       throw ApiException.forbidden("not your domain");
 *   }
 * }</pre>
 *
 * <p>In a reactive chain, wrap with {@code Mono.error(...)}:
 *
 * <pre>{@code
 *   return repo.findById(id)
 *       .switchIfEmpty(Mono.error(ApiException.notFound("not found")));
 * }</pre>
 *
 * @see org.springframework.http.HttpStatus
 * @since hugmesh-commons initial extraction from per-repo copies
 */
public class ApiException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    /** The HTTP status code returned to the client. */
    private final HttpStatus status;

    /**
     * Creates an {@code ApiException} with the given HTTP status and message.
     *
     * @param httpStatus  the HTTP status code to return to the client
     * @param message the human-readable error text rendered as
     *                {@code {"error": "<message>"}} in the response body
     */
    public ApiException(final HttpStatus httpStatus, final String message) {
        super(message);
        this.status = httpStatus;
    }

    /**
     * The HTTP status code this exception maps to.
     *
     * @return the {@link HttpStatus} set at construction time
     */
    public HttpStatus status() {
        return status;
    }

    // -----------------------------------------------------------------------
    // Factory methods — one per HTTP status used across the BFF codebase
    // -----------------------------------------------------------------------

    /**
     * Creates a {@code 401 Unauthorized} exception — the session/token is
     * absent or invalid; the client must (re-)authenticate.
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 401}
     */
    public static ApiException unauthorized(final String msg) {
        return new ApiException(HttpStatus.UNAUTHORIZED, msg);
    }

    /**
     * Creates a {@code 403 Forbidden} exception — the caller is
     * authenticated but lacks the authority to perform the requested
     * operation (e.g. wrong domain, insufficient role).
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 403}
     */
    public static ApiException forbidden(final String msg) {
        return new ApiException(HttpStatus.FORBIDDEN, msg);
    }

    /**
     * Creates a {@code 404 Not Found} exception — the requested resource
     * does not exist or is not visible to the caller.
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 404}
     */
    public static ApiException notFound(final String msg) {
        return new ApiException(HttpStatus.NOT_FOUND, msg);
    }

    /**
     * Creates a {@code 410 Gone} exception — the resource existed but has
     * been permanently removed (e.g. a deleted account or expired token).
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 410}
     */
    public static ApiException gone(final String msg) {
        return new ApiException(HttpStatus.GONE, msg);
    }

    /**
     * Creates a {@code 400 Bad Request} exception — the caller supplied a
     * malformed or semantically invalid request.
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 400}
     */
    public static ApiException badRequest(final String msg) {
        return new ApiException(HttpStatus.BAD_REQUEST, msg);
    }

    /**
     * Creates a {@code 409 Conflict} exception — the request conflicts
     * with the current state of the resource (e.g. a duplicate name or a
     * state-machine violation).
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 409}
     */
    public static ApiException conflict(final String msg) {
        return new ApiException(HttpStatus.CONFLICT, msg);
    }

    /**
     * Creates a {@code 502 Bad Gateway} exception — an upstream dependency
     * (Casdoor, an external service) returned an unexpected or invalid
     * response.
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 502}
     */
    public static ApiException badGateway(final String msg) {
        return new ApiException(HttpStatus.BAD_GATEWAY, msg);
    }

    /**
     * Creates a {@code 503 Service Unavailable} exception — a required
     * upstream service is temporarily unreachable or overloaded.
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 503}
     */
    public static ApiException serviceUnavailable(final String msg) {
        return new ApiException(HttpStatus.SERVICE_UNAVAILABLE, msg);
    }

    /**
     * Creates a {@code 422 Unprocessable Content} exception — the request
     * was well-formed but failed semantic validation (e.g. business-rule
     * violations that aren't covered by {@code 400}).
     *
     * @param msg the error message included in the response body
     * @return a new {@link ApiException} with status {@code 422}
     */
    public static ApiException unprocessable(final String msg) {
        return new ApiException(HttpStatus.UNPROCESSABLE_CONTENT, msg);
    }
}
