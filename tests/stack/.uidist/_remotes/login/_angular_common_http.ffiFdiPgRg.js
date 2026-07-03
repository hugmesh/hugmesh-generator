import { d as Me, g as Ne, h as De } from "@nf-internal/chunk-ATG6JNNG";
import { a as G, c as Re, d as oe } from "@nf-internal/chunk-PZNONLPT";
import * as d from "@angular/core";
import { \u0275RuntimeError as M, InjectionToken as k, inject as T, NgZone as br, DestroyRef as Pr, \u0275formatRuntimeError as vt, runInInjectionContext as ue, PendingTasks as Ce, CSP_NONCE as Rr, DOCUMENT as Ue, \u0275TracingService as Mr, EnvironmentInjector as Nr, makeEnvironmentProviders as Dr } from "@angular/core";
import { finalize as je, concatMap as Or, filter as _r, map as W, switchMap as Ir } from "rxjs/operators";
import { Observable as he, of as Le, from as Ar } from "rxjs";
var R = class e {
    headers;
    normalizedNames = new Map;
    lazyInit;
    lazyUpdate = null;
    constructor(t) {
        t ? typeof t == "string" ? this.lazyInit = () => {
            this.headers = new Map, t.split(`
`).forEach(r => { let n = r.indexOf(":"); if (n > 0) {
                let o = r.slice(0, n), s = r.slice(n + 1).trim();
                this.addHeaderEntry(o, s);
            } });
        } : typeof Headers < "u" && t instanceof Headers ? (this.headers = new Map, t.forEach((r, n) => { this.addHeaderEntry(n, r); })) : this.lazyInit = () => { this.headers = new Map, Object.entries(t).forEach(([r, n]) => { this.setHeaderEntries(r, n); }); } : this.headers = new Map;
    }
    has(t) { return this.init(), this.headers.has(t.toLowerCase()); }
    get(t) { this.init(); let r = this.headers.get(t.toLowerCase()); return r && r.length > 0 ? r[0] : null; }
    keys() { return this.init(), Array.from(this.normalizedNames.values()); }
    getAll(t) { return this.init(), this.headers.get(t.toLowerCase()) || null; }
    append(t, r) { return this.clone({ name: t, value: r, op: "a" }); }
    set(t, r) { return this.clone({ name: t, value: r, op: "s" }); }
    delete(t, r) { return this.clone({ name: t, value: r, op: "d" }); }
    maybeSetNormalizedName(t, r) { this.normalizedNames.has(r) || this.normalizedNames.set(r, t); }
    init() { this.lazyInit && (this.lazyInit instanceof e ? this.copyFrom(this.lazyInit) : this.lazyInit(), this.lazyInit = null, this.lazyUpdate && (this.lazyUpdate.forEach(t => this.applyUpdate(t)), this.lazyUpdate = null)); }
    copyFrom(t) { t.init(), Array.from(t.headers.keys()).forEach(r => { this.headers.set(r, t.headers.get(r)), this.normalizedNames.set(r, t.normalizedNames.get(r)); }); }
    clone(t) { let r = new e; return r.lazyInit = this.lazyInit && this.lazyInit instanceof e ? this.lazyInit : this, r.lazyUpdate = (this.lazyUpdate || []).concat([t]), r; }
    applyUpdate(t) { let r = t.name.toLowerCase(); switch (t.op) {
        case "a":
        case "s":
            let n = t.value;
            if (typeof n == "string" && (n = [n]), n.length === 0)
                return;
            this.maybeSetNormalizedName(t.name, r);
            let o = (t.op === "a" ? this.headers.get(r) : void 0) || [];
            o.push(...n), this.headers.set(r, o);
            break;
        case "d":
            let s = t.value;
            if (!s)
                this.headers.delete(r), this.normalizedNames.delete(r);
            else {
                let i = this.headers.get(r);
                if (!i)
                    return;
                i = i.filter(c => s.indexOf(c) === -1), i.length === 0 ? (this.headers.delete(r), this.normalizedNames.delete(r)) : this.headers.set(r, i);
            }
            break;
    } }
    addHeaderEntry(t, r) { let n = t.toLowerCase(); this.maybeSetNormalizedName(t, n), this.headers.has(n) ? this.headers.get(n).push(r) : this.headers.set(n, [r]); }
    setHeaderEntries(t, r) { let n = (Array.isArray(r) ? r : [r]).map(s => s.toString()), o = t.toLowerCase(); this.headers.set(o, n), this.maybeSetNormalizedName(t, o); }
    forEach(t) { this.init(), Array.from(this.normalizedNames.keys()).forEach(r => t(this.normalizedNames.get(r), this.headers.get(r))); }
};
var ie = class {
    defaultValue;
    constructor(t) { this.defaultValue = t; }
}, Y = class {
    map = new Map;
    set(t, r) { return this.map.set(t, r), this; }
    get(t) { return this.map.has(t) || this.map.set(t, t.defaultValue()), this.map.get(t); }
    delete(t) { return this.map.delete(t), this; }
    has(t) { return this.map.has(t); }
    keys() { return this.map.keys(); }
}, Z = class {
    encodeKey(t) { return Oe(t); }
    encodeValue(t) { return Oe(t); }
    decodeKey(t) { return decodeURIComponent(t); }
    decodeValue(t) { return decodeURIComponent(t); }
};
function kr(e, t) { let r = new Map; return e.length > 0 && e.replace(/^\?/, "").split("&").forEach(o => { let s = o.indexOf("="), [i, c] = s == -1 ? [t.decodeKey(o), ""] : [t.decodeKey(o.slice(0, s)), t.decodeValue(o.slice(s + 1))], a = r.get(i) || []; a.push(c), r.set(i, a); }), r; }
var xr = /%(\d[a-f0-9])/gi, Fr = { 40: "@", "3A": ":", 24: "$", "2C": ",", "3B": ";", "3D": "=", "3F": "?", "2F": "/" };
function Oe(e) { return encodeURIComponent(e).replace(xr, (t, r) => Fr[r] ?? t); }
function K(e) { return `${e}`; }
var O = class e {
    map;
    encoder;
    updates = null;
    cloneFrom = null;
    constructor(t = {}) { if (this.encoder = t.encoder || new Z, t.fromString) {
        if (t.fromObject)
            throw new M(2805, !1);
        this.map = kr(t.fromString, this.encoder);
    }
    else
        t.fromObject ? (this.map = new Map, Object.keys(t.fromObject).forEach(r => { let n = t.fromObject[r], o = Array.isArray(n) ? n.map(K) : [K(n)]; this.map.set(r, o); })) : this.map = null; }
    has(t) { return this.init(), this.map.has(t); }
    get(t) { this.init(); let r = this.map.get(t); return r ? r[0] : null; }
    getAll(t) { return this.init(), this.map.get(t) || null; }
    keys() { return this.init(), Array.from(this.map.keys()); }
    append(t, r) { return this.clone({ param: t, value: r, op: "a" }); }
    appendAll(t) { let r = []; return Object.keys(t).forEach(n => { let o = t[n]; Array.isArray(o) ? o.forEach(s => { r.push({ param: n, value: s, op: "a" }); }) : r.push({ param: n, value: o, op: "a" }); }), this.clone(r); }
    set(t, r) { return this.clone({ param: t, value: r, op: "s" }); }
    delete(t, r) { return this.clone({ param: t, value: r, op: "d" }); }
    toString() { return this.init(), this.keys().map(t => { let r = this.encoder.encodeKey(t); return this.map.get(t).map(n => r + "=" + this.encoder.encodeValue(n)).join("&"); }).filter(t => t !== "").join("&"); }
    clone(t) { let r = new e({ encoder: this.encoder }); return r.cloneFrom = this.cloneFrom || this, r.updates = (this.updates || []).concat(t), r; }
    init() { this.map === null && (this.map = new Map), this.cloneFrom !== null && (this.cloneFrom.init(), this.cloneFrom.keys().forEach(t => this.map.set(t, this.cloneFrom.map.get(t))), this.updates.forEach(t => { switch (t.op) {
        case "a":
        case "s":
            let r = (t.op === "a" ? this.map.get(t.param) : void 0) || [];
            r.push(K(t.value)), this.map.set(t.param, r);
            break;
        case "d": if (t.value !== void 0) {
            let n = this.map.get(t.param) || [], o = n.indexOf(K(t.value));
            o !== -1 && n.splice(o, 1), n.length > 0 ? this.map.set(t.param, n) : this.map.delete(t.param);
        }
        else {
            this.map.delete(t.param);
            break;
        }
    } }), this.cloneFrom = this.updates = null); }
};
function Sr(e) { switch (e) {
    case "DELETE":
    case "GET":
    case "HEAD":
    case "OPTIONS":
    case "JSONP": return !1;
    default: return !0;
} }
function _e(e) { return typeof ArrayBuffer < "u" && e instanceof ArrayBuffer; }
function Ie(e) { return typeof Blob < "u" && e instanceof Blob; }
function Ae(e) { return typeof FormData < "u" && e instanceof FormData; }
function Cr(e) { return typeof URLSearchParams < "u" && e instanceof URLSearchParams; }
var J = "Content-Type", Q = "Accept", Be = "text/plain", Xe = "application/json", ze = `${Xe}, ${Be}, */*`, U = class e {
    url;
    body = null;
    headers;
    context;
    reportProgress = !1;
    reportUploadProgress = !1;
    reportDownloadProgress = !1;
    withCredentials = !1;
    credentials;
    keepalive = !1;
    cache;
    priority;
    mode;
    redirect;
    referrer;
    integrity;
    referrerPolicy;
    responseType = "json";
    method;
    params;
    urlWithParams;
    transferCache;
    timeout;
    constructor(t, r, n, o) { this.url = r, this.method = t.toUpperCase(); let s; if (Sr(this.method) || o ? (this.body = n !== void 0 ? n : null, s = o) : s = n, s) {
        if (this.reportProgress = !!s.reportProgress, this.reportUploadProgress = !!s.reportUploadProgress, this.reportDownloadProgress = !!s.reportDownloadProgress, this.withCredentials = !!s.withCredentials, this.keepalive = !!s.keepalive, s.responseType && (this.responseType = s.responseType), s.headers && (this.headers = s.headers), s.context && (this.context = s.context), s.params && (this.params = s.params), s.priority && (this.priority = s.priority), s.cache && (this.cache = s.cache), s.credentials && (this.credentials = s.credentials), typeof s.timeout == "number") {
            if (s.timeout < 1 || !Number.isInteger(s.timeout))
                throw new M(2822, "");
            this.timeout = s.timeout;
        }
        s.mode && (this.mode = s.mode), s.redirect && (this.redirect = s.redirect), s.integrity && (this.integrity = s.integrity), s.referrer && (this.referrer = s.referrer), s.referrerPolicy && (this.referrerPolicy = s.referrerPolicy), this.transferCache = s.transferCache;
    } if (this.headers ??= new R, this.context ??= new Y, !this.params)
        this.params = new O, this.urlWithParams = r;
    else {
        let i = this.params.toString();
        if (i.length === 0)
            this.urlWithParams = r;
        else {
            let c = r.indexOf("?"), a = c === -1 ? "?" : c < r.length - 1 ? "&" : "";
            this.urlWithParams = r + a + i;
        }
    } }
    serializeBody() { return this.body === null ? null : typeof this.body == "string" || _e(this.body) || Ie(this.body) || Ae(this.body) || Cr(this.body) ? this.body : this.body instanceof O ? this.body.toString() : typeof this.body == "object" || typeof this.body == "boolean" || Array.isArray(this.body) ? JSON.stringify(this.body) : this.body.toString(); }
    detectContentTypeHeader() { return this.body === null || Ae(this.body) ? null : Ie(this.body) ? this.body.type || null : _e(this.body) ? null : typeof this.body == "string" ? Be : this.body instanceof O ? "application/x-www-form-urlencoded;charset=UTF-8" : typeof this.body == "object" || typeof this.body == "number" || typeof this.body == "boolean" ? Xe : null; }
    clone(t = {}) { let r = t.method || this.method, n = t.url || this.url, o = t.responseType || this.responseType, s = t.keepalive ?? this.keepalive, i = t.priority || this.priority, c = t.cache || this.cache, a = t.mode || this.mode, l = t.redirect || this.redirect, f = t.credentials || this.credentials, u = t.referrer || this.referrer, v = t.integrity || this.integrity, D = t.referrerPolicy || this.referrerPolicy, E = t.transferCache ?? this.transferCache, b = t.timeout ?? this.timeout, g = t.body !== void 0 ? t.body : this.body, y = t.withCredentials ?? this.withCredentials, h = t.reportProgress ?? this.reportProgress, p = t.reportUploadProgress ?? this.reportUploadProgress, w = t.reportDownloadProgress ?? this.reportDownloadProgress, x = t.headers || this.headers, m = t.params || this.params, F = t.context ?? this.context; return t.setHeaders !== void 0 && (x = Object.keys(t.setHeaders).reduce((S, I) => S.set(I, t.setHeaders[I]), x)), t.setParams && (m = Object.keys(t.setParams).reduce((S, I) => S.set(I, t.setParams[I]), m)), new e(r, n, g, { params: m, headers: x, context: F, reportProgress: h, reportUploadProgress: p, reportDownloadProgress: w, responseType: o, withCredentials: y, transferCache: E, keepalive: s, cache: c, priority: i, timeout: b, mode: a, redirect: l, credentials: f, referrer: u, integrity: v, referrerPolicy: D }); }
}, N = (function (e) { return e[e.Sent = 0] = "Sent", e[e.UploadProgress = 1] = "UploadProgress", e[e.ResponseHeader = 2] = "ResponseHeader", e[e.DownloadProgress = 3] = "DownloadProgress", e[e.Response = 4] = "Response", e[e.User = 5] = "User", e; })(N || {}), j = class {
    headers;
    status;
    statusText;
    url;
    ok;
    type;
    redirected;
    responseType;
    constructor(t, r = 200, n = "OK") { this.headers = t.headers || new R, this.status = t.status !== void 0 ? t.status : r, this.statusText = t.statusText || n, this.url = t.url || null, this.redirected = t.redirected, this.responseType = t.responseType, this.ok = this.status >= 200 && this.status < 300; }
}, V = class e extends j {
    constructor(t = {}) { super(t); }
    type = N.ResponseHeader;
    clone(t = {}) { return new e({ headers: t.headers || this.headers, status: t.status !== void 0 ? t.status : this.status, statusText: t.statusText || this.statusText, url: t.url || this.url || void 0 }); }
}, A = class e extends j {
    body;
    constructor(t = {}) { super(t), this.body = t.body !== void 0 ? t.body : null; }
    type = N.Response;
    clone(t = {}) { return new e({ body: t.body !== void 0 ? t.body : this.body, headers: t.headers || this.headers, status: t.status !== void 0 ? t.status : this.status, statusText: t.statusText || this.statusText, url: t.url || this.url || void 0, redirected: t.redirected ?? this.redirected, responseType: t.responseType ?? this.responseType }); }
}, P = class extends j {
    name = "HttpErrorResponse";
    message;
    error;
    ok = !1;
    constructor(t) { super(t, 0, "Unknown Error"), this.status >= 200 && this.status < 300 ? this.message = `Http failure during parsing for ${t.url || "(unknown url)"}` : this.message = `Http failure response for ${t.url || "(unknown url)"}: ${t.status} ${t.statusText}`, this.error = t.error || null; }
}, fe = 200, Ur = 204, Je = (function (e) { return e[e.Continue = 100] = "Continue", e[e.SwitchingProtocols = 101] = "SwitchingProtocols", e[e.Processing = 102] = "Processing", e[e.EarlyHints = 103] = "EarlyHints", e[e.Ok = 200] = "Ok", e[e.Created = 201] = "Created", e[e.Accepted = 202] = "Accepted", e[e.NonAuthoritativeInformation = 203] = "NonAuthoritativeInformation", e[e.NoContent = 204] = "NoContent", e[e.ResetContent = 205] = "ResetContent", e[e.PartialContent = 206] = "PartialContent", e[e.MultiStatus = 207] = "MultiStatus", e[e.AlreadyReported = 208] = "AlreadyReported", e[e.ImUsed = 226] = "ImUsed", e[e.MultipleChoices = 300] = "MultipleChoices", e[e.MovedPermanently = 301] = "MovedPermanently", e[e.Found = 302] = "Found", e[e.SeeOther = 303] = "SeeOther", e[e.NotModified = 304] = "NotModified", e[e.UseProxy = 305] = "UseProxy", e[e.Unused = 306] = "Unused", e[e.TemporaryRedirect = 307] = "TemporaryRedirect", e[e.PermanentRedirect = 308] = "PermanentRedirect", e[e.BadRequest = 400] = "BadRequest", e[e.Unauthorized = 401] = "Unauthorized", e[e.PaymentRequired = 402] = "PaymentRequired", e[e.Forbidden = 403] = "Forbidden", e[e.NotFound = 404] = "NotFound", e[e.MethodNotAllowed = 405] = "MethodNotAllowed", e[e.NotAcceptable = 406] = "NotAcceptable", e[e.ProxyAuthenticationRequired = 407] = "ProxyAuthenticationRequired", e[e.RequestTimeout = 408] = "RequestTimeout", e[e.Conflict = 409] = "Conflict", e[e.Gone = 410] = "Gone", e[e.LengthRequired = 411] = "LengthRequired", e[e.PreconditionFailed = 412] = "PreconditionFailed", e[e.PayloadTooLarge = 413] = "PayloadTooLarge", e[e.UriTooLong = 414] = "UriTooLong", e[e.UnsupportedMediaType = 415] = "UnsupportedMediaType", e[e.RangeNotSatisfiable = 416] = "RangeNotSatisfiable", e[e.ExpectationFailed = 417] = "ExpectationFailed", e[e.ImATeapot = 418] = "ImATeapot", e[e.MisdirectedRequest = 421] = "MisdirectedRequest", e[e.UnprocessableEntity = 422] = "UnprocessableEntity", e[e.Locked = 423] = "Locked", e[e.FailedDependency = 424] = "FailedDependency", e[e.TooEarly = 425] = "TooEarly", e[e.UpgradeRequired = 426] = "UpgradeRequired", e[e.PreconditionRequired = 428] = "PreconditionRequired", e[e.TooManyRequests = 429] = "TooManyRequests", e[e.RequestHeaderFieldsTooLarge = 431] = "RequestHeaderFieldsTooLarge", e[e.UnavailableForLegalReasons = 451] = "UnavailableForLegalReasons", e[e.InternalServerError = 500] = "InternalServerError", e[e.NotImplemented = 501] = "NotImplemented", e[e.BadGateway = 502] = "BadGateway", e[e.ServiceUnavailable = 503] = "ServiceUnavailable", e[e.GatewayTimeout = 504] = "GatewayTimeout", e[e.HttpVersionNotSupported = 505] = "HttpVersionNotSupported", e[e.VariantAlsoNegotiates = 506] = "VariantAlsoNegotiates", e[e.InsufficientStorage = 507] = "InsufficientStorage", e[e.LoopDetected = 508] = "LoopDetected", e[e.NotExtended = 510] = "NotExtended", e[e.NetworkAuthenticationRequired = 511] = "NetworkAuthenticationRequired", e; })(Je || {}), jr = /^\)\]\}',?\n/, Lr = 1024 * 1024, Ve = new k("", { factory: () => typeof ngServerMode < "u" && ngServerMode ? Lr : null }), L = (() => { class e {
    fetchImpl = T(ae, { optional: !0 })?.fetch ?? ((...r) => globalThis.fetch(...r));
    ngZone = T(br);
    destroyRef = T(Pr);
    maxResponseSize = T(Ve);
    handle(r) { return new he(n => { let o = new AbortController; this.doRequest(r, o.signal, n).then(ce, i => n.error(new P({ error: i }))); let s; return r.timeout && (s = this.ngZone.runOutsideAngular(() => setTimeout(() => { o.signal.aborted || o.abort(new DOMException("signal timed out", "TimeoutError")); }, r.timeout))), () => { s !== void 0 && clearTimeout(s), o.abort(); }; }); }
    doRequest(r, n, o) { return oe(this, null, function* () { let s = this.createRequestInit(r), i; try {
        let g = this.ngZone.runOutsideAngular(() => this.fetchImpl(r.urlWithParams, G({ signal: n }, s)));
        Br(g), o.next({ type: N.Sent }), i = yield g;
    }
    catch (g) {
        o.error(new P({ error: g, status: g.status ?? 0, statusText: g.statusText, url: r.urlWithParams, headers: g.headers }));
        return;
    } let c = new R(i.headers), a = i.statusText, l = i.url || r.urlWithParams, f = i.status, u = null, v = r.reportProgress || r.reportDownloadProgress; if (v && o.next(new V({ headers: c, status: f, statusText: a, url: l })), i.body) {
        let g = i.headers.get("content-length"), y = g !== null ? Number(g) : NaN;
        this.maxResponseSize !== null && Number.isFinite(y) && y > this.maxResponseSize && ke(this.maxResponseSize);
        let h = [], p = i.body.getReader(), w = 0, x, m, F = typeof Zone < "u" && Zone.current, S = !1;
        if (yield this.ngZone.runOutsideAngular(() => oe(this, null, function* () { for (;;) {
            if (this.destroyRef.destroyed) {
                yield p.cancel(), S = !0;
                break;
            }
            let { done: z, value: ne } = yield p.read();
            if (z)
                break;
            if (h.push(ne), w += ne.length, this.maxResponseSize !== null && w > this.maxResponseSize && (yield p.cancel(), ke(this.maxResponseSize)), v) {
                m = r.responseType === "text" ? (m ?? "") + (x ??= new TextDecoder).decode(ne, { stream: !0 }) : void 0;
                let Pe = () => o.next({ type: N.DownloadProgress, total: Number.isFinite(y) ? y : void 0, loaded: w, partialText: m });
                F ? F.run(Pe) : Pe();
            }
        } })), S) {
            o.complete();
            return;
        }
        let I = this.concatChunks(h, w);
        try {
            let z = i.headers.get(J) ?? "";
            u = this.parseBody(r, I, z, f);
        }
        catch (z) {
            o.error(new P({ error: z, headers: new R(i.headers), status: i.status, statusText: i.statusText, url: i.url || r.urlWithParams }));
            return;
        }
    } f === 0 && (f = u ? fe : 0); let D = f >= 200 && f < 300, E = i.redirected, b = i.type; D ? (o.next(new A({ body: u, headers: c, status: f, statusText: a, url: l, redirected: E, responseType: b })), o.complete()) : o.error(new P({ error: u, headers: c, status: f, statusText: a, url: l, redirected: E, responseType: b })); }); }
    parseBody(r, n, o, s) { switch (r.responseType) {
        case "json":
            let i = new TextDecoder().decode(n).replace(jr, "");
            if (i === "")
                return null;
            try {
                return JSON.parse(i);
            }
            catch (c) {
                if (s < 200 || s >= 300)
                    return i;
                throw c;
            }
        case "text": return new TextDecoder().decode(n);
        case "blob": return new Blob([n], { type: o });
        case "arraybuffer": return n.buffer;
    } }
    createRequestInit(r) { if (r.reportUploadProgress)
        throw new M(2824, !1); let n = {}, o; if (o = r.credentials, r.withCredentials && (o = "include"), r.headers.forEach((s, i) => n[s] = i.join(",")), r.headers.has(Q) || (n[Q] = ze), !r.headers.has(J)) {
        let s = r.detectContentTypeHeader();
        s !== null && (n[J] = s);
    } return { body: r.serializeBody(), method: r.method, headers: n, credentials: o, keepalive: r.keepalive, cache: r.cache, priority: r.priority, mode: r.mode, redirect: r.redirect, referrer: r.referrer, integrity: r.integrity, referrerPolicy: r.referrerPolicy }; }
    concatChunks(r, n) { let o = new Uint8Array(n), s = 0; for (let i of r)
        o.set(i, s), s += i.length; return o; }
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275prov = d.\u0275\u0275defineService({ token: e, factory: e.\u0275fac });
} return e; })(), ae = class {
};
function ce() { }
function Br(e) { e.then(ce, ce); }
function ke(e) { throw new M(2825, !1); }
function $e(e, t) { return t(e); }
function Xr(e, t) { return (r, n) => t.intercept(r, { handle: o => e(o, n) }); }
function zr(e, t, r) { return (n, o) => ue(r, () => t(n, s => e(s, o))); }
var pe = new k(""), $ = new k("", { factory: () => [] }), ye = new k(""), ge = new k("", { factory: () => !0 });
function Jr() { let e = null; return (t, r) => { e === null && (e = (T(pe, { optional: !0 }) ?? []).reduceRight(Xr, $e)); let n = T(Ce); if (T(ge)) {
    let s = n.add();
    return e(t, r).pipe(je(s));
}
else
    return e(t, r); }; }
