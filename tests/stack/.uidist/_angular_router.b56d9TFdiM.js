import { a as l, b as E, d as S } from "@nf-internal/chunk-PZNONLPT";
import { DOCUMENT as zn, Location as Jt } from "@angular/common";
import * as R from "@angular/core";
import { \u0275isPromise as Hn, \u0275RuntimeError as T, computed as Fn, InjectionToken as ie, EventEmitter as Ye, input as qn, inject as g, ViewContainerRef as Bn, ChangeDetectorRef as Vn, reflectComponentType as Gn, runInInjectionContext as j, \u0275isInjectable as Wn, \u0275isNgModule as Fa, isStandalone as qa, createEnvironmentInjector as Qn, Compiler as Kn, \u0275maybeUnwrapDefaultExport as Er, NgModuleFactory as Yn, afterNextRender as Zn, signal as Rr, EnvironmentInjector as Xt, DestroyRef as Jn, untracked as Ue, \u0275Console as Xn, \u0275PendingTasksInternal as ei, \u0275INTERNAL_APPLICATION_ERROR_HANDLER as ti, \u0275formatRuntimeError as ri } from "@angular/core";
import { isObservable as Tr, from as W, of as v, BehaviorSubject as F, combineLatest as Nr, EmptyError as ni, Observable as ii, concat as oi, defer as er, pipe as ai, EMPTY as z, throwError as si, Subject as Pt, Subscription as ci } from "rxjs";
import { first as he, map as D, switchMap as H, take as Le, startWith as ui, filter as xe, takeUntil as Lt, mergeMap as ce, concatMap as Mr, tap as G, takeLast as Dr, catchError as _r, finalize as li } from "rxjs/operators";
import * as Ur from "@angular/platform-browser";
var f = "primary", Be = Symbol("RouteTitle"), xt = class {
    params;
    constructor(n) { this.params = n || {}; }
    has(n) { return Object.prototype.hasOwnProperty.call(this.params, n); }
    get(n) { if (this.has(n)) {
        let e = this.params[n];
        return Array.isArray(e) ? e[0] : e;
    } return null; }
    getAll(n) { if (this.has(n)) {
        let e = this.params[n];
        return Array.isArray(e) ? e : [e];
    } return []; }
    get keys() { return Object.keys(this.params); }
};
function ue(t) { return new xt(t); }
function Dt(t, n, e) { for (let r = 0; r < t.length; r++) {
    let i = t[r], o = n[r];
    if (i[0] === ":")
        e[i.substring(1)] = o;
    else if (i !== o.path)
        return !1;
} return !0; }
function Or(t, n, e) { let r = e.path.split("/"), i = r.indexOf("**"); if (i === -1) {
    if (r.length > t.length || e.pathMatch === "full" && (n.hasChildren() || r.length < t.length))
        return null;
    let s = {}, u = t.slice(0, r.length);
    return Dt(r, u, s) ? { consumed: u, posParams: s } : null;
} if (i !== r.lastIndexOf("**"))
    return null; let o = r.slice(0, i), a = r.slice(i + 1); if (o.length + a.length > t.length || e.pathMatch === "full" && n.hasChildren() && e.path !== "**")
    return null; let c = {}; return !Dt(o, t.slice(0, o.length), c) || !Dt(a, t.slice(t.length - a.length), c) ? null : { consumed: t, posParams: c }; }
function rt(t) { return new Promise((n, e) => { t.pipe(he()).subscribe({ next: r => n(r), error: r => e(r) }); }); }
function hi(t, n) { if (t.length !== n.length)
    return !1; for (let e = 0; e < t.length; ++e)
    if (!Q(t[e], n[e]))
        return !1; return !0; }
function Q(t, n) { let e = t ? jt(t) : void 0, r = n ? jt(n) : void 0; if (!e || !r || e.length != r.length)
    return !1; let i; for (let o = 0; o < e.length; o++)
    if (i = e[o], !Pr(t[i], n[i]))
        return !1; return !0; }
function jt(t) { return [...Object.keys(t), ...Object.getOwnPropertySymbols(t)]; }
function Pr(t, n) { if (Array.isArray(t) && Array.isArray(n)) {
    if (t.length !== n.length)
        return !1;
    let e = [...t].sort(), r = [...n].sort();
    return e.every((i, o) => r[o] === i);
}
else
    return t === n; }
function di(t) { return t.length > 0 ? t[t.length - 1] : null; }
function de(t) { return Tr(t) ? t : Hn(t) ? W(Promise.resolve(t)) : v(t); }
function Lr(t) { return Tr(t) ? rt(t) : Promise.resolve(t); }
var fi = { exact: jr, subset: kr }, xr = { exact: pi, subset: gi, ignored: () => !0 }, tr = { paths: "exact", fragment: "ignored", matrixParams: "ignored", queryParams: "exact" }, je = { paths: "subset", fragment: "ignored", matrixParams: "ignored", queryParams: "subset" };
function rr(t, n, e) { let r = t instanceof M ? t : n.parseUrl(t); return Fn(() => kt(n.lastSuccessfulNavigation()?.finalUrl ?? new M, r, l(l({}, je), e))); }
function kt(t, n, e) { return fi[e.paths](t.root, n.root, e.matrixParams) && xr[e.queryParams](t.queryParams, n.queryParams) && !(e.fragment === "exact" && t.fragment !== n.fragment); }
function pi(t, n) { return Q(t, n); }
function jr(t, n, e) { if (!se(t.segments, n.segments) || !Xe(t.segments, n.segments, e) || t.numberOfChildren !== n.numberOfChildren)
    return !1; for (let r in n.children)
    if (!t.children[r] || !jr(t.children[r], n.children[r], e))
        return !1; return !0; }
