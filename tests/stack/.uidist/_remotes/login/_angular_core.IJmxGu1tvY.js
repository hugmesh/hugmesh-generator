import { a as Kc, b as ct, f as Jc } from "@nf-internal/chunk-Z7JQKSY7";
import { B as Zc, E as Yc, F as jh, G as Vh, H as Xc, I as Hh, J as Bh, K as $h, L as yw, a as ae, b as x, c as Gi, f as Qc, g as Wi, n as Yo, p as zi, r as Qi, s as $t, w as Zi, x as Ph, y as Fh } from "@nf-internal/chunk-S4GBJQJW";
import { a as q, b as Ie, c as Lh, d as Se, e as zc } from "@nf-internal/chunk-PZNONLPT";
import { setActiveConsumer as zn } from "@angular/core/primitives/signals";
import { isNotFound as Ew } from "@angular/core/primitives/di";
import { BehaviorSubject as Iw, Observable as Dw, Subject as Tw, Subscription as Cw } from "rxjs";
var Ki = class {
    full;
    major;
    minor;
    patch;
    constructor(t) { this.full = t; let n = t.split("."); this.major = n[0], this.minor = n[1], this.patch = n.slice(2).join("."); }
}, Ji = new Ki("22.0.2"), ts = (() => { let e = Ji.full; return `https://${e.includes("-next") || e.includes("-rc") || e === "0.0.0-PLACEHOLDER" ? "next" : `v${Ji.major}`}.angular.dev`; })(), Mw = `${ts}/errors`, ns = "https://angular.dev/best-practices/security#preventing-cross-site-scripting-xss", D = class extends Error {
    code;
    constructor(t, n) { super(ir(t, n)), this.code = t; }
};
function ww(e) { return `NG0${Math.abs(e)}`; }
function ir(e, t) { return `${ww(e)}${t ? ": " + t : ""}`; }
function V(e) { for (let t in e)
    if (e[t] === V)
        return t; throw Error(""); }
function Qh(e, t) { for (let n in t)
    t.hasOwnProperty(n) && !e.hasOwnProperty(n) && (e[n] = t[n]); }
function sr(e) {
    if (typeof e == "string")
        return e;
    if (Array.isArray(e))
        return `[${e.map(sr).join(", ")}]`;
    if (e == null)
        return "" + e;
    let t = e.overriddenName || e.name;
    if (t)
        return `${t}`;
    let n = e.toString();
    if (n == null)
        return "" + n;
    let o = n.indexOf(`
`);
    return o >= 0 ? n.slice(0, o) : n;
}
function os(e, t) { return e ? t ? `${e} ${t}` : e : t || ""; }
function Nw(e, t = 100) { if (!e || t < 1 || e.length <= t)
    return e; if (t == 1)
    return e.substring(0, 1) + "..."; let n = Math.round(t / 2); return e.substring(0, n) + "..." + e.substring(e.length - n); }
var _w = V({ __forward_ref__: V });
function ar(e) { return e.__forward_ref__ = ar, e; }
function P(e) { return cr(e) ? e() : e; }
function cr(e) { return typeof e == "function" && e.hasOwnProperty(_w) && e.__forward_ref__ === ar; }
function fl(e, t, n) { e != t && Gt(n, e, t, "=="); }
function pl(e, t) { e == null && Gt(t, e, null, "!="); }
function Gt(e, t, n, o) { throw new Error(`ASSERTION ERROR: ${e}` + (o == null ? "" : ` [Expected=> ${n} ${o} ${t} <=Actual]`)); }
function Y(e) { return { token: e.token, providedIn: e.providedIn || null, factory: e.factory, value: void 0 }; }
function lr(e) { return { providers: e.providers || [], imports: e.imports || [] }; }
function ur(e) { return bw(e, Wt); }
function Sw(e) { return ur(e) !== null; }
function bw(e, t) { return e.hasOwnProperty(t) && e[t] || null; }
function Aw(e) { let t = e?.[Wt] ?? null; return t || null; }
function Jo(e) { return e && e.hasOwnProperty(Xo) ? e[Xo] : null; }
var Wt = V({ \u0275prov: V }), Xo = V({ \u0275inj: V }), C = class {
    _desc;
    ngMetadataName = "InjectionToken";
    \u0275prov;
    constructor(t, n) { this._desc = t, this.\u0275prov = void 0, typeof n == "number" ? this.__NG_ELEMENT_ID__ = n : n !== void 0 && (this.\u0275prov = Y({ token: this, providedIn: n.providedIn || "root", factory: n.factory })); }
    get multi() { return this; }
    toString() { return `InjectionToken ${this._desc}`; }
}, Uh;
function Rw(e) { Gt("setInjectorProfilerContext should never be called in production mode"); let t = Uh; return Uh = e, t; }
function hl(e) { return e && !!e.\u0275providers; }
var pn = V({ \u0275cmp: V }), dr = V({ \u0275dir: V }), fr = V({ \u0275pipe: V }), rs = V({ \u0275mod: V }), $e = V({ \u0275fac: V }), hn = V({ __NG_ELEMENT_ID__: V }), qh = V({ __NG_ENV_ID__: V });
function Zn(e) { return ss(e, "@NgModule"), e[rs] || null; }
function is(e) { let t = Zn(e); if (!t)
    throw new D(915, !1); return t; }
function W(e) { return ss(e, "@Component"), e[pn] || null; }
function Oe(e) { return ss(e, "@Directive"), e[dr] || null; }
function tt(e) { return ss(e, "@Pipe"), e[fr] || null; }
function ss(e, t) { if (e == null)
    throw new D(-919, !1); }
function pr(e) { let t = W(e) || Oe(e) || tt(e); return t !== null && t.standalone; }
function b(e) { return typeof e == "string" ? e : e == null ? "" : String(e); }
function Ge(e) { return typeof e == "function" ? e.name || e.toString() : typeof e == "object" && e != null && typeof e.type == "function" ? e.type.name || e.type.toString() : b(e); }
var Zh = V({ ngErrorCode: V }), xw = V({ ngErrorMessage: V }), kw = V({ ngTokenPath: V });
function gl(e, t) { return Yh("", -200, t); }
function as(e, t) { throw new D(-201, !1); }
function Yh(e, t, n) { let o = new D(t, e); return o[Zh] = t, o[xw] = e, n && (o[kw] = n), o; }
function Ow(e) { return e[Zh]; }
var tl;
function Kh() { return tl; }
function Te(e) { let t = tl; return tl = e, t; }
function ml(e, t, n) { let o = ur(e); if (o && o.providedIn == "root")
    return o.value === void 0 ? o.value = o.factory() : o.value; if (n & 8)
    return null; if (t !== void 0)
    return t; as(e, ""); }
var Le = globalThis;
var Lw = {}, un = Lw, nl = "__NG_DI_FLAG__", ol = class {
    injector;
    constructor(t) { this.injector = t; }
    retrieve(t, n) { let o = dn(n) || 0; try {
        return this.injector.get(t, o & 8 ? null : un, o);
    }
    catch (r) {
        if (Jc(r))
            return r;
        throw r;
    } }
};
function Pw(e, t = 0) { let n = Kc(); if (n === void 0)
    throw new D(-203, !1); if (n === null)
    return ml(e, void 0, t); {
    let o = Fw(t), r = n.retrieve(e, o);
    if (Jc(r)) {
        if (o.optional)
            return null;
        throw r;
    }
    return r;
} }
function he(e, t = 0) { return (Kh() || Pw)(P(e), t); }
function cs(e) { throw new D(202, !1); }
function E(e, t) { return he(e, dn(t)); }
function dn(e) { return typeof e > "u" || typeof e == "number" ? e : 0 | (e.optional && 8) | (e.host && 1) | (e.self && 2) | (e.skipSelf && 4); }
function Fw(e) { return { optional: !!(e & 8), host: !!(e & 1), self: !!(e & 2), skipSelf: !!(e & 4) }; }
function rl(e) { let t = []; for (let n = 0; n < e.length; n++) {
    let o = P(e[n]);
    if (Array.isArray(o)) {
        if (o.length === 0)
            throw new D(900, !1);
        let r, i = 0;
        for (let s = 0; s < o.length; s++) {
            let a = o[s], c = jw(a);
            typeof c == "number" ? c === -1 ? r = a.token : i |= c : r = a;
        }
        t.push(he(r, i));
    }
    else
        t.push(he(o));
} return t; }
function Yn(e, t) { return e[nl] = t, e.prototype[nl] = t, e; }
function jw(e) { return e[nl]; }
function Ut(e, t) { let n = e.hasOwnProperty($e); return n ? e[$e] : null; }
function Jh(e, t, n) { if (e.length !== t.length)
    return !1; for (let o = 0; o < e.length; o++) {
    let r = e[o], i = t[o];
    if (n && (r = n(r), i = n(i)), i !== r)
        return !1;
} return !0; }
function nt(e) { return e.flat(Number.POSITIVE_INFINITY); }
function hr(e, t) { e.forEach(n => Array.isArray(n) ? hr(n, t) : t(n)); }
function vl(e, t, n) { t >= e.length ? e.push(n) : e.splice(t, 0, n); }
function gr(e, t) { return t >= e.length - 1 ? e.pop() : e.splice(t, 1)[0]; }
function mr(e, t) { let n = []; for (let o = 0; o < e; o++)
    n.push(t); return n; }
function yl(e, t, n) { let o = e.length - n; for (; t < o;)
    e[t] = e[t + n], t++; for (; n--;)
    e.pop(); }
function El(e, t, n, o) { let r = e.length; if (r == t)
    e.push(n, o);
else if (r === 1)
    e.push(o, e[0]), e[0] = n;
else {
    for (r--, e.push(e[r - 1], e[r]); r > t;) {
        let i = r - 2;
        e[r] = e[i], r--;
    }
    e[t] = n, e[t + 1] = o;
} }
function vr(e, t, n) { let o = Kn(e, t); return o >= 0 ? e[o | 1] = n : (o = ~o, El(e, o, t, n)), o; }
function ls(e, t) { let n = Kn(e, t); if (n >= 0)
    return e[n | 1]; }
function Kn(e, t) { return Vw(e, t, 1); }
function Vw(e, t, n) { let o = 0, r = e.length >> n; for (; r !== o;) {
    let i = o + (r - o >> 1), s = e[i << n];
    if (t === s)
        return i << n;
    s > t ? r = i : o = i + 1;
} return ~(r << n); }
var wt = {}, F = [], We = new C(""), yr = new C("", -1), us = new C(""), Ct = class {
    get(t, n = un) { if (n === un) {
        let r = Yh("", -201);
        throw r.name = "\u0275NotFound", r;
    } return n; }
};
function Pe(e) { return { \u0275providers: e }; }
function Il(e) { return Pe([{ provide: We, multi: !0, useValue: e }]); }
function Xh(...e) { return { \u0275providers: ds(!0, e), \u0275fromNgModule: !0 }; }
function ds(e, ...t) { let n = [], o = new Set, r, i = s => { n.push(s); }; return hr(t, s => { let a = s; er(a, i, [], o) && (r ||= [], r.push(a)); }), r !== void 0 && eg(r, i), n; }
function eg(e, t) { for (let n = 0; n < e.length; n++) {
    let { ngModule: o, providers: r } = e[n];
    Dl(r, i => { t(i, o); });
} }
function er(e, t, n, o) { if (e = P(e), !e)
    return !1; let r = null, i = Jo(e), s = !i && W(e); if (!i && !s) {
    let c = e.ngModule;
    if (i = Jo(c), i)
        r = c;
    else
        return !1;
}
else {
    if (s && !s.standalone)
        return !1;
    r = e;
} let a = o.has(r); if (s) {
    if (a)
        return !1;
    if (o.add(r), s.dependencies) {
        let c = typeof s.dependencies == "function" ? s.dependencies() : s.dependencies;
        for (let l of c)
            er(l, t, n, o);
    }
}
else if (i) {
    if (i.imports != null && !a) {
        o.add(r);
        let l;
        hr(i.imports, u => { er(u, t, n, o) && (l ||= [], l.push(u)); }), l !== void 0 && eg(l, t);
    }
    if (!a) {
        let l = Ut(r) || (() => new r);
        t({ provide: r, useFactory: l, deps: F }, r), t({ provide: us, useValue: r, multi: !0 }, r), t({ provide: We, useValue: () => he(r), multi: !0 }, r);
    }
    let c = i.providers;
    if (c != null && !a) {
        let l = e;
        Dl(c, u => { t(u, l); });
    }
}
else
    return !1; return r !== e && e.providers !== void 0; }
function Dl(e, t) { for (let n of e)
    hl(n) && (n = n.\u0275providers), Array.isArray(n) ? Dl(n, t) : t(n); }
var Hw = V({ provide: String, useValue: V });
function tg(e) { return e !== null && typeof e == "object" && Hw in e; }
function Bw(e) { return !!(e && e.useExisting); }
function $w(e) { return !!(e && e.useFactory); }
function fn(e) { return typeof e == "function"; }
function ng(e) { return !!e.useClass; }
var Tl = new C(""), Yi = {}, Gh = {}, el;
function Jn() { return el === void 0 && (el = new Ct), el; }
var be = class {
}, et = class extends be {
    parent;
    source;
    scopes;
    records = new Map;
    _ngOnDestroyHooks = new Set;
    _onDestroyHooks = [];
    get destroyed() { return this._destroyed; }
    _destroyed = !1;
    injectorDefTypes;
    constructor(t, n, o, r) { super(), this.parent = n, this.source = o, this.scopes = r, sl(t, s => this.processProvider(s)), this.records.set(yr, Qn(void 0, this)), r.has("environment") && this.records.set(be, Qn(void 0, this)); let i = this.records.get(Tl); i != null && typeof i.value == "string" && this.scopes.add(i.value), this.injectorDefTypes = new Set(this.get(us, F, { self: !0 })); }
    retrieve(t, n) { let o = dn(n) || 0; try {
        return this.get(t, un, o);
    }
    catch (r) {
        if (Ew(r))
            return r;
        throw r;
    } }
    destroy() { Ko(this), this._destroyed = !0; let t = zn(null); try {
        for (let o of this._ngOnDestroyHooks)
            o.ngOnDestroy();
        let n = this._onDestroyHooks;
        this._onDestroyHooks = [];
        for (let o of n)
            o();
    }
    finally {
        this.records.clear(), this._ngOnDestroyHooks.clear(), this.injectorDefTypes.clear(), zn(t);
    } }
    onDestroy(t) { return Ko(this), this._onDestroyHooks.push(t), () => this.removeOnDestroy(t); }
    runInContext(t) { Ko(this); let n = ct(this), o = Te(void 0), r; try {
        return t();
    }
    finally {
        ct(n), Te(o);
    } }
    get(t, n = un, o) { if (Ko(this), t.hasOwnProperty(qh))
        return t[qh](this); let r = dn(o), i, s = ct(this), a = Te(void 0); try {
        if (!(r & 4)) {
            let l = this.records.get(t);
            if (l === void 0) {
                let u = zw(t) && ur(t);
                u && this.injectableDefInScope(u) ? l = Qn(il(t), Yi) : l = null, this.records.set(t, l);
            }
            if (l != null)
                return this.hydrate(t, l, r);
        }
        let c = r & 2 ? Jn() : this.parent;
        return n = r & 8 && n === un ? null : n, c.get(t, n);
    }
    catch (c) {
        let l = Ow(c);
        throw l === -200 || l === -201 ? new D(l, null) : c;
    }
    finally {
        Te(a), ct(s);
    } }
    resolveInjectorInitializers() { let t = zn(null), n = ct(this), o = Te(void 0), r; try {
        let i = this.get(We, F, { self: !0 });
        for (let s of i)
            s();
    }
    finally {
        ct(n), Te(o), zn(t);
    } }
    toString() { return "R3Injector[...]"; }
    processProvider(t) { t = P(t); let n = fn(t) ? t : P(t && t.provide), o = qw(t); if (!fn(t) && t.multi === !0) {
        let r = this.records.get(n);
        r || (r = Qn(void 0, Yi, !0), r.factory = () => rl(r.multi), this.records.set(n, r)), n = t, r.multi.push(t);
    } this.records.set(n, o); }
    hydrate(t, n, o) { let r = zn(null); try {
        if (n.value === Gh)
            throw gl("");
        return n.value === Yi && (n.value = Gh, n.value = n.factory(void 0, o)), typeof n.value == "object" && n.value && Ww(n.value) && this._ngOnDestroyHooks.add(n.value), n.value;
    }
    finally {
        zn(r);
    } }
    injectableDefInScope(t) { if (!t.providedIn)
        return !1; let n = P(t.providedIn); return typeof n == "string" ? n === "any" || this.scopes.has(n) : this.injectorDefTypes.has(n); }
    removeOnDestroy(t) { let n = this._onDestroyHooks.indexOf(t); n !== -1 && this._onDestroyHooks.splice(n, 1); }
};
function il(e) { let t = ur(e), n = t !== null ? t.factory : Ut(e); if (n !== null)
    return n; if (e instanceof C)
    throw new D(-204, !1); if (e instanceof Function)
    return Uw(e); throw new D(-204, !1); }
function Uw(e) { if (e.length > 0)
    throw new D(-204, !1); let n = Aw(e); return n !== null ? () => n.factory(e) : () => new e; }
function qw(e) { if (tg(e))
    return Qn(void 0, e.useValue); {
    let t = Cl(e);
    return Qn(t, Yi);
} }
function Cl(e, t, n) { let o; if (fn(e)) {
    let r = P(e);
    return Ut(r) || il(r);
}
else if (tg(e))
    o = () => P(e.useValue);
else if ($w(e))
    o = () => e.useFactory(...rl(e.deps || []));
else if (Bw(e))
    o = (r, i) => he(P(e.useExisting), i !== void 0 && i & 8 ? 8 : void 0);
else {
    let r = P(e && (e.useClass || e.provide));
    if (Gw(e))
        o = () => new r(...rl(e.deps));
    else
        return Ut(r) || il(r);
} return o; }
function Ko(e) { if (e.destroyed)
    throw new D(-205, !1); }
function Qn(e, t, n = !1) { return { factory: e, value: t, multi: n ? [] : void 0 }; }
function Gw(e) { return !!e.deps; }
function Ww(e) { return e !== null && typeof e == "object" && typeof e.ngOnDestroy == "function"; }
function zw(e) { return typeof e == "function" || typeof e == "object" && e.ngMetadataName === "InjectionToken"; }
function sl(e, t) { for (let n of e)
    Array.isArray(n) ? sl(n, t) : n && hl(n) ? sl(n.\u0275providers, t) : t(n); }
function Er(e, t) { let n; e instanceof et ? (Ko(e), n = e) : n = new ol(e); let o, r = ct(n), i = Te(void 0); try {
    return t();
}
finally {
    ct(r), Te(i);
} }
function fs() { return Kh() !== void 0 || Kc() != null; }
function Qw(e) { if (!fs())
    throw new D(-203, !1); }
var B = 0, m = 1, w = 2, z = 3, ge = 4, ce = 5, fe = 6, zt = 7, j = 8, k = 9, ze = 10, N = 11, Qt = 12, Ir = 13, Zt = 14, re = 15, Yt = 16, gn = 17, lt = 18, Fe = 19, Ml = 20, Tt = 21, ps = 22, qt = 23, Ae = 24, mn = 25, Qe = 26, I = 27, wl = 1, je = 6, ot = 7, Dr = 8, vn = 9, U = 10;
function J(e) { return Array.isArray(e) && typeof e[wl] == "object"; }
function K(e) { return Array.isArray(e) && e[wl] === !0; }
function Nl(e) { return (e.flags & 4) !== 0; }
function Ce(e) { return e.componentOffset > -1; }
function Xn(e) { return (e.flags & 1) === 1; }
function Ze(e) { return !!e.template; }
function rt(e) { return (e[w] & 512) !== 0; }
function _l(e) { return (e.type & 16) === 16; }
function og(e) { return (e[w] & 32) === 32; }
function ut(e) { return (e[w] & 256) === 256; }
function rg(e, t) { Zw(e, t[m]); }
function Zw(e, t) { Sl(e); let n = t.data; for (let o = I; o < n.length; o++)
    if (n[o] === e)
        return; Gt("This TNode does not belong to this TView."); }
function Sl(e) { pl(e, "TNode must be defined"), e && typeof e == "object" && e.hasOwnProperty("directiveStylingLast") || Gt("Not of type TNode, got: " + e); }
function ig(e) { pl(e, "LView must be defined"), fl(J(e), !0, "Expecting LView"); }
var bl = "svg", Al = "math";
function O(e) { for (; Array.isArray(e);)
    e = e[B]; return e; }
function Tr(e) { for (; Array.isArray(e);) {
    if (typeof e[wl] == "object")
        return e;
    e = e[B];
} return null; }
function yn(e, t) { return O(t[e]); }
function ie(e, t) { return O(t[e.index]); }
function sg(e, t) { let n = e === null ? -1 : e.index; return n !== -1 ? O(t[n]) : null; }
function Kt(e, t) { return e.data[t]; }
function Jt(e, t) { return e[t]; }
function Cr(e, t, n, o) { n >= e.data.length && (e.data[n] = null, e.blueprint[n] = null), t[n] = o; }
function me(e, t) { let n = t[e]; return J(n) ? n : n[B]; }
function ag(e) { return (e[w] & 4) === 4; }
function hs(e) { return (e[w] & 128) === 128; }
function cg(e) { return K(e[z]); }
function ve(e, t) { return t == null ? null : e[t]; }
function Rl(e) { e[gn] = 0; }
function Mr(e) { e[w] & 1024 || (e[w] |= 1024, hs(e) && En(e)); }
function xl(e, t) { for (; e > 0;)
    t = t[Zt], e--; return t; }
function eo(e) { return !!(e[w] & 9216 || e[Ae]?.dirty); }
function gs(e) { e[ze].changeDetectionScheduler?.notify(8), e[w] & 64 && (e[w] |= 1024), eo(e) && En(e); }
function En(e) { e[ze].changeDetectionScheduler?.notify(0); let t = Ue(e); for (; t !== null && !(t[w] & 8192 || (t[w] |= 8192, !hs(t)));)
    t = Ue(t); }
function to(e, t) { if (ut(e))
    throw new D(911, !1); e[Tt] === null && (e[Tt] = []), e[Tt].push(t); }
function ms(e, t) { if (e[Tt] === null)
    return; let n = e[Tt].indexOf(t); n !== -1 && e[Tt].splice(n, 1); }
function Ue(e) { let t = e[z]; return K(t) ? t[z] : t; }
function kl(e) { return e[zt] ??= []; }
function Ol(e) { return e.cleanup ??= []; }
function lg(e, t, n, o) { let r = kl(t); r.push(n), e.firstCreatePass && Ol(e).push(o, r.length - 1); }
var S = { lFrame: vg(null), bindingsEnabled: !0, skipHydrationRootTNode: null };
var al = !1;
function ug() { return S.lFrame.elementDepthCount; }
function dg() { S.lFrame.elementDepthCount++; }
function Ll() { S.lFrame.elementDepthCount--; }
function vs() { return S.bindingsEnabled; }
function wr() { return S.skipHydrationRootTNode !== null; }
function Pl(e) { return S.skipHydrationRootTNode === e; }
function Fl() { S.bindingsEnabled = !0; }
function fg(e) { S.skipHydrationRootTNode = e; }
function jl() { S.bindingsEnabled = !1; }
function Vl() { S.skipHydrationRootTNode = null; }
function g() { return S.lFrame.lView; }
function A() { return S.lFrame.tView; }
function Hl(e) { return S.lFrame.contextLView = e, e[j]; }
function Bl(e) { return S.lFrame.contextLView = null, e; }
function _() { let e = $l(); for (; e !== null && e.type === 64;)
    e = e.parent; return e; }
function $l() { return S.lFrame.currentTNode; }
function no() { let e = S.lFrame, t = e.currentTNode; return e.isParent ? t : t.parent; }
function dt(e, t) { let n = S.lFrame; n.currentTNode = e, n.isParent = t; }
function Ul() { return S.lFrame.isParent; }
function ql() { S.lFrame.isParent = !1; }
function Gl() { return S.lFrame.contextLView; }
function Wl() { return al; }
function tr(e) { let t = al; return al = e, t; }
function ye() { let e = S.lFrame, t = e.bindingRootIndex; return t === -1 && (t = e.bindingRootIndex = e.tView.bindingStartIndex), t; }
function ft() { return S.lFrame.bindingIndex; }
function zl(e) { return S.lFrame.bindingIndex = e; }
function De() { return S.lFrame.bindingIndex++; }
function pt(e) { let t = S.lFrame, n = t.bindingIndex; return t.bindingIndex = t.bindingIndex + e, n; }
function pg() { return S.lFrame.inI18n; }
function Ql(e) { S.lFrame.inI18n = e; }
function hg(e, t) { let n = S.lFrame; n.bindingIndex = n.bindingRootIndex = e, ys(t); }
function gg() { return S.lFrame.currentDirectiveIndex; }
function ys(e) { S.lFrame.currentDirectiveIndex = e; }
function Es(e) { let t = S.lFrame.currentDirectiveIndex; return t === -1 ? null : e[t]; }
function Is() { return S.lFrame.currentQueryIndex; }
function Nr(e) { S.lFrame.currentQueryIndex = e; }
function Yw(e) { let t = e[m]; return t.type === 2 ? t.declTNode : t.type === 1 ? e[ce] : null; }
function Zl(e, t, n) { if (n & 4) {
    let r = t, i = e;
    for (; r = r.parent, r === null && !(n & 1);)
        if (r = Yw(i), r === null || (i = i[Zt], r.type & 10))
            break;
    if (r === null)
        return !1;
    t = r, e = i;
} let o = S.lFrame = mg(); return o.currentTNode = t, o.lView = e, !0; }
function Ds(e) { let t = mg(), n = e[m]; S.lFrame = t, t.currentTNode = n.firstChild, t.lView = e, t.tView = n, t.contextLView = e, t.bindingIndex = n.bindingStartIndex, t.inI18n = !1; }
function mg() { let e = S.lFrame, t = e === null ? null : e.child; return t === null ? vg(e) : t; }
function vg(e) { let t = { currentTNode: null, isParent: !0, lView: null, tView: null, selectedIndex: -1, contextLView: null, elementDepthCount: 0, currentNamespace: null, currentDirectiveIndex: -1, bindingRootIndex: -1, bindingIndex: -1, currentQueryIndex: 0, parent: e, child: null, inI18n: !1 }; return e !== null && (e.child = t), t; }
function yg() { let e = S.lFrame; return S.lFrame = e.parent, e.currentTNode = null, e.lView = null, e; }
var Yl = yg;
function Ts() { let e = yg(); e.isParent = !0, e.tView = null, e.selectedIndex = -1, e.contextLView = null, e.elementDepthCount = 0, e.currentDirectiveIndex = -1, e.currentNamespace = null, e.bindingRootIndex = -1, e.bindingIndex = -1, e.currentQueryIndex = 0; }
function Eg(e) { return (S.lFrame.contextLView = xl(e, S.lFrame.contextLView))[j]; }
function le() { return S.lFrame.selectedIndex; }
function ht(e) { S.lFrame.selectedIndex = e; }
function Ve() { let e = S.lFrame; return Kt(e.tView, e.selectedIndex); }
function Kl() { S.lFrame.currentNamespace = bl; }
function Jl() { S.lFrame.currentNamespace = Al; }
function Xl() { Kw(); }
function Kw() { S.lFrame.currentNamespace = null; }
function Cs() { return S.lFrame.currentNamespace; }
var Ig = !0;
function _r() { return Ig; }
function it(e) { Ig = e; }
function oo() { let e, t; return { promise: new Promise((o, r) => { e = o, t = r; }), resolve: e, reject: t }; }
function cl(e, t = null, n = null, o) { let r = eu(e, t, n, o); return r.resolveInjectorInitializers(), r; }
function eu(e, t = null, n = null, o, r = new Set) { let i = [n || F, Xh(e)], s; return new et(i, t || Jn(), s || null, r); }
var Jw = new Set;
function Dg() { return Jw; }
var oe = class e {
    static THROW_IF_NOT_FOUND = un;
    static NULL = new Ct;
    static create(t, n) { if (Array.isArray(t))
        return cl({ name: "" }, n, t, ""); {
        let o = t.name ?? "";
        return cl({ name: o }, t.parent, t.providers, o);
    } }
    static \u0275prov = Y({ token: e, providedIn: "any", factory: () => he(yr) });
    static __NG_ELEMENT_ID__ = -1;
}, Nt = new C(""), Re = (() => { class e {
    static __NG_ELEMENT_ID__ = Xw;
    static __NG_ENV_ID__ = n => n;
} return e; })(), Xi = class extends Re {
    _lView;
    constructor(t) { super(), this._lView = t; }
    get destroyed() { return ut(this._lView); }
    onDestroy(t) { let n = this._lView; return to(n, t), () => ms(n, t); }
};
function Xw() { return new Xi(g()); }
var tu = !1, nu = new C(""), gt = (() => { class e {
    taskId = 0;
    pendingTasks = new Set;
    destroyed = !1;
    pendingTask = new Iw(!1);
    debugTaskTracker = E(nu, { optional: !0 });
    get hasPendingTasks() { return this.destroyed ? !1 : this.pendingTask.value; }
    get hasPendingTasksObservable() { return this.destroyed ? new Dw(n => { n.next(!1), n.complete(); }) : this.pendingTask; }
    add() { !this.hasPendingTasks && !this.destroyed && this.pendingTask.next(!0); let n = this.taskId++; return this.pendingTasks.add(n), this.debugTaskTracker?.add(n), n; }
    has(n) { return this.pendingTasks.has(n); }
    remove(n) { this.pendingTasks.delete(n), this.debugTaskTracker?.remove(n), this.pendingTasks.size === 0 && this.hasPendingTasks && this.pendingTask.next(!1); }
    ngOnDestroy() { this.pendingTasks.clear(), this.hasPendingTasks && this.pendingTask.next(!1), this.destroyed = !0, this.pendingTask.unsubscribe(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })(), ll = class extends Tw {
    __isAsync;
    destroyRef = void 0;
    pendingTasks = void 0;
    constructor(t = !1) { super(), this.__isAsync = t, fs() && (this.destroyRef = E(Re, { optional: !0 }) ?? void 0, this.pendingTasks = E(gt, { optional: !0 }) ?? void 0); }
    emit(t) { let n = x(null); try {
        super.next(t);
    }
    finally {
        x(n);
    } }
    subscribe(t, n, o) { let r = t, i = n || (() => null), s = o; if (t && typeof t == "object") {
        let c = t;
        r = c.next?.bind(c), i = c.error?.bind(c), s = c.complete?.bind(c);
    } this.__isAsync && (i = this.wrapInTimeout(i), r && (r = this.wrapInTimeout(r)), s && (s = this.wrapInTimeout(s))); let a = super.subscribe({ next: r, error: i, complete: s }); return t instanceof Cw && t.add(a), a; }
    wrapInTimeout(t) { return n => { let o = this.pendingTasks?.add(); setTimeout(() => { try {
        t(n);
    }
    finally {
        o !== void 0 && this.pendingTasks?.remove(o);
    } }); }; }
}, Dt = ll;
function es(...e) { }
function ou(e) { let t, n; function o() { e = es; try {
    n !== void 0 && typeof cancelAnimationFrame == "function" && cancelAnimationFrame(n), t !== void 0 && clearTimeout(t);
}
catch { } } return t = setTimeout(() => { e(), o(); }), typeof requestAnimationFrame == "function" && (n = requestAnimationFrame(() => { e(), o(); })), () => o(); }
function Tg(e) { return queueMicrotask(() => e()), () => { e = es; }; }
var ru = "isAngularZone", nr = ru + "_ID", eN = 0, G = class e {
    hasPendingMacrotasks = !1;
    hasPendingMicrotasks = !1;
    isStable = !0;
    onUnstable = new Dt(!1);
    onMicrotaskEmpty = new Dt(!1);
    onStable = new Dt(!1);
    onError = new Dt(!1);
    constructor(t) { let { enableLongStackTrace: n = !1, shouldCoalesceEventChangeDetection: o = !1, shouldCoalesceRunChangeDetection: r = !1, scheduleInRootZone: i = tu } = t; if (typeof Zone > "u")
        throw new D(908, !1); Zone.assertZonePatched(); let s = this; s._nesting = 0, s._outer = s._inner = Zone.current, Zone.TaskTrackingZoneSpec && (s._inner = s._inner.fork(new Zone.TaskTrackingZoneSpec)), n && Zone.longStackTraceZoneSpec && (s._inner = s._inner.fork(Zone.longStackTraceZoneSpec)), s.shouldCoalesceEventChangeDetection = !r && o, s.shouldCoalesceRunChangeDetection = r, s.callbackScheduled = !1, s.scheduleInRootZone = i, oN(s); }
    static isInAngularZone() { return typeof Zone < "u" && Zone.current.get(ru) === !0; }
    static assertInAngularZone() { if (!e.isInAngularZone())
        throw new D(909, !1); }
    static assertNotInAngularZone() { if (e.isInAngularZone())
        throw new D(909, !1); }
    run(t, n, o) { return this._inner.run(t, n, o); }
    runTask(t, n, o, r) { let i = this._inner, s = i.scheduleEventTask("NgZoneEvent: " + r, t, tN, es, es); try {
        return i.runTask(s, n, o);
    }
    finally {
        i.cancelTask(s);
    } }
    runGuarded(t, n, o) { return this._inner.runGuarded(t, n, o); }
    runOutsideAngular(t) { return this._outer.run(t); }
}, tN = {};
function iu(e) { if (e._nesting == 0 && !e.hasPendingMicrotasks && !e.isStable)
    try {
        e._nesting++, e.onMicrotaskEmpty.emit(null);
    }
    finally {
        if (e._nesting--, !e.hasPendingMicrotasks)
            try {
                e.runOutsideAngular(() => e.onStable.emit(null));
            }
            finally {
                e.isStable = !0;
            }
    } }
function nN(e) { if (e.isCheckStableRunning || e.callbackScheduled)
    return; e.callbackScheduled = !0; function t() { ou(() => { e.callbackScheduled = !1, ul(e), e.isCheckStableRunning = !0, iu(e), e.isCheckStableRunning = !1; }); } e.scheduleInRootZone ? Zone.root.run(() => { t(); }) : e._outer.run(() => { t(); }), ul(e); }
function oN(e) { let t = () => { nN(e); }, n = eN++; e._inner = e._inner.fork({ name: "angular", properties: { [ru]: !0, [nr]: n, [nr + n]: !0 }, onInvokeTask: (o, r, i, s, a, c) => { if (rN(c))
        return o.invokeTask(i, s, a, c); try {
        return Wh(e), o.invokeTask(i, s, a, c);
    }
    finally {
        (e.shouldCoalesceEventChangeDetection && s.type === "eventTask" || e.shouldCoalesceRunChangeDetection) && t(), zh(e);
    } }, onInvoke: (o, r, i, s, a, c, l) => { try {
        return Wh(e), o.invoke(i, s, a, c, l);
    }
    finally {
        e.shouldCoalesceRunChangeDetection && !e.callbackScheduled && !iN(c) && t(), zh(e);
    } }, onHasTask: (o, r, i, s) => { o.hasTask(i, s), r === i && (s.change == "microTask" ? (e._hasPendingMicrotasks = s.microTask, ul(e), iu(e)) : s.change == "macroTask" && (e.hasPendingMacrotasks = s.macroTask)); }, onHandleError: (o, r, i, s) => (o.handleError(i, s), e.runOutsideAngular(() => e.onError.emit(s)), !1) }); }
function ul(e) { e._hasPendingMicrotasks || (e.shouldCoalesceEventChangeDetection || e.shouldCoalesceRunChangeDetection) && e.callbackScheduled === !0 ? e.hasPendingMicrotasks = !0 : e.hasPendingMicrotasks = !1; }
function Wh(e) { e._nesting++, e.isStable && (e.isStable = !1, e.onUnstable.emit(null)); }
function zh(e) { e._nesting--, iu(e); }
var or = class {
    hasPendingMicrotasks = !1;
    hasPendingMacrotasks = !1;
    isStable = !0;
    onUnstable = new Dt;
    onMicrotaskEmpty = new Dt;
    onStable = new Dt;
    onError = new Dt;
    run(t, n, o) { return t.apply(n, o); }
    runGuarded(t, n, o) { return t.apply(n, o); }
    runOutsideAngular(t) { return t(); }
    runTask(t, n, o, r) { return t.apply(n, o); }
};
function rN(e) { return Cg(e, "__ignore_ng_zone__"); }
function iN(e) { return Cg(e, "__scheduler_tick__"); }
function Cg(e, t) { return !Array.isArray(e) || e.length !== 1 ? !1 : e[0]?.data?.[t] === !0; }
var Mt = class {
    _console = console;
    handleError(t) { this._console.error("ERROR", t); }
}, _t = new C("", { factory: () => { let e = E(G), t = E(be), n; return o => { e.runOutsideAngular(() => { t.destroyed && !n ? setTimeout(() => { throw o; }) : (n ??= t.get(Mt), n.handleError(o)); }); }; } }), su = { provide: We, useValue: () => { let e = E(Mt, { optional: !0 }); }, multi: !0 }, sN = new C("", { factory: () => { if (typeof ngServerMode < "u" && ngServerMode)
        return; let e = E(Nt).defaultView; if (!e)
        return; let t = E(_t), n = i => { t(i.reason), i.preventDefault(); }, o = i => { i.error ? t(i.error) : t(new Error(i.message, { cause: i })), i.preventDefault(); }, r = () => { e.addEventListener("unhandledrejection", n), e.addEventListener("error", o); }; typeof Zone < "u" ? Zone.root.run(r) : r(), E(Re).onDestroy(() => { e.removeEventListener("error", o), e.removeEventListener("unhandledrejection", n); }); } });
function aN() { return Pe([Il(() => { E(sN); })]); }
function cN(e) { return null; }
function mt(e, t) { let [n, o, r] = Fh(e, t?.equal), i = n, s = i[ae]; return i.set = o, i.update = r, i.asReadonly = ro.bind(i), i; }
function ro() { let e = this[ae]; if (e.readonlyFn === void 0) {
    let t = () => this();
    t[ae] = e, e.readonlyFn = t;
} return e.readonlyFn; }
var vt = new C("", { factory: () => lN }), lN = "ng";
var au = new C(""), uN = new C("", { providedIn: "platform", factory: () => "unknown" }), dN = new C(""), fN = new C("", { factory: () => E(Nt).body?.querySelector("[ngCspNonce]")?.getAttribute("ngCspNonce") || null }), Mg = { breakpoints: [16, 32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, 3840], placeholderResolution: 30, disableImageSizeWarning: !1, disableImageLazyLoadWarning: !1 }, pN = new C("", { factory: () => Mg });
function wg(e) { return e; }
var St = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => { let n = new e; return (typeof ngServerMode > "u" || !ngServerMode) && (n.store = cu(E(Nt), E(vt))), n; } });
    store = {};
    onSerializeCallbacks = {};
    get(n, o) { return this.store[n] !== void 0 ? this.store[n] : o; }
    set(n, o) { this.store[n] = o; }
    remove(n) { delete this.store[n]; }
    hasKey(n) { return this.store.hasOwnProperty(n); }
    get isEmpty() { return Object.keys(this.store).length === 0; }
    onSerialize(n, o) { this.onSerializeCallbacks[n] = o; }
    toJson() { for (let n in this.onSerializeCallbacks)
        if (this.onSerializeCallbacks.hasOwnProperty(n))
            try {
                this.store[n] = this.onSerializeCallbacks[n]();
            }
            catch (o) {
                console.warn("Exception in onSerialize callback: ", o);
            } return JSON.stringify(this.store).replace(/</g, "\\u003C").replace(/\//g, "\\u002F"); }
} return e; })();
function cu(e, t) { let n = e.getElementById(t + "-state"); if (n?.tagName === "SCRIPT" && n.textContent)
    try {
        return JSON.parse(n.textContent);
    }
    catch (o) {
        console.warn("Exception while restoring TransferState for app " + t, o);
    } return {}; }
function hN(e, t) { if (Gi() !== null)
    throw new D(-602, !1); }
var io = (() => { class e {
    view;
    node;
    constructor(n, o) { this.view = n, this.node = o; }
    static __NG_ELEMENT_ID__ = gN;
} return e; })();
function gN() { return new io(g(), _()); }
var qe = class {
}, so = new C("", { factory: () => !0 }), mN = new C("", { factory: () => !1 }), Ms = new C(""), ws = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new dl });
} return e; })(), dl = class {
    dirtyEffectCount = 0;
    queues = new Map;
    add(t) { this.enqueue(t), this.schedule(t); }
    schedule(t) { t.dirty && this.dirtyEffectCount++; }
    remove(t) { let n = t.zone, o = this.queues.get(n); o.has(t) && (o.delete(t), t.dirty && this.dirtyEffectCount--); }
    enqueue(t) { let n = t.zone; this.queues.has(n) || this.queues.set(n, new Set); let o = this.queues.get(n); o.has(t) || o.add(t); }
    flush() { for (; this.dirtyEffectCount > 0;) {
        let t = !1;
        for (let [n, o] of this.queues)
            n === null ? t ||= this.flushQueue(o) : t ||= n.run(() => this.flushQueue(o));
        t || (this.dirtyEffectCount = 0);
    } }
    flushQueue(t) { let n = !1; for (let o of t)
        o.dirty && (this.dirtyEffectCount--, n = !0, o.run()); return n; }
}, rr = class {
    [ae];
    constructor(t) { this[ae] = t; }
    destroy() { this[ae].destroy(); }
};
function Ns(e, t) { let n = t?.injector ?? E(oe), o = t?.manualCleanup !== !0 ? n.get(Re) : null, r, i = n.get(io, null, { optional: !0 }), s = n.get(qe); return i !== null ? (r = EN(i.view, s, e), o instanceof Xi && o._lView === i.view && (o = null)) : r = IN(e, n.get(ws), s), r.injector = n, o !== null && (r.onDestroyFns = [o.onDestroy(() => r.destroy())]), new rr(r); }
var Ng = Ie(q({}, jh), { cleanupFns: void 0, zone: null, onDestroyFns: null, run() { let e = tr(!1); try {
        Vh(this);
    }
    finally {
        tr(e);
    } }, cleanup() { if (!this.cleanupFns?.length)
        return; let e = x(null); try {
        for (; this.cleanupFns.length;)
            this.cleanupFns.pop()();
    }
    finally {
        this.cleanupFns = [], x(e);
    } } }), vN = Ie(q({}, Ng), { consumerMarkedDirty() { this.scheduler.schedule(this), this.notifier.notify(12); }, destroy() { if ($t(this), this.onDestroyFns !== null)
        for (let e of this.onDestroyFns)
            e(); this.cleanup(), this.scheduler.remove(this); } }), yN = Ie(q({}, Ng), { consumerMarkedDirty() { this.view[w] |= 8192, En(this.view), this.notifier.notify(13); }, destroy() { if ($t(this), this.onDestroyFns !== null)
        for (let e of this.onDestroyFns)
            e(); this.cleanup(), this.view[qt]?.delete(this); } });
function EN(e, t, n) { let o = Object.create(yN); return o.view = e, o.zone = typeof Zone < "u" ? Zone.current : null, o.notifier = t, o.fn = _g(o, n), e[qt] ??= new Set, e[qt].add(o), o.consumerMarkedDirty(o), o; }
function IN(e, t, n) { let o = Object.create(vN); return o.fn = _g(o, e), o.scheduler = t, o.notifier = n, o.zone = typeof Zone < "u" ? Zone.current : null, o.scheduler.add(o), o.notifier.notify(12), o; }
function _g(e, t) { return () => { t(n => (e.cleanupFns ??= []).push(n)); }; }
function ao(e) { return typeof e == "function" && e[ae] !== void 0; }
function _s(e) { return ao(e) && typeof e.set == "function"; }
var Sr = (() => { class e {
    internalPendingTasks = E(gt);
    scheduler = E(qe);
    errorHandler = E(_t);
    add() { let n = this.internalPendingTasks.add(); return () => { this.internalPendingTasks.has(n) && (this.scheduler.notify(11), this.internalPendingTasks.remove(n)); }; }
    run(n) { let o = this.add(); try {
        n().catch(this.errorHandler).finally(o);
    }
    catch (r) {
        this.errorHandler(r), o();
    } }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })();
import { setActiveConsumer as uo } from "@angular/core/primitives/signals";
import { Subject as Km, Subscription as DN } from "rxjs";
import { map as TN } from "rxjs/operators";
var co = { JSACTION: "jsaction" };
function Et(e) { return { toString: e }.toString(); }
var Zs = class {
    previousValue;
    currentValue;
    firstChange;
    constructor(t, n, o) { this.previousValue = t, this.currentValue = n, this.firstChange = o; }
    isFirstChange() { return this.firstChange; }
};
function Jm(e, t, n, o) { t !== null ? t.applyValueToInputSignal(t, o) : e[n] = o; }
var Xm = (() => { let e = () => ev; return e.ngInherit = !0, e; })();
function ev(e) { return e.type.prototype.ngOnChanges && (e.setInput = MN), CN; }
function CN() { let e = tv(this), t = e?.current; if (t) {
    let n = e.previous;
    if (n === wt)
        e.previous = t;
    else
        for (let o in t)
            n[o] = t[o];
    e.current = null, this.ngOnChanges(t);
} }
function MN(e, t, n, o, r) { let i = this.declaredInputs[o], s = tv(e) || wN(e, { previous: wt, current: null }), a = s.current || (s.current = {}), c = s.previous, l = c[i]; a[i] = new Zs(l && l.currentValue, n, c === wt), Jm(e, t, r, n); }
var ku = "__ngSimpleChanges__";
function tv(e) { return Object.hasOwn(e, ku) && e[ku] || null; }
function wN(e, t) { return e[ku] = t; }
var Sg = [];
var H = function (e, t = null, n) { for (let o = 0; o < Sg.length; o++) {
    let r = Sg[o];
    r(e, t, n);
} }, L = (function (e) { return e[e.TemplateCreateStart = 0] = "TemplateCreateStart", e[e.TemplateCreateEnd = 1] = "TemplateCreateEnd", e[e.TemplateUpdateStart = 2] = "TemplateUpdateStart", e[e.TemplateUpdateEnd = 3] = "TemplateUpdateEnd", e[e.LifecycleHookStart = 4] = "LifecycleHookStart", e[e.LifecycleHookEnd = 5] = "LifecycleHookEnd", e[e.OutputStart = 6] = "OutputStart", e[e.OutputEnd = 7] = "OutputEnd", e[e.BootstrapApplicationStart = 8] = "BootstrapApplicationStart", e[e.BootstrapApplicationEnd = 9] = "BootstrapApplicationEnd", e[e.BootstrapComponentStart = 10] = "BootstrapComponentStart", e[e.BootstrapComponentEnd = 11] = "BootstrapComponentEnd", e[e.ChangeDetectionStart = 12] = "ChangeDetectionStart", e[e.ChangeDetectionEnd = 13] = "ChangeDetectionEnd", e[e.ChangeDetectionSyncStart = 14] = "ChangeDetectionSyncStart", e[e.ChangeDetectionSyncEnd = 15] = "ChangeDetectionSyncEnd", e[e.AfterRenderHooksStart = 16] = "AfterRenderHooksStart", e[e.AfterRenderHooksEnd = 17] = "AfterRenderHooksEnd", e[e.ComponentStart = 18] = "ComponentStart", e[e.ComponentEnd = 19] = "ComponentEnd", e[e.DeferBlockStateStart = 20] = "DeferBlockStateStart", e[e.DeferBlockStateEnd = 21] = "DeferBlockStateEnd", e[e.DynamicComponentStart = 22] = "DynamicComponentStart", e[e.DynamicComponentEnd = 23] = "DynamicComponentEnd", e[e.HostBindingsUpdateStart = 24] = "HostBindingsUpdateStart", e[e.HostBindingsUpdateEnd = 25] = "HostBindingsUpdateEnd", e; })(L || {});
function NN(e, t, n) { let { ngOnChanges: o, ngOnInit: r, ngDoCheck: i } = t.type.prototype; if (o) {
    let s = ev(t);
    (n.preOrderHooks ??= []).push(e, s), (n.preOrderCheckHooks ??= []).push(e, s);
} r && (n.preOrderHooks ??= []).push(0 - e, r), i && ((n.preOrderHooks ??= []).push(e, i), (n.preOrderCheckHooks ??= []).push(e, i)); }
function nv(e, t) { for (let n = t.directiveStart, o = t.directiveEnd; n < o; n++) {
    let i = e.data[n].type.prototype, { ngAfterContentInit: s, ngAfterContentChecked: a, ngAfterViewInit: c, ngAfterViewChecked: l, ngOnDestroy: u } = i;
    s && (e.contentHooks ??= []).push(-n, s), a && ((e.contentHooks ??= []).push(n, a), (e.contentCheckHooks ??= []).push(n, a)), c && (e.viewHooks ??= []).push(-n, c), l && ((e.viewHooks ??= []).push(n, l), (e.viewCheckHooks ??= []).push(n, l)), u != null && (e.destroyHooks ??= []).push(n, u);
} }
function Hs(e, t, n) { ov(e, t, 3, n); }
function Bs(e, t, n, o) { (e[w] & 3) === n && ov(e, t, n, o); }
function lu(e, t) { let n = e[w]; (n & 3) === t && (n &= 16383, n += 1, e[w] = n); }
function ov(e, t, n, o) { let r = o !== void 0 ? e[gn] & 65535 : 0, i = o ?? -1, s = t.length - 1, a = 0; for (let c = r; c < s; c++)
    if (typeof t[c + 1] == "number") {
        if (a = t[c], o != null && a >= o)
            break;
    }
    else
        t[c] < 0 && (e[gn] += 65536), (a < i || i == -1) && (_N(e, n, t, c), e[gn] = (e[gn] & 4294901760) + c + 2), c++; }
function bg(e, t) { H(L.LifecycleHookStart, e, t); let n = x(null); try {
    t.call(e);
}
finally {
    x(n), H(L.LifecycleHookEnd, e, t);
} }
function _N(e, t, n, o) { let r = n[o] < 0, i = n[o + 1], s = r ? -n[o] : n[o], a = e[s]; r ? e[w] >> 14 < e[gn] >> 16 && (e[w] & 3) === t && (e[w] += 16384, bg(a, i)) : bg(a, i); }
var vo = -1, Nn = class {
    factory;
    name;
    injectImpl;
    resolving = !1;
    canSeeViewProviders;
    multi;
    componentProviders;
    index;
    providerFactory;
    constructor(t, n, o, r) { this.factory = t, this.name = r, this.canSeeViewProviders = n, this.injectImpl = o; }
};
function Ma(e) { return e != null && typeof e == "object" && (e.insertBeforeIndex === null || typeof e.insertBeforeIndex == "number" || Array.isArray(e.insertBeforeIndex)); }
function rv(e) { return !!(e.type & 128); }
function SN(e) { return (e.flags & 8) !== 0; }
function bN(e) { return (e.flags & 16) !== 0; }
function AN(e, t, n) { let o = 0; for (; o < n.length;) {
    let r = n[o];
    if (typeof r == "number") {
        if (r !== 0)
            break;
        o++;
        let i = n[o++], s = n[o++], a = n[o++];
        e.setAttribute(t, s, a, i);
    }
    else {
        let i = r, s = n[++o];
        RN(i) ? e.setProperty(t, i, s) : e.setAttribute(t, i, s), o++;
    }
} return o; }
function iv(e) { return e === 3 || e === 4 || e === 6; }
function RN(e) { return e.charCodeAt(0) === 64; }
function To(e, t) { if (!(t === null || t.length === 0))
    if (e === null || e.length === 0)
        e = t.slice();
    else {
        let n = -1;
        for (let o = 0; o < t.length; o++) {
            let r = t[o];
            typeof r == "number" ? n = r : n === 0 || (n === -1 || n === 2 ? Ag(e, n, r, null, t[++o]) : Ag(e, n, r, null, null));
        }
    } return e; }
function Ag(e, t, n, o, r) { let i = 0, s = e.length; if (t === -1)
    s = -1;
else
    for (; i < e.length;) {
        let a = e[i++];
        if (typeof a == "number") {
            if (a === t) {
                s = -1;
                break;
            }
            else if (a > t) {
                s = i - 1;
                break;
            }
        }
    } for (; i < e.length;) {
    let a = e[i];
    if (typeof a == "number")
        break;
    if (a === n) {
        r !== null && (e[i + 1] = r);
        return;
    }
    i++, r !== null && i++;
} s !== -1 && (e.splice(s, 0, t), i = s + 1), e.splice(i++, 0, n), r !== null && e.splice(i++, 0, r); }
function sv(e) { return e !== vo; }
function Ys(e) { return e & 32767; }
function xN(e) { return e >> 16; }
function Ks(e, t) { let n = xN(e), o = t; for (; n > 0;)
    o = o[Zt], n--; return o; }
var Ou = !0;
function Js(e) { let t = Ou; return Ou = e, t; }
var kN = 256, av = kN - 1, cv = 5, ON = 0, yt = {};
function LN(e, t, n) { let o; typeof n == "string" ? o = n.charCodeAt(0) || 0 : n.hasOwnProperty(hn) && (o = n[hn]), o == null && (o = n[hn] = ON++); let r = o & av, i = 1 << r; t.data[e + (r >> cv)] |= i; }
function Xs(e, t) { let n = lv(e, t); if (n !== -1)
    return n; let o = t[m]; o.firstCreatePass && (e.injectorIndex = t.length, uu(o.data, e), uu(t, null), uu(o.blueprint, null)); let r = Hd(e, t), i = e.injectorIndex; if (sv(r)) {
    let s = Ys(r), a = Ks(r, t), c = a[m].data;
    for (let l = 0; l < 8; l++)
        t[i + l] = a[s + l] | c[s + l];
} return t[i + 8] = r, i; }
function uu(e, t) { e.push(0, 0, 0, 0, 0, 0, 0, 0, t); }
function lv(e, t) { return e.injectorIndex === -1 || e.parent && e.parent.injectorIndex === e.injectorIndex || t[e.injectorIndex + 8] === null ? -1 : e.injectorIndex; }
function Hd(e, t) { if (e.parent && e.parent.injectorIndex !== -1)
    return e.parent.injectorIndex; let n = 0, o = null, r = t; for (; r !== null;) {
    if (o = gv(r), o === null)
        return vo;
    if (n++, r = r[Zt], o.injectorIndex !== -1)
        return o.injectorIndex | n << 16;
} return vo; }
function Lu(e, t, n) { LN(e, t, n); }
function PN(e, t) { if (t === "class")
    return e.classes; if (t === "style")
    return e.styles; let n = e.attrs; if (n) {
    let o = n.length, r = 0;
    for (; r < o;) {
        let i = n[r];
        if (iv(i))
            break;
        if (i === 0)
            r = r + 2;
        else if (typeof i == "number")
            for (r++; r < o && typeof n[r] == "string";)
                r++;
        else {
            if (i === t)
                return n[r + 1];
            r = r + 2;
        }
    }
} return null; }
function uv(e, t, n) { if (n & 8 || e !== void 0)
    return e; as(t, "NodeInjector"); }
function dv(e, t, n, o) { if (n & 8 && o === void 0 && (o = null), (n & 3) === 0) {
    let r = e[k], i = Te(void 0);
    try {
        return r ? r.get(t, o, n & 8) : ml(t, o, n & 8);
    }
    finally {
        Te(i);
    }
} return uv(o, t, n); }
function fv(e, t, n, o = 0, r) { if (e !== null) {
    if (t[w] & 2048 && !(o & 2)) {
        let s = HN(e, t, n, o, yt);
        if (s !== yt)
            return s;
    }
    let i = pv(e, t, n, o, yt);
    if (i !== yt)
        return i;
} return dv(t, n, o, r); }
function pv(e, t, n, o, r) { let i = jN(n); if (typeof i == "function") {
    if (!Zl(t, e, o))
        return o & 1 ? uv(r, n, o) : dv(t, n, o, r);
    try {
        let s;
        if (s = i(o), s == null && !(o & 8))
            as(n);
        else
            return s;
    }
    finally {
        Yl();
    }
}
else if (typeof i == "number") {
    let s = null, a = lv(e, t), c = vo, l = o & 1 ? t[re][ce] : null;
    for ((a === -1 || o & 4) && (c = a === -1 ? Hd(e, t) : t[a + 8], c === vo || !xg(o, !1) ? a = -1 : (s = t[m], a = Ys(c), t = Ks(c, t))); a !== -1;) {
        let u = t[m];
        if (Rg(i, a, u.data)) {
            let d = FN(a, t, n, s, o, l);
            if (d !== yt)
                return d;
        }
        c = t[a + 8], c !== vo && xg(o, t[m].data[a + 8] === l) && Rg(i, a, t) ? (s = u, a = Ys(c), t = Ks(c, t)) : a = -1;
    }
} return r; }
function FN(e, t, n, o, r, i) { let s = t[m], a = s.data[e + 8], c = o == null ? Ce(a) && Ou : o != s && (a.type & 3) !== 0, l = r & 1 && i === a, u = $s(a, s, n, c, l); return u !== null ? Wr(t, s, u, a, r) : yt; }
function $s(e, t, n, o, r) { let i = e.providerIndexes, s = t.data, a = i & 1048575, c = e.directiveStart, l = e.directiveEnd, u = i >> 20, d = o ? a : a + u, f = r ? a + u : l; for (let p = d; p < f; p++) {
    let h = s[p];
    if (p < c && n === h || p >= c && h.type === n)
        return p;
} if (r) {
    let p = s[c];
    if (p && Ze(p) && p.type === n)
        return c;
} return null; }
function Wr(e, t, n, o, r) { let i = e[n], s = t.data; if (i instanceof Nn) {
    let a = i;
    if (a.resolving)
        throw gl("");
    let c = Js(a.canSeeViewProviders);
    a.resolving = !0;
    let l = s[n].type || s[n], u, d = a.injectImpl ? Te(a.injectImpl) : null, f = Zl(e, o, 0);
    try {
        i = e[n] = a.factory(void 0, r, s, e, o), t.firstCreatePass && n >= o.directiveStart && NN(n, s[n], t);
    }
    finally {
        d !== null && Te(d), Js(c), a.resolving = !1, Yl();
    }
} return i; }
function jN(e) { if (typeof e == "string")
    return e.charCodeAt(0) || 0; let t = e.hasOwnProperty(hn) ? e[hn] : void 0; return typeof t == "number" ? t >= 0 ? t & av : VN : t; }
function Rg(e, t, n) { let o = 1 << e; return !!(n[t + (e >> cv)] & o); }
function xg(e, t) { return !(e & 2) && !(e & 1 && t); }
function Bd(e) { return e._lView; }
function pi(e) { return e._tNode; }
var Me = class {
    _tNode;
    _lView;
    constructor(t, n) { this._tNode = t, this._lView = n; }
    get(t, n, o) { return fv(this._tNode, this._lView, t, dn(o), n); }
};
function VN() { return new Me(_(), g()); }
function hv(e) { return Et(() => { let t = e.prototype.constructor, n = t[$e] || Pu(t), o = Object.prototype, r = Object.getPrototypeOf(e.prototype).constructor; for (; r && r !== o;) {
    let i = r[$e] || Pu(r);
    if (i && i !== n)
        return i;
    r = Object.getPrototypeOf(r);
} return i => new i; }); }
function Pu(e) { return cr(e) ? () => { let t = Pu(P(e)); return t && t(); } : Ut(e); }
function HN(e, t, n, o, r) { let i = e, s = t; for (; i !== null && s !== null && s[w] & 2048 && !rt(s);) {
    let a = pv(i, s, n, o | 2, yt);
    if (a !== yt)
        return a;
    let c = i.parent;
    if (!c) {
        let l = s[Ml];
        if (l) {
            let u = l.get(n, yt, o & -5);
            if (u !== yt)
                return u;
        }
        c = gv(s), s = s[Zt];
    }
    i = c;
} return r; }
function gv(e) { let t = e[m], n = t.type; return n === 2 ? t.declTNode : n === 1 ? e[ce] : null; }
function wa(e) { return PN(_(), e); }
var BN = () => (typeof requestIdleCallback < "u" ? requestIdleCallback : e => setTimeout(e)).bind(globalThis), $N = () => (typeof requestIdleCallback < "u" ? cancelIdleCallback : clearTimeout).bind(globalThis), Na = new C("", { factory: () => new Fu });
function UN(e) { return Pe([{ provide: Na, useExisting: e }]); }
var Fu = class {
    requestIdleCallback = BN();
    cancelIdleCallback = $N();
    requestOnIdle(t, n) { return this.requestIdleCallback(t, n); }
    cancelOnIdle(t) { return this.cancelIdleCallback(t); }
}, fo = "__annotations__", po = "__parameters__", ho = "__prop__metadata__";
function Ao(e, t, n, o, r) { return Et(() => { let i = $d(t); function s(...a) { if (this instanceof s)
    return i.call(this, ...a), this; let c = new s(...a); return function (u) { return r && r(u, ...a), (u.hasOwnProperty(fo) ? u[fo] : Object.defineProperty(u, fo, { value: [] })[fo]).push(c), u; }; } return n && (s.prototype = Object.create(n.prototype)), s.prototype.ngMetadataName = e, s.annotationCls = s, s; }); }
function $d(e) { return function (...n) { if (e) {
    let o = e(...n);
    for (let r in o)
        this[r] = o[r];
} }; }
function Ro(e, t, n) { return Et(() => { let o = $d(t); function r(...i) { if (this instanceof r)
    return o.apply(this, i), this; let s = new r(...i); return a.annotation = s, a; function a(c, l, u) { let d = c.hasOwnProperty(po) ? c[po] : Object.defineProperty(c, po, { value: [] })[po]; for (; d.length <= u;)
    d.push(null); return (d[u] = d[u] || []).push(s), c; } } return r.prototype.ngMetadataName = e, r.annotationCls = r, r; }); }
function Ot(e, t, n, o) { return Et(() => { let r = $d(t); function i(...s) { if (this instanceof i)
    return r.apply(this, s), this; let a = new i(...s); function c(l, u) { if (l === void 0)
    throw new Error("Standard Angular field decorators are not supported in JIT mode."); let d = l.constructor, f = d.hasOwnProperty(ho) ? d[ho] : Object.defineProperty(d, ho, { value: {} })[ho]; f[u] = f.hasOwnProperty(u) && f[u] || [], f[u].unshift(a); } return c; } return n && (i.prototype = Object.create(n.prototype)), i.prototype.ngMetadataName = e, i.annotationCls = i, i; }); }
function ee(e) { let t = Le.ng; if (t && t.\u0275compilerFacade)
    return t.\u0275compilerFacade; throw new Error("JIT compiler unavailable"); }
function Lt(e) { return { token: e.token, providedIn: e.autoProvided === !1 ? null : "root", factory: e.factory, value: void 0 }; }
var ea = { \u0275\u0275defineInjectable: Y, \u0275\u0275defineInjector: lr, \u0275\u0275defineService: Lt, \u0275\u0275inject: he, \u0275\u0275invalidFactoryDep: cs, resolveForwardRef: P }, mv = Function;
function Ss(e) { return typeof e == "function"; }
var qN = /^function\s+\S+\(\)\s*{[\s\S]+\.apply\(this,\s*(arguments|(?:[^()]+\(\[\],)?[^()]+\(arguments\).*)\)/, GN = /^class\s+[A-Za-z\d$_]*\s*extends\s+[^{]+{/, WN = /^class\s+[A-Za-z\d$_]*\s*extends\s+[^{]+{[\s\S]*constructor\s*\(/, zN = /^class\s+[A-Za-z\d$_]*\s*extends\s+[^{]+{[\s\S]*constructor\s*\(\)\s*{[^}]*super\(\.\.\.arguments\)/;
function QN(e) { return qN.test(e) || zN.test(e) || GN.test(e) && !WN.test(e); }
var ta = class {
    _reflect;
    constructor(t) { this._reflect = t || Le.Reflect; }
    factory(t) { return (...n) => new t(...n); }
    _zipTypesAndAnnotations(t, n) { let o; typeof t > "u" ? o = mr(n.length) : o = mr(t.length); for (let r = 0; r < o.length; r++)
        typeof t > "u" ? o[r] = [] : t[r] && t[r] != Object ? o[r] = [t[r]] : o[r] = [], n && n[r] != null && (o[r] = o[r].concat(n[r])); return o; }
    _ownParameters(t, n) { let o = t.toString(); if (QN(o))
        return null; if (t.parameters && t.parameters !== n.parameters)
        return t.parameters; let r = t.ctorParameters; if (r && r !== n.ctorParameters) {
        let a = typeof r == "function" ? r() : r, c = a.map(u => u && u.type), l = a.map(u => u && du(u.decorators));
        return this._zipTypesAndAnnotations(c, l);
    } let i = t.hasOwnProperty(po) && t[po], s = this._reflect && this._reflect.getOwnMetadata && this._reflect.getOwnMetadata("design:paramtypes", t); return s || i ? this._zipTypesAndAnnotations(s, i) : mr(t.length); }
    parameters(t) { if (!Ss(t))
        return []; let n = bs(t), o = this._ownParameters(t, n); return !o && n !== Object && (o = this.parameters(n)), o || []; }
    _ownAnnotations(t, n) { if (t.annotations && t.annotations !== n.annotations) {
        let o = t.annotations;
        return typeof o == "function" && o.annotations && (o = o.annotations), o;
    } return t.decorators && t.decorators !== n.decorators ? du(t.decorators) : t.hasOwnProperty(fo) ? t[fo] : null; }
    annotations(t) { if (!Ss(t))
        return []; let n = bs(t), o = this._ownAnnotations(t, n) || []; return (n !== Object ? this.annotations(n) : []).concat(o); }
    _ownPropMetadata(t, n) { if (t.propMetadata && t.propMetadata !== n.propMetadata) {
        let o = t.propMetadata;
        return typeof o == "function" && o.propMetadata && (o = o.propMetadata), o;
    } if (t.propDecorators && t.propDecorators !== n.propDecorators) {
        let o = t.propDecorators, r = {};
        return Object.keys(o).forEach(i => { r[i] = du(o[i]); }), r;
    } return t.hasOwnProperty(ho) ? t[ho] : null; }
    propMetadata(t) { if (!Ss(t))
        return {}; let n = bs(t), o = {}; if (n !== Object) {
        let i = this.propMetadata(n);
        Object.keys(i).forEach(s => { o[s] = i[s]; });
    } let r = this._ownPropMetadata(t, n); return r && Object.keys(r).forEach(i => { let s = []; o.hasOwnProperty(i) && s.push(...o[i]), s.push(...r[i]), o[i] = s; }), o; }
    ownPropMetadata(t) { return Ss(t) ? this._ownPropMetadata(t, bs(t)) || {} : {}; }
    hasLifecycleHook(t, n) { return t instanceof mv && n in t.prototype; }
};
function du(e) { return e ? e.map(t => { let o = t.type.annotationCls, r = t.args ? t.args : []; return new o(...r); }) : []; }
function bs(e) { let t = e.prototype ? Object.getPrototypeOf(e.prototype) : null; return (t ? t.constructor : null) || Object; }
var vv = Yn(Ro("Inject", e => ({ token: e })), -1), yv = Yn(Ro("Optional"), 8), Ev = Yn(Ro("Self"), 2), Iv = Yn(Ro("SkipSelf"), 4), Dv = Yn(Ro("Host"), 1), Tv = Ro("Attribute", e => ({ attributeName: e, __NG_ELEMENT_ID__: () => wa(e) })), kg = null;
function Ud() { return kg = kg || new ta; }
function hi(e) { return Cv(Ud().parameters(e)); }
function Cv(e) { return e.map(t => ZN(t)); }
function ZN(e) { let t = { token: null, attribute: null, host: !1, optional: !1, self: !1, skipSelf: !1 }; if (Array.isArray(e) && e.length > 0)
    for (let n = 0; n < e.length; n++) {
        let o = e[n];
        if (o === void 0)
            continue;
        let r = Object.getPrototypeOf(o);
        if (o instanceof yv || r.ngMetadataName === "Optional")
            t.optional = !0;
        else if (o instanceof Iv || r.ngMetadataName === "SkipSelf")
            t.skipSelf = !0;
        else if (o instanceof Ev || r.ngMetadataName === "Self")
            t.self = !0;
        else if (o instanceof Dv || r.ngMetadataName === "Host")
            t.host = !0;
        else if (o instanceof vv)
            t.token = o.token;
        else if (o instanceof Tv) {
            if (o.attributeName === void 0)
                throw new D(-204, !1);
            t.attribute = o.attributeName;
        }
        else
            t.token = o;
    }
else
    e === void 0 || Array.isArray(e) && e.length === 0 ? t.token = null : t.token = e; return t; }
function YN(e, t) { let n = null, o = null; e.hasOwnProperty(Wt) || Object.defineProperty(e, Wt, { get: () => (n === null && (n = ee({ usage: 0, kind: "injectable", type: e }).compileInjectable(ea, `ng:///${e.name}/\u0275prov.js`, e_(e, t))), n) }), e.hasOwnProperty($e) || Object.defineProperty(e, $e, { get: () => { if (o === null) {
        let r = ee({ usage: 0, kind: "injectable", type: e });
        o = r.compileFactory(ea, `ng:///${e.name}/\u0275fac.js`, { name: e.name, type: e, typeArgumentCount: 0, deps: hi(e), target: r.FactoryTarget.Injectable });
    } return o; }, configurable: !0 }); }
var KN = V({ provide: String, useValue: V });
function Og(e) { return e.useClass !== void 0; }
function JN(e) { return KN in e; }
function Lg(e) { return e.useFactory !== void 0; }
function XN(e) { return e.useExisting !== void 0; }
function e_(e, t) { let n = t || { providedIn: null }, o = { name: e.name, type: e, typeArgumentCount: 0, providedIn: n.providedIn }; return (Og(n) || Lg(n)) && n.deps !== void 0 && (o.deps = Cv(n.deps)), Og(n) ? o.useClass = n.useClass : JN(n) ? o.useValue = n.useValue : Lg(n) ? o.useFactory = n.useFactory : XN(n) && (o.useExisting = n.useExisting), o; }
var t_ = Ao("Injectable", void 0, void 0, void 0, (e, t) => YN(e, t));
function n_(e, t) { let n = null, o = null; e.hasOwnProperty(Wt) || Object.defineProperty(e, Wt, { get: () => (n === null && (n = ee({ usage: 0, kind: "service", type: e }).compileService(ea, `ng:///${e.name}/\u0275prov.js`, o_(e, t))), n) }), e.hasOwnProperty($e) || Object.defineProperty(e, $e, { get: () => { if (o === null) {
        let r = ee({ usage: 0, kind: "service", type: e });
        o = r.compileFactory(ea, `ng:///${e.name}/\u0275fac.js`, { name: e.name, type: e, typeArgumentCount: 0, deps: hi(e), target: r.FactoryTarget.Service });
    } return o; }, configurable: !0 }); }
function o_(e, t) { return { name: e.name, type: e, typeArgumentCount: 0, autoProvided: t?.autoProvided, factory: t?.factory }; }
var r_ = Ao("Service", void 0, void 0, void 0, (e, t) => n_(e, t));
function i_() { return xo(_(), g()); }
function xo(e, t) { return new gi(ie(e, t)); }
var gi = (() => { class e {
    nativeElement;
    constructor(n) { this.nativeElement = n; }
    static __NG_ELEMENT_ID__ = i_;
} return e; })();
function Mv(e) { return e instanceof gi ? e.nativeElement : e; }
function s_() { return this._results[Symbol.iterator](); }
var na = class {
    _emitDistinctChangesOnly;
    dirty = !0;
    _onDirty = void 0;
    _results = [];
    _changesDetected = !1;
    _changes = void 0;
    length = 0;
    first = void 0;
    last = void 0;
    get changes() { return this._changes ??= new Km; }
    constructor(t = !1) { this._emitDistinctChangesOnly = t; }
    get(t) { return this._results[t]; }
    map(t) { return this._results.map(t); }
    filter(t) { return this._results.filter(t); }
    find(t) { return this._results.find(t); }
    reduce(t, n) { return this._results.reduce(t, n); }
    forEach(t) { this._results.forEach(t); }
    some(t) { return this._results.some(t); }
    toArray() { return this._results.slice(); }
    toString() { return this._results.toString(); }
    reset(t, n) { this.dirty = !1; let o = nt(t); (this._changesDetected = !Jh(this._results, o, n)) && (this._results = o, this.length = o.length, this.last = o[this.length - 1], this.first = o[0]); }
    notifyOnChanges() { this._changes !== void 0 && (this._changesDetected || !this._emitDistinctChangesOnly) && this._changes.next(this); }
    onDirty(t) { this._onDirty = t; }
    setDirty() { this.dirty = !0, this._onDirty?.(); }
    destroy() { this._changes !== void 0 && (this._changes.complete(), this._changes.unsubscribe()); }
    [Symbol.iterator] = s_;
}, jn = "ngSkipHydration", a_ = "ngskiphydration";
function qd(e) { let t = e.mergedAttrs; if (t === null)
    return !1; for (let n = 0; n < t.length; n += 2) {
    let o = t[n];
    if (typeof o == "number")
        return !1;
    if (typeof o == "string" && o.toLowerCase() === a_)
        return !0;
} return !1; }
function wv(e) { return e.hasAttribute(jn); }
function zr(e) { return (e.flags & 128) === 128; }
function ko(e) { if (zr(e))
    return !0; let t = e.parent; for (; t;) {
    if (zr(e) || qd(t))
        return !0;
    t = t.parent;
} return !1; }
function Nv(e) { return zr(e) || qd(e) || ko(e); }
var _a = (function (e) { return e[e.OnPush = 0] = "OnPush", e[e.Eager = 1] = "Eager", e[e.Default = 1] = "Default", e; })(_a || {}), Sa = new Map, c_ = 0;
function l_() { return c_++; }
function u_(e) { Sa.set(e[Fe], e); }
function _v(e) { return Sa.get(e) || null; }
function ju(e) { Sa.delete(e[Fe]); }
function d_() { return Sa; }
var oa = class {
    lViewId;
    nodeIndex;
    native;
    component;
    directives;
    localRefs;
    get lView() { return _v(this.lViewId); }
    constructor(t, n, o) { this.lViewId = t, this.nodeIndex = n, this.native = o; }
};
function we(e) { let t = Us(e); if (t) {
    if (J(t)) {
        let n = t, o, r, i;
        if (Sv(e)) {
            if (o = g_(n, e), o == -1)
                throw new Error("The provided component was not found in the application");
            r = e;
        }
        else if (p_(e)) {
            if (o = m_(n, e), o == -1)
                throw new Error("The provided directive was not found in the application");
            i = bv(o, n);
        }
        else if (o = Fg(n, e), o == -1)
            return null;
        let s = O(n[o]), a = Us(s), c = a && !Array.isArray(a) ? a : Pg(n, o, s);
        if (r && c.component === void 0 && (c.component = r, Ye(c.component, c)), i && c.directives === void 0) {
            c.directives = i;
            for (let l = 0; l < i.length; l++)
                Ye(i[l], c);
        }
        Ye(c.native, c), t = c;
    }
}
else {
    let n = e, o = n;
    for (; o = o.parentNode;) {
        let r = Us(o);
        if (r) {
            let i = Array.isArray(r) ? r : r.lView;
            if (!i)
                return null;
            let s = Fg(i, n);
            if (s >= 0) {
                let a = O(i[s]), c = Pg(i, s, a);
                Ye(a, c), t = c;
                break;
            }
        }
    }
} return t || null; }
function Pg(e, t, n) { return new oa(e[Fe], t, n); }
var Vu = "__ngContext__";
function Ye(e, t) { J(t) ? (e[Vu] = t[Fe], u_(t)) : e[Vu] = t; }
function Us(e) { let t = e[Vu]; return typeof t == "number" ? _v(t) : t || null; }
function f_(e) { let t = Us(e); return t ? J(t) ? t : t.lView : null; }
function Sv(e) { return e && e.constructor && e.constructor.\u0275cmp; }
function p_(e) { return e && e.constructor && e.constructor.\u0275dir; }
function Fg(e, t) { let n = e[m]; for (let o = I; o < n.bindingStartIndex; o++)
    if (O(e[o]) === t)
        return o; return -1; }
function h_(e) { if (e.child)
    return e.child; if (e.next)
    return e.next; for (; e.parent && !e.parent.next;)
    e = e.parent; return e.parent && e.parent.next; }
function g_(e, t) { let n = e[m].components; if (n)
    for (let o = 0; o < n.length; o++) {
        let r = n[o];
        if (me(r, e)[j] === t)
            return r;
    }
else if (me(I, e)[j] === t)
    return I; return -1; }
function m_(e, t) { let n = e[m].firstChild; for (; n;) {
    let o = n.directiveStart, r = n.directiveEnd;
    for (let i = o; i < r; i++)
        if (e[i] === t)
            return n.index;
    n = h_(n);
} return -1; }
function bv(e, t) { let n = t[m].data[e]; if (n.directiveStart === 0)
    return F; let o = []; for (let r = n.directiveStart; r < n.directiveEnd; r++) {
    let i = t[r];
    Sv(i) || o.push(i);
} return o; }
function v_(e, t) { let n = t[m].data[e]; return Ce(n) ? t[n.directiveStart + n.componentOffset] : null; }
function y_(e, t) { let n = e[m].data[t]; if (n && n.localNames) {
    let o = {}, r = n.index + 1;
    for (let i = 0; i < n.localNames.length; i += 2)
        o[n.localNames[i]] = e[r], r++;
    return o;
} return null; }
function Av(e) { return xv(e[Qt]); }
function Rv(e) { return xv(e[ge]); }
function xv(e) { for (; e !== null && !K(e);)
    e = e[ge]; return e; }
function* E_(e, t) { let n = e.child; for (; n;)
    yield [n, t], n = n.next; if (e.componentOffset > -1) {
    let r = me(e.index, t);
    if (J(r)) {
        let s = r[m].firstChild;
        for (; s;)
            yield [s, r], s = s.next;
    }
} let o = t[e.index]; if (K(o))
    for (let r = U; r < o.length; r++) {
        let i = o[r], a = i[m].firstChild;
        for (; a;)
            yield [a, i], a = a.next;
    } }
function* I_(e) { let n = e[m].firstChild; for (; n;)
    yield* zc(kv(n, e)), n = n.next; }
function* kv(e, t) { yield [e, t]; for (let [n, o] of E_(e, t))
    yield* zc(kv(n, o)); }
function* Gd(e) { for (let [t, n] of I_(e))
    t.directiveEnd > t.directiveStart && (yield [t, n]); }
function jg(e) { let t = we(e); if (t === null)
    return null; if (t.component === void 0) {
    let n = t.lView;
    if (n === null)
        return null;
    t.component = v_(t.nodeIndex, n);
} return t.component; }
function D_(e) { A_(e); let t = we(e), n = t ? t.lView : null; return n === null ? null : n[j]; }
function T_(e) { let t = we(e), n = t ? t.lView : null; if (n === null)
    return null; let o; for (; n[m].type === 2 && (o = Ue(n));)
    n = o; return rt(n) ? null : n[j]; }
function Wd(e) { let t = we(e), n = t ? t.lView : null; if (n === null)
    return oe.NULL; let o = n[m].data[t.nodeIndex]; return new Me(o, n); }
function C_(e) { let t = we(e), n = t ? t.lView : null; if (n === null)
    return []; let o = n[m], r = o.data[t.nodeIndex], i = [], s = r.providerIndexes & 1048575, a = r.directiveEnd; for (let c = s; c < a; c++) {
    let l = o.data[c];
    b_(l) && (l = l.type), i.push(l);
} return i; }
function M_(e) { if (e instanceof Text)
    return []; let t = we(e), n = t ? t.lView : null; if (n === null)
    return []; let o = n[m], r = t.nodeIndex; return o?.data[r] ? (t.directives === void 0 && (t.directives = bv(r, n)), t.directives === null ? [] : [...t.directives]) : []; }
var Ov = (function (e) { return e[e.Default = 0] = "Default", e[e.OnPush = 1] = "OnPush", e; })(Ov || {}), Lv = (function (e) { return e[e.Emulated = 0] = "Emulated", e[e.None = 1] = "None", e; })(Lv || {});
function w_(e) { let t = we(e); if (t === null)
    return {}; if (t.localRefs === void 0) {
    let n = t.lView;
    if (n === null)
        return {};
    t.localRefs = y_(n, t.nodeIndex);
} return t.localRefs || {}; }
function N_(e) { return we(e).native; }
function __(e) { let t = we(e), n = t === null ? null : t.lView; if (n === null)
    return []; let o = n[m], r = n[zt], i = o.cleanup, s = []; if (i && r)
    for (let a = 0; a < i.length;) {
        let c = i[a++], l = i[a++];
        if (typeof c == "string") {
            let u = c, d = O(n[l]), f = r[i[a++]], p = i[a++], h = typeof p == "boolean" || p >= 0 ? "dom" : "output", v = typeof p == "boolean" ? p : !1;
            e == d && s.push({ element: e, name: u, callback: f, useCapture: v, type: h });
        }
    } return s.sort(S_), s; }
function S_(e, t) { return e.name == t.name ? 0 : e.name < t.name ? -1 : 1; }
function b_(e) { return e.type !== void 0 && e.declaredInputs !== void 0 && e.resolveHostDirectives !== void 0; }
function A_(e) { if (typeof Element < "u" && !(e instanceof Element))
    throw new Error("Expecting instance of DOM Element"); }
var Hu;
function R_(e) { Hu = e; }
function mi() { if (Hu !== void 0)
    return Hu; if (typeof document < "u")
    return document; throw new D(210, !1); }
var zd = "h", Qd = "b", Pv = "f", Fv = "n", vi = "e", ba = "t", Oo = "c", yi = "x", xt = "r", Aa = "i", Ei = "n", Lo = "d", Ra = "l", xa = "di", Ii = "s", Zd = "p", Di = "t", Vn = new C(""), jv = !1, Yd = new C("", { factory: () => jv }), Kd = new C(""), ka = new C(""), Jd = !1, Vv = new C("", { factory: () => [] }), Xd = new C(""), Ti = new C("", { factory: () => new Map }), x_ = new C(""), ra = { passive: !0, capture: !0 }, fu = new WeakMap, pu = new WeakMap, tn = new WeakMap, ia = ["click", "keydown"], sa = ["mouseenter", "mouseover", "focusin"], As = new Map, Qr = class {
    callbacks = new Set;
    listener = () => { for (let t of this.callbacks)
        t(); };
};
function Hv(e, t) { let n = pu.get(e); if (!n) {
    n = new Qr, pu.set(e, n);
    for (let o of ia)
        e.addEventListener(o, n.listener, ra);
} return n.callbacks.add(t), () => { let { callbacks: o, listener: r } = n; if (o.delete(t), o.size === 0) {
    pu.delete(e);
    for (let i of ia)
        e.removeEventListener(i, r, ra);
} }; }
function Bv(e, t) { let n = fu.get(e); if (!n) {
    n = new Qr, fu.set(e, n);
    for (let o of sa)
        e.addEventListener(o, n.listener, ra);
} return n.callbacks.add(t), () => { let { callbacks: o, listener: r } = n; if (o.delete(t), o.size === 0) {
    for (let i of sa)
        e.removeEventListener(i, r, ra);
    fu.delete(e);
} }; }
function k_(e) { let t = $v(e); return new IntersectionObserver(n => { for (let o of n)
    o.isIntersecting && tn.has(o.target) && tn.get(o.target)?.get(t)?.listener(); }, e); }
function O_(e, t, n, o) { let r = $v(o), i = tn.get(e)?.get(r); As.has(r) || As.set(r, { observer: n(o), count: 0 }); let s = As.get(r); if (!i) {
    i = new Qr, s.observer.observe(e);
    let a = tn.get(e);
    a ? a.set(r, i) : (a = new Map, tn.set(e, a)), a.set(r, i), s.count++;
} return i.callbacks.add(t), () => { if (tn.get(e)?.has(r)) {
    if (i.callbacks.delete(t), i.callbacks.size === 0) {
        s.observer.unobserve(e), s.count--;
        let a = tn.get(e);
        a && (a.delete(r), a.size === 0 && tn.delete(e));
    }
    s.count === 0 && (s.observer.disconnect(), As.delete(r));
} }; }
function $v(e) {
    return e ? `${e.rootMargin}/${typeof e.threshold == "number" ? e.threshold : e.threshold?.join(`
`)}` : "";
}
var Po = "ngb";
function ef(e, t, n = null) { if (t.length === 0 || e.nodeType !== Node.ELEMENT_NODE)
    return; let o = e.getAttribute(co.JSACTION), r = t.reduce((s, a) => (o?.indexOf(a) ?? -1) === -1 ? s + a + ":;" : s, ""); e.setAttribute(co.JSACTION, `${o ?? ""}${r}`); let i = n ?? ""; i !== "" && r.length > 0 && e.setAttribute(Po, i); }
var Uv = (e, t, n) => { let o = e, r = o.__jsaction_fns ?? new Map, i = r.get(t) ?? []; i.push(n), r.set(t, i), o.__jsaction_fns = r; }, tf = (e, t) => { let n = e, o = n.getAttribute(Po) ?? "", r = t.get(o) ?? new Set; r.has(n) || r.add(n), t.set(o, r); };
function L_(e, t) { if (e.length > 0) {
    let n = [];
    for (let r of e)
        t.has(r) && (n = [...n, ...t.get(r)]);
    new Set(n).forEach(nf);
} }
var nf = e => { e.removeAttribute(co.JSACTION), e.removeAttribute(Po), e.__jsaction_fns = void 0; }, of = new C("", { factory: () => ({}) }), Bu = new WeakMap;
function P_(e, t) { if (e == null || typeof e != "object")
    return; let n = Bu.get(e); n || (n = new WeakSet, Bu.set(e, n)), n.add(t); }
function rf(e, t) { let n = t?.__jsaction_fns?.get(e.type); if (!(!n || !t?.isConnected) && !(t && Bu.get(e)?.has(t)))
    for (let o of n)
        o(e); }
var $u = new Map;
function qv(e, t) { return $u.set(e, t), () => $u.delete(e); }
var Vg = !1, Gv = (e, t, n, o) => { };
function F_(e, t, n, o) { Gv(e, t, n, o); }
function Wv() { Vg || (Gv = (e, t, n, o) => { let r = e[k].get(vt); $u.get(r)?.(t, n, o); }, Vg = !0); }
var Pt = new C(""), j_ = (() => { class e {
    registry = new Map;
    cleanupFns = new Map;
    jsActionMap = E(Ti);
    contract = E(of);
    add(n, o) { if (this.registry.set(n, o), this.awaitingCallbacks.has(n)) {
        let r = this.awaitingCallbacks.get(n);
        for (let i of r)
            i();
    } }
    get(n) { return this.registry.get(n) ?? null; }
    has(n) { return this.registry.has(n); }
    cleanup(n) { L_(n, this.jsActionMap); for (let o of n)
        this.registry.delete(o), this.jsActionMap.delete(o), this.invokeTriggerCleanupFns(o), this.hydrating.delete(o), this.awaitingCallbacks.delete(o); this.size === 0 && this.contract.instance?.cleanUp(); }
    get size() { return this.registry.size; }
    addCleanupFn(n, o) { let r = []; this.cleanupFns.has(n) && (r = this.cleanupFns.get(n)), r.push(o), this.cleanupFns.set(n, r); }
    invokeTriggerCleanupFns(n) { let o = this.cleanupFns.get(n) ?? []; for (let r of o)
        r(); this.cleanupFns.delete(n); }
    hydrating = new Map;
    awaitingCallbacks = new Map;
    awaitParentBlock(n, o) { let r = this.awaitingCallbacks.get(n) ?? []; r.push(o), this.awaitingCallbacks.set(n, r); }
    static \u0275prov = Y({ token: e, providedIn: null, factory: () => new e });
} return e; })();
function Fo(e) { return (e.flags & 32) === 32; }
var zv = "__nghData__", Oa = zv, Qv = "__nghDeferData__", La = Qv;
function V_(e) { return e === zv || e === Qv; }
var yo = "ngh", Zv = "nghm", Yv = () => null;
function H_(e, t, n = !1) { let o = e.getAttribute(yo); if (o == null)
    return null; let [r, i] = o.split("|"); if (o = n ? i : r, !o)
    return null; let s = i ? `|${i}` : "", a = n ? r : s, c = {}; if (o !== "") {
    let u = t.get(St, null, { optional: !0 });
    u !== null && (c = u.get(Oa, [])[Number(o)]);
} let l = { data: c, firstChild: e.firstChild ?? null }; return n && (l.firstChild = e, Pa(l, 0, e.nextSibling)), a ? e.setAttribute(yo, a) : e.removeAttribute(yo), l; }
function Kv() { Yv = H_; }
function Jv(e, t, n = !1) { return Yv(e, t, n); }
function sf(e) { let t = e._lView; return t[m].type === 2 ? null : (rt(t) && (t = t[I]), t); }
function B_(e) { return e.textContent?.replace(/\s/gm, ""); }
function $_(e) { let t = mi(), n = t.createNodeIterator(e, NodeFilter.SHOW_COMMENT, { acceptNode(i) { let s = B_(i); return s === "ngetn" || s === "ngtns" ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } }), o, r = []; for (; o = n.nextNode();)
    r.push(o); for (let i of r)
    i.textContent === "ngetn" ? i.replaceWith(t.createTextNode("")) : i.remove(); }
var Xv = (function (e) { return e.Hydrated = "hydrated", e.Skipped = "skipped", e.Mismatched = "mismatched", e; })(Xv || {}), U_ = "__ngDebugHydrationInfo__";
function q_(e) { return e[U_] ?? null; }
function Pa(e, t, n) { e.segmentHeads ??= {}, e.segmentHeads[t] = n; }
function Uu(e, t) { return e.segmentHeads?.[t] ?? null; }
function Ci(e) { return e.get(Xd, !1, { optional: !0 }); }
var G_ = !1;
function W_() { G_ = !1; }
function ey(e, t) { let n = e.data, o = n[vi]?.[t] ?? null; return o === null && n[Oo]?.[t] && (o = af(e, t)), o; }
function z_(e, t) { return e.data[vi]?.[t] !== void 0; }
function ty(e, t) { return e.data[Oo]?.[t] ?? null; }
function af(e, t) { let n = ty(e, t) ?? [], o = 0; for (let r of n)
    o += r[xt] * (r[yi] ?? 1); return o; }
function ny(e) { if (typeof e.disconnectedNodes > "u") {
    let t = e.data[Lo];
    e.disconnectedNodes = t ? new Set(t) : null;
} return e.disconnectedNodes; }
function Fa(e, t) { if (typeof e.disconnectedNodes > "u") {
    let n = e.data[Lo];
    e.disconnectedNodes = n ? new Set(n) : null;
} return !!ny(e)?.has(t); }
function ja(e, t) { let n = e[fe]; return n !== null && !wr() && !Fo(t) && !Fa(n, t.index - I); }
function cf(e, t) { let n = t, o = e.corruptedTextNodes; n.textContent === "" ? o.set(n, "ngetn") : n.nextSibling?.nodeType === Node.TEXT_NODE && o.set(n, "ngtns"); }
function oy(e) { let t = []; return e !== null && (e.has(4) && t.push(...sa), e.has(3) && t.push(...ia)), t; }
function Q_(e, t) { let n = t.get(Pt), r = t.get(St).get(La, {}), i = !1, s = e, a = null, c = []; for (; !i && s;) {
    i = n.has(s);
    let l = n.hydrating.get(s);
    if (a === null && l != null) {
        a = l.promise;
        break;
    }
    c.unshift(s), s = r[s][Zd];
} return { parentBlockPromise: a, hydrationQueue: c }; }
function Z_(e) { let t = e.body.querySelectorAll("[jsaction]"), n = new Set, o = [sa.join(":;"), ia.join(":;")].join("|"); for (let r of t) {
    let i = r.getAttribute("jsaction"), s = r.getAttribute("ngb");
    i?.match(o) && s !== null && n.add(r);
} return n; }
function Y_(e, t) { let n = Z_(e), o = t.get(Ti); for (let r of n)
    tf(r, o); }
var ry = () => ({});
function K_(e) { let t = e.get(St, null, { optional: !0 }); return t !== null ? t.get(La, {}) : {}; }
function J_() { ry = K_; }
function X_(e) { return ry(e); }
function eS(e) { return typeof e == "object" && e.trigger === 5; }
function tS(e) { return e[Di]?.find(n => eS(n))?.delay ?? null; }
function nS(e) { let t = e[Di]; if (t)
    for (let n of t) {
        if (n === 2)
            return !0;
        if (typeof n == "object" && n.trigger === 2)
            return n.intersectionObserverOptions || !0;
    } return null; }
function Hg(e, t) { return e[Di]?.includes(t) ?? !1; }
function oS(e) { return { data: e, hydrate: { idle: Hg(e, 0), immediate: Hg(e, 1), timer: tS(e), viewport: nS(e) } }; }
function rS(e) { let t = X_(e), n = new Map; for (let o in t)
    n.set(o, oS(t[o])); return n; }
function hu(e) { return !!e && e.nodeType === Node.COMMENT_NODE && e.textContent?.trim() === Zv; }
function Bg(e) { for (; e && e.nodeType === Node.TEXT_NODE;)
    e = e.previousSibling; return e; }
function iy(e) { for (let o of e.body.childNodes)
    if (hu(o))
        return; let t = Bg(e.body.previousSibling); if (hu(t))
    return; let n = Bg(e.head.lastChild); if (!hu(n))
    throw new D(-507, !1); }
function sy(e, t) { let n = e.contentQueries; if (n !== null) {
    let o = x(null);
    try {
        for (let r = 0; r < n.length; r += 2) {
            let i = n[r], s = n[r + 1];
            if (s !== -1) {
                let a = e.data[s];
                Nr(i), a.contentQueries(2, t[s], s);
            }
        }
    }
    finally {
        x(o);
    }
} }
function qu(e, t, n) { Nr(0); let o = x(null); try {
    t(e, n);
}
finally {
    x(o);
} }
function lf(e, t, n) { if (Nl(t)) {
    let o = x(null);
    try {
        let r = t.directiveStart, i = t.directiveEnd;
        for (let s = r; s < i; s++) {
            let a = e.data[s];
            if (a.contentQueries) {
                let c = n[s];
                a.contentQueries(1, c, s);
            }
        }
    }
    finally {
        x(o);
    }
} }
var Ke = (function (e) { return e[e.Emulated = 0] = "Emulated", e[e.None = 2] = "None", e[e.ShadowDom = 3] = "ShadowDom", e[e.ExperimentalIsolatedShadowDom = 4] = "ExperimentalIsolatedShadowDom", e; })(Ke || {}), iS = { name: "custom-elements" }, sS = { name: "no-errors-schema" }, ay = !1;
function aS(e) { ay = e; }
function cS() { return ay; }
var cy = !1;
function lS(e) { cy = e; }
function uS() { return cy; }
var Rs;
function ly() { if (Rs === void 0 && (Rs = null, Le.trustedTypes))
    try {
        Rs = Le.trustedTypes.createPolicy("angular", { createHTML: e => e, createScript: e => e, createScriptURL: e => e });
    }
    catch { } return Rs; }
function jo(e) { return ly()?.createHTML(e) || e; }
function dS(e) { return ly()?.createScriptURL(e) || e; }
var xs;
function uf() { if (xs === void 0 && (xs = null, Le.trustedTypes))
    try {
        xs = Le.trustedTypes.createPolicy("angular#unsafe-bypass", { createHTML: e => e, createScript: e => e, createScriptURL: e => e });
    }
    catch { } return xs; }
function $g(e) { return uf()?.createHTML(e) || e; }
function Ug(e) { return uf()?.createScript(e) || e; }
function qg(e) { return uf()?.createScriptURL(e) || e; }
var kt = class {
    changingThisBreaksApplicationSecurity;
    constructor(t) { this.changingThisBreaksApplicationSecurity = t; }
    toString() { return `SafeValue must use [property]=binding: ${this.changingThisBreaksApplicationSecurity} (see ${ns})`; }
}, Gu = class extends kt {
    getTypeName() { return "HTML"; }
}, Wu = class extends kt {
    getTypeName() { return "Style"; }
}, zu = class extends kt {
    getTypeName() { return "Script"; }
}, Qu = class extends kt {
    getTypeName() { return "URL"; }
}, Zu = class extends kt {
    getTypeName() { return "ResourceURL"; }
};
function Ft(e) { return e instanceof kt ? e.changingThisBreaksApplicationSecurity : e; }
function Vo(e, t) { let n = uy(e); if (n != null && n !== t) {
    if (n === "ResourceURL" && t === "URL")
        return !0;
    throw new Error(`Required a safe ${t}, got a ${n} (see ${ns})`);
} return n === t; }
function uy(e) { return e instanceof kt && e.getTypeName() || null; }
function fS(e) { return new Gu(e); }
function pS(e) { return new Wu(e); }
function hS(e) { return new zu(e); }
function gS(e) { return new Qu(e); }
function mS(e) { return new Zu(e); }
function dy(e) { let t = new Ku(e); return vS() ? new Yu(t) : t; }
var Yu = class {
    inertDocumentHelper;
    constructor(t) { this.inertDocumentHelper = t; }
    getInertBodyElement(t) { t = "<body><remove></remove>" + t; try {
        let n = new window.DOMParser().parseFromString(jo(t), "text/html").body;
        return n === null ? this.inertDocumentHelper.getInertBodyElement(t) : (n.firstChild?.remove(), n);
    }
    catch {
        return null;
    } }
}, Ku = class {
    defaultDoc;
    inertDocument;
    constructor(t) { this.defaultDoc = t, this.inertDocument = this.defaultDoc.implementation.createHTMLDocument("sanitization-inert"); }
    getInertBodyElement(t) { let n = this.inertDocument.createElement("template"); return n.innerHTML = jo(t), n; }
};
function vS() { try {
    return !!new window.DOMParser().parseFromString(jo(""), "text/html");
}
catch {
    return !1;
} }
var yS = /^(?!javascript:)(?:[a-z0-9+.-]+:|[^&:\/?#]*(?:[\/?#]|$))/i;
function Va(e) { return e = String(e), e.match(yS) ? e : "unsafe:" + e; }
function jt(e) { let t = {}; for (let n of e.split(","))
    t[n] = !0; return t; }
function Mi(...e) { let t = {}; for (let n of e)
    for (let o in n)
        n.hasOwnProperty(o) && (t[o] = !0); return t; }
var fy = jt("area,br,col,hr,img,wbr"), py = jt("colgroup,dd,dt,li,p,tbody,td,tfoot,th,thead,tr"), hy = jt("rp,rt"), ES = Mi(hy, py), IS = Mi(py, jt("address,article,aside,blockquote,caption,center,del,details,dialog,dir,div,dl,figure,figcaption,footer,h1,h2,h3,h4,h5,h6,header,hgroup,hr,ins,main,map,menu,nav,ol,pre,section,summary,table,ul")), DS = Mi(hy, jt("a,abbr,acronym,audio,b,bdi,bdo,big,br,cite,code,del,dfn,em,font,i,img,ins,kbd,label,map,mark,picture,q,ruby,rp,rt,s,samp,small,source,span,strike,strong,sub,sup,time,track,tt,u,var,video")), Ju = Mi(fy, IS, DS, ES), gy = jt("background,cite,href,itemtype,longdesc,poster,src,xlink:href"), TS = jt("abbr,accesskey,align,alt,autoplay,axis,bgcolor,border,cellpadding,cellspacing,class,clear,color,cols,colspan,compact,controls,coords,datetime,default,dir,download,face,headers,height,hidden,hreflang,hspace,ismap,itemscope,itemprop,kind,label,lang,language,loop,media,muted,nohref,nowrap,open,preload,rel,rev,role,rows,rowspan,rules,scope,scrolling,shape,size,sizes,span,srclang,srcset,start,summary,tabindex,target,title,translate,type,usemap,valign,value,vspace,width"), CS = jt("aria-activedescendant,aria-atomic,aria-autocomplete,aria-busy,aria-checked,aria-colcount,aria-colindex,aria-colspan,aria-controls,aria-current,aria-describedby,aria-details,aria-disabled,aria-dropeffect,aria-errormessage,aria-expanded,aria-flowto,aria-grabbed,aria-haspopup,aria-hidden,aria-invalid,aria-keyshortcuts,aria-label,aria-labelledby,aria-level,aria-live,aria-modal,aria-multiline,aria-multiselectable,aria-orientation,aria-owns,aria-placeholder,aria-posinset,aria-pressed,aria-readonly,aria-relevant,aria-required,aria-roledescription,aria-rowcount,aria-rowindex,aria-rowspan,aria-selected,aria-setsize,aria-sort,aria-valuemax,aria-valuemin,aria-valuenow,aria-valuetext"), Xu = Mi(gy, TS, CS), MS = jt("script,style,template"), ed = class {
    sanitizedSomething = !1;
    buf = [];
    sanitizeChildren(t) { let n = t.firstChild, o = !0, r = []; for (; n;) {
        if (n.nodeType === Node.ELEMENT_NODE ? o = this.startElement(n) : n.nodeType === Node.TEXT_NODE ? this.chars(n.nodeValue) : this.sanitizedSomething = !0, o && n.firstChild) {
            r.push(n), n = _S(n);
            continue;
        }
        for (; n;) {
            n.nodeType === Node.ELEMENT_NODE && this.endElement(n);
            let i = NS(n);
            if (i) {
                n = i;
                break;
            }
            n = r.pop();
        }
    } return this.buf.join(""); }
    startElement(t) { let n = Gg(t).toLowerCase(); if (!Ju.hasOwnProperty(n))
        return this.sanitizedSomething = !0, !MS.hasOwnProperty(n); this.buf.push("<"), this.buf.push(n); let o = t.attributes; for (let r = 0; r < o.length; r++) {
        let i = o.item(r), s = i.name, a = s.toLowerCase();
        if (!Xu.hasOwnProperty(a)) {
            this.sanitizedSomething = !0;
            continue;
        }
        let c = i.value;
        gy[a] && (c = Va(c)), this.buf.push(" ", s, '="', Wg(c), '"');
    } return this.buf.push(">"), !0; }
    endElement(t) { let n = Gg(t).toLowerCase(); Ju.hasOwnProperty(n) && !fy.hasOwnProperty(n) && (this.buf.push("</"), this.buf.push(n), this.buf.push(">")); }
    chars(t) { this.buf.push(Wg(t)); }
};
function wS(e, t) { return (e.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_CONTAINED_BY) !== Node.DOCUMENT_POSITION_CONTAINED_BY; }
function NS(e) { let t = e.nextSibling; if (t && e !== t.previousSibling)
    throw my(t); return t; }
function _S(e) { let t = e.firstChild; if (t && wS(e, t))
    throw my(t); return t; }
function Gg(e) { let t = e.nodeName; return typeof t == "string" ? t : "FORM"; }
function my(e) { return new Error(`Failed to sanitize html because the element is clobbered: ${e.outerHTML}`); }
var SS = /[\uD800-\uDBFF][\uDC00-\uDFFF]/g, bS = /([^\#-~ |!])/g;
function Wg(e) { return e.replace(/&/g, "&amp;").replace(SS, function (t) { let n = t.charCodeAt(0), o = t.charCodeAt(1); return "&#" + ((n - 55296) * 1024 + (o - 56320) + 65536) + ";"; }).replace(bS, function (t) { return "&#" + t.charCodeAt(0) + ";"; }).replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
var ks;
function vy(e, t) { let n = null; try {
    ks = ks || dy(e);
    let o = t ? String(t) : "";
    n = ks.getInertBodyElement(o);
    let r = 5, i = o;
    do {
        if (r === 0)
            throw new Error("Failed to sanitize html because the input is unstable");
        r--, o = i, i = n.innerHTML, n = ks.getInertBodyElement(o);
    } while (o !== i);
    let a = new ed().sanitizeChildren(td(n) || n);
    return jo(a);
}
finally {
    if (n) {
        let o = td(n) || n;
        for (; o.firstChild;)
            o.firstChild.remove();
    }
} }
function td(e) { return "content" in e && AS(e) ? e.content : null; }
function AS(e) { return e.nodeType === Node.ELEMENT_NODE && e.nodeName === "TEMPLATE"; }
var RS = />|->|<!--|-->|--!>|<!-$/g, xS = /(<|>)/g, kS = "\u200B$1\u200B";
function OS(e) { return e.replace(RS, t => t.replace(xS, kS)); }
function df(e, t) { return e.createText(t); }
function yy(e, t, n) { e.setValue(t, n); }
function ff(e, t) { return e.createComment(OS(t)); }
function Ha(e, t, n) { return e.createElement(t, n); }
function _n(e, t, n, o, r) { e.insertBefore(t, n, o, r); }
function Ey(e, t, n) { e.appendChild(t, n); }
function zg(e, t, n, o, r) { o !== null ? _n(e, t, n, o, r) : Ey(e, t, n); }
function wi(e, t, n, o) { e.removeChild(null, t, n, o); }
function Iy(e) { e.textContent = ""; }
function LS(e, t, n) { e.setAttribute(t, "style", n); }
function PS(e, t, n) { n === "" ? e.removeAttribute(t, "class") : e.setAttribute(t, "class", n); }
function Dy(e, t, n) { let { mergedAttrs: o, classes: r, styles: i } = n; o !== null && AN(e, t, o), r !== null && PS(e, t, r), i !== null && LS(e, t, i); }
function FS(e) { let t = g(); e.src = "", e.srcdoc = jo(""), wi(t[N], e); }
var X = (function (e) { return e[e.NONE = 0] = "NONE", e[e.HTML = 1] = "HTML", e[e.STYLE = 2] = "STYLE", e[e.SCRIPT = 3] = "SCRIPT", e[e.URL = 4] = "URL", e[e.RESOURCE_URL = 5] = "RESOURCE_URL", e[e.ATTRIBUTE_NO_BINDING = 6] = "ATTRIBUTE_NO_BINDING", e; })(X || {}), Rr, Qg = "svg", jS = "math", Ty = "", Zg = "*", nd = () => Object.create(null);
function VS() { return Rr || (Rr = nd(), Xt(X.HTML, void 0, [["iframe", ["srcdoc"]], ["*", ["innerHTML", "outerHTML"]]]), Xt(X.STYLE, void 0, [["*", ["style"]]]), Xt(X.URL, void 0, [["*", ["formAction"]], ["area", ["href"]], ["a", ["href", "xlink:href"]], ["form", ["action"]], ["img", ["src"]], ["video", ["src"]]]), Xt(X.URL, jS, [["*", ["href", "xlink:href"]]]), Xt(X.RESOURCE_URL, void 0, [["base", ["href"]], ["embed", ["src"]], ["frame", ["src"]], ["iframe", ["src"]], ["link", ["href"]], ["object", ["codebase", "data"]]]), Xt(X.URL, Qg, [["a", ["href", "xlink:href"]]]), Xt(X.ATTRIBUTE_NO_BINDING, Qg, [["animate", ["attributeName", "values", "to", "from"]], ["set", ["to", "attributeName"]], ["animateMotion", ["attributeName"]], ["animateTransform", ["attributeName"]]]), Xt(X.ATTRIBUTE_NO_BINDING, void 0, [["unknown", ["attributeName", "values", "to", "from", "sandbox", "allow", "allowFullscreen", "referrerPolicy", "csp", "fetchPriority", "credentialless"]], ["iframe", ["sandbox", "allow", "allowFullscreen", "referrerPolicy", "csp", "fetchPriority", "credentialless"]]]), Rr); }
function Xt(e, t, n) { let o = t ?? Ty; for (let [r, i] of n) {
    let s = r.toLowerCase();
    for (let a of i) {
        let c = a.toLowerCase(), l = Rr[c] ??= nd(), u = l[o] ??= nd();
        u[s] = e;
    }
} }
function Yg(e, t, n) { let r = VS()[t.toLowerCase()]; if (!r)
    return X.NONE; let i = e.toLowerCase(), s; if (n) {
    let a = r[n];
    a && (s = a[i] ?? a[Zg]);
} if (s === void 0) {
    let a = r[Ty];
    a && (s = a[i] ?? a[Zg]);
} return s ?? X.NONE; }
function pf(e) { let t = Ni(); return t ? $g(t.sanitize(X.HTML, e) || "") : Vo(e, "HTML") ? $g(Ft(e)) : vy(mi(), b(e)); }
function hf(e) { let t = Ni(); return t ? t.sanitize(X.STYLE, e) || "" : Vo(e, "Style") ? Ft(e) : b(e); }
function gf(e) { let t = Ni(); return t ? t.sanitize(X.URL, e) || "" : Vo(e, "URL") ? Ft(e) : Va(b(e)); }
function Ba(e) { let t = Ni(); if (t)
    return qg(t.sanitize(X.RESOURCE_URL, e) || ""); if (Vo(e, "ResourceURL"))
    return qg(Ft(e)); throw new D(904, !1); }
function mf(e) { let t = Ni(); if (t)
    return Ug(t.sanitize(X.SCRIPT, e) || ""); if (Vo(e, "Script"))
    return Ug(Ft(e)); throw new D(905, !1); }
function Cy(e) { return jo(e[0]); }
function My(e) { return dS(e[0]); }
var HS = { embed: { src: !0 }, frame: { src: !0 }, iframe: { src: !0 }, media: { src: !0 }, base: { href: !0 }, link: { href: !0 }, object: { data: !0, codebase: !0 } };
function BS(e, t) { return HS[e.toLowerCase()]?.[t.toLowerCase()] === !0 ? Ba : gf; }
function wy(e, t, n) { return BS(t, n)(e); }
function Ni() { let e = g(); return e && e[ze].sanitizer; }
var Os = new Set(["href", "xlink:href"]), $S = ["attributeName", "attributename"], US = { iframe: { sandbox: !0, allow: !0, allowfullscreen: !0, referrerpolicy: !0, csp: !0, fetchpriority: !0, credentialless: !0 }, ":svg:animate": { attributename: !0, to: Os, values: Os, from: Os }, ":svg:set": { attributename: !0, to: Os }, ":svg:animatemotion": { attributename: !0 }, ":svg:animatetransform": { attributename: !0 } };
function vf(e, t, n) { let o = t.toLowerCase(), r = n.toLowerCase(), s = le() === -1 ? null : Ve(); if (s && s.type !== 2)
    return e; let a = o[0] !== ":" && s?.namespace ? `:${s.namespace}:${o}` : o, c = US[a]?.[r]; if (!c)
    return e; let l = g(); if (s && o === "iframe") {
    let f = ie(s, l);
    FS(f);
} let u = t[0] === ":" ? t.split(":").pop() : t; if (typeof c != "boolean") {
    if (!s)
        throw new D(-910, !1);
    let f = ie(s, l);
    if (qS(f, c))
        throw new D(-910, !1);
    return e;
} let d = !1; throw new D(-910, d); }
function qS(e, t) { for (let n of $S) {
    let o = e.getAttribute(n);
    if (o !== null && t.has(o.toLowerCase()))
        return o;
} return null; }
function GS() { return Pe([]); }
function Ny(e) { return e.ownerDocument.defaultView; }
function _y(e) { return e.ownerDocument; }
function yf(e) { return e.ownerDocument.body; }
var WS = "\uFFFD";
function xr(e) { return e instanceof Function ? e() : e; }
function zS(e, t, n) { let o = e.length; for (;;) {
    let r = e.indexOf(t, n);
    if (r === -1)
        return r;
    if (r === 0 || e.charCodeAt(r - 1) <= 32) {
        let i = t.length;
        if (r + i === o || e.charCodeAt(r + i) <= 32)
            return r;
    }
    n = r + 1;
} }
var Sy = "ng-template";
function QS(e, t, n, o) { let r = 0; if (o) {
    for (; r < t.length && typeof t[r] == "string"; r += 2)
        if (t[r] === "class" && zS(t[r + 1].toLowerCase(), n, 0) !== -1)
            return !0;
}
else if (Ef(e))
    return !1; if (r = t.indexOf(1, r), r > -1) {
    let i;
    for (; ++r < t.length && typeof (i = t[r]) == "string";)
        if (i.toLowerCase() === n)
            return !0;
} return !1; }
function Ef(e) { return e.type === 4 && e.value !== Sy; }
function ZS(e, t, n) { let o = e.type === 4 && !n ? Sy : e.value; return t === o; }
function YS(e, t, n) { let o = 4, r = e.attrs, i = r !== null ? XS(r) : 0, s = !1; for (let a = 0; a < t.length; a++) {
    let c = t[a];
    if (typeof c == "number") {
        if (!s && !st(o) && !st(c))
            return !1;
        if (s && st(c))
            continue;
        s = !1, o = c | o & 1;
        continue;
    }
    if (!s)
        if (o & 4) {
            if (o = 2 | o & 1, c !== "" && !ZS(e, c, n) || c === "" && t.length === 1) {
                if (st(o))
                    return !1;
                s = !0;
            }
        }
        else if (o & 8) {
            if (r === null || !QS(e, r, c, n)) {
                if (st(o))
                    return !1;
                s = !0;
            }
        }
        else {
            let l = t[++a], u = KS(c, r, Ef(e), n);
            if (u === -1) {
                if (st(o))
                    return !1;
                s = !0;
                continue;
            }
            if (l !== "") {
                let d;
                if (u > i ? d = "" : d = r[u + 1].toLowerCase(), o & 2 && l !== d) {
                    if (st(o))
                        return !1;
                    s = !0;
                }
            }
        }
} return st(o) || s; }
function st(e) { return (e & 1) === 0; }
function KS(e, t, n, o) { if (t === null)
    return -1; let r = 0; if (o || !n) {
    let i = !1;
    for (; r < t.length;) {
        let s = t[r];
        if (s === e)
            return r;
        if (s === 3 || s === 6)
            i = !0;
        else if (s === 1 || s === 2) {
            let a = t[++r];
            for (; typeof a == "string";)
                a = t[++r];
            continue;
        }
        else {
            if (s === 4)
                break;
            if (s === 0) {
                r += 4;
                continue;
            }
        }
        r += i ? 1 : 2;
    }
    return -1;
}
else
    return eb(t, e); }
function by(e, t, n = !1) { for (let o = 0; o < t.length; o++)
    if (YS(e, t[o], n))
        return !0; return !1; }
function JS(e) { let t = e.attrs; if (t != null) {
    let n = t.indexOf(5);
    if ((n & 1) === 0)
        return t[n + 1];
} return null; }
function XS(e) { for (let t = 0; t < e.length; t++) {
    let n = e[t];
    if (iv(n))
        return t;
} return e.length; }
function eb(e, t) { let n = e.indexOf(4); if (n > -1)
    for (n++; n < e.length;) {
        let o = e[n];
        if (typeof o == "number")
            return -1;
        if (o === t)
            return n;
        n++;
    } return -1; }
function tb(e, t) { e: for (let n = 0; n < t.length; n++) {
    let o = t[n];
    if (e.length === o.length) {
        for (let r = 0; r < e.length; r++)
            if (e[r] !== o[r])
                continue e;
        return !0;
    }
} return !1; }
function Kg(e, t) { return e ? ":not(" + t.trim() + ")" : t; }
function nb(e) { let t = e[0], n = 1, o = 2, r = "", i = !1; for (; n < e.length;) {
    let s = e[n];
    if (typeof s == "string")
        if (o & 2) {
            let a = e[++n];
            r += "[" + s + (a.length > 0 ? '="' + a + '"' : "") + "]";
        }
        else
            o & 8 ? r += "." + s : o & 4 && (r += " " + s);
    else
        r !== "" && !st(s) && (t += Kg(i, r), r = ""), o = s, i = i || !st(o);
    n++;
} return r !== "" && (t += Kg(i, r)), t; }
function ob(e) { return e.map(nb).join(","); }
function rb(e) { let t = [], n = [], o = 1, r = 2; for (; o < e.length;) {
    let i = e[o];
    if (typeof i == "string")
        r === 2 ? i !== "" && t.push(i, e[++o]) : r === 8 && n.push(i);
    else {
        if (!st(r))
            break;
        r = i;
    }
    o++;
} return n.length && t.push(1, ...n), t; }
var $ = {}, aa = (function (e) { return e[e.Important = 1] = "Important", e[e.DashCase = 2] = "DashCase", e; })(aa || {}), od;
function If(e, t) { return od(e, t); }
function ib(e) { od === void 0 && (od = e()); }
var Ay = new C("", { factory: () => !1 }), Ry = new C("", { factory: () => sb }), sb = 4e3, ab = !1, Hn = (typeof ngServerMode > "u" || !ngServerMode) && typeof document < "u" && typeof document?.documentElement?.getAnimations == "function";
function $a(e) { return e[k].get(Ay, ab); }
function cb(e, t, n) { let o = Co.get(e); if (o) {
    for (let r of t)
        o.classList.push(r);
    for (let r of n)
        o.cleanupFns.push(r);
}
else
    Co.set(e, { classList: t, cleanupFns: n }); }
function Df(e) { let t = Co.get(e); if (t) {
    for (let n of t.cleanupFns)
        n();
    Co.delete(e);
} wn.delete(e); }
var lb = () => { }, Co = new WeakMap, wn = new WeakMap, Zr = new WeakMap;
function xy(e) { return e ? e[Zt] ?? e : null; }
var kr = new WeakSet;
function rd(e, t) { let n = Zr.get(e); if (n && n.length > 0) {
    let o = n.findIndex(r => r.el === t);
    o > -1 && n.splice(o, 1);
} n?.length === 0 && Zr.delete(e); }
function ub(e, t, n) { let o = Zr.get(e); if (!o || o.length === 0)
    return; let r = t.parentNode, i = t.previousSibling, s = xy(n); for (let a = o.length - 1; a >= 0; a--) {
    let { el: c, declarationView: l } = o[a], u = c.parentNode;
    c === t ? (o.splice(a, 1), kr.add(c), c.dispatchEvent(new CustomEvent("animationend", { detail: { cancel: !0 } }))) : i && c === i ? (o.splice(a, 1), c.dispatchEvent(new CustomEvent("animationend", { detail: { cancel: !0 } })), c.parentNode?.removeChild(c)) : u && r && u !== r && (s === null || l === null || s === l) && (o.splice(a, 1), c.dispatchEvent(new CustomEvent("animationend", { detail: { cancel: !0 } })), c.parentNode?.removeChild(c));
} }
function Tf(e, t, n) { let o = xy(n), r = Zr.get(e); r ? r.some(i => i.el === t) || r.push({ el: t, declarationView: o }) : Zr.set(e, [{ el: t, declarationView: o }]); }
function ca(e) { let t = e[Qe] ??= {}; return t.enter ??= new Map; }
function Sn(e) { let t = e[Qe] ??= {}; return t.leave ??= new Map; }
function ky(e) { let t = typeof e == "function" ? e() : e, n = Array.isArray(t) ? t : null; return typeof t == "string" && (n = t.trim().split(/\s+/).filter(o => o)), n; }
function db(e, t) { if (!Hn)
    return; let n = Co.get(e); if (n && n.classList.length > 0 && fb(e, n.classList))
    for (let o of n.classList)
        t.removeClass(e, o); Df(e); }
function fb(e, t) { for (let n of t)
    if (e.classList.contains(n))
        return !0; return !1; }
function Yr(e) { return e.composedPath ? e.composedPath()[0] : e.target; }
function Cf(e, t) { let n = wn.get(t); return n === void 0 ? !0 : t === Yr(e) && (n.animationName !== void 0 && e.animationName === n.animationName || n.propertyName !== void 0 && (n.propertyName === "all" || e.propertyName === n.propertyName)); }
function Ua(e, t, n) { let o = e.get(t.index) ?? { animateFns: [] }; o.animateFns.push(n), e.set(t.index, o); }
function id(e, t) { if (e)
    for (let n of e)
        n(); for (let n of t)
    n(); }
function sd(e, t) { let n = Sn(e).get(t.index); n && (n.resolvers = void 0); }
function Ls(e, t, n, o, r) { rd(t, n), id(o, r), sd(e, t); }
function la(e) { if (!e)
    return 0; let t = e.toLowerCase().indexOf("ms") > -1 ? 1 : 1e3; return parseFloat(e) * t; }
function Cn(e, t) { return e.getPropertyValue(t).split(",").map(o => o.trim()); }
function pb(e) { let t = Cn(e, "transition-property"), n = Cn(e, "transition-duration"), o = Cn(e, "transition-delay"), r = { propertyName: "", duration: 0, animationName: void 0 }; for (let i = 0; i < t.length; i++) {
    let s = la(o[i]) + la(n[i]);
    s > r.duration && (r.propertyName = t[i], r.duration = s);
} return r; }
function hb(e) { let t = Cn(e, "animation-name"), n = Cn(e, "animation-delay"), o = Cn(e, "animation-duration"), r = Cn(e, "animation-iteration-count"), i = { animationName: "", propertyName: void 0, duration: 0 }; for (let s = 0; s < t.length; s++) {
    let a = la(n[s]) + la(o[s]), c = r[s];
    a > i.duration && c !== "infinite" && (i.animationName = t[s], i.duration = a);
} return i; }
function Oy(e, t) { return e !== void 0 && e.duration > t.duration; }
function Ly(e) { return (e.animationName != null || e.propertyName != null) && e.duration > 0; }
function gb(e, t) { let n = getComputedStyle(e), o = hb(n), r = pb(n), i = o.duration > r.duration ? o : r; Oy(t.get(e), i) || Ly(i) && t.set(e, i); }
function Py(e, t, n) { if (!n)
    return; let o = e.getAnimations(); return o.length === 0 ? gb(e, t) : mb(e, t, o); }
function mb(e, t, n) { let o = { animationName: void 0, propertyName: void 0, duration: 0 }; for (let r of n) {
    let i = r.effect?.getTiming();
    if (i?.iterations === 1 / 0)
        continue;
    let s = typeof i?.duration == "number" ? i.duration : 0, a = (i?.delay ?? 0) + s, c = r.playbackRate;
    c !== void 0 && c !== 0 && c !== 1 && (a /= Math.abs(c));
    let l, u;
    r.animationName ? u = r.animationName : l = r.transitionProperty, a >= o.duration && (o = { animationName: u, propertyName: l, duration: a });
} Oy(t.get(e), o) || Ly(o) && t.set(e, o); }
var rn = new Set, qa = (function (e) { return e[e.CHANGE_DETECTION = 0] = "CHANGE_DETECTION", e[e.AFTER_NEXT_RENDER = 1] = "AFTER_NEXT_RENDER", e; })(qa || {}), Bn = new C(""), Jg = new Set;
function te(e) { Jg.has(e) || (Jg.add(e), performance?.mark?.("mark_feature_usage", { detail: { feature: e } })); }
var Ga = (() => { class e {
    impl = null;
    execute() { this.impl?.execute(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })(), Mf = [0, 1, 2, 3], wf = (() => { class e {
    ngZone = E(G);
    scheduler = E(qe);
    errorHandler = E(Mt, { optional: !0 });
    sequences = new Set;
    deferredRegistrations = new Set;
    executing = !1;
    constructor() { E(Bn, { optional: !0 }); }
    execute() { let n = this.sequences.size > 0; n && H(L.AfterRenderHooksStart), this.executing = !0; for (let o of Mf)
        for (let r of this.sequences)
            if (!(r.erroredOrDestroyed || !r.hooks[o]))
                try {
                    r.pipelinedValue = this.ngZone.runOutsideAngular(() => this.maybeTrace(() => { let i = r.hooks[o]; return i(r.pipelinedValue); }, r.snapshot));
                }
                catch (i) {
                    r.erroredOrDestroyed = !0, this.errorHandler?.handleError(i);
                } this.executing = !1; for (let o of this.sequences)
        o.afterRun(), o.once && (this.sequences.delete(o), o.destroy()); for (let o of this.deferredRegistrations)
        this.sequences.add(o); this.deferredRegistrations.size > 0 && this.scheduler.notify(7), this.deferredRegistrations.clear(), n && H(L.AfterRenderHooksEnd); }
    register(n) { let { view: o } = n; o !== void 0 ? ((o[mn] ??= []).push(n), En(o), o[w] |= 8192) : this.executing ? this.deferredRegistrations.add(n) : this.addSequence(n); }
    addSequence(n) { this.sequences.add(n), this.scheduler.notify(7); }
    unregister(n) { this.executing && this.sequences.has(n) ? (n.erroredOrDestroyed = !0, n.pipelinedValue = void 0, n.once = !0) : (this.sequences.delete(n), this.deferredRegistrations.delete(n)); }
    maybeTrace(n, o) { return o ? o.run(qa.AFTER_NEXT_RENDER, n) : n(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })(), Kr = class {
    impl;
    hooks;
    view;
    once;
    snapshot;
    erroredOrDestroyed = !1;
    pipelinedValue = void 0;
    unregisterOnDestroy;
    constructor(t, n, o, r, i, s = null) { this.impl = t, this.hooks = n, this.view = o, this.once = r, this.snapshot = s, this.unregisterOnDestroy = i?.onDestroy(() => this.destroy()); }
    afterRun() { this.erroredOrDestroyed = !1, this.pipelinedValue = void 0, this.snapshot?.dispose(), this.snapshot = null; }
    destroy() { this.impl.unregister(this), this.unregisterOnDestroy?.(); let t = this.view?.[mn]; t && (this.view[mn] = t.filter(n => n !== this)); }
};
function Fy(e, t) { let n = t?.injector ?? E(oe); return typeof ngServerMode < "u" && ngServerMode ? Wa : (te("NgAfterRender"), jy(e, n, t, !1)); }
function Nf(e, t) { let n = t?.injector ?? E(oe); return typeof ngServerMode < "u" && ngServerMode ? Wa : (te("NgAfterNextRender"), jy(e, n, t, !0)); }
function vb(e) { return e instanceof Function ? [void 0, void 0, e, void 0] : [e.earlyRead, e.write, e.mixedReadWrite, e.read]; }
function jy(e, t, n, o) { let r = t.get(Ga); r.impl ??= t.get(wf); let i = t.get(Bn, null, { optional: !0 }), s = n?.manualCleanup !== !0 ? t.get(Re) : null, a = t.get(io, null, { optional: !0 }), c = new Kr(r.impl, vb(e), a?.view, o, s, i?.snapshot(null)); return r.impl.register(c), c; }
var Wa = { destroy() { } }, _i = new C("", { factory: () => { let e = E(be), t = new Set; return e.onDestroy(() => t.clear()), { queue: t, isScheduled: !1, scheduler: null, injector: e }; } });
function Vy(e, t, n) { let o = e.get(_i); if (Array.isArray(t))
    for (let r of t)
        o.queue.add(r), n?.detachedLeaveAnimationFns?.push(r);
else
    o.queue.add(t), n?.detachedLeaveAnimationFns?.push(t); o.scheduler && o.scheduler(e); }
function yb(e, t) { let n = e.get(_i); if (Array.isArray(t))
    for (let o of t)
        n.queue.delete(o);
else
    n.queue.delete(t); }
function Eb(e, t) { let n = e.get(_i); if (t.detachedLeaveAnimationFns) {
    for (let o of t.detachedLeaveAnimationFns)
        n.queue.delete(o);
    t.detachedLeaveAnimationFns = void 0;
} }
function Ib(e) { let t = e.get(_i); t.isScheduled || (Nf(() => { t.isScheduled = !1; for (let n of t.queue)
    n(); t.queue.clear(); }, { injector: t.injector }), t.isScheduled = !0); }
function za(e) { let t = e.get(_i); t.scheduler = Ib, t.scheduler(e); }
function _f(e, t) { for (let [n, o] of t)
    Vy(e, o.animateFns); }
function Xg(e, t, n, o) { let r = e?.[Qe]?.enter; t !== null && r && r.has(n.index) && _f(o, r); }
function em(e, t, n, o) { try {
    n.get(yr);
}
catch {
    return o(!1);
} let r = e?.[Qe]; r?.enter?.has(t.index) && yb(n, r.enter.get(t.index).animateFns); let i = Db(e, t, r); if (i.size === 0) {
    let s = !1;
    if (e) {
        let a = [];
        Qa(e, t, a), s = a.length > 0;
    }
    if (!s)
        return o(!1);
} e && rn.add(e[Fe]), Vy(n, () => Tb(e, t, r || void 0, i, o), r || void 0); }
function Db(e, t, n) { let o = new Map, r = n?.leave; if (r && r.has(t.index) && o.set(t.index, r.get(t.index)), e && r)
    for (let [i, s] of r) {
        if (o.has(i))
            continue;
        let c = e[m].data[i].parent;
        for (; c;) {
            if (c === t) {
                o.set(i, s);
                break;
            }
            c = c.parent;
        }
    } return o; }
function Tb(e, t, n, o, r) { let i = []; if (n && n.leave)
    for (let [s] of o) {
        if (!n.leave.has(s))
            continue;
        let a = n.leave.get(s);
        for (let c of a.animateFns) {
            let { promise: l } = c();
            i.push(l);
        }
        n.detachedLeaveAnimationFns = void 0;
    } if (e && Qa(e, t, i), i.length > 0) {
    let s = n || e?.[Qe];
    if (s) {
        let a = s.running;
        a && i.push(a), s.running = Promise.allSettled(i), Mb(e, s.running, r);
    }
    else
        Promise.allSettled(i).then(() => { e && rn.delete(e[Fe]), r(!0); });
}
else
    e && rn.delete(e[Fe]), r(!1); }
function Qa(e, t, n) { if (t.type & 12) {
    let r = e[t.index];
    if (K(r))
        for (let i = U; i < r.length; i++) {
            let s = r[i];
            s[m].type === 2 && Cb(s, n);
        }
} let o = t.child; for (; o;)
    Qa(e, o, n), o = o.next; }
function Cb(e, t) { let n = e[Qe]; if (n && n.leave)
    for (let r of n.leave.values())
        for (let i of r.animateFns) {
            let { promise: s } = i();
            t.push(s);
        } let o = e[m].firstChild; for (; o;)
    Qa(e, o, t), o = o.next; }
function Mb(e, t, n) { t.then(() => { e[Qe]?.running === t && (e[Qe].running = void 0, rn.delete(e[Fe])), n(!0); }); }
function go(e, t, n, o, r, i, s, a) { if (r != null) {
    let c, l = !1;
    K(r) ? c = r : J(r) && (l = !0, r = r[B]);
    let u = O(r);
    e === 0 && o !== null ? (Xg(a, o, i, n), s == null ? Ey(t, o, u) : _n(t, o, u, s || null, !0)) : e === 1 && o !== null ? (Xg(a, o, i, n), _n(t, o, u, s || null, !0), ub(i, u, a)) : e === 2 ? (a?.[Qe]?.leave?.has(i.index) && Tf(i, u, a), kr.delete(u), em(a, i, n, d => { if (kr.has(u)) {
        kr.delete(u);
        return;
    } wi(t, u, l, d); })) : e === 3 && (kr.delete(u), em(a, i, n, () => { t.destroyNode(u); })), c != null && Ab(t, e, n, c, i, o, s);
} }
function Hy(e, t) { By(e, t), t[B] = null, t[ce] = null; }
function wb(e, t, n, o, r, i) { o[B] = r, o[ce] = t, Za(e, o, n, 1, r, i); }
function By(e, t) { t[ze].changeDetectionScheduler?.notify(9), Za(e, t, t[N], 2, null, null); }
function Nb(e) { let t = e[Qt]; if (!t)
    return gu(e[m], e); for (; t;) {
    let n = null;
    if (J(t))
        n = t[Qt];
    else {
        let o = t[U];
        o && (n = o);
    }
    if (!n) {
        for (; t && !t[ge] && t !== e;)
            J(t) && gu(t[m], t), t = t[z];
        t === null && (t = e), J(t) && gu(t[m], t), n = t && t[ge];
    }
    t = n;
} }
function Sf(e, t) { let n = e[vn], o = n.indexOf(t); n.splice(o, 1); }
function Si(e, t) { if (ut(t))
    return; let n = t[N]; n.destroyNode && Za(e, t, n, 3, null, null), Nb(t); }
function gu(e, t) { if (ut(t))
    return; let n = x(null); try {
    t[w] &= -129, t[w] |= 256, t[Ae] && $t(t[Ae]), Sb(e, t), _b(e, t), t[m].type === 1 && t[N].destroy();
    let o = t[Yt];
    if (o !== null && K(t[z])) {
        o !== t[z] && Sf(o, t);
        let r = t[lt];
        r !== null && r.detachView(e);
    }
    ju(t);
}
finally {
    x(n);
} }
function _b(e, t) { let n = e.cleanup, o = t[zt]; if (n !== null)
    for (let s = 0; s < n.length - 1; s += 2)
        if (typeof n[s] == "string") {
            let a = n[s + 3];
            a >= 0 ? o[a]() : o[-a].unsubscribe(), s += 2;
        }
        else {
            let a = o[n[s + 1]];
            n[s].call(a);
        } o !== null && (t[zt] = null); let r = t[Tt]; if (r !== null) {
    t[Tt] = null;
    for (let s = 0; s < r.length; s++) {
        let a = r[s];
        a();
    }
} let i = t[qt]; if (i !== null) {
    t[qt] = null;
    for (let s of i)
        s.destroy();
} }
function Sb(e, t) { let n; if (e != null && (n = e.destroyHooks) != null)
    for (let o = 0; o < n.length; o += 2) {
        let r = t[n[o]];
        if (!(r instanceof Nn)) {
            let i = n[o + 1];
            if (Array.isArray(i))
                for (let s = 0; s < i.length; s += 2) {
                    let a = r[i[s]], c = i[s + 1];
                    H(L.LifecycleHookStart, a, c);
                    try {
                        c.call(a);
                    }
                    finally {
                        H(L.LifecycleHookEnd, a, c);
                    }
                }
            else {
                H(L.LifecycleHookStart, r, i);
                try {
                    i.call(r);
                }
                finally {
                    H(L.LifecycleHookEnd, r, i);
                }
            }
        }
    } }
function bf(e, t, n) { return $y(e, t.parent, n); }
function $y(e, t, n) { let o = t; for (; o !== null && o.type & 168;)
    t = o, o = t.parent; if (o === null)
    return n[B]; if (Ce(o)) {
    let { encapsulation: r } = e.data[o.directiveStart + o.componentOffset];
    if (r === Ke.None || r === Ke.Emulated)
        return null;
} return ie(o, n); }
function Uy(e, t, n) { return Gy(e, t, n); }
function qy(e, t, n) { return e.type & 40 ? ie(e, n) : null; }
var Gy = qy, ad;
function Wy(e, t) { Gy = e, ad = t; }
function Af(e, t, n, o) { let r = bf(e, o, t), i = t[N], s = o.parent || t[ce], a = Uy(s, o, t); if (r != null)
    if (Array.isArray(n))
        for (let c = 0; c < n.length; c++)
            zg(i, r, n[c], a, !1);
    else
        zg(i, r, n, a, !1); ad !== void 0 && ad(i, o, t, n, r); }
function Mn(e, t) { if (t !== null) {
    let n = t.type;
    if (n & 3)
        return ie(t, e);
    if (n & 4)
        return cd(-1, e[t.index]);
    if (n & 8) {
        let o = t.child;
        if (o !== null)
            return Mn(e, o);
        {
            let r = e[t.index];
            return K(r) ? cd(-1, r) : O(r);
        }
    }
    else {
        if (n & 128)
            return Mn(e, t.next);
        if (n & 32)
            return If(t, e)() || O(e[t.index]);
        {
            let o = zy(e, t);
            if (o !== null) {
                if (Array.isArray(o))
                    return o[0];
                let r = Ue(e[re]);
                return Mn(r, o);
            }
            else
                return Mn(e, t.next);
        }
    }
} return null; }
function zy(e, t) { if (t !== null) {
    let o = e[re][ce], r = t.projection;
    return o.projection[r];
} return null; }
function cd(e, t) { let n = U + e + 1; if (n < t.length) {
    let o = t[n], r = o[m].firstChild;
    if (r !== null)
        return Mn(o, r);
} return t[ot]; }
function Rf(e, t, n, o, r, i, s) { for (; n != null;) {
    let a = o[k];
    if (n.type === 128) {
        n = n.next;
        continue;
    }
    let c = o[n.index], l = n.type;
    if (s && t === 0 && (c && Ye(O(c), o), n.flags |= 2), !Fo(n))
        if (l & 8)
            Rf(e, t, n.child, o, r, i, !1), go(t, e, a, r, c, n, i, o);
        else if (l & 32) {
            let u = If(n, o), d;
            for (; d = u();)
                go(t, e, a, r, d, n, i, o);
            go(t, e, a, r, c, n, i, o);
        }
        else
            l & 16 ? Qy(e, t, o, n, r, i) : go(t, e, a, r, c, n, i, o);
    n = s ? n.projectionNext : n.next;
} }
function Za(e, t, n, o, r, i) { Rf(n, o, e.firstChild, t, r, i, !1); }
function bb(e, t, n) { let o = t[N], r = bf(e, n, t), i = n.parent || t[ce], s = Uy(i, n, t); Qy(o, 0, t, n, r, s); }
function Qy(e, t, n, o, r, i) { let s = n[re], c = s[ce].projection[o.projection]; if (Array.isArray(c))
    for (let l = 0; l < c.length; l++) {
        let u = c[l];
        go(t, e, n[k], r, u, o, i, n);
    }
else {
    let l = c, u = s[z];
    zr(o) && (l.flags |= 128), Rf(e, t, l, u, r, i, !0);
} }
function Ab(e, t, n, o, r, i, s) { let a = o[ot], c = O(o); a !== c && go(t, e, n, i, a, r, s); for (let l = U; l < o.length; l++) {
    let u = o[l];
    Za(u[m], u, e, t, i, a);
} }
function Rb(e, t, n, o, r) { if (t)
    r ? e.addClass(n, o) : e.removeClass(n, o);
else {
    let i = o.indexOf("-") === -1 ? void 0 : aa.DashCase;
    r == null ? e.removeStyle(n, o, i) : (typeof r == "string" && r.endsWith("!important") && (r = r.slice(0, -10), i |= aa.Important), e.setStyle(n, o, r, i));
} }
function xf(e, t, n, o, r, i, s, a, c, l, u) { let d = I + o, f = d + r, p = xb(d, f), h = typeof l == "function" ? l() : l; return p[m] = { type: e, blueprint: p, template: n, queries: null, viewQuery: a, declTNode: t, data: p.slice().fill(null, d), bindingStartIndex: d, expandoStartIndex: f, hostBindingOpCodes: null, firstCreatePass: !0, firstUpdatePass: !0, staticViewQueries: !1, staticContentQueries: !1, preOrderHooks: null, preOrderCheckHooks: null, contentHooks: null, contentCheckHooks: null, viewHooks: null, viewCheckHooks: null, destroyHooks: null, cleanup: null, contentQueries: null, components: null, directiveRegistry: typeof i == "function" ? i() : i, pipeRegistry: typeof s == "function" ? s() : s, firstChild: null, schemas: c, consts: h, incompleteFirstPass: !1, ssrId: u }; }
function xb(e, t) { let n = []; for (let o = 0; o < t; o++)
    n.push(o < e ? null : $); return n; }
function Zy(e) { let t = e.tView; return t === null || t.incompleteFirstPass ? e.tView = xf(1, null, e.template, e.decls, e.vars, e.directiveDefs, e.pipeDefs, e.viewQuery, e.schemas, e.consts, e.id) : t; }
function Ya(e, t, n, o, r, i, s, a, c, l, u) { let d = t.blueprint.slice(); return d[B] = r, d[w] = o | 4 | 128 | 8 | 64 | 1024, (l !== null || e && e[w] & 2048) && (d[w] |= 2048), Rl(d), d[z] = d[Zt] = e, d[j] = n, d[ze] = s || e && e[ze], d[N] = a || e && e[N], d[k] = c || e && e[k] || null, d[ce] = i, d[Fe] = l_(), d[fe] = u, d[Ml] = l, d[re] = t.type == 2 ? e[re] : d, d; }
function kb(e, t, n) { let o = ie(t, e), r = Zy(n), i = e[ze].rendererFactory, s = Of(e, Ya(e, r, null, kf(n), o, t, null, i.createRenderer(o, n), null, null, null)); return e[t.index] = s; }
function kf(e) { let t = 16; return e.signals ? t = 4096 : e.onPush && (t = 64), t; }
function bi(e, t, n, o) { if (n === 0)
    return -1; let r = t.length; for (let i = 0; i < n; i++)
    t.push(o), e.blueprint.push(o), e.data.push(null); return r; }
function Of(e, t) { return e[Qt] ? e[Ir][ge] = t : e[Qt] = t, e[Ir] = t, t; }
function Yy(e = 1) { Ky(A(), g(), le() + e, !1); }
function Ky(e, t, n, o) { if (!o)
    if ((t[w] & 3) === 3) {
        let i = e.preOrderCheckHooks;
        i !== null && Hs(t, i, n);
    }
    else {
        let i = e.preOrderHooks;
        i !== null && Bs(t, i, 0, n);
    } ht(n); }
var Ka = (function (e) { return e[e.None = 0] = "None", e[e.SignalBased = 1] = "SignalBased", e[e.HasDecoratorInputTransform = 2] = "HasDecoratorInputTransform", e; })(Ka || {});
function bn(e, t, n, o) { let r = x(null); try {
    let [i, s, a] = e.inputs[n], c = null;
    (s & Ka.SignalBased) !== 0 && (c = t[i][ae]), c !== null && c.transformFn !== void 0 ? o = c.transformFn(o) : a !== null && (o = a.call(t, o)), e.setInput !== null ? e.setInput(t, c, o, n, i) : Jm(t, c, i, o);
}
finally {
    x(r);
} }
function Jy(e, t, n, o, r) { let i = le(), s = o & 2; try {
    ht(-1), s && t.length > I && Ky(e, t, I, !1);
    let a = s ? L.TemplateUpdateStart : L.TemplateCreateStart;
    H(a, r, n), n(o, r);
}
finally {
    ht(i);
    let a = s ? L.TemplateUpdateEnd : L.TemplateCreateEnd;
    H(a, r, n);
} }
function Ja(e, t, n) { jb(e, t, n), (n.flags & 64) === 64 && Vb(e, t, n); }
function Ho(e, t, n = ie) { let o = t.localNames; if (o !== null) {
    let r = t.index + 1;
    for (let i = 0; i < o.length; i += 2) {
        let s = o[i + 1], a = s === -1 ? n(t, e) : e[s];
        e[r++] = a;
    }
} }
function Ob(e, t, n, o) { let i = o.get(Yd, jv) || n === Ke.ShadowDom || n === Ke.ExperimentalIsolatedShadowDom, s = e.selectRootElement(t, i); if (s.tagName.toLowerCase() === "script")
    throw new D(905, !1); return Lb(s), s; }
function Lb(e) { Xy(e); }
var Xy = () => null;
function Pb(e) { wv(e) ? Iy(e) : $_(e); }
function eE() { Xy = Pb; }
function Fb(e) { return e === "class" ? "className" : e === "for" ? "htmlFor" : e === "formaction" ? "formAction" : e === "innerHtml" ? "innerHTML" : e === "readonly" ? "readOnly" : e === "tabindex" ? "tabIndex" : e; }
function Lf(e, t, n, o, r, i) { let s = t[m]; if (nc(e, s, t, n, o)) {
    Ce(e) && tE(t, e.index);
    return;
} e.type & 3 && (n = Fb(n)), Pf(e, t, n, o, r, i); }
function Pf(e, t, n, o, r, i) { if (e.type & 3) {
    let s = ie(e, t);
    o = i != null ? i(o, e.value || "", n) : o, r.setProperty(s, n, o);
}
else
    e.type & 12; }
function tE(e, t) { let n = me(t, e); n[w] & 16 || (n[w] |= 64); }
function jb(e, t, n) { let o = n.directiveStart, r = n.directiveEnd; Ce(n) && kb(t, n, e.data[o + n.componentOffset]), e.firstCreatePass || Xs(n, t); let i = n.initialInputs; for (let s = o; s < r; s++) {
    let a = e.data[s], c = Wr(t, e, s, n);
    if (Ye(c, t), i !== null && $b(t, s - o, c, a, n, i), Ze(a)) {
        let l = me(n.index, t);
        l[j] = Wr(t, e, s, n);
    }
} }
function Vb(e, t, n) { let o = n.directiveStart, r = n.directiveEnd, i = n.index, s = gg(); try {
    ht(i);
    for (let a = o; a < r; a++) {
        let c = e.data[a], l = t[a];
        ys(a), (c.hostBindings !== null || c.hostVars !== 0 || c.hostAttrs !== null) && Hb(c, l);
    }
}
finally {
    ht(-1), ys(s);
} }
function Hb(e, t) { e.hostBindings !== null && e.hostBindings(1, t); }
function Ff(e, t) { let n = e.directiveRegistry, o = null; if (n)
    for (let r = 0; r < n.length; r++) {
        let i = n[r];
        by(t, i.selectors, !1) && (o ??= [], Ze(i) ? o.unshift(i) : o.push(i));
    } return o; }
function Bb(e, t, n, o, r, i) { let s = ie(e, t); Xa(t[N], s, i, e.value, n, o, r); }
function Xa(e, t, n, o, r, i, s) { if (i == null)
    s?.(i, o || "", r), e.removeAttribute(t, r, n);
else {
    let a = s == null ? b(i) : s(i, o || "", r);
    e.setAttribute(t, r, a, n);
} }
function $b(e, t, n, o, r, i) { let s = i[t]; if (s !== null)
    for (let a = 0; a < s.length; a += 2) {
        let c = s[a], l = s[a + 1];
        bn(o, n, c, l);
    } }
function ec(e, t, n, o, r) { let i = I + n, s = t[m], a = r(s, t, e, o, n); t[i] = a, dt(e, !0); let c = e.type === 2; return c ? (Dy(t[N], a, e), (ug() === 0 || Xn(e)) && Ye(a, t), dg()) : Ye(a, t), _r() && (!c || !Fo(e)) && Af(s, t, a, e), e; }
function tc(e) { let t = e; return Ul() ? ql() : (t = t.parent, dt(t, !1)), t; }
function nE(e, t, n) { return (e === null || Ze(e)) && (n = Tr(n[t.index])), n[N]; }
function jf(e, t) { let n = e[k]; if (!n)
    return; let o; try {
    o = n.get(_t, null);
}
catch {
    o = null;
} o?.(t); }
function nc(e, t, n, o, r) { let i = e.inputs?.[o], s = e.hostDirectiveInputs?.[o], a = !1; if (s)
    for (let c = 0; c < s.length; c += 2) {
        let l = s[c], u = s[c + 1], d = t.data[l];
        bn(d, n[l], u, r), a = !0;
    } if (i)
    for (let c of i) {
        let l = n[c], u = t.data[c];
        bn(u, l, o, r), a = !0;
    } return a; }
function oE(e, t, n, o, r, i) { let s = null, a = null, c = null, l = !1, u = e.directiveToIndex.get(o.type); if (typeof u == "number" ? s = u : [s, a, c] = u, a !== null && c !== null && e.hostDirectiveInputs?.hasOwnProperty(r)) {
    let d = e.hostDirectiveInputs[r];
    for (let f = 0; f < d.length; f += 2) {
        let p = d[f];
        if (p >= a && p <= c) {
            let h = t.data[p], v = d[f + 1];
            bn(h, n[p], v, i), l = !0;
        }
        else if (p > c)
            break;
    }
} return s !== null && o.inputs.hasOwnProperty(r) && (bn(o, n[s], r, i), l = !0), l; }
function Ub(e, t) { let n = me(t, e), o = n[m]; qb(o, n); let r = n[B]; r !== null && n[fe] === null && (n[fe] = Jv(r, n[k])), H(L.ComponentStart); try {
    oc(o, n, n[j]);
}
finally {
    H(L.ComponentEnd, n[j]);
} }
function qb(e, t) { for (let n = t.length; n < e.blueprint.length; n++)
    t.push(e.blueprint[n]); }
function oc(e, t, n) { Ds(t); try {
    let o = e.viewQuery;
    o !== null && qu(1, o, n);
    let r = e.template;
    r !== null && Jy(e, t, r, 1, n), e.firstCreatePass && (e.firstCreatePass = !1), t[lt]?.finishViewCreation(e), e.staticContentQueries && sy(e, t), e.staticViewQueries && qu(2, e.viewQuery, n);
    let i = e.components;
    i !== null && Gb(t, i);
}
catch (o) {
    throw e.firstCreatePass && (e.incompleteFirstPass = !0, e.firstCreatePass = !1), o;
}
finally {
    t[w] &= -5, Ts();
} }
function Gb(e, t) { for (let n = 0; n < t.length; n++)
    Ub(e, t[n]); }
function Bo(e, t, n, o) { let r = x(null); try {
    let i = t.tView, a = e[w] & 4096 ? 4096 : 16, c = Ya(e, i, n, a, null, t, null, null, o?.injector ?? null, o?.embeddedViewInjector ?? null, o?.dehydratedView ?? null), l = e[t.index];
    c[Yt] = l;
    let u = e[lt];
    return u !== null && (c[lt] = u.createEmbeddedView(i)), oc(i, c, n), c;
}
finally {
    x(r);
} }
function An(e, t) { return !t || t.firstChild === null || zr(e); }
function Mo(e, t, n, o, r = !1) { for (; n !== null;) {
    if (n.type === 128) {
        n = r ? n.projectionNext : n.next;
        continue;
    }
    let i = t[n.index];
    i !== null && o.push(O(i)), K(i) && rc(i, o);
    let s = n.type;
    if (s & 8)
        Mo(e, t, n.child, o);
    else if (s & 32) {
        let a = If(n, t), c;
        for (; c = a();)
            o.push(c);
    }
    else if (s & 16) {
        let a = zy(t, n);
        if (Array.isArray(a))
            o.push(...a);
        else {
            let c = Ue(t[re]);
            Mo(c[m], c, a, o, !0);
        }
    }
    n = r ? n.projectionNext : n.next;
} return o; }
function rc(e, t) { for (let n = U; n < e.length; n++) {
    let o = e[n], r = o[m].firstChild;
    r !== null && Mo(o[m], o, r, t);
} e[ot] !== e[B] && t.push(e[ot]); }
function rE(e) { if (e[mn] !== null) {
    for (let t of e[mn])
        t.impl.addSequence(t);
    e[mn].length = 0;
} }
var iE = [];
function Wb(e) { return e[Ae] ?? zb(e); }
function zb(e) { let t = iE.pop() ?? Object.create(Zb); return t.lView = e, t; }
function Qb(e) { e.lView[Ae] !== e && (e.lView = null, iE.push(e)); }
var Zb = Ie(q({}, Qc), { consumerIsAlwaysLive: !0, kind: "template", consumerMarkedDirty: e => { En(e.lView); }, consumerOnSignalRead() { this.lView[Ae] = this; } });
function Yb(e) { let t = e[Ae] ?? Object.create(Kb); return t.lView = e, t; }
var Kb = Ie(q({}, Qc), { consumerIsAlwaysLive: !0, kind: "template", consumerMarkedDirty: e => { let t = Ue(e.lView); for (; t && !sE(t[m]);)
        t = Ue(t); t && Mr(t); }, consumerOnSignalRead() { this.lView[Ae] = this; } });
function sE(e) { return e.type !== 2; }
function aE(e) { if (e[qt] === null)
    return; let t = !0; for (; t;) {
    let n = !1;
    for (let o of e[qt])
        o.dirty && (n = !0, o.zone === null || Zone.current === o.zone ? o.run() : o.zone.run(() => o.run()));
    t = n && !!(e[w] & 8192);
} }
var Jb = 100;
function cE(e, t = 0) { let o = e[ze].rendererFactory, r = !1; r || o.begin?.(); try {
    Xb(e, t);
}
finally {
    r || o.end?.();
} }
function Xb(e, t) { let n = Wl(); try {
    tr(!0), ld(e, t);
    let o = 0;
    for (; eo(e);) {
        if (o === Jb)
            throw new D(103, !1);
        o++, ld(e, 1);
    }
}
finally {
    tr(n);
} }
function lE(e, t, n, o) { if (ut(t))
    return; let r = t[w], i = !1, s = !1; Ds(t); let a = !0, c = null, l = null; i || (sE(e) ? (l = Wb(t), c = Yo(l)) : Gi() === null ? (a = !1, l = Yb(t), c = Yo(l)) : t[Ae] && ($t(t[Ae]), t[Ae] = null)); try {
    Rl(t), zl(e.bindingStartIndex), n !== null && Jy(e, t, n, 2, o);
    let u = (r & 3) === 3;
    if (!i)
        if (u) {
            let p = e.preOrderCheckHooks;
            p !== null && Hs(t, p, null);
        }
        else {
            let p = e.preOrderHooks;
            p !== null && Bs(t, p, 0, null), lu(t, 0);
        }
    if (s || eA(t), aE(t), uE(t, 0), e.contentQueries !== null && sy(e, t), !i)
        if (u) {
            let p = e.contentCheckHooks;
            p !== null && Hs(t, p);
        }
        else {
            let p = e.contentHooks;
            p !== null && Bs(t, p, 1), lu(t, 1);
        }
    nA(e, t);
    let d = e.components;
    d !== null && fE(t, d, 0);
    let f = e.viewQuery;
    if (f !== null && qu(2, f, o), !i)
        if (u) {
            let p = e.viewCheckHooks;
            p !== null && Hs(t, p);
        }
        else {
            let p = e.viewHooks;
            p !== null && Bs(t, p, 2), lu(t, 2);
        }
    if (e.firstUpdatePass === !0 && (e.firstUpdatePass = !1), t[ps]) {
        for (let p of t[ps])
            p();
        t[ps] = null;
    }
    i || (rE(t), t[w] &= -73);
}
catch (u) {
    throw i || En(t), u;
}
finally {
    l !== null && (zi(l, c), a && Qb(l)), Ts();
} }
function uE(e, t) { for (let n = Av(e); n !== null; n = Rv(n))
    for (let o = U; o < n.length; o++) {
        let r = n[o];
        dE(r, t);
    } }
function eA(e) { for (let t = Av(e); t !== null; t = Rv(t)) {
    if (!(t[w] & 2))
        continue;
    let n = t[vn];
    for (let o = 0; o < n.length; o++) {
        let r = n[o];
        Mr(r);
    }
} }
function tA(e, t, n) { H(L.ComponentStart); let o = me(t, e); try {
    dE(o, n);
}
finally {
    H(L.ComponentEnd, o[j]);
} }
function dE(e, t) { hs(e) && ld(e, t); }
function ld(e, t) { let o = e[m], r = e[w], i = e[Ae], s = !!(t === 0 && r & 16); if (s ||= !!(r & 64 && t === 0), s ||= !!(r & 1024), s ||= !!(i?.dirty && Qi(i)), s ||= !1, i && (i.dirty = !1), e[w] &= -9217, s)
    lE(o, e, o.template, e[j]);
else if (r & 8192) {
    let a = x(null);
    try {
        aE(e), uE(e, 1);
        let c = o.components;
        c !== null && fE(e, c, 1), rE(e);
    }
    finally {
        x(a);
    }
} }
function fE(e, t, n) { for (let o = 0; o < t.length; o++)
    tA(e, t[o], n); }
function nA(e, t) { let n = e.hostBindingOpCodes; if (n !== null)
    try {
        for (let o = 0; o < n.length; o++) {
            let r = n[o];
            if (r < 0)
                ht(~r);
            else {
                let i = r, s = n[++o], a = n[++o];
                hg(s, i);
                let c = t[i];
                H(L.HostBindingsUpdateStart, c);
                try {
                    a(2, c);
                }
                finally {
                    H(L.HostBindingsUpdateEnd, c);
                }
            }
        }
    }
    finally {
        ht(-1);
    } }
function ic(e, t) { let n = Wl() ? 64 : 1088; for (e[ze].changeDetectionScheduler?.notify(t); e;) {
    e[w] |= n;
    let o = Ue(e);
    if (rt(e) && !o)
        return e;
    e = o;
} return null; }
function pE(e, t, n, o) { return [e, !0, 0, t, null, o, null, n, null, null]; }
function hE(e, t) { let n = U + t; if (n < e.length)
    return e[n]; }
function $o(e, t, n, o = !0) { let r = t[m]; if (oA(r, t, e, n), o) {
    let s = cd(n, e), a = t[N], c = a.parentNode(e[ot]);
    c !== null && wb(r, e[ce], a, t, c, s);
} let i = t[fe]; i !== null && i.firstChild !== null && (i.firstChild = null); }
function Vf(e, t) { let n = Jr(e, t); return n !== void 0 && Si(n[m], n), n; }
function Jr(e, t) { if (e.length <= U)
    return; let n = U + t, o = e[n]; if (o) {
    let r = o[Yt];
    r !== null && r !== e && Sf(r, o), t > 0 && (e[n - 1][ge] = o[ge]);
    let i = gr(e, U + t);
    Hy(o[m], o);
    let s = i[lt];
    s !== null && s.detachView(i[m]), o[z] = null, o[ge] = null, o[w] &= -129;
} return o; }
function oA(e, t, n, o) { let r = U + o, i = n.length; o > 0 && (n[r - 1][ge] = t), o < i - U ? (t[ge] = n[r], vl(n, U + o, t)) : (n.push(t), t[ge] = null), t[z] = n; let s = t[Yt]; s !== null && n !== s && gE(s, t); let a = t[lt]; a !== null && a.insertView(e), gs(t), t[w] |= 128; }
function gE(e, t) { let n = e[vn], o = t[z]; if (J(o))
    e[w] |= 2;
else {
    let r = o[z][re];
    t[re] !== r && (e[w] |= 2);
} n === null ? e[vn] = [t] : n.push(t); }
var sn = class {
    _lView;
    _cdRefInjectingView;
    _appRef = null;
    _attachedToViewContainer = !1;
    exhaustive;
    get rootNodes() { let t = this._lView, n = t[m]; return Mo(n, t, n.firstChild, []); }
    constructor(t, n) { this._lView = t, this._cdRefInjectingView = n; }
    get context() { return this._lView[j]; }
    set context(t) { this._lView[j] = t; }
    get destroyed() { return ut(this._lView); }
    destroy() { if (this._appRef)
        this._appRef.detachView(this);
    else if (this._attachedToViewContainer) {
        let t = this._lView[z];
        if (K(t)) {
            let n = t[Dr], o = n ? n.indexOf(this) : -1;
            o > -1 && (Jr(t, o), gr(n, o));
        }
        this._attachedToViewContainer = !1;
    } Si(this._lView[m], this._lView); }
    onDestroy(t) { to(this._lView, t); }
    markForCheck() { ic(this._cdRefInjectingView || this._lView, 4); }
    detach() { this._lView[w] &= -129; }
    reattach() { gs(this._lView), this._lView[w] |= 128; }
    detectChanges() { this._lView[w] |= 1024, cE(this._lView); }
    checkNoChanges() { }
    attachToViewContainerRef() { if (this._appRef)
        throw new D(902, !1); this._attachedToViewContainer = !0; }
    detachFromAppRef() { this._appRef = null; let t = rt(this._lView), n = this._lView[Yt]; n !== null && !t && Sf(n, this._lView), By(this._lView[m], this._lView); }
    attachToAppRef(t) { if (this._attachedToViewContainer)
        throw new D(902, !1); this._appRef = t; let n = rt(this._lView), o = this._lView[Yt]; o !== null && !n && gE(o, this._lView), gs(this._lView); }
};
function rA(e) { return eo(e._lView) || !!(e._lView[w] & 64); }
function iA(e) { Mr(e._lView); }
var Xr = (() => { class e {
    _declarationLView;
    _declarationTContainer;
    elementRef;
    static __NG_ELEMENT_ID__ = sA;
    constructor(n, o, r) { this._declarationLView = n, this._declarationTContainer = o, this.elementRef = r; }
    get ssrId() { return this._declarationTContainer.tView?.ssrId || null; }
    createEmbeddedView(n, o) { return this.createEmbeddedViewImpl(n, o); }
    createEmbeddedViewImpl(n, o, r) { let i = Bo(this._declarationLView, this._declarationTContainer, n, { embeddedViewInjector: o, dehydratedView: r }); return new sn(i); }
} return e; })();
function sA() { return sc(_(), g()); }
function sc(e, t) { return e.type & 4 ? new Xr(t, e, xo(e, t)) : null; }
var ud = "<-- AT THIS LOCATION", aA = "/guide/hydration#third-party-scripts-with-dom-manipulation";
function cA(e) { switch (e) {
    case 4: return "view container";
    case 2: return "element";
    case 8: return "ng-container";
    case 32: return "icu";
    case 64: return "i18n";
    case 16: return "projection";
    case 1: return "text";
    case 128: return "@let";
    default: return "<unknown>";
} }
function lA(e, t) {
    let n = `During serialization, Angular was unable to find an element in the DOM:

`, o = `${pA(e, t, !1)}

`, r = gA();
    throw new D(-502, n + o + r);
}
function mE(e) {
    let t = "During serialization, Angular detected DOM nodes that were created outside of Angular context and provided as projectable nodes (likely via `ViewContainerRef.createComponent` or `createComponent` APIs). Hydration is not supported for such cases, consider refactoring the code to avoid this pattern or using `ngSkipHydration` on the host element of the component.\n\n", n = `${hA(e)}

`, o = t + n + mA();
    return new D(-503, o);
}
function uA(e) { let t = []; if (e.attrs)
    for (let n = 0; n < e.attrs.length;) {
        let o = e.attrs[n++];
        if (typeof o == "number")
            break;
        let r = e.attrs[n++];
        t.push(`${o}="${ua(r)}"`);
    } return t.join(" "); }
var dA = new Set(["ngh", "ng-version", "ng-server-context"]);
function fA(e) { let t = []; for (let n = 0; n < e.attributes.length; n++) {
    let o = e.attributes[n];
    dA.has(o.name) || t.push(`${o.name}="${ua(o.value)}"`);
} return t.join(" "); }
function mu(e, t = "\u2026") { switch (e.type) {
    case 1: return `#text${e.value ? `(${e.value})` : ""}`;
    case 2:
        let o = uA(e), r = e.value.toLowerCase();
        return `<${r}${o ? " " + o : ""}>${t}</${r}>`;
    case 8: return "<!-- ng-container -->";
    case 4: return "<!-- container -->";
    default: return `#node(${cA(e.type)})`;
} }
function qs(e, t = "\u2026") { let n = e; switch (n.nodeType) {
    case Node.ELEMENT_NODE:
        let o = n.tagName.toLowerCase(), r = fA(n);
        return `<${o}${r ? " " + r : ""}>${t}</${o}>`;
    case Node.TEXT_NODE:
        let i = n.textContent ? ua(n.textContent) : "";
        return `#text${i ? `(${i})` : ""}`;
    case Node.COMMENT_NODE: return `<!-- ${ua(n.textContent ?? "")} -->`;
    default: return `#node(${n.nodeType})`;
} }
function pA(e, t, n) {
    let r = "";
    t.prev ? (r += `  \u2026
`, r += "  " + mu(t.prev) + `
`) : t.type && t.type & 12 && (r += `  \u2026
`), n ? (r += "  " + mu(t) + `
`, r += `  <!-- container -->  ${ud}
`) : r += "  " + mu(t) + `  ${ud}
`, r += `  \u2026
`;
    let i = t.type ? bf(e[m], t, e) : null;
    return i && (r = qs(i, `
` + r)), r;
}
function hA(e) {
    let n = "", o = e;
    return o.previousSibling && (n += `  \u2026
`, n += "  " + qs(o.previousSibling) + `
`), n += "  " + qs(o) + `  ${ud}
`, e.nextSibling && (n += `  \u2026
`), e.parentNode && (n = qs(o.parentNode, `
` + n)), n;
}
function gA(e) {
    return `To fix this problem:
  * check ${e ? `the "${e}"` : "corresponding"} component for hydration-related issues
  * check to see if your template has valid HTML structure
  * check if there are any third-party scripts that manipulate the DOM. More info: ${ts}${aA}
  * or skip hydration by adding the \`ngSkipHydration\` attribute to its host node in a template

`;
}
function mA() {
    return `Note: attributes are only displayed to better represent the DOM but have no effect on hydration mismatches.

`;
}
function vA(e) { return e.replace(/\s+/gm, ""); }
function ua(e, t = 50) { return e ? (e = vA(e), e.length > t ? `${e.substring(0, t - 1)}\u2026` : e) : ""; }
function vE(e, t, n) { let o = t.insertBeforeIndex, r = Array.isArray(o) ? o[0] : o; return r === null ? qy(e, t, n) : O(n[r]); }
function yE(e, t, n, o, r) { let i = t.insertBeforeIndex; if (Array.isArray(i)) {
    let s = o, a = null;
    if (t.type & 3 || (a = s, s = r), s !== null && t.componentOffset === -1)
        for (let c = 1; c < i.length; c++) {
            let l = n[i[c]];
            _n(e, s, l, a, !1);
        }
} }
function $n(e, t, n, o, r) { let i = e.data[t]; if (i === null)
    i = Hf(e, t, n, o, r), pg() && (i.flags |= 32);
else if (i.type & 64) {
    i.type = n, i.value = o, i.attrs = r;
    let s = no();
    i.injectorIndex = s === null ? -1 : s.injectorIndex;
} return dt(i, !0), i; }
function Hf(e, t, n, o, r) { let i = $l(), s = Ul(), a = s ? i : i && i.parent, c = e.data[t] = EA(e, a, n, t, o, r); return yA(e, c, i, s), c; }
function yA(e, t, n, o) { e.firstChild === null && (e.firstChild = t), n !== null && (o ? n.child == null && t.parent !== null && (n.child = t) : n.next === null && (n.next = t, t.prev = n)); }
function EA(e, t, n, o, r, i) { let s = t ? t.injectorIndex : -1, a = 0; return wr() && (a |= 128), { type: n, index: o, insertBeforeIndex: null, injectorIndex: s, directiveStart: -1, directiveEnd: -1, directiveStylingLast: -1, componentOffset: -1, controlDirectiveIndex: -1, customControlIndex: -1, propertyBindings: null, flags: a, providerIndexes: 0, value: r, namespace: Cs(), attrs: i, mergedAttrs: null, localNames: null, initialInputs: null, inputs: null, hostDirectiveInputs: null, outputs: null, hostDirectiveOutputs: null, directiveToIndex: null, tView: null, next: null, prev: null, projectionNext: null, child: null, parent: t, projection: null, styles: null, stylesWithoutHost: null, residualStyles: void 0, classes: null, classesWithoutHost: null, residualClasses: void 0, classBindings: 0, styleBindings: 0 }; }
function EE(e, t) { if (e.push(t), e.length > 1)
    for (let n = e.length - 2; n >= 0; n--) {
        let o = e[n];
        IE(o) || IA(o, t) && DA(o) === null && TA(o, t.index);
    } }
function IE(e) { return !(e.type & 64); }
function IA(e, t) { return IE(t) || e.index > t.index; }
function DA(e) { let t = e.insertBeforeIndex; return Array.isArray(t) ? t[0] : t; }
function TA(e, t) { let n = e.insertBeforeIndex; Array.isArray(n) ? n[0] = t : (Wy(vE, yE), e.insertBeforeIndex = t); }
function Lr(e, t) { let n = e.data[t]; return n === null || typeof n == "string" ? null : n.hasOwnProperty("currentCaseLViewIndex") ? n : n.value; }
function CA(e, t, n) { let o = e.data[t]; o === null ? e.data[t] = n : o.value = n; }
function MA(e, t) { let n = e.insertBeforeIndex; n === null ? (Wy(vE, yE), n = e.insertBeforeIndex = [null, t]) : (fl(Array.isArray(n), !0, "Expecting array here"), n.push(t)); }
function wA(e, t, n) { let o = Hf(e, n, 64, null, null); return EE(t, o), o; }
function ac(e, t) { let n = t[e.currentCaseLViewIndex]; return n === null ? n : n < 0 ? ~n : n; }
function NA(e) { return e >>> 17; }
function _A(e) { return (e & 131070) >>> 1; }
function SA(e, t, n) { return e | t << 17 | n << 1; }
function DE(e) { return e === -1; }
function Bf(e, t, n) { e.index = 0; let o = ac(t, n); o !== null ? e.removes = t.remove[o] : e.removes = F; }
function da(e) { if (e.index < e.removes.length) {
    let t = e.removes[e.index++];
    if (t > 0)
        return e.lView[t];
    {
        e.stack.push(e.index, e.removes);
        let n = ~t, o = e.lView[m].data[n];
        return Bf(e, o, e.lView), da(e);
    }
}
else
    return e.stack.length === 0 ? (e.lView = void 0, null) : (e.removes = e.stack.pop(), e.index = e.stack.pop(), da(e)); }
function bA() { let e = { stack: [], index: -1 }; function t(n, o) { for (e.lView = o; e.stack.length;)
    e.stack.pop(); return Bf(e, n.value, o), da.bind(null, e); } return t; }
function AA(e, t) { let n = { stack: [], index: -1, lView: t }; return Bf(n, e, t), da.bind(null, n); }
var RA = new RegExp(`^(\\d+)*(${Qd}|${zd})*(.*)`);
function xA(e, t) { let n = [e]; for (let o of t) {
    let r = n.length - 1;
    if (r > 0 && n[r - 1] === o) {
        let i = n[r] || 1;
        n[r] = i + 1;
    }
    else
        n.push(o, "");
} return n.join(""); }
function kA(e) { let t = e.match(RA), [n, o, r, i] = t, s = o ? parseInt(o, 10) : r, a = []; for (let [c, l, u] of i.matchAll(/(f|n)(\d*)/g)) {
    let d = parseInt(u, 10) || 1;
    a.push(l, d);
} return [s, ...a]; }
function OA(e) { return !e.prev && e.parent?.type === 8; }
function vu(e) { return e.index - I; }
function Uo(e, t) { return !(e.type & 144) && !!t[e.index] && TE(O(t[e.index])); }
function TE(e) { return !!e && !e.isConnected; }
function CE(e, t) { let n = e.i18nNodes; if (n)
    return n.get(t); }
function LA(e, t, n) { let r = e.data[Ei]?.[n]; return r ? ME(r, t) : null; }
function Ai(e, t, n, o) { let r = vu(o), i = CE(e, r); if (i === void 0) {
    let s = e.data[Ei];
    if (s?.[r])
        i = ME(s[r], n);
    else if (t.firstChild === o)
        i = e.firstChild;
    else {
        let a = o.prev === null, c = o.prev ?? o.parent;
        if (OA(o)) {
            let l = vu(o.parent);
            i = Uu(e, l);
        }
        else {
            let l = ie(c, n);
            if (a)
                i = l.firstChild;
            else {
                let u = vu(c), d = Uu(e, u);
                if (c.type === 2 && d) {
                    let p = af(e, u) + 1;
                    i = cc(p, d);
                }
                else
                    i = l.nextSibling;
            }
        }
    }
} return i; }
function cc(e, t) { let n = t; for (let o = 0; o < e; o++)
    n = n.nextSibling; return n; }
function PA(e, t) { let n = e; for (let o = 0; o < t.length; o += 2) {
    let r = t[o], i = t[o + 1];
    for (let s = 0; s < i; s++)
        switch (r) {
            case Pv:
                n = n.firstChild;
                break;
            case Fv:
                n = n.nextSibling;
                break;
        }
} return n; }
function ME(e, t) { let [n, ...o] = kA(e), r; if (n === zd)
    r = t[re][B];
else if (n === Qd)
    r = yf(t[re][B]);
else {
    let i = Number(n);
    r = O(t[i + I]);
} return PA(r, o); }
function dd(e, t) { if (e === t)
    return []; if (e.parentElement == null || t.parentElement == null)
    return null; if (e.parentElement === t.parentElement)
    return FA(e, t); {
    let n = t.parentElement, o = dd(e, n), r = dd(n.firstChild, t);
    return !o || !r ? null : [...o, Pv, ...r];
} }
function FA(e, t) { let n = [], o = null; for (o = e; o != null && o !== t; o = o.nextSibling)
    n.push(Fv); return o == null ? null : n; }
function tm(e, t, n) { let o = dd(e, t); return o === null ? null : xA(n, o); }
function wE(e, t, n) { let o = e.parent, r, i, s; for (; o !== null && (Uo(o, t) || n?.has(o.index));)
    o = o.parent; o === null || !(o.type & 3) ? (r = s = zd, i = t[re][B]) : (r = o.index, i = O(t[r]), s = b(r - I)); let a = O(t[e.index]); if (e.type & 44) {
    let l = Mn(t, e);
    l && (a = l);
} let c = tm(i, a, s); if (c === null && i !== a) {
    let l = i.ownerDocument.body;
    if (c = tm(l, a, Qd), c === null)
        throw lA(t, e);
} return c; }
function jA(e, t) { let n = e.createNodeIterator(t, NodeFilter.SHOW_COMMENT, { acceptNode: VA }), o, r = new Map; for (; o = n.nextNode();) {
    let i = "ngh=", s = o?.textContent, a = s?.indexOf(i) ?? -1;
    if (a > -1) {
        let c = s.substring(a + i.length).trim();
        r.set(c, o);
    }
} return r; }
function VA(e) { return e.textContent?.trimStart().startsWith("ngh=") ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
var NE = !1, _E = () => { };
function $f(e) { NE = e; }
function lc() { return NE; }
function HA(e, t, n, o) { _E(e, t, n, o); }
function SE() { _E = GA; }
function bE(e) { return e = e ?? E(oe), e.get(Kd, !1); }
function AE(e, t) { let n = t.i18nChildren.get(e); return n === void 0 && (n = BA(e), t.i18nChildren.set(e, n)), n; }
function BA(e) { let t = new Set; function n(o) { switch (t.add(o.index), o.kind) {
    case 1:
    case 2: {
        for (let r of o.children)
            n(r);
        break;
    }
    case 3: {
        for (let r of o.cases)
            for (let i of r)
                n(i);
        break;
    }
} } for (let o = I; o < e.bindingStartIndex; o++) {
    let r = e.data[o];
    if (!(!r || !r.ast))
        for (let i of r.ast)
            n(i);
} return t.size === 0 ? null : t; }
function RE(e, t, n) { if (!n.isI18nHydrationEnabled)
    return null; let o = e[m], r = o.data[t]; if (!r || !r.ast)
    return null; let i = o.data[r.parentTNodeIndex]; if (i && Nv(i))
    return null; let s = { caseQueue: [], disconnectedNodes: new Set, disjointNodes: new Set }; return fd(e, s, n, r.ast), s.caseQueue.length === 0 && s.disconnectedNodes.size === 0 && s.disjointNodes.size === 0 ? null : s; }
function fd(e, t, n, o) { let r = null; for (let i of o) {
    let s = UA(e, t, n, i);
    s && ($A(r, s) && t.disjointNodes.add(i.index - I), r = s);
} return r; }
function $A(e, t) { return e && e.nextSibling !== t; }
function UA(e, t, n, o) { let r = O(e[o.index]); if (!r || TE(r))
    return t.disconnectedNodes.add(o.index - I), null; let i = r; switch (o.kind) {
    case 0: {
        cf(n, i);
        break;
    }
    case 1:
    case 2: {
        fd(e, t, n, o.children);
        break;
    }
    case 3: {
        let s = e[o.currentCaseLViewIndex];
        if (s != null) {
            let a = s < 0 ? ~s : s;
            t.caseQueue.push(a), fd(e, t, n, o.cases[a]);
        }
        break;
    }
} return qA(e, o); }
function qA(e, t) { let o = e[m].data[t.index]; return Ma(o) ? Mn(e, o) : t.kind === 3 ? AA(o, e)() ?? O(e[t.index]) : O(e[t.index]) ?? null; }
function In(e, t) { e.currentNode = t; }
function br(e, t, n) { let o = n.index - I, { disconnectedNodes: r } = e, i = t.currentNode; return t.isConnected ? (e.i18nNodes.set(o, i), r.delete(o)) : r.add(o), i; }
function yu(e, t) { let n = e.currentNode; for (let o = 0; o < t && n; o++)
    n = n?.nextSibling ?? null; return n; }
function Eu(e, t) { return { currentNode: t, isConnected: e.isConnected }; }
function GA(e, t, n, o) { let r = e[fe]; if (!r || !lc() || n && (Nv(n) || Fa(r, n.index - I)))
    return; let i = e[m], s = i.data[t]; function a() { if (DE(o)) {
    let p = Ai(r, i, e, n);
    return n.type & 8 ? p : p.firstChild;
} return r?.firstChild; } let c = a(), l = ny(r) ?? new Set, u = r.i18nNodes ??= new Map, d = r.data[Ra]?.[t - I] ?? [], f = r.dehydratedIcuData ??= new Map; lo({ hydrationInfo: r, lView: e, i18nNodes: u, disconnectedNodes: l, caseQueue: d, dehydratedIcuData: f }, { currentNode: c, isConnected: !0 }, s.ast), r.disconnectedNodes = l.size === 0 ? null : l; }
function lo(e, t, n) { if (Array.isArray(n)) {
    let o = t;
    for (let r of n) {
        let i = LA(e.hydrationInfo, e.lView, r.index - I);
        i && (o = Eu(t, i)), lo(e, o, r);
    }
}
else {
    if (e.disconnectedNodes.has(n.index - I))
        return;
    switch (n.kind) {
        case 0: {
            let o = br(e, t, n);
            In(t, o?.nextSibling ?? null);
            break;
        }
        case 1: {
            lo(e, Eu(t, t.currentNode?.firstChild ?? null), n.children);
            let o = br(e, t, n);
            In(t, o?.nextSibling ?? null);
            break;
        }
        case 2: {
            let o = n.index - I, { hydrationInfo: r } = e, i = ey(r, o);
            switch (n.type) {
                case 0: {
                    let s = br(e, t, n);
                    if (z_(r, o)) {
                        lo(e, t, n.children);
                        let a = yu(t, 1);
                        In(t, a);
                    }
                    else if (lo(e, Eu(t, t.currentNode?.firstChild ?? null), n.children), In(t, s?.nextSibling ?? null), i !== null) {
                        let a = yu(t, i + 1);
                        In(t, a);
                    }
                    break;
                }
                case 1: {
                    br(e, t, n);
                    let s = yu(t, i + 1);
                    In(t, s);
                    break;
                }
            }
            break;
        }
        case 3: {
            let o = t.isConnected ? e.caseQueue.shift() : null, r = { currentNode: null, isConnected: !1 };
            for (let s = 0; s < n.cases.length; s++)
                lo(e, s === o ? t : r, n.cases[s]);
            o !== null && e.dehydratedIcuData.set(n.index, { case: o, node: n });
            let i = br(e, t, n);
            In(t, i?.nextSibling ?? null);
            break;
        }
    }
} }
var xE = () => { };
function WA(e, t, n) { xE(e, t, n); }
function kE() { xE = zA; }
function zA(e, t, n) { let o = e[fe]?.dehydratedIcuData; o && o.get(t)?.case === n && o.delete(t); }
function QA(e) { let t = e[fe]; if (t) {
    let { i18nNodes: n, dehydratedIcuData: o } = t;
    if (n && o) {
        let r = e[N];
        for (let i of o.values())
            ZA(r, n, i);
    }
    t.i18nNodes = void 0, t.dehydratedIcuData = void 0;
} }
function ZA(e, t, n) { for (let o of n.node.cases[n.case]) {
    let r = t.get(o.index - I);
    r && wi(e, r, !1);
} }
function uc(e) { let t = e[je] ?? [], o = e[z][N], r = []; for (let i of t)
    i.data[xa] !== void 0 ? r.push(i) : OE(i, o); e[je] = r; }
function YA(e) { let { lContainer: t } = e, n = t[je]; if (n === null)
    return; let r = t[z][N]; for (let i of n)
    OE(i, r); }
function OE(e, t) { let n = 0, o = e.firstChild; if (o) {
    let r = e.data[xt];
    for (; n < r;) {
        let i = o.nextSibling;
        wi(t, o, !1), o = i, n++;
    }
} }
function dc(e) { uc(e); let t = e[B]; J(t) && ei(t); for (let n = U; n < e.length; n++)
    ei(e[n]); }
function ei(e) { QA(e); let t = e[m]; for (let n = I; n < t.bindingStartIndex; n++)
    if (K(e[n])) {
        let o = e[n];
        dc(o);
    }
    else
        J(e[n]) && ei(e[n]); }
function Uf(e) { let t = e._views; for (let n of t) {
    let o = sf(n);
    o !== null && o[B] !== null && (J(o) ? ei(o) : dc(o));
} }
function KA(e, t, n, o) { e !== null && (n.cleanup(t), dc(e.lContainer), Uf(o)); }
function JA(e, t) { let n = []; for (let o of t)
    for (let r = 0; r < (o[yi] ?? 1); r++) {
        let i = { data: o, firstChild: null };
        o[xt] > 0 && (i.firstChild = e, e = cc(o[xt], e)), n.push(i);
    } return [e, n]; }
var LE = () => null, PE = () => null;
function FE() { LE = XA, PE = eR; }
function XA(e, t) { return VE(e, t) ? e[je].shift() : (uc(e), null); }
function ti(e, t) { return LE(e, t); }
function eR(e, t, n) { if (t.tView.ssrId === null)
    return null; let o = ti(e, t.tView.ssrId); return n[m].firstUpdatePass && o === null && tR(n, t), o; }
function jE(e, t, n) { return PE(e, t, n); }
function tR(e, t) { let n = t; for (; n;) {
    if (nm(e, n))
        return;
    if ((n.flags & 256) === 256)
        break;
    n = n.prev;
} for (n = t.next; n && (n.flags & 512) === 512;) {
    if (nm(e, n))
        return;
    n = n.next;
} }
function VE(e, t) { let n = e[je]; return !t || n === null || n.length === 0 ? !1 : n[0].data[Aa] === t; }
function nm(e, t) { let n = t.tView?.ssrId; if (n == null)
    return !1; let o = e[t.index]; return K(o) && VE(o, n) ? (uc(o), !0) : !1; }
var HE = class {
}, ni = class {
}, nR = (() => { class e {
    destroyNode = null;
    static __NG_ELEMENT_ID__ = () => oR();
} return e; })();
function oR() { let e = g(), t = _(), n = me(t.index, e); return (J(n) ? n : e)[N]; }
var BE = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => null });
} return e; })();
function qf(e) { return e.ngModule !== void 0; }
function Dn(e) { return !!Zn(e); }
function Ps(e) { return !!tt(e); }
function om(e) { return !!Oe(e); }
function Pr(e) { return !!W(e); }
function rR(e) { return W(e) ? "component" : Oe(e) ? "directive" : tt(e) ? "pipe" : "type"; }
function iR(e, t) { if (cr(e) && (e = P(e), !e))
    throw new Error(`Expected forwardRef function, imported from "${Ge(t)}", to return a standalone entity or NgModule but got "${Ge(e) || e}".`); if (Zn(e) == null) {
    let n = W(e) || Oe(e) || tt(e);
    if (n != null) {
        if (!n.standalone) {
            let o = rR(e);
            throw new Error(`The "${Ge(e)}" ${o}, imported from "${Ge(t)}", is not standalone. Does the ${o} have the standalone: false flag?`);
        }
    }
    else
        throw qf(e) ? new Error(`A module with providers was imported from "${Ge(t)}". Modules with providers are not supported in standalone components imports.`) : new Error(`The "${Ge(e)}" type, imported from "${Ge(t)}", must be a standalone component / directive / pipe or an NgModule. Did you forget to add the required @Component / @Directive / @Pipe or @NgModule annotation?`);
} }
var pd = class {
    ownerNgModule = new WeakMap;
    ngModulesWithSomeUnresolvedDecls = new Set;
    ngModulesScopeCache = new WeakMap;
    standaloneComponentsScopeCache = new WeakMap;
    resolveNgModulesDecls() { if (this.ngModulesWithSomeUnresolvedDecls.size !== 0) {
        for (let t of this.ngModulesWithSomeUnresolvedDecls) {
            let n = Zn(t);
            if (n?.declarations)
                for (let o of xr(n.declarations))
                    Pr(o) && this.ownerNgModule.set(o, t);
        }
        this.ngModulesWithSomeUnresolvedDecls.clear();
    } }
    getComponentDependencies(t, n) { this.resolveNgModulesDecls(); let o = W(t); if (o === null)
        throw new Error(`Attempting to get component dependencies for a type that is not a component: ${t}`); if (o.standalone) {
        let r = this.getStandaloneComponentScope(t, n);
        return r.compilation.isPoisoned ? { dependencies: [] } : { dependencies: [...r.compilation.directives, ...r.compilation.pipes, ...r.compilation.ngModules] };
    }
    else {
        if (!this.ownerNgModule.has(t))
            return { dependencies: [] };
        let r = this.getNgModuleScope(this.ownerNgModule.get(t));
        return r.compilation.isPoisoned ? { dependencies: [] } : { dependencies: [...r.compilation.directives, ...r.compilation.pipes] };
    } }
    registerNgModule(t, n) { if (!Dn(t))
        throw new Error(`Attempting to register a Type which is not NgModule as NgModule: ${t}`); this.ngModulesWithSomeUnresolvedDecls.add(t); }
    clearScopeCacheFor(t) { this.ngModulesScopeCache.delete(t), this.standaloneComponentsScopeCache.delete(t); }
    getNgModuleScope(t) { if (this.ngModulesScopeCache.has(t))
        return this.ngModulesScopeCache.get(t); let n = this.computeNgModuleScope(t); return this.ngModulesScopeCache.set(t, n), n; }
    computeNgModuleScope(t) { let n = is(t), o = { exported: { directives: new Set, pipes: new Set }, compilation: { directives: new Set, pipes: new Set } }; for (let r of xr(n.imports))
        if (Dn(r)) {
            let i = this.getNgModuleScope(r);
            en(i.exported.directives, o.compilation.directives), en(i.exported.pipes, o.compilation.pipes);
        }
        else if (pr(r))
            if (om(r) || Pr(r))
                o.compilation.directives.add(r);
            else if (Ps(r))
                o.compilation.pipes.add(r);
            else
                throw new D(980, "The standalone imported type is neither a component nor a directive nor a pipe");
        else {
            o.compilation.isPoisoned = !0;
            break;
        } if (!o.compilation.isPoisoned)
        for (let r of xr(n.declarations)) {
            if (Dn(r) || pr(r)) {
                o.compilation.isPoisoned = !0;
                break;
            }
            Ps(r) ? o.compilation.pipes.add(r) : o.compilation.directives.add(r);
        } for (let r of xr(n.exports))
        if (Dn(r)) {
            let i = this.getNgModuleScope(r);
            en(i.exported.directives, o.exported.directives), en(i.exported.pipes, o.exported.pipes), en(i.exported.directives, o.compilation.directives), en(i.exported.pipes, o.compilation.pipes);
        }
        else
            Ps(r) ? o.exported.pipes.add(r) : o.exported.directives.add(r); return o; }
    getStandaloneComponentScope(t, n) { if (this.standaloneComponentsScopeCache.has(t))
        return this.standaloneComponentsScopeCache.get(t); let o = this.computeStandaloneComponentScope(t, n); return this.standaloneComponentsScopeCache.set(t, o), o; }
    computeStandaloneComponentScope(t, n) { let o = { compilation: { directives: new Set([t]), pipes: new Set, ngModules: new Set } }; for (let r of nt(n ?? [])) {
        let i = P(r);
        try {
            iR(i, t);
        }
        catch {
            return o.compilation.isPoisoned = !0, o;
        }
        if (Dn(i)) {
            o.compilation.ngModules.add(i);
            let s = this.getNgModuleScope(i);
            if (s.exported.isPoisoned)
                return o.compilation.isPoisoned = !0, o;
            en(s.exported.directives, o.compilation.directives), en(s.exported.pipes, o.compilation.pipes);
        }
        else if (Ps(i))
            o.compilation.pipes.add(i);
        else if (om(i) || Pr(i))
            o.compilation.directives.add(i);
        else
            return o.compilation.isPoisoned = !0, o;
    } return o; }
    isOrphanComponent(t) { let n = W(t); return !n || n.standalone ? !1 : (this.resolveNgModulesDecls(), !this.ownerNgModule.has(t)); }
};
function en(e, t) { for (let n of e)
    t.add(n); }
var wo = new pd;
function sR(e, t) { let n = e; for (; n;) {
    let o = f_(n);
    if (o !== null)
        for (let r = I; r < o.length; r++) {
            let i = o[r];
            if (!J(i) && !K(i) || i[B] !== n)
                continue;
            let s = o[m], a = Kt(s, r);
            if (Ce(a)) {
                let c = s.data[a.directiveStart + a.componentOffset], l = Gf(c);
                if (l !== null && (!t || t(n, l)))
                    return l;
                break;
            }
        }
    n = n.parentNode;
} return null; }
function Gf(e) { return e.debugInfo?.className || e.type.name || null; }
var Gs = {}, nn = class {
    injector;
    parentInjector;
    constructor(t, n) { this.injector = t, this.parentInjector = n; }
    get(t, n, o) { let r = this.injector.get(t, Gs, o); return r !== Gs || n === Gs ? r : this.parentInjector.get(t, n, o); }
};
function oi(e) { return fc(e) ? Array.isArray(e) || !(e instanceof Map) && Symbol.iterator in e : !1; }
function aR(e, t, n) { let o = e[Symbol.iterator](), r = t[Symbol.iterator](); for (;;) {
    let i = o.next(), s = r.next();
    if (i.done && s.done)
        return !0;
    if (i.done || s.done || !n(i.value, s.value))
        return !1;
} }
function $E(e, t) { if (Array.isArray(e))
    for (let n = 0; n < e.length; n++)
        t(e[n]);
else {
    let n = e[Symbol.iterator](), o;
    for (; !(o = n.next()).done;)
        t(o.value);
} }
function fc(e) { return e !== null && (typeof e == "function" || typeof e == "object"); }
function UE(e, t) { let n = oi(e), o = oi(t); return n && o ? aR(e, t, UE) : !n && (e && (typeof e == "object" || typeof e == "function")) && !o && (t && (typeof t == "object" || typeof t == "function")) ? !0 : Object.is(e, t); }
function at(e, t, n) { return e[t] = n; }
function qo(e, t) { return e[t]; }
function Z(e, t, n) { if (n === $)
    return !1; let o = e[t]; return Object.is(o, n) ? !1 : (e[t] = n, !0); }
function Rn(e, t, n, o) { let r = Z(e, t, n); return Z(e, t + 1, o) || r; }
function pc(e, t, n, o, r) { let i = Rn(e, t, n, o); return Z(e, t + 2, r) || i; }
function Je(e, t, n, o, r, i) { let s = Rn(e, t, n, o); return Rn(e, t + 2, r, i) || s; }
function on(e, t, n) { return function o(r) { let i = o.__ngNativeEl__; i !== void 0 && P_(r, i); let s = Ce(e) ? me(e.index, t) : t; ic(s, 5); let a = t[j], c = rm(t, a, n, r), l = o.__ngNextListenerFn__; for (; l;)
    c = rm(t, a, l, r) && c, l = l.__ngNextListenerFn__; return c; }; }
function rm(e, t, n, o) { let r = uo(null); try {
    return H(L.OutputStart, t, n), n(o) !== !1;
}
catch (i) {
    return jf(e, i), !1;
}
finally {
    H(L.OutputEnd, t, n), uo(r);
} }
function Wf(e, t, n, o, r, i, s, a) { let c = Xn(e), l = !1, u = null; if (!o && c && (u = lR(t, n, i, e.index)), u !== null) {
    let d = u.__ngLastListenerFn__ || u;
    d.__ngNextListenerFn__ = s, u.__ngLastListenerFn__ = s, l = !0;
}
else {
    let d = ie(e, n), f = o ? o(d) : d;
    F_(n, f, i, a), o || (a.__ngNativeEl__ = d);
    let p = r.listen(f, i, a);
    if (!cR(i)) {
        let h = o ? v => o(O(v[e.index])) : e.index;
        qE(h, t, n, i, a, p, !1);
    }
} return l; }
function cR(e) { return e.startsWith("animation") || e.startsWith("transition"); }
function lR(e, t, n, o) { let r = e.cleanup; if (r != null)
    for (let i = 0; i < r.length - 1; i += 2) {
        let s = r[i];
        if (s === n && r[i + 1] === o) {
            let a = t[zt], c = r[i + 2];
            return a && a.length > c ? a[c] : null;
        }
        typeof s == "string" && (i += 2);
    } return null; }
function qE(e, t, n, o, r, i, s) { let a = t.firstCreatePass ? Ol(t) : null, c = kl(n), l = c.length; c.push(r, i), a && a.push(o, e, l, (l + 1) * (s ? -1 : 1)); }
function uR(e, t, n, o, r) { let i = on(e, t, n), s = hd(e, t, o, r, i); }
function hd(e, t, n, o, r) { let i = null, s = null, a = null, c = !1, l = e.directiveToIndex.get(n.type); if (typeof l == "number" ? i = l : [i, s, a] = l, s !== null && a !== null && e.hostDirectiveOutputs?.hasOwnProperty(o)) {
    let u = e.hostDirectiveOutputs[o];
    for (let d = 0; d < u.length; d += 2) {
        let f = u[d];
        if (f >= s && f <= a)
            c = !0, fa(e, t, f, u[d + 1], o, r);
        else if (f > a)
            break;
    }
} return n.outputs.hasOwnProperty(o) && (c = !0, fa(e, t, i, o, o, r)), c; }
function fa(e, t, n, o, r, i) { let s = t[n], a = t[m], l = a.data[n].outputs[o], d = s[l].subscribe(i); qE(e.index, a, t, r, i, d, !0); }
function GE() { WE(); }
function WE() { let e = g(), t = A(), n = _(); if (t.firstCreatePass && dR(t, n), n.controlDirectiveIndex === -1)
    return; te("NgSignalForms"); let o = e[n.controlDirectiveIndex]; t.data[n.controlDirectiveIndex].controlDef.create(o, new pa(e, t, n)); }
function zE() { QE(); }
function QE() { let e = g(), t = A(), n = Ve(); if (n.controlDirectiveIndex === -1)
    return; let o = t.data[n.controlDirectiveIndex].controlDef, r = e[n.controlDirectiveIndex]; o.update(r, new pa(e, t, n)); }
var pa = class {
    lView;
    tView;
    tNode;
    hasPassThrough;
    constructor(t, n, o) { this.lView = t, this.tView = n, this.tNode = o, this.hasPassThrough = !!(o.flags & 4096); }
    get customControl() { return this.tNode.customControlIndex !== -1 ? this.lView[this.tNode.customControlIndex] : void 0; }
    get nativeElement() { return ie(this.tNode, this.lView); }
    get descriptor() { return `<${this.tNode.value}>`; }
    listenToCustomControlOutput(t, n) { let o = this.tView.data[this.tNode.customControlIndex]; hd(this.tNode, this.lView, o, t, on(this.tNode, this.lView, n)); }
    listenToCustomControlModel(t) { let n = this.tNode.flags & 1024 ? "valueChange" : "checkedChange", o = this.tView.data[this.tNode.customControlIndex]; hd(this.tNode, this.lView, o, n, on(this.tNode, this.lView, t)); }
    listenToDom(t, n) { Wf(this.tNode, this.tView, this.lView, void 0, this.lView[N], t, n, on(this.tNode, this.lView, n)); }
    setInputOnDirectives(t, n) { let o = this.tNode.inputs?.[t], r = this.tNode.hostDirectiveInputs?.[t]; if (!o && !r)
        return !1; let i = !1; if (o)
        for (let s of o) {
            if (s === this.tNode.controlDirectiveIndex)
                continue;
            let a = this.tView.data[s], c = this.lView[s];
            bn(a, c, t, n), i = !0;
        } if (r)
        for (let s = 0; s < r.length; s += 2) {
            let a = r[s];
            if (a === this.tNode.controlDirectiveIndex)
                continue;
            let c = r[s + 1], l = this.tView.data[a], u = this.lView[a];
            bn(l, u, c, n), i = !0;
        } return i; }
    setCustomControlModelInput(t) { let n = this.tView.data[this.tNode.customControlIndex], o = this.tNode.flags & 1024 ? "value" : "checked"; oE(this.tNode, this.tView, this.lView, n, o, t); }
    customControlHasInput(t) { if (this.tNode.customControlIndex === -1)
        return !1; let n = this.tView.data[this.tNode.customControlIndex]; return (n.signalFormsInputPresence ??= this._buildCustomControlInputCache(n))[t] === !0; }
    _buildCustomControlInputCache(t) { let n = {}; for (let o in t.inputs)
        n[o] = !0; if (t.hostDirectives !== null) {
        let o = [...t.hostDirectives];
        for (; o.length > 0;) {
            let r = o.shift();
            if (typeof r != "function") {
                for (let s in r.inputs)
                    n[r.inputs[s]] = !0;
                let i = im(r.directive);
                i !== null && o.push(...i);
                continue;
            }
            for (let i of r()) {
                if (typeof i == "function")
                    continue;
                if (i.inputs)
                    for (let a = 0; a < i.inputs.length; a += 2) {
                        let c = i.inputs[a + 1] || i.inputs[a];
                        n[c] = !0;
                    }
                let s = im(i.directive);
                s !== null && o.push(...s);
            }
        }
    } return n; }
};
function im(e) { return typeof e == "function" && "\u0275dir" in e ? e.\u0275dir.hostDirectives ?? null : null; }
function dR(e, t, n) { for (let r = t.directiveStart; r < t.directiveEnd; r++)
    if (e.data[r].controlDef) {
        t.controlDirectiveIndex = r;
        break;
    } if (t.controlDirectiveIndex === -1)
    return; let o = e.data[t.controlDirectiveIndex].controlDef; if (o.passThroughInput && (t.inputs?.[o.passThroughInput]?.length ?? 0) > 1) {
    t.flags |= 4096;
    return;
} fR(e, t); }
function fR(e, t) { for (let n = t.directiveStart; n < t.directiveEnd; n++) {
    let o = e.data[n];
    if (!(t.directiveToIndex && !t.directiveToIndex.has(o.type))) {
        if (sm(o, "value")) {
            t.flags |= 1024, t.customControlIndex = n;
            return;
        }
        if (sm(o, "checked")) {
            t.flags |= 2048, t.customControlIndex = n;
            return;
        }
    }
} if (t.hostDirectiveInputs !== null && t.hostDirectiveOutputs !== null && t.directiveToIndex !== null) {
    let n = (o, r) => { let i = t.hostDirectiveInputs[o], s = t.hostDirectiveOutputs[o + "Change"]; if (!i || !s)
        return !1; for (let a = 0; a < i.length; a += 2) {
        let c = i[a];
        for (let l = 0; l < s.length; l += 2) {
            let u = s[l];
            if (c === u)
                for (let d of t.directiveToIndex.values()) {
                    if (!Array.isArray(d))
                        continue;
                    let [f, p, h] = d;
                    if (c >= p && c <= h)
                        return t.flags |= r, t.customControlIndex = f, !0;
                }
        }
    } return !1; };
    if (n("value", 1024) || n("checked", 2048))
        return;
} }
function sm(e, t) { return pR(e, t) && hR(e, t + "Change"); }
function pR(e, t) { return t in e.inputs; }
function hR(e, t) { return t in e.outputs; }
var Rt = Symbol("BINDING"), am = { kind: "input", requiredVars: 1 }, gR = { kind: "output", requiredVars: 0 };
function cm(e, t, n) { let o = g(), r = De(); if (Z(o, r, n)) {
    let i = o[m], s = Ve(), a = me(s.index, o);
    ic(a, 1);
    let c = i.directiveRegistry[e], l = oE(s, i, o, c, t, n);
} }
function ZE(e, t) { if (e === "formField") {
    let o = { [Rt]: am, create: () => { WE(); }, update: () => { cm(o.targetIdx, e, t()), QE(); } };
    return o;
} let n = { [Rt]: am, update: () => cm(n.targetIdx, e, t()) }; return n; }
function YE(e, t) { let n = { [Rt]: gR, create: () => { let o = g(), r = _(), s = o[m].directiveRegistry[n.targetIdx]; uR(r, o, t, s, e); } }; return n; }
function mR(e, t) { let n = ZE(e, t), o = YE(e + "Change", i => t.set(i)); return { [Rt]: { kind: "twoWay", requiredVars: n[Rt].requiredVars + o[Rt].requiredVars }, set targetIdx(i) { n.targetIdx = i, o.targetIdx = i; }, create: o.create, update: n.update }; }
var KE = new C("");
function ha(e, t, n) { let o = n ? e.styles : null, r = n ? e.classes : null, i = 0; if (t !== null)
    for (let s = 0; s < t.length; s++) {
        let a = t[s];
        if (typeof a == "number")
            i = a;
        else if (i == 1)
            r = os(r, a);
        else if (i == 2) {
            let c = a, l = t[++s];
            o = os(o, c + ": " + l + ";");
        }
    } n ? e.styles = o : e.stylesWithoutHost = o, n ? e.classes = r : e.classesWithoutHost = r; }
function Go(e, t = 0) { let n = g(); if (n === null)
    return he(e, t); let o = _(); return fv(o, n, P(e), t); }
function JE() { let e = "invalid"; throw new Error(e); }
function XE(e, t, n, o, r) { let i = o === null ? null : { "": -1 }, s = r(e, n); if (s !== null) {
    let a = s, c = null, l = null;
    for (let u of s)
        if (u.resolveHostDirectives !== null) {
            [a, c, l] = u.resolveHostDirectives(s);
            break;
        }
    ER(e, t, n, a, i, c, l);
} i !== null && o !== null && vR(n, o, i); }
function vR(e, t, n) { let o = e.localNames = []; for (let r = 0; r < t.length; r += 2) {
    let i = n[t[r + 1]];
    if (i == null)
        throw new D(-301, !1);
    o.push(t[r], i);
} }
function yR(e, t, n) { t.componentOffset = n, (e.components ??= []).push(t.index); }
function ER(e, t, n, o, r, i, s) { let a = o.length, c = null; for (let f = 0; f < a; f++) {
    let p = o[f];
    c === null && Ze(p) && (c = p, yR(e, n, f)), Lu(Xs(n, t), e, p.type);
} wR(n, e.data.length, a), c?.viewProvidersResolver && c.viewProvidersResolver(c); for (let f = 0; f < a; f++) {
    let p = o[f];
    p.providersResolver && p.providersResolver(p);
} let l = !1, u = !1, d = bi(e, t, a, null); a > 0 && (n.directiveToIndex = new Map); for (let f = 0; f < a; f++) {
    let p = o[f];
    if (n.mergedAttrs = To(n.mergedAttrs, p.hostAttrs), DR(e, n, t, d, p), MR(d, p, r), s !== null && s.has(p)) {
        let [v, y] = s.get(p);
        n.directiveToIndex.set(p.type, [d, v + n.directiveStart, y + n.directiveStart]);
    }
    else
        (i === null || !i.has(p)) && n.directiveToIndex.set(p.type, d);
    p.contentQueries !== null && (n.flags |= 4), (p.hostBindings !== null || p.hostAttrs !== null || p.hostVars !== 0) && (n.flags |= 64);
    let h = p.type.prototype;
    !l && (h.ngOnChanges || h.ngOnInit || h.ngDoCheck) && ((e.preOrderHooks ??= []).push(n.index), l = !0), !u && (h.ngOnChanges || h.ngDoCheck) && ((e.preOrderCheckHooks ??= []).push(n.index), u = !0), d++;
} IR(e, n, i); }
function IR(e, t, n) { for (let o = t.directiveStart; o < t.directiveEnd; o++) {
    let r = e.data[o];
    if (n === null || !n.has(r))
        lm(0, t, r, o), lm(1, t, r, o), dm(t, o, !1);
    else {
        let i = n.get(r);
        um(0, t, i, o), um(1, t, i, o), dm(t, o, !0);
    }
} }
function lm(e, t, n, o) { let r = e === 0 ? n.inputs : n.outputs; for (let i in r)
    if (r.hasOwnProperty(i)) {
        let s;
        e === 0 ? s = t.inputs ??= {} : s = t.outputs ??= {}, s[i] ??= [], s[i].push(o), eI(t, i);
    } }
function um(e, t, n, o) { let r = e === 0 ? n.inputs : n.outputs; for (let i in r)
    if (r.hasOwnProperty(i)) {
        let s = r[i], a;
        e === 0 ? a = t.hostDirectiveInputs ??= {} : a = t.hostDirectiveOutputs ??= {}, a[s] ??= [], a[s].push(o, i), eI(t, s);
    } }
function eI(e, t) { t === "class" ? e.flags |= 8 : t === "style" && (e.flags |= 16); }
function dm(e, t, n) { let { attrs: o, inputs: r, hostDirectiveInputs: i } = e; if (o === null || !n && r === null || n && i === null || Ef(e)) {
    e.initialInputs ??= [], e.initialInputs.push(null);
    return;
} let s = null, a = 0; for (; a < o.length;) {
    let c = o[a];
    if (c === 0) {
        a += 4;
        continue;
    }
    else if (c === 5) {
        a += 2;
        continue;
    }
    else if (typeof c == "number")
        break;
    if (!n && r.hasOwnProperty(c)) {
        let l = r[c];
        for (let u of l)
            if (u === t) {
                s ??= [], s.push(c, o[a + 1]);
                break;
            }
    }
    else if (n && i.hasOwnProperty(c)) {
        let l = i[c];
        for (let u = 0; u < l.length; u += 2)
            if (l[u] === t) {
                s ??= [], s.push(l[u + 1], o[a + 1]);
                break;
            }
    }
    a += 2;
} e.initialInputs ??= [], e.initialInputs.push(s); }
function DR(e, t, n, o, r) { e.data[o] = r; let i = r.factory || (r.factory = Ut(r.type, !0)), s = new Nn(i, Ze(r), Go, null); e.blueprint[o] = s, n[o] = s, TR(e, t, o, bi(e, n, r.hostVars, $), r); }
function TR(e, t, n, o, r) { let i = r.hostBindings; if (i) {
    let s = e.hostBindingOpCodes;
    s === null && (s = e.hostBindingOpCodes = []);
    let a = ~t.index;
    CR(s) != a && s.push(a), s.push(n, o, i);
} }
function CR(e) { let t = e.length; for (; t > 0;) {
    let n = e[--t];
    if (typeof n == "number" && n < 0)
        return n;
} return 0; }
function MR(e, t, n) { if (n) {
    if (t.exportAs)
        for (let o = 0; o < t.exportAs.length; o++)
            n[t.exportAs[o]] = e;
    Ze(t) && (n[""] = e);
} }
function wR(e, t, n) { e.flags |= 1, e.directiveStart = t, e.directiveEnd = t + n, e.providerIndexes = t; }
function zf(e, t, n, o, r, i, s, a) { let c = t[m], l = c.consts, u = ve(l, s), d = $n(c, e, n, o, u); return i && XE(c, t, d, ve(l, a), r), d.mergedAttrs = To(d.mergedAttrs, d.attrs), d.attrs !== null && ha(d, d.attrs, !1), d.mergedAttrs !== null && ha(d, d.mergedAttrs, !0), c.queries !== null && c.queries.elementStart(c, d), d; }
function Qf(e, t) { nv(e, t), Nl(t) && e.queries.elementEnd(t); }
function tI(e, t, n, o, r, i) { let s = t.consts, a = ve(s, r), c = $n(t, e, n, o, a); if (c.mergedAttrs = To(c.mergedAttrs, c.attrs), i != null) {
    let l = ve(s, i);
    c.localNames = [];
    for (let u = 0; u < l.length; u += 2)
        c.localNames.push(l[u], -1);
} return c.attrs !== null && ha(c, c.attrs, !1), c.mergedAttrs !== null && ha(c, c.mergedAttrs, !0), t.queries !== null && t.queries.elementStart(t, c), c; }
var nI = typeof ShadowRoot < "u", NR = typeof Document < "u";
function _R(e) { return Object.keys(e).map(t => { let [n, o, r] = e[t], i = { propName: n, templateName: t, isSignal: (o & Ka.SignalBased) !== 0 }; return r && (i.transform = r), i; }); }
function SR(e) { return Object.keys(e).map(t => ({ propName: e[t], templateName: t })); }
function bR(e, t, n) { let o = t instanceof be ? t : t?.injector; return o && e.getStandaloneInjector !== null && (o = e.getStandaloneInjector(o) || o), o ? new nn(n, o) : n; }
function AR(e) { let t = e.get(ni, null); if (t === null)
    throw new D(407, !1); let n = e.get(BE, null), o = e.get(qe, null), r = e.get(Bn, null, { optional: !0 }); return { rendererFactory: t, sanitizer: n, changeDetectionScheduler: o, ngReflect: !1, tracingService: r }; }
function RR(e, t) { let n = oI(e); return Ha(t, n, n === "svg" ? bl : n === "math" ? Al : null); }
function oI(e) { return (e.selectors[0][0] || "div").toLowerCase(); }
var xn = class {
    componentDef;
    ngModule;
    selector;
    componentType;
    ngContentSelectors;
    isBoundToModule;
    cachedInputs = null;
    cachedOutputs = null;
    get inputs() { return this.cachedInputs ??= _R(this.componentDef.inputs), this.cachedInputs; }
    get outputs() { return this.cachedOutputs ??= SR(this.componentDef.outputs), this.cachedOutputs; }
    constructor(t, n) { this.componentDef = t, this.ngModule = n, this.componentType = t.type, this.selector = ob(t.selectors), this.ngContentSelectors = t.ngContentSelectors ?? [], this.isBoundToModule = !!n; }
    create(t, n, o, r, i, s) { H(L.DynamicComponentStart); let a = x(null); try {
        let c = this.componentDef, l = bR(c, r || this.ngModule, t), u = AR(l), d = u.tracingService;
        return d && d.componentCreate ? d.componentCreate(Gf(c), () => this.createComponentRef(u, l, n, o, i, s)) : this.createComponentRef(u, l, n, o, i, s);
    }
    finally {
        x(a);
    } }
    createComponentRef(t, n, o, r, i, s) { let a = this.componentDef, c = xR(r, a, s, i), l = t.rendererFactory.createRenderer(null, a), u = r ? Ob(l, r, a.encapsulation, n) : RR(a, l), d = n.get(KE, null), f = kR(u, () => n.get(Nt, null) ?? mi()); d && d.addHost(f); let p = s?.some(fm) || i?.some(y => typeof y != "function" && y.bindings.some(fm)), h = Ya(null, c, null, 512 | kf(a), null, null, t, l, n, null, Jv(u, n, !0)); d && nI && f instanceof ShadowRoot && to(h, () => { d.removeHost(f); }), h[I] = u, Ds(h); let v = null; try {
        let y = zf(I, h, 2, "#host", () => c.directiveRegistry, !0, 0);
        Dy(l, u, y), Ye(u, h), Ja(c, h, y), lf(c, y, h), Qf(c, y), o !== void 0 && LR(y, this.ngContentSelectors, o), v = me(y.index, h), h[j] = v[j], oc(c, h, null);
    }
    catch (y) {
        throw v !== null && ju(v), ju(h), y;
    }
    finally {
        H(L.DynamicComponentEnd), Ts();
    } return new ga(this.componentType, h, !!p); }
};
function xR(e, t, n, o) { let r = e ? ["ng-version", "22.0.2"] : rb(t.selectors[0]), i = null, s = null, a = 0; if (n)
    for (let u of n)
        a += u[Rt].requiredVars, u.create && (u.targetIdx = 0, (i ??= []).push(u)), u.update && (u.targetIdx = 0, (s ??= []).push(u)); if (o)
    for (let u = 0; u < o.length; u++) {
        let d = o[u];
        if (typeof d != "function")
            for (let f of d.bindings) {
                a += f[Rt].requiredVars;
                let p = u + 1;
                f.create && (f.targetIdx = p, (i ??= []).push(f)), f.update && (f.targetIdx = p, (s ??= []).push(f));
            }
    } let c = [t]; if (o)
    for (let u of o) {
        let d = typeof u == "function" ? u : u.type, f = Oe(d);
        c.push(f);
    } return xf(0, null, OR(i, s), 1, a, c, null, null, null, [r], null); }
function kR(e, t) { let n = e.getRootNode?.(); return NR && n instanceof Document ? n.head : n && nI && n instanceof ShadowRoot ? n : t().head; }
function OR(e, t) { return !e && !t ? null : n => { if (n & 1 && e)
    for (let o of e)
        o.create(); if (n & 2 && t)
    for (let o of t)
        o.update(); }; }
function fm(e) { let t = e[Rt].kind; return t === "input" || t === "twoWay"; }
var ga = class extends HE {
    _rootLView;
    _hasInputBindings;
    instance;
    hostView;
    changeDetectorRef;
    componentType;
    location;
    previousInputValues = null;
    _tNode;
    constructor(t, n, o) { super(), this._rootLView = n, this._hasInputBindings = o, this._tNode = Kt(n[m], I), this.location = xo(this._tNode, n), this.instance = me(this._tNode.index, n)[j], this.hostView = this.changeDetectorRef = new sn(n, void 0), this.componentType = t; }
    setInput(t, n) { this._hasInputBindings; let o = this._tNode; if (this.previousInputValues ??= new Map, this.previousInputValues.has(t) && Object.is(this.previousInputValues.get(t), n))
        return; let r = this._rootLView, i = nc(o, r[m], r, t, n); this.previousInputValues.set(t, n); let s = me(o.index, r); ic(s, 1); }
    get injector() { return new Me(this._tNode, this._rootLView); }
    destroy() { this.hostView.destroy(); }
    onDestroy(t) { this.hostView.onDestroy(t); }
};
function LR(e, t, n) { let o = e.projection = []; for (let r = 0; r < t.length; r++) {
    let i = n[r];
    o.push(i != null && i.length ? Array.from(i) : null);
} }
var hc = (() => { class e {
    static __NG_ELEMENT_ID__ = PR;
} return e; })();
function PR() { let e = _(); return rI(e, g()); }
var gd = class e extends hc {
    _lContainer;
    _hostTNode;
    _hostLView;
    constructor(t, n, o) { super(), this._lContainer = t, this._hostTNode = n, this._hostLView = o; }
    get element() { return xo(this._hostTNode, this._hostLView); }
    get injector() { return new Me(this._hostTNode, this._hostLView); }
    get parentInjector() { let t = Hd(this._hostTNode, this._hostLView); if (sv(t)) {
        let n = Ks(t, this._hostLView), o = Ys(t), r = n[m].data[o + 8];
        return new Me(r, n);
    }
    else
        return new Me(null, this._hostLView); }
    clear() { for (; this.length > 0;)
        this.remove(this.length - 1); }
    get(t) { let n = pm(this._lContainer); return n !== null && n[t] || null; }
    get length() { return this._lContainer.length - U; }
    createEmbeddedView(t, n, o) { let r, i; typeof o == "number" ? r = o : o != null && (r = o.index, i = o.injector); let s = ti(this._lContainer, t.ssrId), a = t.createEmbeddedViewImpl(n || {}, i, s); return this.insertImpl(a, r, An(this._hostTNode, s)), a; }
    createComponent(t, n, o, r, i, s, a) { let c, l = n || {}; c = l.index, o = l.injector, r = l.projectableNodes, i = l.environmentInjector || l.ngModuleRef, s = l.directives, a = l.bindings; let u = new xn(W(t)), d = o || this.parentInjector; if (!i && u.ngModule == null) {
        let T = this.parentInjector.get(be, null);
        T && (i = T);
    } let f = W(u.componentType ?? {}), p = ti(this._lContainer, f?.id ?? null), h = p?.firstChild ?? null, v = u.create(d, r, h, i, s, a); return this.insertImpl(v.hostView, c, An(this._hostTNode, p)), v; }
    insert(t, n) { return this.insertImpl(t, n, !0); }
    insertImpl(t, n, o) { let r = t._lView; if (cg(r)) {
        let a = this.indexOf(t);
        if (a !== -1)
            this.detach(a);
        else {
            let c = r[z], l = new e(c, c[ce], c[z]);
            l.detach(l.indexOf(t));
        }
    } let i = this._adjustIndex(n), s = this._lContainer; return $o(s, r, i, o), t.attachToViewContainerRef(), vl(Iu(s), i, t), t; }
    move(t, n) { return this.insert(t, n); }
    indexOf(t) { let n = pm(this._lContainer); return n !== null ? n.indexOf(t) : -1; }
    remove(t) { let n = this._adjustIndex(t, -1), o = Jr(this._lContainer, n); o && (gr(Iu(this._lContainer), n), Si(o[m], o)); }
    detach(t) { let n = this._adjustIndex(t, -1), o = Jr(this._lContainer, n); return o && gr(Iu(this._lContainer), n) != null ? new sn(o) : null; }
    _adjustIndex(t, n = 0) { return t ?? this.length + n; }
};
function pm(e) { return e[Dr]; }
function Iu(e) { return e[Dr] || (e[Dr] = []); }
function rI(e, t) { let n, o = t[e.index]; return K(o) ? n = o : (n = pE(o, t, null, e), t[e.index] = n, Of(t, n)), iI(n, t, e, o), new gd(n, e, t); }
function FR(e, t) { let n = e[N], o = n.createComment(""), r = ie(t, e), i = n.parentNode(r); return _n(n, i, o, n.nextSibling(r), !1), o; }
var iI = aI, Zf = () => !1;
function sI(e, t, n) { return Zf(e, t, n); }
function aI(e, t, n, o) { if (e[ot])
    return; let r; n.type & 8 ? r = O(o) : r = FR(t, n), e[ot] = r; }
function jR(e, t, n) { if (e[ot] && e[je])
    return !0; let o = n[fe], r = t.index - I; if (!o || ko(t) || Fa(o, r))
    return !1; let s = Uu(o, r), a = o.data[Oo]?.[r]; if (a === void 0)
    return !1; let [c, l] = JA(s, a); return e[ot] = c, e[je] = l, !0; }
function VR(e, t, n, o) { Zf(e, n, t) || aI(e, t, n, o); }
function cI() { iI = VR, Zf = jR; }
var md = class e {
    queryList;
    matches = null;
    constructor(t) { this.queryList = t; }
    clone() { return new e(this.queryList); }
    setDirty() { this.queryList.setDirty(); }
}, vd = class e {
    queries;
    constructor(t = []) { this.queries = t; }
    createEmbeddedView(t) { let n = t.queries; if (n !== null) {
        let o = t.contentQueries !== null ? t.contentQueries[0] : n.length, r = [];
        for (let i = 0; i < o; i++) {
            let s = n.getByIndex(i), a = this.queries[s.indexInDeclarationView];
            r.push(a.clone());
        }
        return new e(r);
    } return null; }
    insertView(t) { this.dirtyQueriesWithMatches(t); }
    detachView(t) { this.dirtyQueriesWithMatches(t); }
    finishViewCreation(t) { this.dirtyQueriesWithMatches(t); }
    dirtyQueriesWithMatches(t) { for (let n = 0; n < this.queries.length; n++)
        Kf(t, n).matches !== null && this.queries[n].setDirty(); }
}, ma = class {
    flags;
    read;
    predicate;
    constructor(t, n, o = null) { this.flags = n, this.read = o, typeof t == "string" ? this.predicate = qR(t) : this.predicate = t; }
}, yd = class e {
    queries;
    constructor(t = []) { this.queries = t; }
    elementStart(t, n) { for (let o = 0; o < this.queries.length; o++)
        this.queries[o].elementStart(t, n); }
    elementEnd(t) { for (let n = 0; n < this.queries.length; n++)
        this.queries[n].elementEnd(t); }
    embeddedTView(t) { let n = null; for (let o = 0; o < this.length; o++) {
        let r = n !== null ? n.length : 0, i = this.getByIndex(o).embeddedTView(t, r);
        i && (i.indexInDeclarationView = o, n !== null ? n.push(i) : n = [i]);
    } return n !== null ? new e(n) : null; }
    template(t, n) { for (let o = 0; o < this.queries.length; o++)
        this.queries[o].template(t, n); }
    getByIndex(t) { return this.queries[t]; }
    get length() { return this.queries.length; }
    track(t) { this.queries.push(t); }
}, Ed = class e {
    metadata;
    matches = null;
    indexInDeclarationView = -1;
    crossesNgTemplate = !1;
    _declarationNodeIndex;
    _appliesToNextNode = !0;
    constructor(t, n = -1) { this.metadata = t, this._declarationNodeIndex = n; }
    elementStart(t, n) { this.isApplyingToNode(n) && this.matchTNode(t, n); }
    elementEnd(t) { this._declarationNodeIndex === t.index && (this._appliesToNextNode = !1); }
    template(t, n) { this.elementStart(t, n); }
    embeddedTView(t, n) { return this.isApplyingToNode(t) ? (this.crossesNgTemplate = !0, this.addMatch(-t.index, n), new e(this.metadata)) : null; }
    isApplyingToNode(t) { if (this._appliesToNextNode && (this.metadata.flags & 1) !== 1) {
        let n = this._declarationNodeIndex, o = t.parent;
        for (; o !== null && o.type & 8 && o.index !== n;)
            o = o.parent;
        return n === (o !== null ? o.index : -1);
    } return this._appliesToNextNode; }
    matchTNode(t, n) { let o = this.metadata.predicate; if (Array.isArray(o))
        for (let r = 0; r < o.length; r++) {
            let i = o[r];
            this.matchTNodeWithReadOption(t, n, HR(n, i)), this.matchTNodeWithReadOption(t, n, $s(n, t, i, !1, !1));
        }
    else
        o === Xr ? n.type & 4 && this.matchTNodeWithReadOption(t, n, -1) : this.matchTNodeWithReadOption(t, n, $s(n, t, o, !1, !1)); }
    matchTNodeWithReadOption(t, n, o) { if (o !== null) {
        let r = this.metadata.read;
        if (r !== null)
            if (r === gi || r === hc || r === Xr && n.type & 4)
                this.addMatch(n.index, -2);
            else {
                let i = $s(n, t, r, !1, !1);
                i !== null && this.addMatch(n.index, i);
            }
        else
            this.addMatch(n.index, o);
    } }
    addMatch(t, n) { this.matches === null ? this.matches = [t, n] : this.matches.push(t, n); }
};
function HR(e, t) { let n = e.localNames; if (n !== null) {
    for (let o = 0; o < n.length; o += 2)
        if (n[o] === t)
            return n[o + 1];
} return null; }
function BR(e, t) { return e.type & 11 ? xo(e, t) : e.type & 4 ? sc(e, t) : null; }
function $R(e, t, n, o) { return n === -1 ? BR(t, e) : n === -2 ? UR(e, t, o) : Wr(e, e[m], n, t); }
function UR(e, t, n) { if (n === gi)
    return xo(t, e); if (n === Xr)
    return sc(t, e); if (n === hc)
    return rI(t, e); }
function lI(e, t, n, o) { let r = t[lt].queries[o]; if (r.matches === null) {
    let i = e.data, s = n.matches, a = [];
    for (let c = 0; s !== null && c < s.length; c += 2) {
        let l = s[c];
        if (l < 0)
            a.push(null);
        else {
            let u = i[l];
            a.push($R(t, u, s[c + 1], n.metadata.read));
        }
    }
    r.matches = a;
} return r.matches; }
function Id(e, t, n, o) { let r = e.queries.getByIndex(n), i = r.matches; if (i !== null) {
    let s = lI(e, t, r, n);
    for (let a = 0; a < i.length; a += 2) {
        let c = i[a];
        if (c > 0)
            o.push(s[a / 2]);
        else {
            let l = i[a + 1], u = t[-c];
            for (let d = U; d < u.length; d++) {
                let f = u[d];
                f[Yt] === f[z] && Id(f[m], f, l, o);
            }
            if (u[vn] !== null) {
                let d = u[vn];
                for (let f = 0; f < d.length; f++) {
                    let p = d[f];
                    Id(p[m], p, l, o);
                }
            }
        }
    }
} return o; }
function Yf(e, t) { return e[lt].queries[t].queryList; }
function uI(e, t, n) { let o = new na((n & 4) === 4); return lg(e, t, o, o.destroy), (t[lt] ??= new vd).queries.push(new md(o)) - 1; }
function dI(e, t, n) { let o = A(); return o.firstCreatePass && (pI(o, new ma(e, t, n), -1), (t & 2) === 2 && (o.staticViewQueries = !0)), uI(o, g(), t); }
function fI(e, t, n, o) { let r = A(); if (r.firstCreatePass) {
    let i = _();
    pI(r, new ma(t, n, o), i.index), GR(r, e), (n & 2) === 2 && (r.staticContentQueries = !0);
} return uI(r, g(), n); }
function qR(e) { return e.split(",").map(t => t.trim()); }
function pI(e, t, n) { e.queries === null && (e.queries = new yd), e.queries.track(new Ed(t, n)); }
function GR(e, t) { let n = e.contentQueries || (e.contentQueries = []), o = n.length ? n[n.length - 1] : -1; t !== o && n.push(e.queries.length - 1, t); }
function Kf(e, t) { return e.queries.getByIndex(t); }
function hI(e, t) { let n = e[m], o = Kf(n, t); return o.crossesNgTemplate ? Id(n, e, t, []) : lI(n, e, o, t); }
function Jf(e, t, n) { let o, r = Zi(() => { o._dirtyCounter(); let i = WR(o, e); if (t && i === void 0)
    throw new D(-951, !1); return i; }); return o = r[ae], o._dirtyCounter = mt(0), o._flatValue = void 0, r; }
function Xf(e) { return Jf(!0, !1, e); }
function ep(e) { return Jf(!0, !0, e); }
function tp(e) { return Jf(!1, !1, e); }
function gI(e, t) { let n = e[ae]; n._lView = g(), n._queryIndex = t, n._queryList = Yf(n._lView, t), n._queryList.onDirty(() => n._dirtyCounter.update(o => o + 1)); }
function WR(e, t) { let n = e._lView, o = e._queryIndex; if (n === void 0 || o === void 0 || n[w] & 4)
    return t ? void 0 : F; let r = Yf(n, o), i = hI(n, o); return r.reset(i, Mv), t ? r.first : r._changesDetected || e._flatValue === void 0 ? e._flatValue = r.toArray() : e._flatValue; }
function np(e) { return !!e && typeof e.then == "function"; }
function mI(e) { return !!e && typeof e.subscribe == "function"; }
var kn = class {
}, vI = class {
};
function zR(e, t) { return new No(e, t ?? null, []); }
var No = class extends kn {
    ngModuleType;
    _parent;
    _bootstrapComponents = [];
    _r3Injector;
    instance;
    destroyCbs = [];
    constructor(t, n, o, r = !0) { super(), this.ngModuleType = t, this._parent = n; let i = Zn(t); this._bootstrapComponents = xr(i.bootstrap), this._r3Injector = eu(t, n, [{ provide: kn, useValue: this }, ...o], sr(t), new Set(["environment"])), r && this.resolveInjectorInitializers(); }
    resolveInjectorInitializers() { this._r3Injector.resolveInjectorInitializers(), this.instance = this._r3Injector.get(this.ngModuleType); }
    get injector() { return this._r3Injector; }
    destroy() { let t = this._r3Injector; !t.destroyed && t.destroy(), this.destroyCbs.forEach(n => n()), this.destroyCbs = null; }
    onDestroy(t) { this.destroyCbs.push(t); }
}, _o = class extends vI {
    moduleType;
    constructor(t) { super(), this.moduleType = t; }
    create(t) { return new No(this.moduleType, t, []); }
};
function yI(e, t, n) { return new No(e, t, n, !1); }
var ri = class extends kn {
    injector;
    instance = null;
    constructor(t) { super(); let n = new et([...t.providers, { provide: kn, useValue: this }], t.parent || Jn(), t.debugName, new Set(["environment"])); this.injector = n, t.runEnvironmentInitializers && n.resolveInjectorInitializers(); }
    destroy() { this.injector.destroy(); }
    onDestroy(t) { this.injector.onDestroy(t); }
};
function op(e, t, n = null) { return new ri({ providers: e, parent: t, debugName: n, runEnvironmentInitializers: !0 }).injector; }
var QR = (() => { class e {
    _injector;
    cachedInjectors = new Map;
    constructor(n) { this._injector = n; }
    getOrCreateStandaloneInjector(n) { if (!n.standalone)
        return null; if (!this.cachedInjectors.has(n)) {
        let o = ds(!1, n.type), r = o.length > 0 ? op([o], this._injector, "") : null;
        this.cachedInjectors.set(n, r);
    } return this.cachedInjectors.get(n); }
    ngOnDestroy() { try {
        for (let n of this.cachedInjectors.values())
            n !== null && n.destroy();
    }
    finally {
        this.cachedInjectors.clear();
    } }
    static \u0275prov = Y({ token: e, providedIn: "environment", factory: () => new e(he(be)) });
} return e; })();
function EI(e) { return Et(() => { let t = CI(e), n = Ie(q({}, t), { decls: e.decls, vars: e.vars, template: e.template, consts: e.consts || null, ngContentSelectors: e.ngContentSelectors, onPush: e.changeDetection !== _a.Eager, directiveDefs: null, pipeDefs: null, dependencies: t.standalone && e.dependencies || null, getStandaloneInjector: t.standalone ? r => r.get(QR).getOrCreateStandaloneInjector(n) : null, getExternalStyles: null, signals: e.signals ?? !1, data: e.data || {}, encapsulation: e.encapsulation || Ke.Emulated, styles: e.styles || F, _: null, schemas: e.schemas || null, tView: null, id: "" }); t.standalone && te("NgStandalone"), MI(n); let o = e.dependencies; return n.directiveDefs = va(o, II), n.pipeDefs = va(o, tt), n.id = JR(n), n; }); }
function II(e) { return W(e) || Oe(e); }
function rp(e) { return Et(() => ({ type: e.type, bootstrap: e.bootstrap || F, declarations: e.declarations || F, imports: e.imports || F, exports: e.exports || F, transitiveCompileScopes: null, schemas: e.schemas || null, id: e.id || null })); }
function ZR(e, t) { if (e == null)
    return wt; let n = {}; for (let o in e)
    if (e.hasOwnProperty(o)) {
        let r = e[o], i, s, a, c;
        Array.isArray(r) ? (a = r[0], i = r[1], s = r[2] ?? i, c = r[3] || null) : (i = r, s = r, a = Ka.None, c = null), n[i] = [o, a, c], t[i] = s;
    } return n; }
function YR(e) { if (e == null)
    return wt; let t = {}; for (let n in e)
    e.hasOwnProperty(n) && (t[e[n]] = n); return t; }
function DI(e) { return Et(() => { let t = CI(e); return MI(t), t; }); }
function TI(e) { return { type: e.type, name: e.name, factory: null, pure: e.pure !== !1, standalone: e.standalone ?? !0, onDestroy: e.type.prototype.ngOnDestroy || null }; }
function CI(e) { let t = {}; return { type: e.type, providersResolver: null, viewProvidersResolver: null, factory: null, hostBindings: e.hostBindings || null, hostVars: e.hostVars || 0, hostAttrs: e.hostAttrs || null, contentQueries: e.contentQueries || null, declaredInputs: t, inputConfig: e.inputs || wt, exportAs: e.exportAs || null, standalone: e.standalone ?? !0, signals: e.signals === !0, selectors: e.selectors || F, viewQuery: e.viewQuery || null, features: e.features || null, setInput: null, resolveHostDirectives: null, hostDirectives: null, controlDef: null, signalFormsInputPresence: null, inputs: ZR(e.inputs, t), outputs: YR(e.outputs), debugInfo: null }; }
function MI(e) { e.features?.forEach(t => t(e)); }
function va(e, t) { return e ? () => { let n = typeof e == "function" ? e() : e, o = []; for (let r of n) {
    let i = t(r);
    i !== null && o.push(i);
} return o; } : null; }
var KR = new Map;
function JR(e) { let t = 0, n = typeof e.consts == "function" ? "" : e.consts, o = [e.selectors, e.ngContentSelectors, e.hostVars, e.hostAttrs, n, e.vars, e.decls, e.encapsulation, e.standalone, e.signals, e.exportAs, JSON.stringify(e.inputs), JSON.stringify(e.outputs), Object.getOwnPropertyNames(e.type.prototype), !!e.contentQueries, !!e.viewQuery]; for (let i of o.join("|"))
    t = Math.imul(31, t) + i.charCodeAt(0) << 0; return t += 2147483648, "c" + t; }
var Fr = "__ngAsyncComponentMetadataFn__", wI = "__ngAsyncMetadataLoaded__";
function XR(e) { let t = e; return t[Fr] === wI ? null : t[Fr] ?? null; }
function NI(e, t, n) { let o = e; return o[Fr] = () => Promise.all(t()).then(r => (n(...r), o[Fr] = wI, r)), o[Fr]; }
function ip(e, t, n, o) { return Et(() => { let r = e; t !== null && (r.hasOwnProperty("decorators") && r.decorators !== void 0 ? r.decorators.push(...t) : r.decorators = t), n !== null && (r.ctorParameters = n), o !== null && (r.hasOwnProperty("propDecorators") && r.propDecorators !== void 0 ? r.propDecorators = q(q({}, r.propDecorators), o) : r.propDecorators = o); }); }
var sp = new C("");
function _I(e) { return Pe([{ provide: sp, multi: !0, useValue: e }]); }
var ap = (() => { class e {
    resolve;
    reject;
    initialized = !1;
    done = !1;
    donePromise = new Promise((n, o) => { this.resolve = n, this.reject = o; });
    appInits = E(sp, { optional: !0 }) ?? [];
    injector = E(oe);
    constructor() { }
    runInitializers() { if (this.initialized)
        return; let n = []; for (let r of this.appInits) {
        let i = Er(this.injector, r);
        if (np(i))
            n.push(i);
        else if (mI(i)) {
            let s = new Promise((a, c) => { i.subscribe({ complete: a, error: c }); });
            n.push(s);
        }
    } let o = () => { this.done = !0, this.resolve(); }; Promise.all(n).then(() => { o(); }).catch(r => { this.reject(r); }), n.length === 0 && o(), this.initialized = !0; }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Lt({ token: e, factory: e.\u0275fac });
} return e; })(), On = new Map, ii = new Set;
function SI(e) { return Se(this, null, function* () { let t = On; On = new Map; let n = new Map; function o(i) { let s = n.get(i); if (s)
    return s; let a = e(i).then(c => rx(i, c)); return n.set(i, a), a; } let r = Array.from(t).map(a => Se(null, [a], function* ([i, s]) { if (s.styleUrl && s.styleUrls?.length)
    throw new Error("@Component cannot define both `styleUrl` and `styleUrls`. Use `styleUrl` if the component has one stylesheet, or `styleUrls` if it has multiple"); let c = []; s.templateUrl && c.push(o(s.templateUrl).then(f => { s.template = f; })); let l = typeof s.styles == "string" ? [s.styles] : s.styles ?? []; s.styles = l; let { styleUrl: u, styleUrls: d } = s; if (u && (d = [u], s.styleUrl = void 0), d?.length) {
    let f = Promise.all(d.map(p => o(p))).then(p => { l.push(...p), s.styleUrls = void 0; });
    c.push(f);
} yield Promise.all(c), ii.delete(i); })); yield Promise.all(r); }); }
function ex(e, t) { bI(t) && (On.set(e, t), ii.add(e)); }
function tx(e) { return ii.has(e); }
function bI(e) { return !!(e.templateUrl && !e.hasOwnProperty("template") || e.styleUrls?.length || e.styleUrl); }
function nx() { let e = On; return On = new Map, e; }
function ox(e) { ii.clear(); for (let t of e.keys())
    ii.add(t); On = e; }
function AI() { return On.size === 0; }
function rx(e, t) { return Se(this, null, function* () { if (typeof t == "string")
    return t; if (t.status !== void 0 && t.status !== 200)
    throw new D(918, !1); return t.text(); }); }
var Dd = new Map, RI = !0;
function ix(e, t, n) { if (t && t !== n && RI)
    throw new D(921, !1); }
function cp(e, t) { let n = Dd.get(t) || null; ix(t, n, e), Dd.set(t, e); }
function lp(e) { return Dd.get(e); }
function sx(e) { RI = !e; }
function xI(e) { return t => { t.controlDef = { create: (n, o) => { n?.\u0275ngControlCreate(o); }, update: (n, o) => { n?.\u0275ngControlUpdate?.(o); }, passThroughInput: e }; }; }
function kI(e) { let t = n => { let o = Array.isArray(e); n.hostDirectives === null ? (n.resolveHostDirectives = ax, n.hostDirectives = o ? e.map(Td) : [e]) : o ? n.hostDirectives.unshift(...e.map(Td)) : n.hostDirectives.unshift(e); }; return t.ngInherit = !0, t; }
function ax(e) { let t = [], n = !1, o = null, r = null; for (let i = 0; i < e.length; i++) {
    let s = e[i];
    if (s.hostDirectives !== null) {
        let a = t.length;
        o ??= new Map, r ??= new Map, OI(s, t, o, e), r.set(s, [a, t.length - 1]);
    }
    i === 0 && Ze(s) && (n = !0, t.push(s));
} for (let i = n ? 1 : 0; i < e.length; i++)
    t.push(e[i]); return o !== null && o.forEach((i, s) => { cx(s.declaredInputs, i.inputs); }), [t, o, r]; }
function OI(e, t, n, o) { if (e.hostDirectives !== null)
    for (let r of e.hostDirectives)
        if (typeof r == "function") {
            let i = r();
            for (let s of i)
                hm(Td(s), t, n, o);
        }
        else
            hm(r, t, n, o); }
function hm(e, t, n, o) { let r = Oe(e.directive); if (OI(r, t, n, o), n.has(r)) {
    let i = n.get(r);
    gm(i, e.inputs, "input"), gm(i, e.outputs, "output");
}
else
    o.includes(r) || (n.set(r, e), t.push(r)); }
function gm(e, t, n) { let o = n === "input" ? e.inputs : e.outputs; Object.keys(t).forEach(r => { let i = t[r]; (!o.hasOwnProperty(r) || o[r] === i) && (o[r] = i); }); }
function Td(e) { return typeof e == "function" ? { directive: P(e), inputs: {}, outputs: {} } : { directive: P(e.directive), inputs: mm(e.inputs), outputs: mm(e.outputs) }; }
function mm(e) { let t = {}; if (e !== void 0 && e.length > 0)
    for (let n = 0; n < e.length; n += 2)
        t[e[n]] = e[n + 1]; return t; }
function cx(e, t) { for (let n in t)
    if (t.hasOwnProperty(n)) {
        let o = t[n], r = e[n];
        e[o] = r;
    } }
function lx(e) { return Object.getPrototypeOf(e.prototype).constructor; }
function up(e) { let t = lx(e.type), n = !0, o = [e]; for (; t;) {
    let r;
    if (Ze(e))
        r = t.\u0275cmp || t.\u0275dir;
    else {
        if (t.\u0275cmp)
            throw new D(903, !1);
        r = t.\u0275dir;
    }
    if (r) {
        if (n) {
            o.push(r);
            let s = e;
            s.inputs = Du(e.inputs), s.declaredInputs = Du(e.declaredInputs), s.outputs = Du(e.outputs);
            let a = r.hostBindings;
            a && hx(e, a);
            let c = r.viewQuery, l = r.contentQueries;
            if (c && fx(e, c), l && px(e, l), ux(e, r), Qh(e.outputs, r.outputs), Ze(r) && r.data.animation) {
                let u = e.data;
                u.animation = (u.animation || []).concat(r.data.animation);
            }
        }
        let i = r.features;
        if (i)
            for (let s = 0; s < i.length; s++) {
                let a = i[s];
                a && a.ngInherit && a(e), a === up && (n = !1);
            }
    }
    t = Object.getPrototypeOf(t);
} dx(o); }
function ux(e, t) { for (let n in t.inputs) {
    if (!t.inputs.hasOwnProperty(n) || e.inputs.hasOwnProperty(n))
        continue;
    let o = t.inputs[n];
    o !== void 0 && (e.inputs[n] = o, e.declaredInputs[n] = t.declaredInputs[n]);
} }
function dx(e) { let t = 0, n = null; for (let o = e.length - 1; o >= 0; o--) {
    let r = e[o];
    r.hostVars = t += r.hostVars, r.hostAttrs = To(r.hostAttrs, n = To(n, r.hostAttrs));
} }
function Du(e) { return e === wt ? {} : e === F ? [] : e; }
function fx(e, t) { let n = e.viewQuery; n ? e.viewQuery = (o, r) => { t(o, r), n(o, r); } : e.viewQuery = t; }
function px(e, t) { let n = e.contentQueries; n ? e.contentQueries = (o, r, i) => { t(o, r, i), n(o, r, i); } : e.contentQueries = t; }
function hx(e, t) { let n = e.hostBindings; n ? e.hostBindings = (o, r) => { t(o, r), n(o, r); } : e.hostBindings = t; }
function LI(e, t, n, o, r, i, s, a) { if (n.firstCreatePass) {
    e.mergedAttrs = To(e.mergedAttrs, e.attrs);
    let u = e.tView = xf(2, e, r, i, s, n.directiveRegistry, n.pipeRegistry, null, n.schemas, n.consts, null);
    n.queries !== null && (n.queries.template(n, e), u.queries = n.queries.embeddedTView(e));
} a && (e.flags |= a), dt(e, !1); let c = PI(n, t, e, o); _r() && Af(n, t, c, e), Ye(c, t); let l = pE(c, t, c, e); t[o + I] = l, Of(t, l), sI(l, e, t); }
function gx(e, t, n, o, r, i, s, a, c, l, u) { let d = n + I, f; return t.firstCreatePass ? (f = $n(t, d, 4, s || null, a || null), vs() && XE(t, e, f, ve(t.consts, l), Ff), nv(t, f)) : f = t.data[d], LI(f, e, t, n, o, r, i, c), Xn(f) && Ja(t, e, f), l != null && Ho(e, f, u), f; }
function Ln(e, t, n, o, r, i, s, a, c, l, u) { let d = n + I, f; if (t.firstCreatePass) {
    if (f = $n(t, d, 4, s || null, a || null), l != null) {
        let p = ve(t.consts, l);
        f.localNames = [];
        for (let h = 0; h < p.length; h += 2)
            f.localNames.push(p[h], -1);
    }
}
else
    f = t.data[d]; return LI(f, e, t, n, o, r, i, c), l != null && Ho(e, f, u), f; }
function dp(e, t, n, o, r, i, s, a) { let c = g(), l = A(), u = ve(l.consts, i); return gx(c, l, e, t, n, o, r, u, void 0, s, a), dp; }
function fp(e, t, n, o, r, i, s, a) { let c = g(), l = A(), u = ve(l.consts, i); return Ln(c, l, e, t, n, o, r, u, void 0, s, a), fp; }
var PI = FI;
function FI(e, t, n, o) { return it(!0), t[N].createComment(""); }
function mx(e, t, n, o) { let r = !ja(t, n); it(r); let i = t[fe]?.data[ba]?.[o] ?? null; if (i !== null && n.tView !== null && n.tView.ssrId === null && (n.tView.ssrId = i), r)
    return FI(e, t); let s = t[fe], a = Ai(s, e, t, n); Pa(s, o, a); let c = af(s, o); return cc(c, a); }
function jI() { PI = mx; }
var ue = (function (e) { return e[e.NOT_STARTED = 0] = "NOT_STARTED", e[e.IN_PROGRESS = 1] = "IN_PROGRESS", e[e.COMPLETE = 2] = "COMPLETE", e[e.FAILED = 3] = "FAILED", e; })(ue || {}), vm = 0, vx = 1, Q = (function (e) { return e[e.Placeholder = 0] = "Placeholder", e[e.Loading = 1] = "Loading", e[e.Complete = 2] = "Complete", e[e.Error = 3] = "Error", e; })(Q || {}), si = (function (e) { return e[e.Initial = -1] = "Initial", e; })(si || {}), Eo = 0, Vt = 1, Or = 2, Fs = 3, yx = 4, Ex = 5, gc = 6, Ix = 7, Io = 8, Dx = 9, pp = (function (e) { return e[e.Manual = 0] = "Manual", e[e.Playthrough = 1] = "Playthrough", e; })(pp || {});
function Ri(e, t, n) { let o = HI(e); t[o] === null && (t[o] = []), t[o].push(n); }
function Ws(e, t) { let n = HI(e), o = t[n]; if (o !== null) {
    for (let r of o)
        r();
    t[n] = null;
} }
function VI(e) { Ws(1, e), Ws(0, e), Ws(2, e); }
function HI(e) { let t = yx; return e === 1 ? t = Ex : e === 2 && (t = Dx), t; }
function xi(e) { return e + 1; }
function Ne(e, t) { let n = e[m], o = xi(t.index); return e[o]; }
function Tx(e, t, n) { let o = e[m], r = xi(t); e[r] = n; }
function pe(e, t) { let n = xi(t.index); return e.data[n]; }
function Cx(e, t, n) { let o = xi(t); e.data[o] = n; }
function Mx(e, t, n) { let o = t[m], r = pe(o, n); switch (e) {
    case Q.Complete: return r.primaryTmplIndex;
    case Q.Loading: return r.loadingTmplIndex;
    case Q.Error: return r.errorTmplIndex;
    case Q.Placeholder: return r.placeholderTmplIndex;
    default: return null;
} }
function Cd(e, t) { return t === Q.Placeholder ? e.placeholderBlockConfig?.[vm] ?? null : t === Q.Loading ? e.loadingBlockConfig?.[vm] ?? null : null; }
function BI(e) { return e.loadingBlockConfig?.[vx] ?? null; }
function ym(e, t) { if (!e || e.length === 0)
    return t; let n = new Set(e); for (let o of t)
    n.add(o); return e.length === n.size ? e : Array.from(n); }
function wx(e, t) { let n = t.primaryTmplIndex + I; return Kt(e, n); }
function $I(e) { return e !== null && typeof e == "object" && typeof e.primaryTmplIndex == "number"; }
function UI(e, t) { let n = null, o = xi(t.index); return I < o && o < e.bindingStartIndex && (n = pe(e, t)), !!n && $I(n); }
var Nx = (() => { class e {
    cachedInjectors = new Map;
    getOrCreateInjector(n, o, r, i) { if (!this.cachedInjectors.has(n)) {
        let s = r.length > 0 ? op(r, o, i) : null;
        this.cachedInjectors.set(n, s);
    } return this.cachedInjectors.get(n); }
    ngOnDestroy() { try {
        for (let n of this.cachedInjectors.values())
            n !== null && n.destroy();
    }
    finally {
        this.cachedInjectors.clear();
    } }
    static \u0275prov = Y({ token: e, providedIn: "environment", factory: () => new e });
} return e; })();
function mc(e) { return (t, n) => qI(e, t, n); }
function qI(e, t, n) { let o = n.get(GI), r = n.get(G), i = () => o.remove(t); return o.add(e, t, r), i; }
var GI = (() => { class e {
    executingCallbacks = !1;
    timeoutId = null;
    invokeTimerAt = null;
    current = [];
    deferred = [];
    add(n, o, r) { let i = this.executingCallbacks ? this.deferred : this.current; this.addToQueue(i, Date.now() + n, o), this.scheduleTimer(r); }
    remove(n) { let { current: o, deferred: r } = this; this.removeFromQueue(o, n) === -1 && this.removeFromQueue(r, n), o.length === 0 && r.length === 0 && this.clearTimeout(); }
    addToQueue(n, o, r) { let i = n.length; for (let s = 0; s < n.length; s += 2)
        if (n[s] > o) {
            i = s;
            break;
        } El(n, i, o, r); }
    removeFromQueue(n, o) { let r = -1; for (let i = 0; i < n.length; i += 2)
        if (n[i + 1] === o) {
            r = i;
            break;
        } return r > -1 && yl(n, r, 2), r; }
    scheduleTimer(n) { let o = () => { this.clearTimeout(), this.executingCallbacks = !0; let i = [...this.current], s = Date.now(); for (let c = 0; c < i.length; c += 2) {
        let l = i[c], u = i[c + 1];
        if (l <= s)
            u();
        else
            break;
    } let a = -1; for (let c = 0; c < this.current.length && this.current[c] <= s; c += 2)
        a = c + 1; if (a >= 0 && yl(this.current, 0, a + 1), this.executingCallbacks = !1, this.deferred.length > 0) {
        for (let c = 0; c < this.deferred.length; c += 2) {
            let l = this.deferred[c], u = this.deferred[c + 1];
            this.addToQueue(this.current, l, u);
        }
        this.deferred.length = 0;
    } this.scheduleTimer(n); }; if (this.current.length > 0) {
        let i = Date.now(), s = this.current[0];
        if (this.timeoutId === null || this.invokeTimerAt && this.invokeTimerAt - s > 16) {
            this.clearTimeout();
            let a = Math.max(s - i, 16);
            this.invokeTimerAt = s, this.timeoutId = n.runOutsideAngular(() => setTimeout(() => n.run(o), a));
        }
    } }
    clearTimeout() { this.timeoutId !== null && (clearTimeout(this.timeoutId), this.timeoutId = null); }
    ngOnDestroy() { this.clearTimeout(), this.current.length = 0, this.deferred.length = 0; }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })(), _x = new C("DEFER_BLOCK_DEPENDENCY_INTERCEPTOR"), WI = new C("");
function Tu(e, t, n) { return e.get(Nx).getOrCreateInjector(t, e, n, ""); }
function Sx(e, t, n) { if (e instanceof nn) {
    let r = e.injector, i = e.parentInjector, s = Tu(i, t, n);
    return new nn(r, s);
} let o = e.get(be); if (o !== e) {
    let r = Tu(o, t, n);
    return new nn(e, r);
} return Tu(e, t, n); }
function At(e, t, n, o = !1) { let r = n[z], i = r[m]; if (ut(r))
    return; let s = Ne(r, t), a = s[Vt], c = s[Ix]; if (!(c !== null && e < c) && Im(a, e) && Im(s[Eo] ?? -1, e)) {
    let l = pe(i, t), d = !o && (typeof ngServerMode > "u" || !ngServerMode) && (BI(l) !== null || Cd(l, Q.Loading) !== null || Cd(l, Q.Placeholder)) ? Md : zI;
    try {
        d(e, s, n, t, r);
    }
    catch (f) {
        jf(r, f);
    }
} }
function bx(e, t) { let n = e[je]?.findIndex(r => r.data[Ii] === t[Vt]) ?? -1; return { dehydratedView: n > -1 ? e[je][n] : null, dehydratedViewIx: n }; }
function zI(e, t, n, o, r) { H(L.DeferBlockStateStart); let i = Mx(e, r, o); if (i !== null) {
    t[Vt] = e;
    let s = r[m], a = i + I, c = Kt(s, a), l = 0;
    Vf(n, l);
    let u;
    if (e === Q.Complete) {
        let h = pe(s, o), v = h.providers;
        v && v.length > 0 && (u = Sx(r[k], h, v));
    }
    let { dehydratedView: d, dehydratedViewIx: f } = bx(n, t), p = Bo(r, c, null, { injector: u, dehydratedView: d });
    if ($o(n, p, l, An(c, d)), Mr(p), f > -1 && n[je]?.splice(f, 1), (e === Q.Complete || e === Q.Error) && Array.isArray(t[Io])) {
        for (let h of t[Io])
            h();
        t[Io] = null;
    }
} H(L.DeferBlockStateEnd); }
function Ax(e, t, n, o, r) { let i = Date.now(), s = r[m], a = pe(s, o); if (t[Or] === null || t[Or] <= i) {
    t[Or] = null;
    let c = BI(a), l = t[Fs] !== null;
    if (e === Q.Loading && c !== null && !l) {
        t[Eo] = e;
        let u = Em(c, t, o, n, r);
        t[Fs] = u;
    }
    else {
        e > Q.Loading && l && (t[Fs](), t[Fs] = null, t[Eo] = null), zI(e, t, n, o, r);
        let u = Cd(a, e);
        u !== null && (t[Or] = i + u, Em(u, t, o, n, r));
    }
}
else
    t[Eo] = e; }
function Em(e, t, n, o, r) { return qI(e, () => { let s = t[Eo]; t[Or] = null, t[Eo] = null, s !== null && At(s, n, o); }, r[k]); }
function Im(e, t) { return e < t; }
function Wo(e, t) { let n = e[t.index]; At(Q.Placeholder, t, n); }
function Dm(e, t, n) { e.loadingPromise.then(() => { e.loadingState === ue.COMPLETE ? At(Q.Complete, t, n) : e.loadingState === ue.FAILED && At(Q.Error, t, n); }); }
var Md = null;
function QI(e, t, n, o) { let r = e.consts; n != null && (t.placeholderBlockConfig = ve(r, n)), o != null && (t.loadingBlockConfig = ve(r, o)), Md === null && (Md = Ax); }
function hp(e, t) { return !(e === 0 && typeof ngServerMode < "u" && ngServerMode || t[k].get(WI, null, { optional: !0 })?.behavior === pp.Manual); }
function gp(e, t, n, o) { let r = n.get(G); return O_(e, () => r.run(t), i => r.runOutsideAngular(() => k_(i)), o); }
function Rx(e, t, n) { return n == null ? e : n >= 0 ? xl(n, e) : e[t.index][U] ?? null; }
function xx(e, t) { return yn(I + t, e); }
function zo(e, t, n, o, r, i, s, a) { if (!hp(s, e))
    return; let c = e[k], l = c.get(G), u; function d() { if (ut(e)) {
    u.destroy();
    return;
} let f = Ne(e, t), p = f[Vt]; if (p !== si.Initial && p !== Q.Placeholder) {
    u.destroy();
    return;
} let h = Rx(e, t, o); if (!h || (u.destroy(), ut(h)))
    return; let v = xx(h, n), y = r(v, () => { l.run(() => { e !== h && ms(h, y), i(); }); }, c, a); e !== h && to(h, y), Ri(s, f, y); } u = Fy({ read: d }, { injector: c }); }
var kx = (() => { class e {
    log(n) { console.log(n); }
    warn(n) { console.warn(n); }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac, providedIn: "platform" });
} return e; })(), wd = class {
    resolverToTokenToDependencies = new WeakMap;
    resolverToProviders = new WeakMap;
    resolverToEffects = new WeakMap;
    standaloneInjectorToComponent = new WeakMap;
    reset() { this.resolverToTokenToDependencies = new WeakMap, this.resolverToProviders = new WeakMap, this.standaloneInjectorToComponent = new WeakMap; }
}, Ox = new wd;
function vc() { return Ox; }
var ZI = (function (e) { return e[e.Defer = 0] = "Defer", e[e.For = 1] = "For", e; })(ZI || {});
function Lx(e) { let { standaloneInjectorToComponent: t } = vc(); if (t.has(e))
    return t.get(e); let n = e.get(kn, null, { self: !0, optional: !0 }); return n === null || n.instance === null ? null : n.instance.constructor; }
function Px(e) { let t = pi(e), { resolverToProviders: n } = vc(), o = n.get(t) ?? [], r = Array.from(Dg()).map(i => ({ token: i, isViewProvider: !1, provider: i })); return [...o, ...r]; }
function Fx(e) { let t = new Map, o = jx(t, new Set); return er(e, o, [], new Set), t; }
function jx(e, t) { return (n, o) => { if (e.has(n) || e.set(n, [o]), !t.has(o))
    for (let r of e.keys()) {
        let i = e.get(r), s = Jo(o);
        if (!s) {
            let l = o.ngModule;
            s = Jo(l);
        }
        if (!s)
            return;
        let a = i[0], c = !1;
        hr(s.imports, l => { c || (c = l.ngModule === a || l === a, c && e.get(r)?.unshift(o)); });
    } t.add(o); }; }
function Vx(e) { let t = vc().resolverToProviders.get(e) ?? []; if (Hx(e))
    return t; let n = Lx(e); if (n === null)
    return t; let o = Fx(n), r = []; for (let i of t) {
    let s = i.provider, a = s.provide;
    if (a === We || a === us)
        continue;
    let c = o.get(s) ?? [];
    W(n)?.standalone && (c = [n, ...c]), r.push(Ie(q({}, i), { importPath: c }));
} return r; }
function Hx(e) { return e instanceof et && e.scopes.has("platform"); }
function YI(e) { if (e instanceof Me)
    return Px(e); if (e instanceof be)
    return Vx(e); Gt("getInjectorProviders only supports NodeInjector and EnvironmentInjector"); }
function KI(e) { if (e instanceof Me) {
    let t = Bd(e), n = pi(e);
    return rg(n, t), { type: "element", source: ie(n, t) };
} return e instanceof et ? { type: "environment", source: e.source ?? null } : e instanceof Ct ? { type: "null", source: null } : null; }
function Bx(e) { return e.kind === "computed"; }
function $x(e) { return e.kind === "template"; }
function Ux(e) { return e.kind === "signal"; }
function qx(e) { let t = pi(e); Sl(t); let n = Bd(e); ig(n); let o = n[t.index]; return J(o) ? o[Ae] ?? null : null; }
var Tm = new WeakMap, Cm = 0;
function Gx(e) { let t = Array.from(e.keys()), n = [], o = []; for (let [r, i] of e.entries()) {
    let s = t.indexOf(r), a = Tm.get(r);
    a || (Cm++, a = Cm.toString(), Tm.set(r, a)), Bx(r) ? n.push({ label: r.debugName, value: r.value, kind: r.kind, epoch: r.version, debuggableFn: r.computation, id: a }) : Ux(r) ? n.push({ label: r.debugName, value: r.value, kind: r.kind, epoch: r.version, id: a }) : $x(r) ? n.push({ label: r.debugName ?? r.lView?.[B]?.tagName?.toLowerCase?.(), kind: r.kind, epoch: r.version, debuggableFn: r.lView?.[j]?.constructor, id: a }) : n.push({ label: r.debugName, kind: r.kind, epoch: r.version, id: a });
    for (let c of i)
        o.push({ consumer: s, producer: t.indexOf(c) });
} return { nodes: n, edges: o }; }
function Wx(e) { let t = e; return e instanceof Me && (t = Bd(e)), (vc().resolverToEffects.get(t) ?? []).map(r => r instanceof rr ? r[ae] : r.signal[ae]); }
function JI(e, t = new Map) { for (let n of e) {
    if (t.has(n))
        continue;
    let o = [];
    for (let r = n.producers; r !== void 0; r = r.nextProducer) {
        let i = r.producer;
        o.push(i);
    }
    t.set(n, o), JI(o, t);
} return t; }
function XI(e) { let t = null; if (!(e instanceof Me) && !(e instanceof et))
    return Gt("getSignalGraph must be called with a NodeInjector or R3Injector"); e instanceof Me && (t = qx(e)); let n = Wx(e), o = t ? [t, ...n] : n, r = JI(o); return Gx(r); }
function zx() { return te("Chrome DevTools profiling"), () => { }; }
function Qx(e) { let t = e.get(Nt), n = e.get(vt), o = cu(t, n), r = {}; for (let [i, s] of Object.entries(o))
    V_(i) || (r[i] = s); return r; }
var Mm = "ng";
function Zx(e, t) { Yx(e, t); }
function Yx(e, t) { if (typeof COMPILED > "u" || !COMPILED) {
    let n = Le;
    n[Mm] ??= {}, n[Mm][e] = t;
} }
var eD = new C(""), tD = new C(""), nD = new C("USE_PENDING_TASKS", { providedIn: "root", factory: () => typeof Zone > "u" }), Kx = (() => { class e {
    _ngZone;
    registry;
    _isZoneStable = !0;
    _callbacks = [];
    _taskTrackingZone = null;
    _destroyRef;
    pendingTasksInternal = E(gt);
    _usePendingTasks = E(nD);
    constructor(n, o, r) { this._ngZone = n, this.registry = o, fs() && (this._destroyRef = E(Re, { optional: !0 }) ?? void 0), mp || (rD(r), r.addToWindow(o)), this._watchAngularEvents(), n.run(() => { this._taskTrackingZone = typeof Zone > "u" ? null : Zone.current.get("TaskTrackingZone"); }); }
    _watchAngularEvents() { let n = this._ngZone.onUnstable.subscribe({ next: () => { this._isZoneStable = !1; } }), o, r; this._ngZone.runOutsideAngular(() => { this._usePendingTasks && (o = this.pendingTasksInternal.hasPendingTasksObservable.subscribe(() => { this.isStable() && this._ngZone.runOutsideAngular(() => { this._runCallbacksIfReady(); }); })), r = this._ngZone.onStable.subscribe({ next: () => { G.assertNotInAngularZone(), queueMicrotask(() => { this._isZoneStable = !0, this._runCallbacksIfReady(); }); } }); }), this._destroyRef?.onDestroy(() => { n.unsubscribe(), o?.unsubscribe(), r.unsubscribe(); }); }
    isStable() { return this._isZoneStable && !this._ngZone.hasPendingMacrotasks && (!this._usePendingTasks || !this.pendingTasksInternal.hasPendingTasks); }
    _runCallbacksIfReady() { if (this.isStable())
        queueMicrotask(() => { for (; this._callbacks.length !== 0;) {
            let n = this._callbacks.pop();
            clearTimeout(n.timeoutId), n.doneCb();
        } });
    else {
        let n = this.getPendingTasks();
        this._callbacks = this._callbacks.filter(o => o.updateCb && o.updateCb(n) ? (clearTimeout(o.timeoutId), !1) : !0);
    } }
    getPendingTasks() { return this._taskTrackingZone ? this._taskTrackingZone.macroTasks.map(n => ({ source: n.source, creationLocation: n.creationLocation, data: n.data })) : []; }
    addCallback(n, o, r) { let i = -1; o && o > 0 && (i = setTimeout(() => { this._callbacks = this._callbacks.filter(s => s.timeoutId !== i), n(); }, o)), this._callbacks.push({ doneCb: n, timeoutId: i, updateCb: r }); }
    whenStable(n, o, r) { if (r && !this._taskTrackingZone)
        throw new Error('Task tracking zone is required when passing an update callback to whenStable(). Is "zone.js/plugins/task-tracking" loaded?'); this.addCallback(n, o, r), this._runCallbacksIfReady(); }
    registerApplication(n) { this.registry.registerApplication(n, this); }
    unregisterApplication(n) { this.registry.unregisterApplication(n); }
    findProviders(n, o, r) { return []; }
    static \u0275fac = function (o) { return new (o || e)(he(G), he(oD), he(tD)); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac });
} return e; })(), oD = (() => { class e {
    _applications = new Map;
    registerApplication(n, o) { this._applications.set(n, o); }
    unregisterApplication(n) { this._applications.delete(n); }
    unregisterAllApplications() { this._applications.clear(); }
    getTestability(n) { return this._applications.get(n) || null; }
    getAllTestabilities() { return Array.from(this._applications.values()); }
    getAllRootElements() { return Array.from(this._applications.keys()); }
    findTestabilityInTree(n, o = !0) { return mp?.findTestabilityInTree(this, n, o) ?? null; }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac, providedIn: "platform" });
} return e; })();
function rD(e) { mp = e; }
var mp, ki = new C("");
function vp() { Ph(() => { let e = ""; throw new D(600, e); }); }
var Jx = 10;
function yp(e, t) { return Array.isArray(t) ? t.reduce(yp, e) : q(q({}, e), t); }
var He = (() => { class e {
    _runningTick = !1;
    _destroyed = !1;
    _destroyListeners = [];
    _views = [];
    internalErrorHandler = E(_t);
    afterRenderManager = E(Ga);
    zonelessEnabled = E(so);
    rootEffectScheduler = E(ws);
    dirtyFlags = 0;
    tracingSnapshot = null;
    allTestViews = new Set;
    autoDetectTestViews = new Set;
    includeAllTestViews = !1;
    afterTick = new Km;
    get allViews() { return [...(this.includeAllTestViews ? this.allTestViews : this.autoDetectTestViews).keys(), ...this._views]; }
    get destroyed() { return this._destroyed; }
    componentTypes = [];
    components = [];
    internalPendingTask = E(gt);
    get isStable() { return this.internalPendingTask.hasPendingTasksObservable.pipe(TN(n => !n)); }
    constructor() { E(Bn, { optional: !0 }); }
    whenStable() { let n; return new Promise(o => { n = this.isStable.subscribe({ next: r => { r && o(); } }); }).finally(() => { n.unsubscribe(); }); }
    _injector = E(be);
    _rendererFactory = null;
    get injector() { return this._injector; }
    bootstrap(n, o) { return this.bootstrapImpl(n, o); }
    bootstrapImpl(n, o, r = oe.NULL) { return this._injector.get(G).run(() => { if (H(L.BootstrapComponentStart), !this._injector.get(ap).done) {
        let T = "";
        throw new D(405, T);
    } let a = W(n), c = this._injector.get(kn), l = new xn(a, c); this.componentTypes.push(n); let { hostElement: u, directives: d, bindings: f } = Xx(o), p = u || l.selector, h = l.create(r, [], p, c.injector, d, f), v = h.location.nativeElement, y = h.injector.get(eD, null); return y?.registerApplication(v), h.onDestroy(() => { this.detachView(h.hostView), jr(this.components, h), y?.unregisterApplication(v); }), this._loadComponent(h), H(L.BootstrapComponentEnd, h), h; }); }
    tick() { this.zonelessEnabled || (this.dirtyFlags |= 1), this._tick(); }
    _tick() { H(L.ChangeDetectionStart), this.tracingSnapshot !== null ? this.tracingSnapshot.run(qa.CHANGE_DETECTION, this.tickImpl) : this.tickImpl(); }
    tickImpl = () => { if (this._runningTick)
        throw H(L.ChangeDetectionEnd), new D(101, !1); let n = x(null); try {
        this._runningTick = !0, this.synchronize();
    }
    finally {
        this._runningTick = !1, this.tracingSnapshot?.dispose(), this.tracingSnapshot = null, x(n), this.afterTick.next(), H(L.ChangeDetectionEnd);
    } };
    synchronize() { this._rendererFactory === null && !this._injector.destroyed && (this._rendererFactory = this._injector.get(ni, null, { optional: !0 })); let n = 0; for (; this.dirtyFlags !== 0 && n++ < Jx;) {
        H(L.ChangeDetectionSyncStart);
        try {
            this.synchronizeOnce();
        }
        finally {
            H(L.ChangeDetectionSyncEnd);
        }
    } }
    synchronizeOnce() { this.dirtyFlags & 16 && (this.dirtyFlags &= -17, this.rootEffectScheduler.flush()); let n = !1; if (this.dirtyFlags & 7) {
        let o = !!(this.dirtyFlags & 1);
        this.dirtyFlags &= -8, this.dirtyFlags |= 8;
        for (let { _lView: r } of this.allViews) {
            if (!o && !eo(r))
                continue;
            let i = o && !this.zonelessEnabled ? 0 : 1;
            cE(r, i), n = !0;
        }
        if (this.dirtyFlags &= -5, this.syncDirtyFlagsWithViews(), this.dirtyFlags & 23)
            return;
    } n || (this._rendererFactory?.begin?.(), this._rendererFactory?.end?.()), this.dirtyFlags & 8 && (this.dirtyFlags &= -9, this.afterRenderManager.execute()), this.syncDirtyFlagsWithViews(); }
    syncDirtyFlagsWithViews() { if (this.allViews.some(({ _lView: n }) => eo(n))) {
        this.dirtyFlags |= 2;
        return;
    }
    else
        this.dirtyFlags &= -8; }
    attachView(n) { let o = n; this._views.push(o), o.attachToAppRef(this); }
    detachView(n) { let o = n; jr(this._views, o), o.detachFromAppRef(); }
    _loadComponent(n) { this.attachView(n.hostView); try {
        this.tick();
    }
    catch (r) {
        this.internalErrorHandler(r);
    } this.components.push(n), this._injector.get(ki, []).forEach(r => r(n)); }
    ngOnDestroy() { if (!this._destroyed)
        try {
            this._destroyListeners.forEach(n => n()), this._views.slice().forEach(n => n.destroy());
        }
        finally {
            this._destroyed = !0, this._views = [], this._destroyListeners = [];
        } }
    onDestroy(n) { return this._destroyListeners.push(n), () => jr(this._destroyListeners, n); }
    destroy() { if (this._destroyed)
        throw new D(406, !1); let n = this._injector; n.destroy && !n.destroyed && n.destroy(); }
    get viewCount() { return this._views.length; }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Lt({ token: e, factory: e.\u0275fac });
} return e; })();
function Xx(e) { return e === void 0 || typeof e == "string" || e instanceof Element ? { hostElement: e } : e; }
function jr(e, t) { let n = e.indexOf(t); n > -1 && e.splice(n, 1); }
function iD(e, t, n) { let o = t.get(ek), r = () => o.remove(e); return o.add(e, n), r; }
function Ep(e) { return (t, n) => iD(t, n, e); }
var ek = (() => { class e {
    buckets = new Map;
    callbackBucket = new Map;
    applicationRef = E(He);
    ngZone = E(G);
    idleService = E(Na);
    add(n, o) { let r = wm(o); this.callbackBucket.set(n, r); let i = this.buckets.get(r); i == null && (i = { idleId: null, queue: new Set }, this.buckets.set(r, i)), i.queue.add(n), this.scheduleBucket(i, o); }
    remove(n) { let o = this.callbackBucket.get(n); if (o === void 0)
        return; this.callbackBucket.delete(n); let r = this.buckets.get(o); r && (r.queue.delete(n), r.queue.size === 0 && (this.cancelBucket(r), this.buckets.delete(o))); }
    scheduleBucket(n, o) { if (n.idleId !== null)
        return; let r = wm(o), i = s => { this.cancelBucket(n); for (let a of n.queue)
        if (a(), this.applicationRef._tick(), n.queue.delete(a), this.callbackBucket.delete(a), s && s.timeRemaining() === 0 && !s.didTimeout)
            break; n.queue.size > 0 ? this.scheduleBucket(n, o) : this.buckets.delete(r); }; n.idleId = this.idleService.requestOnIdle(s => this.ngZone.run(() => i(s)), o); }
    cancelBucket(n) { n.idleId !== null && (this.idleService.cancelOnIdle(n.idleId), n.idleId = null); }
    ngOnDestroy() { for (let n of this.buckets.values())
        this.cancelBucket(n); this.buckets.clear(), this.callbackBucket.clear(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })();
function wm(e) { return !e || e.timeout == null ? "" : `${e.timeout}`; }
function sD(e) { let t = g(), n = _(); if (Wo(t, n), !hp(0, t))
    return; let o = t[k], r = Ne(t, n), i = e(() => _e(0, t, n), o); Ri(0, r, i); }
function aD(e) { if (typeof ngServerMode < "u" && ngServerMode)
    return; let t = g(), n = t[k], o = _(), r = t[m], i = pe(r, o); if (i.loadingState === ue.NOT_STARTED) {
    let s = Ne(t, o), c = e(() => Oi(i, t, o), n);
    Ri(1, s, c);
} }
function cD(e, t, n) { if (typeof ngServerMode < "u" && ngServerMode)
    return; let o = t[k], r = Ne(t, n), i = r[gc], s = e(() => Ht(o, i), o); Ri(2, r, s); }
function Oi(e, t, n) { yc(e, t, n); }
function yc(e, t, n) { let o = t[k], r = t[m]; if (e.loadingState !== ue.NOT_STARTED)
    return e.loadingPromise ?? Promise.resolve(); let i = Ne(t, n), s = wx(r, e); e.loadingState = ue.IN_PROGRESS, Ws(1, i); let a = e.dependencyResolverFn, c = o.get(Sr).add(); return a ? (e.loadingPromise = Promise.allSettled(a()).then(l => { let u = !1, d = null, f = [], p = []; for (let h = 0; h < l.length; h++) {
    let v = l[h];
    if (v.status === "fulfilled") {
        let y = v.value, T = W(y) || Oe(y);
        if (T)
            f.push(T);
        else {
            let R = tt(y);
            R && p.push(R);
        }
    }
    else {
        u = !0, d = v.reason instanceof Error ? v.reason : new Error(String(v.reason));
        break;
    }
} if (u) {
    if (e.loadingState = ue.FAILED, e.errorTmplIndex === null) {
        let v = "", y = new D(-750, v);
        jf(t, y);
    }
}
else {
    e.loadingState = ue.COMPLETE;
    let h = s.tView;
    if (f.length > 0) {
        h.directiveRegistry = ym(h.directiveRegistry, f);
        let v = f.map(T => T.type), y = ds(!1, ...v);
        e.providers = y;
    }
    p.length > 0 && (h.pipeRegistry = ym(h.pipeRegistry, p));
} }), e.loadingPromise.finally(() => { e.loadingPromise = null, c(); })) : (e.loadingPromise = Promise.resolve().then(() => { e.loadingPromise = null, e.loadingState = ue.COMPLETE, c(); }), e.loadingPromise); }
function _e(e, t, n) { let o = t[m], r = t[n.index]; if (!hp(e, t))
    return; let i = Ne(t, n), s = pe(o, n); switch (VI(i), s.loadingState) {
    case ue.NOT_STARTED:
        At(Q.Loading, n, r), yc(s, t, n), s.loadingState === ue.IN_PROGRESS && Dm(s, n, r);
        break;
    case ue.IN_PROGRESS:
        At(Q.Loading, n, r), Dm(s, n, r);
        break;
    case ue.COMPLETE:
        At(Q.Complete, n, r);
        break;
    case ue.FAILED:
        At(Q.Error, n, r);
        break;
    default:
} }
function Ht(e, t, n) { return Se(this, null, function* () { let o = e.get(Pt); if (o.hydrating.has(t))
    return; let { parentBlockPromise: i, hydrationQueue: s } = Q_(t, e); if (s.length === 0)
    return; i !== null && s.shift(), ok(o, s), i !== null && (yield i); let a = s[0]; o.has(a) ? yield Nm(e, s, n) : o.awaitParentBlock(a, () => Se(null, null, function* () { return yield Nm(e, s, n); })); }); }
function Nm(e, t, n) { return Se(this, null, function* () { let o = e.get(Pt), r = o.hydrating, i = e.get(gt), s = i.add(); for (let c = 0; c < t.length; c++) {
    let l = t[c], u = o.get(l);
    if (u != null) {
        if (yield ik(u), yield rk(e), tk(u)) {
            YA(u), _m(t.slice(c), o);
            break;
        }
        r.get(l).resolve();
    }
    else {
        nk(c, t, o), _m(t.slice(c), o);
        break;
    }
} let a = t[t.length - 1]; yield r.get(a)?.promise, i.remove(s), n && n(t), KA(o.get(a), t, o, e.get(He)); }); }
function tk(e) { return Ne(e.lView, e.tNode)[Vt] === Q.Error; }
function nk(e, t, n) { let o = e - 1, r = o > -1 ? n.get(t[o]) : null; r && dc(r.lContainer); }
function _m(e, t) { let n = t.hydrating; for (let o in e)
    n.get(o)?.reject(); t.cleanup(e); }
function ok(e, t) { for (let n of t)
    e.hydrating.set(n, oo()); }
function rk(e) { return new Promise(t => Nf(t, { injector: e })); }
function ik(e) { return Se(this, null, function* () { let { tNode: t, lView: n } = e, o = Ne(n, t); return new Promise(r => { sk(o, r), _e(2, n, t); }); }); }
function sk(e, t) { Array.isArray(e[Io]) || (e[Io] = []), e[Io].push(t); }
function ne(e, t, n) { return e === 0 ? Sm(t, n) : e === 2 ? !Sm(t, n) : !(typeof ngServerMode < "u" && ngServerMode); }
function ak(e) { return e != null && (e & 1) === 1; }
function Sm(e, t) { let n = e[k], o = pe(e[m], t), r = Ci(n), i = ak(o.flags); if (typeof ngServerMode < "u" && ngServerMode)
    return !r || !i; let a = Ne(e, t)[gc] !== null; return !(i && a && r); }
function an(e, t) { let n = pe(e, t); return n.hydrateTriggers ??= new Map; }
function ck(e, t, n) { let o = [], r = [], i = [], s = []; for (let [a, c] of t) {
    let l = n.get(a);
    if (l !== void 0) {
        let u = c.data[xt], d = l;
        for (let f = 0; f < u; f++) {
            if (d = d.previousSibling, d.nodeType !== Node.ELEMENT_NODE)
                continue;
            let p = { el: d, blockName: a };
            c.hydrate.idle && o.push(p), c.hydrate.immediate && s.push(p), c.hydrate.timer !== null && (p.delay = c.hydrate.timer, r.push(p)), c.hydrate.viewport && (typeof c.hydrate.viewport != "boolean" && (p.intersectionObserverOptions = c.hydrate.viewport), i.push(p));
        }
    }
} lk(e, o), fk(e, s), uk(e, i), dk(e, r); }
function lk(e, t) { for (let n of t) {
    let o = e.get(Pt), i = iD(() => Ht(e, n.blockName), e);
    o.addCleanupFn(n.blockName, i);
} }
function uk(e, t) { if (t.length > 0) {
    let n = e.get(Pt);
    for (let o of t) {
        let r = gp(o.el, () => Ht(e, o.blockName), e, o.intersectionObserverOptions);
        n.addCleanupFn(o.blockName, r);
    }
} }
function dk(e, t) { for (let n of t) {
    let o = e.get(Pt), r = () => Ht(e, n.blockName), s = mc(n.delay)(r, e);
    o.addCleanupFn(n.blockName, s);
} }
function fk(e, t) { for (let n of t)
    Ht(e, n.blockName); }
function lD(e, t, n, o, r, i, s, a, c, l) { let u = g(), d = A(), f = e + I, p = Ln(u, d, e, null, 0, 0), h = u[k], v = Ci(h); if (d.firstCreatePass) {
    te("NgDefer");
    let It = { primaryTmplIndex: t, loadingTmplIndex: o ?? null, placeholderTmplIndex: r ?? null, errorTmplIndex: i ?? null, placeholderBlockConfig: null, loadingBlockConfig: null, dependencyResolverFn: n ?? null, loadingState: ue.NOT_STARTED, loadingPromise: null, providers: null, hydrateTriggers: null, debug: null, flags: l ?? 0 };
    c?.(d, It, a, s), Cx(d, f, It);
} let y = u[f]; sI(y, p, u); let T = null, R = null; if (y[je]?.length > 0) {
    let It = y[je][0].data;
    R = It[xa] ?? null, T = It[Ii];
} let se = [null, si.Initial, null, null, null, null, R, T, null, null]; Tx(u, f, se); let Xe = null; R !== null && v && (Xe = h.get(Pt), Xe.add(R, { lView: u, tNode: p, lContainer: y })); let Be = () => { VI(se), R !== null && Xe?.cleanup([R]); }; Ri(0, se, () => ms(u, Be)), to(u, Be); }
function uD(e) { let t = g(), n = Ve(); if (!ne(0, t, n))
    return; let o = De(); if (Z(t, o, e)) {
    let r = x(null);
    try {
        let i = !!e, a = Ne(t, n)[Vt];
        i === !1 && a === si.Initial ? Wo(t, n) : i === !0 && (a === si.Initial || a === Q.Placeholder) && _e(0, t, n);
    }
    finally {
        x(r);
    }
} }
function dD(e) { let t = g(), n = Ve(); if (!ne(1, t, n))
    return; let o = De(); if (Z(t, o, e)) {
    let r = x(null);
    try {
        let i = !!e, s = t[m], a = pe(s, n);
        i === !0 && a.loadingState === ue.NOT_STARTED && Oi(a, t, n);
    }
    finally {
        x(r);
    }
} }
function fD(e) { let t = g(), n = Ve(); if (!ne(2, t, n))
    return; let o = De(), r = A(); if (an(r, n).set(6, null), Z(t, o, e))
    if (typeof ngServerMode < "u" && ngServerMode)
        _e(2, t, n);
    else {
        let s = t[k], a = x(null);
        try {
            if (!!e === !0) {
                let u = Ne(t, n)[gc];
                Ht(s, u);
            }
        }
        finally {
            x(a);
        }
    } }
function pD() { let e = g(), t = _(); if (!ne(2, e, t))
    return; an(A(), t).set(7, null), typeof ngServerMode < "u" && ngServerMode && _e(2, e, t); }
function hD(e) { let t = g(), n = _(); ne(0, t, n) && sD(Ep({ timeout: e })); }
function gD(e) { let t = g(), n = _(); ne(1, t, n) && aD(Ep({ timeout: e })); }
function mD(e) { let t = g(), n = _(); if (!ne(2, t, n))
    return; an(A(), n).set(0, null), typeof ngServerMode < "u" && ngServerMode ? _e(2, t, n) : cD(Ep({ timeout: e }), t, n); }
function vD() { let e = g(), t = _(); if (!ne(0, e, t))
    return; pe(e[m], t).loadingTmplIndex === null && Wo(e, t), _e(0, e, t); }
function yD() { let e = g(), t = _(); if (!ne(1, e, t))
    return; let n = e[m], o = pe(n, t); o.loadingState === ue.NOT_STARTED && yc(o, e, t); }
function ED() { let e = g(), t = _(); if (!ne(2, e, t))
    return; if (an(A(), t).set(1, null), typeof ngServerMode < "u" && ngServerMode)
    _e(2, e, t);
else {
    let o = e[k], i = Ne(e, t)[gc];
    Ht(o, i);
} }
function ID(e) { let t = g(), n = _(); ne(0, t, n) && sD(mc(e)); }
function DD(e) { let t = g(), n = _(); ne(1, t, n) && aD(mc(e)); }
function TD(e) { let t = g(), n = _(); if (!ne(2, t, n))
    return; an(A(), n).set(5, { type: 5, delay: e }), typeof ngServerMode < "u" && ngServerMode ? _e(2, t, n) : cD(mc(e), t, n); }
function CD(e, t) { let n = g(), o = _(); ne(0, n, o) && (Wo(n, o), typeof ngServerMode < "u" && ngServerMode || zo(n, o, e, t, Bv, () => _e(0, n, o), 0)); }
function MD(e, t) { let n = g(), o = _(); if (!ne(1, n, o))
    return; let r = n[m], i = pe(r, o); i.loadingState === ue.NOT_STARTED && zo(n, o, e, t, Bv, () => Oi(i, n, o), 1); }
function wD() { let e = g(), t = _(); if (!ne(2, e, t))
    return; an(A(), t).set(4, null), typeof ngServerMode < "u" && ngServerMode && _e(2, e, t); }
function ND(e, t) { let n = g(), o = _(); ne(0, n, o) && (Wo(n, o), typeof ngServerMode < "u" && ngServerMode || zo(n, o, e, t, Hv, () => _e(0, n, o), 0)); }
function _D(e, t) { let n = g(), o = _(); if (!ne(1, n, o))
    return; let r = n[m], i = pe(r, o); i.loadingState === ue.NOT_STARTED && zo(n, o, e, t, Hv, () => Oi(i, n, o), 1); }
function SD() { let e = g(), t = _(); if (!ne(2, e, t))
    return; an(A(), t).set(3, null), typeof ngServerMode < "u" && ngServerMode && _e(2, e, t); }
function bD(e, t, n) { let o = g(), r = _(); ne(0, o, r) && (Wo(o, r), typeof ngServerMode < "u" && ngServerMode || zo(o, r, e, t, gp, () => _e(0, o, r), 0, n)); }
function AD(e, t, n) { let o = g(), r = _(); if (!ne(1, o, r))
    return; let i = o[m], s = pe(i, r); s.loadingState === ue.NOT_STARTED && zo(o, r, e, t, gp, () => Oi(s, o, r), 1, n); }
function RD(e) { let t = g(), n = _(); if (!ne(2, t, n))
    return; an(A(), n).set(2, e ? { type: 2, intersectionObserverOptions: e } : null), typeof ngServerMode < "u" && ngServerMode && _e(2, t, n); }
function Ip(e, t) { let n = g(), o = De(); if (Z(n, o, t)) {
    let r = A(), i = Ve();
    if (nc(i, r, n, e, t))
        Ce(i) && tE(n, i.index);
    else {
        let a = ie(i, n);
        Xa(n[N], a, null, i.value, e, t, null);
    }
} return Ip; }
function Dp(e, t, n, o) { let r = g(), i = De(); if (Z(r, i, t)) {
    let s = A(), a = Ve();
    Bb(a, r, e, t, n, o);
} return Dp; }
function Vr(e) { if (te("NgAnimateEnter"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Vr; let t = g(); if ($a(t))
    return Vr; let n = _(), o = t[k].get(G); return Ua(ca(t), n, () => pk(t, n, e, o)), za(t[k]), _f(t[k], ca(t)), Vr; }
function pk(e, t, n, o) { let r = ie(t, e), i = e[N], s = ky(n), a = [], c = !1, l = d => { if (Yr(d) !== r)
    return; let f = d instanceof AnimationEvent ? "animationend" : "transitionend"; o.runOutsideAngular(() => { i.listen(r, f, u); }); }, u = d => { Yr(d) === r && (Cf(d, r) && (c = !0), hk(d, r, i)); }; if (s && s.length > 0) {
    o.runOutsideAngular(() => { a.push(i.listen(r, "animationstart", l)), a.push(i.listen(r, "transitionstart", l)); }), cb(r, s, a);
    for (let d of s)
        i.addClass(r, d);
    o.runOutsideAngular(() => { requestAnimationFrame(() => { if (!c && (Py(r, wn, Hn), !wn.has(r))) {
        for (let d of s)
            i.removeClass(r, d);
        Df(r);
    } }); });
} }
function hk(e, t, n) { let o = Co.get(t); if (!(Yr(e) !== t || !o) && Cf(e, t)) {
    e.stopPropagation();
    for (let r of o.classList)
        n.removeClass(t, r);
    Df(t);
} }
function Hr(e) { if (te("NgAnimateEnter"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Hr; let t = g(); if ($a(t))
    return Hr; let n = _(); return Ua(ca(t), n, () => gk(t, n, e)), za(t[k]), _f(t[k], ca(t)), Hr; }
function gk(e, t, n) { let o = ie(t, e); n.call(e[j], { target: o, animationComplete: lb }); }
function Br(e) { if (te("NgAnimateLeave"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Br; let t = g(); if ($a(t))
    return Br; let o = _(), r = t[k].get(G); return Ua(Sn(t), o, () => mk(t, o, e, r)), za(t[k]), Br; }
function mk(e, t, n, o) { let { promise: r, resolve: i } = oo(), s = ie(t, e), a = e[N]; rn.add(e[Fe]), (Sn(e).get(t.index).resolvers ??= []).push(i); let c = ky(n); return c && c.length > 0 ? vk(s, t, e, c, a, o) : i(), { promise: r, resolve: i }; }
function vk(e, t, n, o, r, i) { db(e, r); let s = [], a = Sn(n).get(t.index)?.resolvers, c, l = !1, u = d => { if (!(Yr(d) !== e && d.type !== "animation-fallback") && (d.type === "animation-fallback" || Cf(d, e))) {
    if (l = !0, c && clearTimeout(c), d.type !== "animation-fallback" && d.stopPropagation(), wn.delete(e), rd(t, e), Array.isArray(t.projection))
        for (let p of o)
            r.removeClass(e, p);
    id(a, s), sd(n, t);
} }; i.runOutsideAngular(() => { s.push(r.listen(e, "animationend", u)), s.push(r.listen(e, "transitionend", u)); }), Tf(t, e); for (let d of o)
    r.addClass(e, d); i.runOutsideAngular(() => { requestAnimationFrame(() => { if (l)
    return; Py(e, wn, Hn); let d = wn.get(e); d ? (c = setTimeout(() => { u(new CustomEvent("animation-fallback")); }, d.duration + 50), s.push(() => clearTimeout(c))) : (rd(t, e), id(a, s), sd(n, t)); }); }); }
function ya(e) { if (te("NgAnimateLeave"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return ya; let t = g(), n = _(); rn.add(t[Fe]); let o = t[k].get(G), r = t[k].get(Ry); return Ua(Sn(t), n, () => yk(t, n, e, o, r)), za(t[k]), ya; }
function yk(e, t, n, o, r) { let { promise: i, resolve: s } = oo(), a = ie(t, e), c = [], l = e[N], u = $a(e); (Sn(e).get(t.index).resolvers ??= []).push(s); let d = Sn(e).get(t.index)?.resolvers; if (u)
    Ls(e, t, a, d, c);
else {
    let f = setTimeout(() => Ls(e, t, a, d, c), r), p = { target: a, animationComplete: () => { Ls(e, t, a, d, c), clearTimeout(f); } };
    Tf(t, a), o.runOutsideAngular(() => { c.push(l.listen(a, "animationend", () => { Ls(e, t, a, d, c), clearTimeout(f); }, { once: !0 })); }), n.call(e[j], p);
} return { promise: i, resolve: s }; }
function xD() { return g()[re][j]; }
var Nd = class {
    destroy(t) { }
    updateValue(t, n) { }
    swap(t, n) { let o = Math.min(t, n), r = Math.max(t, n), i = this.detach(r); if (r - o > 1) {
        let s = this.detach(o);
        this.attach(o, i), this.attach(r, s);
    }
    else
        this.attach(o, i); }
    move(t, n) { this.attach(n, this.detach(t)); }
};
function Cu(e, t, n, o, r) { return e === n && Object.is(t, o) ? 1 : Object.is(r(e, t), r(n, o)) ? -1 : 0; }
function Ek(e, t, n, o) { let r, i, s = 0, a = e.length - 1, c = void 0; if (Array.isArray(t)) {
    uo(o);
    let l = t.length - 1;
    for (uo(null); s <= a && s <= l;) {
        let u = e.at(s), d = t[s], f = Cu(s, u, s, d, n);
        if (f !== 0) {
            f < 0 && e.updateValue(s, d), s++;
            continue;
        }
        let p = e.at(a), h = t[l], v = Cu(a, p, l, h, n);
        if (v !== 0) {
            v < 0 && e.updateValue(a, h), a--, l--;
            continue;
        }
        let y = n(s, u), T = n(a, p), R = n(s, d);
        if (Object.is(R, T)) {
            let se = n(l, h);
            Object.is(se, y) ? (e.swap(s, a), e.updateValue(a, h), l--, a--) : e.move(a, s), e.updateValue(s, d), s++;
            continue;
        }
        if (r ??= new Ea, i ??= Am(e, s, a, n), _d(e, r, s, R))
            e.updateValue(s, d), s++, a++;
        else if (i.has(R))
            r.set(y, e.detach(s)), a--;
        else {
            let se = e.create(s, t[s]);
            e.attach(s, se), s++, a++;
        }
    }
    for (; s <= l;)
        bm(e, r, n, s, t[s]), s++;
}
else if (t != null) {
    uo(o);
    let l = t[Symbol.iterator]();
    uo(null);
    let u = l.next();
    for (; !u.done && s <= a;) {
        let d = e.at(s), f = u.value, p = Cu(s, d, s, f, n);
        if (p !== 0)
            p < 0 && e.updateValue(s, f), s++, u = l.next();
        else {
            r ??= new Ea, i ??= Am(e, s, a, n);
            let h = n(s, f);
            if (_d(e, r, s, h))
                e.updateValue(s, f), s++, a++, u = l.next();
            else if (!i.has(h))
                e.attach(s, e.create(s, f)), s++, a++, u = l.next();
            else {
                let v = n(s, d);
                r.set(v, e.detach(s)), a--;
            }
        }
    }
    for (; !u.done;)
        bm(e, r, n, e.length, u.value), u = l.next();
} for (; s <= a;)
    e.destroy(e.detach(a--)); r?.forEach(l => { e.destroy(l); }); }
function _d(e, t, n, o) { return t !== void 0 && t.has(o) ? (e.attach(n, t.get(o)), t.delete(o), !0) : !1; }
function bm(e, t, n, o, r) { if (_d(e, t, o, n(o, r)))
    e.updateValue(o, r);
else {
    let i = e.create(o, r);
    e.attach(o, i);
} }
function Am(e, t, n, o) { let r = new Set; for (let i = t; i <= n; i++)
    r.add(o(i, e.at(i))); return r; }
var Ea = class {
    kvMap = new Map;
    _vMap = void 0;
    has(t) { return this.kvMap.has(t); }
    delete(t) { if (!this.has(t))
        return !1; let n = this.kvMap.get(t); return this._vMap !== void 0 && this._vMap.has(n) ? (this.kvMap.set(t, this._vMap.get(n)), this._vMap.delete(n)) : this.kvMap.delete(t), !0; }
    get(t) { return this.kvMap.get(t); }
    set(t, n) { if (this.kvMap.has(t)) {
        let o = this.kvMap.get(t);
        this._vMap === void 0 && (this._vMap = new Map);
        let r = this._vMap;
        for (; r.has(o);)
            o = r.get(o);
        r.set(o, n);
    }
    else
        this.kvMap.set(t, n); }
    forEach(t) { for (let [n, o] of this.kvMap)
        if (t(o, n), this._vMap !== void 0) {
            let r = this._vMap;
            for (; r.has(o);)
                o = r.get(o), t(o, n);
        } }
};
function kD(e, t, n, o, r, i, s, a) { te("NgControlFlow"); let c = g(), l = A(), u = ve(l.consts, i); return Ln(c, l, e, t, n, o, r, u, 256, s, a), Ec; }
function Ec(e, t, n, o, r, i, s, a) { te("NgControlFlow"); let c = g(), l = A(), u = ve(l.consts, i); return Ln(c, l, e, t, n, o, r, u, 512, s, a), Ec; }
function OD(e, t) { te("NgControlFlow"); let n = g(), o = De(), r = n[o] !== $ ? n[o] : -1, i = r !== -1 ? Ia(n, I + r) : void 0, s = 0; if (Z(n, o, e)) {
    let a = x(null);
    try {
        if (i !== void 0 && Vf(i, s), e !== -1) {
            let c = I + e, l = Ia(n, c), u = Rd(n[m], c), d = jE(l, u, n), f = Bo(n, u, t, { dehydratedView: d });
            $o(l, f, s, An(u, d));
        }
    }
    finally {
        x(a);
    }
}
else if (i !== void 0) {
    let a = hE(i, s);
    a !== void 0 && (a[j] = t);
} }
var Sd = class {
    lContainer;
    $implicit;
    $index;
    constructor(t, n, o) { this.lContainer = t, this.$implicit = n, this.$index = o; }
    get $count() { return this.lContainer.length - U; }
};
function LD(e) { return e; }
function PD(e, t) { return t; }
var bd = class {
    hasEmptyBlock;
    trackByFn;
    liveCollection;
    constructor(t, n, o) { this.hasEmptyBlock = t, this.trackByFn = n, this.liveCollection = o; }
};
function FD(e, t, n, o, r, i, s, a, c, l, u, d, f) { te("NgControlFlow"); let p = g(), h = A(), v = c !== void 0, y = g(), T = a ? s.bind(y[re][j]) : s, R = new bd(v, T); y[I + e] = R, Ln(p, h, e + 1, t, n, o, r, ve(h.consts, i), 256), v && Ln(p, h, e + 2, c, l, u, d, ve(h.consts, f), 512); }
var Ad = class extends Nd {
    lContainer;
    hostLView;
    templateTNode;
    operationsCounter = void 0;
    needsIndexUpdate = !1;
    constructor(t, n, o) { super(), this.lContainer = t, this.hostLView = n, this.templateTNode = o; }
    get length() { return this.lContainer.length - U; }
    at(t) { return this.getLView(t)[j].$implicit; }
    attach(t, n) { let o = n[fe]; this.needsIndexUpdate ||= t !== this.length, $o(this.lContainer, n, t, An(this.templateTNode, o)), Ik(this.lContainer, t); }
    detach(t) { return this.needsIndexUpdate ||= t !== this.length - 1, Dk(this.lContainer, t), Tk(this.lContainer, t); }
    create(t, n) { let o = ti(this.lContainer, this.templateTNode.tView.ssrId); return Bo(this.hostLView, this.templateTNode, new Sd(this.lContainer, n, t), { dehydratedView: o }); }
    destroy(t) { Si(t[m], t); }
    updateValue(t, n) { this.getLView(t)[j].$implicit = n; }
    reset() { this.needsIndexUpdate = !1; }
    updateIndexes() { if (this.needsIndexUpdate)
        for (let t = 0; t < this.length; t++)
            this.getLView(t)[j].$index = t; }
    getLView(t) { return Ck(this.lContainer, t); }
};
function jD(e) { let t = x(null), n = le(); try {
    let o = g(), r = o[m], i = o[n], s = n + 1, a = Ia(o, s);
    if (i.liveCollection === void 0) {
        let l = Rd(r, s);
        i.liveCollection = new Ad(a, o, l);
    }
    else
        i.liveCollection.reset();
    let c = i.liveCollection;
    if (Ek(c, e, i.trackByFn, t), c.updateIndexes(), i.hasEmptyBlock) {
        let l = De(), u = c.length === 0;
        if (Z(o, l, u)) {
            let d = n + 2, f = Ia(o, d);
            if (u) {
                let p = Rd(r, d), h = jE(f, p, o), v = Bo(o, p, void 0, { dehydratedView: h });
                $o(f, v, 0, An(p, h));
            }
            else
                r.firstUpdatePass && uc(f), Vf(f, 0);
        }
    }
}
finally {
    x(t);
} }
function Ia(e, t) { return e[t]; }
function Ik(e, t) { if (e.length <= U)
    return; let n = U + t, o = e[n], r = o ? o[Qe] : void 0; if (o && r && r.detachedLeaveAnimationFns && r.detachedLeaveAnimationFns.length > 0) {
    let i = o[k];
    Eb(i, r), rn.delete(o[Fe]), r.detachedLeaveAnimationFns = void 0;
} }
function Dk(e, t) { if (e.length <= U)
    return; let n = U + t, o = e[n], r = o ? o[Qe] : void 0; r && r.leave && r.leave.size > 0 && (r.detachedLeaveAnimationFns = []); }
function Tk(e, t) { return Jr(e, t); }
function Ck(e, t) { return hE(e, t); }
function Rd(e, t) { return Kt(e, t); }
function Tp(e, t, n) { let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve();
    Lf(s, o, e, t, o[N], n);
} return Tp; }
function xd(e, t, n, o, r) { nc(t, e, n, r ? "class" : "style", o); }
function ai(e, t, n, o) { let r = g(), i = r[m], s = e + I, a = i.firstCreatePass ? zf(s, r, 2, t, Ff, vs(), n, o) : i.data[s]; if (Ce(a)) {
    let c = r[ze].tracingService;
    if (c && c.componentCreate) {
        let l = i.data[a.directiveStart + a.componentOffset];
        return c.componentCreate(Gf(l), () => (Rm(e, t, r, a, o), ai));
    }
} return Rm(e, t, r, a, o), ai; }
function Rm(e, t, n, o, r) { if (ec(o, n, e, t, wp), Xn(o)) {
    let i = n[m];
    Ja(i, n, o), lf(i, o, n);
} r != null && Ho(n, o); }
function Ic() { let e = A(), t = _(), n = tc(t); return e.firstCreatePass && Qf(e, n), Pl(n) && Vl(), Ll(), n.classesWithoutHost != null && SN(n) && xd(e, n, g(), n.classesWithoutHost, !0), n.stylesWithoutHost != null && bN(n) && xd(e, n, g(), n.stylesWithoutHost, !1), Ic; }
function Cp(e, t, n, o) { return ai(e, t, n, o), Ic(), Cp; }
function Dc(e, t, n, o) { let r = g(), i = r[m], s = e + I, a = i.firstCreatePass ? tI(s, i, 2, t, n, o) : i.data[s]; return ec(a, r, e, t, wp), o != null && Ho(r, a), Dc; }
function Tc() { let e = _(), t = tc(e); return Pl(t) && Vl(), Ll(), Tc; }
function Mp(e, t, n, o) { return Dc(e, t, n, o), Tc(), Mp; }
var wp = (e, t, n, o, r) => (it(!0), Ha(t[N], o, Cs()));
function Mk(e, t, n, o, r) { let i = !ja(t, n); if (it(i), i)
    return Ha(t[N], o, Cs()); let s = t[fe], a = Ai(s, e, t, n); return ty(s, r) && Pa(s, r, a.nextSibling), s && (qd(n) || wv(a)) && Ce(n) && (fg(n), Iy(a)), a; }
function VD() { wp = Mk; }
function Cc(e, t, n) { let o = g(), r = o[m], i = e + I, s = r.firstCreatePass ? zf(i, o, 8, "ng-container", Ff, vs(), t, n) : r.data[i]; if (ec(s, o, e, "ng-container", bp), Xn(s)) {
    let a = o[m];
    Ja(a, o, s), lf(a, s, o);
} return n != null && Ho(o, s), Cc; }
function Li() { let e = A(), t = _(), n = tc(t); return e.firstCreatePass && Qf(e, n), Li; }
function Np(e, t, n) { return Cc(e, t, n), Li(), Np; }
function Mc(e, t, n) { let o = g(), r = o[m], i = e + I, s = r.firstCreatePass ? tI(i, r, 8, "ng-container", t, n) : r.data[i]; return ec(s, o, e, "ng-container", bp), n != null && Ho(o, s), Mc; }
function _p() { let e = _(), t = tc(e); return Li; }
function Sp(e, t, n) { return Mc(e, t, n), _p(), Sp; }
var bp = (e, t, n, o, r) => (it(!0), ff(t[N], ""));
function wk(e, t, n, o, r) { let i, s = !ja(t, n); if (it(s), s)
    return ff(t[N], ""); let a = t[fe], c = Ai(a, e, t, n), l = ey(a, r); return Pa(a, r, c), i = cc(l, c), i; }
function HD() { bp = wk; }
function BD() { return g(); }
function Ap(e, t, n) { let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve();
    Pf(s, o, e, t, o[N], n);
} return Ap; }
function Rp(e, t, n) { let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve(), a = Es(i.data), c = nE(a, s, o);
    Pf(s, o, e, t, c, n);
} return Rp; }
var Ar = void 0;
function Nk(e) { let t = Math.floor(Math.abs(e)), n = e.toString().replace(/^[^.]*\.?/, "").length; return t === 1 && n === 0 ? 1 : 5; }
var _k = ["en", [["a", "p"], ["AM", "PM"]], [["AM", "PM"]], [["S", "M", "T", "W", "T", "F", "S"], ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]], Ar, [["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"], ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]], Ar, [["B", "A"], ["BC", "AD"], ["Before Christ", "Anno Domini"]], 0, [6, 0], ["M/d/yy", "MMM d, y", "MMMM d, y", "EEEE, MMMM d, y"], ["h:mm\u202Fa", "h:mm:ss\u202Fa", "h:mm:ss\u202Fa z", "h:mm:ss\u202Fa zzzz"], ["{1}, {0}", Ar, Ar, Ar], [".", ",", ";", "%", "+", "-", "E", "\xD7", "\u2030", "\u221E", "NaN", ":"], ["#,##0.###", "#,##0%", "\xA4#,##0.00", "#E0"], "USD", "$", "US Dollar", {}, "ltr", Nk], Do = Object.create(null);
function Sk(e, t, n) { typeof t != "string" && (n = t, t = e[ci.LocaleId]), t = t.toLowerCase().replace(/_/g, "-"), Do[t] = e, n && (Do[t][ci.ExtraData] = n); }
function xp(e) { let t = Rk(e), n = xm(t); if (n)
    return n; let o = t.split("-")[0]; if (n = xm(o), n)
    return n; if (o === "en")
    return _k; throw new D(701, !1); }
function bk(e) { return xp(e)[ci.CurrencyCode] || null; }
function $D(e) { return xp(e)[ci.PluralCase]; }
function xm(e) { if (!(e in Do)) {
    let t = Le.ng && Le.ng.common && Le.ng.common.locales && Le.ng.common.locales[e];
    return t !== void 0 && (Do[e] = t), t;
} return Do[e]; }
function Ak() { Do = Object.create(null); }
var ci = { LocaleId: 0, DayPeriodsFormat: 1, DayPeriodsStandalone: 2, DaysFormat: 3, DaysStandalone: 4, MonthsFormat: 5, MonthsStandalone: 6, Eras: 7, FirstDayOfWeek: 8, WeekendRange: 9, DateFormat: 10, TimeFormat: 11, DateTimeFormat: 12, NumberSymbols: 13, NumberFormats: 14, CurrencyCode: 15, CurrencySymbol: 16, CurrencyName: 17, Currencies: 18, Directionality: 19, PluralCase: 20, ExtraData: 21 };
function Rk(e) { return e.toLowerCase().replace(/_/g, "-"); }
var xk = ["zero", "one", "two", "few", "many"];
function kk(e, t) { let n = $D(t)(parseInt(e, 10)), o = xk[n]; return o !== void 0 ? o : "other"; }
var Pi = "en-US", Ok = "USD", UD = { marker: "element" }, qD = { marker: "ICU" }, bt = (function (e) { return e[e.SHIFT = 2] = "SHIFT", e[e.APPEND_EAGERLY = 1] = "APPEND_EAGERLY", e[e.COMMENT = 2] = "COMMENT", e; })(bt || {}), GD = Pi;
function WD(e) { typeof e == "string" && (GD = e.toLowerCase().replace(/_/g, "-")); }
function Lk() { return GD; }
var li = 0, $r = 0;
function Pk(e) { e && (li = li | 1 << Math.min($r, 31)), $r++; }
function Fk(e, t, n) { try {
    if ($r > 0) {
        let o = e.data[n], r = Array.isArray(o) ? o : o.update, i = ft() - $r - 1;
        YD(e, t, r, i, li);
    }
}
finally {
    li = 0, $r = 0;
} }
function zD(e, t, n) { let o = e[N]; switch (n) {
    case Node.COMMENT_NODE: return ff(o, t);
    case Node.TEXT_NODE: return df(o, t);
    case Node.ELEMENT_NODE: return Ha(o, t, null);
} }
var Ur = (e, t, n, o) => (it(!0), zD(e, n, o));
function jk(e, t, n, o) { let r = e[fe], i = t - I, s = !lc() || !r || wr() || Fa(r, i); return it(s), s ? zD(e, n, o) : CE(r, i); }
function QD() { Ur = jk; }
function Vk(e, t, n, o) { let r = e[N]; for (let i = 0; i < t.length; i++) {
    let s = t[i++], a = t[i], c = (s & bt.COMMENT) === bt.COMMENT, l = (s & bt.APPEND_EAGERLY) === bt.APPEND_EAGERLY, u = s >>> bt.SHIFT, d = e[u], f = !1;
    d === null && (d = e[u] = Ur(e, u, a, c ? Node.COMMENT_NODE : Node.TEXT_NODE), f = _r()), l && n !== null && f && _n(r, n, d, o, !1);
} }
function ZD(e, t, n, o) { let r = n[N], i = null, s; for (let a = 0; a < t.length; a++) {
    let c = t[a];
    if (typeof c == "string") {
        let l = t[++a];
        n[l] === null && (n[l] = Ur(n, l, c, Node.TEXT_NODE));
    }
    else if (typeof c == "number")
        switch (c & 1) {
            case 0:
                let l = NA(c);
                i === null && (i = l, s = r.parentNode(o));
                let u, d;
                if (l === i ? (u = o, d = s) : (u = null, d = O(n[l])), d !== null) {
                    let v = _A(c), y = n[v];
                    _n(r, d, y, u, !1);
                    let T = Lr(e, v);
                    if (T !== null && typeof T == "object") {
                        let R = ac(T, n);
                        R !== null && ZD(e, T.create[R], n, n[T.anchorIdx]);
                    }
                }
                break;
            case 1:
                let f = c >>> 1, p = t[++a], h = t[++a];
                Xa(r, yn(f, n), null, null, p, h, null);
                break;
            default:
        }
    else
        switch (c) {
            case qD:
                let l = t[++a], u = t[++a];
                if (n[u] === null) {
                    let p = n[u] = Ur(n, u, l, Node.COMMENT_NODE);
                    Ye(p, n);
                }
                break;
            case UD:
                let d = t[++a], f = t[++a];
                if (n[f] === null) {
                    let p = n[f] = Ur(n, f, d, Node.ELEMENT_NODE);
                    Ye(p, n);
                }
                break;
            default:
        }
} }
function YD(e, t, n, o, r) { for (let i = 0; i < n.length; i++) {
    let s = n[i], a = n[++i];
    if (s & r) {
        let c = "";
        for (let l = i + 1; l <= i + a; l++) {
            let u = n[l];
            if (typeof u == "string")
                c += u;
            else if (typeof u == "number")
                if (u < 0)
                    c += b(t[o - u]);
                else {
                    let d = u >>> 2;
                    switch (u & 3) {
                        case 1:
                            let f = n[++l], p = n[++l], h = e.data[d];
                            if (typeof h == "string")
                                Xa(t[N], t[d], null, h, f, c, p);
                            else {
                                let y = le();
                                ht(d);
                                try {
                                    Lf(h, t, f, c, t[N], p);
                                }
                                finally {
                                    ht(y);
                                }
                            }
                            break;
                        case 0:
                            let v = t[d];
                            v !== null && yy(t[N], v, c);
                            break;
                        case 2:
                            Hk(e, Lr(e, d), t, c);
                            break;
                        case 3:
                            km(e, Lr(e, d), o, t);
                            break;
                    }
                }
        }
    }
    else {
        let c = n[i + 1];
        if (c > 0 && (c & 3) === 3) {
            let l = c >>> 2, u = Lr(e, l);
            t[u.currentCaseLViewIndex] < 0 && km(e, u, o, t);
        }
    }
    i += a;
} }
function km(e, t, n, o) { let r = o[t.currentCaseLViewIndex]; if (r !== null) {
    let i = li;
    r < 0 && (r = o[t.currentCaseLViewIndex] = ~r, i = -1), YD(e, o, t.update[r], n, i);
} }
function Hk(e, t, n, o) { let r = Bk(t, o); if (ac(t, n) !== r && (KD(e, t, n), n[t.currentCaseLViewIndex] = r === null ? null : ~r, r !== null)) {
    let s = n[t.anchorIdx];
    s && ZD(e, t.create[r], n, s), WA(n, t.anchorIdx, r);
} }
function KD(e, t, n) { let o = ac(t, n); if (o !== null) {
    let r = t.remove[o];
    for (let i = 0; i < r.length; i++) {
        let s = r[i];
        if (s > 0) {
            let a = yn(s, n);
            a !== null && wi(n[N], a);
        }
        else
            KD(e, Lr(e, ~s), n);
    }
} }
function Bk(e, t) { let n = e.cases.indexOf(t); if (n === -1)
    switch (e.type) {
        case 1: {
            let o = kk(t, Lk());
            n = e.cases.indexOf(o), n === -1 && o !== "other" && (n = e.cases.indexOf("other"));
            break;
        }
        case 0: {
            n = e.cases.indexOf("other");
            break;
        }
    } return n === -1 ? null : n; }
var Da = /�(\d+):?\d*�/gi, $k = /({\s*�\d+:?\d*�\s*,\s*\S{6}\s*,[\s\S]*})/gi, Uk = /�(\d+)�/, JD = /^\s*(�\d+:?\d*�)\s*,\s*(select|plural)\s*,/, qr = "\uFFFD", qk = /�\/?\*(\d+:\d+)�/gi, Gk = /�(\/?[#*]\d+):?\d*�/gi, Wk = /\uE500/g;
function zk(e) { return e.replace(Wk, " "); }
function Qk(e, t, n, o, r, i) { let s = no(), a = [], c = [], l = [[]], u = [[]]; r = Jk(r, i); let d = zk(r).split(Gk); for (let f = 0; f < d.length; f++) {
    let p = d[f];
    if ((f & 1) === 0) {
        let h = kd(p);
        for (let v = 0; v < h.length; v++) {
            let y = h[v];
            if ((v & 1) === 0) {
                let T = y;
                T !== "" && Zk(u[0], e, s, l[0], a, c, n, T);
            }
            else {
                let T = y;
                if (typeof T != "object")
                    throw new Error(`Unable to parse ICU expression in "${r}" message.`);
                let se = XD(e, s, l[0], n, a, "", !0).index;
                tT(u[0], e, n, c, t, T, se);
            }
        }
    }
    else {
        let h = p.charCodeAt(0) === 47, v = p.charCodeAt(h ? 1 : 0), y = I + Number.parseInt(p.substring(h ? 2 : 1));
        if (h)
            l.shift(), u.shift(), dt(no(), !1);
        else {
            let T = wA(e, l[0], y);
            l.unshift([]), dt(T, !0);
            let R = { kind: 2, index: y, children: [], type: v === 35 ? 0 : 1 };
            u[0].push(R), u.unshift(R.children);
        }
    }
} e.data[o] = { create: a, update: c, ast: u[0], parentTNodeIndex: t }; }
function XD(e, t, n, o, r, i, s) { let a = bi(e, o, 1, null), c = a << bt.SHIFT, l = no(); t === l && (l = null), l === null && (c |= bt.APPEND_EAGERLY), s && (c |= bt.COMMENT, ib(bA)), r.push(c, i === null ? "" : i); let u = Hf(e, a, s ? 32 : 1, i === null ? "" : i, null); EE(n, u); let d = u.index; return dt(u, !1), l !== null && t !== l && MA(l, d), u; }
function Zk(e, t, n, o, r, i, s, a) { let c = a.match(Da), u = XD(t, n, o, s, r, c ? null : a, !1).index; c && Ta(i, a, u, null, 0, null), e.push({ kind: 0, index: u }); }
function Yk(e, t, n) { let o = _(), r = o.index, i = []; if (e.firstCreatePass && e.data[t] === null) {
    for (let s = 0; s < n.length; s += 2) {
        let a = n[s], c = n[s + 1];
        if (c !== "") {
            if ($k.test(c))
                throw new Error(`ICU expressions are not supported in attributes. Message: "${c}".`);
            let l = o.namespace ? `:${o.namespace}:${o.value}` : o.value;
            Ta(i, c, r, a, Kk(i), Od(a, l));
        }
    }
    e.data[t] = i;
} }
function Ta(e, t, n, o, r, i) { let s = e.length, a = s + 1; e.push(null, null); let c = s + 2, l = t.split(Da), u = 0; for (let d = 0; d < l.length; d++) {
    let f = l[d];
    if (d & 1) {
        let p = r + parseInt(f, 10);
        e.push(-1 - p), u = u | eT(p);
    }
    else
        f !== "" && e.push(f);
} return e.push(n << 2 | (o ? 1 : 0)), o && e.push(o, i), e[s] = u, e[a] = e.length - c, u; }
function Kk(e) { let t = 0; for (let n = 0; n < e.length; n++) {
    let o = e[n];
    typeof o == "number" && o < 0 && t++;
} return t; }
function eT(e) { return 1 << Math.min(e, 31); }
function Om(e) { let t, n = "", o = 0, r = !1, i; for (; (t = qk.exec(e)) !== null;)
    r ? t[0] === `${qr}/*${i}${qr}` && (o = t.index, r = !1) : (n += e.substring(o, t.index + t[0].length), i = t[1], r = !0); return n += e.slice(o), n; }
function Jk(e, t) { if (DE(t))
    return Om(e); {
    let n = e.indexOf(`:${t}${qr}`) + 2 + t.toString().length, o = e.search(new RegExp(`${qr}\\/\\*\\d+:${t}${qr}`));
    return Om(e.substring(n, o));
} }
function tT(e, t, n, o, r, i, s) { let a = 0, c = { type: i.type, currentCaseLViewIndex: bi(t, n, 1, null), anchorIdx: s, cases: [], create: [], remove: [], update: [] }; nO(o, i, s), CA(t, s, c); let l = i.values, u = []; for (let d = 0; d < l.length; d++) {
    let f = l[d], p = [];
    for (let v = 0; v < f.length; v++) {
        let y = f[v];
        if (typeof y != "string") {
            let T = p.push(y) - 1;
            f[v] = `<!--\uFFFD${T}\uFFFD-->`;
        }
    }
    let h = [];
    u.push(h), a = eO(h, t, c, n, o, r, i.cases[d], f.join(""), p) | a;
} a && oO(o, a, s), e.push({ kind: 3, index: s, cases: u, currentCaseLViewIndex: c.currentCaseLViewIndex }); }
function Xk(e) { let t = [], n = [], o = 1, r = 0; e = e.replace(JD, function (s, a, c) { return c === "select" ? o = 0 : o = 1, r = parseInt(a.slice(1), 10), ""; }); let i = kd(e); for (let s = 0; s < i.length;) {
    let a = i[s++].trim();
    o === 1 && (a = a.replace(/\s*(?:=)?(\w+)\s*/, "$1")), a.length && t.push(a);
    let c = kd(i[s++]);
    t.length > n.length && n.push(c);
} return { type: o, mainBinding: r, cases: t, values: n }; }
function kd(e) { if (!e)
    return []; let t = 0, n = [], o = [], r = /[{}]/g; r.lastIndex = 0; let i; for (; i = r.exec(e);) {
    let a = i.index;
    if (i[0] == "}") {
        if (n.pop(), n.length == 0) {
            let c = e.substring(t, a);
            JD.test(c) ? o.push(Xk(c)) : o.push(c), t = a + 1;
        }
    }
    else {
        if (n.length == 0) {
            let c = e.substring(t, a);
            o.push(c), t = a + 1;
        }
        n.push("{");
    }
} let s = e.substring(t); return o.push(s), o; }
function eO(e, t, n, o, r, i, s, a, c) { let l = [], u = [], d = []; n.cases.push(s), n.create.push(l), n.remove.push(u), n.update.push(d); let p = dy(mi()).getInertBodyElement(a), h = td(p) || p; return h ? nT(e, t, n, o, r, l, u, d, h, i, c, 0) : 0; }
function nT(e, t, n, o, r, i, s, a, c, l, u, d) { let f = 0, p = c.firstChild; for (; p;) {
    let h = bi(t, o, 1, null);
    switch (p.nodeType) {
        case Node.ELEMENT_NODE:
            let v = p, y = v.tagName.toLowerCase();
            if (Ju.hasOwnProperty(y)) {
                Mu(i, UD, y, l, h), t.data[h] = y;
                let Xe = v.attributes;
                for (let It = 0; It < Xe.length; It++) {
                    let ln = Xe.item(It), qi = ln.name.toLowerCase(), mw = !!ln.value.match(Da), kh = v.namespaceURI, Oh = kh === "http://www.w3.org/2000/svg" ? `:svg:${y}` : kh === "http://www.w3.org/1998/Math/MathML" ? `:math:${y}` : y;
                    if (mw)
                        Xu.hasOwnProperty(qi) && Ta(a, ln.value, h, ln.name, 0, Od(qi, Oh));
                    else if (Xu[qi]) {
                        let vw = ln.value;
                        Od(qi, Oh) ? Pm(i, h, ln.name, "unsafe:blocked") : Pm(i, h, ln.name, vw);
                    }
                }
                let Be = { kind: 1, index: h, children: [] };
                e.push(Be), f = nT(Be.children, t, n, o, r, i, s, a, p, h, u, d + 1) | f, Lm(s, h, d);
            }
            break;
        case Node.TEXT_NODE:
            let T = p.textContent || "", R = T.match(Da);
            Mu(i, null, R ? "" : T, l, h), Lm(s, h, d), R && (f = Ta(a, T, h, null, 0, null) | f), e.push({ kind: 0, index: h });
            break;
        case Node.COMMENT_NODE:
            let se = Uk.exec(p.textContent || "");
            if (se) {
                let Xe = parseInt(se[1], 10), Be = u[Xe];
                Mu(i, qD, "", l, h), tT(e, t, o, r, l, Be, h), tO(s, h, d);
            }
            break;
    }
    p = p.nextSibling;
} return f; }
function Lm(e, t, n) { n === 0 && e.push(t); }
function tO(e, t, n) { n === 0 && (e.push(~t), e.push(t)); }
function nO(e, t, n) { e.push(eT(t.mainBinding), 2, -1 - t.mainBinding, n << 2 | 2); }
function oO(e, t, n) { e.push(t, 1, n << 2 | 3); }
function Mu(e, t, n, o, r) { t !== null && e.push(t), e.push(n, r, SA(0, o, r)); }
function Pm(e, t, n, o) { e.push(t << 1 | 1, n, o); }
function rO(e, t = !0) { if (e[0] != ":")
    return [null, e]; let n = e.indexOf(":", 1); if (n === -1) {
    if (t)
        throw new Error(`Unsupported format "${e}" expecting ":namespace:name"`);
    return [null, e];
} return [e.slice(1, n), e.slice(n + 1)]; }
function Od(e, t) { let n; if (t) {
    let [o, r] = rO(t, !1);
    n = Yg(r, e, o);
}
else
    n = Yg("*", e); switch (n) {
    case X.HTML: return pf;
    case X.STYLE: return hf;
    case X.SCRIPT: return mf;
    case X.URL: return Va;
    case X.RESOURCE_URL: return Ba;
    case X.ATTRIBUTE_NO_BINDING: return vf;
    default: return null;
} }
var Fm = 0, iO = /\[(�.+?�?)\]/, sO = /\[(�.+?�?)\]|(�\/?\*\d+:\d+�)/g, aO = /({\s*)(VAR_(PLURAL|SELECT)(_\d+)?)(\s*,)/g, cO = /{([A-Z0-9_]+)}/g, lO = /�I18N_EXP_(ICU(_\d+)?)�/g, uO = /\/\*/, dO = /\d+\:(\d+)/;
function fO(e, t = {}) { let n = e; if (iO.test(e)) {
    let o = {}, r = [Fm];
    n = n.replace(sO, (i, s, a) => { let c = s || a, l = o[c] || []; if (l.length || (c.split("|").forEach(v => { let y = v.match(dO), T = y ? parseInt(y[1], 10) : Fm, R = uO.test(v); l.push([T, R, v]); }), o[c] = l), !l.length)
        throw new Error(`i18n postprocess: unmatched placeholder - ${c}`); let u = r[r.length - 1], d = 0; for (let v = 0; v < l.length; v++)
        if (l[v][0] === u) {
            d = v;
            break;
        } let [f, p, h] = l[d]; return p ? r.pop() : u !== f && r.push(f), l.splice(d, 1), h; });
} return Object.keys(t).length && (n = n.replace(aO, (o, r, i, s, a, c) => t.hasOwnProperty(i) ? `${r}${t[i]}${c}` : o), n = n.replace(cO, (o, r) => t.hasOwnProperty(r) ? t[r] : o), n = n.replace(lO, (o, r) => { if (t.hasOwnProperty(r)) {
    let i = t[r];
    if (!i.length)
        throw new Error(`i18n postprocess: unmatched ICU - ${o} with key: ${r}`);
    return i.shift();
} return o; })), n; }
function kp(e, t, n = -1) { let o = A(), r = g(), i = I + e, s = ve(o.consts, t), a = no(); if (o.firstCreatePass && Qk(o, a === null ? 0 : a.index, r, i, s, n), o.type === 2) {
    let f = r[re];
    f[w] |= 32;
}
else
    r[w] |= 32; let c = o.data[i], l = a === r[ce] ? null : a, u = $y(o, l, r), d = a && a.type & 8 ? r[a.index] : null; HA(r, i, a, n), Vk(r, c.create, u, d), Ql(!0); }
function Op() { Ql(!1); }
function oT(e, t, n) { kp(e, t, n), Op(); }
function rT(e, t) { let n = A(), o = ve(n.consts, t); Yk(n, e + I, o); }
function Lp(e) { let t = g(); return Pk(Z(t, De(), e)), Lp; }
function iT(e) { Fk(A(), g(), e + I); }
function sT(e, t = {}) { return fO(e, t); }
function Pp(e, t, n) { let o = g(), r = A(), i = _(); return Vp(r, o, o[N], i, e, t, n), Pp; }
function Fp(e, t) { let n = _(), o = g(), r = A(), i = Es(r.data), s = nE(i, n, o); return Vp(r, o, s, n, e, t), Fp; }
function jp(e, t, n) { let o = g(), r = A(), i = _(); return (i.type & 3 || n) && Wf(i, r, o, n, o[N], e, t, on(i, o, t)), jp; }
function Vp(e, t, n, o, r, i, s) { let a = !0, c = null; if ((o.type & 3 || s) && (c ??= on(o, t, i), Wf(o, e, t, s, n, r, i, c) && (a = !1)), a) {
    let l = o.outputs?.[r], u = o.hostDirectiveOutputs?.[r];
    if (u && u.length)
        for (let d = 0; d < u.length; d += 2) {
            let f = u[d], p = u[d + 1];
            c ??= on(o, t, i), fa(o, t, f, p, r, c);
        }
    if (l && l.length)
        for (let d of l)
            c ??= on(o, t, i), fa(o, t, d, r, r, c);
} }
function aT(e = 1) { return Eg(e); }
function pO(e, t) { let n = null, o = JS(e); for (let r = 0; r < t.length; r++) {
    let i = t[r];
    if (i === "*") {
        n = r;
        continue;
    }
    if (o === null ? by(e, i, !0) : tb(o, i))
        return r;
} return n; }
function cT(e) { let t = g()[re][ce]; if (!t.projection) {
    let n = e ? e.length : 1, o = t.projection = mr(n, null), r = o.slice(), i = t.child;
    for (; i !== null;) {
        if (i.type !== 128) {
            let s = e ? pO(i, e) : 0;
            s !== null && (r[s] ? r[s].projectionNext = i : o[s] = i, r[s] = i);
        }
        i = i.next;
    }
} }
function lT(e, t = 0, n, o, r, i) { let s = g(), a = A(), c = o ? e + 1 : null; c !== null && Ln(s, a, c, o, r, i, null, n); let l = $n(a, I + e, 16, null, n || null); l.projection === null && (l.projection = t), ql(); let d = !s[fe] || wr(); s[re][ce].projection[l.projection] === null && c !== null ? hO(s, a, c) : d && !Fo(l) && bb(a, s, l); }
function hO(e, t, n) { let o = I + n, r = t.data[o], i = e[o], s = ti(i, r.tView.ssrId), a = Bo(e, r, void 0, { dehydratedView: s }); $o(i, a, 0, An(r, s)); }
function Hp(e, t, n, o) { return fI(e, t, n, o), Hp; }
function Bp(e, t, n) { return dI(e, t, n), Bp; }
function uT(e) { let t = g(), n = A(), o = Is(); Nr(o + 1); let r = Kf(n, o); if (e.dirty && ag(t) === ((r.metadata.flags & 2) === 2)) {
    if (r.matches === null)
        e.reset([]);
    else {
        let i = hI(t, o);
        e.reset(i, Mv), e.notifyOnChanges();
    }
    return !0;
} return !1; }
function dT() { return Yf(g(), Is()); }
function $p(e, t, n, o, r) { return gI(t, fI(e, n, o, r)), $p; }
function Up(e, t, n, o) { return gI(e, dI(t, n, o)), Up; }
function fT(e = 1) { Nr(Is() + e); }
function pT(e) { let t = Gl(); return Jt(t, I + e); }
function js(e, t) { return e << 17 | t << 2; }
function Pn(e) { return e >> 17 & 32767; }
function gO(e) { return (e & 2) == 2; }
function mO(e, t) { return e & 131071 | t << 17; }
function Ld(e) { return e | 2; }
function So(e) { return (e & 131068) >> 2; }
function wu(e, t) { return e & -131069 | t << 2; }
function vO(e) { return (e & 1) === 1; }
function Pd(e) { return e | 1; }
function yO(e, t, n, o, r, i) { let s = i ? t.classBindings : t.styleBindings, a = Pn(s), c = So(s); e[o] = n; let l = !1, u; if (Array.isArray(n)) {
    let d = n;
    u = d[1], (u === null || Kn(d, u) > 0) && (l = !0);
}
else
    u = n; if (r)
    if (c !== 0) {
        let f = Pn(e[a + 1]);
        e[o + 1] = js(f, a), f !== 0 && (e[f + 1] = wu(e[f + 1], o)), e[a + 1] = mO(e[a + 1], o);
    }
    else
        e[o + 1] = js(a, 0), a !== 0 && (e[a + 1] = wu(e[a + 1], o)), a = o;
else
    e[o + 1] = js(c, 0), a === 0 ? a = o : e[c + 1] = wu(e[c + 1], o), c = o; l && (e[o + 1] = Ld(e[o + 1])), jm(e, u, o, !0), jm(e, u, o, !1), EO(t, u, e, o, i), s = js(a, c), i ? t.classBindings = s : t.styleBindings = s; }
function EO(e, t, n, o, r) { let i = r ? e.residualClasses : e.residualStyles; i != null && typeof t == "string" && Kn(i, t) >= 0 && (n[o + 1] = Pd(n[o + 1])); }
function jm(e, t, n, o) { let r = e[n + 1], i = t === null, s = o ? Pn(r) : So(r), a = !1; for (; s !== 0 && (a === !1 || i);) {
    let c = e[s], l = e[s + 1];
    IO(c, t) && (a = !0, e[s + 1] = o ? Pd(l) : Ld(l)), s = o ? Pn(l) : So(l);
} a && (e[n + 1] = o ? Ld(r) : Pd(r)); }
function IO(e, t) { return e === null || t == null || (Array.isArray(e) ? e[1] : e) === t ? !0 : Array.isArray(e) && typeof t == "string" ? Kn(e, t) >= 0 : !1; }
var de = { textEnd: 0, key: 0, keyEnd: 0, value: 0, valueEnd: 0 };
function hT(e) { return e.substring(de.key, de.keyEnd); }
function DO(e) { return e.substring(de.value, de.valueEnd); }
function TO(e) { return vT(e), gT(e, bo(e, 0, de.textEnd)); }
function gT(e, t) { let n = de.textEnd; return n === t ? -1 : (t = de.keyEnd = MO(e, de.key = t, n), bo(e, t, n)); }
function CO(e) { return vT(e), mT(e, bo(e, 0, de.textEnd)); }
function mT(e, t) { let n = de.textEnd, o = de.key = bo(e, t, n); return n === o ? -1 : (o = de.keyEnd = wO(e, o, n), o = Vm(e, o, n, 58), o = de.value = bo(e, o, n), o = de.valueEnd = NO(e, o, n), Vm(e, o, n, 59)); }
function vT(e) { de.key = 0, de.keyEnd = 0, de.value = 0, de.valueEnd = 0, de.textEnd = e.length; }
function bo(e, t, n) { for (; t < n && e.charCodeAt(t) <= 32;)
    t++; return t; }
function MO(e, t, n) { for (; t < n && e.charCodeAt(t) > 32;)
    t++; return t; }
function wO(e, t, n) { let o; for (; t < n && ((o = e.charCodeAt(t)) === 45 || o === 95 || (o & -33) >= 65 && (o & -33) <= 90 || o >= 48 && o <= 57);)
    t++; return t; }
function Vm(e, t, n, o) { return t = bo(e, t, n), t < n && t++, t; }
function NO(e, t, n) { let o = -1, r = -1, i = -1, s = t, a = s; for (; s < n;) {
    let c = e.charCodeAt(s++);
    if (c === 59)
        return a;
    c === 34 || c === 39 ? a = s = Hm(e, c, s, n) : t === s - 4 && i === 85 && r === 82 && o === 76 && c === 40 ? a = s = Hm(e, 41, s, n) : c > 32 && (a = s), i = r, r = o, o = c & -33;
} return a; }
function Hm(e, t, n, o) { let r = -1, i = n; for (; i < o;) {
    let s = e.charCodeAt(i++);
    if (s == t && r !== 92)
        return i;
    s == 92 && r === 92 ? r = 0 : r = s;
} throw new Error; }
function qp(e, t, n) { return IT(e, t, n, !1), qp; }
function Gp(e, t) { return IT(e, t, null, !0), Gp; }
function yT(e) { DT(MT, _O, e, !1); }
function _O(e, t) { for (let n = CO(t); n >= 0; n = mT(t, n))
    MT(e, hT(t), DO(t)); }
function ET(e) { DT(OO, SO, e, !0); }
function SO(e, t) { for (let n = TO(t); n >= 0; n = gT(t, n))
    vr(e, hT(t), !0); }
function IT(e, t, n, o) { let r = g(), i = A(), s = pt(2); if (i.firstUpdatePass && CT(i, e, s, o), t !== $ && Z(r, s, t)) {
    let a = i.data[le()];
    wT(i, a, r, r[N], e, r[s + 1] = PO(t, n), o, s);
} }
function DT(e, t, n, o) { let r = A(), i = pt(2); r.firstUpdatePass && CT(r, null, i, o); let s = g(); if (n !== $ && Z(s, i, n)) {
    let a = r.data[le()];
    if (NT(a, o) && !TT(r, i)) {
        let c = o ? a.classesWithoutHost : a.stylesWithoutHost;
        c !== null && (n = os(c, n || "")), xd(r, a, s, n, o);
    }
    else
        LO(r, a, s, s[N], s[i + 1], s[i + 1] = kO(e, t, n), o, i);
} }
function TT(e, t) { return t >= e.expandoStartIndex; }
function CT(e, t, n, o) { let r = e.data; if (r[n + 1] === null) {
    let i = r[le()], s = TT(e, n);
    NT(i, o) && t === null && !s && (t = !1), t = bO(r, i, t, o), yO(r, i, t, n, s, o);
} }
function bO(e, t, n, o) { let r = Es(e), i = o ? t.residualClasses : t.residualStyles; if (r === null)
    (o ? t.classBindings : t.styleBindings) === 0 && (n = Nu(null, e, t, n, o), n = ui(n, t.attrs, o), i = null);
else {
    let s = t.directiveStylingLast;
    if (s === -1 || e[s] !== r)
        if (n = Nu(r, e, t, n, o), i === null) {
            let c = AO(e, t, o);
            c !== void 0 && Array.isArray(c) && (c = Nu(null, e, t, c[1], o), c = ui(c, t.attrs, o), RO(e, t, o, c));
        }
        else
            i = xO(e, t, o);
} return i !== void 0 && (o ? t.residualClasses = i : t.residualStyles = i), n; }
function AO(e, t, n) { let o = n ? t.classBindings : t.styleBindings; if (So(o) !== 0)
    return e[Pn(o)]; }
function RO(e, t, n, o) { let r = n ? t.classBindings : t.styleBindings; e[Pn(r)] = o; }
function xO(e, t, n) { let o, r = t.directiveEnd; for (let i = 1 + t.directiveStylingLast; i < r; i++) {
    let s = e[i].hostAttrs;
    o = ui(o, s, n);
} return ui(o, t.attrs, n); }
function Nu(e, t, n, o, r) { let i = null, s = n.directiveEnd, a = n.directiveStylingLast; for (a === -1 ? a = n.directiveStart : a++; a < s && (i = t[a], o = ui(o, i.hostAttrs, r), i !== e);)
    a++; return e !== null && (n.directiveStylingLast = a), o; }
function ui(e, t, n) { let o = n ? 1 : 2, r = -1; if (t !== null)
    for (let i = 0; i < t.length; i++) {
        let s = t[i];
        typeof s == "number" ? r = s : r === o && (Array.isArray(e) || (e = e === void 0 ? [] : ["", e]), vr(e, s, n ? !0 : t[++i]));
    } return e === void 0 ? null : e; }
function kO(e, t, n) { if (n == null || n === "")
    return F; let o = [], r = Ft(n); if (Array.isArray(r))
    for (let i = 0; i < r.length; i++)
        e(o, r[i], !0);
else if (r instanceof Set)
    for (let i of r)
        e(o, i, !0);
else if (typeof r == "object")
    for (let i in r)
        Object.hasOwn(r, i) && e(o, i, r[i]);
else
    typeof r == "string" && t(o, r); return o; }
function MT(e, t, n) { vr(e, t, Ft(n)); }
function OO(e, t, n) { let o = String(t); o !== "" && !o.includes(" ") && vr(e, o, n); }
function LO(e, t, n, o, r, i, s, a) { r === $ && (r = F); let c = 0, l = 0, u = 0 < r.length ? r[0] : null, d = 0 < i.length ? i[0] : null; for (; u !== null || d !== null;) {
    let f = c < r.length ? r[c + 1] : void 0, p = l < i.length ? i[l + 1] : void 0, h = null, v;
    u === d ? (c += 2, l += 2, f !== p && (h = d, v = p)) : d === null || u !== null && u < d ? (c += 2, h = u) : (l += 2, h = d, v = p), h !== null && wT(e, t, n, o, h, v, s, a), u = c < r.length ? r[c] : null, d = l < i.length ? i[l] : null;
} }
function wT(e, t, n, o, r, i, s, a) { if (!(t.type & 3))
    return; let c = e.data, l = c[a + 1], u = vO(l) ? Bm(c, t, n, r, So(l), s) : void 0; if (!Ca(u)) {
    Ca(i) || gO(l) && (i = Bm(c, null, n, r, a, s));
    let d = yn(le(), n);
    Rb(o, s, d, r, i);
} }
function Bm(e, t, n, o, r, i) { let s = t === null, a; for (; r > 0;) {
    let c = e[r], l = Array.isArray(c), u = l ? c[1] : c, d = u === null, f = n[r + 1];
    f === $ && (f = d ? F : void 0);
    let p = d ? ls(f, o) : u === o ? f : void 0;
    if (l && !Ca(p) && (p = ls(c, o)), Ca(p) && (a = p, s))
        return a;
    let h = e[r + 1];
    r = s ? Pn(h) : So(h);
} if (t !== null) {
    let c = i ? t.residualClasses : t.residualStyles;
    c != null && (a = ls(c, o));
} return a; }
function Ca(e) { return e !== void 0; }
function PO(e, t) { return e == null || e === "" || (typeof t == "string" ? e = e + t : typeof e == "object" && (e = sr(Ft(e)))), e; }
function NT(e, t) { return (e.flags & (t ? 8 : 16)) !== 0; }
function _T(e, t = "") { let n = g(), o = A(), r = e + I, i = o.firstCreatePass ? $n(o, r, 1, t, null) : o.data[r], s = ST(o, n, i, t); n[r] = s, _r() && Af(o, n, s, i), dt(i, !1); }
var ST = (e, t, n, o) => (it(!0), df(t[N], o));
function FO(e, t, n, o) { let r = !ja(t, n); if (it(r), r)
    return df(t[N], o); let i = t[fe]; return Ai(i, e, t, n); }
function bT() { ST = FO; }
function AT(e, t) { let n = !1, o = ft(); for (let i = 1; i < t.length; i += 2)
    n = Z(e, o++, t[i]) || n; if (zl(o), !n)
    return $; let r = t[0]; for (let i = 1; i < t.length; i += 2)
    r += b(t[i]) + (i + 1 !== t.length ? t[i + 1] : ""); return r; }
function RT(e, t, n, o = "") { return Z(e, De(), n) ? t + b(n) + o : $; }
function xT(e, t, n, o, r, i = "") { let s = ft(), a = Rn(e, s, n, r); return pt(2), a ? t + b(n) + o + b(r) + i : $; }
function kT(e, t, n, o, r, i, s, a = "") { let c = ft(), l = pc(e, c, n, r, s); return pt(3), l ? t + b(n) + o + b(r) + i + b(s) + a : $; }
function OT(e, t, n, o, r, i, s, a, c, l = "") { let u = ft(), d = Je(e, u, n, r, s, c); return pt(4), d ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l : $; }
function LT(e, t, n, o, r, i, s, a, c, l, u, d = "") { let f = ft(), p = Je(e, f, n, r, s, c); return p = Z(e, f + 4, u) || p, pt(5), p ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d : $; }
function PT(e, t, n, o, r, i, s, a, c, l, u, d, f, p = "") { let h = ft(), v = Je(e, h, n, r, s, c); return v = Rn(e, h + 4, u, f) || v, pt(6), v ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d + b(f) + p : $; }
function FT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v = "") { let y = ft(), T = Je(e, y, n, r, s, c); return T = pc(e, y + 4, u, f, h) || T, pt(7), T ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d + b(f) + p + b(h) + v : $; }
function jT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y, T = "") { let R = ft(), se = Je(e, R, n, r, s, c); return se = Je(e, R + 4, u, f, h, y) || se, pt(8), se ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d + b(f) + p + b(h) + v + b(y) + T : $; }
function Wp(e) { return wc("", e), Wp; }
function wc(e, t, n) { let o = g(), r = RT(o, e, t, n); return r !== $ && Bt(o, le(), r), wc; }
function zp(e, t, n, o, r) { let i = g(), s = xT(i, e, t, n, o, r); return s !== $ && Bt(i, le(), s), zp; }
function Qp(e, t, n, o, r, i, s) { let a = g(), c = kT(a, e, t, n, o, r, i, s); return c !== $ && Bt(a, le(), c), Qp; }
function Zp(e, t, n, o, r, i, s, a, c) { let l = g(), u = OT(l, e, t, n, o, r, i, s, a, c); return u !== $ && Bt(l, le(), u), Zp; }
function Yp(e, t, n, o, r, i, s, a, c, l, u) { let d = g(), f = LT(d, e, t, n, o, r, i, s, a, c, l, u); return f !== $ && Bt(d, le(), f), Yp; }
function Kp(e, t, n, o, r, i, s, a, c, l, u, d, f) { let p = g(), h = PT(p, e, t, n, o, r, i, s, a, c, l, u, d, f); return h !== $ && Bt(p, le(), h), Kp; }
function Jp(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h) { let v = g(), y = FT(v, e, t, n, o, r, i, s, a, c, l, u, d, f, p, h); return y !== $ && Bt(v, le(), y), Jp; }
function Xp(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y) { let T = g(), R = jT(T, e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y); return R !== $ && Bt(T, le(), R), Xp; }
function eh(e) { let t = g(), n = AT(t, e); return n !== $ && Bt(t, le(), n), eh; }
function Bt(e, t, n) { let o = yn(t, e); yy(e[N], o, n); }
function th(e, t, n) { _s(t) && (t = t()); let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve();
    Lf(s, o, e, t, o[N], n);
} return th; }
function VT(e, t) { let n = _s(e); return n && e.set(t), n; }
function nh(e, t) { let n = g(), o = A(), r = _(); return Vp(o, n, n[N], r, e, t), nh; }
var HT = {};
function oh(e) { te("NgLet"); let t = A(), n = g(), o = e + I, r = $n(t, o, 128, null, null); return dt(r, !1), Cr(t, n, o, HT), oh; }
function BT(e) { let t = A(), n = g(), o = le(); return Cr(t, n, o, e), e; }
function $T(e) { let t = Gl(), n = Jt(t, I + e); if (n === HT)
    throw new D(314, !1); return n; }
function UT(e, t) { let n = A(), o = g(), r = o[N], i = "data-ng-source-location"; for (let [s, a, c, l] of t) {
    let u = Kt(n, s + I), d = yn(s + I, o);
    if (!d.hasAttribute(i)) {
        let f = `${e}@o:${a},l:${c},c:${l}`;
        r.setAttribute(d, i, f);
    }
} }
function qT(e) { return Z(g(), De(), e) ? b(e) : $; }
function GT(e, t, n = "") { return RT(g(), e, t, n); }
function WT(e, t, n, o, r = "") { return xT(g(), e, t, n, o, r); }
function zT(e, t, n, o, r, i, s = "") { return kT(g(), e, t, n, o, r, i, s); }
function QT(e, t, n, o, r, i, s, a, c = "") { return OT(g(), e, t, n, o, r, i, s, a, c); }
function ZT(e, t, n, o, r, i, s, a, c, l, u = "") { return LT(g(), e, t, n, o, r, i, s, a, c, l, u); }
function YT(e, t, n, o, r, i, s, a, c, l, u, d, f = "") { return PT(g(), e, t, n, o, r, i, s, a, c, l, u, d, f); }
function KT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h = "") { return FT(g(), e, t, n, o, r, i, s, a, c, l, u, d, f, p, h); }
function JT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y = "") { return jT(g(), e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y); }
function XT(e) { return AT(g(), e); }
function eC(e, t, n) { let o = ye() + e, r = g(); return r[o] === $ ? at(r, o, t(n, r)) : qo(r, o); }
function $m(e, t, n) { let o = A(); o.firstCreatePass && tC(t, o.data, o.blueprint, Ze(e), n); }
function tC(e, t, n, o, r) { if (e = P(e), Array.isArray(e))
    for (let i = 0; i < e.length; i++)
        tC(e[i], t, n, o, r);
else {
    let i = A(), s = g(), a = _(), c = fn(e) ? e : P(e.provide), l = Cl(e), u = a.providerIndexes & 1048575, d = a.directiveStart, f = a.providerIndexes >> 20;
    if (fn(e) || !e.multi) {
        let p = new Nn(l, r, Go, null), h = Su(c, t, r ? u : u + f, d);
        h === -1 ? (Lu(Xs(a, s), i, c), _u(i, e, t.length), t.push(c), a.directiveStart++, a.directiveEnd++, r && (a.providerIndexes += 1048576), n.push(p), s.push(p)) : (n[h] = p, s[h] = p);
    }
    else {
        let p = Su(c, t, u + f, d), h = Su(c, t, u, u + f), v = p >= 0 && n[p], y = h >= 0 && n[h];
        if (r && !y || !r && !v) {
            Lu(Xs(a, s), i, c);
            let T = HO(r ? VO : jO, n.length, r, o, l, e);
            !r && y && (n[h].providerFactory = T), _u(i, e, t.length, 0), t.push(c), a.directiveStart++, a.directiveEnd++, r && (a.providerIndexes += 1048576), n.push(T), s.push(T);
        }
        else {
            let T = nC(n[r ? h : p], l, !r && o);
            _u(i, e, p > -1 ? p : h, T);
        }
        !r && o && y && n[h].componentProviders++;
    }
} }
function _u(e, t, n, o) { let r = fn(t), i = ng(t); if (r || i) {
    let c = (i ? P(t.useClass) : t).prototype.ngOnDestroy;
    if (c) {
        let l = e.destroyHooks || (e.destroyHooks = []);
        if (!r && t.multi) {
            let u = l.indexOf(n);
            u === -1 ? l.push(n, [o, c]) : l[u + 1].push(o, c);
        }
        else
            l.push(n, c);
    }
} }
function nC(e, t, n) { return n && e.componentProviders++, e.multi.push(t) - 1; }
function Su(e, t, n, o) { for (let r = n; r < o; r++)
    if (t[r] === e)
        return r; return -1; }
function jO(e, t, n, o, r) { return Fd(this.multi, []); }
function VO(e, t, n, o, r) { let i = this.multi, s; if (this.providerFactory) {
    let a = this.providerFactory.componentProviders, c = Wr(o, o[m], this.providerFactory.index, r);
    s = c.slice(0, a), Fd(i, s);
    for (let l = a; l < c.length; l++)
        s.push(c[l]);
}
else
    s = [], Fd(i, s); return s; }
function Fd(e, t) { for (let n = 0; n < e.length; n++) {
    let o = e[n];
    t.push(o());
} return t; }
function HO(e, t, n, o, r, i) { let s = new Nn(e, n, Go, null); return s.multi = [], s.index = t, s.componentProviders = 0, nC(s, r, o && !n), s; }
function oC(e, t) { return n => { n.providersResolver = (o, r) => $m(o, r ? r(e) : e, !1), t && (n.viewProvidersResolver = (o, r) => $m(o, r ? r(t) : t, !0)); }; }
function rC(e) { return t => { e.length < 1 || (t.getExternalStyles = n => e.map(r => r + "?ngcomp" + (n ? "=" + encodeURIComponent(n) : "") + "&e=" + t.encapsulation)); }; }
function iC(e, t, n) { let o = e.\u0275cmp; o.directiveDefs = va(t, II), o.pipeDefs = va(n, tt); }
function sC(e, t) { return Et(() => { let n = is(e); n.declarations = Vs(t.declarations || F), n.imports = Vs(t.imports || F), n.exports = Vs(t.exports || F), t.bootstrap && (n.bootstrap = Vs(t.bootstrap)), wo.registerNgModule(e, t); }); }
function Vs(e) { if (typeof e == "function")
    return e; let t = nt(e); return t.some(cr) ? () => t.map(P).map(Um) : t.map(Um); }
function Um(e) { return qf(e) ? e.ngModule : e; }
var aC = () => null, cC = () => { }, qm = !1;
function lC() { return aC(); }
function uC(e, t) { cC(e, t); }
function dC() { qm || (qm = !0, J_(), te("NgIncrementalHydration"), aC = () => new j_, cC = (e, t) => { let n = rS(e), o = jA(t, t.body); ck(e, n, o), Y_(t, e); }); }
function fC(e, t) { let n = ye() + e, o = g(); return o[n] === $ ? at(o, n, t()) : qo(o, n); }
function pC(e, t, n) { return TC(g(), ye(), e, t, n); }
function hC(e, t, n, o) { return CC(g(), ye(), e, t, n, o); }
function gC(e, t, n, o, r) { return MC(g(), ye(), e, t, n, o, r); }
function mC(e, t, n, o, r, i, s) { return wC(g(), ye(), e, t, n, o, r, i); }
function vC(e, t, n, o, r, i, s) { let a = ye() + e, c = g(), l = Je(c, a, n, o, r, i); return Z(c, a + 4, s) || l ? at(c, a + 5, t(n, o, r, i, s)) : qo(c, a + 5); }
function yC(e, t, n, o, r, i, s, a) { let c = ye() + e, l = g(), u = Je(l, c, n, o, r, i); return Rn(l, c + 4, s, a) || u ? at(l, c + 6, t(n, o, r, i, s, a)) : qo(l, c + 6); }
function EC(e, t, n, o, r, i, s, a, c) { let l = ye() + e, u = g(), d = Je(u, l, n, o, r, i); return pc(u, l + 4, s, a, c) || d ? at(u, l + 7, t(n, o, r, i, s, a, c)) : qo(u, l + 7); }
function IC(e, t, n, o, r, i, s, a, c, l) { let u = ye() + e, d = g(), f = Je(d, u, n, o, r, i); return Je(d, u + 4, s, a, c, l) || f ? at(d, u + 8, t(n, o, r, i, s, a, c, l)) : qo(d, u + 8); }
function DC(e, t, n) { return NC(g(), ye(), e, t, n); }
function Fi(e, t) { let n = e[t]; return n === $ ? void 0 : n; }
function TC(e, t, n, o, r, i) { let s = t + n; return Z(e, s, r) ? at(e, s + 1, i ? o.call(i, r) : o(r)) : Fi(e, s + 1); }
function CC(e, t, n, o, r, i, s) { let a = t + n; return Rn(e, a, r, i) ? at(e, a + 2, s ? o.call(s, r, i) : o(r, i)) : Fi(e, a + 2); }
function MC(e, t, n, o, r, i, s, a) { let c = t + n; return pc(e, c, r, i, s) ? at(e, c + 3, a ? o.call(a, r, i, s) : o(r, i, s)) : Fi(e, c + 3); }
function wC(e, t, n, o, r, i, s, a, c) { let l = t + n; return Je(e, l, r, i, s, a) ? at(e, l + 4, c ? o.call(c, r, i, s, a) : o(r, i, s, a)) : Fi(e, l + 4); }
function NC(e, t, n, o, r, i) { let s = t + n, a = !1; for (let c = 0; c < r.length; c++)
    Z(e, s++, r[c]) && (a = !0); return a ? at(e, s, o.apply(i, r)) : Fi(e, s); }
function _C(e, t) { let n = A(), o, r = e + I; n.firstCreatePass ? (o = BO(t, n.pipeRegistry), n.data[r] = o, o.onDestroy && (n.destroyHooks ??= []).push(r, o.onDestroy)) : o = n.data[r]; let i = o.factory || (o.factory = Ut(o.type, !0)), s, a = Te(Go); try {
    let c = Js(!1), l = i();
    return Js(c), Cr(n, g(), r, l), l;
}
finally {
    Te(a);
} }
function BO(e, t) { if (t)
    for (let n = t.length - 1; n >= 0; n--) {
        let o = t[n];
        if (e === o.name)
            return o;
    } }
function SC(e, t, n) { let o = e + I, r = g(), i = Jt(r, o); return ji(r, o) ? TC(r, ye(), t, i.transform, n, i) : i.transform(n); }
function bC(e, t, n, o) { let r = e + I, i = g(), s = Jt(i, r); return ji(i, r) ? CC(i, ye(), t, s.transform, n, o, s) : s.transform(n, o); }
function AC(e, t, n, o, r) { let i = e + I, s = g(), a = Jt(s, i); return ji(s, i) ? MC(s, ye(), t, a.transform, n, o, r, a) : a.transform(n, o, r); }
function RC(e, t, n, o, r, i) { let s = e + I, a = g(), c = Jt(a, s); return ji(a, s) ? wC(a, ye(), t, c.transform, n, o, r, i, c) : c.transform(n, o, r, i); }
function xC(e, t, n) { let o = e + I, r = g(), i = Jt(r, o); return ji(r, o) ? NC(r, ye(), t, i.transform, n, i) : i.transform.apply(i, n); }
function ji(e, t) { return e[m].data[t].pure; }
function kC(e, t) { return sc(e, t); }
function OC(e, t) { return () => { try {
    return wo.getComponentDependencies(e, t).dependencies;
}
catch (n) {
    throw console.error(`Computing dependencies in local compilation mode for the component "${e.name}" failed with the exception:`, n), n;
} }; }
function LC(e, t) { let n = W(e); n !== null && (n.debugInfo = t); }
function PC(e, t, n) { let o = `./@ng/component?c=${e}&t=${encodeURIComponent(t)}`; return new URL(o, n).href; }
function FC(e, t, n, o, r = null, i = null) { let s = W(e); t.apply(null, [e, n, ...o]); let { newDef: a, oldDef: c } = $O(s, W(e)); if (e[pn] = a, c.tView) {
    let l = d_().values();
    for (let u of l)
        rt(u) && u[z] === null && zs(r, i, a, c, u);
} }
function $O(e, t) { let n = q({}, e); return { newDef: Object.assign(e, t, { directiveDefs: n.directiveDefs, pipeDefs: n.pipeDefs, setInput: n.setInput, type: n.type }), oldDef: n }; }
function zs(e, t, n, o, r) { let i = r[m]; if (i === o.tView) {
    qO(e, t, n, o, r);
    return;
} for (let s = I; s < i.bindingStartIndex; s++) {
    let a = r[s];
    if (K(a)) {
        J(a[B]) && zs(e, t, n, o, a[B]);
        for (let c = U; c < a.length; c++)
            zs(e, t, n, o, a[c]);
    }
    else
        J(a) && zs(e, t, n, o, a);
} }
function UO(e, t) { e.componentReplaced?.(t.id); }
function qO(e, t, n, o, r) { let i = r[j], s = r[B], a = r[z], c = r[ce], l = r[k].get(G, null), u = () => { if (o.encapsulation === Ke.ShadowDom || o.encapsulation === Ke.ExperimentalIsolatedShadowDom) {
    let h = s.cloneNode(!1);
    s.replaceWith(h), s = h;
} let d = Zy(n), f = Ya(a, d, i, kf(n), s, c, null, null, null, null, null); GO(a, r, f, c.index), Si(r[m], r), ei(r); let p = r[ze].rendererFactory; UO(p, o), f[N] = p.createRenderer(s, n), Hy(r[m], r), WO(c), oc(d, f, i), lE(d, f, d.template, i); }; l === null ? Gm(e, t, u) : l.run(() => Gm(e, t, u)); }
function Gm(e, t, n) {
    try {
        n();
    }
    catch (o) {
        let r = o;
        if (t !== null && r.message) {
            let i = r.message + (r.stack ? `
` + r.stack : "");
            e?.hot?.send?.("angular:invalidate", { id: t, message: i, error: !0 });
        }
        throw o;
    }
}
function GO(e, t, n, o) { for (let r = I; r < e[m].bindingStartIndex; r++) {
    let i = e[r];
    if ((J(i) || K(i)) && i[ge] === t) {
        i[ge] = n;
        break;
    }
} e[Qt] === t && (e[Qt] = n), e[Ir] === t && (e[Ir] = n), n[ge] = t[ge], t[ge] = null, e[o] = n; }
function WO(e) { if (e.projection !== null) {
    for (let t of e.projection)
        Ma(t) && (t.projectionNext = null, t.flags &= -3);
    e.projection = null;
} }
var Ee = { \u0275\u0275animateEnter: Vr, \u0275\u0275animateEnterListener: Hr, \u0275\u0275animateLeave: Br, \u0275\u0275animateLeaveListener: ya, \u0275\u0275attribute: Dp, \u0275\u0275defineComponent: EI, \u0275\u0275defineDirective: DI, \u0275\u0275defineInjectable: Y, \u0275\u0275defineInjector: lr, \u0275\u0275defineNgModule: rp, \u0275\u0275defineService: Lt, \u0275\u0275definePipe: TI, \u0275\u0275directiveInject: Go, \u0275\u0275getInheritedFactory: hv, \u0275\u0275inject: he, \u0275\u0275injectAttribute: wa, \u0275\u0275invalidFactory: JE, \u0275\u0275invalidFactoryDep: cs, \u0275\u0275templateRefExtractor: kC, \u0275\u0275resetView: Bl, \u0275\u0275HostDirectivesFeature: kI, \u0275\u0275NgOnChangesFeature: Xm, \u0275\u0275ControlFeature: xI, \u0275\u0275ProvidersFeature: oC, \u0275\u0275InheritDefinitionFeature: up, \u0275\u0275ExternalStylesFeature: rC, \u0275\u0275nextContext: aT, \u0275\u0275namespaceHTML: Xl, \u0275\u0275namespaceMathML: Jl, \u0275\u0275namespaceSVG: Kl, \u0275\u0275enableBindings: Fl, \u0275\u0275disableBindings: jl, \u0275\u0275elementStart: ai, \u0275\u0275elementEnd: Ic, \u0275\u0275element: Cp, \u0275\u0275elementContainerStart: Cc, \u0275\u0275elementContainerEnd: Li, \u0275\u0275domElement: Mp, \u0275\u0275domElementStart: Dc, \u0275\u0275domElementEnd: Tc, \u0275\u0275domElementContainer: Sp, \u0275\u0275domElementContainerStart: Mc, \u0275\u0275domElementContainerEnd: _p, \u0275\u0275domTemplate: fp, \u0275\u0275domListener: jp, \u0275\u0275elementContainer: Np, \u0275\u0275pureFunction0: fC, \u0275\u0275pureFunction1: pC, \u0275\u0275pureFunction2: hC, \u0275\u0275pureFunction3: gC, \u0275\u0275pureFunction4: mC, \u0275\u0275pureFunction5: vC, \u0275\u0275pureFunction6: yC, \u0275\u0275pureFunction7: EC, \u0275\u0275pureFunction8: IC, \u0275\u0275pureFunctionV: DC, \u0275\u0275getCurrentView: BD, \u0275\u0275restoreView: Hl, \u0275\u0275listener: Pp, \u0275\u0275projection: lT, \u0275\u0275syntheticHostProperty: Rp, \u0275\u0275syntheticHostListener: Fp, \u0275\u0275pipeBind1: SC, \u0275\u0275pipeBind2: bC, \u0275\u0275pipeBind3: AC, \u0275\u0275pipeBind4: RC, \u0275\u0275pipeBindV: xC, \u0275\u0275projectionDef: cT, \u0275\u0275domProperty: Ap, \u0275\u0275ariaProperty: Ip, \u0275\u0275property: Tp, \u0275\u0275control: zE, \u0275\u0275controlCreate: GE, \u0275\u0275pipe: _C, \u0275\u0275queryRefresh: uT, \u0275\u0275queryAdvance: fT, \u0275\u0275viewQuery: Bp, \u0275\u0275viewQuerySignal: Up, \u0275\u0275loadQuery: dT, \u0275\u0275contentQuery: Hp, \u0275\u0275contentQuerySignal: $p, \u0275\u0275reference: pT, \u0275\u0275classMap: ET, \u0275\u0275styleMap: yT, \u0275\u0275styleProp: qp, \u0275\u0275classProp: Gp, \u0275\u0275advance: Yy, \u0275\u0275template: dp, \u0275\u0275conditional: OD, \u0275\u0275conditionalCreate: kD, \u0275\u0275conditionalBranchCreate: Ec, \u0275\u0275defer: lD, \u0275\u0275deferWhen: uD, \u0275\u0275deferOnIdle: hD, \u0275\u0275deferOnImmediate: vD, \u0275\u0275deferOnTimer: ID, \u0275\u0275deferOnHover: CD, \u0275\u0275deferOnInteraction: ND, \u0275\u0275deferOnViewport: bD, \u0275\u0275deferPrefetchWhen: dD, \u0275\u0275deferPrefetchOnIdle: gD, \u0275\u0275deferPrefetchOnImmediate: yD, \u0275\u0275deferPrefetchOnTimer: DD, \u0275\u0275deferPrefetchOnHover: MD, \u0275\u0275deferPrefetchOnInteraction: _D, \u0275\u0275deferPrefetchOnViewport: AD, \u0275\u0275deferHydrateWhen: fD, \u0275\u0275deferHydrateNever: pD, \u0275\u0275deferHydrateOnIdle: mD, \u0275\u0275deferHydrateOnImmediate: ED, \u0275\u0275deferHydrateOnTimer: TD, \u0275\u0275deferHydrateOnHover: wD, \u0275\u0275deferHydrateOnInteraction: SD, \u0275\u0275deferHydrateOnViewport: RD, \u0275\u0275deferEnableTimerScheduling: QI, \u0275\u0275enableIncrementalHydrationRuntime: dC, \u0275\u0275repeater: jD, \u0275\u0275repeaterCreate: FD, \u0275\u0275repeaterTrackByIndex: LD, \u0275\u0275repeaterTrackByIdentity: PD, \u0275\u0275componentInstance: xD, \u0275\u0275text: _T, \u0275\u0275textInterpolate: Wp, \u0275\u0275textInterpolate1: wc, \u0275\u0275textInterpolate2: zp, \u0275\u0275textInterpolate3: Qp, \u0275\u0275textInterpolate4: Zp, \u0275\u0275textInterpolate5: Yp, \u0275\u0275textInterpolate6: Kp, \u0275\u0275textInterpolate7: Jp, \u0275\u0275textInterpolate8: Xp, \u0275\u0275textInterpolateV: eh, \u0275\u0275i18n: oT, \u0275\u0275i18nAttributes: rT, \u0275\u0275i18nExp: Lp, \u0275\u0275i18nStart: kp, \u0275\u0275i18nEnd: Op, \u0275\u0275i18nApply: iT, \u0275\u0275i18nPostprocess: sT, \u0275\u0275resolveWindow: Ny, \u0275\u0275resolveDocument: _y, \u0275\u0275resolveBody: yf, \u0275\u0275setComponentScope: iC, \u0275\u0275setNgModuleScope: sC, \u0275\u0275registerNgModuleType: cp, \u0275\u0275getComponentDepsFactory: OC, \u0275setClassDebugInfo: LC, \u0275\u0275declareLet: oh, \u0275\u0275storeLet: BT, \u0275\u0275arrowFunction: eC, \u0275\u0275readContextLet: $T, \u0275\u0275attachSourceLocations: UT, \u0275\u0275interpolate: qT, \u0275\u0275interpolate1: GT, \u0275\u0275interpolate2: WT, \u0275\u0275interpolate3: zT, \u0275\u0275interpolate4: QT, \u0275\u0275interpolate5: ZT, \u0275\u0275interpolate6: YT, \u0275\u0275interpolate7: KT, \u0275\u0275interpolate8: JT, \u0275\u0275interpolateV: XT, \u0275\u0275sanitizeHtml: pf, \u0275\u0275sanitizeStyle: hf, \u0275\u0275sanitizeResourceUrl: Ba, \u0275\u0275sanitizeScript: mf, \u0275\u0275validateAttribute: vf, \u0275\u0275sanitizeUrl: gf, \u0275\u0275sanitizeUrlOrResourceUrl: wy, \u0275\u0275trustConstantHtml: Cy, \u0275\u0275trustConstantResourceUrl: My, forwardRef: ar, resolveForwardRef: P, \u0275\u0275twoWayProperty: th, \u0275\u0275twoWayBindingSet: VT, \u0275\u0275twoWayListener: nh, \u0275\u0275replaceMetadata: FC, \u0275\u0275getReplaceMetadataURL: PC }, mo = null;
function jC(e) { mo !== null && (e.defaultEncapsulation !== mo.defaultEncapsulation || e.preserveWhitespaces !== mo.preserveWhitespaces) || (mo = e); }
function zO() { return mo; }
function QO() { mo = null; }
var Gr = [];
function ZO(e, t) { Gr.push({ moduleType: e, ngModule: t }); }
var bu = !1;
function VC() { if (!bu) {
    bu = !0;
    try {
        for (let e = Gr.length - 1; e >= 0; e--) {
            let { moduleType: t, ngModule: n } = Gr[e];
            n.declarations && n.declarations.every(HC) && (Gr.splice(e, 1), eL(t, n));
        }
    }
    finally {
        bu = !1;
    }
} }
function HC(e) { return Array.isArray(e) ? e.every(HC) : !!P(e); }
function BC(e, t = {}) { $C(e, t), t.id !== void 0 && cp(e, t.id), ZO(e, t); }
function $C(e, t, n = !1) { let o = nt(t.declarations || F), r = null; Object.defineProperty(e, rs, { configurable: !0, get: () => (r === null && (r = ee({ usage: 0, kind: "NgModule", type: e }).compileNgModule(Ee, `ng:///${e.name}/\u0275mod.js`, { type: e, bootstrap: nt(t.bootstrap || F).map(P), declarations: o.map(P), imports: nt(t.imports || F).map(P).map(Wm), exports: nt(t.exports || F).map(P).map(Wm), schemas: t.schemas ? nt(t.schemas) : null, id: t.id || null }), r.schemas || (r.schemas = [])), r) }); let i = null; Object.defineProperty(e, $e, { get: () => { if (i === null) {
        let a = ee({ usage: 0, kind: "NgModule", type: e });
        i = a.compileFactory(Ee, `ng:///${e.name}/\u0275fac.js`, { name: e.name, type: e, deps: hi(e), target: a.FactoryTarget.NgModule, typeArgumentCount: 0 });
    } return i; }, configurable: !1 }); let s = null; Object.defineProperty(e, Xo, { get: () => { if (s === null) {
        let a = { name: e.name, type: e, providers: t.providers || F, imports: [(t.imports || F).map(P), (t.exports || F).map(P)] };
        s = ee({ usage: 0, kind: "NgModule", type: e }).compileInjector(Ee, `ng:///${e.name}/\u0275inj.js`, a);
    } return s; }, configurable: !1 }); }
function YO(e, t) { let n = `Unexpected "${Ge(e)}" found in the "declarations" array of the`, o = `"${Ge(e)}" is marked as standalone and can't be declared in any NgModule - did you intend to import it instead (by adding it to the "imports" array)?`; return `${n} ${t}, ${o}`; }
var KO = new WeakMap, JO = new WeakMap;
function XO() { KO = new WeakMap, JO = new WeakMap, Gr.length = 0, KR.clear(); }
function eL(e, t) { let n = nt(t.declarations || F), o = ih(e); n.forEach(r => { if (r = P(r), r.hasOwnProperty(pn)) {
    let s = W(r);
    rh(s, o);
}
else
    !r.hasOwnProperty(dr) && !r.hasOwnProperty(fr) && (r.ngSelectorScope = e); }); }
function rh(e, t) { e.directiveDefs = () => Array.from(t.compilation.directives).map(n => n.hasOwnProperty(pn) ? W(n) : Oe(n)).filter(n => !!n), e.pipeDefs = () => Array.from(t.compilation.pipes).map(n => tt(n)), e.schemas = t.schemas, e.tView = null; }
function ih(e) { if (Dn(e)) {
    let t = wo.getNgModuleScope(e), n = is(e);
    return q({ schemas: n.schemas || null }, t);
}
else if (pr(e)) {
    if ((W(e) || Oe(e)) !== null)
        return { schemas: null, compilation: { directives: new Set, pipes: new Set }, exported: { directives: new Set([e]), pipes: new Set } };
    if (tt(e) !== null)
        return { schemas: null, compilation: { directives: new Set, pipes: new Set }, exported: { directives: new Set, pipes: new Set([e]) } };
} throw new Error(`${e.name} does not have a module def (\u0275mod property)`); }
function Wm(e) { return qf(e) ? e.ngModule : e; }
var Au = 0;
function UC(e, t) {
    let n = null;
    ex(e, t), GC(e, t), Object.defineProperty(e, pn, { get: () => {
            if (n === null) {
                let o = ee({ usage: 0, kind: "component", type: e });
                if (bI(t)) {
                    let u = [`Component '${e.name}' is not resolved:`];
                    throw t.templateUrl && u.push(` - templateUrl: ${t.templateUrl}`), t.styleUrls && t.styleUrls.length && u.push(` - styleUrls: ${JSON.stringify(t.styleUrls)}`), t.styleUrl && u.push(` - styleUrl: ${t.styleUrl}`), u.push("Did you run and wait for 'resolveComponentResources()'?"), new Error(u.join(`
`));
                }
                let r = zO(), i = t.preserveWhitespaces;
                i === void 0 && (r !== null && r.preserveWhitespaces !== void 0 ? i = r.preserveWhitespaces : i = !1);
                let s = t.encapsulation;
                s === void 0 && (r !== null && r.defaultEncapsulation !== void 0 ? s = r.defaultEncapsulation : s = Ke.Emulated);
                let a = t.templateUrl || `ng:///${e.name}/template.html`, c = WC(e, t), l = Ie(q({}, c), { typeSourceSpan: o.createParseSourceSpan("Component", e.name, a), template: t.template || "", preserveWhitespaces: i, styles: typeof t.styles == "string" ? [t.styles] : t.styles || F, animations: t.animations, declarations: [], changeDetection: t.changeDetection, encapsulation: s, viewProviders: t.viewProviders || null, hasDirectiveDependencies: !c.isStandalone || t.imports != null && t.imports.length > 0 });
                Au++;
                try {
                    if (l.usesInheritance && zC(e), n = o.compileComponent(Ee, a, l), l.isStandalone) {
                        let u = nt(t.imports || F), { directiveDefs: d, pipeDefs: f } = tL(e, u);
                        n.directiveDefs = d, n.pipeDefs = f, n.dependencies = () => u.map(P);
                    }
                }
                finally {
                    Au--;
                }
                if (Au === 0 && VC(), nL(e)) {
                    let u = ih(e.ngSelectorScope);
                    rh(n, u);
                }
                if (t.schemas)
                    if (l.isStandalone)
                        n.schemas = t.schemas;
                    else
                        throw new Error(`The 'schemas' was specified for the ${Ge(e)} but is only valid on a component that is standalone.`);
                else
                    l.isStandalone && (n.schemas = []);
            }
            return n;
        }, set: o => { n = o; }, configurable: !1 });
}
function tL(e, t) { return { directiveDefs: () => Pr(e) ? [...wo.getStandaloneComponentScope(e, t).compilation.directives].map(i => W(i) || Oe(i)).filter(i => i !== null) : [], pipeDefs: () => Pr(e) ? [...wo.getStandaloneComponentScope(e, t).compilation.pipes].map(i => tt(i)).filter(i => i !== null) : [] }; }
function nL(e) { return e.ngSelectorScope !== void 0; }
function sh(e, t) { let n = null; GC(e, t || {}), Object.defineProperty(e, dr, { get: () => { if (n === null) {
        let o = qC(e, t || {});
        n = ee({ usage: 0, kind: "directive", type: e }).compileDirective(Ee, o.sourceMapUrl, o.metadata);
    } return n; }, configurable: !1 }); }
function qC(e, t) { let n = e && e.name, o = `ng:///${n}/\u0275dir.js`, r = ee({ usage: 0, kind: "directive", type: e }), i = WC(e, t); return i.typeSourceSpan = r.createParseSourceSpan("Directive", n, o), i.usesInheritance && zC(e), { metadata: i, sourceMapUrl: o }; }
function GC(e, t) { let n = null; Object.defineProperty(e, $e, { get: () => { if (n === null) {
        let o = qC(e, t), r = ee({ usage: 0, kind: "directive", type: e });
        n = r.compileFactory(Ee, `ng:///${e.name}/\u0275fac.js`, { name: o.metadata.name, type: o.metadata.type, typeArgumentCount: 0, deps: hi(e), target: r.FactoryTarget.Directive });
    } return n; }, configurable: !1 }); }
function oL(e) { return Object.getPrototypeOf(e.prototype) === Object.prototype; }
function WC(e, t) { let n = Ud(), o = n.ownPropMetadata(e); return { name: e.name, legacyOptionalChaining: !1, type: e, selector: t.selector !== void 0 ? t.selector : null, host: t.host || wt, propMetadata: o, inputs: t.inputs || F, outputs: t.outputs || F, queries: zm(e, o, QC), lifecycle: { usesOnChanges: n.hasLifecycleHook(e, "ngOnChanges") }, controlCreate: n.hasLifecycleHook(e, "\u0275ngControlCreate") ? { passThroughInput: null } : null, typeSourceSpan: null, usesInheritance: !oL(e), exportAs: sL(t.exportAs), providers: t.providers || null, viewQueries: zm(e, o, ZC), isStandalone: t.standalone === void 0 ? !0 : !!t.standalone, isSignal: !!t.signals, hostDirectives: t.hostDirectives?.map(r => typeof r == "function" ? { directive: r } : r) || null }; }
function zC(e) { let t = Object.prototype, n = Object.getPrototypeOf(e.prototype).constructor; for (; n && n !== t;)
    !Oe(n) && !W(n) && cL(n) && sh(n, null), n = Object.getPrototypeOf(n); }
function rL(e) { return typeof e == "string" ? KC(e) : P(e); }
function iL(e, t) { return { propertyName: e, predicate: rL(t.selector), descendants: t.descendants, first: t.first, read: t.read ? t.read : null, static: !!t.static, emitDistinctChangesOnly: !!t.emitDistinctChangesOnly, isSignal: !!t.isSignal }; }
function zm(e, t, n) { let o = [], r = []; for (let i in t)
    if (t.hasOwnProperty(i)) {
        let s = t[i];
        s.forEach(a => { if (n(a)) {
            if (!a.selector)
                throw new Error(`Can't construct a query for the property "${i}" of "${Ge(e)}" since the query selector wasn't defined.`);
            if (s.some(YC))
                throw new Error("Cannot combine @Input decorators with query decorators");
            let c = iL(i, a);
            c.isSignal ? o.push(c) : r.push(c);
        } });
    } return [...o, ...r]; }
function sL(e) { return e === void 0 ? null : KC(e); }
function QC(e) { let t = e.ngMetadataName; return t === "ContentChild" || t === "ContentChildren"; }
function ZC(e) { let t = e.ngMetadataName; return t === "ViewChild" || t === "ViewChildren"; }
function YC(e) { return e.ngMetadataName === "Input"; }
function KC(e) { return e.split(",").map(t => t.trim()); }
var aL = ["ngOnChanges", "ngOnInit", "ngOnDestroy", "ngDoCheck", "ngAfterViewInit", "ngAfterViewChecked", "ngAfterContentInit", "ngAfterContentChecked"];
function cL(e) { let t = Ud(); if (aL.some(o => t.hasLifecycleHook(e, o)))
    return !0; let n = t.propMetadata(e); for (let o in n) {
    let r = n[o];
    for (let i = 0; i < r.length; i++) {
        let s = r[i], a = s.ngMetadataName;
        if (YC(s) || QC(s) || ZC(s) || a === "Output" || a === "HostBinding" || a === "HostListener")
            return !0;
    }
} return !1; }
function JC(e, t) { let n = null, o = null; Object.defineProperty(e, $e, { get: () => { if (o === null) {
        let r = Qm(e, t), i = ee({ usage: 0, kind: "pipe", type: r.type });
        o = i.compileFactory(Ee, `ng:///${r.name}/\u0275fac.js`, { name: r.name, type: r.type, typeArgumentCount: 0, deps: hi(e), target: i.FactoryTarget.Pipe });
    } return o; }, configurable: !1 }), Object.defineProperty(e, fr, { get: () => { if (n === null) {
        let r = Qm(e, t);
        n = ee({ usage: 0, kind: "pipe", type: r.type }).compilePipe(Ee, `ng:///${r.name}/\u0275pipe.js`, r);
    } return n; }, configurable: !1 }); }
function Qm(e, t) { return { type: e, name: e.name, pipeName: t.name, pure: t.pure !== void 0 ? t.pure : !0, isStandalone: t.standalone === void 0 ? !0 : !!t.standalone }; }
var XC = Ao("Directive", (e = {}) => e, void 0, void 0, (e, t) => sh(e, t)), lL = Ao("Component", (e = {}) => q({ changeDetection: _a.Eager }, e), XC, void 0, (e, t) => UC(e, t)), uL = Ao("Pipe", e => q({ pure: !0 }, e), void 0, void 0, (e, t) => JC(e, t)), dL = Ot("Input", e => e ? typeof e == "string" ? { alias: e } : e : {}), fL = Ot("Output", e => ({ alias: e })), pL = Ot("HostBinding", e => ({ hostPropertyName: e })), hL = Ot("HostListener", (e, t) => ({ eventName: e, args: t })), gL = Ao("NgModule", e => e, void 0, void 0, (e, t) => BC(e, t));
var eM = (() => { class e {
    applicationErrorHandler = E(_t);
    appRef = E(He);
    taskService = E(gt);
    ngZone = E(G);
    zonelessEnabled = E(so);
    tracing = E(Bn, { optional: !0 });
    zoneIsDefined = typeof Zone < "u" && !!Zone.root.run;
    schedulerTickApplyArgs = [{ data: { __scheduler_tick__: !0 } }];
    subscriptions = new DN;
    angularZoneId = this.zoneIsDefined ? this.ngZone._inner?.get(nr) : null;
    scheduleInRootZone = !this.zonelessEnabled && this.zoneIsDefined && (E(Ms, { optional: !0 }) ?? !1);
    cancelScheduledCallback = null;
    useMicrotaskScheduler = !1;
    runningTick = !1;
    pendingRenderTaskId = null;
    constructor() { this.subscriptions.add(this.appRef.afterTick.subscribe(() => { let n = this.taskService.add(); if (!this.runningTick && (this.cleanup(), !this.zonelessEnabled || this.appRef.includeAllTestViews)) {
        this.taskService.remove(n);
        return;
    } this.switchToMicrotaskScheduler(), this.taskService.remove(n); })), this.subscriptions.add(this.ngZone.onUnstable.subscribe(() => { this.runningTick || this.cleanup(); })); }
    switchToMicrotaskScheduler() { this.ngZone.runOutsideAngular(() => { let n = this.taskService.add(); this.useMicrotaskScheduler = !0, queueMicrotask(() => { this.useMicrotaskScheduler = !1, this.taskService.remove(n); }); }); }
    notify(n) { if (!this.zonelessEnabled && n === 5)
        return; switch (n) {
        case 0:
        case 2: {
            this.appRef.dirtyFlags |= 2;
            break;
        }
        case 3:
        case 4:
        case 5:
        case 1: {
            this.appRef.dirtyFlags |= 4;
            break;
        }
        case 6: {
            this.appRef.dirtyFlags |= 2;
            break;
        }
        case 12: {
            this.appRef.dirtyFlags |= 16;
            break;
        }
        case 13: {
            this.appRef.dirtyFlags |= 2;
            break;
        }
        case 11: break;
        default: this.appRef.dirtyFlags |= 8;
    } if (this.appRef.tracingSnapshot = this.tracing?.snapshot(this.appRef.tracingSnapshot) ?? null, !this.shouldScheduleTick())
        return; let o = this.useMicrotaskScheduler ? Tg : ou; this.pendingRenderTaskId = this.taskService.add(), this.scheduleInRootZone ? this.cancelScheduledCallback = Zone.root.run(() => o(() => this.tick())) : this.cancelScheduledCallback = this.ngZone.runOutsideAngular(() => o(() => this.tick())); }
    shouldScheduleTick() { return !(this.appRef.destroyed || this.pendingRenderTaskId !== null || this.runningTick || this.appRef._runningTick || !this.zonelessEnabled && this.zoneIsDefined && Zone.current.get(nr + this.angularZoneId)); }
    tick() { if (this.runningTick || this.appRef.destroyed)
        return; if (this.appRef.dirtyFlags === 0) {
        this.cleanup();
        return;
    } !this.zonelessEnabled && this.appRef.dirtyFlags & 7 && (this.appRef.dirtyFlags |= 1); let n = this.taskService.add(); try {
        this.ngZone.run(() => { this.runningTick = !0, this.appRef._tick(); }, void 0, this.schedulerTickApplyArgs);
    }
    catch (o) {
        this.applicationErrorHandler(o);
    }
    finally {
        this.taskService.remove(n), this.cleanup();
    } }
    ngOnDestroy() { this.subscriptions.unsubscribe(), this.cleanup(); }
    cleanup() { if (this.runningTick = !1, this.cancelScheduledCallback?.(), this.cancelScheduledCallback = null, this.pendingRenderTaskId !== null) {
        let n = this.pendingRenderTaskId;
        this.pendingRenderTaskId = null, this.taskService.remove(n);
    } }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Lt({ token: e, factory: e.\u0275fac });
} return e; })();
function mL() { return te("NgZoneless"), Pe([...Nc(), []]); }
function Nc() { return [{ provide: qe, useExisting: eM }, { provide: G, useClass: or }, { provide: so, useValue: !0 }]; }
var vL = (() => { class e {
    compileModuleSync(n) { return new _o(n); }
    compileModuleAsync(n) { return Promise.resolve(this.compileModuleSync(n)); }
    clearCache() { }
    clearCacheFor(n) { }
    getModuleId(n) { }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Lt({ token: e, factory: e.\u0275fac });
} return e; })(), tM = new C(""), jd = class {
};
function yL() { return typeof ngI18nClosureMode < "u" && ngI18nClosureMode && typeof goog < "u" && goog.LOCALE !== "en" ? goog.LOCALE : typeof $localize < "u" && $localize.locale || Pi; }
var ah = new C("", { factory: () => E(ah, { optional: !0, skipSelf: !0 }) || yL() }), EL = new C("", { factory: () => Ok }), IL = new C(""), DL = new C(""), nM = (function (e) { return e[e.Error = 0] = "Error", e[e.Warning = 1] = "Warning", e[e.Ignore = 2] = "Ignore", e; })(nM || {});
function Qs(e, t) { let n = e[m]; for (let o = I; o < n.bindingStartIndex; o++)
    if (K(e[o])) {
        let r = e[o];
        if (!(o === n.bindingStartIndex - 1)) {
            let s = n.data[o], a = pe(n, s);
            if ($I(a)) {
                t.push({ lContainer: r, lView: e, tNode: s, tDetails: a });
                continue;
            }
        }
        J(r[B]) && Qs(r[B], t);
        for (let s = U; s < r.length; s++)
            Qs(r[s], t);
    }
    else
        J(e[o]) && Qs(e[o], t); }
var Vd = class {
    name;
    callback;
    constructor(t, n) { this.name = t, this.callback = n; }
};
function TL(e) { return e.map(t => t.nativeElement); }
var di = class {
    nativeNode;
    constructor(t) { this.nativeNode = t; }
    get parent() { let t = this.nativeNode.parentNode; return t ? new Fn(t) : null; }
    get injector() { return Wd(this.nativeNode); }
    get componentInstance() { let t = this.nativeNode; return t && (jg(t) || T_(t)); }
    get context() { return jg(this.nativeNode) || D_(this.nativeNode); }
    get listeners() { return __(this.nativeNode).filter(t => t.type === "dom"); }
    get references() { return w_(this.nativeNode); }
    get providerTokens() { return C_(this.nativeNode); }
}, Fn = class extends di {
    constructor(t) { super(t); }
    get nativeElement() { return this.nativeNode.nodeType == Node.ELEMENT_NODE ? this.nativeNode : null; }
    get name() { let t = we(this.nativeNode), n = t ? t.lView : null; return n !== null ? n[m].data[t.nodeIndex].value : this.nativeNode.nodeName; }
    get properties() { let t = we(this.nativeNode), n = t ? t.lView : null; if (n === null)
        return {}; let o = n[m].data, r = o[t.nodeIndex], i = {}; return CL(this.nativeElement, i), wL(i, r, n, o), i; }
    get attributes() { let t = {}, n = this.nativeElement; if (!n)
        return t; let o = we(n), r = o ? o.lView : null; if (r === null)
        return {}; let i = r[m].data[o.nodeIndex].attrs, s = []; if (i) {
        let a = 0;
        for (; a < i.length;) {
            let c = i[a];
            if (typeof c != "string")
                break;
            let l = i[a + 1];
            t[c] = l, s.push(c.toLowerCase()), a += 2;
        }
    } for (let a of n.attributes)
        s.includes(a.name) || (t[a.name] = a.value); return t; }
    get styles() { return this.nativeElement?.style ?? {}; }
    get classes() { let t = {}, o = this.nativeElement.className; return (typeof o != "string" ? o.baseVal.split(" ") : o.split(" ")).forEach(i => t[i] = !0), t; }
    get childNodes() { let t = this.nativeNode.childNodes, n = []; for (let o = 0; o < t.length; o++) {
        let r = t[o];
        n.push(fi(r));
    } return n; }
    get children() { let t = this.nativeElement; if (!t)
        return []; let n = t.children, o = []; for (let r = 0; r < n.length; r++) {
        let i = n[r];
        o.push(fi(i));
    } return o; }
    query(t) { return this.queryAll(t)[0] || null; }
    queryAll(t) { let n = []; return Zm(this, t, n, !0), n; }
    queryAllNodes(t) { let n = []; return Zm(this, t, n, !1), n; }
    triggerEventHandler(t, n) { let o = this.nativeNode, r = []; this.listeners.forEach(i => { if (i.name === t) {
        let s = i.callback;
        s.call(o, n), r.push(s);
    } }), typeof o.eventListeners == "function" && o.eventListeners(t).forEach(i => { if (i.toString().indexOf("__ngUnwrap__") !== -1) {
        let s = i("__ngUnwrap__");
        return r.indexOf(s) === -1 && s.call(o, n);
    } }); }
};
function CL(e, t) { if (e) {
    let n = Object.getPrototypeOf(e), o = Node.prototype;
    for (; n !== null && n !== o;) {
        let r = Object.getOwnPropertyDescriptors(n);
        for (let i in r)
            if (!i.startsWith("__") && !i.startsWith("on")) {
                let s = e[i];
                ML(s) && (t[i] = s);
            }
        n = Object.getPrototypeOf(n);
    }
} }
function ML(e) { return typeof e == "string" || typeof e == "boolean" || typeof e == "number" || e === null; }
function Zm(e, t, n, o) { let r = we(e.nativeNode), i = r ? r.lView : null; if (i !== null) {
    let s = i[m].data[r.nodeIndex];
    Tn(s, i, t, n, o, e.nativeNode);
}
else
    ch(e.nativeNode, t, n, o); }
function Tn(e, t, n, o, r, i) { let s = sg(e, t); if (e.type & 11) {
    if (Ru(s, n, o, r, i), Ce(e)) {
        let c = me(e.index, t);
        c && c[m].firstChild && Tn(c[m].firstChild, c, n, o, r, i);
    }
    else
        e.child && Tn(e.child, t, n, o, r, i), s && ch(s, n, o, r);
    let a = t[e.index];
    K(a) && Ym(a, n, o, r, i);
}
else if (e.type & 4) {
    let a = t[e.index];
    Ru(a[ot], n, o, r, i), Ym(a, n, o, r, i);
}
else if (e.type & 16) {
    let a = t[re], l = a[ce].projection[e.projection];
    if (Array.isArray(l))
        for (let u of l)
            Ru(u, n, o, r, i);
    else if (l) {
        let u = a[z], d = u[m].data[l.index];
        Tn(d, u, n, o, r, i);
    }
}
else
    e.child && Tn(e.child, t, n, o, r, i); if (i !== s) {
    let a = e.flags & 2 ? e.projectionNext : e.next;
    a && Tn(a, t, n, o, r, i);
} }
function Ym(e, t, n, o, r) { for (let i = U; i < e.length; i++) {
    let s = e[i], a = s[m].firstChild;
    a && Tn(a, s, t, n, o, r);
} }
function Ru(e, t, n, o, r) { if (r !== e) {
    let i = fi(e);
    if (!i)
        return;
    (o && i instanceof Fn && t(i) && n.indexOf(i) === -1 || !o && t(i) && n.indexOf(i) === -1) && n.push(i);
} }
function ch(e, t, n, o) { let r = e.childNodes, i = r.length; for (let s = 0; s < i; s++) {
    let a = r[s], c = fi(a);
    c && ((o && c instanceof Fn && t(c) && n.indexOf(c) === -1 || !o && t(c) && n.indexOf(c) === -1) && n.push(c), ch(a, t, n, o));
} }
function wL(e, t, n, o) { let r = t.propertyBindings; if (r !== null)
    for (let i = 0; i < r.length; i++) {
        let s = r[i], c = o[s].split(WS), l = c[0];
        if (c.length > 1) {
            let u = c[1];
            for (let d = 1; d < c.length - 1; d++)
                u += b(n[s + d - 1]) + c[d + 1];
            e[l] = u;
        }
        else
            e[l] = n[s];
    } }
var xu = "__ng_debug__";
function fi(e) { return e instanceof Node ? (e.hasOwnProperty(xu) || (e[xu] = e.nodeType == Node.ELEMENT_NODE ? new Fn(e) : new di(e)), e[xu]) : null; }
var Vi = class {
    destroyed = !1;
    listeners = null;
    errorHandler = E(Mt, { optional: !0 });
    isEmitting = !1;
    hasNullListeners = !1;
    destroyRef = E(Re);
    constructor() { this.destroyRef.onDestroy(() => { this.destroyed = !0, this.listeners = null; }); }
    subscribe(t) { if (this.destroyed)
        throw new D(953, !1); return (this.listeners ??= []).push(t), { unsubscribe: () => { let n = this.listeners ? this.listeners.indexOf(t) : -1; n > -1 && (this.isEmitting ? (this.hasNullListeners = !0, this.listeners[n] = null) : this.listeners.splice(n, 1)); } }; }
    emit(t) { if (this.destroyed) {
        console.warn(ir(953, !1));
        return;
    } if (this.listeners === null)
        return; this.isEmitting = !0; let n = x(null); try {
        for (let o of this.listeners)
            try {
                o !== null && o(t);
            }
            catch (r) {
                this.errorHandler?.handleError(r);
            }
    }
    finally {
        this.hasNullListeners && (this.hasNullListeners = !1, this.listeners && NL(this.listeners)), x(n), this.isEmitting = !1;
    } }
};
function NL(e) { let t = e.length - 1; for (; t > -1;)
    e[t] === null && e.splice(t, 1), t--; }
function _L(e) { return e.destroyRef; }
var sM = new C("");
function ke(e, t) { return Zi(e, t?.equal); }
function xe(e) { return $h(e); }
var _c = class extends Error {
    dependency;
    constructor(t) { super("Dependency error", { cause: t.error() }), this.name = "ResourceDependencyError", this.dependency = t; }
}, Un = class e extends Error {
    _brand;
    constructor(t) { super(t); }
    static IDLE = new e("IDLE");
    static LOADING = new e("LOADING");
}, SL = e => e;
function Sc(e, t) { if (typeof e == "function") {
    let n = Xc(e, SL, t?.equal);
    return oM(n, t?.debugName);
}
else {
    let n = Xc(e.source, e.computation, e.equal);
    return oM(n, e.debugName);
} }
function oM(e, t) { let n = e[ae], o = e; return o.set = r => Hh(n, r), o.update = r => Bh(n, r), o.asReadonly = ro.bind(e), o; }
function bL(e) { let t = e.request, n = e.params ?? t ?? (() => null); return new bc(n, RL(e), e.defaultValue, e.equal ? AL(e.equal) : void 0, e.debugName, e.injector ?? E(oe), e.id); }
var lh = class {
    value;
    isLoading;
    constructor(t, n) { this.value = t, this.value.set = this.set.bind(this), this.value.update = this.update.bind(this), this.value.asReadonly = ro, this.isLoading = ke(() => this.status() === "loading" || this.status() === "reloading", void 0); }
    isError = ke(() => this.status() === "error");
    update(t) { this.set(t(xe(this.value))); }
    isValueDefined = ke(() => this.isError() ? !1 : this.value() !== void 0);
    _snapshot;
    get snapshot() { return this._snapshot ??= ke(() => { let t = this.status(); return t === "error" ? { status: "error", error: this.error() } : { status: t, value: this.value() }; }); }
    hasValue() { return this.isValueDefined(); }
    asReadonly() { return this; }
}, bc = class extends lh {
    loaderFn;
    equal;
    debugName;
    transferCacheKey;
    pendingTasks;
    state;
    extRequest;
    effectRef;
    pendingController;
    resolvePendingTask = void 0;
    destroyed = !1;
    unregisterOnDestroy;
    status;
    error;
    transferState;
    constructor(t, n, o, r, i, s, a, c) { if (dh())
        throw fh(); super(ke(() => { let u = this.state().stream?.(); if (!u || this.state().status === "loading" && this.error())
        return o; if (!Ac(u))
        throw new Hi(this.error()); return u.value; }, { equal: r }), i), this.loaderFn = n, this.equal = r, this.debugName = i, this.transferCacheKey = a; let l = s.get(sM, void 0, { optional: !0 }) ?? { isActive: !1 }; this.transferState = s.get(St, void 0, { optional: !0 }) ?? void 0, this.extRequest = Sc(() => { try {
        return qn(!0), { request: t(OL), reload: 0 };
    }
    catch (u) {
        return Bi(u), u === Un.IDLE ? { status: "idle", reload: 0 } : u === Un.LOADING ? { status: "loading", reload: 0 } : { error: u, reload: 0 };
    }
    finally {
        qn(!1);
    } }, void 0), this.state = Sc({ source: this.extRequest, computation: (u, d) => { let { request: f, status: p, error: h } = u, v; if (h)
            p = "resolved", v = mt({ error: Rc(h) }, void 0);
        else if (!p)
            if (d)
                p = f === void 0 ? "idle" : "loading", d.value.extRequest.request === f && (v = d.value.stream);
            else {
                let y = this.transferState, T = this.transferCacheKey;
                l.isActive && T && y && f !== void 0 && y.hasKey(T) && (v = mt({ value: y.get(T, o) }, void 0)), v || (v = c?.(u.request)), c = void 0, p = f === void 0 ? "idle" : v ? "resolved" : "loading";
            } return { extRequest: u, status: p, previousStatus: d ? iM(d.value) : "idle", stream: v }; } }), this.effectRef = Ns(this.loadEffect.bind(this), { injector: s, manualCleanup: !0 }), this.pendingTasks = s.get(Sr), this.unregisterOnDestroy = s.get(Re).onDestroy(() => this.destroy()), this.status = ke(() => iM(this.state()), void 0), this.error = ke(() => { let u = this.state().stream?.(); return u && !Ac(u) ? u.error : void 0; }, void 0); }
    set(t) { if (this.destroyed)
        return; let n = xe(this.error), o = xe(this.state); if (!n) {
        let r = xe(this.value);
        if (o.status === "local" && (this.equal ? this.equal(r, t) : r === t))
            return;
    } this.state.set({ extRequest: o.extRequest, status: "local", previousStatus: "local", stream: mt({ value: t }, void 0) }), this.abortInProgressLoad(); }
    reload() { let { status: t } = xe(this.state); return t === "idle" || t === "loading" ? !1 : (this.extRequest.update(({ request: n, reload: o }) => ({ request: n, reload: o + 1 })), !0); }
    destroy() { this.destroyed = !0, this.unregisterOnDestroy(), this.effectRef.destroy(), this.abortInProgressLoad(), this.state.set({ extRequest: { request: void 0, reload: 0 }, status: "idle", previousStatus: "idle", stream: void 0 }); }
    loadEffect() { return Se(this, null, function* () { let t = this.extRequest(), { status: n, previousStatus: o } = xe(this.state); if (t.request === void 0)
        return; if (n !== "loading")
        return; this.abortInProgressLoad(); let r = this.resolvePendingTask = this.pendingTasks.add(), { signal: i } = this.pendingController = new AbortController; try {
        let s = xe(() => this.loaderFn({ params: t.request, abortSignal: i, previous: { status: o } })), a = () => i.aborted || xe(this.extRequest) !== t;
        if (ao(s)) {
            if (a())
                return;
            this.state.set({ extRequest: t, status: "resolved", previousStatus: "resolved", stream: s });
            let c = xe(s);
            typeof ngServerMode < "u" && ngServerMode && rM(c, this.transferCacheKey, this.transferState);
        }
        else {
            let c = yield s;
            if (a())
                return;
            this.state.set({ extRequest: t, status: "resolved", previousStatus: "resolved", stream: c });
            let l = c ? xe(c) : void 0;
            typeof ngServerMode < "u" && ngServerMode && rM(l, this.transferCacheKey, this.transferState);
        }
    }
    catch (s) {
        if (Bi(s), i.aborted || xe(this.extRequest) !== t)
            return;
        this.state.set({ extRequest: t, status: "resolved", previousStatus: "error", stream: mt({ error: Rc(s) }, void 0) });
    }
    finally {
        r?.(), r = void 0;
    } }); }
    abortInProgressLoad() { xe(() => this.pendingController?.abort()), this.pendingController = void 0, this.resolvePendingTask?.(), this.resolvePendingTask = void 0; }
};
function rM(e, t, n) { t && n && e && Ac(e) && n.set(t, e.value); }
function AL(e) { return (t, n) => t === void 0 || n === void 0 ? t === n : e(t, n); }
function RL(e) { return xL(e) ? e.stream : t => Se(null, null, function* () { try {
    return mt({ value: yield e.loader(t) }, void 0);
}
catch (n) {
    return mt({ error: Rc(n) }, void 0);
} }); }
function xL(e) { return !!e.stream; }
function iM(e) { switch (e.status) {
    case "loading": return e.extRequest.reload === 0 ? "loading" : "reloading";
    case "resolved": return Ac(e.stream()) ? "resolved" : "error";
    default: return e.status;
} }
function Ac(e) { return e.error === void 0; }
function Rc(e) { return kL(e) ? e : new uh(e); }
function kL(e) { return e instanceof Error || typeof e == "object" && typeof e.name == "string" && typeof e.message == "string"; }
var Hi = class extends Error {
    constructor(t) { super(t.message, { cause: t }); }
}, uh = class extends Error {
    constructor(t) { super(String(t), { cause: t }); }
};
function aM(e) { switch (e.status()) {
    case "idle": throw Un.IDLE;
    case "error": throw new _c(e);
    case "loading":
    case "reloading": throw Un.LOADING;
} return e.value(); }
var OL = { chain: aM }, cM = !1;
function dh() { return cM; }
function qn(e) { cM = e; }
function fh() { return new D(992, !1); }
function Bi(e) { if (e instanceof D && e.code === 992)
    throw e; }
import { Subscription as hP } from "rxjs";
var vh = { JSACTION: "__jsaction", OWNER: "__owner" }, fM = {};
function LL(e) { return e[vh.JSACTION]; }
function lM(e, t) { e[vh.JSACTION] = t; }
function PL(e) { return fM[e]; }
function FL(e, t) { fM[e] = t; }
var M = { CLICK: "click", CLICKMOD: "clickmod", DBLCLICK: "dblclick", FOCUS: "focus", FOCUSIN: "focusin", BLUR: "blur", FOCUSOUT: "focusout", SUBMIT: "submit", KEYDOWN: "keydown", KEYPRESS: "keypress", KEYUP: "keyup", MOUSEOVER: "mouseover", MOUSEOUT: "mouseout", MOUSEENTER: "mouseenter", MOUSELEAVE: "mouseleave", POINTEROVER: "pointerover", POINTEROUT: "pointerout", POINTERENTER: "pointerenter", POINTERLEAVE: "pointerleave", ERROR: "error", LOAD: "load", TOUCHSTART: "touchstart", TOUCHEND: "touchend", TOUCHMOVE: "touchmove", TOGGLE: "toggle" }, jL = [M.MOUSEENTER, M.MOUSELEAVE, "pointerenter", "pointerleave"], VL = [M.CLICK, M.DBLCLICK, M.FOCUSIN, M.FOCUSOUT, M.KEYDOWN, M.KEYUP, M.KEYPRESS, M.MOUSEOVER, M.MOUSEOUT, M.SUBMIT, M.TOUCHSTART, M.TOUCHEND, M.TOUCHMOVE, "touchcancel", "auxclick", "change", "compositionstart", "compositionupdate", "compositionend", "beforeinput", "input", "select", "copy", "cut", "paste", "mousedown", "mouseup", "wheel", "contextmenu", "dragover", "dragenter", "dragleave", "drop", "dragstart", "dragend", "pointerdown", "pointermove", "pointerup", "pointercancel", "pointerover", "pointerout", "gotpointercapture", "lostpointercapture", "ended", "loadedmetadata", "pagehide", "pageshow", "visibilitychange", "beforematch"], pM = [M.FOCUS, M.BLUR, M.ERROR, M.LOAD, M.TOGGLE], Fc = e => pM.indexOf(e) >= 0, HL = VL.concat(pM), hM = e => HL.indexOf(e) >= 0;
function BL(e) { return e === M.MOUSEENTER ? M.MOUSEOVER : e === M.MOUSELEAVE ? M.MOUSEOUT : e === M.POINTERENTER ? M.POINTEROVER : e === M.POINTERLEAVE ? M.POINTEROUT : e; }
function $L(e, t, n, o) { let r = !1; Fc(t) && (r = !0); let i = typeof o == "boolean" ? { capture: r, passive: o } : r; return e.addEventListener(t, n, i), { eventType: t, handler: n, capture: r, passive: o }; }
function UL(e, t) { if (e.removeEventListener) {
    let n = typeof t.passive == "boolean" ? { capture: t.capture } : t.capture;
    e.removeEventListener(t.eventType, t.handler, n);
}
else
    e.detachEvent && e.detachEvent(`on${t.eventType}`, t.handler); }
function qL(e) { e.preventDefault ? e.preventDefault() : e.returnValue = !1; }
var uM = typeof navigator < "u" && /Macintosh/.test(navigator.userAgent);
function GL(e) { return e.which === 2 || e.which == null && e.button === 4; }
function WL(e) { return uM && e.metaKey || !uM && e.ctrlKey || GL(e) || e.shiftKey; }
function zL(e, t, n) { let o = e.relatedTarget; return (e.type === M.MOUSEOVER && t === M.MOUSEENTER || e.type === M.MOUSEOUT && t === M.MOUSELEAVE || e.type === M.POINTEROVER && t === M.POINTERENTER || e.type === M.POINTEROUT && t === M.POINTERLEAVE) && (!o || o !== n && !n.contains(o)); }
function QL(e, t) { let n = {}; for (let o in e) {
    if (o === "srcElement" || o === "target")
        continue;
    let r = o, i = e[r];
    typeof i != "function" && (n[r] = i);
} return e.type === M.MOUSEOVER ? n.type = M.MOUSEENTER : e.type === M.MOUSEOUT ? n.type = M.MOUSELEAVE : e.type === M.POINTEROVER ? n.type = M.POINTERENTER : n.type = M.POINTERLEAVE, n.target = n.srcElement = t, n.bubbles = !1, n._originalEvent = e, n; }
var Lc = class {
    element;
    handlerInfos = [];
    constructor(t) { this.element = t; }
    addEventListener(t, n, o) { this.handlerInfos.push($L(this.element, t, n(this.element), o)); }
    cleanUp() { for (let t = 0; t < this.handlerInfos.length; t++)
        UL(this.element, this.handlerInfos[t]); this.handlerInfos = []; }
}, ZL = { EVENT_ACTION_SEPARATOR: ":" };
function cn(e) { return e.eventType; }
function yh(e, t) { e.eventType = t; }
function kc(e) { return e.event; }
function gM(e, t) { e.event = t; }
function mM(e) { return e.targetElement; }
function vM(e, t) { e.targetElement = t; }
function yM(e) { return e.eic; }
function YL(e, t) { e.eic = t; }
function KL(e) { return e.timeStamp; }
function JL(e, t) { e.timeStamp = t; }
function Oc(e) { return e.eia; }
function EM(e, t, n) { e.eia = [t, n]; }
function ph(e) { e.eia = void 0; }
function xc(e) { return e[1]; }
function XL(e) { return e.eirp; }
function IM(e, t) { e.eirp = t; }
function DM(e) { return e.eir; }
function TM(e, t) { e.eir = t; }
function CM(e) { return { eventType: e.eventType, event: e.event, targetElement: e.targetElement, eic: e.eic, eia: e.eia, timeStamp: e.timeStamp, eirp: e.eirp, eiack: e.eiack, eir: e.eir }; }
function eP(e, t, n, o, r, i, s, a) { return { eventType: e, event: t, targetElement: n, eic: o, timeStamp: r, eia: i, eirp: s, eiack: a }; }
var hh = class e {
    eventInfo;
    constructor(t) { this.eventInfo = t; }
    getEventType() { return cn(this.eventInfo); }
    setEventType(t) { yh(this.eventInfo, t); }
    getEvent() { return kc(this.eventInfo); }
    setEvent(t) { gM(this.eventInfo, t); }
    getTargetElement() { return mM(this.eventInfo); }
    setTargetElement(t) { vM(this.eventInfo, t); }
    getContainer() { return yM(this.eventInfo); }
    setContainer(t) { YL(this.eventInfo, t); }
    getTimestamp() { return KL(this.eventInfo); }
    setTimestamp(t) { JL(this.eventInfo, t); }
    getAction() { let t = Oc(this.eventInfo); if (t)
        return { name: t[0], element: t[1] }; }
    setAction(t) { if (!t) {
        ph(this.eventInfo);
        return;
    } EM(this.eventInfo, t.name, t.element); }
    getIsReplay() { return XL(this.eventInfo); }
    setIsReplay(t) { IM(this.eventInfo, t); }
    getResolved() { return DM(this.eventInfo); }
    setResolved(t) { TM(this.eventInfo, t); }
    clone() { return new e(CM(this.eventInfo)); }
}, tP = {}, nP = /\s*;\s*/, oP = M.CLICK, gh = class {
    a11yClickSupport = !1;
    clickModSupport = !0;
    syntheticMouseEventSupport;
    updateEventInfoForA11yClick = void 0;
    preventDefaultForA11yClick = void 0;
    populateClickOnlyAction = void 0;
    constructor({ syntheticMouseEventSupport: t = !1, clickModSupport: n = !0 } = {}) { this.syntheticMouseEventSupport = t, this.clickModSupport = n; }
    resolveEventType(t) { this.clickModSupport && cn(t) === M.CLICK && WL(kc(t)) ? yh(t, M.CLICKMOD) : this.a11yClickSupport && this.updateEventInfoForA11yClick(t); }
    resolveAction(t) { DM(t) || (this.populateAction(t, mM(t)), TM(t, !0)); }
    resolveParentAction(t) { let n = Oc(t), o = n && xc(n); ph(t); let r = o && this.getParentNode(o); r && this.populateAction(t, r); }
    populateAction(t, n) { let o = n; for (; o && o !== yM(t) && (o.nodeType === Node.ELEMENT_NODE && this.populateActionOnElement(o, t), !Oc(t));)
        o = this.getParentNode(o); let r = Oc(t); if (r && (this.a11yClickSupport && this.preventDefaultForA11yClick(t), this.syntheticMouseEventSupport && (cn(t) === M.MOUSEENTER || cn(t) === M.MOUSELEAVE || cn(t) === M.POINTERENTER || cn(t) === M.POINTERLEAVE)))
        if (zL(kc(t), cn(t), xc(r))) {
            let i = QL(kc(t), xc(r));
            gM(t, i), vM(t, xc(r));
        }
        else
            ph(t); }
    getParentNode(t) { let n = t[vh.OWNER]; if (n)
        return n; let o = t.parentNode; return o?.nodeName === "#document-fragment" ? o?.host ?? null : o; }
    populateActionOnElement(t, n) { let o = this.parseActions(t), r = o[cn(n)]; r !== void 0 && EM(n, r, t), this.a11yClickSupport && this.populateClickOnlyAction(t, n, o); }
    parseActions(t) { let n = LL(t); if (!n) {
        let o = t.getAttribute(co.JSACTION);
        if (!o)
            n = tP, lM(t, n);
        else {
            if (n = PL(o), !n) {
                n = {};
                let r = o.split(nP);
                for (let i = 0; i < r.length; i++) {
                    let s = r[i];
                    if (!s)
                        continue;
                    let a = s.indexOf(ZL.EVENT_ACTION_SEPARATOR), c = a !== -1, l = c ? s.substr(0, a).trim() : oP, u = c ? s.substr(a + 1).trim() : s;
                    n[l] = u;
                }
                FL(o, n);
            }
            lM(t, n);
        }
    } return n; }
    addA11yClickSupport(t, n, o) { this.a11yClickSupport = !0, this.updateEventInfoForA11yClick = t, this.preventDefaultForA11yClick = n, this.populateClickOnlyAction = o; }
}, MM = (function (e) { return e[e.I_AM_THE_JSACTION_FRAMEWORK = 0] = "I_AM_THE_JSACTION_FRAMEWORK", e; })(MM || {}), mh = class {
    dispatchDelegate;
    actionResolver;
    eventReplayer;
    eventReplayScheduled = !1;
    replayEventInfoWrappers = [];
    constructor(t, { actionResolver: n, eventReplayer: o } = {}) { this.dispatchDelegate = t, this.actionResolver = n, this.eventReplayer = o; }
    dispatch(t) { let n = new hh(t); this.actionResolver?.resolveEventType(t), this.actionResolver?.resolveAction(t); let o = n.getAction(); if (o && rP(o.element, n) && qL(n.getEvent()), this.eventReplayer && n.getIsReplay()) {
        this.scheduleEventInfoWrapperReplay(n);
        return;
    } this.dispatchDelegate(n); }
    scheduleEventInfoWrapperReplay(t) { this.replayEventInfoWrappers.push(t), !this.eventReplayScheduled && (this.eventReplayScheduled = !0, Promise.resolve().then(() => { this.eventReplayScheduled = !1, this.eventReplayer(this.replayEventInfoWrappers); })); }
};
function rP(e, t) { return e.tagName === "A" && (t.getEventType() === M.CLICK || t.getEventType() === M.CLICKMOD); }
var wM = Symbol.for("propagationStopped"), Eh = { REPLAY: 101 };
var iP = "`preventDefault` called during event replay.";
var sP = "`composedPath` called during event replay.", Pc = class {
    dispatchDelegate;
    clickModSupport;
    actionResolver;
    dispatcher;
    constructor(t, n = !0) { this.dispatchDelegate = t, this.clickModSupport = n, this.actionResolver = new gh({ clickModSupport: n }), this.dispatcher = new mh(o => { this.dispatchToDelegate(o); }, { actionResolver: this.actionResolver }); }
    dispatch(t) { this.dispatcher.dispatch(t); }
    dispatchToDelegate(t) { for (t.getIsReplay() && lP(t), aP(t); t.getAction();) {
        if (uP(t), Fc(t.getEventType()) && t.getAction().element !== t.getTargetElement() || (this.dispatchDelegate(t.getEvent(), t.getAction().name), cP(t)))
            return;
        this.actionResolver.resolveParentAction(t.eventInfo);
    } }
};
function aP(e) { let t = e.getEvent(), n = e.getEvent().stopPropagation.bind(t), o = () => { t[wM] = !0, n(); }; Gn(t, "stopPropagation", o), Gn(t, "stopImmediatePropagation", o); }
function cP(e) { return !!e.getEvent()[wM]; }
function lP(e) { let t = e.getEvent(), n = e.getTargetElement(), o = t.preventDefault.bind(t); Gn(t, "target", n), Gn(t, "eventPhase", Eh.REPLAY), Gn(t, "preventDefault", () => { throw o(), new Error(iP + ""); }), Gn(t, "composedPath", () => { throw new Error(sP + ""); }); }
function uP(e) { let t = e.getEvent(), n = e.getAction()?.element; n && Gn(t, "currentTarget", n, { configurable: !0 }); }
function Gn(e, t, n, { configurable: o = !1 } = {}) { Object.defineProperty(e, t, { value: n, configurable: o }); }
function NM(e, t) { e.ecrd(n => { t.dispatch(n); }, MM.I_AM_THE_JSACTION_FRAMEWORK); }
function dP(e) { return e?.q ?? []; }
function fP(e) { e && (dM(e.c, e.et, e.h), dM(e.c, e.etc, e.h, !0)); }
function dM(e, t, n, o) { for (let r = 0; r < t.length; r++)
    e.removeEventListener(t[r], n, o); }
var pP = !1, _M = (() => { class e {
    static MOUSE_SPECIAL_SUPPORT = pP;
    containerManager;
    eventHandlers = {};
    browserEventTypeToExtraEventTypes = {};
    dispatcher = null;
    queuedEventInfos = [];
    constructor(n) { this.containerManager = n; }
    handleEvent(n, o, r) { let i = eP(n, o, o.target, r, Date.now()); this.handleEventInfo(i); }
    handleEventInfo(n) { if (!this.dispatcher) {
        IM(n, !0), this.queuedEventInfos?.push(n);
        return;
    } this.dispatcher(n); }
    addEvent(n, o, r) { if (n in this.eventHandlers || !this.containerManager || !e.MOUSE_SPECIAL_SUPPORT && jL.indexOf(n) >= 0)
        return; let i = (a, c, l) => { this.handleEvent(a, c, l); }; this.eventHandlers[n] = i; let s = BL(o || n); if (s !== n) {
        let a = this.browserEventTypeToExtraEventTypes[s] || [];
        a.push(n), this.browserEventTypeToExtraEventTypes[s] = a;
    } this.containerManager.addEventListener(s, a => c => { i(n, c, a); }, r); }
    replayEarlyEvents(n = window._ejsa) { n && (this.replayEarlyEventInfos(n.q), fP(n), delete window._ejsa); }
    replayEarlyEventInfos(n) { for (let o = 0; o < n.length; o++) {
        let r = n[o], i = this.getEventTypesForBrowserEventType(r.eventType);
        for (let s = 0; s < i.length; s++) {
            let a = CM(r);
            yh(a, i[s]), this.handleEventInfo(a);
        }
    } }
    getEventTypesForBrowserEventType(n) { let o = []; return this.eventHandlers[n] && o.push(n), this.browserEventTypeToExtraEventTypes[n] && o.push(...this.browserEventTypeToExtraEventTypes[n]), o; }
    handler(n) { return this.eventHandlers[n]; }
    cleanUp() { this.containerManager?.cleanUp(), this.containerManager = null, this.eventHandlers = {}, this.browserEventTypeToExtraEventTypes = {}, this.dispatcher = null, this.queuedEventInfos = []; }
    registerDispatcher(n, o) { this.ecrd(n, o); }
    ecrd(n, o) { if (this.dispatcher = n, this.queuedEventInfos?.length) {
        for (let r = 0; r < this.queuedEventInfos.length; r++)
            this.handleEventInfo(this.queuedEventInfos[r]);
        this.queuedEventInfos = null;
    } }
} return e; })();
function SM(e, t = window) { return dP(t._ejsas?.[e]); }
function Ih(e, t = window) { t._ejsas && (t._ejsas[e] = void 0); }
import "@angular/core/primitives/signals";
import "@angular/core/primitives/di";
import "rxjs/operators";
typeof globalThis.ngServerMode > "u" && (globalThis.ngServerMode = typeof window > "u");
var qc = Symbol("InputSignalNode#UNSET"), QM = Ie(q({}, Yc), { transformFn: void 0, applyValueToInputSignal(e, t) { Zc(e, t); } }), a0 = Symbol();
function ZM(e, t) { let n = Object.create(QM); n.value = e, n.transformFn = t?.transform; function o() { if (Wi(n), n.value === qc) {
    let r = null;
    throw new D(-950, r);
} return n.value; } return o[ae] = n, o; }
var gP = (function (e) { return e.Angular = "angular", e.ACX = "acx", e.Wiz = "wiz", e; })(gP || {}), bM = class {
    attributeName;
    constructor(t) { this.attributeName = t; }
    __NG_ELEMENT_ID__ = () => wa(this.attributeName);
    toString() { return `HostAttributeToken ${this.attributeName}`; }
}, c0 = (() => { let e = new C(""); return e.__NG_ELEMENT_ID__ = t => { let n = _(); if (n === null)
    throw new D(-204, !1); if (n.type & 2)
    return n.value; if (t & 8)
    return null; throw new D(-204, !1); }, e; })();
function mP(e) { return vP(e) ? e.default : e; }
function vP(e) { return e && typeof e == "object" && "default" in e; }
function l0(e, t) { let n = E(oe), o = null, r = () => (o || (o = e()), o); return t?.prefetch && t.prefetch().then(() => r()), () => r().then(i => n.get(mP(i))); }
function u0(e) { let t = E(Na), { promise: n, resolve: o } = oo(); return t.requestOnIdle(() => o(), e), n; }
var Wn = (function (e) { return e[e.Directive = 0] = "Directive", e[e.Component = 1] = "Component", e[e.Injectable = 2] = "Injectable", e[e.Pipe = 3] = "Pipe", e[e.NgModule = 4] = "NgModule", e[e.Service = 5] = "Service", e; })(Wn || {});
function d0(e) { return new Vi; }
function AM(e, t) { return ZM(e, t); }
function yP(e) { return ZM(qc, e); }
var f0 = (AM.required = yP, AM);
function YM(e, t) { let n = Object.create(QM), o = new Vi; n.value = e; function r() { return Wi(n), RM(n.value), n.value; } return r[ae] = n, r.asReadonly = ro.bind(r), r.set = i => { n.equal(n.value, i) || (Zc(n, i), o.emit(i)); }, r.update = i => { RM(n.value), r.set(i(n.value)); }, r.subscribe = o.subscribe.bind(o), r.destroyRef = o.destroyRef, r; }
function RM(e) { if (e === qc)
    throw new D(952, !1); }
function xM(e, t) { return YM(e, t); }
function EP(e) { return YM(qc, e); }
var p0 = (xM.required = EP, xM);
function kM(e, t) { return Xf(t); }
function IP(e, t) { return ep(t); }
var h0 = (kM.required = IP, kM);
function g0(e, t) { return tp(t); }
function OM(e, t) { return Xf(t); }
function DP(e, t) { return ep(t); }
var m0 = (OM.required = DP, OM);
function v0(e, t) { return tp(t); }
function y0(...e) { return e.reduce((t, n) => Object.assign(t, n, { providers: [...t.providers, ...n.providers] }), { providers: [] }); }
var KM = !0, Zo = class {
}, E0 = Ot("ContentChildren", (e, t = {}) => q({ selector: e, first: !1, isViewQuery: !1, descendants: !1, emitDistinctChangesOnly: KM }, t), Zo), I0 = Ot("ContentChild", (e, t = {}) => q({ selector: e, first: !0, isViewQuery: !1, descendants: !0 }, t), Zo), D0 = Ot("ViewChildren", (e, t = {}) => q({ selector: e, first: !1, isViewQuery: !0, descendants: !0, emitDistinctChangesOnly: KM }, t), Zo), T0 = Ot("ViewChild", (e, t) => q({ selector: e, first: !0, isViewQuery: !0, descendants: !0 }, t), Zo), C0 = (() => { class e {
    constructor(n) { }
    static \u0275fac = function (o) { return new (o || e)(he(He)); };
    static \u0275mod = rp({ type: e });
    static \u0275inj = lr({});
} return e; })(), M0 = new C("", { providedIn: "platform", factory: () => null }), w0 = new C("", { providedIn: "platform", factory: () => null }), N0 = new C("", { providedIn: "platform", factory: () => null }), jc = new WeakSet, LM = "";
function PM(e) { return e.get(ka, Jd); }
function TP() { let e = [{ provide: ka, useFactory: () => { let t = !0; if (typeof ngServerMode > "u" || !ngServerMode) {
            let n = E(vt);
            t = !!window._ejsas?.[n];
        } return t && te("NgEventReplay"), t; } }]; return (typeof ngServerMode > "u" || !ngServerMode) && e.push({ provide: We, useValue: () => { let t = E(He), { injector: n } = t; if (!jc.has(t)) {
        let o = E(Ti);
        if (PM(n)) {
            Wv();
            let r = n.get(vt), i = qv(r, (s, a, c) => { s.nodeType === Node.ELEMENT_NODE && (Uv(s, a, c), tf(s, o)); });
            t.onDestroy(i);
        }
    } }, multi: !0 }, { provide: ki, useFactory: () => { let t = E(He), { injector: n } = t; return () => { if (!PM(n) || jc.has(t))
        return; jc.add(t); let o = n.get(vt); t.onDestroy(() => { jc.delete(t), typeof ngServerMode < "u" && !ngServerMode && Ih(o); }), t.whenStable().then(() => { if (t.destroyed)
        return; let r = n.get(of); CP(r, n); let i = n.get(Ti); i.get(LM)?.forEach(nf), i.delete(LM); let s = r.instance; Ci(n) ? t.onDestroy(() => s.cleanUp()) : s.cleanUp(); }); }; }, multi: !0 }), e; }
var CP = (e, t) => { let n = t.get(vt), o = window._ejsas[n], r = e.instance = new _M(new Lc(o.c)); for (let a of o.et)
    r.addEvent(a); for (let a of o.etc)
    r.addEvent(a); let i = SM(n); r.replayEarlyEventInfos(i), Ih(n); let s = new Pc(a => { wP(t, a, a.currentTarget); }); NM(r, s); };
function MP(e, t, n) { let o = new Map, r = t[zt], i = e.cleanup; if (!i || !r)
    return o; for (let s = 0; s < i.length;) {
    let a = i[s++], c = i[s++];
    if (typeof a != "string")
        continue;
    let l = a;
    if (!hM(l))
        continue;
    Fc(l) ? n.capture.add(l) : n.regular.add(l);
    let u = O(t[c]);
    s++;
    let d = i[s++];
    (typeof d == "boolean" || d >= 0) && (o.has(u) ? o.get(u).push(l) : o.set(u, [l]));
} return o; }
function wP(e, t, n) { let o = (n && n.getAttribute(Po)) ?? ""; /d\d+/.test(o) ? NP(o, e, t, n) : t.eventPhase === Eh.REPLAY && rf(t, n); }
function NP(e, t, n, o) { let r = t.get(Vv); r.push({ event: n, currentTarget: o }), Ht(t, e, _P(r)); }
function _P(e) { return t => { let n = new Set(t), o = []; for (let { event: r, currentTarget: i } of e) {
    let s = i.getAttribute(Po);
    n.has(s) ? rf(r, i) : o.push({ event: r, currentTarget: i });
} e.length = 0, e.push(...o); }; }
var FM = !1, jM = !1, SP = 1e4;
function bP() { FM || (FM = !0, Kv(), VD(), bT(), HD(), jI(), cI(), FE(), eE()); }
function AP() { jM || (jM = !0, QD(), SE(), kE()); }
function RP(e) { return e.whenStable(); }
var _0 = "ngcm";
function S0() { let e = [{ provide: Vn, useFactory: () => { let t = !0; return (typeof ngServerMode > "u" || !ngServerMode) && (t = !!E(St, { optional: !0 })?.get(Oa, null)), t && te("NgHydration"), t; } }, { provide: We, useValue: () => { if ($f(!1), typeof ngServerMode < "u" && ngServerMode)
            return; let t = E(Nt); E(Vn) && (iy(t), bP()); }, multi: !0 }]; return (typeof ngServerMode > "u" || !ngServerMode) && e.push({ provide: Yd, useFactory: () => E(Vn) }, { provide: ki, useFactory: () => { let t = E(qe); if (E(Vn)) {
        let n = E(He);
        return () => { RP(n).then(() => { n.destroyed || (Uf(n), t.notify(7)); }); };
    } return () => { }; }, multi: !0 }), Pe(e); }
function b0() { return [{ provide: Kd, useFactory: () => E(Vn) }, { provide: We, useValue: () => { E(Vn) && (AP(), $f(!0), te("NgI18nHydration")); }, multi: !0 }]; }
function A0() { let e = [TP(), { provide: Xd, useValue: !0 }, { provide: Pt, useFactory: lC }]; return (typeof ngServerMode > "u" || !ngServerMode) && e.push({ provide: ki, useFactory: () => { let t = E(oe), n = E(Nt); return () => { uC(t, n); }; }, multi: !0 }), e; }
var VM = SP - 1e3, Ch = class {
    openTasks = new Map;
    add(t) { this.openTasks.set(t, new Error("Task stack tracking error")); }
    remove(t) { this.openTasks.delete(t); }
};
function R0() { let e = new Ch, { openTasks: t } = e; return Pe([{ provide: nu, useValue: e }, _I(() => { console.warn("Stability debugging utility was provided in production mode. This will cause debug code to be included in production bundles. If this is intentional because you are debugging stability issues in a production environment, you can ignore this warning."); let n = E(G), o = E(He), r = null; typeof Zone < "u" && n.run(() => { r = Zone.current.get("TaskTrackingZone"); }), n.runOutsideAngular(() => { let i = setTimeout(() => { if (console.debug(`---- Application did not stabilize within ${VM / 1e3} seconds ----`), typeof Zone < "u" && !r && console.info('Zone.js is present but no TaskTrackingZone found. To enable better debugging of tasks in the Angular Zone, import "zone.js/plugins/task-tracking" in your application.'), r?.macroTasks?.length) {
        console.group("Macrotasks keeping Angular Zone unstable:");
        for (let s of r?.macroTasks ?? [])
            console.debug(s.creationLocation.stack);
        console.groupEnd();
    } console.group("PendingTasks keeping application unstable:"); for (let s of t.values())
        console.debug(s.stack); console.groupEnd(); }, VM); o.whenStable().then(() => { clearTimeout(i); }); }); })]); }
var Vc = class {
    supports(t) { return oi(t); }
    create(t) { return new Mh(t); }
}, xP = (e, t) => t, Mh = class {
    length = 0;
    collection;
    _linkedRecords = null;
    _unlinkedRecords = null;
    _previousItHead = null;
    _itHead = null;
    _itTail = null;
    _additionsHead = null;
    _additionsTail = null;
    _movesHead = null;
    _movesTail = null;
    _removalsHead = null;
    _removalsTail = null;
    _identityChangesHead = null;
    _identityChangesTail = null;
    _trackByFn;
    constructor(t) { this._trackByFn = t || xP; }
    forEachItem(t) { let n; for (n = this._itHead; n !== null; n = n._next)
        t(n); }
    forEachOperation(t) { let n = this._itHead, o = this._removalsHead, r = 0, i = null; for (; n || o;) {
        let s = !o || n && n.currentIndex < HM(o, r, i) ? n : o, a = HM(s, r, i), c = s.currentIndex;
        if (s === o)
            r--, o = o._nextRemoved;
        else if (n = n._next, s.previousIndex == null)
            r++;
        else {
            i || (i = []);
            let l = a - r, u = c - r;
            if (l != u) {
                for (let f = 0; f < l; f++) {
                    let p = f < i.length ? i[f] : i[f] = 0, h = p + f;
                    u <= h && h < l && (i[f] = p + 1);
                }
                let d = s.previousIndex;
                i[d] = u - l;
            }
        }
        a !== c && t(s, a, c);
    } }
    forEachPreviousItem(t) { let n; for (n = this._previousItHead; n !== null; n = n._nextPrevious)
        t(n); }
    forEachAddedItem(t) { let n; for (n = this._additionsHead; n !== null; n = n._nextAdded)
        t(n); }
    forEachMovedItem(t) { let n; for (n = this._movesHead; n !== null; n = n._nextMoved)
        t(n); }
    forEachRemovedItem(t) { let n; for (n = this._removalsHead; n !== null; n = n._nextRemoved)
        t(n); }
    forEachIdentityChange(t) { let n; for (n = this._identityChangesHead; n !== null; n = n._nextIdentityChange)
        t(n); }
    diff(t) { if (t == null && (t = []), !oi(t))
        throw new D(900, !1); return this.check(t) ? this : null; }
    onDestroy() { }
    check(t) { this._reset(); let n = this._itHead, o = !1, r, i, s; if (Array.isArray(t)) {
        this.length = t.length;
        for (let a = 0; a < this.length; a++)
            i = t[a], s = this._trackByFn(a, i), n === null || !Object.is(n.trackById, s) ? (n = this._mismatch(n, i, s, a), o = !0) : (o && (n = this._verifyReinsertion(n, i, s, a)), Object.is(n.item, i) || this._addIdentityChange(n, i)), n = n._next;
    }
    else
        r = 0, $E(t, a => { s = this._trackByFn(r, a), n === null || !Object.is(n.trackById, s) ? (n = this._mismatch(n, a, s, r), o = !0) : (o && (n = this._verifyReinsertion(n, a, s, r)), Object.is(n.item, a) || this._addIdentityChange(n, a)), n = n._next, r++; }), this.length = r; return this._truncate(n), this.collection = t, this.isDirty; }
    get isDirty() { return this._additionsHead !== null || this._movesHead !== null || this._removalsHead !== null || this._identityChangesHead !== null; }
    _reset() { if (this.isDirty) {
        let t;
        for (t = this._previousItHead = this._itHead; t !== null; t = t._next)
            t._nextPrevious = t._next;
        for (t = this._additionsHead; t !== null; t = t._nextAdded)
            t.previousIndex = t.currentIndex;
        for (this._additionsHead = this._additionsTail = null, t = this._movesHead; t !== null; t = t._nextMoved)
            t.previousIndex = t.currentIndex;
        this._movesHead = this._movesTail = null, this._removalsHead = this._removalsTail = null, this._identityChangesHead = this._identityChangesTail = null;
    } }
    _mismatch(t, n, o, r) { let i; return t === null ? i = this._itTail : (i = t._prev, this._remove(t)), t = this._unlinkedRecords === null ? null : this._unlinkedRecords.get(o, null), t !== null ? (Object.is(t.item, n) || this._addIdentityChange(t, n), this._reinsertAfter(t, i, r)) : (t = this._linkedRecords === null ? null : this._linkedRecords.get(o, r), t !== null ? (Object.is(t.item, n) || this._addIdentityChange(t, n), this._moveAfter(t, i, r)) : t = this._addAfter(new wh(n, o), i, r)), t; }
    _verifyReinsertion(t, n, o, r) { let i = this._unlinkedRecords === null ? null : this._unlinkedRecords.get(o, null); return i !== null ? t = this._reinsertAfter(i, t._prev, r) : t.currentIndex != r && (t.currentIndex = r, this._addToMoves(t, r)), t; }
    _truncate(t) { for (; t !== null;) {
        let n = t._next;
        this._addToRemovals(this._unlink(t)), t = n;
    } this._unlinkedRecords !== null && this._unlinkedRecords.clear(), this._additionsTail !== null && (this._additionsTail._nextAdded = null), this._movesTail !== null && (this._movesTail._nextMoved = null), this._itTail !== null && (this._itTail._next = null), this._removalsTail !== null && (this._removalsTail._nextRemoved = null), this._identityChangesTail !== null && (this._identityChangesTail._nextIdentityChange = null); }
    _reinsertAfter(t, n, o) { this._unlinkedRecords !== null && this._unlinkedRecords.remove(t); let r = t._prevRemoved, i = t._nextRemoved; return r === null ? this._removalsHead = i : r._nextRemoved = i, i === null ? this._removalsTail = r : i._prevRemoved = r, this._insertAfter(t, n, o), this._addToMoves(t, o), t; }
    _moveAfter(t, n, o) { return this._unlink(t), this._insertAfter(t, n, o), this._addToMoves(t, o), t; }
    _addAfter(t, n, o) { return this._insertAfter(t, n, o), this._additionsTail === null ? this._additionsTail = this._additionsHead = t : this._additionsTail = this._additionsTail._nextAdded = t, t; }
    _insertAfter(t, n, o) { let r = n === null ? this._itHead : n._next; return t._next = r, t._prev = n, r === null ? this._itTail = t : r._prev = t, n === null ? this._itHead = t : n._next = t, this._linkedRecords === null && (this._linkedRecords = new Hc), this._linkedRecords.put(t), t.currentIndex = o, t; }
    _remove(t) { return this._addToRemovals(this._unlink(t)); }
    _unlink(t) { this._linkedRecords !== null && this._linkedRecords.remove(t); let n = t._prev, o = t._next; return n === null ? this._itHead = o : n._next = o, o === null ? this._itTail = n : o._prev = n, t; }
    _addToMoves(t, n) { return t.previousIndex === n || (this._movesTail === null ? this._movesTail = this._movesHead = t : this._movesTail = this._movesTail._nextMoved = t), t; }
    _addToRemovals(t) { return this._unlinkedRecords === null && (this._unlinkedRecords = new Hc), this._unlinkedRecords.put(t), t.currentIndex = null, t._nextRemoved = null, this._removalsTail === null ? (this._removalsTail = this._removalsHead = t, t._prevRemoved = null) : (t._prevRemoved = this._removalsTail, this._removalsTail = this._removalsTail._nextRemoved = t), t; }
    _addIdentityChange(t, n) { return t.item = n, this._identityChangesTail === null ? this._identityChangesTail = this._identityChangesHead = t : this._identityChangesTail = this._identityChangesTail._nextIdentityChange = t, t; }
}, wh = class {
    item;
    trackById;
    currentIndex = null;
    previousIndex = null;
    _nextPrevious = null;
    _prev = null;
    _next = null;
    _prevDup = null;
    _nextDup = null;
    _prevRemoved = null;
    _nextRemoved = null;
    _nextAdded = null;
    _nextMoved = null;
    _nextIdentityChange = null;
    constructor(t, n) { this.item = t, this.trackById = n; }
}, Nh = class {
    _head = null;
    _tail = null;
    add(t) { this._head === null ? (this._head = this._tail = t, t._nextDup = null, t._prevDup = null) : (this._tail._nextDup = t, t._prevDup = this._tail, t._nextDup = null, this._tail = t); }
    get(t, n) { let o; for (o = this._head; o !== null; o = o._nextDup)
        if ((n === null || n <= o.currentIndex) && Object.is(o.trackById, t))
            return o; return null; }
    remove(t) { let n = t._prevDup, o = t._nextDup; return n === null ? this._head = o : n._nextDup = o, o === null ? this._tail = n : o._prevDup = n, this._head === null; }
}, Hc = class {
    map = new Map;
    put(t) { let n = t.trackById, o = this.map.get(n); o || (o = new Nh, this.map.set(n, o)), o.add(t); }
    get(t, n) { let o = t, r = this.map.get(o); return r ? r.get(t, n) : null; }
    remove(t) { let n = t.trackById; return this.map.get(n).remove(t) && this.map.delete(n), t; }
    get isEmpty() { return this.map.size === 0; }
    clear() { this.map.clear(); }
};
function HM(e, t, n) { let o = e.previousIndex; if (o === null)
    return o; let r = 0; return n && o < n.length && (r = n[o]), o + t + r; }
var Bc = class {
    supports(t) { return t instanceof Map || fc(t); }
    create() { return new _h; }
}, _h = class {
    _records = new Map;
    _mapHead = null;
    _appendAfter = null;
    _previousMapHead = null;
    _changesHead = null;
    _changesTail = null;
    _additionsHead = null;
    _additionsTail = null;
    _removalsHead = null;
    get isDirty() { return this._additionsHead !== null || this._changesHead !== null || this._removalsHead !== null; }
    forEachItem(t) { let n; for (n = this._mapHead; n !== null; n = n._next)
        t(n); }
    forEachPreviousItem(t) { let n; for (n = this._previousMapHead; n !== null; n = n._nextPrevious)
        t(n); }
    forEachChangedItem(t) { let n; for (n = this._changesHead; n !== null; n = n._nextChanged)
        t(n); }
    forEachAddedItem(t) { let n; for (n = this._additionsHead; n !== null; n = n._nextAdded)
        t(n); }
    forEachRemovedItem(t) { let n; for (n = this._removalsHead; n !== null; n = n._nextRemoved)
        t(n); }
    diff(t) { if (!t)
        t = new Map;
    else if (!(t instanceof Map || fc(t)))
        throw new D(900, !1); return this.check(t) ? this : null; }
    check(t) { this._reset(); let n = this._mapHead; if (this._appendAfter = null, this._forEach(t, (o, r) => { if (n && n.key === r)
        this._maybeAddToChanges(n, o), this._appendAfter = n, n = n._next;
    else {
        let i = this._getOrCreateRecordForKey(r, o);
        n = this._insertBeforeOrAppend(n, i);
    } }), n) {
        n._prev && (n._prev._next = null), this._removalsHead = n;
        for (let o = n; o !== null; o = o._nextRemoved)
            o === this._mapHead && (this._mapHead = null), this._records.delete(o.key), o._nextRemoved = o._next, o.previousValue = o.currentValue, o.currentValue = null, o._prev = null, o._next = null;
    } return this._changesTail && (this._changesTail._nextChanged = null), this._additionsTail && (this._additionsTail._nextAdded = null), this.isDirty; }
    _insertBeforeOrAppend(t, n) { if (t) {
        let o = t._prev;
        return n._next = t, n._prev = o, t._prev = n, o && (o._next = n), t === this._mapHead && (this._mapHead = n), this._appendAfter = t, t;
    } return this._appendAfter ? (this._appendAfter._next = n, n._prev = this._appendAfter) : this._mapHead = n, this._appendAfter = n, null; }
    _getOrCreateRecordForKey(t, n) { if (this._records.has(t)) {
        let r = this._records.get(t);
        this._maybeAddToChanges(r, n);
        let i = r._prev, s = r._next;
        return i && (i._next = s), s && (s._prev = i), r._next = null, r._prev = null, r;
    } let o = new Sh(t); return this._records.set(t, o), o.currentValue = n, this._addToAdditions(o), o; }
    _reset() { if (this.isDirty) {
        let t;
        for (this._previousMapHead = this._mapHead, t = this._previousMapHead; t !== null; t = t._next)
            t._nextPrevious = t._next;
        for (t = this._changesHead; t !== null; t = t._nextChanged)
            t.previousValue = t.currentValue;
        for (t = this._additionsHead; t != null; t = t._nextAdded)
            t.previousValue = t.currentValue;
        this._changesHead = this._changesTail = null, this._additionsHead = this._additionsTail = null, this._removalsHead = null;
    } }
    _maybeAddToChanges(t, n) { Object.is(n, t.currentValue) || (t.previousValue = t.currentValue, t.currentValue = n, this._addToChanges(t)); }
    _addToAdditions(t) { this._additionsHead === null ? this._additionsHead = this._additionsTail = t : (this._additionsTail._nextAdded = t, this._additionsTail = t); }
    _addToChanges(t) { this._changesHead === null ? this._changesHead = this._changesTail = t : (this._changesTail._nextChanged = t, this._changesTail = t); }
    _forEach(t, n) { t instanceof Map ? t.forEach(n) : Object.keys(t).forEach(o => n(t[o], o)); }
}, Sh = class {
    key;
    previousValue = null;
    currentValue = null;
    _nextPrevious = null;
    _next = null;
    _prev = null;
    _nextAdded = null;
    _nextRemoved = null;
    _nextChanged = null;
    constructor(t) { this.key = t; }
};
function BM() { return new JM([new Vc]); }
var JM = (() => { class e {
    factories;
    static \u0275prov = Y({ token: e, providedIn: "root", factory: BM });
    constructor(n) { this.factories = n; }
    static create(n, o) { if (o != null) {
        let r = o.factories.slice();
        n = n.concat(r);
    } return new e(n); }
    static extend(n) { return { provide: e, useFactory: () => { let o = E(e, { optional: !0, skipSelf: !0 }); return e.create(n, o || BM()); } }; }
    find(n) { let o = this.factories.find(r => r.supports(n)); if (o != null)
        return o; throw new D(901, !1); }
} return e; })();
function $M() { return new XM([new Bc]); }
var XM = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: $M });
    factories;
    constructor(n) { this.factories = n; }
    static create(n, o) { if (o) {
        let r = o.factories.slice();
        n = n.concat(r);
    } return new e(n); }
    static extend(n) { return { provide: e, useFactory: () => { let o = E(e, { optional: !0, skipSelf: !0 }); return e.create(n, o || $M()); } }; }
    find(n) { let o = this.factories.find(r => r.supports(n)); if (o)
        return o; throw new D(901, !1); }
} return e; })(), kP = (() => { class e {
    static __NG_ELEMENT_ID__ = OP;
} return e; })();
function OP(e) { return LP(_(), g(), (e & 16) === 16); }
function LP(e, t, n) { if (Ce(e) && !n) {
    let o = me(e.index, t);
    return new sn(o, o);
}
else if (e.type & 175) {
    let o = t[re];
    return new sn(o, t);
} return null; }
var PP = [new Bc], FP = [new Vc], x0 = new JM(FP), k0 = new XM(PP);
function O0(e) { return Pe([]); }
var jP = (() => { class e {
    zone = E(G);
    changeDetectionScheduler = E(qe);
    applicationRef = E(He);
    applicationErrorHandler = E(_t);
    _onMicrotaskEmptySubscription;
    initialize() { this._onMicrotaskEmptySubscription || (this._onMicrotaskEmptySubscription = this.zone.onMicrotaskEmpty.subscribe({ next: () => { this.changeDetectionScheduler.runningTick || this.zone.run(() => { try {
            this.applicationRef.dirtyFlags |= 1, this.applicationRef._tick();
        }
        catch (n) {
            this.applicationErrorHandler(n);
        } }); } })); }
    ngOnDestroy() { this._onMicrotaskEmptySubscription?.unsubscribe(); }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Lt({ token: e, factory: e.\u0275fac });
} return e; })(), VP = new C("", { factory: () => !1 });
function HP({ ngZoneFactory: e, scheduleInRootZone: t }) { return e ??= () => new G(Ie(q({}, ew()), { scheduleInRootZone: t })), [{ provide: so, useValue: !1 }, { provide: G, useFactory: e }, { provide: We, multi: !0, useFactory: () => { let n = E(jP, { optional: !0 }); return () => n.initialize(); } }, { provide: We, multi: !0, useFactory: () => { let n = E(BP); return () => { n.initialize(); }; } }, { provide: Ms, useValue: t ?? tu }]; }
function L0(e) { let t = e?.scheduleInRootZone, n = HP({ ngZoneFactory: () => { let o = ew(e); return o.scheduleInRootZone = t, o.shouldCoalesceEventChangeDetection && te("NgZone_CoalesceEvent"), new G(o); }, scheduleInRootZone: t }); return Pe([{ provide: VP, useValue: !0 }, n]); }
function ew(e) { return { enableLongStackTrace: !1, shouldCoalesceEventChangeDetection: e?.eventCoalescing ?? !1, shouldCoalesceRunChangeDetection: e?.runCoalescing ?? !1 }; }
var BP = (() => { class e {
    subscription = new hP;
    initialized = !1;
    zone = E(G);
    pendingTasks = E(gt);
    initialize() { if (this.initialized)
        return; this.initialized = !0; let n = null; !this.zone.isStable && !this.zone.hasPendingMacrotasks && !this.zone.hasPendingMicrotasks && (n = this.pendingTasks.add()), this.zone.runOutsideAngular(() => { this.subscription.add(this.zone.onStable.subscribe(() => { G.assertNotInAngularZone(), queueMicrotask(() => { n !== null && !this.zone.hasPendingMacrotasks && !this.zone.hasPendingMicrotasks && (this.pendingTasks.remove(n), n = null); }); })); }), this.subscription.add(this.zone.onUnstable.subscribe(() => { G.assertInAngularZone(), n ??= this.pendingTasks.add(); })); }
    ngOnDestroy() { this.subscription.unsubscribe(); }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Lt({ token: e, factory: e.\u0275fac });
} return e; })();
function $P(e, t, n) { let o = new _o(n); return Promise.resolve(o); }
function UM(e) { for (let t = e.length - 1; t >= 0; t--)
    if (e[t] !== void 0)
        return e[t]; }
var $c = new C(""), UP = new C("");
function $i(e) { return !e.moduleRef; }
function tw(e) { let t = $i(e) ? e.r3Injector : e.moduleRef.injector, n = t.get(G); return n.run(() => { $i(e) ? e.r3Injector.resolveInjectorInitializers() : e.moduleRef.resolveInjectorInitializers(); let o = t.get(_t), r; if (n.runOutsideAngular(() => { r = n.onError.subscribe({ next: o }); }), $i(e)) {
    let i = () => t.destroy(), s = e.platformInjector.get($c);
    s.add(i), t.onDestroy(() => { r.unsubscribe(), s.delete(i); });
}
else {
    let i = () => e.moduleRef.destroy(), s = e.platformInjector.get($c);
    s.add(i), e.moduleRef.onDestroy(() => { jr(e.allPlatformModules, e.moduleRef), r.unsubscribe(), s.delete(i); });
} return GP(o, n, () => { let i = t.get(gt), s = i.add(), a = t.get(ap); return a.runInitializers(), a.donePromise.then(() => { let c = t.get(ah, Pi); if (WD(c || Pi), !t.get(UP, !0))
    return $i(e) ? t.get(He) : (e.allPlatformModules.push(e.moduleRef), e.moduleRef); if ($i(e)) {
    let u = t.get(He);
    return e.rootComponent !== void 0 && u.bootstrap(e.rootComponent), u;
}
else
    return nw?.(e.moduleRef, e.allPlatformModules), e.moduleRef; }).finally(() => { i.remove(s); }); }); }); }
var nw;
function qM() { nw = qP; }
function qP(e, t) { let n = e.injector.get(He); if (e._bootstrapComponents.length > 0)
    e._bootstrapComponents.forEach(o => n.bootstrap(o));
else if (e.instance.ngDoBootstrap)
    e.instance.ngDoBootstrap(n);
else
    throw new D(-403, !1); t.push(e); }
function GP(e, t, n) { try {
    let o = n();
    return np(o) ? o.catch(r => { throw t.runOutsideAngular(() => e(r)), r; }) : o;
}
catch (o) {
    throw t.runOutsideAngular(() => e(o)), o;
} }
var ow = (() => { class e {
    _injector;
    _modules = [];
    _destroyListeners = [];
    _destroyed = !1;
    constructor(n) { this._injector = n; }
    bootstrapModuleFactory(n, o) { let r = [Nc(), ...o?.applicationProviders ?? [], su], i = yI(n.moduleType, this.injector, r); return qM(), tw({ moduleRef: i, allPlatformModules: this._modules, platformInjector: this.injector }); }
    bootstrapModule(n, o = []) { let r = yp({}, o); return qM(), $P(this.injector, r, n).then(i => this.bootstrapModuleFactory(i, r)); }
    onDestroy(n) { this._destroyListeners.push(n); }
    get injector() { return this._injector; }
    destroy() { if (this._destroyed)
        throw new D(404, !1); this._modules.slice().forEach(o => o.destroy()), this._destroyListeners.forEach(o => o()); let n = this._injector.get($c, null); n && (n.forEach(o => o()), n.clear()), this._destroyed = !0; }
    get destroyed() { return this._destroyed; }
    static \u0275fac = function (o) { return new (o || e)(he(oe)); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac, providedIn: "platform" });
} return e; })();
function rw(e) { let t = KI(e); if (t?.type === "null")
    return { name: "Null Injector", type: "null", providers: [], children: [] }; let n = []; if ((t?.type === "element" || t?.type === "environment") && (n = YI(e).map(o => ({ token: o.token, value: e.get(o.token, null, { optional: !0, self: !0 }) }))), t?.type === "element") {
    let o = pi(e), r = o ? o.providerIndexes >> 20 : 0, i = n.slice(0, r), s = n.slice(r);
    return { name: e.constructor.name, type: "element", providers: s, viewProviders: i, children: [], hostElement: t.source };
} return { name: t?.source ?? e.constructor.name ?? "Unknown Injector", type: "environment", providers: n, children: [] }; }
var P0 = { name: "angular:di_graph", description: "\nExposes the Angular Dependency Injection (DI) graph of the application.\n\nThis tool extracts both the element injector tree (associated with DOM elements and components)\nand the environment injector tree (associated with modules and standalone application roots).\nIt captures the relationship structure and the providers resolved at each level.\n\nReturns:\n- `elementInjectorRoots`: An array of root element injectors (one for each Angular application\n  root found). Each node forms a tree hierarchy:\n  - `name`: The constructor name of this injector.\n  - `type`: 'element'.\n  - `providers`: Array of providers configured on this injector.\n    - `token`: The DI token.\n    - `value`: The resolved value of that provider if it was instantiated.\n  - `hostElement`: The DOM element that this injector is associated with.\n  - `children`: Array of child element injectors.\n- `environmentInjectorRoot`: The root environment injector. It forms a tree hierarchy of nodes\n  representing all environment injectors:\n  - `name`: The identifier for the environment injector.\n  - `type`: 'environment' or 'null'.\n  - `providers`: Array of providers configured on this injector.\n    - `token`: The DI token.\n    - `value`: The resolved value of that provider if it was instantiated.\n  - `children`: Array of child environment injectors.\n  ".trim(), inputSchema: { type: "object", properties: {} }, execute: () => Se(null, null, function* () { let e = Array.from(document.querySelectorAll("[ng-version]")); if (e.length === 0)
        throw new Error("Could not find Angular root element ([ng-version]) on the page."); return WP(e); }) };
function WP(e) { let t = e.map(n => { let o = we(n); if (!o?.lView)
    throw new Error(`Could not find an \`LView\` for root \`<${n.tagName.toLowerCase()}>\`, is it an Angular component?`); return o.lView; }); return { elementInjectorRoots: t.map(n => zP(n)), environmentInjectorRoot: QP(t) }; }
function zP(e) { if (e[m].type !== 0)
    throw new Error(`Expected a root LView but got type: \`${e[m].type}\`.`); let t = []; for (let [o, r] of Gd(e)) {
    let i = new Me(o, r), s = rw(i);
    for (; t.length > 0;) {
        let [a, c, l] = t[t.length - 1], u = iw(o, a), d = ZP(r, c, a);
        if (u || d) {
            l.children.push(s);
            break;
        }
        else
            t.pop();
    }
    t.push([o, r, s]);
} if (t.length === 0)
    throw new Error("Expected at least one component/directive in the root `LView`."); let [, , n] = t[0]; return n; }
function QP(e) { let t = new Map, n; function o(r) { let i = t.get(r); if (i)
    return i; let s = rw(r); t.set(r, s); let a = YP(r); if (a)
    o(a).children.push(s);
else if (!n)
    n = s;
else if (n !== s)
    throw new Error("Expected only one root environment injector, but found multiple.", { cause: { firstRoot: n, secondRoot: s } }); return s; } for (let r of e)
    for (let [, i] of Gd(r))
        o(i[k]); if (!n)
    throw new Error("Expected a root environment injector but did not find one."); return n; }
function iw(e, t) { let n = e; for (; n;) {
    if (n === t)
        return !0;
    n = n.parent;
} return !1; }
function ZP(e, t, n) { let o = e, r = null; for (; o && o !== t;)
    r = o[ce], o = Ue(o); return o === t && r !== null && iw(r, n); }
function YP(e) { if (e instanceof nn)
    return e.parentInjector; if (e instanceof et)
    return e.parent; if (e instanceof Ct)
    return; throw new Error(`Unknown injector type: "${e.constructor.name}".`); }
var F0 = { name: "angular:signal_graph", description: "\nExposes the Angular signal dependency graph for a given DOM element.\n\nThis tool extracts the reactive dependency graph (signals, computeds, and effects) that\nare transitive dependencies of the effects of that element. It will include signals\nauthored in other components/services and depended upon by the target component, but\nwill *not* include signals only used in descendant components effects.\n\nParams:\n- `target`: The element to get the signal graph for. Must be the host element of an\n  Angular component.\n\nReturns:\n- `nodes`: An array of reactive nodes discovered in the context. Each node contains:\n  - `kind`: The type of reactive node ('signal', 'computed', 'effect', or 'template'\n    for component template effects).\n  - `value`: The current evaluated value of the node (if applicable).\n  - `label`: The symbol name of the associated signal if available (ex.\n    `const foo = signal(0);` has `label: 'foo'`).\n  - `epoch`: The internal version number of the node's value.\n- `edges`: An array of dependency links representing which nodes read from which other\n  nodes.\n  - `consumer`: The index in the `nodes` array of the node that depends on the value.\n  - `producer`: The index in the `nodes` array of the node that provides the value.\n\nExample: An edge with `{consumer: 2, producer: 0}` means that `nodes[2]` (e.g. an\n`effect`) reads the value of `nodes[0]` (e.g. a `signal`).\n  ".trim(), inputSchema: { type: "object", properties: { target: { type: "object", description: "The element to get the signal graph for.", "x-mcp-type": "HTMLElement" } }, required: ["target"] }, execute: t => Se(null, [t], function* ({ target: e }) { if (!(e instanceof HTMLElement))
        throw new Error('Invalid input: "target" must be an HTMLElement.'); let n = Wd(e); if (n instanceof Ct)
        throw new Error('Invalid input: "target" is not the host element of an Angular component.'); let o = XI(n); return { nodes: o.nodes.map(a => { var c = a, { id: r, debuggableFn: i } = c, s = Lh(c, ["id", "debuggableFn"]); return s; }), edges: o.edges }; }) };
var Qo = null;
function KP(e) { if (Gc())
    throw new D(400, !1); vp(), Qo = typeof ngServerMode > "u" || !ngServerMode ? e : null; let t = e.get(ow); return aw(e), t; }
function JP(e, t, n = []) { let o = `Platform: ${t}`, r = new C(o); return (i = []) => { let s = Gc(); if (!s) {
    let a = [...n, ...i, { provide: r, useValue: !0 }];
    s = e?.(a) ?? KP(sw(a, o));
} return typeof ngServerMode < "u" && ngServerMode ? s : XP(r); }; }
function sw(e = [], t) { return oe.create({ name: t, providers: [{ provide: Tl, useValue: "platform" }, { provide: $c, useValue: new Set([() => Qo = null]) }, ...e] }); }
function XP(e) { let t = Gc(); if (!t)
    throw new D(-401, !1); return t; }
function Gc() { return typeof ngServerMode < "u" && ngServerMode ? null : Qo?.get(ow) ?? null; }
function j0() { Gc()?.destroy(); }
function eF(e = []) { if (Qo)
    return Qo; let t = sw(e); return (typeof ngServerMode > "u" || !ngServerMode) && (Qo = t), vp(), aw(t), t; }
function V0(e) { return { provide: au, useValue: e, multi: !0 }; }
function aw(e) { let t = e.get(au, null); Er(e, () => { t?.forEach(n => n()); }); }
function H0(e) { let { rootComponent: t, appProviders: n, platformProviders: o, platformRef: r } = e; if (H(L.BootstrapApplicationStart), typeof ngServerMode < "u" && ngServerMode && !r)
    throw new D(-401, !1); try {
    let i = r?.injector ?? eF(o), s = [Nc(), su, ...n || []], a = new ri({ providers: s, parent: i, debugName: "", runEnvironmentInitializers: !1 });
    return tw({ r3Injector: a.injector, platformInjector: i, rootComponent: t });
}
catch (i) {
    return Promise.reject(i);
}
finally {
    H(L.BootstrapApplicationEnd);
} }
var bh = class {
    views = [];
    indexByContent = new Map;
    add(t) { let n = JSON.stringify(t); if (!this.indexByContent.has(n)) {
        let o = this.views.length;
        return this.views.push(t), this.indexByContent.set(n, o), o;
    } return this.indexByContent.get(n); }
    getAll() { return this.views; }
}, tF = 0;
function cw(e) { return e.ssrId || (e.ssrId = `t${tF++}`), e.ssrId; }
function lw(e, t, n) { let o = []; return Mo(e, t, n, o), o.length; }
function nF(e) { let t = []; return rc(e, t), t.length; }
function uw(e, t) { let n = e[B]; return n && !n.hasAttribute(jn) ? Uc(n, e, null, t) : null; }
function dw(e, t) { let n = Tr(e[B]), o = uw(n, t); if (o === null)
    return; let r = O(n[B]), i = e[z], s = Uc(r, i, null, t), a = n[N], c = `${o}|${s}`; a.setAttribute(r, yo, c); }
function B0(e, t) { let n = e.injector, o = bE(n), r = Ci(n), i = new bh, s = new Map, a = e._views, c = n.get(ka, Jd), l = { regular: new Set, capture: new Set }, u = new Map; e.injector.get(vt); for (let p of a) {
    let h = sf(p);
    if (h !== null) {
        let v = { serializedViewCollection: i, corruptedTextNodes: s, isI18nHydrationEnabled: o, isIncrementalHydrationEnabled: r, i18nChildren: new Map, eventTypesToReplay: l, shouldReplayEvents: c, deferBlocks: u };
        K(h) ? dw(h, v) : uw(h, v), aF(s, t);
    }
} let d = i.getAll(), f = n.get(St); if (f.set(Oa, d), u.size > 0) {
    let p = {};
    for (let [h, v] of u.entries())
        p[h] = v;
    f.set(La, p);
} return l; }
function oF(e, t, n, o, r) { let i = [], s = ""; for (let a = U; a < e.length; a++) {
    let c = e[a], l, u, d;
    if (rt(c) && (c = c[I], K(c))) {
        u = nF(c) + 1, dw(c, r);
        let p = Tr(c[B]);
        d = { [Aa]: p[m].ssrId, [xt]: u };
    }
    if (!d) {
        let p = c[m];
        p.type === 1 ? (l = p.ssrId, u = 1) : (l = cw(p), u = lw(p, c, p.firstChild)), d = { [Aa]: l, [xt]: u };
        let h = !1;
        if (UI(n[m], t)) {
            let v = Ne(n, t), y = pe(n[m], t);
            if (r.isIncrementalHydrationEnabled && y.hydrateTriggers !== null) {
                let T = `d${r.deferBlocks.size}`;
                y.hydrateTriggers.has(7) && (h = !0);
                let R = [];
                rc(e, R);
                let se = { [xt]: R.length, [Ii]: v[Vt] }, Xe = rF(y.hydrateTriggers);
                Xe.length > 0 && (se[Di] = Xe), o !== null && (se[Zd] = o), r.deferBlocks.set(T, se);
                let Be = O(e);
                Be !== void 0 ? Be.nodeType === Node.COMMENT_NODE && GM(Be, T) : GM(Be, T), h || lF(y, R, T, r), o = T, d[xa] = T;
            }
            d[Ii] = v[Vt];
        }
        if (!h) {
            let v = O(c[B]);
            (c[m].type !== 1 || v === null || !v.hasAttribute(jn)) && Object.assign(d, fw(e[a], o, r));
        }
    }
    let f = JSON.stringify(d);
    if (i.length > 0 && f === s) {
        let p = i[i.length - 1];
        p[yi] ??= 1, p[yi]++;
    }
    else
        s = f, i.push(d);
} return i; }
function rF(e) { let t = new Set([0, 1, 2, 5]), n = []; for (let [o, r] of e)
    t.has(o) && (r === null ? n.push(o) : r.type === 5 ? n.push({ trigger: o, delay: r.delay }) : n.push({ trigger: o, intersectionObserverOptions: r.intersectionObserverOptions })); return n; }
function Ui(e, t, n, o) { let r = t.index - I; e[Ei] ??= {}, e[Ei][r] ??= wE(t, n, o); }
function Dh(e, t) { let n = typeof t == "number" ? t : t.index - I; e[Lo] ??= [], e[Lo].includes(n) || e[Lo].push(n); }
function fw(e, t = null, n) { let o = {}, r = e[m], i = AE(r, n), s = n.shouldReplayEvents ? MP(r, e, n.eventTypesToReplay) : null; for (let a = I; a < r.bindingStartIndex; a++) {
    let c = r.data[a], l = a - I, u = RE(e, a, n);
    if (u) {
        o[Ra] ??= {}, o[Ra][l] = u.caseQueue;
        for (let d of u.disconnectedNodes)
            Dh(o, d);
        for (let d of u.disjointNodes) {
            let f = r.data[d + I];
            Ui(o, f, e, i);
        }
        continue;
    }
    if (Ma(c) && !Fo(c)) {
        if (K(e[a]) && c.tView && (o[ba] ??= {}, o[ba][l] = cw(c.tView)), Uo(c, e) && cF(c)) {
            Dh(o, c);
            continue;
        }
        if (Array.isArray(c.projection)) {
            for (let d of c.projection)
                if (d)
                    if (!Array.isArray(d))
                        !_l(d) && !ko(d) && (Uo(d, e) ? Dh(o, d) : Ui(o, d, e, i));
                    else
                        throw mE(O(e[a]));
        }
        if (iF(o, c, e, i), K(e[a])) {
            let d = e[a][B];
            if (Array.isArray(d)) {
                let f = O(d);
                f.hasAttribute(jn) || Uc(f, d, t, n);
            }
            o[Oo] ??= {}, o[Oo][l] = oF(e[a], c, e, t, n);
        }
        else if (Array.isArray(e[a]) && !rv(c)) {
            let d = O(e[a][B]);
            d.hasAttribute(jn) || Uc(d, e[a], t, n);
        }
        else if (c.type & 8)
            o[vi] ??= {}, o[vi][l] = lw(r, e, c.child);
        else if (c.type & 144) {
            let d = c.next;
            for (; d !== null && d.type & 144;)
                d = d.next;
            d && !ko(d) && Ui(o, d, e, i);
        }
        else if (c.type & 1) {
            let d = O(e[a]);
            cf(n, d);
        }
        if (s && c.type & 2) {
            let d = O(e[a]);
            s.has(d) && ef(d, s.get(d), t);
        }
    }
} return o; }
function iF(e, t, n, o) { _l(t) || (t.projectionNext && t.projectionNext !== t.next && !ko(t.projectionNext) && Ui(e, t.projectionNext, n, o), t.prev === null && t.parent !== null && Uo(t.parent, n) && !Uo(t, n) && Ui(e, t, n, o)); }
function sF(e) { let t = e[j]; if (!t?.constructor)
    return !1; let n = W(t.constructor); return n?.encapsulation === Ke.ShadowDom || n?.encapsulation === Ke.ExperimentalIsolatedShadowDom; }
function Uc(e, t, n, o) { let r = t[N]; if (og(t) && !lc() || sF(t))
    return r.setAttribute(e, jn, ""), null; {
    let i = fw(t, n, o), s = o.serializedViewCollection.add(i);
    return r.setAttribute(e, yo, s.toString()), s;
} }
function GM(e, t) { e.textContent = `ngh=${t}`; }
function aF(e, t) { for (let [n, o] of e)
    n.after(t.createComment(o)); }
function cF(e) { let t = e; for (; t != null;) {
    if (Ce(t))
        return !0;
    t = t.parent;
} return !1; }
function lF(e, t, n, o) { let r = oy(e.hydrateTriggers); for (let i of r)
    o.eventTypesToReplay.regular.add(i); if (r.length > 0) {
    let i = t.filter(s => s.nodeType === Node.ELEMENT_NODE);
    for (let s of i)
        ef(s, r, n);
} }
function $0(e) { let t = g(); for (; t;) {
    if (t[m].type === 1 && e(t[j]))
        return t[j];
    if (rt(t))
        break;
    t = Ue(t);
} return null; }
var uF = "\u{1F170}\uFE0F", Wc = !1;
function U0(e) { if (!Wc)
    return; let { startLabel: t } = pw(e); performance.mark(t); }
function q0(e) { if (!Wc)
    return; let { startLabel: t, labelName: n, endLabel: o } = pw(e); performance.mark(o), performance.measure(n, t, o), performance.clearMarks(t), performance.clearMarks(o); }
function pw(e) { let t = `${uF}:${e}`; return { labelName: t, startLabel: `start:${t}`, endLabel: `end:${t}` }; }
var WM = !1;
function G0() { if (!WM && (typeof performance > "u" || !performance.mark || !performance.measure)) {
    WM = !0, console.warn("Performance API is not supported on this platform");
    return;
} Wc = !0; }
function W0() { Wc = !1; }
function z0(e) { }
function Q0(e) { return typeof e == "boolean" ? e : e != null && e !== "false"; }
function Z0(e, t = NaN) { return !isNaN(parseFloat(e)) && !isNaN(Number(e)) ? Number(e) : t; }
var Th = Symbol("NOT_SET"), hw = new Set, dF = Ie(q({}, Yc), { kind: "afterRenderEffectPhase", consumerIsAlwaysLive: !0, consumerAllowSignalWrites: !0, value: Th, cleanup: null, consumerMarkedDirty() { if (this.sequence.impl.executing) {
        if (this.sequence.lastPhase === null || this.sequence.lastPhase < this.phase)
            return;
        this.sequence.erroredOrDestroyed = !0;
    } this.sequence.scheduler.notify(7); }, phaseFn(e) { if (this.sequence.lastPhase = this.phase, !this.dirty)
        return this.signal; if (this.dirty = !1, this.value !== Th && !Qi(this))
        return this.signal; try {
        for (let r of this.cleanup ?? hw)
            r();
    }
    finally {
        this.cleanup?.clear();
    } let t = []; e !== void 0 && t.push(e), t.push(this.registerCleanupFn); let n = Yo(this), o; try {
        o = this.userFn.apply(null, t);
    }
    finally {
        zi(this, n);
    } return (this.value === Th || !this.equal(this.value, o)) && (this.value = o, this.version++), this.signal; } }), Ah = class extends Kr {
    scheduler;
    lastPhase = null;
    nodes = [void 0, void 0, void 0, void 0];
    onDestroyFns = null;
    constructor(t, n, o, r, i, s = null) { super(t, [void 0, void 0, void 0, void 0], o, !1, i.get(Re), s), this.scheduler = r; for (let a of Mf) {
        let c = n[a];
        if (c === void 0)
            continue;
        let l = Object.create(dF);
        l.sequence = this, l.phase = a, l.userFn = c, l.dirty = !0, l.signal = () => (Wi(l), l.value), l.signal[ae] = l, l.registerCleanupFn = u => (l.cleanup ??= new Set).add(u), this.nodes[a] = l, this.hooks[a] = u => l.phaseFn(u);
    } }
    afterRun() { super.afterRun(), this.lastPhase = null; }
    destroy() { if (this.onDestroyFns !== null)
        for (let t of this.onDestroyFns)
            t(); super.destroy(); for (let t of this.nodes)
        if (t)
            try {
                for (let n of t.cleanup ?? hw)
                    n();
            }
            finally {
                $t(t);
            } }
};
function Y0(e, t) { if (typeof ngServerMode < "u" && ngServerMode)
    return Wa; let n = t?.injector ?? E(oe), o = n.get(qe), r = n.get(Ga), i = n.get(Bn, null, { optional: !0 }); r.impl ??= n.get(wf); let s = e; typeof s == "function" && (s = { mixedReadWrite: e }); let a = n.get(io, null, { optional: !0 }), c = new Ah(r.impl, [s.earlyRead, s.write, s.mixedReadWrite, s.read], a?.view, o, n, i?.snapshot(null)); return r.impl.register(c), c; }
function K0(e) { return ee({ usage: 1, kind: "directive", type: e.type }).compileDirectiveDeclaration(Ee, `ng:///${e.type.name}/\u0275fac.js`, e); }
function J0(e) { ip(e.type, e.decorators, e.ctorParameters ?? null, e.propDecorators ?? null); }
function X0(e) { NI(e.type, e.resolveDeferredDeps, (...t) => { let n = e.resolveMetadata(...t); ip(e.type, n.decorators, n.ctorParameters, n.propDecorators); }); }
function ej(e) { return ee({ usage: 1, kind: "component", type: e.type }).compileComponentDeclaration(Ee, `ng:///${e.type.name}/\u0275cmp.js`, e); }
function tj(e) { return ee({ usage: 1, kind: fF(e.target), type: e.type }).compileFactoryDeclaration(Ee, `ng:///${e.type.name}/\u0275fac.js`, e); }
function fF(e) { switch (e) {
    case Wn.Directive: return "directive";
    case Wn.Component: return "component";
    case Wn.Injectable: return "injectable";
    case Wn.Pipe: return "pipe";
    case Wn.NgModule: return "NgModule";
    case Wn.Service: return "service";
} }
function nj(e) { return ee({ usage: 1, kind: "injectable", type: e.type }).compileInjectableDeclaration(Ee, `ng:///${e.type.name}/\u0275prov.js`, e); }
function oj(e) { return ee({ usage: 1, kind: "NgModule", type: e.type }).compileInjectorDeclaration(Ee, `ng:///${e.type.name}/\u0275inj.js`, e); }
function rj(e) { return ee({ usage: 1, kind: "NgModule", type: e.type }).compileNgModuleDeclaration(Ee, `ng:///${e.type.name}/\u0275mod.js`, e); }
function ij(e) { return ee({ usage: 1, kind: "pipe", type: e.type }).compilePipeDeclaration(Ee, `ng:///${e.type.name}/\u0275pipe.js`, e); }
function sj(e) { return ee({ usage: 1, kind: "service", type: e.type }).compileServiceDeclaration(Ee, `ng:///${e.type.name}/\u0275prov.js`, e); }
function aj(e) { let t = lp(e); if (!t)
    throw gw(e); return new _o(t); }
function cj(e) { let t = lp(e); if (!t)
    throw gw(e); return t; }
function gw(e) { return new D(920, !1); }
var Rh = class extends kP {
}, zM = class extends Rh {
}, lj = JP(null, "core", []);
function uj(e, t) { let n = W(e), o = t.elementInjector || Jn(); return new xn(n).create(o, t.projectableNodes, t.hostElement, t.environmentInjector, t.directives, t.bindings); }
function dj(e) { let t = W(e); if (!t)
    return null; let n = new xn(t); return { get selector() { return n.selector; }, get type() { return n.componentType; }, get inputs() { return n.inputs; }, get outputs() { return n.outputs; }, get ngContentSelectors() { return n.ngContentSelectors; }, get isStandalone() { return t.standalone; }, get isSignal() { return t.signals; } }; }
function pF(e) { return new xh(ao(e) ? e : ke(e)); }
var xh = class {
    snapshot;
    constructor(t) { this.snapshot = t; }
    get state() { return this.snapshot(); }
    value = ke(() => { if (this.state.status === "error")
        throw new Hi(this.state.error); return this.state.value; });
    status = ke(() => this.state.status);
    error = ke(() => this.state.status === "error" ? this.state.error : void 0);
    isLoading = ke(() => this.state.status === "loading" || this.state.status === "reloading");
    isValueDefined = ke(() => this.state.status !== "error" && this.state.value !== void 0);
    hasValue() { return this.isValueDefined(); }
};
function fj(e, t, n) { if (dh())
    throw fh(); let o = n?.injector ?? E(oe), r, i; o.get(Re).onDestroy(() => { r = void 0; }); let s = Sc({ source: () => { try {
        return qn(!0), { value: e(), thrown: !1 };
    }
    catch (a) {
        return Bi(a), { error: a, thrown: !0 };
    }
    finally {
        qn(!1);
    } }, computation: (a, c) => c !== void 0 ? c.value : a.thrown ? { status: "error", error: a.error } : { status: "resolved", value: a.value } }); return Ns(() => { let a; try {
    qn(!0), a = e();
}
catch (f) {
    Bi(f), s.set({ status: "error", error: f }), r = i = void 0;
    return;
}
finally {
    qn(!1);
} let c = xe(s), l = n?.equal ?? Object.is; if (c.status === "reloading" || c.status === "loading") {
    if (l(a, i))
        return;
}
else if (c.status === "resolved" && l(a, c.value))
    return; let d = (typeof t == "number" ? () => new Promise(f => setTimeout(f, t)) : t)(a, c); d === void 0 ? (s.set({ status: "resolved", value: a }), r = i = void 0) : (c.status !== "loading" && c.status !== "error" && s.set({ status: "loading", value: c.value }), r = d, i = a, d.then(() => { r === d && (s.set({ status: "resolved", value: a }), r = i = void 0); })); }, { injector: o }), pF(s); }
function pj() { return !1; }
function hj() { }
function hF(e, t) { if (typeof ngServerMode < "u" && ngServerMode)
    return; let n = globalThis.document.modelContext ?? globalThis.navigator.modelContext; if (!n || typeof n.registerTool != "function")
    return; let o = t ?? E(oe), r = o.get(Re), i = new AbortController, s = Ie(q({}, e), { execute: (a, c) => Er(o, () => e.execute(a, Ie(q({}, c), { signal: i.signal }))) }); n.registerTool(s, { signal: i.signal }), r.onDestroy(() => { i.abort(); }); }
function gj(e) { return Pe([Il(() => { for (let t of e)
        hF(t); })]); }
export { dN as ANIMATION_MODULE_TYPE, ki as APP_BOOTSTRAP_LISTENER, vt as APP_ID, sp as APP_INITIALIZER, ap as ApplicationInitStatus, C0 as ApplicationModule, He as ApplicationRef, Tv as Attribute, tM as COMPILER_OPTIONS, fN as CSP_NONCE, iS as CUSTOM_ELEMENTS_SCHEMA, _a as ChangeDetectionStrategy, kP as ChangeDetectorRef, vL as Compiler, jd as CompilerFactory, lL as Component, HE as ComponentRef, I0 as ContentChild, E0 as ContentChildren, EL as DEFAULT_CURRENCY_CODE, Nt as DOCUMENT, Fn as DebugElement, Vd as DebugEventListener, di as DebugNode, Mh as DefaultIterableDiffer, Re as DestroyRef, XC as Directive, We as ENVIRONMENT_INITIALIZER, gi as ElementRef, zM as EmbeddedViewRef, be as EnvironmentInjector, Mt as ErrorHandler, Dt as EventEmitter, c0 as HOST_TAG_NAME, Dv as Host, bM as HostAttributeToken, pL as HostBinding, hL as HostListener, yr as INJECTOR, vv as Inject, t_ as Injectable, C as InjectionToken, oe as Injector, dL as Input, JM as IterableDiffers, XM as KeyValueDiffers, ah as LOCALE_ID, Ry as MAX_ANIMATION_TIMEOUT, nM as MissingTranslationStrategy, sS as NO_ERRORS_SCHEMA, gL as NgModule, vI as NgModuleFactory, kn as NgModuleRef, G as NgZone, yv as Optional, fL as Output, Vi as OutputEmitterRef, uN as PLATFORM_ID, au as PLATFORM_INITIALIZER, Sr as PendingTasks, uL as Pipe, ow as PlatformRef, Zo as Query, na as QueryList, M0 as REQUEST, N0 as REQUEST_CONTEXT, w0 as RESPONSE_INIT, nR as Renderer2, ni as RendererFactory2, aa as RendererStyleFlags2, _c as ResourceDependencyError, Un as ResourceParamsStatus, BE as Sanitizer, X as SecurityContext, Ev as Self, r_ as Service, Zs as SimpleChange, Iv as SkipSelf, IL as TRANSLATIONS, DL as TRANSLATIONS_FORMAT, Xr as TemplateRef, Kx as Testability, oD as TestabilityRegistry, St as TransferState, mv as Type, Ji as VERSION, Ki as Version, T0 as ViewChild, D0 as ViewChildren, hc as ViewContainerRef, Ke as ViewEncapsulation, Rh as ViewRef, Fy as afterEveryRender, Nf as afterNextRender, Y0 as afterRenderEffect, TL as asNativeElements, Qw as assertInInjectionContext, hN as assertNotInReactiveContext, XP as assertPlatform, Q0 as booleanAttribute, ke as computed, m0 as contentChild, v0 as contentChildren, uj as createComponent, op as createEnvironmentInjector, zR as createNgModule, KP as createPlatform, JP as createPlatformFactory, fj as debounced, hF as declareExperimentalWebMcpTool, j0 as destroyPlatform, Ns as effect, hj as enableProdMode, zx as enableProfiling, ar as forwardRef, fi as getDebugNode, aj as getModuleFactory, cj as getNgModuleById, Gc as getPlatform, Xh as importProvidersFrom, E as inject, l0 as injectAsync, f0 as input, ZE as inputBinding, pj as isDevMode, ao as isSignal, pr as isStandalone, _s as isWritableSignal, Sc as linkedSignal, Pe as makeEnvironmentProviders, wg as makeStateKey, y0 as mergeApplicationConfig, p0 as model, Z0 as numberAttribute, u0 as onIdle, d0 as output, YE as outputBinding, lj as platformCore, _I as provideAppInitializer, aN as provideBrowserGlobalErrorListeners, O0 as provideCheckNoChangesConfig, Il as provideEnvironmentInitializer, gj as provideExperimentalWebMcpTools, UN as provideIdleServiceWith, GS as provideNgReflectAttributes, V0 as providePlatformInitializer, R0 as provideStabilityDebugging, L0 as provideZoneChangeDetection, mL as provideZonelessChangeDetection, dj as reflectComponentType, P as resolveForwardRef, bL as resource, pF as resourceFromSnapshots, Er as runInInjectionContext, rD as setTestabilityGetter, mt as signal, mR as twoWayBinding, xe as untracked, h0 as viewChild, g0 as viewChildren, Ay as \u0275ANIMATIONS_DISABLED, Ov as \u0275AcxChangeDetectionStrategy, Lv as \u0275AcxViewEncapsulation, Ga as \u0275AfterRenderManager, sM as \u0275CACHE_ACTIVE, _0 as \u0275CLIENT_RENDER_MODE_FLAG, U as \u0275CONTAINER_HEADER_OFFSET, qe as \u0275ChangeDetectionScheduler, kx as \u0275Console, ZI as \u0275ControlFlowBlockType, Pi as \u0275DEFAULT_LOCALE_ID, WI as \u0275DEFER_BLOCK_CONFIG, _x as \u0275DEFER_BLOCK_DEPENDENCY_INTERCEPTOR, Pt as \u0275DEHYDRATED_BLOCK_REGISTRY, pp as \u0275DeferBlockBehavior, Q as \u0275DeferBlockState, UP as \u0275ENABLE_ROOT_COMPONENT_BOOTSTRAP, Vv as \u0275EVENT_REPLAY_QUEUE, ws as \u0275EffectScheduler, gP as \u0275Framework, Xv as \u0275HydrationStatus, pN as \u0275IMAGE_CONFIG, Mg as \u0275IMAGE_CONFIG_DEFAULTS, Tl as \u0275INJECTOR_SCOPE, a0 as \u0275INPUT_SIGNAL_BRAND_WRITE_TYPE, _t as \u0275INTERNAL_APPLICATION_ERROR_HANDLER, x_ as \u0275IS_ENABLED_BLOCKING_INITIAL_NAVIGATION, Vn as \u0275IS_HYDRATION_DOM_REUSE_ENABLED, Xd as \u0275IS_INCREMENTAL_HYDRATION_ENABLED, Ti as \u0275JSACTION_BLOCK_ELEMENT_MAP, of as \u0275JSACTION_EVENT_CONTRACT, oa as \u0275LContext, ci as \u0275LocaleDataIndex, pn as \u0275NG_COMP_DEF, dr as \u0275NG_DIR_DEF, hn as \u0275NG_ELEMENT_ID, Xo as \u0275NG_INJ_DEF, rs as \u0275NG_MOD_DEF, fr as \u0275NG_PIPE_DEF, Wt as \u0275NG_PROV_DEF, Gs as \u0275NOT_FOUND_CHECK_ONLY_ELEMENT_INJECTOR, $ as \u0275NO_CHANGE, _o as \u0275NgModuleFactory, or as \u0275NoopNgZone, uF as \u0275PERFORMANCE_MARK_PREFIX, VP as \u0275PROVIDED_NG_ZONE, mN as \u0275PROVIDED_ZONELESS, gt as \u0275PendingTasksInternal, L as \u0275ProfilerEvent, et as \u0275R3Injector, ta as \u0275ReflectionCapabilities, xn as \u0275Render3ComponentFactory, ga as \u0275Render3ComponentRef, No as \u0275Render3NgModuleRef, bc as \u0275ResourceImpl, D as \u0275RuntimeError, KE as \u0275SHARED_STYLES_HOST, ae as \u0275SIGNAL, Zv as \u0275SSR_CONTENT_INTEGRITY_MARKER, eD as \u0275TESTABILITY, tD as \u0275TESTABILITY_GETTER, GI as \u0275TimerScheduler, qa as \u0275TracingAction, Bn as \u0275TracingService, nD as \u0275USE_PENDING_TASKS, sn as \u0275ViewRef, ns as \u0275XSS_SECURITY_URL, so as \u0275ZONELESS_ENABLED, vy as \u0275_sanitizeHtml, Va as \u0275_sanitizeUrl, rn as \u0275allLeavingAnimations, Vo as \u0275allowSanitizationBypassAndThrow, B0 as \u0275annotateForHydration, z0 as \u0275assertType, fS as \u0275bypassSanitizationTrustHtml, mS as \u0275bypassSanitizationTrustResourceUrl, hS as \u0275bypassSanitizationTrustScript, pS as \u0275bypassSanitizationTrustStyle, gS as \u0275bypassSanitizationTrustUrl, aM as \u0275chain, nx as \u0275clearResolutionOfComponentResourcesQueue, UC as \u0275compileComponent, sh as \u0275compileDirective, BC as \u0275compileNgModule, $C as \u0275compileNgModuleDefs, $P as \u0275compileNgModuleFactory, JC as \u0275compilePipe, dn as \u0275convertToBitFlags, cl as \u0275createInjector, eF as \u0275createOrReusePlatformInjector, x0 as \u0275defaultIterableDiffers, k0 as \u0275defaultKeyValueDiffers, wo as \u0275depsTracker, UE as \u0275devModeEqual, W0 as \u0275disableProfiling, G0 as \u0275enableProfiling, Rc as \u0275encapsulateResourceError, xp as \u0275findLocaleData, VC as \u0275flushModuleScopingQueueAsMuchAsPossible, ir as \u0275formatRuntimeError, YO as \u0275generateStandaloneInDeclarationsError, XR as \u0275getAsyncClassMetadataFn, sR as \u0275getClosestComponentName, W as \u0275getComponentDef, $0 as \u0275getCurrentClosestComponentInstance, Qs as \u0275getDeferBlocks, M_ as \u0275getDirectives, mi as \u0275getDocument, N_ as \u0275getHostElement, ur as \u0275getInjectableDef, we as \u0275getLContext, bk as \u0275getLocaleCurrencyCode, $D as \u0275getLocalePluralCase, _L as \u0275getOutputDestroyRef, uy as \u0275getSanitizationBypassType, Qx as \u0275getTransferState, cS as \u0275getUnknownElementStrictMode, uS as \u0275getUnknownPropertyStrictMode, Le as \u0275global, oI as \u0275inferTagNameFromDefinition, OP as \u0275injectChangeDetectorRef, H0 as \u0275internalCreateApplication, HP as \u0275internalProvideZoneChangeDetection, tx as \u0275isComponentDefPendingResolution, hl as \u0275isEnvironmentProviders, Sw as \u0275isInjectable, Dn as \u0275isNgModule, np as \u0275isPromise, mI as \u0275isSubscribable, rA as \u0275isViewDirty, iA as \u0275markForRefresh, mP as \u0275maybeUnwrapDefaultExport, Et as \u0275noSideEffects, rh as \u0275patchComponentDefWithScope, te as \u0275performanceMarkFeature, oo as \u0275promiseWithResolvers, Nc as \u0275provideZonelessChangeDetectionInternal, Zx as \u0275publishNonCoreGlobalUtil, q_ as \u0275readHydrationInfo, Sk as \u0275registerLocaleData, At as \u0275renderDeferBlockState, XO as \u0275resetCompiledComponents, W_ as \u0275resetIncrementalHydrationEnabledWarnedForTests, QO as \u0275resetJitOptions, SI as \u0275resolveComponentResources, ox as \u0275restoreComponentResolutionQueue, sx as \u0275setAllowDuplicateNgModuleIdsForTest, yw as \u0275setAlternateWeakRefImpl, LC as \u0275setClassDebugInfo, ip as \u0275setClassMetadata, NI as \u0275setClassMetadataAsync, ct as \u0275setCurrentInjector, R_ as \u0275setDocument, Rw as \u0275setInjectorProfilerContext, WD as \u0275setLocaleId, aS as \u0275setUnknownElementStrictMode, lS as \u0275setUnknownPropertyStrictMode, U0 as \u0275startMeasuring, q0 as \u0275stopMeasuring, Cr as \u0275store, sr as \u0275stringify, ih as \u0275transitiveScopesFor, yc as \u0275triggerResourceLoading, Nw as \u0275truncateMiddle, Ak as \u0275unregisterLocaleData, Ft as \u0275unwrapSafeValue, cN as \u0275unwrapWritableSignal, S0 as \u0275withDomHydration, TP as \u0275withEventReplay, b0 as \u0275withI18nSupport, A0 as \u0275withIncrementalHydration, xI as \u0275\u0275ControlFeature, rC as \u0275\u0275ExternalStylesFeature, Wn as \u0275\u0275FactoryTarget, kI as \u0275\u0275HostDirectivesFeature, up as \u0275\u0275InheritDefinitionFeature, Xm as \u0275\u0275NgOnChangesFeature, oC as \u0275\u0275ProvidersFeature, Yy as \u0275\u0275advance, Vr as \u0275\u0275animateEnter, Hr as \u0275\u0275animateEnterListener, Br as \u0275\u0275animateLeave, ya as \u0275\u0275animateLeaveListener, Ip as \u0275\u0275ariaProperty, eC as \u0275\u0275arrowFunction, UT as \u0275\u0275attachSourceLocations, Dp as \u0275\u0275attribute, ET as \u0275\u0275classMap, Gp as \u0275\u0275classProp, xD as \u0275\u0275componentInstance, OD as \u0275\u0275conditional, Ec as \u0275\u0275conditionalBranchCreate, kD as \u0275\u0275conditionalCreate, Hp as \u0275\u0275contentQuery, $p as \u0275\u0275contentQuerySignal, zE as \u0275\u0275control, GE as \u0275\u0275controlCreate, oh as \u0275\u0275declareLet, lD as \u0275\u0275defer, QI as \u0275\u0275deferEnableTimerScheduling, pD as \u0275\u0275deferHydrateNever, wD as \u0275\u0275deferHydrateOnHover, mD as \u0275\u0275deferHydrateOnIdle, ED as \u0275\u0275deferHydrateOnImmediate, SD as \u0275\u0275deferHydrateOnInteraction, TD as \u0275\u0275deferHydrateOnTimer, RD as \u0275\u0275deferHydrateOnViewport, fD as \u0275\u0275deferHydrateWhen, CD as \u0275\u0275deferOnHover, hD as \u0275\u0275deferOnIdle, vD as \u0275\u0275deferOnImmediate, ND as \u0275\u0275deferOnInteraction, ID as \u0275\u0275deferOnTimer, bD as \u0275\u0275deferOnViewport, MD as \u0275\u0275deferPrefetchOnHover, gD as \u0275\u0275deferPrefetchOnIdle, yD as \u0275\u0275deferPrefetchOnImmediate, _D as \u0275\u0275deferPrefetchOnInteraction, DD as \u0275\u0275deferPrefetchOnTimer, AD as \u0275\u0275deferPrefetchOnViewport, dD as \u0275\u0275deferPrefetchWhen, uD as \u0275\u0275deferWhen, EI as \u0275\u0275defineComponent, DI as \u0275\u0275defineDirective, Y as \u0275\u0275defineInjectable, lr as \u0275\u0275defineInjector, rp as \u0275\u0275defineNgModule, TI as \u0275\u0275definePipe, Lt as \u0275\u0275defineService, Go as \u0275\u0275directiveInject, jl as \u0275\u0275disableBindings, Mp as \u0275\u0275domElement, Sp as \u0275\u0275domElementContainer, _p as \u0275\u0275domElementContainerEnd, Mc as \u0275\u0275domElementContainerStart, Tc as \u0275\u0275domElementEnd, Dc as \u0275\u0275domElementStart, jp as \u0275\u0275domListener, Ap as \u0275\u0275domProperty, fp as \u0275\u0275domTemplate, Cp as \u0275\u0275element, Np as \u0275\u0275elementContainer, Li as \u0275\u0275elementContainerEnd, Cc as \u0275\u0275elementContainerStart, Ic as \u0275\u0275elementEnd, ai as \u0275\u0275elementStart, Fl as \u0275\u0275enableBindings, dC as \u0275\u0275enableIncrementalHydrationRuntime, OC as \u0275\u0275getComponentDepsFactory, BD as \u0275\u0275getCurrentView, hv as \u0275\u0275getInheritedFactory, PC as \u0275\u0275getReplaceMetadataURL, oT as \u0275\u0275i18n, iT as \u0275\u0275i18nApply, rT as \u0275\u0275i18nAttributes, Op as \u0275\u0275i18nEnd, Lp as \u0275\u0275i18nExp, sT as \u0275\u0275i18nPostprocess, kp as \u0275\u0275i18nStart, he as \u0275\u0275inject, wa as \u0275\u0275injectAttribute, qT as \u0275\u0275interpolate, GT as \u0275\u0275interpolate1, WT as \u0275\u0275interpolate2, zT as \u0275\u0275interpolate3, QT as \u0275\u0275interpolate4, ZT as \u0275\u0275interpolate5, YT as \u0275\u0275interpolate6, KT as \u0275\u0275interpolate7, JT as \u0275\u0275interpolate8, XT as \u0275\u0275interpolateV, JE as \u0275\u0275invalidFactory, cs as \u0275\u0275invalidFactoryDep, Pp as \u0275\u0275listener, dT as \u0275\u0275loadQuery, Xl as \u0275\u0275namespaceHTML, Jl as \u0275\u0275namespaceMathML, Kl as \u0275\u0275namespaceSVG, aT as \u0275\u0275nextContext, J0 as \u0275\u0275ngDeclareClassMetadata, X0 as \u0275\u0275ngDeclareClassMetadataAsync, ej as \u0275\u0275ngDeclareComponent, K0 as \u0275\u0275ngDeclareDirective, tj as \u0275\u0275ngDeclareFactory, nj as \u0275\u0275ngDeclareInjectable, oj as \u0275\u0275ngDeclareInjector, rj as \u0275\u0275ngDeclareNgModule, ij as \u0275\u0275ngDeclarePipe, sj as \u0275\u0275ngDeclareService, _C as \u0275\u0275pipe, SC as \u0275\u0275pipeBind1, bC as \u0275\u0275pipeBind2, AC as \u0275\u0275pipeBind3, RC as \u0275\u0275pipeBind4, xC as \u0275\u0275pipeBindV, lT as \u0275\u0275projection, cT as \u0275\u0275projectionDef, Tp as \u0275\u0275property, fC as \u0275\u0275pureFunction0, pC as \u0275\u0275pureFunction1, hC as \u0275\u0275pureFunction2, gC as \u0275\u0275pureFunction3, mC as \u0275\u0275pureFunction4, vC as \u0275\u0275pureFunction5, yC as \u0275\u0275pureFunction6, EC as \u0275\u0275pureFunction7, IC as \u0275\u0275pureFunction8, DC as \u0275\u0275pureFunctionV, fT as \u0275\u0275queryAdvance, uT as \u0275\u0275queryRefresh, $T as \u0275\u0275readContextLet, pT as \u0275\u0275reference, cp as \u0275\u0275registerNgModuleType, jD as \u0275\u0275repeater, FD as \u0275\u0275repeaterCreate, PD as \u0275\u0275repeaterTrackByIdentity, LD as \u0275\u0275repeaterTrackByIndex, FC as \u0275\u0275replaceMetadata, Bl as \u0275\u0275resetView, yf as \u0275\u0275resolveBody, _y as \u0275\u0275resolveDocument, Ny as \u0275\u0275resolveWindow, Hl as \u0275\u0275restoreView, pf as \u0275\u0275sanitizeHtml, Ba as \u0275\u0275sanitizeResourceUrl, mf as \u0275\u0275sanitizeScript, hf as \u0275\u0275sanitizeStyle, gf as \u0275\u0275sanitizeUrl, wy as \u0275\u0275sanitizeUrlOrResourceUrl, iC as \u0275\u0275setComponentScope, sC as \u0275\u0275setNgModuleScope, BT as \u0275\u0275storeLet, yT as \u0275\u0275styleMap, qp as \u0275\u0275styleProp, Fp as \u0275\u0275syntheticHostListener, Rp as \u0275\u0275syntheticHostProperty, dp as \u0275\u0275template, kC as \u0275\u0275templateRefExtractor, _T as \u0275\u0275text, Wp as \u0275\u0275textInterpolate, wc as \u0275\u0275textInterpolate1, zp as \u0275\u0275textInterpolate2, Qp as \u0275\u0275textInterpolate3, Zp as \u0275\u0275textInterpolate4, Yp as \u0275\u0275textInterpolate5, Kp as \u0275\u0275textInterpolate6, Jp as \u0275\u0275textInterpolate7, Xp as \u0275\u0275textInterpolate8, eh as \u0275\u0275textInterpolateV, Cy as \u0275\u0275trustConstantHtml, My as \u0275\u0275trustConstantResourceUrl, VT as \u0275\u0275twoWayBindingSet, nh as \u0275\u0275twoWayListener, th as \u0275\u0275twoWayProperty, vf as \u0275\u0275validateAttribute, Bp as \u0275\u0275viewQuery, Up as \u0275\u0275viewQuerySignal };
/*! Bundled license information:

@angular/core/fesm2022/_pending_tasks-chunk.mjs:
@angular/core/fesm2022/_attribute-chunk.mjs:
@angular/core/fesm2022/_debug_node-chunk.mjs:
@angular/core/fesm2022/_resource-chunk.mjs:
@angular/core/fesm2022/primitives-event-dispatch.mjs:
@angular/core/fesm2022/core.mjs:
  (**
   * @license Angular v22.0.2
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