var B = (() => { class e {
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: function (n) { let o = null; return n ? o = new (n || e) : o = d.\u0275\u0275inject(L), o; }, providedIn: "root" });
} return e; })();
var q = (() => { class e {
    backend;
    injector;
    chain = null;
    pendingTasks = T(Ce);
    contributeToStability = T(ge);
    constructor(r, n) { this.backend = r, this.injector = n; }
    handle(r) { if (this.chain === null) {
        let n = Array.from(new Set([...this.injector.get($), ...this.injector.get(ye, [])]));
        this.chain = n.reduceRight((o, s) => zr(o, s, this.injector), $e);
    } if (this.contributeToStability) {
        let n = this.pendingTasks.add();
        return this.chain(r, o => this.backend.handle(o)).pipe(je(n));
    }
    else
        return this.chain(r, n => this.backend.handle(n)); }
    static \u0275fac = function (n) { return new (n || e)(d.\u0275\u0275inject(B), d.\u0275\u0275inject(d.EnvironmentInjector)); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: e.\u0275fac, providedIn: "root" });
} return e; })(), ee = (() => { class e {
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: function (n) { let o = null; return n ? o = new (n || e) : o = d.\u0275\u0275inject(q), o; }, providedIn: "root" });
} return e; })();
function se(e, t) { return { body: t, headers: e.headers, context: e.context, observe: e.observe, params: e.params, reportProgress: e.reportProgress, responseType: e.responseType, withCredentials: e.withCredentials, credentials: e.credentials, transferCache: e.transferCache, timeout: e.timeout, keepalive: e.keepalive, priority: e.priority, cache: e.cache, mode: e.mode, redirect: e.redirect, integrity: e.integrity, referrer: e.referrer, referrerPolicy: e.referrerPolicy }; }
var me = (() => { class e {
    handler;
    constructor(r) { this.handler = r; }
    request(r, n, o = {}) { let s; if (r instanceof U)
        s = r;
    else {
        let a;
        o.headers instanceof R ? a = o.headers : a = new R(o.headers);
        let l;
        o.params && (o.params instanceof O ? l = o.params : l = new O({ fromObject: o.params })), s = new U(r, n, o.body !== void 0 ? o.body : null, { headers: a, context: o.context, params: l, reportProgress: o.reportProgress, reportUploadProgress: o.reportUploadProgress, reportDownloadProgress: o.reportDownloadProgress, responseType: o.responseType || "json", withCredentials: o.withCredentials, transferCache: o.transferCache, keepalive: o.keepalive, priority: o.priority, cache: o.cache, mode: o.mode, redirect: o.redirect, credentials: o.credentials, referrer: o.referrer, referrerPolicy: o.referrerPolicy, integrity: o.integrity, timeout: o.timeout });
    } let i = Le(s).pipe(Or(a => this.handler.handle(a))); if (r instanceof U || o.observe === "events")
        return i; let c = i.pipe(_r(a => a instanceof A)); switch (o.observe || "body") {
        case "body": switch (s.responseType) {
            case "arraybuffer": return c.pipe(W(a => { if (a.body !== null && !(a.body instanceof ArrayBuffer))
                throw new M(2806, !1); return a.body; }));
            case "blob": return c.pipe(W(a => { if (a.body !== null && !(a.body instanceof Blob))
                throw new M(2807, !1); return a.body; }));
            case "text": return c.pipe(W(a => { if (a.body !== null && typeof a.body != "string")
                throw new M(2808, !1); return a.body; }));
            default: return c.pipe(W(a => a.body));
        }
        case "response": return c;
        default: throw new M(2809, !1);
    } }
    delete(r, n = {}) { return this.request("DELETE", r, n); }
    get(r, n = {}) { return this.request("GET", r, n); }
    head(r, n = {}) { return this.request("HEAD", r, n); }
    jsonp(r, n) { return this.request("JSONP", r, { params: new O().append(n, "JSONP_CALLBACK"), observe: "body", responseType: "json" }); }
    options(r, n = {}) { return this.request("OPTIONS", r, n); }
    patch(r, n, o = {}) { return this.request("PATCH", r, se(o, n)); }
    post(r, n, o = {}) { return this.request("POST", r, se(o, n)); }
    put(r, n, o = {}) { return this.request("PUT", r, se(o, n)); }
    static \u0275fac = function (n) { return new (n || e)(d.\u0275\u0275inject(ee)); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: e.\u0275fac, providedIn: "root" });
} return e; })(), Vr = 0, xe, $r = "JSONP injected script did not invoke callback.";
var H = class {
};
function Gr() { return typeof window == "object" ? window : {}; }
var Te = (() => { class e {
    callbackMap;
    document;
    resolvedPromise = Promise.resolve();
    nonce = T(Rr, { optional: !0 });
    constructor(r, n) { this.callbackMap = r, this.document = n; }
    nextCallback() { return `ng_jsonp_callback_${Vr++}`; }
    handle(r) { if (r.method !== "JSONP")
        throw new M(2810, !1); if (r.responseType !== "json")
        throw new M(2811, !1); if (r.headers.keys().length > 0)
        throw new M(2812, !1); return new he(n => { let o = this.nextCallback(), s = r.urlWithParams.replace(/=JSONP_CALLBACK(&|$)/, `=${o}$1`), i = this.document.createElement("script"); i.src = s, this.nonce && i.setAttribute("nonce", this.nonce); let c = null, a = !1; this.callbackMap[o] = v => { delete this.callbackMap[o], c = v, a = !0; }; let l = () => { i.removeEventListener("load", f), i.removeEventListener("error", u), i.remove(), delete this.callbackMap[o]; }, f = () => { this.resolvedPromise.then(() => { if (l(), !a) {
        n.error(new P({ url: s, status: 0, statusText: "JSONP Error", error: new Error($r) }));
        return;
    } n.next(new A({ body: c, status: fe, statusText: "OK", url: s })), n.complete(); }); }, u = v => { l(), n.error(new P({ error: v, status: 0, statusText: "JSONP Error", url: s })); }; return i.addEventListener("load", f), i.addEventListener("error", u), this.document.body.appendChild(i), n.next({ type: N.Sent }), () => { a || this.removeListeners(i), l(); }; }); }
    removeListeners(r) { xe ??= this.document.implementation.createHTMLDocument(), xe.adoptNode(r); }
    static \u0275fac = function (n) { return new (n || e)(d.\u0275\u0275inject(H), d.\u0275\u0275inject(Ue)); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: e.\u0275fac });
} return e; })();
function Ge(e, t) { return e.method === "JSONP" ? T(Te).handle(e) : t(e); }
var Wr = (() => { class e {
    injector;
    constructor(r) { this.injector = r; }
    intercept(r, n) { return ue(this.injector, () => Ge(r, o => n.handle(o))); }
    static \u0275fac = function (n) { return new (n || e)(d.\u0275\u0275inject(d.EnvironmentInjector)); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: e.\u0275fac });
} return e; })(), Kr = /^\)\]\}',?\n/;
var de = (() => { class e {
    xhrFactory;
    tracingService = T(Mr, { optional: !0 });
    constructor(r) { this.xhrFactory = r; }
    maybePropagateTrace(r) { return this.tracingService?.propagate ? this.tracingService.propagate(r) : r; }
    handle(r) { if (r.method === "JSONP")
        throw new M(-2800, !1); let n = this.xhrFactory; return (typeof ngServerMode < "u" && ngServerMode && n.\u0275loadImpl ? Ar(n.\u0275loadImpl()) : Le(null)).pipe(Ir(() => new he(s => { let i = n.build(); if (i.open(r.method, r.urlWithParams), r.withCredentials && (i.withCredentials = !0), r.headers.forEach((h, p) => i.setRequestHeader(h, p.join(","))), r.headers.has(Q) || i.setRequestHeader(Q, ze), !r.headers.has(J)) {
        let h = r.detectContentTypeHeader();
        h !== null && i.setRequestHeader(J, h);
    } if (r.timeout && (i.timeout = r.timeout), r.responseType) {
        let h = r.responseType.toLowerCase();
        i.responseType = h !== "json" ? h : "text";
    } let c = r.serializeBody(), a = null, l = () => { if (a !== null)
        return a; let h = i.statusText || "OK", p = new R(i.getAllResponseHeaders()), w = i.responseURL || r.url; return a = new V({ headers: p, status: i.status, statusText: h, url: w }), a; }, f = this.maybePropagateTrace(() => { let { headers: h, status: p, statusText: w, url: x } = l(), m = null; p !== Ur && (m = typeof i.response > "u" ? i.responseText : i.response), p === 0 && (p = m ? fe : 0); let F = p >= 200 && p < 300; if (r.responseType === "json" && typeof m == "string") {
        let S = m;
        m = m.replace(Kr, "");
        try {
            m = m !== "" ? JSON.parse(m) : null;
        }
        catch (I) {
            m = S, F && (F = !1, m = { error: I, text: m });
        }
    } F ? (s.next(new A({ body: m, headers: h, status: p, statusText: w, url: x || void 0 })), s.complete()) : s.error(new P({ error: m, headers: h, status: p, statusText: w, url: x || void 0 })); }), u = this.maybePropagateTrace(h => { let { url: p } = l(), w = new P({ error: h, status: i.status || 0, statusText: i.statusText || "Unknown Error", url: p || void 0 }); s.error(w); }), v = u; r.timeout && (v = this.maybePropagateTrace(h => { let { url: p } = l(), w = new P({ error: new DOMException("Request timed out", "TimeoutError"), status: i.status || 0, statusText: i.statusText || "Request timeout", url: p || void 0 }); s.error(w); })); let D = !1, E = this.maybePropagateTrace(h => { D || (s.next(l()), D = !0); let p = { type: N.DownloadProgress, loaded: h.loaded }; h.lengthComputable && (p.total = h.total), r.responseType === "text" && i.responseText && (p.partialText = i.responseText), s.next(p); }), b = this.maybePropagateTrace(h => { let p = { type: N.UploadProgress, loaded: h.loaded }; h.lengthComputable && (p.total = h.total), s.next(p); }); i.addEventListener("load", f), i.addEventListener("error", u), i.addEventListener("timeout", v), i.addEventListener("abort", u); let g = r.reportProgress || r.reportUploadProgress, y = r.reportProgress || r.reportDownloadProgress; return y && i.addEventListener("progress", E), g && c !== null && i.upload && i.upload.addEventListener("progress", b), i.send(c), s.next({ type: N.Sent }), () => { i.removeEventListener("error", u), i.removeEventListener("abort", u), i.removeEventListener("load", f), i.removeEventListener("timeout", v), y && i.removeEventListener("progress", E), g && c !== null && i.upload && i.upload.removeEventListener("progress", b), i.readyState !== i.DONE && i.abort(); }; }))); }
    static \u0275fac = function (n) { return new (n || e)(d.\u0275\u0275inject(De)); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: e.\u0275fac, providedIn: "root" });
} return e; })(), ve = new k("", { factory: () => !0 }), We = "XSRF-TOKEN", Ke = new k("", { factory: () => We }), Ye = "X-XSRF-TOKEN", Ze = new k("", { factory: () => Ye }), Qe = (() => { class e {
    cookieName = T(Ke);
    doc = T(Ue);
    lastCookieString = "";
    lastToken = null;
    parseCount = 0;
    getToken() { if (typeof ngServerMode < "u" && ngServerMode)
        return null; let r = this.doc.cookie || ""; return r !== this.lastCookieString && (this.parseCount++, this.lastToken = Ne(r, this.cookieName), this.lastCookieString = r), this.lastToken; }
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275prov = d.\u0275\u0275defineService({ token: e, factory: e.\u0275fac });
} return e; })(), we = (() => { class e {
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: function (n) { let o = null; return n ? o = new (n || e) : o = d.\u0275\u0275inject(Qe), o; }, providedIn: "root" });
} return e; })();
function qe(e, t) { if (!T(ve) || e.method === "GET" || e.method === "HEAD")
    return t(e); try {
    let o = T(Me).href, { origin: s } = new URL(o), { origin: i } = new URL(e.url, s);
    if (s !== i)
        return t(e);
}
catch {
    return t(e);
} let r = T(we).getToken(), n = T(Ze); return r != null && !e.headers.has(n) && (e = e.clone({ headers: e.headers.set(n, r) })), t(e); }
var Fe = (() => { class e {
    injector = T(Nr);
    intercept(r, n) { return ue(this.injector, () => qe(r, o => n.handle(o))); }
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: e, factory: e.\u0275fac });
} return e; })(), _ = (function (e) { return e[e.Interceptors = 0] = "Interceptors", e[e.LegacyInterceptors = 1] = "LegacyInterceptors", e[e.CustomXsrfConfiguration = 2] = "CustomXsrfConfiguration", e[e.NoXsrfProtection = 3] = "NoXsrfProtection", e[e.JsonpSupport = 4] = "JsonpSupport", e[e.RequestsMadeViaParent = 5] = "RequestsMadeViaParent", e[e.Fetch = 6] = "Fetch", e[e.Xhr = 7] = "Xhr", e; })(_ || {});
function C(e, t) { return { \u0275kind: e, \u0275providers: t }; }
function He(...e) { let t = [me, L, q, { provide: ee, useExisting: q }, { provide: B, useFactory: () => T(L) }, { provide: $, useValue: qe, multi: !0 }]; for (let r of e)
    t.push(...r.\u0275providers); return Dr(t); }