function gi(t, n) { return Object.keys(n).length <= Object.keys(t).length && Object.keys(n).every(e => Pr(t[e], n[e])); }
function kr(t, n, e) { return $r(t, n, n.segments, e); }
function $r(t, n, e, r) { if (t.segments.length > e.length) {
    let i = t.segments.slice(0, e.length);
    return !(!se(i, e) || n.hasChildren() || !Xe(i, e, r));
}
else if (t.segments.length === e.length) {
    if (!se(t.segments, e) || !Xe(t.segments, e, r))
        return !1;
    for (let i in n.children)
        if (!t.children[i] || !kr(t.children[i], n.children[i], r))
            return !1;
    return !0;
}
else {
    let i = e.slice(0, t.segments.length), o = e.slice(t.segments.length);
    return !se(t.segments, i) || !Xe(t.segments, i, r) || !t.children[f] ? !1 : $r(t.children[f], n, o, r);
} }
function Xe(t, n, e) { return n.every((r, i) => xr[e](t[i].parameters, r.parameters)); }
var M = class {
    root;
    queryParams;
    fragment;
    _queryParamMap;
    constructor(n = new y([], {}), e = {}, r = null) { this.root = n, this.queryParams = e, this.fragment = r; }
    get queryParamMap() { return this._queryParamMap ??= ue(this.queryParams), this._queryParamMap; }
    toString() { return yi.serialize(this); }
}, y = class {
    segments;
    children;
    parent = null;
    constructor(n, e) { this.segments = n, this.children = e, Object.values(e).forEach(r => r.parent = this); }
    hasChildren() { return this.numberOfChildren > 0; }
    get numberOfChildren() { return Object.keys(this.children).length; }
    toString() { return et(this); }
}, te = class {
    path;
    parameters;
    _parameterMap;
    constructor(n, e) { this.path = n, this.parameters = e; }
    get parameterMap() { return this._parameterMap ??= ue(this.parameters), this._parameterMap; }
    toString() { return Hr(this); }
};
function vi(t, n) { return se(t, n) && t.every((e, r) => Q(e.parameters, n[r].parameters)); }
function se(t, n) { return t.length !== n.length ? !1 : t.every((e, r) => e.path === n[r].path); }
function mi(t, n) { let e = []; return Object.entries(t.children).forEach(([r, i]) => { r === f && (e = e.concat(n(i, r))); }), Object.entries(t.children).forEach(([r, i]) => { r !== f && (e = e.concat(n(i, r))); }), e; }
var oe = (() => { class t {
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: () => new J });
} return t; })(), J = class {
    parse(n) { let e = new zt(n); return new M(e.parseRootSegment(), e.parseQueryParams(), e.parseFragment()); }
    serialize(n) { let e = `/${De(n.root, !0)}`, r = Ci(n.queryParams), i = typeof n.fragment == "string" ? `#${Ri(n.fragment)}` : ""; return `${e}${r}${i}`; }
}, yi = new J;
function et(t) { return t.segments.map(n => Hr(n)).join("/"); }
function De(t, n) { if (!t.hasChildren())
    return et(t); if (n) {
    let e = t.children[f] ? De(t.children[f], !1) : "", r = [];
    return Object.entries(t.children).forEach(([i, o]) => { i !== f && r.push(`${i}:${De(o, !1)}`); }), r.length > 0 ? `${e}(${r.join("//")})` : e;
}
else {
    let e = mi(t, (r, i) => i === f ? [De(t.children[f], !1)] : [`${i}:${De(r, !1)}`]);
    return Object.keys(t.children).length === 1 && t.children[f] != null ? `${et(t)}/${e[0]}` : `${et(t)}/(${e.join("//")})`;
} }
function zr(t) { return encodeURIComponent(t).replace(/%40/g, "@").replace(/%3A/gi, ":").replace(/%24/g, "$").replace(/%2C/gi, ","); }
function Ze(t) { return zr(t).replace(/%3B/gi, ";"); }
function Ri(t) { return encodeURI(t); }
function $t(t) { return zr(t).replace(/\(/g, "%28").replace(/\)/g, "%29").replace(/%26/gi, "&"); }
function tt(t) { return decodeURIComponent(t); }
function Sr(t) { return tt(t.replace(/\+/g, "%20")); }
function Hr(t) { return `${$t(t.path)}${Si(t.parameters)}`; }
function Si(t) { return Object.entries(t).map(([n, e]) => `;${$t(n)}=${$t(e)}`).join(""); }
function Ci(t) { let n = Object.entries(t).map(([e, r]) => Array.isArray(r) ? r.map(i => `${Ze(e)}=${Ze(i)}`).join("&") : `${Ze(e)}=${Ze(r)}`).filter(e => e); return n.length ? `?${n.join("&")}` : ""; }
var wi = /^[^\/()?;#]+/;
function _t(t) { let n = t.match(wi); return n ? n[0] : ""; }
var bi = /^[^\/()?;=#]+/;
function Ii(t) { let n = t.match(bi); return n ? n[0] : ""; }
var Ai = /^[^=?&#]+/;
function Ei(t) { let n = t.match(Ai); return n ? n[0] : ""; }
var Ti = /^[^&#]+/;
function Ni(t) { let n = t.match(Ti); return n ? n[0] : ""; }
var zt = class {
    url;
    remaining;
    constructor(n) { this.url = n, this.remaining = n; }
    parseRootSegment() { for (; this.consumeOptional("/");)
        ; return this.remaining === "" || this.peekStartsWith("?") || this.peekStartsWith("#") ? new y([], {}) : new y([], this.parseChildren()); }
    parseQueryParams() { let n = {}; if (this.consumeOptional("?"))
        do
            this.parseQueryParam(n);
        while (this.consumeOptional("&")); return n; }
    parseFragment() { return this.consumeOptional("#") ? decodeURIComponent(this.remaining) : null; }
    parseChildren(n = 0) { if (n > 50)
        throw new T(4010, !1); if (this.remaining === "")
        return {}; this.consumeOptional("/"); let e = []; for (this.peekStartsWith("(") || e.push(this.parseSegment()); this.peekStartsWith("/") && !this.peekStartsWith("//") && !this.peekStartsWith("/(");)
        this.capture("/"), e.push(this.parseSegment()); let r = {}; this.peekStartsWith("/(") && (this.capture("/"), r = this.parseParens(!0, n)); let i = {}; return this.peekStartsWith("(") && (i = this.parseParens(!1, n)), (e.length > 0 || Object.keys(r).length > 0) && (i[f] = new y(e, r)), i; }
    parseSegment() { let n = _t(this.remaining); if (n === "" && this.peekStartsWith(";"))
        throw new T(4009, !1); return this.capture(n), new te(tt(n), this.parseMatrixParams()); }
    parseMatrixParams() { let n = {}; for (; this.consumeOptional(";");)
        this.parseParam(n); return n; }
    parseParam(n) { let e = Ii(this.remaining); if (!e)
        return; this.capture(e); let r = ""; if (this.consumeOptional("=")) {
        let i = _t(this.remaining);
        i && (r = i, this.capture(r));
    } n[tt(e)] = tt(r); }
    parseQueryParam(n) { let e = Ei(this.remaining); if (!e)
        return; this.capture(e); let r = ""; if (this.consumeOptional("=")) {
        let a = Ni(this.remaining);
        a && (r = a, this.capture(r));
    } let i = Sr(e), o = Sr(r); if (n.hasOwnProperty(i)) {
        let a = n[i];
        Array.isArray(a) || (a = [a], n[i] = a), a.push(o);
    }
    else
        n[i] = o; }
    parseParens(n, e) { let r = {}; for (this.capture("("); !this.consumeOptional(")") && this.remaining.length > 0;) {
        let i = _t(this.remaining), o = this.remaining[i.length];
        if (o !== "/" && o !== ")" && o !== ";")
            throw new T(4010, !1);
        let a;
        i.indexOf(":") > -1 ? (a = i.slice(0, i.indexOf(":")), this.capture(a), this.capture(":")) : n && (a = f);
        let c = this.parseChildren(e + 1);
        r[a ?? f] = Object.keys(c).length === 1 && c[f] ? c[f] : new y([], c), this.consumeOptional("//");
    } return r; }
    peekStartsWith(n) { return this.remaining.startsWith(n); }
    consumeOptional(n) { return this.peekStartsWith(n) ? (this.remaining = this.remaining.substring(n.length), !0) : !1; }
    capture(n) { if (!this.consumeOptional(n))
        throw new T(4011, !1); }
};
function Fr(t) { return t.segments.length > 0 ? new y([], { [f]: t }) : t; }
function qr(t) { let n = {}; for (let [r, i] of Object.entries(t.children)) {
    let o = qr(i);
    if (r === f && o.segments.length === 0 && o.hasChildren())
        for (let [a, c] of Object.entries(o.children))
            n[a] = c;
    else
        (o.segments.length > 0 || o.hasChildren()) && (n[r] = o);
} let e = new y(t.segments, n); return Mi(e); }
function Mi(t) { if (t.numberOfChildren === 1 && t.children[f]) {
    let n = t.children[f];
    return new y(t.segments.concat(n.segments), n.children);
} return t; }
function re(t) { return t instanceof M; }
function Br(t, n, e = null, r = null, i = new J) { let o = Vr(t); return Gr(o, n, e, r, i); }
function Vr(t) { let n; function e(o) { let a = {}; for (let s of o.children) {
    let u = e(s);
    a[s.outlet] = u;
} let c = new y(o.url, a); return o === t && (n = c), c; } let r = e(t.root), i = Fr(r); return n ?? i; }
function Gr(t, n, e, r, i) { let o = t; for (; o.parent;)
    o = o.parent; if (n.length === 0)
    return Ut(o, o, o, e, r, i); let a = Di(n); if (a.toRoot())
    return Ut(o, o, new y([], {}), e, r, i); let c = _i(a, o, t), s = c.processChildren ? Oe(c.segmentGroup, c.index, a.commands) : Qr(c.segmentGroup, c.index, a.commands); return Ut(o, c.segmentGroup, s, e, r, i); }
function nt(t) { return typeof t == "object" && t != null && !t.outlets && !t.segmentPath; }
function ke(t) { return typeof t == "object" && t != null && t.outlets; }
function Cr(t, n, e) { t ||= "\u0275"; let r = new M; return r.queryParams = { [t]: n }, e.parse(e.serialize(r)).queryParams[t]; }
function Ut(t, n, e, r, i, o) { let a = {}; for (let [u, h] of Object.entries(r ?? {}))
    a[u] = Array.isArray(h) ? h.map(m => Cr(u, m, o)) : Cr(u, h, o); let c; t === n ? c = e : c = Wr(t, n, e); let s = Fr(qr(c)); return new M(s, a, i); }
function Wr(t, n, e) { let r = {}; return Object.entries(t.children).forEach(([i, o]) => { o === n ? r[i] = e : r[i] = Wr(o, n, e); }), new y(t.segments, r); }
var it = class {
    isAbsolute;
    numberOfDoubleDots;
    commands;
    constructor(n, e, r) { if (this.isAbsolute = n, this.numberOfDoubleDots = e, this.commands = r, n && r.length > 0 && nt(r[0]))
        throw new T(4003, !1); let i = r.find(ke); if (i && i !== di(r))
        throw new T(4004, !1); }
    toRoot() { return this.isAbsolute && this.commands.length === 1 && this.commands[0] == "/"; }
};
function Di(t) { if (typeof t[0] == "string" && t.length === 1 && t[0] === "/")
    return new it(!0, 0, t); let n = 0, e = !1, r = t.reduce((i, o, a) => { if (typeof o == "object" && o != null) {
    if (o.outlets) {
        let c = {};
        return Object.entries(o.outlets).forEach(([s, u]) => { c[s] = typeof u == "string" ? u.split("/") : u; }), [...i, { outlets: c }];
    }
    if (o.segmentPath)
        return [...i, o.segmentPath];
} return typeof o != "string" ? [...i, o] : a === 0 ? (o.split("/").forEach((c, s) => { s == 0 && c === "." || (s == 0 && c === "" ? e = !0 : c === ".." ? n++ : c != "" && i.push(c)); }), i) : [...i, o]; }, []); return new it(e, n, r); }
var me = class {
    segmentGroup;
    processChildren;
    index;
    constructor(n, e, r) { this.segmentGroup = n, this.processChildren = e, this.index = r; }
};
function _i(t, n, e) { if (t.isAbsolute)
    return new me(n, !0, 0); if (!e)
    return new me(n, !1, NaN); if (e.parent === null)
    return new me(e, !0, 0); let r = nt(t.commands[0]) ? 0 : 1, i = e.segments.length - 1 + r; return Ui(e, i, t.numberOfDoubleDots); }
function Ui(t, n, e) { let r = t, i = n, o = e; for (; o > i;) {
    if (o -= i, r = r.parent, !r)
        throw new T(4005, !1);
    i = r.segments.length;
} return new me(r, !1, i - o); }
function Oi(t) { return ke(t[0]) ? t[0].outlets : { [f]: t }; }
function Qr(t, n, e) { if (t ??= new y([], {}), t.segments.length === 0 && t.hasChildren())
    return Oe(t, n, e); let r = Pi(t, n, e), i = e.slice(r.commandIndex); if (r.match && r.pathIndex < t.segments.length) {
    let o = new y(t.segments.slice(0, r.pathIndex), {});
    return o.children[f] = new y(t.segments.slice(r.pathIndex), t.children), Oe(o, 0, i);
}
else
    return r.match && i.length === 0 ? new y(t.segments, {}) : r.match && !t.hasChildren() ? Ht(t, n, e) : r.match ? Oe(t, 0, i) : Ht(t, n, e); }
function Oe(t, n, e) { if (e.length === 0)
    return new y(t.segments, {}); {
    let r = Oi(e), i = {};
    if (Object.keys(r).some(o => o !== f) && t.children[f] && t.numberOfChildren === 1 && t.children[f].segments.length === 0) {
        let o = Oe(t.children[f], n, e);
        return new y(t.segments, o.children);
    }
    return Object.entries(r).forEach(([o, a]) => { typeof a == "string" && (a = [a]), a !== null && (i[o] = Qr(t.children[o], n, a)); }), Object.entries(t.children).forEach(([o, a]) => { r[o] === void 0 && (i[o] = a); }), new y(t.segments, i);
} }
function Pi(t, n, e) { let r = 0, i = n, o = { match: !1, pathIndex: 0, commandIndex: 0 }; for (; i < t.segments.length;) {
    if (r >= e.length)
        return o;
    let a = t.segments[i], c = e[r];
    if (ke(c))
        break;
    let s = `${c}`, u = r < e.length - 1 ? e[r + 1] : null;
    if (i > 0 && s === void 0)
        break;
    if (s && u && typeof u == "object" && u.outlets === void 0) {
        if (!br(s, u, a))
            return o;
        r += 2;
    }
    else {
        if (!br(s, {}, a))
            return o;
        r++;
    }
    i++;
} return { match: !0, pathIndex: i, commandIndex: r }; }
function Ht(t, n, e) { let r = t.segments.slice(0, n), i = 0; for (; i < e.length;) {
    let o = e[i];
    if (ke(o)) {
        let s = Li(o.outlets);
        return new y(r, s);
    }
    if (i === 0 && nt(e[0])) {
        let s = t.segments[n];
        r.push(new te(s.path, wr(e[0]))), i++;
        continue;
    }
    let a = ke(o) ? o.outlets[f] : `${o}`, c = i < e.length - 1 ? e[i + 1] : null;
    a && c && nt(c) ? (r.push(new te(a, wr(c))), i += 2) : (r.push(new te(a, {})), i++);
} return new y(r, {}); }
function Li(t) { let n = {}; return Object.entries(t).forEach(([e, r]) => { typeof r == "string" && (r = [r]), r !== null && (n[e] = Ht(new y([], {}), 0, r)); }), n; }
function wr(t) { let n = {}; return Object.entries(t).forEach(([e, r]) => n[e] = `${r}`), n; }
function br(t, n, e) { return t == e.path && Q(n, e.parameters); }
var ye = "imperative", w = (function (t) { return t[t.NavigationStart = 0] = "NavigationStart", t[t.NavigationEnd = 1] = "NavigationEnd", t[t.NavigationCancel = 2] = "NavigationCancel", t[t.NavigationError = 3] = "NavigationError", t[t.RoutesRecognized = 4] = "RoutesRecognized", t[t.ResolveStart = 5] = "ResolveStart", t[t.ResolveEnd = 6] = "ResolveEnd", t[t.GuardsCheckStart = 7] = "GuardsCheckStart", t[t.GuardsCheckEnd = 8] = "GuardsCheckEnd", t[t.RouteConfigLoadStart = 9] = "RouteConfigLoadStart", t[t.RouteConfigLoadEnd = 10] = "RouteConfigLoadEnd", t[t.ChildActivationStart = 11] = "ChildActivationStart", t[t.ChildActivationEnd = 12] = "ChildActivationEnd", t[t.ActivationStart = 13] = "ActivationStart", t[t.ActivationEnd = 14] = "ActivationEnd", t[t.Scroll = 15] = "Scroll", t[t.NavigationSkipped = 16] = "NavigationSkipped", t; })(w || {}), x = class {
    id;
    url;
    constructor(n, e) { this.id = n, this.url = e; }
}, X = class extends x {
    type = w.NavigationStart;
    navigationTrigger;
    restoredState;
    constructor(n, e, r = "imperative", i = null) { super(n, e), this.navigationTrigger = r, this.restoredState = i; }
    toString() { return `NavigationStart(id: ${this.id}, url: '${this.url}')`; }
}, _ = class extends x {
    urlAfterRedirects;
    type = w.NavigationEnd;
    constructor(n, e, r) { super(n, e), this.urlAfterRedirects = r; }
    toString() { return `NavigationEnd(id: ${this.id}, url: '${this.url}', urlAfterRedirects: '${this.urlAfterRedirects}')`; }
}, b = (function (t) { return t[t.Redirect = 0] = "Redirect", t[t.SupersededByNewNavigation = 1] = "SupersededByNewNavigation", t[t.NoDataFromResolver = 2] = "NoDataFromResolver", t[t.GuardRejected = 3] = "GuardRejected", t[t.Aborted = 4] = "Aborted", t; })(b || {}), Se = (function (t) { return t[t.IgnoredSameUrlNavigation = 0] = "IgnoredSameUrlNavigation", t[t.IgnoredByUrlHandlingStrategy = 1] = "IgnoredByUrlHandlingStrategy", t; })(Se || {}), N = class extends x {
    reason;
    code;
    type = w.NavigationCancel;
    constructor(n, e, r, i) { super(n, e), this.reason = r, this.code = i; }
    toString() { return `NavigationCancel(id: ${this.id}, url: '${this.url}')`; }
};
function nr(t) { return t instanceof N && (t.code === b.Redirect || t.code === b.SupersededByNewNavigation); }
var B = class extends x {
    reason;
    code;
    type = w.NavigationSkipped;
    constructor(n, e, r, i) { super(n, e), this.reason = r, this.code = i; }
}, ne = class extends x {
    error;
    target;
    type = w.NavigationError;
    constructor(n, e, r, i) { super(n, e), this.error = r, this.target = i; }
    toString() { return `NavigationError(id: ${this.id}, url: '${this.url}', error: ${this.error})`; }
}, $e = class extends x {
    urlAfterRedirects;
    state;
    type = w.RoutesRecognized;
    constructor(n, e, r, i) { super(n, e), this.urlAfterRedirects = r, this.state = i; }
    toString() { return `RoutesRecognized(id: ${this.id}, url: '${this.url}', urlAfterRedirects: '${this.urlAfterRedirects}', state: ${this.state})`; }
}, ot = class extends x {
    urlAfterRedirects;
    state;
    type = w.GuardsCheckStart;
    constructor(n, e, r, i) { super(n, e), this.urlAfterRedirects = r, this.state = i; }
    toString() { return `GuardsCheckStart(id: ${this.id}, url: '${this.url}', urlAfterRedirects: '${this.urlAfterRedirects}', state: ${this.state})`; }
}, at = class extends x {
    urlAfterRedirects;
    state;
    shouldActivate;
    type = w.GuardsCheckEnd;
    constructor(n, e, r, i, o) { super(n, e), this.urlAfterRedirects = r, this.state = i, this.shouldActivate = o; }
    toString() { return `GuardsCheckEnd(id: ${this.id}, url: '${this.url}', urlAfterRedirects: '${this.urlAfterRedirects}', state: ${this.state}, shouldActivate: ${this.shouldActivate})`; }
}, st = class extends x {
    urlAfterRedirects;
    state;
    type = w.ResolveStart;
    constructor(n, e, r, i) { super(n, e), this.urlAfterRedirects = r, this.state = i; }
    toString() { return `ResolveStart(id: ${this.id}, url: '${this.url}', urlAfterRedirects: '${this.urlAfterRedirects}', state: ${this.state})`; }
}, ct = class extends x {
    urlAfterRedirects;
    state;
    type = w.ResolveEnd;
    constructor(n, e, r, i) { super(n, e), this.urlAfterRedirects = r, this.state = i; }
    toString() { return `ResolveEnd(id: ${this.id}, url: '${this.url}', urlAfterRedirects: '${this.urlAfterRedirects}', state: ${this.state})`; }
}, ut = class {
    route;
    type = w.RouteConfigLoadStart;
    constructor(n) { this.route = n; }
    toString() { return `RouteConfigLoadStart(path: ${this.route.path})`; }
}, lt = class {
    route;
    type = w.RouteConfigLoadEnd;
    constructor(n) { this.route = n; }
    toString() { return `RouteConfigLoadEnd(path: ${this.route.path})`; }
}, ht = class {
    snapshot;
    type = w.ChildActivationStart;
    constructor(n) { this.snapshot = n; }
    toString() { return `ChildActivationStart(path: '${this.snapshot.routeConfig && this.snapshot.routeConfig.path || ""}')`; }
}, dt = class {
    snapshot;
    type = w.ChildActivationEnd;
    constructor(n) { this.snapshot = n; }
    toString() { return `ChildActivationEnd(path: '${this.snapshot.routeConfig && this.snapshot.routeConfig.path || ""}')`; }
}, ft = class {
    snapshot;
    type = w.ActivationStart;
    constructor(n) { this.snapshot = n; }
    toString() { return `ActivationStart(path: '${this.snapshot.routeConfig && this.snapshot.routeConfig.path || ""}')`; }
}, pt = class {
    snapshot;
    type = w.ActivationEnd;
    constructor(n) { this.snapshot = n; }
    toString() { return `ActivationEnd(path: '${this.snapshot.routeConfig && this.snapshot.routeConfig.path || ""}')`; }
}, Ce = class {
    routerEvent;
    position;
    anchor;
    scrollBehavior;
    type = w.Scroll;
    constructor(n, e, r, i) { this.routerEvent = n, this.position = e, this.anchor = r, this.scrollBehavior = i; }
    toString() { let n = this.position ? `${this.position[0]}, ${this.position[1]}` : null; return `Scroll(anchor: '${this.anchor}', position: '${n}')`; }
}, le = class {
}, we = class {
}, be = class {
    url;
    navigationBehaviorOptions;
    constructor(n, e) { this.url = n, this.navigationBehaviorOptions = e; }
};
function xi(t) { return !(t instanceof le) && !(t instanceof be) && !(t instanceof we); }
var gt = class {
    rootInjector;
    outlet = null;
    route = null;
    children;
    attachRef = null;
    get injector() { return this.route?.snapshot._environmentInjector ?? this.rootInjector; }
    constructor(n) { this.rootInjector = n, this.children = new fe(this.rootInjector); }
}, fe = (() => { class t {
    rootInjector;
    contexts = new Map;
    constructor(e) { this.rootInjector = e; }
    onChildOutletCreated(e, r) { let i = this.getOrCreateContext(e); i.outlet = r, this.contexts.set(e, i); }
    onChildOutletDestroyed(e) { let r = this.getContext(e); r && (r.outlet = null, r.attachRef = null); }
    onOutletDeactivated() { let e = this.contexts; return this.contexts = new Map, e; }
    onOutletReAttached(e) { this.contexts = e; }
    getOrCreateContext(e) { let r = this.getContext(e); return r || (r = new gt(this.rootInjector), this.contexts.set(e, r)), r; }
    getContext(e) { return this.contexts.get(e) || null; }
    static \u0275fac = function (r) { return new (r || t)(R.\u0275\u0275inject(R.EnvironmentInjector)); };
    static \u0275prov = R.\u0275\u0275defineInjectable({ token: t, factory: t.\u0275fac, providedIn: "root" });
} return t; })(), vt = class {
    _root;
    constructor(n) { this._root = n; }
    get root() { return this._root.value; }
    parent(n) { let e = this.pathFromRoot(n); return e.length > 1 ? e[e.length - 2] : null; }
    children(n) { let e = Ft(n, this._root); return e ? e.children.map(r => r.value) : []; }
    firstChild(n) { let e = Ft(n, this._root); return e && e.children.length > 0 ? e.children[0].value : null; }
    siblings(n) { let e = qt(n, this._root); return e.length < 2 ? [] : e[e.length - 2].children.map(i => i.value).filter(i => i !== n); }
    pathFromRoot(n) { return qt(n, this._root).map(e => e.value); }
};
function Ft(t, n) { if (t === n.value)
    return n; for (let e of n.children) {
    let r = Ft(t, e);
    if (r)
        return r;
} return null; }
function qt(t, n) { if (t === n.value)
    return [n]; for (let e of n.children) {
    let r = qt(t, e);
    if (r.length)
        return r.unshift(n), r;
} return []; }
var L = class {
    value;
    children;
    constructor(n, e) { this.value = n, this.children = e; }
    toString() { return `TreeNode(${this.value})`; }
};
function ve(t) { let n = {}; return t && t.children.forEach(e => n[e.value.outlet] = e), n; }
var ze = class extends vt {
    snapshot;
    constructor(n, e) { super(n), this.snapshot = e, or(this, n); }
    toString() { return this.snapshot.toString(); }
};
function Kr(t, n) { let e = ji(t, n), r = new F([new te("", {})]), i = new F({}), o = new F({}), a = new F({}), c = new F(""), s = new K(r, i, a, c, o, f, t, e.root); return s.snapshot = e.root, new ze(new L(s, []), e); }
function ji(t, n) { let e = {}, r = {}, i = {}, a = new Ie([], e, i, "", r, f, t, null, {}, n); return new He("", new L(a, [])); }
var K = class {
    urlSubject;
    paramsSubject;
    queryParamsSubject;
    fragmentSubject;
    dataSubject;
    outlet;
    component;
    snapshot;
    _futureSnapshot;
    _routerState;
    _paramMap;
    _queryParamMap;
    title;
    url;
    params;
    queryParams;
    fragment;
    data;
    constructor(n, e, r, i, o, a, c, s) { this.urlSubject = n, this.paramsSubject = e, this.queryParamsSubject = r, this.fragmentSubject = i, this.dataSubject = o, this.outlet = a, this.component = c, this._futureSnapshot = s, this.title = this.dataSubject?.pipe(D(u => u[Be])) ?? v(void 0), this.url = n, this.params = e, this.queryParams = r, this.fragment = i, this.data = o; }
    get routeConfig() { return this._futureSnapshot.routeConfig; }
    get root() { return this._routerState.root; }
    get parent() { return this._routerState.parent(this); }
    get firstChild() { return this._routerState.firstChild(this); }
    get children() { return this._routerState.children(this); }
    get pathFromRoot() { return this._routerState.pathFromRoot(this); }
    get paramMap() { return this._paramMap ??= this.params.pipe(D(n => ue(n))), this._paramMap; }
    get queryParamMap() { return this._queryParamMap ??= this.queryParams.pipe(D(n => ue(n))), this._queryParamMap; }
    toString() { return this.snapshot ? this.snapshot.toString() : `Future(${this._futureSnapshot})`; }
}, ki = "always";
function ir(t, n, e) { let r, { routeConfig: i } = t; return n !== null && (e === "always" || i?.path === "" || !n.component && !n.routeConfig?.loadComponent) ? r = { params: l(l({}, n.params), t.params), data: l(l({}, n.data), t.data), resolve: l(l(l(l({}, t.data), n.data), i?.data), t._resolvedData) } : r = { params: l({}, t.params), data: l({}, t.data), resolve: l(l({}, t.data), t._resolvedData ?? {}) }, i && Zr(i) && (r.resolve[Be] = i.title), r; }
var Ie = class {
    url;
    params;
    queryParams;
    fragment;
    data;
    outlet;
    component;
    routeConfig;
    _resolve;
    _resolvedData;
    _routerState;
    _paramMap;
    _queryParamMap;
    _environmentInjector;
    get title() { return this.data?.[Be]; }
    constructor(n, e, r, i, o, a, c, s, u, h) { this.url = n, this.params = e, this.queryParams = r, this.fragment = i, this.data = o, this.outlet = a, this.component = c, this.routeConfig = s, this._resolve = u, this._environmentInjector = h; }
    get root() { return this._routerState.root; }
    get parent() { return this._routerState.parent(this); }
    get firstChild() { return this._routerState.firstChild(this); }
    get children() { return this._routerState.children(this); }
    get pathFromRoot() { return this._routerState.pathFromRoot(this); }
    get paramMap() { return this._paramMap ??= ue(this.params), this._paramMap; }
    get queryParamMap() { return this._queryParamMap ??= ue(this.queryParams), this._queryParamMap; }
    toString() { let n = this.url.map(r => r.toString()).join("/"), e = this.routeConfig ? this.routeConfig.path : ""; return `Route(url:'${n}', path:'${e}')`; }
}, He = class extends vt {
    url;
    constructor(n, e) { super(e), this.url = n, or(this, e); }
    toString() { return Yr(this._root); }
};
function or(t, n) { n.value._routerState = t, n.children.forEach(e => or(t, e)); }
function Yr(t) { let n = t.children.length > 0 ? ` { ${t.children.map(Yr).join(", ")} } ` : ""; return `${t.value}${n}`; }
function Ot(t) { if (t.snapshot) {
    let n = t.snapshot, e = t._futureSnapshot;
    t.snapshot = e, Q(n.queryParams, e.queryParams) || t.queryParamsSubject.next(e.queryParams), n.fragment !== e.fragment && t.fragmentSubject.next(e.fragment), Q(n.params, e.params) || t.paramsSubject.next(e.params), hi(n.url, e.url) || t.urlSubject.next(e.url), Q(n.data, e.data) || t.dataSubject.next(e.data);
}
else
    t.snapshot = t._futureSnapshot, t.dataSubject.next(t._futureSnapshot.data); }
function Bt(t, n) { let e = Q(t.params, n.params) && vi(t.url, n.url), r = !t.parent != !n.parent; return e && !r && (!t.parent || Bt(t.parent, n.parent)); }
function Zr(t) { return typeof t.title == "string" || t.title === null; }
var Jr = new ie(""), ar = (() => { class t {
    activated = null;
    get activatedComponentRef() { return this.activated; }
    _activatedRoute = null;
    name = f;
    activateEvents = new Ye;
    deactivateEvents = new Ye;
    attachEvents = new Ye;
    detachEvents = new Ye;
    routerOutletData = qn();
    parentContexts = g(fe);
    location = g(Bn);
    changeDetector = g(Vn);
    inputBinder = g(Ve, { optional: !0 });
    supportsBindingToComponentInputs = !0;
    ngOnChanges(e) { if (e.name) {
        let { firstChange: r, previousValue: i } = e.name;
        if (r)
            return;
        this.isTrackedInParentContexts(i) && (this.deactivate(), this.parentContexts.onChildOutletDestroyed(i)), this.initializeOutletWithName();
    } }
    ngOnDestroy() { this.isTrackedInParentContexts(this.name) && this.parentContexts.onChildOutletDestroyed(this.name), this.inputBinder?.unsubscribeFromRouteData(this); }
    isTrackedInParentContexts(e) { return this.parentContexts.getContext(e)?.outlet === this; }
    ngOnInit() { this.initializeOutletWithName(); }
    initializeOutletWithName() { if (this.parentContexts.onChildOutletCreated(this.name, this), this.activated)
        return; let e = this.parentContexts.getContext(this.name); e?.route && (e.attachRef ? this.attach(e.attachRef, e.route) : this.activateWith(e.route, e.injector)); }
    get isActivated() { return !!this.activated; }
    get component() { if (!this.activated)
        throw new T(4012, !1); return this.activated.instance; }
    get activatedRoute() { if (!this.activated)
        throw new T(4012, !1); return this._activatedRoute; }
    get activatedRouteData() { return this._activatedRoute ? this._activatedRoute.snapshot.data : {}; }
    detach() { if (!this.activated)
        throw new T(4012, !1); this.location.detach(); let e = this.activated; return this.activated = null, this._activatedRoute = null, this.detachEvents.emit(e.instance), e; }
    attach(e, r) { this.activated = e, this._activatedRoute = r, this.location.insert(e.hostView), this.inputBinder?.bindActivatedRouteToOutletComponent(this), this.attachEvents.emit(e.instance); }
    deactivate() { if (this.activated) {
        let e = this.component;
        this.activated.destroy(), this.activated = null, this._activatedRoute = null, this.deactivateEvents.emit(e);
    } }
    activateWith(e, r) { if (this.isActivated)
        throw new T(4013, !1); this._activatedRoute = e; let i = this.location, a = e.snapshot.component, c = this.parentContexts.getOrCreateContext(this.name).children, s = new Vt(e, c, i.injector, this.routerOutletData); this.activated = i.createComponent(a, { index: i.length, injector: s, environmentInjector: r }), this.changeDetector.markForCheck(), this.inputBinder?.bindActivatedRouteToOutletComponent(this), this.activateEvents.emit(this.activated.instance); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275dir = R.\u0275\u0275defineDirective({ type: t, selectors: [["router-outlet"]], inputs: { name: "name", routerOutletData: [1, "routerOutletData"] }, outputs: { activateEvents: "activate", deactivateEvents: "deactivate", attachEvents: "attach", detachEvents: "detach" }, exportAs: ["outlet"], features: [R.\u0275\u0275NgOnChangesFeature] });
} return t; })(), Vt = class {
    route;
    childContexts;
    parent;
    outletData;
    constructor(n, e, r, i) { this.route = n, this.childContexts = e, this.parent = r, this.outletData = i; }
    get(n, e) { return n === K ? this.route : n === fe ? this.childContexts : n === Jr ? this.outletData : this.parent.get(n, e); }
}, Ve = new ie(""), Xr = (() => { class t {
    options;
    outletDataSubscriptions = new Map;
    outletSeenKeys = new Map;
    constructor(e) { this.options = e, this.options.queryParams ??= !0; }
    bindActivatedRouteToOutletComponent(e) { this.unsubscribeFromRouteData(e), this.subscribeToRouteData(e); }
    unsubscribeFromRouteData(e) { this.outletDataSubscriptions.get(e)?.unsubscribe(), this.outletDataSubscriptions.delete(e), this.outletSeenKeys.delete(e); }
    subscribeToRouteData(e) { let { activatedRoute: r } = e, i = Nr([this.options.queryParams ? r.queryParams : v({}), r.params, r.data]).pipe(H(([o, a, c], s) => (c = l(l(l({}, o), a), c), s === 0 ? v(c) : Promise.resolve(c)))).subscribe(o => { if (!e.isActivated || !e.activatedComponentRef || e.activatedRoute !== r || r.component === null) {
        this.unsubscribeFromRouteData(e);
        return;
    } let a = Gn(r.component); if (!a) {
        this.unsubscribeFromRouteData(e);
        return;
    } let c = this.outletSeenKeys.get(e); c || (c = new Set, this.outletSeenKeys.set(e, c)); for (let u of Object.keys(o))
        c.add(u); let s = this.options.unmatchedInputBehavior ?? "alwaysUndefined"; for (let { templateName: u } of a.inputs) {
        let h = o[u];
        (h !== void 0 || s === "alwaysUndefined" || c.has(u)) && e.activatedComponentRef.setInput(u, h);
    } }); this.outletDataSubscriptions.set(e, i); }
    static \u0275fac = function (r) { R.\u0275\u0275invalidFactory(); };
    static \u0275prov = R.\u0275\u0275defineInjectable({ token: t, factory: t.\u0275fac });
} return t; })(), sr = (() => { class t {
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275cmp = R.\u0275\u0275defineComponent({ type: t, selectors: [["ng-component"]], exportAs: ["emptyRouterOutlet"], decls: 1, vars: 0, template: function (r, i) { r & 1 && R.\u0275\u0275element(0, "router-outlet"); }, dependencies: [ar], encapsulation: 2, changeDetection: 1 });
} return t; })();
function cr(t) { let n = t.children && t.children.map(cr), e = n ? E(l({}, t), { children: n }) : l({}, t); return !e.component && !e.loadComponent && (n || e.loadChildren) && e.outlet && e.outlet !== f && (e.component = sr), e; }
function $i(t, n, e) { let r = Fe(t, n._root, e ? e._root : void 0); return new ze(r, n); }
function Fe(t, n, e) { if (e && t.shouldReuseRoute(n.value, e.value.snapshot)) {
    let r = e.value;
    r._futureSnapshot = n.value;
    let i = zi(t, n, e);
    return new L(r, i);
}
else {
    if (t.shouldAttach(n.value)) {
        let o = t.retrieve(n.value);
        if (o !== null) {
            let a = o.route;
            return a.value._futureSnapshot = n.value, a.children = n.children.map(c => Fe(t, c)), a;
        }
    }
    let r = Hi(n.value), i = n.children.map(o => Fe(t, o));
    return new L(r, i);
} }
function zi(t, n, e) { return n.children.map(r => { for (let i of e.children)
    if (t.shouldReuseRoute(r.value, i.value.snapshot))
        return Fe(t, r, i); return Fe(t, r); }); }
function Hi(t) { return new K(new F(t.url), new F(t.params), new F(t.queryParams), new F(t.fragment), new F(t.data), t.outlet, t.component, t); }
var Ae = class {
    redirectTo;
    navigationBehaviorOptions;
    constructor(n, e) { this.redirectTo = n, this.navigationBehaviorOptions = e; }
}, en = "ngNavigationCancelingError";
function mt(t, n) { let { redirectTo: e, navigationBehaviorOptions: r } = re(n) ? { redirectTo: n, navigationBehaviorOptions: void 0 } : n, i = tn(!1, b.Redirect); return i.url = e, i.navigationBehaviorOptions = r, i; }
function tn(t, n) { let e = new Error(`NavigationCancelingError: ${t || ""}`); return e[en] = !0, e.cancellationCode = n, e; }
function Fi(t) { return rn(t) && re(t.url); }
function rn(t) { return !!t && t[en]; }
var Gt = class {
    routeReuseStrategy;
    futureState;
    currState;
    forwardEvent;
    inputBindingEnabled;
    constructor(n, e, r, i, o) { this.routeReuseStrategy = n, this.futureState = e, this.currState = r, this.forwardEvent = i, this.inputBindingEnabled = o; }
    activate(n) { let e = this.futureState._root, r = this.currState ? this.currState._root : null; this.deactivateChildRoutes(e, r, n), Ot(this.futureState.root), this.activateChildRoutes(e, r, n); }
    deactivateChildRoutes(n, e, r) { let i = ve(e); n.children.forEach(o => { let a = o.value.outlet; this.deactivateRoutes(o, i[a], r), delete i[a]; }), Object.values(i).forEach(o => { this.deactivateRouteAndItsChildren(o, r); }); }
    deactivateRoutes(n, e, r) { let i = n.value, o = e ? e.value : null; if (i === o)
        if (i.component) {
            let a = r.getContext(i.outlet);
            a && this.deactivateChildRoutes(n, e, a.children);
        }
        else
            this.deactivateChildRoutes(n, e, r);
    else
        o && this.deactivateRouteAndItsChildren(e, r); }
    deactivateRouteAndItsChildren(n, e) { n.value.component && this.routeReuseStrategy.shouldDetach(n.value.snapshot) ? this.detachAndStoreRouteSubtree(n, e) : this.deactivateRouteAndOutlet(n, e); }
    detachAndStoreRouteSubtree(n, e) { let r = e.getContext(n.value.outlet), i = r && n.value.component ? r.children : e, o = ve(n); for (let a of Object.values(o))
        this.deactivateRouteAndItsChildren(a, i); if (r && r.outlet) {
        let a = r.outlet.detach(), c = r.children.onOutletDeactivated();
        this.routeReuseStrategy.store(n.value.snapshot, { componentRef: a, route: n, contexts: c });
    } }
    deactivateRouteAndOutlet(n, e) { let r = e.getContext(n.value.outlet), i = r && n.value.component ? r.children : e, o = ve(n); for (let a of Object.values(o))
        this.deactivateRouteAndItsChildren(a, i); r && (r.outlet && (r.outlet.deactivate(), r.children.onOutletDeactivated()), r.attachRef = null, r.route = null); }
    activateChildRoutes(n, e, r) { let i = ve(e); n.children.forEach(o => { this.activateRoutes(o, i[o.value.outlet], r), this.forwardEvent(new pt(o.value.snapshot)); }), n.children.length && this.forwardEvent(new dt(n.value.snapshot)); }
    activateRoutes(n, e, r) { let i = n.value, o = e ? e.value : null; if (Ot(i), i === o)
        if (i.component) {
            let a = r.getOrCreateContext(i.outlet);
            this.activateChildRoutes(n, e, a.children);
        }
        else
            this.activateChildRoutes(n, e, r);
    else if (i.component) {
        let a = r.getOrCreateContext(i.outlet);
        if (this.routeReuseStrategy.shouldAttach(i.snapshot)) {
            let c = this.routeReuseStrategy.retrieve(i.snapshot);
            this.routeReuseStrategy.store(i.snapshot, null), a.children.onOutletReAttached(c.contexts), a.attachRef = c.componentRef, a.route = c.route.value, a.outlet && a.outlet.attach(c.componentRef, c.route.value), Ot(c.route.value), this.activateChildRoutes(n, null, a.children);
        }
        else
            a.attachRef = null, a.route = i, a.outlet && a.outlet.activateWith(i, a.injector), this.activateChildRoutes(n, null, a.children);
    }
    else
        this.activateChildRoutes(n, null, r); }
}, yt = class {
    path;
    route;
    constructor(n) { this.path = n, this.route = this.path[this.path.length - 1]; }
}, Re = class {
    component;
    route;
    constructor(n, e) { this.component = n, this.route = e; }
};
function qi(t, n, e) { let r = t._root, i = n ? n._root : null; return _e(r, i, e, [r.value]); }
function Bi(t) { let n = t.routeConfig ? t.routeConfig.canActivateChild : null; return !n || n.length === 0 ? null : { node: t, guards: n }; }
function Te(t, n) { let e = Symbol(), r = n.get(t, e); return r === e ? typeof t == "function" && !Wn(t) ? t : n.get(t) : r; }
function _e(t, n, e, r, i = { canDeactivateChecks: [], canActivateChecks: [] }) { let o = ve(n); return t.children.forEach(a => { Vi(a, o[a.value.outlet], e, r.concat([a.value]), i), delete o[a.value.outlet]; }), Object.entries(o).forEach(([a, c]) => Pe(c, e.getContext(a), i)), i; }
function Vi(t, n, e, r, i = { canDeactivateChecks: [], canActivateChecks: [] }) { let o = t.value, a = n ? n.value : null, c = e ? e.getContext(t.value.outlet) : null; if (a && o.routeConfig === a.routeConfig) {
    let s = Gi(a, o, o.routeConfig.runGuardsAndResolvers);
    s ? i.canActivateChecks.push(new yt(r)) : (o.data = a.data, o._resolvedData = a._resolvedData), o.component ? _e(t, n, c ? c.children : null, r, i) : _e(t, n, e, r, i), s && c && c.outlet && c.outlet.isActivated && i.canDeactivateChecks.push(new Re(c.outlet.component, a));
}
else
    a && Pe(n, c, i), i.canActivateChecks.push(new yt(r)), o.component ? _e(t, null, c ? c.children : null, r, i) : _e(t, null, e, r, i); return i; }
function Gi(t, n, e) { if (typeof e == "function")
    return j(n._environmentInjector, () => e(t, n)); switch (e) {
    case "pathParamsChange": return !se(t.url, n.url);
    case "pathParamsOrQueryParamsChange": return !se(t.url, n.url) || !Q(t.queryParams, n.queryParams);
    case "always": return !0;
    case "paramsOrQueryParamsChange": return !Bt(t, n) || !Q(t.queryParams, n.queryParams);
    default: return !Bt(t, n);
} }
function Pe(t, n, e) { let r = ve(t), i = t.value; Object.entries(r).forEach(([o, a]) => { i.component ? n ? Pe(a, n.children.getContext(o), e) : Pe(a, null, e) : Pe(a, n, e); }), i.component ? n && n.outlet && n.outlet.isActivated ? e.canDeactivateChecks.push(new Re(n.outlet.component, i)) : e.canDeactivateChecks.push(new Re(null, i)) : e.canDeactivateChecks.push(new Re(null, i)); }
function Ge(t) { return typeof t == "function"; }
function Wi(t) { return typeof t == "boolean"; }
function Qi(t) { return t && Ge(t.canLoad); }
function Ki(t) { return t && Ge(t.canActivate); }
function Yi(t) { return t && Ge(t.canActivateChild); }
function Zi(t) { return t && Ge(t.canDeactivate); }
function Ji(t) { return t && Ge(t.canMatch); }
function nn(t) { return t instanceof ni || t?.name === "EmptyError"; }
var Je = Symbol("INITIAL_VALUE");
function Ee() { return H(t => Nr(t.map(n => n.pipe(Le(1), ui(Je)))).pipe(D(n => { for (let e of n)
    if (e !== !0) {
        if (e === Je)
            return Je;
        if (e === !1 || Xi(e))
            return e;
    } return !0; }), xe(n => n !== Je), Le(1))); }
function Xi(t) { return re(t) || t instanceof Ae; }
function on(t) { return t.aborted ? v(void 0).pipe(Le(1)) : new ii(n => { let e = () => { n.next(), n.complete(); }; return t.addEventListener("abort", e), () => t.removeEventListener("abort", e); }); }
function an(t) { return Lt(on(t)); }
function eo(t) { return ce(n => { let { targetSnapshot: e, currentSnapshot: r, guards: { canActivateChecks: i, canDeactivateChecks: o } } = n; return o.length === 0 && i.length === 0 ? v(E(l({}, n), { guardsResult: !0 })) : to(o, e, r).pipe(ce(a => a && Wi(a) ? ro(e, i, t) : v(a)), D(a => E(l({}, n), { guardsResult: a }))); }); }
function to(t, n, e) { return W(t).pipe(ce(r => so(r.component, r.route, e, n)), he(r => r !== !0, !0)); }
function ro(t, n, e) { return W(n).pipe(Mr(r => oi(io(r.route.parent, e), no(r.route, e), ao(t, r.path), oo(t, r.route))), he(r => r !== !0, !0)); }
function no(t, n) { return t !== null && n && n(new ft(t)), v(!0); }
function io(t, n) { return t !== null && n && n(new ht(t)), v(!0); }
function oo(t, n) { let e = n.routeConfig ? n.routeConfig.canActivate : null; if (!e || e.length === 0)
    return v(!0); let r = e.map(i => er(() => { let o = n._environmentInjector, a = Te(i, o), c = Ki(a) ? a.canActivate(n, t) : j(o, () => a(n, t)); return de(c).pipe(he()); })); return v(r).pipe(Ee()); }
function ao(t, n) { let e = n[n.length - 1], i = n.slice(0, n.length - 1).reverse().map(o => Bi(o)).filter(o => o !== null).map(o => er(() => { let a = o.guards.map(c => { let s = o.node._environmentInjector, u = Te(c, s), h = Yi(u) ? u.canActivateChild(e, t) : j(s, () => u(e, t)); return de(h).pipe(he()); }); return v(a).pipe(Ee()); })); return v(i).pipe(Ee()); }
function so(t, n, e, r) { let i = n && n.routeConfig ? n.routeConfig.canDeactivate : null; if (!i || i.length === 0)
    return v(!0); let o = i.map(a => { let c = n._environmentInjector, s = Te(a, c), u = Zi(s) ? s.canDeactivate(t, n, e, r) : j(c, () => s(t, n, e, r)); return de(u).pipe(he()); }); return v(o).pipe(Ee()); }
function co(t, n, e, r, i) { let o = n.canLoad; if (o === void 0 || o.length === 0)
    return v(!0); let a = o.map(c => { let s = Te(c, t), u = Qi(s) ? s.canLoad(n, e) : j(t, () => s(n, e)), h = de(u); return i ? h.pipe(an(i)) : h; }); return v(a).pipe(Ee(), sn(r)); }
function sn(t) { return ai(G(n => { if (typeof n != "boolean")
    throw mt(t, n); }), D(n => n === !0)); }
function uo(t, n, e, r, i, o) { let a = n.canMatch; if (!a || a.length === 0)
    return v(!0); let c = a.map(s => { let u = Te(s, t), h = Ji(u) ? u.canMatch(n, e, i) : j(t, () => u(n, e, i)); return de(h).pipe(an(o)); }); return v(c).pipe(Ee(), sn(r)); }
var Z = class t extends Error {
    segmentGroup;
    constructor(n) { super(), this.segmentGroup = n || null, Object.setPrototypeOf(this, t.prototype); }
}, qe = class t extends Error {
    urlTree;
    constructor(n) { super(), this.urlTree = n, Object.setPrototypeOf(this, t.prototype); }
};
function lo(t) { throw new T(4e3, !1); }
function ho(t) { throw tn(!1, b.GuardRejected); }
var Wt = class {
    urlSerializer;
    urlTree;
    constructor(n, e) { this.urlSerializer = n, this.urlTree = e; }
    lineralizeSegments(n, e) { return S(this, null, function* () { let r = [], i = e.root; for (;;) {
        if (r = r.concat(i.segments), i.numberOfChildren === 0)
            return r;
        if (i.numberOfChildren > 1 || !i.children[f])
            throw lo(`${n.redirectTo}`);
        i = i.children[f];
    } }); }
    applyRedirectCommands(n, e, r, i, o) { return S(this, null, function* () { let a = yield fo(e, i, o); if (a instanceof M)
        throw new qe(a); let c = this.applyRedirectCreateUrlTree(a, this.urlSerializer.parse(a), n, r); if (a[0] === "/")
        throw new qe(c); return c; }); }
    applyRedirectCreateUrlTree(n, e, r, i) { let o = this.createSegmentGroup(n, e.root, r, i); return new M(o, this.createQueryParams(e.queryParams, this.urlTree.queryParams), e.fragment); }
    createQueryParams(n, e) { let r = {}; return Object.entries(n).forEach(([i, o]) => { if (typeof o == "string" && o[0] === ":") {
        let c = o.substring(1);
        r[i] = e[c];
    }
    else
        r[i] = o; }), r; }
    createSegmentGroup(n, e, r, i) { let o = this.createSegments(n, e.segments, r, i), a = {}; return Object.entries(e.children).forEach(([c, s]) => { a[c] = this.createSegmentGroup(n, s, r, i); }), new y(o, a); }
    createSegments(n, e, r, i) { return e.map(o => o.path[0] === ":" ? this.findPosParam(n, o, i) : this.findOrReturn(o, r)); }
    findPosParam(n, e, r) { let i = r[e.path.substring(1)]; if (!i)
        throw new T(4001, !1); return i; }
    findOrReturn(n, e) { let r = 0; for (let i of e) {
        if (i.path === n.path)
            return e.splice(r), i;
        r++;
    } return n; }
};
function fo(t, n, e) { if (typeof t == "string")
    return Promise.resolve(t); let r = t; return rt(de(j(e, () => r(n)))); }
function po(t, n) { return t.providers && !t._injector && (t._injector = Qn(t.providers, n, `Route: ${t.path}`)), t._injector ?? n; }
function q(t) { return t.outlet || f; }
function go(t, n) { let e = t.filter(r => q(r) === n); return e.push(...t.filter(r => q(r) !== n)), e; }
var Qt = { matched: !1, consumedSegments: [], remainingSegments: [], parameters: {}, positionalParamSegments: {} };
function cn(t) { return { routeConfig: t.routeConfig, url: t.url, params: t.params, queryParams: t.queryParams, fragment: t.fragment, data: t.data, outlet: t.outlet, title: t.title, paramMap: t.paramMap, queryParamMap: t.queryParamMap }; }
function vo(t, n, e, r, i, o, a) { let c = un(t, n, e); if (!c.matched)
    return v(c); let s = cn(o(c)); return r = po(n, r), uo(r, n, e, i, s, a).pipe(D(u => u === !0 ? c : l({}, Qt))); }
function un(t, n, e) { if (n.path === "")
    return n.pathMatch === "full" && (t.hasChildren() || e.length > 0) ? l({}, Qt) : { matched: !0, consumedSegments: [], remainingSegments: e, parameters: {}, positionalParamSegments: {} }; let i = (n.matcher || Or)(e, t, n); if (!i)
    return l({}, Qt); let o = {}; Object.entries(i.posParams ?? {}).forEach(([c, s]) => { o[c] = s.path; }); let a = i.consumed.length > 0 ? l(l({}, o), i.consumed[i.consumed.length - 1].parameters) : o; return { matched: !0, consumedSegments: i.consumed, remainingSegments: e.slice(i.consumed.length), parameters: a, positionalParamSegments: i.posParams ?? {} }; }
function Ir(t, n, e, r, i) { return e.length > 0 && Ro(t, e, r, i) ? { segmentGroup: new y(n, yo(r, new y(e, t.children))), slicedSegments: [] } : e.length === 0 && So(t, e, r) ? { segmentGroup: new y(t.segments, mo(t, e, r, t.children)), slicedSegments: e } : { segmentGroup: new y(t.segments, t.children), slicedSegments: e }; }
function mo(t, n, e, r) { let i = {}; for (let o of e)
    if (St(t, n, o) && !r[q(o)]) {
        let a = new y([], {});
        i[q(o)] = a;
    } return l(l({}, r), i); }
function yo(t, n) { let e = {}; e[f] = n; for (let r of t)
    if (r.path === "" && q(r) !== f) {
        let i = new y([], {});
        e[q(r)] = i;
    } return e; }
function Ro(t, n, e, r) { return e.some(i => !St(t, n, i) || !(q(i) !== f) ? !1 : !(r !== void 0 && q(i) === r)); }
function So(t, n, e) { return e.some(r => St(t, n, r)); }
function St(t, n, e) { return (t.hasChildren() || n.length > 0) && e.pathMatch === "full" ? !1 : e.path === ""; }
function Co(t, n, e) { return n.length === 0 && !t.children[e]; }
var Kt = class {
};
function wo(t, n, e, r, i, o, a, c) { return S(this, null, function* () { return new Yt(t, n, e, r, i, a, o, c).recognize(); }); }
var bo = 31, Yt = class {
    injector;
    configLoader;
    rootComponentType;
    config;
    urlTree;
    paramsInheritanceStrategy;
    urlSerializer;
    abortSignal;
    applyRedirects;
    absoluteRedirectCount = 0;
    allowRedirects = !0;
    constructor(n, e, r, i, o, a, c, s) { this.injector = n, this.configLoader = e, this.rootComponentType = r, this.config = i, this.urlTree = o, this.paramsInheritanceStrategy = a, this.urlSerializer = c, this.abortSignal = s, this.applyRedirects = new Wt(this.urlSerializer, this.urlTree); }
    noMatchError(n) { return new T(4002, `'${n.segmentGroup}'`); }
    recognize() { return S(this, null, function* () { let n = Ir(this.urlTree.root, [], [], this.config).segmentGroup, { children: e, rootSnapshot: r } = yield this.match(n), i = new L(r, e), o = new He("", i), a = Br(r, [], this.urlTree.queryParams, this.urlTree.fragment); return a.queryParams = this.urlTree.queryParams, o.url = this.urlSerializer.serialize(a), { state: o, tree: a }; }); }
    match(n) { return S(this, null, function* () { let e = new Ie([], Object.freeze({}), Object.freeze(l({}, this.urlTree.queryParams)), this.urlTree.fragment, Object.freeze({}), f, this.rootComponentType, null, {}, this.injector); try {
        return { children: yield this.processSegmentGroup(this.injector, this.config, n, f, e), rootSnapshot: e };
    }
    catch (r) {
        if (r instanceof qe)
            return this.urlTree = r.urlTree, this.match(r.urlTree.root);
        throw r instanceof Z ? this.noMatchError(r) : r;
    } }); }
    processSegmentGroup(n, e, r, i, o) { return S(this, null, function* () { if (r.segments.length === 0 && r.hasChildren())
        return this.processChildren(n, e, r, o); let a = yield this.processSegment(n, e, r, r.segments, i, !0, o); return a instanceof L ? [a] : []; }); }
    processChildren(n, e, r, i) { return S(this, null, function* () { let o = []; for (let s of Object.keys(r.children))
        s === "primary" ? o.unshift(s) : o.push(s); let a = []; for (let s of o) {
        let u = r.children[s], h = go(e, s), m = yield this.processSegmentGroup(n, h, u, s, i);
        a.push(...m);
    } let c = ln(a); return Io(c), c; }); }
    processSegment(n, e, r, i, o, a, c) { return S(this, null, function* () { for (let s of e)
        try {
            return yield this.processSegmentAgainstRoute(s._injector ?? n, e, s, r, i, o, a, c);
        }
        catch (u) {
            if (u instanceof Z || nn(u))
                continue;
            throw u;
        } if (Co(r, i, o))
        return new Kt; throw new Z(r); }); }
    processSegmentAgainstRoute(n, e, r, i, o, a, c, s) { return S(this, null, function* () { if (q(r) !== a && (a === f || !St(i, o, r)))
        throw new Z(i); if (r.redirectTo === void 0)
        return this.matchSegmentAgainstRoute(n, i, r, o, a, s); if (this.allowRedirects && c)
        return this.expandSegmentAgainstRouteUsingRedirect(n, i, e, r, o, a, s); throw new Z(i); }); }
    expandSegmentAgainstRouteUsingRedirect(n, e, r, i, o, a, c) { return S(this, null, function* () { let { matched: s, parameters: u, consumedSegments: h, positionalParamSegments: m, remainingSegments: p } = un(e, i, o); if (!s)
        throw new Z(e); typeof i.redirectTo == "string" && i.redirectTo[0] === "/" && (this.absoluteRedirectCount++, this.absoluteRedirectCount > bo && (this.allowRedirects = !1)); let A = this.createSnapshot(n, i, o, u, c); if (this.abortSignal.aborted)
        throw new Error(this.abortSignal.reason); let P = yield this.applyRedirects.applyRedirectCommands(h, i.redirectTo, m, cn(A), n), I = yield this.applyRedirects.lineralizeSegments(i, P); return this.processSegment(n, r, e, I.concat(p), a, !1, c); }); }
    createSnapshot(n, e, r, i, o) { let a = new Ie(r, i, Object.freeze(l({}, this.urlTree.queryParams)), this.urlTree.fragment, Eo(e), q(e), e.component ?? e._loadedComponent ?? null, e, To(e), n), c = ir(a, o, this.paramsInheritanceStrategy); return a.params = Object.freeze(c.params), a.data = Object.freeze(c.data), a; }
    matchSegmentAgainstRoute(n, e, r, i, o, a) { return S(this, null, function* () { if (this.abortSignal.aborted)
        throw new Error(this.abortSignal.reason); let c = Y => this.createSnapshot(n, r, Y.consumedSegments, Y.parameters, a), s = yield rt(vo(e, r, i, n, this.urlSerializer, c, this.abortSignal)); if (r.path === "**" && (e.children = {}), !s?.matched)
        throw new Z(e); n = r._injector ?? n; let { routes: u } = yield this.getChildConfig(n, r, i), h = r._loadedInjector ?? n, { parameters: m, consumedSegments: p, remainingSegments: A } = s, P = this.createSnapshot(n, r, p, m, a), { segmentGroup: I, slicedSegments: $ } = Ir(e, p, A, u, o); if ($.length === 0 && I.hasChildren()) {
        let Y = yield this.processChildren(h, u, I, P);
        return new L(P, Y);
    } if (u.length === 0 && $.length === 0)
        return new L(P, []); let Me = q(r) === o, ge = yield this.processSegment(h, u, I, $, Me ? f : o, !0, P); return new L(P, ge instanceof L ? [ge] : []); }); }
    getChildConfig(n, e, r) { return S(this, null, function* () { if (e.children)
        return { routes: e.children, injector: n }; if (e.loadChildren) {
        if (e._loadedRoutes !== void 0) {
            let o = e._loadedNgModuleFactory;
            return o && !e._loadedInjector && (e._loadedInjector = o.create(n).injector), { routes: e._loadedRoutes, injector: e._loadedInjector };
        }
        if (this.abortSignal.aborted)
            throw new Error(this.abortSignal.reason);
        if (yield rt(co(n, e, r, this.urlSerializer, this.abortSignal))) {
            let o = yield this.configLoader.loadChildren(n, e);
            return e._loadedRoutes = o.routes, e._loadedInjector = o.injector, e._loadedNgModuleFactory = o.factory, o;
        }
        throw ho(e);
    } return { routes: [], injector: n }; }); }
};
function Io(t) { t.sort((n, e) => n.value.outlet === f ? -1 : e.value.outlet === f ? 1 : n.value.outlet.localeCompare(e.value.outlet)); }
function Ao(t) { let n = t.value.routeConfig; return n && n.path === ""; }
function ln(t) { let n = [], e = new Set; for (let r of t) {
    if (!Ao(r)) {
        n.push(r);
        continue;
    }
    let i = n.find(o => r.value.routeConfig === o.value.routeConfig);
    i !== void 0 ? (i.children.push(...r.children), e.add(i)) : n.push(r);
} for (let r of e) {
    let i = ln(r.children);
    n.push(new L(r.value, i));
} return n.filter(r => !e.has(r)); }
function Eo(t) { return t.data || {}; }
function To(t) { return t.resolve || {}; }
function No(t, n, e, r, i, o, a) { return ce(c => S(null, null, function* () { let { state: s, tree: u } = yield wo(t, n, e, r, c.extractedUrl, i, o, a); return E(l({}, c), { targetSnapshot: s, urlAfterRedirects: u }); })); }
function Mo(t) { return ce(n => { let { targetSnapshot: e, guards: { canActivateChecks: r } } = n; if (!r.length)
    return v(n); let i = new Set(r.map(c => c.route)), o = new Set; for (let c of i)
    if (!o.has(c))
        for (let s of hn(c))
            o.add(s); let a = 0; return W(o).pipe(Mr(c => i.has(c) ? Do(c, e, t) : (c.data = ir(c, c.parent, t).resolve, v(void 0))), G(() => a++), Dr(1), ce(c => a === o.size ? v(n) : z)); }); }
function hn(t) { let n = t.children.map(e => hn(e)).flat(); return [t, ...n]; }
function Do(t, n, e) { let r = t.routeConfig, i = t._resolve; return r?.title !== void 0 && !Zr(r) && (i[Be] = r.title), er(() => (t.data = ir(t, t.parent, e).resolve, _o(i, t, n).pipe(D(o => (t._resolvedData = o, t.data = l(l({}, t.data), o), null))))); }
function _o(t, n, e) { let r = jt(t); if (r.length === 0)
    return v({}); let i = {}; return W(r).pipe(ce(o => Uo(t[o], n, e).pipe(he(), G(a => { if (a instanceof Ae)
    throw mt(new J, a); i[o] = a; }))), Dr(1), D(() => i), _r(o => nn(o) ? z : si(o))); }
function Uo(t, n, e) { let r = n._environmentInjector, i = Te(t, r), o = i.resolve ? i.resolve(n, e) : j(r, () => i(n, e)); return de(o); }
function Ar(t) { return H(n => { let e = t(n); return e ? W(e).pipe(D(() => n)) : v(n); }); }
var ur = (() => { class t {
    buildTitle(e) { let r, i = e.root; for (; i !== void 0;)
        r = this.getResolvedTitleForRoute(i) ?? r, i = i.children.find(o => o.outlet === f); return r; }
    getResolvedTitleForRoute(e) { return e.data[Be]; }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: () => g(dn) });
} return t; })(), dn = (() => { class t extends ur {
    title;
    constructor(e) { super(), this.title = e; }
    updateTitle(e) { let r = this.buildTitle(e); r !== void 0 && this.title.setTitle(r); }
    static \u0275fac = function (r) { return new (r || t)(R.\u0275\u0275inject(Ur.Title)); };
    static \u0275prov = R.\u0275\u0275defineInjectable({ token: t, factory: t.\u0275fac, providedIn: "root" });
} return t; })(), ee = new ie("", { factory: () => ({}) }), pe = new ie(""), Ct = (() => { class t {
    componentLoaders = new WeakMap;
    childrenLoaders = new WeakMap;
    onLoadStartListener;
    onLoadEndListener;
    compiler = g(Kn);
    loadComponent(e, r) { return S(this, null, function* () { if (this.componentLoaders.get(r))
        return this.componentLoaders.get(r); if (r._loadedComponent)
        return Promise.resolve(r._loadedComponent); this.onLoadStartListener && this.onLoadStartListener(r); let i = S(this, null, function* () { try {
        let o = yield Lr(j(e, () => r.loadComponent())), a = yield pn(Er(o));
        return this.onLoadEndListener && this.onLoadEndListener(r), r._loadedComponent = a, a;
    }
    finally {
        this.componentLoaders.delete(r);
    } }); return this.componentLoaders.set(r, i), i; }); }
    loadChildren(e, r) { if (this.childrenLoaders.get(r))
        return this.childrenLoaders.get(r); if (r._loadedRoutes)
        return Promise.resolve({ routes: r._loadedRoutes, injector: r._loadedInjector }); this.onLoadStartListener && this.onLoadStartListener(r); let i = S(this, null, function* () { try {
        let o = yield fn(r, this.compiler, e, this.onLoadEndListener);
        return r._loadedRoutes = o.routes, r._loadedInjector = o.injector, r._loadedNgModuleFactory = o.factory, o;
    }
    finally {
        this.childrenLoaders.delete(r);
    } }); return this.childrenLoaders.set(r, i), i; }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })();
function fn(t, n, e, r) { return S(this, null, function* () { let i = yield Lr(j(e, () => t.loadChildren())), o = yield pn(Er(i)), a; o instanceof Yn || Array.isArray(o) ? a = o : a = yield n.compileModuleAsync(o), r && r(t); let c, s, u = !1, h; return Array.isArray(a) ? (s = a, u = !0) : (c = a.create(e).injector, h = a, s = c.get(pe, [], { optional: !0, self: !0 }).flat()), { routes: s.map(cr), injector: c, factory: h }; }); }
function pn(t) { return S(this, null, function* () { return t; }); }
var wt = (() => { class t {
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: () => g(Oo) });
} return t; })(), Oo = (() => { class t {
    shouldProcessUrl(e) { return !0; }
    extract(e) { return e; }
    merge(e, r) { return e; }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })(), lr = new ie(""), hr = new ie("");
function gn(t, n, e) { let r = t.get(hr), i = t.get(zn); if (!i.startViewTransition || r.skipNextTransition)
    return r.skipNextTransition = !1, new Promise(u => setTimeout(u)); let o, a = new Promise(u => { o = u; }), c = i.startViewTransition(() => (o(), Po(t))); c.updateCallbackDone.catch(u => { }), c.ready.catch(u => { }), c.finished.catch(u => { }); let { onViewTransitionCreated: s } = r; return s && j(t, () => s({ transition: c, from: n, to: e })), a; }
function Po(t) { return new Promise(n => { Zn({ read: () => setTimeout(n) }, { injector: t }); }); }
var Lo = () => { }, bt = new ie(""), It = (() => { class t {
    currentNavigation = Rr(null, { equal: () => !1 });
    currentTransition = null;
    lastSuccessfulNavigation = Rr(null);
    events = new Pt;
    transitionAbortWithErrorSubject = new Pt;
    configLoader = g(Ct);
    environmentInjector = g(Xt);
    destroyRef = g(Jn);
    urlSerializer = g(oe);
    rootContexts = g(fe);
    location = g(Jt);
    inputBindingEnabled = g(Ve, { optional: !0 }) !== null;
    titleStrategy = g(ur);
    options = g(ee, { optional: !0 }) || {};
    paramsInheritanceStrategy = this.options.paramsInheritanceStrategy || ki;
    urlHandlingStrategy = g(wt);
    createViewTransition = g(lr, { optional: !0 });
    navigationErrorHandler = g(bt, { optional: !0 });
    navigationId = 0;
    get hasRequestedNavigation() { return this.navigationId !== 0; }
    transitions;
    afterPreactivation = () => v(void 0);
    rootComponentType = null;
    destroyed = !1;
    constructor() { let e = i => this.events.next(new ut(i)), r = i => this.events.next(new lt(i)); this.configLoader.onLoadEndListener = r, this.configLoader.onLoadStartListener = e, this.destroyRef.onDestroy(() => { this.destroyed = !0; }); }
    complete() { this.transitions?.complete(); }
    handleNavigationRequest(e) { let r = ++this.navigationId; Ue(() => { this.transitions?.next(E(l({}, e), { extractedUrl: this.urlHandlingStrategy.extract(e.rawUrl), targetSnapshot: null, targetRouterState: null, guards: { canActivateChecks: [], canDeactivateChecks: [] }, guardsResult: null, id: r, routesRecognizeHandler: {}, beforeActivateHandler: {} })); }); }
    setupNavigations(e) { return this.transitions = new F(null), this.transitions.pipe(xe(r => r !== null), H(r => { let i = !0, o = !1, a = new AbortController, c = () => !o && this.currentTransition?.id === r.id; return v(r).pipe(H(s => { if (this.navigationId > r.id)
        return this.cancelNavigationTransition(r, "", b.SupersededByNewNavigation), z; this.currentTransition = r; let u = this.lastSuccessfulNavigation(); this.currentNavigation.set({ id: s.id, initialUrl: s.rawUrl, extractedUrl: s.extractedUrl, targetBrowserUrl: typeof s.extras.browserUrl == "string" ? this.urlSerializer.parse(s.extras.browserUrl) : s.extras.browserUrl, trigger: s.source, extras: s.extras, previousNavigation: u ? E(l({}, u), { previousNavigation: null }) : null, abort: () => a.abort(), routesRecognizeHandler: s.routesRecognizeHandler, beforeActivateHandler: s.beforeActivateHandler }); let h = !e.navigated || this.isUpdatingInternalState() || this.isUpdatedBrowserUrl(), m = s.extras.onSameUrlNavigation ?? e.onSameUrlNavigation; if (!h && m !== "reload")
        return this.events.next(new B(s.id, this.urlSerializer.serialize(s.rawUrl), "", Se.IgnoredSameUrlNavigation)), s.resolve(!1), z; if (this.urlHandlingStrategy.shouldProcessUrl(s.rawUrl))
        return v(s).pipe(H(p => (this.events.next(new X(p.id, this.urlSerializer.serialize(p.extractedUrl), p.source, p.restoredState)), p.id !== this.navigationId ? z : Promise.resolve(p))), No(this.environmentInjector, this.configLoader, this.rootComponentType, e.config, this.urlSerializer, this.paramsInheritanceStrategy, a.signal), G(p => { r.targetSnapshot = p.targetSnapshot, r.urlAfterRedirects = p.urlAfterRedirects, this.currentNavigation.update(A => (A.finalUrl = p.urlAfterRedirects, A)), this.events.next(new we); }), H(p => W(r.routesRecognizeHandler.deferredHandle ?? v(void 0)).pipe(D(() => p))), G(() => { let p = new $e(s.id, this.urlSerializer.serialize(s.extractedUrl), this.urlSerializer.serialize(s.urlAfterRedirects), s.targetSnapshot); this.events.next(p); })); if (h && this.urlHandlingStrategy.shouldProcessUrl(s.currentRawUrl)) {
        let { id: p, extractedUrl: A, source: P, restoredState: I, extras: $ } = s, Me = new X(p, this.urlSerializer.serialize(A), P, I);
        this.events.next(Me);
        let ge = Kr(this.rootComponentType, this.environmentInjector).snapshot;
        return this.currentTransition = r = E(l({}, s), { targetSnapshot: ge, urlAfterRedirects: A, extras: E(l({}, $), { skipLocationChange: !1, replaceUrl: !1 }) }), this.currentNavigation.update(Y => (Y.finalUrl = A, Y)), v(r);
    }
    else
        return this.events.next(new B(s.id, this.urlSerializer.serialize(s.extractedUrl), "", Se.IgnoredByUrlHandlingStrategy)), s.resolve(!1), z; }), D(s => { let u = new ot(s.id, this.urlSerializer.serialize(s.extractedUrl), this.urlSerializer.serialize(s.urlAfterRedirects), s.targetSnapshot); return this.events.next(u), this.currentTransition = r = E(l({}, s), { guards: qi(s.targetSnapshot, s.currentSnapshot, this.rootContexts) }), r; }), eo(s => this.events.next(s)), H(s => { if (r.guardsResult = s.guardsResult, s.guardsResult && typeof s.guardsResult != "boolean")
        throw mt(this.urlSerializer, s.guardsResult); let u = new at(s.id, this.urlSerializer.serialize(s.extractedUrl), this.urlSerializer.serialize(s.urlAfterRedirects), s.targetSnapshot, !!s.guardsResult); if (this.events.next(u), !c())
        return z; if (!s.guardsResult)
        return this.cancelNavigationTransition(s, "", b.GuardRejected), z; if (s.guards.canActivateChecks.length === 0)
        return v(s); let h = new st(s.id, this.urlSerializer.serialize(s.extractedUrl), this.urlSerializer.serialize(s.urlAfterRedirects), s.targetSnapshot); if (this.events.next(h), !c())
        return z; let m = !1; return v(s).pipe(Mo(this.paramsInheritanceStrategy), G({ next: () => { m = !0; let p = new ct(s.id, this.urlSerializer.serialize(s.extractedUrl), this.urlSerializer.serialize(s.urlAfterRedirects), s.targetSnapshot); this.events.next(p); }, complete: () => { m || this.cancelNavigationTransition(s, "", b.NoDataFromResolver); } })); }), Ar(s => { let u = m => { let p = []; if (m.routeConfig?._loadedComponent)
        m.component = m.routeConfig?._loadedComponent;
    else if (m.routeConfig?.loadComponent) {
        let A = m._environmentInjector;
        p.push(this.configLoader.loadComponent(A, m.routeConfig).then(P => { m.component = P; }));
    } for (let A of m.children)
        p.push(...u(A)); return p; }, h = u(s.targetSnapshot.root); return h.length === 0 ? v(s) : W(Promise.all(h).then(() => s)); }), H(s => { let u = $i(e.routeReuseStrategy, s.targetSnapshot, s.currentRouterState); return this.currentTransition = r = s = E(l({}, s), { targetRouterState: u }), this.currentNavigation.update(h => (h.targetRouterState = u, h)), v(s); }), Ar(() => this.afterPreactivation()), H(() => { let { currentSnapshot: s, targetSnapshot: u } = r, h = this.createViewTransition?.(this.environmentInjector, s.root, u.root); return h ? W(h).pipe(D(() => r)) : v(r); }), Le(1), H(s => { i = !1, this.events.next(new le); let u = r.beforeActivateHandler.deferredHandle; return u ? W(u.then(() => s)) : v(s); }), G(s => { new Gt(e.routeReuseStrategy, r.targetRouterState, r.currentRouterState, u => this.events.next(u), this.inputBindingEnabled).activate(this.rootContexts), c() && (o = !0, this.currentNavigation.update(u => (u.abort = Lo, u)), this.lastSuccessfulNavigation.set(Ue(this.currentNavigation)), this.events.next(new _(s.id, this.urlSerializer.serialize(s.extractedUrl), this.urlSerializer.serialize(s.urlAfterRedirects))), this.titleStrategy?.updateTitle(s.targetRouterState.snapshot), s.resolve(!0)); }), Lt(on(a.signal).pipe(xe(() => !o && i), G(() => { this.cancelNavigationTransition(r, a.signal.reason + "", b.Aborted); }))), G({ complete: () => { o = !0; } }), Lt(this.transitionAbortWithErrorSubject.pipe(G(s => { throw s; }))), li(() => { a.abort(), o || this.cancelNavigationTransition(r, "", b.SupersededByNewNavigation), this.currentTransition?.id === r.id && (this.currentNavigation.set(null), this.currentTransition = null); }), _r(s => { if (o = !0, this.destroyed)
        return r.resolve(!1), z; if (rn(s))
        this.events.next(new N(r.id, this.urlSerializer.serialize(r.extractedUrl), s.message, s.cancellationCode)), Fi(s) ? this.events.next(new be(s.url, s.navigationBehaviorOptions)) : r.resolve(!1);
    else {
        let u = new ne(r.id, this.urlSerializer.serialize(r.extractedUrl), s, r.targetSnapshot ?? void 0);
        try {
            let h = j(this.environmentInjector, () => this.navigationErrorHandler?.(u));
            if (h instanceof Ae) {
                let { message: m, cancellationCode: p } = mt(this.urlSerializer, h);
                this.events.next(new N(r.id, this.urlSerializer.serialize(r.extractedUrl), m, p)), this.events.next(new be(h.redirectTo, h.navigationBehaviorOptions));
            }
            else
                throw this.events.next(u), s;
        }
        catch (h) {
            this.options.resolveNavigationPromiseOnError ? r.resolve(!1) : r.reject(h);
        }
    } return z; })); })); }
    cancelNavigationTransition(e, r, i) { let o = new N(e.id, this.urlSerializer.serialize(e.extractedUrl), r, i); this.events.next(o), e.resolve(!1); }
    isUpdatingInternalState() { return this.currentTransition?.extractedUrl.toString() !== this.currentTransition?.currentUrlTree.toString(); }
    isUpdatedBrowserUrl() { let e = this.urlHandlingStrategy.extract(this.urlSerializer.parse(this.location.path(!0))), r = Ue(this.currentNavigation), i = r?.targetBrowserUrl ?? r?.extractedUrl; return e.toString() !== i?.toString() && !r?.extras.skipLocationChange; }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })();
function xo(t) { return t !== ye; }
var dr = new ie("");
function vn(t, n, e) { let r = new Set; n.snapshot.root && mn(n.snapshot.root, r); let i = t.retrieveStoredRouteHandles?.() || []; for (let o of i) {
    let a = o;
    if (a?.route?.value?.snapshot)
        for (let c of a.route.value.snapshot.pathFromRoot)
            c.routeConfig && r.add(c.routeConfig);
} Zt(e, r, t, !1); }
function mn(t, n) { t.routeConfig && n.add(t.routeConfig); for (let e of t.children)
    mn(e, n); }
function Zt(t, n, e, r) { for (let i of t) {
    let o = r || !!((i._injector || i._loadedInjector) && !n.has(i) && (e.shouldDestroyInjector?.(i) ?? !1));
    i.children && Zt(i.children, n, e, o), i.loadChildren && i._loadedRoutes && Zt(i._loadedRoutes, n, e, o), o && (i._injector && (i._injector.destroy(), i._injector = void 0), i._loadedInjector && (i._loadedInjector.destroy(), i._loadedInjector = void 0));
} }
function jo(t) { let n = t; n && n.componentRef && n.componentRef.destroy(); }
var yn = (() => { class t {
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: () => g(ko) });
} return t; })(), Rt = class {
    shouldDetach(n) { return !1; }
    store(n, e) { }
    shouldAttach(n) { return !1; }
    retrieve(n) { return null; }
    shouldReuseRoute(n, e) { return n.routeConfig === e.routeConfig; }
    shouldDestroyInjector(n) { return !0; }
}, ko = (() => { class t extends Rt {
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })(), Ne = (() => { class t {
    urlSerializer = g(oe);
    options = g(ee, { optional: !0 }) || {};
    canceledNavigationResolution = this.options.canceledNavigationResolution || "replace";
    location = g(Jt);
    urlHandlingStrategy = g(wt);
    urlUpdateStrategy = this.options.urlUpdateStrategy || "deferred";
    currentUrlTree = new M;
    getCurrentUrlTree() { return this.currentUrlTree; }
    rawUrlTree = this.currentUrlTree;
    getRawUrlTree() { return this.rawUrlTree; }
    createBrowserPath({ finalUrl: e, initialUrl: r, targetBrowserUrl: i }) { let o = e !== void 0 ? this.urlHandlingStrategy.merge(e, r) : r, a = i ?? o; return a instanceof M ? this.urlSerializer.serialize(a) : a; }
    routerUrlState(e) { return e?.targetBrowserUrl === void 0 || e?.finalUrl === void 0 ? {} : { \u0275routerUrl: this.urlSerializer.serialize(e.finalUrl) }; }
    commitTransition({ targetRouterState: e, finalUrl: r, initialUrl: i }) { r && e ? (this.currentUrlTree = r, this.rawUrlTree = this.urlHandlingStrategy.merge(r, i), this.routerState = e) : this.rawUrlTree = i; }
    routerState = Kr(null, g(Xt));
    getRouterState() { return this.routerState; }
    _stateMemento = this.createStateMemento();
    get stateMemento() { return this._stateMemento; }
    updateStateMemento() { this._stateMemento = this.createStateMemento(); }
    createStateMemento() { return { rawUrlTree: this.rawUrlTree, currentUrlTree: this.currentUrlTree, routerState: this.routerState }; }
    restoredState() { return this.location.getState(); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: () => g($o) });
} return t; })(), $o = (() => { class t extends Ne {
    currentPageId = 0;
    lastSuccessfulId = -1;
    get browserPageId() { return this.canceledNavigationResolution !== "computed" ? this.currentPageId : this.restoredState()?.\u0275routerPageId ?? this.currentPageId; }
    registerNonRouterCurrentEntryChangeListener(e) { return this.location.subscribe(r => { r.type === "popstate" && setTimeout(() => { e(r.url, r.state, "popstate", { replaceUrl: !0 }); }); }); }
    handleRouterEvent(e, r) { e instanceof X ? this.updateStateMemento() : e instanceof B ? this.commitTransition(r) : e instanceof $e ? this.urlUpdateStrategy === "eager" && (r.extras.skipLocationChange || this.setBrowserUrl(this.createBrowserPath(r), r)) : e instanceof le ? (this.commitTransition(r), this.urlUpdateStrategy === "deferred" && !r.extras.skipLocationChange && this.setBrowserUrl(this.createBrowserPath(r), r)) : e instanceof N && !nr(e) ? this.restoreHistory(r) : e instanceof ne ? this.restoreHistory(r, !0) : e instanceof _ && (this.lastSuccessfulId = e.id, this.currentPageId = this.browserPageId); }
    setBrowserUrl(e, r) { let { extras: i, id: o } = r, { replaceUrl: a, state: c } = i; if (this.location.isCurrentPathEqualTo(e) || a) {
        let s = this.browserPageId, u = l(l({}, c), this.generateNgRouterState(o, s, r));
        this.location.replaceState(e, "", u);
    }
    else {
        let s = l(l({}, c), this.generateNgRouterState(o, this.browserPageId + 1, r));
        this.location.go(e, "", s);
    } }
    restoreHistory(e, r = !1) { if (this.canceledNavigationResolution === "computed") {
        let i = this.browserPageId, o = this.currentPageId - i;
        o !== 0 ? this.location.historyGo(o) : this.getCurrentUrlTree() === e.finalUrl && o === 0 && (this.resetInternalState(e), this.resetUrlToCurrentUrlTree());
    }
    else
        this.canceledNavigationResolution === "replace" && (r && this.resetInternalState(e), this.resetUrlToCurrentUrlTree()); }
    resetInternalState({ finalUrl: e }) { this.routerState = this.stateMemento.routerState, this.currentUrlTree = this.stateMemento.currentUrlTree, this.rawUrlTree = this.urlHandlingStrategy.merge(this.currentUrlTree, e ?? this.rawUrlTree); }
    resetUrlToCurrentUrlTree() { this.location.replaceState(this.urlSerializer.serialize(this.getRawUrlTree()), "", this.generateNgRouterState(this.lastSuccessfulId, this.currentPageId)); }
    generateNgRouterState(e, r, i) { return this.canceledNavigationResolution === "computed" ? l({ navigationId: e, \u0275routerPageId: r }, this.routerUrlState(i)) : l({ navigationId: e }, this.routerUrlState(i)); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })();
function At(t, n) { t.events.pipe(xe(e => e instanceof _ || e instanceof N || e instanceof ne || e instanceof B), D(e => e instanceof _ || e instanceof B ? 0 : (e instanceof N ? e.code === b.Redirect || e.code === b.SupersededByNewNavigation : !1) ? 2 : 1), xe(e => e !== 2), Le(1)).subscribe(() => { n(); }); }
var V = (() => { class t {
    get currentUrlTree() { return this.stateManager.getCurrentUrlTree(); }
    get rawUrlTree() { return this.stateManager.getRawUrlTree(); }
    disposed = !1;
    nonRouterCurrentEntryChangeSubscription;
    console = g(Xn);
    stateManager = g(Ne);
    options = g(ee, { optional: !0 }) || {};
    pendingTasks = g(ei);
    urlUpdateStrategy = this.options.urlUpdateStrategy || "deferred";
    navigationTransitions = g(It);
    urlSerializer = g(oe);
    location = g(Jt);
    urlHandlingStrategy = g(wt);
    injector = g(Xt);
    _events = new Pt;
    get events() { return this._events; }
    get routerState() { return this.stateManager.getRouterState(); }
    navigated = !1;
    routeReuseStrategy = g(yn);
    injectorCleanup = g(dr, { optional: !0 });
    onSameUrlNavigation = this.options.onSameUrlNavigation || "ignore";
    config = g(pe, { optional: !0 })?.flat() ?? [];
    componentInputBindingEnabled = !!g(Ve, { optional: !0 });
    currentNavigation = this.navigationTransitions.currentNavigation.asReadonly();
    constructor() { this.resetConfig(this.config), this.navigationTransitions.setupNavigations(this).subscribe({ error: e => { } }), this.subscribeToNavigationEvents(); }
    eventsSubscription = new ci;
    subscribeToNavigationEvents() { let e = this.navigationTransitions.events.subscribe(r => { try {
        let i = this.navigationTransitions.currentTransition, o = Ue(this.navigationTransitions.currentNavigation);
        if (i !== null && o !== null) {
            if (this.stateManager.handleRouterEvent(r, o), r instanceof N && r.code !== b.Redirect && r.code !== b.SupersededByNewNavigation)
                this.navigated = !0;
            else if (r instanceof _)
                this.navigated = !0, this.injectorCleanup?.(this.routeReuseStrategy, this.routerState, this.config);
            else if (r instanceof be) {
                let a = r.navigationBehaviorOptions, c = this.urlHandlingStrategy.merge(r.url, i.currentRawUrl), s = l({ scroll: i.extras.scroll, browserUrl: i.extras.browserUrl, info: i.extras.info, skipLocationChange: i.extras.skipLocationChange, replaceUrl: i.extras.replaceUrl || this.urlUpdateStrategy === "eager" || xo(i.source) }, a);
                this.scheduleNavigation(c, ye, null, s, { resolve: i.resolve, reject: i.reject, promise: i.promise });
            }
        }
        xi(r) && this._events.next(r);
    }
    catch (i) {
        this.navigationTransitions.transitionAbortWithErrorSubject.next(i);
    } }); this.eventsSubscription.add(e); }
    resetRootComponentType(e) { this.routerState.root.component = e, this.navigationTransitions.rootComponentType = e; }
    initialNavigation() { this.setUpLocationChangeListener(), this.navigationTransitions.hasRequestedNavigation || this.navigateToSyncWithBrowser(this.location.path(!0), ye, this.stateManager.restoredState(), { replaceUrl: !0 }); }
    setUpLocationChangeListener() { this.nonRouterCurrentEntryChangeSubscription ??= this.stateManager.registerNonRouterCurrentEntryChangeListener((e, r, i, o) => { this.navigateToSyncWithBrowser(e, i, r, o); }); }
    navigateToSyncWithBrowser(e, r, i, o) { let a = i?.navigationId ? i : null, c = i?.\u0275routerUrl ?? e; if (i?.\u0275routerUrl && (o = E(l({}, o), { browserUrl: e })), i) {
        let u = l({}, i);
        delete u.navigationId, delete u.\u0275routerPageId, delete u.\u0275routerUrl, Object.keys(u).length !== 0 && (o.state = u);
    } let s = this.parseUrl(c); this.scheduleNavigation(s, r, a, o).catch(u => { this.disposed || this.injector.get(ti)(u); }); }
    get url() { return this.serializeUrl(this.currentUrlTree); }
    getCurrentNavigation() { return Ue(this.navigationTransitions.currentNavigation); }
    get lastSuccessfulNavigation() { return this.navigationTransitions.lastSuccessfulNavigation; }
    resetConfig(e) { this.config = e.map(cr), this.navigated = !1; }
    ngOnDestroy() { this.dispose(); }
    dispose() { this._events.unsubscribe(), this.navigationTransitions.complete(), this.nonRouterCurrentEntryChangeSubscription?.unsubscribe(), this.nonRouterCurrentEntryChangeSubscription = void 0, this.disposed = !0, this.eventsSubscription.unsubscribe(); }
    createUrlTree(e, r = {}) { let { relativeTo: i, queryParams: o, fragment: a, queryParamsHandling: c, preserveFragment: s } = r, u = s ? this.currentUrlTree.fragment : a, h = null; switch (c ?? this.options.defaultQueryParamsHandling) {
        case "merge":
            h = l(l({}, this.currentUrlTree.queryParams), o);
            break;
        case "preserve":
            h = this.currentUrlTree.queryParams;
            break;
        default: h = o || null;
    } h !== null && (h = this.removeEmptyProps(h)); let m; try {
        let p = i ? i.snapshot : this.routerState.snapshot.root;
        m = Vr(p);
    }
    catch {
        (typeof e[0] != "string" || e[0][0] !== "/") && (e = []), m = this.currentUrlTree.root;
    } return Gr(m, e, h, u ?? null, this.urlSerializer); }
    navigateByUrl(e, r = { skipLocationChange: !1 }) { let i = re(e) ? e : this.parseUrl(e), o = this.urlHandlingStrategy.merge(i, this.rawUrlTree); return this.scheduleNavigation(o, ye, null, r); }
    navigate(e, r = { skipLocationChange: !1 }) { return zo(e), this.navigateByUrl(this.createUrlTree(e, r), r); }
    serializeUrl(e) { return this.urlSerializer.serialize(e); }
    parseUrl(e) { try {
        return this.urlSerializer.parse(e);
    }
    catch {
        return this.console.warn(ri(4018, !1)), this.urlSerializer.parse("/");
    } }
    isActive(e, r) { let i; if (r === !0 ? i = l({}, tr) : r === !1 ? i = l({}, je) : i = l(l({}, je), r), re(e))
        return kt(this.currentUrlTree, e, i); let o = this.parseUrl(e); return kt(this.currentUrlTree, o, i); }
    removeEmptyProps(e) { return Object.entries(e).reduce((r, [i, o]) => (o != null && (r[i] = o), r), {}); }
    scheduleNavigation(e, r, i, o, a) { if (this.disposed)
        return Promise.resolve(!1); let c, s, u; a ? (c = a.resolve, s = a.reject, u = a.promise) : u = new Promise((m, p) => { c = m, s = p; }); let h = this.pendingTasks.add(); return At(this, () => { queueMicrotask(() => this.pendingTasks.remove(h)); }), this.navigationTransitions.handleNavigationRequest({ source: r, restoredState: i, currentUrlTree: this.currentUrlTree, currentRawUrl: this.currentUrlTree, rawUrl: e, extras: o, resolve: c, reject: s, promise: u, currentSnapshot: this.routerState.snapshot, currentRouterState: this.routerState }), u.catch(Promise.reject.bind(Promise)); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = R.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })();
function zo(t) { for (let n = 0; n < t.length; n++)
    if (t[n] == null)
        throw new T(4008, !1); }
import * as Sn from "@angular/common";
import { ViewportScroller as Cn, PlatformNavigation as Ho, PlatformLocation as Fo, \u0275PRECOMMIT_HANDLER_SUPPORTED as qo, LOCATION_INITIALIZED as Bo, Location as wn, \u0275NavigationAdapterForLocation as Vo, HashLocationStrategy as bn, LocationStrategy as vr, PathLocationStrategy as Go } from "@angular/common";
import * as d from "@angular/core";
import { inject as C, HostAttributeToken as Wo, linkedSignal as Qo, untracked as U, signal as O, input as Ko, \u0275INTERNAL_APPLICATION_ERROR_HANDLER as Yo, \u0275RuntimeError as Ja, computed as Zo, booleanAttribute as fr, EventEmitter as Jo, createEnvironmentInjector as Xo, InjectionToken as Qe, \u0275IS_HYDRATION_DOM_REUSE_ENABLED as ea, NgZone as ta, ApplicationRef as In, EnvironmentInjector as ra, DestroyRef as na, afterNextRender as ia, \u0275promiseWithResolvers as Rn, makeEnvironmentProviders as oa, APP_BOOTSTRAP_LISTENER as An, provideAppInitializer as En, \u0275IS_ENABLED_BLOCKING_INITIAL_NAVIGATION as aa, Injector as Tn, \u0275performanceMarkFeature as sa } from "@angular/core";
import { Subject as mr, of as ae, from as Et } from "rxjs";
import { mergeAll as Tt, catchError as ca, filter as ua, concatMap as la, mergeMap as ha } from "rxjs/operators";
var da = (() => { class t {
    router = C(V);
    stateManager = C(Ne);
    fragment = O("");
    queryParams = O({});
    path = O("");
    serializer = C(oe);
    constructor() { this.updateState(), this.router.events?.subscribe(e => { e instanceof _ && this.updateState(); }); }
    updateState() { let { fragment: e, root: r, queryParams: i } = this.stateManager.getCurrentUrlTree(); this.fragment.set(e), this.queryParams.set(i), this.path.set(this.serializer.serialize(new M(r))); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = d.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })(), Nt = (() => { class t {
    router;
    route;
    tabIndexAttribute;
    renderer;
    el;
    locationStrategy;
    hrefAttributeValue = C(new Wo("href"), { optional: !0 });
    reactiveHref = Qo(() => this.isAnchorElement ? this.computeHref(this._urlTree()) : this.hrefAttributeValue);
    get href() { return U(this.reactiveHref); }
    set href(e) { this.reactiveHref.set(e); }
    set target(e) { this._target.set(e); }
    get target() { return U(this._target); }
    _target = O(void 0);
    set queryParams(e) { this._queryParams.set(e); }
    get queryParams() { return U(this._queryParams); }
    _queryParams = O(void 0, { equal: () => !1 });
    set fragment(e) { this._fragment.set(e); }
    get fragment() { return U(this._fragment); }
    _fragment = O(void 0);
    set queryParamsHandling(e) { this._queryParamsHandling.set(e); }
    get queryParamsHandling() { return U(this._queryParamsHandling); }
    _queryParamsHandling = O(void 0);
    set state(e) { this._state.set(e); }
    get state() { return U(this._state); }
    _state = O(void 0, { equal: () => !1 });
    set info(e) { this._info.set(e); }
    get info() { return U(this._info); }
    _info = O(void 0, { equal: () => !1 });
    set relativeTo(e) { this._relativeTo.set(e); }
    get relativeTo() { return U(this._relativeTo); }
    _relativeTo = O(void 0);
    set preserveFragment(e) { this._preserveFragment.set(e); }
    get preserveFragment() { return U(this._preserveFragment); }
    _preserveFragment = O(!1);
    set skipLocationChange(e) { this._skipLocationChange.set(e); }
    get skipLocationChange() { return U(this._skipLocationChange); }
    _skipLocationChange = O(!1);
    set replaceUrl(e) { this._replaceUrl.set(e); }
    get replaceUrl() { return U(this._replaceUrl); }
    _replaceUrl = O(!1);
    browserUrl = Ko(void 0);
    isAnchorElement;
    onChanges = new mr;
    applicationErrorHandler = C(Yo);
    options = C(ee, { optional: !0 });
    reactiveRouterState = C(da);
    constructor(e, r, i, o, a, c) { this.router = e, this.route = r, this.tabIndexAttribute = i, this.renderer = o, this.el = a, this.locationStrategy = c; let s = a.nativeElement.tagName?.toLowerCase(); this.isAnchorElement = s === "a" || s === "area" || !!(typeof customElements == "object" && customElements.get(s)?.observedAttributes?.includes?.("href")); }
    setTabIndexIfNotOnNativeEl(e) { this.tabIndexAttribute != null || this.isAnchorElement || this.applyAttributeValue("tabindex", e); }
    ngOnChanges(e) { this.onChanges.next(this); }
    routerLinkInput = O(null);
    set routerLink(e) { e == null ? (this.routerLinkInput.set(null), this.setTabIndexIfNotOnNativeEl(null)) : (re(e) ? this.routerLinkInput.set(e) : this.routerLinkInput.set(Array.isArray(e) ? e : [e]), this.setTabIndexIfNotOnNativeEl("0")); }
    onClick(e, r, i, o, a) { let c = this._urlTree(); if (c === null || this.isAnchorElement && (e !== 0 || r || i || o || a || typeof this.target == "string" && this.target != "_self"))
        return !0; let s = this.browserUrl(), u = l({ skipLocationChange: this.skipLocationChange, replaceUrl: this.replaceUrl, state: this.state, info: this.info }, s !== void 0 && { browserUrl: s }); return this.router.navigateByUrl(c, u)?.catch(h => { this.applicationErrorHandler(h); }), !this.isAnchorElement; }
    ngOnDestroy() { }
    applyAttributeValue(e, r) { let i = this.renderer, o = this.el.nativeElement; r !== null ? i.setAttribute(o, e, r) : i.removeAttribute(o, e); }
    _urlTree = Zo(() => { this.reactiveRouterState.path(), this._preserveFragment() && this.reactiveRouterState.fragment(); let e = i => i === "preserve" || i === "merge"; (e(this._queryParamsHandling()) || e(this.options?.defaultQueryParamsHandling)) && this.reactiveRouterState.queryParams(); let r = this.routerLinkInput(); return r === null || !this.router.createUrlTree ? null : re(r) ? r : this.router.createUrlTree(r, { relativeTo: this._relativeTo() !== void 0 ? this._relativeTo() : this.route, queryParams: this._queryParams(), fragment: this._fragment(), queryParamsHandling: this._queryParamsHandling(), preserveFragment: this._preserveFragment() }); }, { equal: (e, r) => this.computeHref(e) === this.computeHref(r) });
    get urlTree() { return U(this._urlTree); }
    computeHref(e) { return e !== null && this.locationStrategy ? this.locationStrategy?.prepareExternalUrl(this.router.serializeUrl(e)) ?? "" : null; }
    static \u0275fac = function (r) { return new (r || t)(d.\u0275\u0275directiveInject(V), d.\u0275\u0275directiveInject(K), d.\u0275\u0275injectAttribute("tabindex"), d.\u0275\u0275directiveInject(d.Renderer2), d.\u0275\u0275directiveInject(d.ElementRef), d.\u0275\u0275directiveInject(Sn.LocationStrategy)); };
    static \u0275dir = d.\u0275\u0275defineDirective({ type: t, selectors: [["", "routerLink", ""]], hostVars: 2, hostBindings: function (r, i) { r & 1 && d.\u0275\u0275listener("click", function (a) { return i.onClick(a.button, a.ctrlKey, a.shiftKey, a.altKey, a.metaKey); }), r & 2 && d.\u0275\u0275attribute("href", i.reactiveHref(), d.\u0275\u0275sanitizeUrlOrResourceUrl)("target", i._target()); }, inputs: { target: "target", queryParams: "queryParams", fragment: "fragment", queryParamsHandling: "queryParamsHandling", state: "state", info: "info", relativeTo: "relativeTo", preserveFragment: [2, "preserveFragment", "preserveFragment", fr], skipLocationChange: [2, "skipLocationChange", "skipLocationChange", fr], replaceUrl: [2, "replaceUrl", "replaceUrl", fr], browserUrl: [1, "browserUrl"], routerLink: "routerLink" }, features: [d.\u0275\u0275NgOnChangesFeature] });
} return t; })(), fa = (() => { class t {
    router;
    element;
    renderer;
    cdr;
    links;
    classes = [];
    routerEventsSubscription;
    linkInputChangesSubscription;
    _isActive = !1;
    get isActive() { return this._isActive; }
    routerLinkActiveOptions = { exact: !1 };
    ariaCurrentWhenActive;
    isActiveChange = new Jo;
    link = C(Nt, { optional: !0 });
    constructor(e, r, i, o) { this.router = e, this.element = r, this.renderer = i, this.cdr = o, this.routerEventsSubscription = e.events.subscribe(a => { a instanceof _ && this.update(); }); }
    ngAfterContentInit() { ae(this.links.changes, ae(null)).pipe(Tt()).subscribe(e => { this.update(), this.subscribeToEachLinkOnChanges(); }); }
    subscribeToEachLinkOnChanges() { this.linkInputChangesSubscription?.unsubscribe(); let e = [...this.links.toArray(), this.link].filter(r => !!r).map(r => r.onChanges); this.linkInputChangesSubscription = Et(e).pipe(Tt()).subscribe(r => { this._isActive !== this.isLinkActive(this.router)(r) && this.update(); }); }
    set routerLinkActive(e) { let r = Array.isArray(e) ? e : e.split(" "); this.classes = r.filter(i => !!i); }
    ngOnChanges(e) { this.update(); }
    ngOnDestroy() { this.routerEventsSubscription.unsubscribe(), this.linkInputChangesSubscription?.unsubscribe(); }
    update() { !this.links || !this.router.navigated || queueMicrotask(() => { let e = this.hasActiveLinks(); this.classes.forEach(r => { e ? this.renderer.addClass(this.element.nativeElement, r) : this.renderer.removeClass(this.element.nativeElement, r); }), e && this.ariaCurrentWhenActive !== void 0 ? this.renderer.setAttribute(this.element.nativeElement, "aria-current", this.ariaCurrentWhenActive.toString()) : this.renderer.removeAttribute(this.element.nativeElement, "aria-current"), this._isActive !== e && (this._isActive = e, this.cdr.markForCheck(), this.isActiveChange.emit(e)); }); }
    isLinkActive(e) { let r = pa(this.routerLinkActiveOptions) ? this.routerLinkActiveOptions : this.routerLinkActiveOptions.exact ?? !1 ? l({}, tr) : l({}, je); return i => { let o = i.urlTree; return o ? U(rr(o, e, r)) : !1; }; }
    hasActiveLinks() { let e = this.isLinkActive(this.router); return this.link && e(this.link) || this.links.some(e); }
    static \u0275fac = function (r) { return new (r || t)(d.\u0275\u0275directiveInject(V), d.\u0275\u0275directiveInject(d.ElementRef), d.\u0275\u0275directiveInject(d.Renderer2), d.\u0275\u0275directiveInject(d.ChangeDetectorRef)); };
    static \u0275dir = d.\u0275\u0275defineDirective({ type: t, selectors: [["", "routerLinkActive", ""]], contentQueries: function (r, i, o) { if (r & 1 && d.\u0275\u0275contentQuery(o, Nt, 5), r & 2) {
            let a;
            d.\u0275\u0275queryRefresh(a = d.\u0275\u0275loadQuery()) && (i.links = a);
        } }, inputs: { routerLinkActiveOptions: "routerLinkActiveOptions", ariaCurrentWhenActive: "ariaCurrentWhenActive", routerLinkActive: "routerLinkActive" }, outputs: { isActiveChange: "isActiveChange" }, exportAs: ["routerLinkActive"], features: [d.\u0275\u0275NgOnChangesFeature] });
} return t; })();
function pa(t) { let n = t; return !!(n.paths || n.matrixParams || n.queryParams || n.fragment); }
var We = class {
}, ga = (() => { class t {
    preload(e, r) { return r().pipe(ca(() => ae(null))); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = d.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })(), va = (() => { class t {
    preload(e, r) { return ae(null); }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = d.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })(), Nn = (() => { class t {
    router;
    injector;
    preloadingStrategy;
    loader;
    subscription;
    constructor(e, r, i, o) { this.router = e, this.injector = r, this.preloadingStrategy = i, this.loader = o; }
    setUpPreloading() { this.subscription = this.router.events.pipe(ua(e => e instanceof _), la(() => this.preload())).subscribe(() => { }); }
    preload() { return this.processRoutes(this.injector, this.router.config); }
    ngOnDestroy() { this.subscription?.unsubscribe(); }
    processRoutes(e, r) { let i = []; for (let o of r) {
        o.providers && !o._injector && (o._injector = Xo(o.providers, e, ""));
        let a = o._injector ?? e;
        o._loadedNgModuleFactory && !o._loadedInjector && (o._loadedInjector = o._loadedNgModuleFactory.create(a).injector);
        let c = o._loadedInjector ?? a;
        (o.loadChildren && !o._loadedRoutes && o.canLoad === void 0 || o.loadComponent && !o._loadedComponent) && i.push(this.preloadConfig(a, o)), (o.children || o._loadedRoutes) && i.push(this.processRoutes(c, o.children ?? o._loadedRoutes));
    } return Et(i).pipe(Tt()); }
    preloadConfig(e, r) { return this.preloadingStrategy.preload(r, () => { if (e.destroyed)
        return ae(null); let i; r.loadChildren && r.canLoad === void 0 ? i = Et(this.loader.loadChildren(e, r)) : i = ae(null); let o = i.pipe(ha(a => a === null ? ae(void 0) : (r._loadedRoutes = a.routes, r._loadedInjector = a.injector, r._loadedNgModuleFactory = a.factory, this.processRoutes(a.injector ?? e, a.routes)))); if (r.loadComponent && !r._loadedComponent) {
        let a = this.loader.loadComponent(e, r);
        return Et([o, a]).pipe(Tt());
    }
    else
        return o; }); }
    static \u0275fac = function (r) { return new (r || t)(d.\u0275\u0275inject(V), d.\u0275\u0275inject(d.EnvironmentInjector), d.\u0275\u0275inject(We), d.\u0275\u0275inject(Ct)); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: t, factory: t.\u0275fac, providedIn: "root" });
} return t; })(), Mt = new Qe(""), Mn = (() => { class t {
    options;
    routerEventsSubscription;
    scrollEventsSubscription;
    lastId = 0;
    lastSource = ye;
    restoredId = 0;
    store = {};
    isHydrating = C(ea, { optional: !0 }) ?? !1;
    urlSerializer = C(oe);
    zone = C(ta);
    viewportScroller = C(Cn);
    transitions = C(It);
    constructor(e) { this.options = e, this.options.scrollPositionRestoration ||= "disabled", this.options.anchorScrolling ||= "disabled", this.isHydrating && C(In).whenStable().then(() => { this.isHydrating = !1; }); }
    init() { this.options.scrollPositionRestoration !== "disabled" && this.viewportScroller.setHistoryScrollRestoration("manual"), this.routerEventsSubscription = this.createScrollEvents(), this.scrollEventsSubscription = this.consumeScrollEvents(); }
    createScrollEvents() { return this.transitions.events.subscribe(e => { e instanceof X ? (this.store[this.lastId] = this.viewportScroller.getScrollPosition(), this.lastSource = e.navigationTrigger, this.restoredId = e.restoredState ? e.restoredState.navigationId : 0) : e instanceof _ ? (this.lastId = e.id, this.scheduleScrollEvent(e, this.urlSerializer.parse(e.urlAfterRedirects).fragment)) : e instanceof B && e.code === Se.IgnoredSameUrlNavigation && (this.lastSource = void 0, this.restoredId = 0, this.scheduleScrollEvent(e, this.urlSerializer.parse(e.url).fragment)); }); }
    consumeScrollEvents() { return this.transitions.events.subscribe(e => { if (!(e instanceof Ce) || e.scrollBehavior === "manual")
        return; let r = { behavior: "instant" }; e.position ? this.options.scrollPositionRestoration === "top" ? this.viewportScroller.scrollToPosition([0, 0], r) : this.options.scrollPositionRestoration === "enabled" && this.viewportScroller.scrollToPosition(e.position, r) : e.anchor && this.options.anchorScrolling === "enabled" ? this.viewportScroller.scrollToAnchor(e.anchor) : this.options.scrollPositionRestoration !== "disabled" && this.viewportScroller.scrollToPosition([0, 0]); }); }
    scheduleScrollEvent(e, r) { if (this.isHydrating)
        return; let i = U(this.transitions.currentNavigation)?.extras.scroll; this.zone.runOutsideAngular(() => S(this, null, function* () { yield new Promise(o => { setTimeout(o), typeof requestAnimationFrame < "u" && requestAnimationFrame(o); }), this.zone.run(() => { this.transitions.events.next(new Ce(e, this.lastSource === "popstate" ? this.store[this.restoredId] : null, r, i)); }); })); }
    ngOnDestroy() { this.routerEventsSubscription?.unsubscribe(), this.scrollEventsSubscription?.unsubscribe(); }
    static \u0275fac = function (r) { d.\u0275\u0275invalidFactory(); };
    static \u0275prov = d.\u0275\u0275defineInjectable({ token: t, factory: t.\u0275fac });
} return t; })();
var ma = (() => { class t extends Ne {
    injector = C(ra);
    navigation = C(Ho);
    inMemoryScrollingEnabled = C(Mt, { optional: !0 }) !== null;
    base = new URL(C(Fo).href).origin;
    appRootURL = new URL(this.location.prepareExternalUrl?.("/") ?? "/", this.base).href;
    precommitHandlerSupported = C(qo);
    activeHistoryEntry = this.navigation.currentEntry;
    currentNavigation = {};
    nonRouterCurrentEntryChangeSubject = new mr;
    nonRouterEntryChangeListener;
    get registered() { return this.nonRouterEntryChangeListener !== void 0 && !this.nonRouterEntryChangeListener.closed; }
    constructor() { super(); let e = r => { this.handleNavigate(r); }; this.navigation.addEventListener("navigate", e), C(na).onDestroy(() => this.navigation.removeEventListener("navigate", e)); }
    registerNonRouterCurrentEntryChangeListener(e) { return this.activeHistoryEntry = this.navigation.currentEntry, this.nonRouterEntryChangeListener = this.nonRouterCurrentEntryChangeSubject.subscribe(({ path: r, state: i }) => { e(r, i, "popstate", this.precommitHandlerSupported ? {} : { replaceUrl: !0 }); }), this.nonRouterEntryChangeListener; }
    handleRouterEvent(e, r) { return S(this, null, function* () { if (this.currentNavigation = E(l({}, this.currentNavigation), { routerTransition: r }), e instanceof X)
        this.updateStateMemento(), this.precommitHandlerSupported && this.maybeCreateNavigationForTransition(r);
    else if (e instanceof B)
        this.finishNavigation(), this.commitTransition(r);
    else if (e instanceof we)
        r.routesRecognizeHandler.deferredHandle = new Promise(i => S(this, null, function* () { if (this.urlUpdateStrategy === "eager")
            try {
                this.maybeCreateNavigationForTransition(r), yield this.currentNavigation.commitUrl?.();
            }
            catch {
                return;
            } i(); }));
    else if (e instanceof le)
        r.beforeActivateHandler.deferredHandle = new Promise(i => S(this, null, function* () { if (this.urlUpdateStrategy === "deferred")
            try {
                this.maybeCreateNavigationForTransition(r), yield this.currentNavigation.commitUrl?.();
            }
            catch {
                return;
            } this.commitTransition(r), i(); }));
    else if (e instanceof N || e instanceof ne) {
        if (e instanceof N && e.code === b.Redirect && !!this.currentNavigation.commitUrl)
            return;
        this.cancel(r, e);
    }
    else if (e instanceof _) {
        let { resolveHandler: i, removeAbortListener: o } = this.currentNavigation;
        this.currentNavigation = {}, o?.(), this.activeHistoryEntry = this.navigation.currentEntry, ia({ read: () => i?.() }, { injector: this.injector });
    } }); }
    maybeCreateNavigationForTransition(e) { let { navigationEvent: r, commitUrl: i } = this.currentNavigation; if (i || r && r.navigationType === "traverse" && this.eventAndRouterDestinationsMatch(r, e))
        return; this.currentNavigation.removeAbortListener?.(); let o = this.createBrowserPath(e); this.navigate(o, e); }
    navigate(e, r) { let i = r.extras.skipLocationChange ? this.navigation.currentEntry.url : this.location.prepareExternalUrl(e), o = l(l({}, r.extras.state), this.generateNgRouterState(r)), a = { \u0275routerInfo: { intercept: !0 } }; !this.navigation.transition && this.currentNavigation.navigationEvent && (r.extras.replaceUrl = !1); let c = this.location.isCurrentPathEqualTo(i) || r.extras.replaceUrl || r.extras.skipLocationChange ? "replace" : "push"; pr(this.navigation.navigate(i, { state: o, history: c, info: a })); }
    finishNavigation() { this.currentNavigation.commitUrl?.(), this.currentNavigation?.resolveHandler?.(), this.currentNavigation = {}; }
    cancel(e, r) { return S(this, null, function* () { this.currentNavigation.rejectNavigateEvent?.(); let i = {}; if (this.currentNavigation = i, nr(r))
        return; let o = this.canceledNavigationResolution === "computed" && this.navigation.currentEntry.key !== this.activeHistoryEntry.key; if (this.resetInternalState(e.finalUrl, o), this.navigation.currentEntry.id !== this.activeHistoryEntry.id && !(r instanceof N && r.code === b.Aborted && (yield Promise.resolve(), this.currentNavigation !== i)))
        if (o)
            pr(this.navigation.traverseTo(this.activeHistoryEntry.key, { info: { \u0275routerInfo: { intercept: !1 } } }));
        else {
            let a = this.urlSerializer.serialize(this.getCurrentUrlTree()), c = this.location.prepareExternalUrl(a);
            pr(this.navigation.navigate(c, { state: this.activeHistoryEntry.getState(), history: "replace", info: { \u0275routerInfo: { intercept: !1 } } }));
        } }); }
    resetInternalState(e, r) { this.routerState = this.stateMemento.routerState, this.currentUrlTree = this.stateMemento.currentUrlTree, this.rawUrlTree = r ? this.stateMemento.rawUrlTree : this.urlHandlingStrategy.merge(this.currentUrlTree, e ?? this.rawUrlTree); }
    handleNavigate(e) { if (!e.canIntercept || e.navigationType === "reload")
        return; let r = e?.info?.\u0275routerInfo; if (r && !r.intercept)
        return; let i = !!r; if (!i && (this.currentNavigation.routerTransition?.abort(), !this.registered)) {
        this.finishNavigation();
        return;
    } this.currentNavigation = l({}, this.currentNavigation), this.currentNavigation.navigationEvent = e; let o = () => { this.currentNavigation.routerTransition?.abort(); }; e.signal.addEventListener("abort", o), this.currentNavigation.removeAbortListener = () => e.signal.removeEventListener("abort", o); let c = { scroll: this.inMemoryScrollingEnabled ? "manual" : this.currentNavigation.routerTransition?.extras.scroll ?? "after-transition" }, { promise: s, resolve: u, reject: h } = Rn(), { promise: m, resolve: p, reject: A } = Rn(); if (this.currentNavigation.rejectNavigateEvent = () => { e.signal.removeEventListener("abort", o), A(), h(); }, this.currentNavigation.resolveHandler = () => { this.currentNavigation.removeAbortListener?.(), u(); }, s.catch(() => { }), m.catch(() => { }), c.handler = () => s, this.deferredCommitSupported(e)) {
        let P = new Promise(I => { c.precommitHandler = $ => (this.navigation.transition?.navigationType === "traverse" ? I(() => { }) : I($.redirect.bind($)), m); });
        this.currentNavigation.commitUrl = () => S(this, null, function* () { this.currentNavigation.commitUrl = void 0; let I = this.currentNavigation.routerTransition; if (I && !I.extras.skipLocationChange) {
            let $ = this.createBrowserPath(I), Me = this.location.isCurrentPathEqualTo($) || I.extras.replaceUrl ? "replace" : "push", ge = l(l({}, I.extras.state), this.generateNgRouterState(I)), Y = this.location.prepareExternalUrl($);
            (yield P)(Y, { state: ge, history: Me });
        } return p(), yield this.navigation.transition?.committed; });
    } e.intercept(c), i || this.handleNavigateEventTriggeredOutsideRouterAPIs(e); }
    handleNavigateEventTriggeredOutsideRouterAPIs(e) { let r = e.destination.url.substring(this.appRootURL.length - 1), i = e.destination.getState(); this.nonRouterCurrentEntryChangeSubject.next({ path: r, state: i }); }
    eventAndRouterDestinationsMatch(e, r) { let i = this.createBrowserPath(r), o = new URL(e.destination.url), a = this.location.prepareExternalUrl(i); return new URL(a, o.origin).href === o.href; }
    generateNgRouterState(e) { return E(l({}, this.routerUrlState(e)), { navigationId: e.id }); }
    deferredCommitSupported(e) { return this.precommitHandlerSupported && e.cancelable; }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275prov = d.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })();
function pr(t) { return t.finished?.catch(() => { }), t.committed?.catch(() => { }), t; }
function ya(t, ...n) { return oa([{ provide: pe, multi: !0, useValue: t }, { provide: K, useFactory: Dn }, { provide: An, multi: !0, useFactory: _n }, n.map(e => e.\u0275providers)]); }
function Dn() { return C(V).routerState.root; }
function k(t, n) { return { \u0275kind: t, \u0275providers: n }; }
function Ra(t = {}) { return k(4, [{ provide: Mt, useFactory: () => new Mn(t) }]); }
function Sa() { return k(11, [{ provide: Ne, useExisting: ma }, { provide: wn, useClass: Vo }, []]); }
function _n() { let t = C(Tn); return n => { let e = t.get(In); if (n !== e.components[0])
    return; let r = t.get(V), i = t.get(Un); t.get(yr) === 1 && r.initialNavigation(), t.get(Ln, null, { optional: !0 })?.setUpPreloading(), t.get(Mt, null, { optional: !0 })?.init(), r.resetRootComponentType(e.componentTypes[0]), i.closed || (i.next(), i.complete(), i.unsubscribe()); }; }
var Un = new Qe("", { factory: () => new mr }), yr = new Qe("", { factory: () => 1 });
function On() { let t = [{ provide: aa, useValue: !0 }, { provide: yr, useValue: 0 }, En(() => { let n = C(Tn); return n.get(Bo, Promise.resolve()).then(() => new Promise(r => { let i = n.get(V), o = n.get(Un); At(i, () => { r(!0); }), n.get(It).afterPreactivation = () => (r(!0), o.closed ? ae(void 0) : o), i.initialNavigation(); })); })]; return k(2, t); }
function Pn() { let t = [En(() => { C(V).setUpLocationChangeListener(); }), { provide: yr, useValue: 2 }]; return k(3, t); }
function Ca() { let t = []; return t = [], k(1, t); }
var Ln = new Qe("");
function xn(t) { return k(0, [{ provide: Ln, useExisting: Nn }, { provide: We, useExisting: t }]); }
function wa(t) { return k(5, [{ provide: ee, useValue: t }]); }
function ba() { return k(6, [{ provide: vr, useClass: bn }]); }
function Ia(t) { return k(7, [{ provide: bt, useValue: t }]); }
function Aa() { return k(10, [{ provide: dr, useValue: vn }]); }
function jn(t = {}) { return k(8, [{ provide: Ve, useFactory: () => new Xr(t) }]); }
function kn(t) { sa("NgRouterViewTransitions"); let n = [{ provide: lr, useValue: gn }, { provide: hr, useValue: l({ skipNextTransition: !!t?.skipInitialTransition }, t) }]; return k(9, n); }
var $n = [wn, { provide: oe, useClass: J }, V, fe, { provide: K, useFactory: Dn }, Ct], Ea = (() => { class t {
    constructor() { }
    static forRoot(e, r) { return { ngModule: t, providers: [$n, [], { provide: pe, multi: !0, useValue: e }, [], r?.errorHandler ? { provide: bt, useValue: r.errorHandler } : [], { provide: ee, useValue: r || {} }, r?.useHash ? Na() : Ma(), Ta(), r?.preloadingStrategy ? xn(r.preloadingStrategy).\u0275providers : [], r?.initialNavigation ? Da(r) : [], r?.bindToComponentInputs ? jn(typeof r.bindToComponentInputs == "object" ? r.bindToComponentInputs : {}).\u0275providers : [], r?.enableViewTransitions ? kn().\u0275providers : [], _a()] }; }
    static forChild(e) { return { ngModule: t, providers: [{ provide: pe, multi: !0, useValue: e }] }; }
    static \u0275fac = function (r) { return new (r || t); };
    static \u0275mod = d.\u0275\u0275defineNgModule({ type: t });
    static \u0275inj = d.\u0275\u0275defineInjector({});
} return t; })();
function Ta() { return { provide: Mt, useFactory: () => { let t = C(Cn), n = C(ee); return n.scrollOffset && t.setOffset(n.scrollOffset), new Mn(n); } }; }
function Na() { return { provide: vr, useClass: bn }; }
function Ma() { return { provide: vr, useClass: Go }; }
function Da(t) { return [t.initialNavigation === "disabled" ? Pn().\u0275providers : [], t.initialNavigation === "enabledBlocking" ? On().\u0275providers : []]; }
var gr = new Qe("");
function _a() { return [{ provide: gr, useFactory: _n }, { provide: An, multi: !0, useExisting: gr }]; }
import { inject as Ke, Version as Ua } from "@angular/core";
import "@angular/common";
import "rxjs";
import "rxjs/operators";
import "@angular/platform-browser";
function ws(t) { return t.map(n => (...e) => Ke(n).canMatch(...e)); }
function bs(t) { return t.map(n => (...e) => Ke(n).canActivate(...e)); }
function Is(t) { return t.map(n => (...e) => Ke(n).canActivateChild(...e)); }
function As(t) { return t.map(n => (...e) => Ke(n).canDeactivate(...e)); }
function Es(t) { return (...n) => Ke(t).resolve(...n); }
var Ts = new Ua("22.0.0");
export { K as ActivatedRoute, Ie as ActivatedRouteSnapshot, pt as ActivationEnd, ft as ActivationStart, Rt as BaseRouteReuseStrategy, dt as ChildActivationEnd, ht as ChildActivationStart, fe as ChildrenOutletContexts, dn as DefaultTitleStrategy, J as DefaultUrlSerializer, w as EventType, at as GuardsCheckEnd, ot as GuardsCheckStart, N as NavigationCancel, b as NavigationCancellationCode, _ as NavigationEnd, ne as NavigationError, B as NavigationSkipped, Se as NavigationSkippedCode, X as NavigationStart, va as NoPreloading, gt as OutletContext, f as PRIMARY_OUTLET, ga as PreloadAllModules, We as PreloadingStrategy, ee as ROUTER_CONFIGURATION, gr as ROUTER_INITIALIZER, Jr as ROUTER_OUTLET_DATA, pe as ROUTES, Ae as RedirectCommand, ct as ResolveEnd, st as ResolveStart, lt as RouteConfigLoadEnd, ut as RouteConfigLoadStart, yn as RouteReuseStrategy, V as Router, x as RouterEvent, Nt as RouterLink, fa as RouterLinkActive, Nt as RouterLinkWithHref, Ea as RouterModule, ar as RouterOutlet, Nn as RouterPreloader, ze as RouterState, He as RouterStateSnapshot, $e as RoutesRecognized, Ce as Scroll, ur as TitleStrategy, wt as UrlHandlingStrategy, te as UrlSegment, y as UrlSegmentGroup, oe as UrlSerializer, M as UrlTree, Ts as VERSION, ue as convertToParamMap, Br as createUrlTreeFromSnapshot, Or as defaultUrlMatcher, jo as destroyDetachedRouteHandle, rr as isActive, bs as mapToCanActivate, Is as mapToCanActivateChild, As as mapToCanDeactivate, ws as mapToCanMatch, Es as mapToResolve, ya as provideRouter, jn as withComponentInputBinding, Ca as withDebugTracing, Pn as withDisabledInitialNavigation, On as withEnabledBlockingInitialNavigation, Aa as withExperimentalAutoCleanupInjectors, Sa as withExperimentalPlatformNavigation, ba as withHashLocation, Ra as withInMemoryScrolling, Ia as withNavigationErrorHandler, xn as withPreloading, wa as withRouterConfig, kn as withViewTransitions, sr as \u0275EmptyOutletComponent, $n as \u0275ROUTER_PROVIDERS, At as \u0275afterNextNavigation, fn as \u0275loadChildren };
/*! Bundled license information:

@angular/router/fesm2022/_router-chunk.mjs:
@angular/router/fesm2022/_router_module-chunk.mjs:
@angular/router/fesm2022/router.mjs:
  (**
   * @license Angular v22.0.0
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