function Yr(e) { return C(_.Interceptors, e.map(t => ({ provide: $, useValue: t, multi: !0 }))); }
var Se = new k("");
function er() { return C(_.LegacyInterceptors, [{ provide: Se, useFactory: Jr }, { provide: $, useExisting: Se, multi: !0 }]); }
function le({ cookieName: e, headerName: t }) { let r = []; return e !== void 0 && r.push({ provide: Ke, useValue: e }), t !== void 0 && r.push({ provide: Ze, useValue: t }), C(_.CustomXsrfConfiguration, r); }
function rr() { return C(_.NoXsrfProtection, [{ provide: ve, useValue: !1 }]); }
function tr() { return C(_.JsonpSupport, [Te, { provide: H, useFactory: Gr }, { provide: $, useValue: Ge, multi: !0 }]); }
function Zr() { return C(_.RequestsMadeViaParent, [{ provide: B, useFactory: () => T(ee, { skipSelf: !0, optional: !0 }) }]); }
function Qr() { return C(_.Fetch, [L, { provide: B, useExisting: L }]); }
function nr() { return C(_.Xhr, [de, { provide: B, useExisting: de }]); }
var qr = (() => { class e {
    static disable() { return { ngModule: e, providers: [rr().\u0275providers] }; }
    static withOptions(r = {}) { return { ngModule: e, providers: le(r).\u0275providers }; }
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275mod = d.\u0275\u0275defineNgModule({ type: e });
    static \u0275inj = d.\u0275\u0275defineInjector({ providers: [Fe, { provide: pe, useExisting: Fe, multi: !0 }, { provide: we, useClass: Qe }, le({ cookieName: We, headerName: Ye }).\u0275providers, { provide: ve, useValue: !0 }] });
} return e; })(), Hr = (() => { class e {
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275mod = d.\u0275\u0275defineNgModule({ type: e });
    static \u0275inj = d.\u0275\u0275defineInjector({ providers: [He(er(), nr())] });
} return e; })(), et = (() => { class e {
    static \u0275fac = function (n) { return new (n || e); };
    static \u0275mod = d.\u0275\u0275defineNgModule({ type: e });
    static \u0275inj = d.\u0275\u0275defineInjector({ providers: [tr().\u0275providers] });
} return e; })();
import { InjectionToken as ir, APP_BOOTSTRAP_LISTENER as rt, \u0275performanceMarkFeature as tt, inject as X, ApplicationRef as nt, TransferState as ar, \u0275RuntimeError as cr, makeStateKey as ot, \u0275truncateMiddle as xt, \u0275formatRuntimeError as Ft, Injector as st, signal as dr, \u0275ResourceImpl as it, linkedSignal as Ee, computed as at, \u0275encapsulateResourceError as ct } from "@angular/core";
import { of as dt } from "rxjs";
import { tap as lt } from "rxjs/operators";
var lr = new ir(""), ur = "b", hr = "h", fr = "s", pr = "st", yr = "u", gr = "rt", te = new ir(""), ut = ["GET", "HEAD"];
function mr(e, t) { let i = t, { isCacheActive: r } = i, n = Re(i, ["isCacheActive"]), { transferCache: o, method: s } = e; return !(!r || o === !1 || e.withCredentials || s === "POST" && !n.includePostRequests && !o || s !== "POST" && !ut.includes(s) || !n.includeRequestsWithAuthHeaders && ft(e) || n.filter?.(e) === !1); }
function Tr(e, t) { let { includeHeaders: r } = e, n = r; return typeof t == "object" && t.includeHeaders && (n = t.includeHeaders), n; }
function vr(e, t, r, n) { let { transferCache: o } = e; if (!mr(e, t))
    return null; if (typeof ngServerMode < "u" && !ngServerMode && n)
    throw new cr(2803, !1); let s = typeof ngServerMode < "u" && ngServerMode && n ? Er(e.url, n) : e.url, i = wr(e, s), c = r.get(i, null), a = Tr(t, o); if (c) {
    let { [ur]: l, [gr]: f, [hr]: u, [fr]: v, [pr]: D, [yr]: E } = c, b = l;
    switch (f) {
        case "arraybuffer":
            b = sr(l);
            break;
        case "blob":
            b = new Blob([sr(l)]);
            break;
    }
    let g = new R(u);
    return new A({ body: b, headers: g, status: v, statusText: D, url: E });
} return null; }
function ht(e, t) { let r = X(te), n = X(ar), o = X(lr, { optional: !0 }), s = vr(e, r, n, o); if (s)
    return dt(s); let { transferCache: i } = e, c = Tr(r, i), a = typeof ngServerMode < "u" && ngServerMode && o ? Er(e.url, o) : e.url, l = wr(e, a); if (!mr(e, r))
    return t(e); let f = t(e); return typeof ngServerMode < "u" && ngServerMode ? f.pipe(lt(u => { u instanceof A && n.set(l, { [ur]: e.responseType === "arraybuffer" || e.responseType === "blob" ? gt(u.body) : u.body, [hr]: pt(u.headers, c), [fr]: u.status, [pr]: u.statusText, [yr]: a, [gr]: e.responseType }); })) : f; }
function ft(e) { return e.headers.has("authorization") || e.headers.has("proxy-authorization") || e.headers.has("cookie"); }
function pt(e, t) { if (!t)
    return {}; let r = {}; for (let n of t) {
    let o = e.getAll(n);
    o !== null && (r[n] = o);
} return r; }
function or(e) { return [...e.keys()].sort().map(t => `${t}=${e.getAll(t)}`).join("&"); }
function wr(e, t) { let { params: r, method: n, responseType: o } = e, s = or(r), i = e.serializeBody(); i instanceof URLSearchParams ? i = or(i) : typeof i != "string" && (i = ""); let c = [n, o, t, i, s].join("|"), a = yt(c); return ot(a); }
function yt(e) { let t = 0; for (let r of e)
    t = Math.imul(31, t) + r.charCodeAt(0) << 0; return t += 2147483648, t.toString(); }
function gt(e) { let t = new Uint8Array(e), r = 32768, n = ""; for (let o = 0; o < t.length; o += r) {
    let s = t.subarray(o, o + r);
    n += String.fromCharCode.apply(null, s);
} return btoa(n); }
function sr(e) { let t = atob(e); return Uint8Array.from(t, n => n.charCodeAt(0)).buffer; }
function jt(e) { return [{ provide: te, useFactory: () => (tt("NgHttpTransferCache"), G({ isCacheActive: !0 }, e)) }, { provide: ye, useValue: ht, multi: !0 }, { provide: rt, multi: !0, useFactory: () => { let t = X(nt), r = X(te); return () => { t.whenStable().then(() => { r.isCacheActive = !1; }); }; } }]; }
function Er(e, t) { let r = new URL(e, "resolve://").origin, n = t[r]; return n ? e.replace(r, n) : e; }
var Lt = (() => { let e = re("json"); return e.arrayBuffer = re("arraybuffer"), e.blob = re("blob"), e.text = re("text"), e; })();
function re(e) { return function (r, n) { let o = n?.injector ?? X(st), s = o.get(te, null, { optional: !0 }), i = o.get(ar, null, { optional: !0 }), c = o.get(lr, null, { optional: !0 }), a = l => { if (s && i && l) {
    let f = vr(l, s, i, c);
    if (f)
        try {
            let u = f.body, v = n?.parse ? n.parse(u) : u;
            return dr({ value: v });
        }
        catch { }
} }; return new be(o, l => mt(l, r, e), n?.defaultValue, n?.debugName, n?.parse, n?.equal, a); }; }
function mt(e, t, r) { let n = typeof t == "function" ? t(e) : t; if (n === void 0)
    return; typeof n == "string" && (n = { url: n }); let o = n.headers instanceof R ? n.headers : new R(n.headers), s = n.params instanceof O ? n.params : new O({ fromObject: n.params }); return new U(n.method ?? "GET", n.url, n.body ?? null, { headers: o, params: s, reportProgress: n.reportProgress, withCredentials: n.withCredentials, keepalive: n.keepalive, cache: n.cache, priority: n.priority, mode: n.mode, redirect: n.redirect, responseType: r, context: n.context, transferCache: n.transferCache, credentials: n.credentials, referrer: n.referrer, referrerPolicy: n.referrerPolicy, integrity: n.integrity, timeout: n.timeout }); }
var be = class extends it {
    client;
    _headers = Ee({ source: this.extRequest, computation: () => { } });
    _progress = Ee({ source: this.extRequest, computation: () => { } });
    _statusCode = Ee({ source: this.extRequest, computation: () => { } });
    headers = at(() => this.status() === "resolved" || this.status() === "error" ? this._headers() : void 0);
    progress = this._progress.asReadonly();
    statusCode = this._statusCode.asReadonly();
    constructor(t, r, n, o, s, i, c) { super(r, ({ params: a, abortSignal: l }) => { let f, u = !1, v = () => { u = !0, f?.unsubscribe(); }; l.addEventListener("abort", v); let D = dr({ value: void 0 }), E, b = new Promise(y => E = y), g = y => { D.set(y), E?.(D), E = void 0; }; return f = this.client.request(a).subscribe({ next: y => { switch (y.type) {
            case N.Response:
                this._headers.set(y.headers), this._statusCode.set(y.status);
                try {
                    g({ value: s ? s(y.body) : y.body });
                }
                catch (h) {
                    g({ error: ct(h) });
                }
                break;
            case N.DownloadProgress:
                this._progress.set(y);
                break;
        } }, error: y => { y instanceof P && (this._headers.set(y.headers), this._statusCode.set(y.status)), g({ error: y }), l.removeEventListener("abort", v); }, complete: () => { E && g({ error: new cr(991, !1) }), l.removeEventListener("abort", v); } }), u && f.unsubscribe(), b; }, n, i, o, t, void 0, c), this.client = t.get(me); }
    set(t) { super.set(t), this._headers.set(void 0), this._progress.set(void 0), this._statusCode.set(void 0); }
};
export { L as FetchBackend, pe as HTTP_INTERCEPTORS, lr as HTTP_TRANSFER_CACHE_ORIGIN_MAP, B as HttpBackend, me as HttpClient, et as HttpClientJsonpModule, Hr as HttpClientModule, qr as HttpClientXsrfModule, Y as HttpContext, ie as HttpContextToken, P as HttpErrorResponse, N as HttpEventType, _ as HttpFeatureKind, ee as HttpHandler, V as HttpHeaderResponse, R as HttpHeaders, O as HttpParams, U as HttpRequest, A as HttpResponse, j as HttpResponseBase, Je as HttpStatusCode, Z as HttpUrlEncodingCodec, de as HttpXhrBackend, we as HttpXsrfTokenExtractor, Te as JsonpClientBackend, Wr as JsonpInterceptor, Lt as httpResource, He as provideHttpClient, Qr as withFetch, Yr as withInterceptors, er as withInterceptorsFromDi, tr as withJsonpSupport, rr as withNoXsrfProtection, Zr as withRequestsMadeViaParent, nr as withXhr, le as withXsrfConfiguration, Ve as \u0275HTTP_FETCH_MAX_RESPONSE_SIZE, ye as \u0275HTTP_ROOT_INTERCEPTOR_FNS, q as \u0275HttpInterceptingHandler, ge as \u0275REQUESTS_CONTRIBUTE_TO_STABILITY, jt as \u0275withHttpTransferCache };
/*! Bundled license information:

@angular/common/fesm2022/_module-chunk.mjs:
@angular/common/fesm2022/http.mjs:
  (**
   * @license Angular v22.0.0
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
