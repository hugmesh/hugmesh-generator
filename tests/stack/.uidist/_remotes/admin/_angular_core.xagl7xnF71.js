import { a as Xc, b as at, f as el } from "@nf-internal/chunk-7TQWXOH6";
import { B as Kc, E as Jc, F as Lh, G as Fh, H as tl, I as jh, J as Vh, K as Hh, L as pw, a as ae, b as k, c as qi, f as Yc, g as Gi, n as Ko, p as Wi, r as zi, s as $t, w as Qi, x as Oh, y as Ph } from "@nf-internal/chunk-FFXGJPQD";
import { a as q, b as Ie, c as xh, d as Se, e as Zc } from "@nf-internal/chunk-PZNONLPT";
import { setActiveConsumer as zn } from "@angular/core/primitives/signals";
import { isNotFound as hw } from "@angular/core/primitives/di";
import { BehaviorSubject as gw, Observable as mw, Subject as vw, Subscription as yw } from "rxjs";
var Yi = class {
    full;
    major;
    minor;
    patch;
    constructor(t) { this.full = t; let n = t.split("."); this.major = n[0], this.minor = n[1], this.patch = n.slice(2).join("."); }
}, Ki = new Yi("22.0.0"), es = (() => { let e = Ki.full; return `https://${e.includes("-next") || e.includes("-rc") || e === "0.0.0-PLACEHOLDER" ? "next" : `v${Ki.major}`}.angular.dev`; })(), Ew = `${es}/errors`, ts = "https://angular.dev/best-practices/security#preventing-cross-site-scripting-xss", D = class extends Error {
    code;
    constructor(t, n) { super(sr(t, n)), this.code = t; }
};
function Iw(e) { return `NG0${Math.abs(e)}`; }
function sr(e, t) { return `${Iw(e)}${t ? ": " + t : ""}`; }
function j(e) { for (let t in e)
    if (e[t] === j)
        return t; throw Error(""); }
function Wh(e, t) { for (let n in t)
    t.hasOwnProperty(n) && !e.hasOwnProperty(n) && (e[n] = t[n]); }
function ar(e) {
    if (typeof e == "string")
        return e;
    if (Array.isArray(e))
        return `[${e.map(ar).join(", ")}]`;
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
function ns(e, t) { return e ? t ? `${e} ${t}` : e : t || ""; }
function Dw(e, t = 100) { if (!e || t < 1 || e.length <= t)
    return e; if (t == 1)
    return e.substring(0, 1) + "..."; let n = Math.round(t / 2); return e.substring(0, n) + "..." + e.substring(e.length - n); }
var Tw = j({ __forward_ref__: j });
function cr(e) { return e.__forward_ref__ = cr, e; }
function L(e) { return lr(e) ? e() : e; }
function lr(e) { return typeof e == "function" && e.hasOwnProperty(Tw) && e.__forward_ref__ === cr; }
function hl(e, t, n) { e != t && Gt(n, e, t, "=="); }
function gl(e, t) { e == null && Gt(t, e, null, "!="); }
function Gt(e, t, n, o) { throw new Error(`ASSERTION ERROR: ${e}` + (o == null ? "" : ` [Expected=> ${n} ${o} ${t} <=Actual]`)); }
function Y(e) { return { token: e.token, providedIn: e.providedIn || null, factory: e.factory, value: void 0 }; }
function ur(e) { return { providers: e.providers || [], imports: e.imports || [] }; }
function dr(e) { return Mw(e, Wt); }
function Cw(e) { return dr(e) !== null; }
function Mw(e, t) { return e.hasOwnProperty(t) && e[t] || null; }
function ww(e) { let t = e?.[Wt] ?? null; return t || null; }
function Xo(e) { return e && e.hasOwnProperty(er) ? e[er] : null; }
var Wt = j({ \u0275prov: j }), er = j({ \u0275inj: j }), C = class {
    _desc;
    ngMetadataName = "InjectionToken";
    \u0275prov;
    constructor(t, n) { this._desc = t, this.\u0275prov = void 0, typeof n == "number" ? this.__NG_ELEMENT_ID__ = n : n !== void 0 && (this.\u0275prov = Y({ token: this, providedIn: n.providedIn || "root", factory: n.factory })); }
    get multi() { return this; }
    toString() { return `InjectionToken ${this._desc}`; }
}, Bh;
function Nw(e) { Gt("setInjectorProfilerContext should never be called in production mode"); let t = Bh; return Bh = e, t; }
function ml(e) { return e && !!e.\u0275providers; }
var fn = j({ \u0275cmp: j }), fr = j({ \u0275dir: j }), pr = j({ \u0275pipe: j }), os = j({ \u0275mod: j }), $e = j({ \u0275fac: j }), pn = j({ __NG_ELEMENT_ID__: j }), $h = j({ __NG_ENV_ID__: j });
function Zn(e) { return is(e, "@NgModule"), e[os] || null; }
function rs(e) { let t = Zn(e); if (!t)
    throw new D(915, !1); return t; }
function W(e) { return is(e, "@Component"), e[fn] || null; }
function Oe(e) { return is(e, "@Directive"), e[fr] || null; }
function tt(e) { return is(e, "@Pipe"), e[pr] || null; }
function is(e, t) { if (e == null)
    throw new D(-919, !1); }
function hr(e) { let t = W(e) || Oe(e) || tt(e); return t !== null && t.standalone; }
function b(e) { return typeof e == "string" ? e : e == null ? "" : String(e); }
function qe(e) { return typeof e == "function" ? e.name || e.toString() : typeof e == "object" && e != null && typeof e.type == "function" ? e.type.name || e.type.toString() : b(e); }
var zh = j({ ngErrorCode: j }), _w = j({ ngErrorMessage: j }), Sw = j({ ngTokenPath: j });
function vl(e, t) { return Qh("", -200, t); }
function ss(e, t) { throw new D(-201, !1); }
function Qh(e, t, n) { let o = new D(t, e); return o[zh] = t, o[_w] = e, n && (o[Sw] = n), o; }
function bw(e) { return e[zh]; }
var ol;
function Zh() { return ol; }
function Te(e) { let t = ol; return ol = e, t; }
function yl(e, t, n) { let o = dr(e); if (o && o.providedIn == "root")
    return o.value === void 0 ? o.value = o.factory() : o.value; if (n & 8)
    return null; if (t !== void 0)
    return t; ss(e, ""); }
var Pe = globalThis;
var Aw = {}, ln = Aw, rl = "__NG_DI_FLAG__", il = class {
    injector;
    constructor(t) { this.injector = t; }
    retrieve(t, n) { let o = un(n) || 0; try {
        return this.injector.get(t, o & 8 ? null : ln, o);
    }
    catch (r) {
        if (el(r))
            return r;
        throw r;
    } }
};
function Rw(e, t = 0) { let n = Xc(); if (n === void 0)
    throw new D(-203, !1); if (n === null)
    return yl(e, void 0, t); {
    let o = kw(t), r = n.retrieve(e, o);
    if (el(r)) {
        if (o.optional)
            return null;
        throw r;
    }
    return r;
} }
function he(e, t = 0) { return (Zh() || Rw)(L(e), t); }
function as(e) { throw new D(202, !1); }
function E(e, t) { return he(e, un(t)); }
function un(e) { return typeof e > "u" || typeof e == "number" ? e : 0 | (e.optional && 8) | (e.host && 1) | (e.self && 2) | (e.skipSelf && 4); }
function kw(e) { return { optional: !!(e & 8), host: !!(e & 1), self: !!(e & 2), skipSelf: !!(e & 4) }; }
function sl(e) { let t = []; for (let n = 0; n < e.length; n++) {
    let o = L(e[n]);
    if (Array.isArray(o)) {
        if (o.length === 0)
            throw new D(900, !1);
        let r, i = 0;
        for (let s = 0; s < o.length; s++) {
            let a = o[s], c = xw(a);
            typeof c == "number" ? c === -1 ? r = a.token : i |= c : r = a;
        }
        t.push(he(r, i));
    }
    else
        t.push(he(o));
} return t; }
function Yn(e, t) { return e[rl] = t, e.prototype[rl] = t, e; }
function xw(e) { return e[rl]; }
function Ut(e, t) { let n = e.hasOwnProperty($e); return n ? e[$e] : null; }
function Yh(e, t, n) { if (e.length !== t.length)
    return !1; for (let o = 0; o < e.length; o++) {
    let r = e[o], i = t[o];
    if (n && (r = n(r), i = n(i)), i !== r)
        return !1;
} return !0; }
function nt(e) { return e.flat(Number.POSITIVE_INFINITY); }
function gr(e, t) { e.forEach(n => Array.isArray(n) ? gr(n, t) : t(n)); }
function El(e, t, n) { t >= e.length ? e.push(n) : e.splice(t, 0, n); }
function mr(e, t) { return t >= e.length - 1 ? e.pop() : e.splice(t, 1)[0]; }
function vr(e, t) { let n = []; for (let o = 0; o < e; o++)
    n.push(t); return n; }
function Il(e, t, n) { let o = e.length - n; for (; t < o;)
    e[t] = e[t + n], t++; for (; n--;)
    e.pop(); }
function Dl(e, t, n, o) { let r = e.length; if (r == t)
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
function yr(e, t, n) { let o = Kn(e, t); return o >= 0 ? e[o | 1] = n : (o = ~o, Dl(e, o, t, n)), o; }
function cs(e, t) { let n = Kn(e, t); if (n >= 0)
    return e[n | 1]; }
function Kn(e, t) { return Ow(e, t, 1); }
function Ow(e, t, n) { let o = 0, r = e.length >> n; for (; r !== o;) {
    let i = o + (r - o >> 1), s = e[i << n];
    if (t === s)
        return i << n;
    s > t ? r = i : o = i + 1;
} return ~(r << n); }
var wt = {}, F = [], Ge = new C(""), Er = new C("", -1), ls = new C(""), Ct = class {
    get(t, n = ln) { if (n === ln) {
        let r = Qh("", -201);
        throw r.name = "\u0275NotFound", r;
    } return n; }
};
function Le(e) { return { \u0275providers: e }; }
function Tl(e) { return Le([{ provide: Ge, multi: !0, useValue: e }]); }
function Kh(...e) { return { \u0275providers: us(!0, e), \u0275fromNgModule: !0 }; }
function us(e, ...t) { let n = [], o = new Set, r, i = s => { n.push(s); }; return gr(t, s => { let a = s; tr(a, i, [], o) && (r ||= [], r.push(a)); }), r !== void 0 && Jh(r, i), n; }
function Jh(e, t) { for (let n = 0; n < e.length; n++) {
    let { ngModule: o, providers: r } = e[n];
    Cl(r, i => { t(i, o); });
} }
function tr(e, t, n, o) { if (e = L(e), !e)
    return !1; let r = null, i = Xo(e), s = !i && W(e); if (!i && !s) {
    let c = e.ngModule;
    if (i = Xo(c), i)
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
            tr(l, t, n, o);
    }
}
else if (i) {
    if (i.imports != null && !a) {
        o.add(r);
        let l;
        gr(i.imports, u => { tr(u, t, n, o) && (l ||= [], l.push(u)); }), l !== void 0 && Jh(l, t);
    }
    if (!a) {
        let l = Ut(r) || (() => new r);
        t({ provide: r, useFactory: l, deps: F }, r), t({ provide: ls, useValue: r, multi: !0 }, r), t({ provide: Ge, useValue: () => he(r), multi: !0 }, r);
    }
    let c = i.providers;
    if (c != null && !a) {
        let l = e;
        Cl(c, u => { t(u, l); });
    }
}
else
    return !1; return r !== e && e.providers !== void 0; }
function Cl(e, t) { for (let n of e)
    ml(n) && (n = n.\u0275providers), Array.isArray(n) ? Cl(n, t) : t(n); }
var Pw = j({ provide: String, useValue: j });
function Xh(e) { return e !== null && typeof e == "object" && Pw in e; }
function Lw(e) { return !!(e && e.useExisting); }
function Fw(e) { return !!(e && e.useFactory); }
function dn(e) { return typeof e == "function"; }
function eg(e) { return !!e.useClass; }
var Ml = new C(""), Zi = {}, Uh = {}, nl;
function Jn() { return nl === void 0 && (nl = new Ct), nl; }
var be = class {
}, Xe = class extends be {
    parent;
    source;
    scopes;
    records = new Map;
    _ngOnDestroyHooks = new Set;
    _onDestroyHooks = [];
    get destroyed() { return this._destroyed; }
    _destroyed = !1;
    injectorDefTypes;
    constructor(t, n, o, r) { super(), this.parent = n, this.source = o, this.scopes = r, cl(t, s => this.processProvider(s)), this.records.set(Er, Qn(void 0, this)), r.has("environment") && this.records.set(be, Qn(void 0, this)); let i = this.records.get(Ml); i != null && typeof i.value == "string" && this.scopes.add(i.value), this.injectorDefTypes = new Set(this.get(ls, F, { self: !0 })); }
    retrieve(t, n) { let o = un(n) || 0; try {
        return this.get(t, ln, o);
    }
    catch (r) {
        if (hw(r))
            return r;
        throw r;
    } }
    destroy() { Jo(this), this._destroyed = !0; let t = zn(null); try {
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
    onDestroy(t) { return Jo(this), this._onDestroyHooks.push(t), () => this.removeOnDestroy(t); }
    runInContext(t) { Jo(this); let n = at(this), o = Te(void 0), r; try {
        return t();
    }
    finally {
        at(n), Te(o);
    } }
    get(t, n = ln, o) { if (Jo(this), t.hasOwnProperty($h))
        return t[$h](this); let r = un(o), i, s = at(this), a = Te(void 0); try {
        if (!(r & 4)) {
            let l = this.records.get(t);
            if (l === void 0) {
                let u = $w(t) && dr(t);
                u && this.injectableDefInScope(u) ? l = Qn(al(t), Zi) : l = null, this.records.set(t, l);
            }
            if (l != null)
                return this.hydrate(t, l, r);
        }
        let c = r & 2 ? Jn() : this.parent;
        return n = r & 8 && n === ln ? null : n, c.get(t, n);
    }
    catch (c) {
        let l = bw(c);
        throw l === -200 || l === -201 ? new D(l, null) : c;
    }
    finally {
        Te(a), at(s);
    } }
    resolveInjectorInitializers() { let t = zn(null), n = at(this), o = Te(void 0), r; try {
        let i = this.get(Ge, F, { self: !0 });
        for (let s of i)
            s();
    }
    finally {
        at(n), Te(o), zn(t);
    } }
    toString() { return "R3Injector[...]"; }
    processProvider(t) { t = L(t); let n = dn(t) ? t : L(t && t.provide), o = Vw(t); if (!dn(t) && t.multi === !0) {
        let r = this.records.get(n);
        r || (r = Qn(void 0, Zi, !0), r.factory = () => sl(r.multi), this.records.set(n, r)), n = t, r.multi.push(t);
    } this.records.set(n, o); }
    hydrate(t, n, o) { let r = zn(null); try {
        if (n.value === Uh)
            throw vl("");
        return n.value === Zi && (n.value = Uh, n.value = n.factory(void 0, o)), typeof n.value == "object" && n.value && Bw(n.value) && this._ngOnDestroyHooks.add(n.value), n.value;
    }
    finally {
        zn(r);
    } }
    injectableDefInScope(t) { if (!t.providedIn)
        return !1; let n = L(t.providedIn); return typeof n == "string" ? n === "any" || this.scopes.has(n) : this.injectorDefTypes.has(n); }
    removeOnDestroy(t) { let n = this._onDestroyHooks.indexOf(t); n !== -1 && this._onDestroyHooks.splice(n, 1); }
};
function al(e) { let t = dr(e), n = t !== null ? t.factory : Ut(e); if (n !== null)
    return n; if (e instanceof C)
    throw new D(-204, !1); if (e instanceof Function)
    return jw(e); throw new D(-204, !1); }
function jw(e) { if (e.length > 0)
    throw new D(-204, !1); let n = ww(e); return n !== null ? () => n.factory(e) : () => new e; }
function Vw(e) { if (Xh(e))
    return Qn(void 0, e.useValue); {
    let t = wl(e);
    return Qn(t, Zi);
} }
function wl(e, t, n) { let o; if (dn(e)) {
    let r = L(e);
    return Ut(r) || al(r);
}
else if (Xh(e))
    o = () => L(e.useValue);
else if (Fw(e))
    o = () => e.useFactory(...sl(e.deps || []));
else if (Lw(e))
    o = (r, i) => he(L(e.useExisting), i !== void 0 && i & 8 ? 8 : void 0);
else {
    let r = L(e && (e.useClass || e.provide));
    if (Hw(e))
        o = () => new r(...sl(e.deps));
    else
        return Ut(r) || al(r);
} return o; }
function Jo(e) { if (e.destroyed)
    throw new D(-205, !1); }
function Qn(e, t, n = !1) { return { factory: e, value: t, multi: n ? [] : void 0 }; }
function Hw(e) { return !!e.deps; }
function Bw(e) { return e !== null && typeof e == "object" && typeof e.ngOnDestroy == "function"; }
function $w(e) { return typeof e == "function" || typeof e == "object" && e.ngMetadataName === "InjectionToken"; }
function cl(e, t) { for (let n of e)
    Array.isArray(n) ? cl(n, t) : n && ml(n) ? cl(n.\u0275providers, t) : t(n); }
function Ir(e, t) { let n; e instanceof Xe ? (Jo(e), n = e) : n = new il(e); let o, r = at(n), i = Te(void 0); try {
    return t();
}
finally {
    at(r), Te(i);
} }
function ds() { return Zh() !== void 0 || Xc() != null; }
function Uw(e) { if (!ds())
    throw new D(-203, !1); }
var H = 0, m = 1, w = 2, z = 3, ge = 4, ce = 5, fe = 6, zt = 7, B = 8, x = 9, We = 10, N = 11, Qt = 12, Dr = 13, hn = 14, re = 15, Zt = 16, gn = 17, ct = 18, Fe = 19, Nl = 20, Tt = 21, fs = 22, qt = 23, Ae = 24, mn = 25, ze = 26, I = 27, _l = 1, je = 6, ot = 7, Tr = 8, vn = 9, U = 10;
function J(e) { return Array.isArray(e) && typeof e[_l] == "object"; }
function K(e) { return Array.isArray(e) && e[_l] === !0; }
function Sl(e) { return (e.flags & 4) !== 0; }
function Ce(e) { return e.componentOffset > -1; }
function Xn(e) { return (e.flags & 1) === 1; }
function Qe(e) { return !!e.template; }
function lt(e) { return (e[w] & 512) !== 0; }
function bl(e) { return (e.type & 16) === 16; }
function tg(e) { return (e[w] & 32) === 32; }
function ut(e) { return (e[w] & 256) === 256; }
function ng(e, t) { qw(e, t[m]); }
function qw(e, t) { Al(e); let n = t.data; for (let o = I; o < n.length; o++)
    if (n[o] === e)
        return; Gt("This TNode does not belong to this TView."); }
function Al(e) { gl(e, "TNode must be defined"), e && typeof e == "object" && e.hasOwnProperty("directiveStylingLast") || Gt("Not of type TNode, got: " + e); }
function og(e) { gl(e, "LView must be defined"), hl(J(e), !0, "Expecting LView"); }
var ps = "svg", hs = "math";
function O(e) { for (; Array.isArray(e);)
    e = e[H]; return e; }
function Cr(e) { for (; Array.isArray(e);) {
    if (typeof e[_l] == "object")
        return e;
    e = e[H];
} return null; }
function yn(e, t) { return O(t[e]); }
function ie(e, t) { return O(t[e.index]); }
function rg(e, t) { let n = e === null ? -1 : e.index; return n !== -1 ? O(t[n]) : null; }
function Yt(e, t) { return e.data[t]; }
function Kt(e, t) { return e[t]; }
function Mr(e, t, n, o) { n >= e.data.length && (e.data[n] = null, e.blueprint[n] = null), t[n] = o; }
function me(e, t) { let n = t[e]; return J(n) ? n : n[H]; }
function ig(e) { return (e[w] & 4) === 4; }
function gs(e) { return (e[w] & 128) === 128; }
function sg(e) { return K(e[z]); }
function ve(e, t) { return t == null ? null : e[t]; }
function Rl(e) { e[gn] = 0; }
function wr(e) { e[w] & 1024 || (e[w] |= 1024, gs(e) && En(e)); }
function kl(e, t) { for (; e > 0;)
    t = t[hn], e--; return t; }
function eo(e) { return !!(e[w] & 9216 || e[Ae]?.dirty); }
function ms(e) { e[We].changeDetectionScheduler?.notify(8), e[w] & 64 && (e[w] |= 1024), eo(e) && En(e); }
function En(e) { e[We].changeDetectionScheduler?.notify(0); let t = et(e); for (; t !== null && !(t[w] & 8192 || (t[w] |= 8192, !gs(t)));)
    t = et(t); }
function to(e, t) { if (ut(e))
    throw new D(911, !1); e[Tt] === null && (e[Tt] = []), e[Tt].push(t); }
function vs(e, t) { if (e[Tt] === null)
    return; let n = e[Tt].indexOf(t); n !== -1 && e[Tt].splice(n, 1); }
function et(e) { let t = e[z]; return K(t) ? t[z] : t; }
function xl(e) { return e[zt] ??= []; }
function Ol(e) { return e.cleanup ??= []; }
function ag(e, t, n, o) { let r = xl(t); r.push(n), e.firstCreatePass && Ol(e).push(o, r.length - 1); }
var S = { lFrame: gg(null), bindingsEnabled: !0, skipHydrationRootTNode: null };
var ll = !1;
function cg() { return S.lFrame.elementDepthCount; }
function lg() { S.lFrame.elementDepthCount++; }
function Pl() { S.lFrame.elementDepthCount--; }
function ys() { return S.bindingsEnabled; }
function Nr() { return S.skipHydrationRootTNode !== null; }
function Ll(e) { return S.skipHydrationRootTNode === e; }
function Fl() { S.bindingsEnabled = !0; }
function ug(e) { S.skipHydrationRootTNode = e; }
function jl() { S.bindingsEnabled = !1; }
function Vl() { S.skipHydrationRootTNode = null; }
function g() { return S.lFrame.lView; }
function A() { return S.lFrame.tView; }
function Hl(e) { return S.lFrame.contextLView = e, e[B]; }
function Bl(e) { return S.lFrame.contextLView = null, e; }
function _() { let e = $l(); for (; e !== null && e.type === 64;)
    e = e.parent; return e; }
function $l() { return S.lFrame.currentTNode; }
function no() { let e = S.lFrame, t = e.currentTNode; return e.isParent ? t : t.parent; }
function dt(e, t) { let n = S.lFrame; n.currentTNode = e, n.isParent = t; }
function Ul() { return S.lFrame.isParent; }
function ql() { S.lFrame.isParent = !1; }
function Gl() { return S.lFrame.contextLView; }
function Wl() { return ll; }
function nr(e) { let t = ll; return ll = e, t; }
function ye() { let e = S.lFrame, t = e.bindingRootIndex; return t === -1 && (t = e.bindingRootIndex = e.tView.bindingStartIndex), t; }
function ft() { return S.lFrame.bindingIndex; }
function zl(e) { return S.lFrame.bindingIndex = e; }
function De() { return S.lFrame.bindingIndex++; }
function pt(e) { let t = S.lFrame, n = t.bindingIndex; return t.bindingIndex = t.bindingIndex + e, n; }
function dg() { return S.lFrame.inI18n; }
function Ql(e) { S.lFrame.inI18n = e; }
function fg(e, t) { let n = S.lFrame; n.bindingIndex = n.bindingRootIndex = e, Es(t); }
function pg() { return S.lFrame.currentDirectiveIndex; }
function Es(e) { S.lFrame.currentDirectiveIndex = e; }
function Is(e) { let t = S.lFrame.currentDirectiveIndex; return t === -1 ? null : e[t]; }
function Ds() { return S.lFrame.currentQueryIndex; }
function _r(e) { S.lFrame.currentQueryIndex = e; }
function Gw(e) { let t = e[m]; return t.type === 2 ? t.declTNode : t.type === 1 ? e[ce] : null; }
function Zl(e, t, n) { if (n & 4) {
    let r = t, i = e;
    for (; r = r.parent, r === null && !(n & 1);)
        if (r = Gw(i), r === null || (i = i[hn], r.type & 10))
            break;
    if (r === null)
        return !1;
    t = r, e = i;
} let o = S.lFrame = hg(); return o.currentTNode = t, o.lView = e, !0; }
function Ts(e) { let t = hg(), n = e[m]; S.lFrame = t, t.currentTNode = n.firstChild, t.lView = e, t.tView = n, t.contextLView = e, t.bindingIndex = n.bindingStartIndex, t.inI18n = !1; }
function hg() { let e = S.lFrame, t = e === null ? null : e.child; return t === null ? gg(e) : t; }
function gg(e) { let t = { currentTNode: null, isParent: !0, lView: null, tView: null, selectedIndex: -1, contextLView: null, elementDepthCount: 0, currentNamespace: null, currentDirectiveIndex: -1, bindingRootIndex: -1, bindingIndex: -1, currentQueryIndex: 0, parent: e, child: null, inI18n: !1 }; return e !== null && (e.child = t), t; }
function mg() { let e = S.lFrame; return S.lFrame = e.parent, e.currentTNode = null, e.lView = null, e; }
var Yl = mg;
function Cs() { let e = mg(); e.isParent = !0, e.tView = null, e.selectedIndex = -1, e.contextLView = null, e.elementDepthCount = 0, e.currentDirectiveIndex = -1, e.currentNamespace = null, e.bindingRootIndex = -1, e.bindingIndex = -1, e.currentQueryIndex = 0; }
function vg(e) { return (S.lFrame.contextLView = kl(e, S.lFrame.contextLView))[B]; }
function le() { return S.lFrame.selectedIndex; }
function ht(e) { S.lFrame.selectedIndex = e; }
function Ve() { let e = S.lFrame; return Yt(e.tView, e.selectedIndex); }
function Kl() { S.lFrame.currentNamespace = ps; }
function Jl() { S.lFrame.currentNamespace = hs; }
function Xl() { Ww(); }
function Ww() { S.lFrame.currentNamespace = null; }
function Ms() { return S.lFrame.currentNamespace; }
var yg = !0;
function Sr() { return yg; }
function rt(e) { yg = e; }
function oo() { let e, t; return { promise: new Promise((o, r) => { e = o, t = r; }), resolve: e, reject: t }; }
function ul(e, t = null, n = null, o) { let r = eu(e, t, n, o); return r.resolveInjectorInitializers(), r; }
function eu(e, t = null, n = null, o, r = new Set) { let i = [n || F, Kh(e)], s; return new Xe(i, t || Jn(), s || null, r); }
var zw = new Set;
function Eg() { return zw; }
var oe = class e {
    static THROW_IF_NOT_FOUND = ln;
    static NULL = new Ct;
    static create(t, n) { if (Array.isArray(t))
        return ul({ name: "" }, n, t, ""); {
        let o = t.name ?? "";
        return ul({ name: o }, t.parent, t.providers, o);
    } }
    static \u0275prov = Y({ token: e, providedIn: "any", factory: () => he(Er) });
    static __NG_ELEMENT_ID__ = -1;
}, Nt = new C(""), Re = (() => { class e {
    static __NG_ELEMENT_ID__ = Qw;
    static __NG_ENV_ID__ = n => n;
} return e; })(), Ji = class extends Re {
    _lView;
    constructor(t) { super(), this._lView = t; }
    get destroyed() { return ut(this._lView); }
    onDestroy(t) { let n = this._lView; return to(n, t), () => vs(n, t); }
};
function Qw() { return new Ji(g()); }
var tu = !1, nu = new C(""), gt = (() => { class e {
    taskId = 0;
    pendingTasks = new Set;
    destroyed = !1;
    pendingTask = new gw(!1);
    debugTaskTracker = E(nu, { optional: !0 });
    get hasPendingTasks() { return this.destroyed ? !1 : this.pendingTask.value; }
    get hasPendingTasksObservable() { return this.destroyed ? new mw(n => { n.next(!1), n.complete(); }) : this.pendingTask; }
    add() { !this.hasPendingTasks && !this.destroyed && this.pendingTask.next(!0); let n = this.taskId++; return this.pendingTasks.add(n), this.debugTaskTracker?.add(n), n; }
    has(n) { return this.pendingTasks.has(n); }
    remove(n) { this.pendingTasks.delete(n), this.debugTaskTracker?.remove(n), this.pendingTasks.size === 0 && this.hasPendingTasks && this.pendingTask.next(!1); }
    ngOnDestroy() { this.pendingTasks.clear(), this.hasPendingTasks && this.pendingTask.next(!1), this.destroyed = !0, this.pendingTask.unsubscribe(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })(), dl = class extends vw {
    __isAsync;
    destroyRef = void 0;
    pendingTasks = void 0;
    constructor(t = !1) { super(), this.__isAsync = t, ds() && (this.destroyRef = E(Re, { optional: !0 }) ?? void 0, this.pendingTasks = E(gt, { optional: !0 }) ?? void 0); }
    emit(t) { let n = k(null); try {
        super.next(t);
    }
    finally {
        k(n);
    } }
    subscribe(t, n, o) { let r = t, i = n || (() => null), s = o; if (t && typeof t == "object") {
        let c = t;
        r = c.next?.bind(c), i = c.error?.bind(c), s = c.complete?.bind(c);
    } this.__isAsync && (i = this.wrapInTimeout(i), r && (r = this.wrapInTimeout(r)), s && (s = this.wrapInTimeout(s))); let a = super.subscribe({ next: r, error: i, complete: s }); return t instanceof yw && t.add(a), a; }
    wrapInTimeout(t) { return n => { let o = this.pendingTasks?.add(); setTimeout(() => { try {
        t(n);
    }
    finally {
        o !== void 0 && this.pendingTasks?.remove(o);
    } }); }; }
}, Dt = dl;
function Xi(...e) { }
function ou(e) { let t, n; function o() { e = Xi; try {
    n !== void 0 && typeof cancelAnimationFrame == "function" && cancelAnimationFrame(n), t !== void 0 && clearTimeout(t);
}
catch { } } return t = setTimeout(() => { e(), o(); }), typeof requestAnimationFrame == "function" && (n = requestAnimationFrame(() => { e(), o(); })), () => o(); }
function Ig(e) { return queueMicrotask(() => e()), () => { e = Xi; }; }
var ru = "isAngularZone", or = ru + "_ID", Zw = 0, G = class e {
    hasPendingMacrotasks = !1;
    hasPendingMicrotasks = !1;
    isStable = !0;
    onUnstable = new Dt(!1);
    onMicrotaskEmpty = new Dt(!1);
    onStable = new Dt(!1);
    onError = new Dt(!1);
    constructor(t) { let { enableLongStackTrace: n = !1, shouldCoalesceEventChangeDetection: o = !1, shouldCoalesceRunChangeDetection: r = !1, scheduleInRootZone: i = tu } = t; if (typeof Zone > "u")
        throw new D(908, !1); Zone.assertZonePatched(); let s = this; s._nesting = 0, s._outer = s._inner = Zone.current, Zone.TaskTrackingZoneSpec && (s._inner = s._inner.fork(new Zone.TaskTrackingZoneSpec)), n && Zone.longStackTraceZoneSpec && (s._inner = s._inner.fork(Zone.longStackTraceZoneSpec)), s.shouldCoalesceEventChangeDetection = !r && o, s.shouldCoalesceRunChangeDetection = r, s.callbackScheduled = !1, s.scheduleInRootZone = i, Jw(s); }
    static isInAngularZone() { return typeof Zone < "u" && Zone.current.get(ru) === !0; }
    static assertInAngularZone() { if (!e.isInAngularZone())
        throw new D(909, !1); }
    static assertNotInAngularZone() { if (e.isInAngularZone())
        throw new D(909, !1); }
    run(t, n, o) { return this._inner.run(t, n, o); }
    runTask(t, n, o, r) { let i = this._inner, s = i.scheduleEventTask("NgZoneEvent: " + r, t, Yw, Xi, Xi); try {
        return i.runTask(s, n, o);
    }
    finally {
        i.cancelTask(s);
    } }
    runGuarded(t, n, o) { return this._inner.runGuarded(t, n, o); }
    runOutsideAngular(t) { return this._outer.run(t); }
}, Yw = {};
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
function Kw(e) { if (e.isCheckStableRunning || e.callbackScheduled)
    return; e.callbackScheduled = !0; function t() { ou(() => { e.callbackScheduled = !1, fl(e), e.isCheckStableRunning = !0, iu(e), e.isCheckStableRunning = !1; }); } e.scheduleInRootZone ? Zone.root.run(() => { t(); }) : e._outer.run(() => { t(); }), fl(e); }
function Jw(e) { let t = () => { Kw(e); }, n = Zw++; e._inner = e._inner.fork({ name: "angular", properties: { [ru]: !0, [or]: n, [or + n]: !0 }, onInvokeTask: (o, r, i, s, a, c) => { if (Xw(c))
        return o.invokeTask(i, s, a, c); try {
        return qh(e), o.invokeTask(i, s, a, c);
    }
    finally {
        (e.shouldCoalesceEventChangeDetection && s.type === "eventTask" || e.shouldCoalesceRunChangeDetection) && t(), Gh(e);
    } }, onInvoke: (o, r, i, s, a, c, l) => { try {
        return qh(e), o.invoke(i, s, a, c, l);
    }
    finally {
        e.shouldCoalesceRunChangeDetection && !e.callbackScheduled && !eN(c) && t(), Gh(e);
    } }, onHasTask: (o, r, i, s) => { o.hasTask(i, s), r === i && (s.change == "microTask" ? (e._hasPendingMicrotasks = s.microTask, fl(e), iu(e)) : s.change == "macroTask" && (e.hasPendingMacrotasks = s.macroTask)); }, onHandleError: (o, r, i, s) => (o.handleError(i, s), e.runOutsideAngular(() => e.onError.emit(s)), !1) }); }
function fl(e) { e._hasPendingMicrotasks || (e.shouldCoalesceEventChangeDetection || e.shouldCoalesceRunChangeDetection) && e.callbackScheduled === !0 ? e.hasPendingMicrotasks = !0 : e.hasPendingMicrotasks = !1; }
function qh(e) { e._nesting++, e.isStable && (e.isStable = !1, e.onUnstable.emit(null)); }
function Gh(e) { e._nesting--, iu(e); }
var rr = class {
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
function Xw(e) { return Dg(e, "__ignore_ng_zone__"); }
function eN(e) { return Dg(e, "__scheduler_tick__"); }
function Dg(e, t) { return !Array.isArray(e) || e.length !== 1 ? !1 : e[0]?.data?.[t] === !0; }
var Mt = class {
    _console = console;
    handleError(t) { this._console.error("ERROR", t); }
}, _t = new C("", { factory: () => { let e = E(G), t = E(be), n; return o => { e.runOutsideAngular(() => { t.destroyed && !n ? setTimeout(() => { throw o; }) : (n ??= t.get(Mt), n.handleError(o)); }); }; } }), su = { provide: Ge, useValue: () => { let e = E(Mt, { optional: !0 }); }, multi: !0 }, tN = new C("", { factory: () => { if (typeof ngServerMode < "u" && ngServerMode)
        return; let e = E(Nt).defaultView; if (!e)
        return; let t = E(_t), n = i => { t(i.reason), i.preventDefault(); }, o = i => { i.error ? t(i.error) : t(new Error(i.message, { cause: i })), i.preventDefault(); }, r = () => { e.addEventListener("unhandledrejection", n), e.addEventListener("error", o); }; typeof Zone < "u" ? Zone.root.run(r) : r(), E(Re).onDestroy(() => { e.removeEventListener("error", o), e.removeEventListener("unhandledrejection", n); }); } });
function nN() { return Le([Tl(() => { E(tN); })]); }
function oN(e) { return null; }
function mt(e, t) { let [n, o, r] = Ph(e, t?.equal), i = n, s = i[ae]; return i.set = o, i.update = r, i.asReadonly = ro.bind(i), i; }
function ro() { let e = this[ae]; if (e.readonlyFn === void 0) {
    let t = () => this();
    t[ae] = e, e.readonlyFn = t;
} return e.readonlyFn; }
var vt = new C("", { factory: () => rN }), rN = "ng";
var au = new C(""), iN = new C("", { providedIn: "platform", factory: () => "unknown" }), sN = new C(""), aN = new C("", { factory: () => E(Nt).body?.querySelector("[ngCspNonce]")?.getAttribute("ngCspNonce") || null }), Tg = { breakpoints: [16, 32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, 3840], placeholderResolution: 30, disableImageSizeWarning: !1, disableImageLazyLoadWarning: !1 }, cN = new C("", { factory: () => Tg });
function Cg(e) { return e; }
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
function cu(e, t) { let n = e.getElementById(t + "-state"); if (n?.textContent)
    try {
        return JSON.parse(n.textContent);
    }
    catch (o) {
        console.warn("Exception while restoring TransferState for app " + t, o);
    } return {}; }
function lN(e, t) { if (qi() !== null)
    throw new D(-602, !1); }
var io = (() => { class e {
    view;
    node;
    constructor(n, o) { this.view = n, this.node = o; }
    static __NG_ELEMENT_ID__ = uN;
} return e; })();
function uN() { return new io(g(), _()); }
var Ue = class {
}, so = new C("", { factory: () => !0 }), dN = new C("", { factory: () => !1 }), ws = new C(""), Ns = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new pl });
} return e; })(), pl = class {
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
}, ir = class {
    [ae];
    constructor(t) { this[ae] = t; }
    destroy() { this[ae].destroy(); }
};
function _s(e, t) { let n = t?.injector ?? E(oe), o = t?.manualCleanup !== !0 ? n.get(Re) : null, r, i = n.get(io, null, { optional: !0 }), s = n.get(Ue); return i !== null ? (r = hN(i.view, s, e), o instanceof Ji && o._lView === i.view && (o = null)) : r = gN(e, n.get(Ns), s), r.injector = n, o !== null && (r.onDestroyFns = [o.onDestroy(() => r.destroy())]), new ir(r); }
var Mg = Ie(q({}, Lh), { cleanupFns: void 0, zone: null, onDestroyFns: null, run() { let e = nr(!1); try {
        Fh(this);
    }
    finally {
        nr(e);
    } }, cleanup() { if (!this.cleanupFns?.length)
        return; let e = k(null); try {
        for (; this.cleanupFns.length;)
            this.cleanupFns.pop()();
    }
    finally {
        this.cleanupFns = [], k(e);
    } } }), fN = Ie(q({}, Mg), { consumerMarkedDirty() { this.scheduler.schedule(this), this.notifier.notify(12); }, destroy() { if ($t(this), this.onDestroyFns !== null)
        for (let e of this.onDestroyFns)
            e(); this.cleanup(), this.scheduler.remove(this); } }), pN = Ie(q({}, Mg), { consumerMarkedDirty() { this.view[w] |= 8192, En(this.view), this.notifier.notify(13); }, destroy() { if ($t(this), this.onDestroyFns !== null)
        for (let e of this.onDestroyFns)
            e(); this.cleanup(), this.view[qt]?.delete(this); } });
function hN(e, t, n) { let o = Object.create(pN); return o.view = e, o.zone = typeof Zone < "u" ? Zone.current : null, o.notifier = t, o.fn = wg(o, n), e[qt] ??= new Set, e[qt].add(o), o.consumerMarkedDirty(o), o; }
function gN(e, t, n) { let o = Object.create(fN); return o.fn = wg(o, e), o.scheduler = t, o.notifier = n, o.zone = typeof Zone < "u" ? Zone.current : null, o.scheduler.add(o), o.notifier.notify(12), o; }
function wg(e, t) { return () => { t(n => (e.cleanupFns ??= []).push(n)); }; }
function ao(e) { return typeof e == "function" && e[ae] !== void 0; }
function Ss(e) { return ao(e) && typeof e.set == "function"; }
var br = (() => { class e {
    internalPendingTasks = E(gt);
    scheduler = E(Ue);
    errorHandler = E(_t);
    add() { let n = this.internalPendingTasks.add(); return () => { this.internalPendingTasks.has(n) && (this.scheduler.notify(11), this.internalPendingTasks.remove(n)); }; }
    run(n) { let o = this.add(); n().catch(this.errorHandler).finally(o); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })();
import { setActiveConsumer as uo } from "@angular/core/primitives/signals";
import { Subject as zm, Subscription as mN } from "rxjs";
import { map as vN } from "rxjs/operators";
var co = { JSACTION: "jsaction" };
function Et(e) { return { toString: e }.toString(); }
function Qm(e, t, n, o) { t !== null ? t.applyValueToInputSignal(t, o) : e[n] = o; }
var Ks = class {
    previousValue;
    currentValue;
    firstChange;
    constructor(t, n, o) { this.previousValue = t, this.currentValue = n, this.firstChange = o; }
    isFirstChange() { return this.firstChange; }
}, Zm = (() => { let e = () => Ym; return e.ngInherit = !0, e; })();
function Ym(e) { return e.type.prototype.ngOnChanges && (e.setInput = EN), yN; }
function yN() { let e = Jm(this), t = e?.current; if (t) {
    let n = e.previous;
    if (n === wt)
        e.previous = t;
    else
        for (let o in t)
            n[o] = t[o];
    e.current = null, this.ngOnChanges(t);
} }
function EN(e, t, n, o, r) { let i = this.declaredInputs[o], s = Jm(e) || IN(e, { previous: wt, current: null }), a = s.current || (s.current = {}), c = s.previous, l = c[i]; a[i] = new Ks(l && l.currentValue, n, c === wt), Qm(e, t, r, n); }
var Km = "__ngSimpleChanges__";
function Jm(e) { return e[Km] || null; }
function IN(e, t) { return e[Km] = t; }
var Ng = [];
var V = function (e, t = null, n) { for (let o = 0; o < Ng.length; o++) {
    let r = Ng[o];
    r(e, t, n);
} }, P = (function (e) { return e[e.TemplateCreateStart = 0] = "TemplateCreateStart", e[e.TemplateCreateEnd = 1] = "TemplateCreateEnd", e[e.TemplateUpdateStart = 2] = "TemplateUpdateStart", e[e.TemplateUpdateEnd = 3] = "TemplateUpdateEnd", e[e.LifecycleHookStart = 4] = "LifecycleHookStart", e[e.LifecycleHookEnd = 5] = "LifecycleHookEnd", e[e.OutputStart = 6] = "OutputStart", e[e.OutputEnd = 7] = "OutputEnd", e[e.BootstrapApplicationStart = 8] = "BootstrapApplicationStart", e[e.BootstrapApplicationEnd = 9] = "BootstrapApplicationEnd", e[e.BootstrapComponentStart = 10] = "BootstrapComponentStart", e[e.BootstrapComponentEnd = 11] = "BootstrapComponentEnd", e[e.ChangeDetectionStart = 12] = "ChangeDetectionStart", e[e.ChangeDetectionEnd = 13] = "ChangeDetectionEnd", e[e.ChangeDetectionSyncStart = 14] = "ChangeDetectionSyncStart", e[e.ChangeDetectionSyncEnd = 15] = "ChangeDetectionSyncEnd", e[e.AfterRenderHooksStart = 16] = "AfterRenderHooksStart", e[e.AfterRenderHooksEnd = 17] = "AfterRenderHooksEnd", e[e.ComponentStart = 18] = "ComponentStart", e[e.ComponentEnd = 19] = "ComponentEnd", e[e.DeferBlockStateStart = 20] = "DeferBlockStateStart", e[e.DeferBlockStateEnd = 21] = "DeferBlockStateEnd", e[e.DynamicComponentStart = 22] = "DynamicComponentStart", e[e.DynamicComponentEnd = 23] = "DynamicComponentEnd", e[e.HostBindingsUpdateStart = 24] = "HostBindingsUpdateStart", e[e.HostBindingsUpdateEnd = 25] = "HostBindingsUpdateEnd", e; })(P || {});
function DN(e, t, n) { let { ngOnChanges: o, ngOnInit: r, ngDoCheck: i } = t.type.prototype; if (o) {
    let s = Ym(t);
    (n.preOrderHooks ??= []).push(e, s), (n.preOrderCheckHooks ??= []).push(e, s);
} r && (n.preOrderHooks ??= []).push(0 - e, r), i && ((n.preOrderHooks ??= []).push(e, i), (n.preOrderCheckHooks ??= []).push(e, i)); }
function Xm(e, t) { for (let n = t.directiveStart, o = t.directiveEnd; n < o; n++) {
    let i = e.data[n].type.prototype, { ngAfterContentInit: s, ngAfterContentChecked: a, ngAfterViewInit: c, ngAfterViewChecked: l, ngOnDestroy: u } = i;
    s && (e.contentHooks ??= []).push(-n, s), a && ((e.contentHooks ??= []).push(n, a), (e.contentCheckHooks ??= []).push(n, a)), c && (e.viewHooks ??= []).push(-n, c), l && ((e.viewHooks ??= []).push(n, l), (e.viewCheckHooks ??= []).push(n, l)), u != null && (e.destroyHooks ??= []).push(n, u);
} }
function Bs(e, t, n) { ev(e, t, 3, n); }
function $s(e, t, n, o) { (e[w] & 3) === n && ev(e, t, n, o); }
function lu(e, t) { let n = e[w]; (n & 3) === t && (n &= 16383, n += 1, e[w] = n); }
function ev(e, t, n, o) { let r = o !== void 0 ? e[gn] & 65535 : 0, i = o ?? -1, s = t.length - 1, a = 0; for (let c = r; c < s; c++)
    if (typeof t[c + 1] == "number") {
        if (a = t[c], o != null && a >= o)
            break;
    }
    else
        t[c] < 0 && (e[gn] += 65536), (a < i || i == -1) && (TN(e, n, t, c), e[gn] = (e[gn] & 4294901760) + c + 2), c++; }
function _g(e, t) { V(P.LifecycleHookStart, e, t); let n = k(null); try {
    t.call(e);
}
finally {
    k(n), V(P.LifecycleHookEnd, e, t);
} }
function TN(e, t, n, o) { let r = n[o] < 0, i = n[o + 1], s = r ? -n[o] : n[o], a = e[s]; r ? e[w] >> 14 < e[gn] >> 16 && (e[w] & 3) === t && (e[w] += 16384, _g(a, i)) : _g(a, i); }
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
function Na(e) { return e != null && typeof e == "object" && (e.insertBeforeIndex === null || typeof e.insertBeforeIndex == "number" || Array.isArray(e.insertBeforeIndex)); }
function tv(e) { return !!(e.type & 128); }
function CN(e) { return (e.flags & 8) !== 0; }
function MN(e) { return (e.flags & 16) !== 0; }
function wN(e, t, n) { let o = 0; for (; o < n.length;) {
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
        NN(i) ? e.setProperty(t, i, s) : e.setAttribute(t, i, s), o++;
    }
} return o; }
function nv(e) { return e === 3 || e === 4 || e === 6; }
function NN(e) { return e.charCodeAt(0) === 64; }
function To(e, t) { if (!(t === null || t.length === 0))
    if (e === null || e.length === 0)
        e = t.slice();
    else {
        let n = -1;
        for (let o = 0; o < t.length; o++) {
            let r = t[o];
            typeof r == "number" ? n = r : n === 0 || (n === -1 || n === 2 ? Sg(e, n, r, null, t[++o]) : Sg(e, n, r, null, null));
        }
    } return e; }
function Sg(e, t, n, o, r) { let i = 0, s = e.length; if (t === -1)
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
function ov(e) { return e !== vo; }
function Js(e) { return e & 32767; }
function _N(e) { return e >> 16; }
function Xs(e, t) { let n = _N(e), o = t; for (; n > 0;)
    o = o[hn], n--; return o; }
var xu = !0;
function ea(e) { let t = xu; return xu = e, t; }
var SN = 256, rv = SN - 1, iv = 5, bN = 0, yt = {};
function AN(e, t, n) { let o; typeof n == "string" ? o = n.charCodeAt(0) || 0 : n.hasOwnProperty(pn) && (o = n[pn]), o == null && (o = n[pn] = bN++); let r = o & rv, i = 1 << r; t.data[e + (r >> iv)] |= i; }
function ta(e, t) { let n = sv(e, t); if (n !== -1)
    return n; let o = t[m]; o.firstCreatePass && (e.injectorIndex = t.length, uu(o.data, e), uu(t, null), uu(o.blueprint, null)); let r = jd(e, t), i = e.injectorIndex; if (ov(r)) {
    let s = Js(r), a = Xs(r, t), c = a[m].data;
    for (let l = 0; l < 8; l++)
        t[i + l] = a[s + l] | c[s + l];
} return t[i + 8] = r, i; }
function uu(e, t) { e.push(0, 0, 0, 0, 0, 0, 0, 0, t); }
function sv(e, t) { return e.injectorIndex === -1 || e.parent && e.parent.injectorIndex === e.injectorIndex || t[e.injectorIndex + 8] === null ? -1 : e.injectorIndex; }
function jd(e, t) { if (e.parent && e.parent.injectorIndex !== -1)
    return e.parent.injectorIndex; let n = 0, o = null, r = t; for (; r !== null;) {
    if (o = fv(r), o === null)
        return vo;
    if (n++, r = r[hn], o.injectorIndex !== -1)
        return o.injectorIndex | n << 16;
} return vo; }
function Ou(e, t, n) { AN(e, t, n); }
function RN(e, t) { if (t === "class")
    return e.classes; if (t === "style")
    return e.styles; let n = e.attrs; if (n) {
    let o = n.length, r = 0;
    for (; r < o;) {
        let i = n[r];
        if (nv(i))
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
function av(e, t, n) { if (n & 8 || e !== void 0)
    return e; ss(t, "NodeInjector"); }
function cv(e, t, n, o) { if (n & 8 && o === void 0 && (o = null), (n & 3) === 0) {
    let r = e[x], i = Te(void 0);
    try {
        return r ? r.get(t, o, n & 8) : yl(t, o, n & 8);
    }
    finally {
        Te(i);
    }
} return av(o, t, n); }
function lv(e, t, n, o = 0, r) { if (e !== null) {
    if (t[w] & 2048 && !(o & 2)) {
        let s = PN(e, t, n, o, yt);
        if (s !== yt)
            return s;
    }
    let i = uv(e, t, n, o, yt);
    if (i !== yt)
        return i;
} return cv(t, n, o, r); }
function uv(e, t, n, o, r) { let i = xN(n); if (typeof i == "function") {
    if (!Zl(t, e, o))
        return o & 1 ? av(r, n, o) : cv(t, n, o, r);
    try {
        let s;
        if (s = i(o), s == null && !(o & 8))
            ss(n);
        else
            return s;
    }
    finally {
        Yl();
    }
}
else if (typeof i == "number") {
    let s = null, a = sv(e, t), c = vo, l = o & 1 ? t[re][ce] : null;
    for ((a === -1 || o & 4) && (c = a === -1 ? jd(e, t) : t[a + 8], c === vo || !Ag(o, !1) ? a = -1 : (s = t[m], a = Js(c), t = Xs(c, t))); a !== -1;) {
        let u = t[m];
        if (bg(i, a, u.data)) {
            let d = kN(a, t, n, s, o, l);
            if (d !== yt)
                return d;
        }
        c = t[a + 8], c !== vo && Ag(o, t[m].data[a + 8] === l) && bg(i, a, t) ? (s = u, a = Js(c), t = Xs(c, t)) : a = -1;
    }
} return r; }
function kN(e, t, n, o, r, i) { let s = t[m], a = s.data[e + 8], c = o == null ? Ce(a) && xu : o != s && (a.type & 3) !== 0, l = r & 1 && i === a, u = Us(a, s, n, c, l); return u !== null ? Wr(t, s, u, a, r) : yt; }
function Us(e, t, n, o, r) { let i = e.providerIndexes, s = t.data, a = i & 1048575, c = e.directiveStart, l = e.directiveEnd, u = i >> 20, d = o ? a : a + u, f = r ? a + u : l; for (let p = d; p < f; p++) {
    let h = s[p];
    if (p < c && n === h || p >= c && h.type === n)
        return p;
} if (r) {
    let p = s[c];
    if (p && Qe(p) && p.type === n)
        return c;
} return null; }
function Wr(e, t, n, o, r) { let i = e[n], s = t.data; if (i instanceof Nn) {
    let a = i;
    if (a.resolving)
        throw vl("");
    let c = ea(a.canSeeViewProviders);
    a.resolving = !0;
    let l = s[n].type || s[n], u, d = a.injectImpl ? Te(a.injectImpl) : null, f = Zl(e, o, 0);
    try {
        i = e[n] = a.factory(void 0, r, s, e, o), t.firstCreatePass && n >= o.directiveStart && DN(n, s[n], t);
    }
    finally {
        d !== null && Te(d), ea(c), a.resolving = !1, Yl();
    }
} return i; }
function xN(e) { if (typeof e == "string")
    return e.charCodeAt(0) || 0; let t = e.hasOwnProperty(pn) ? e[pn] : void 0; return typeof t == "number" ? t >= 0 ? t & rv : ON : t; }
function bg(e, t, n) { let o = 1 << e; return !!(n[t + (e >> iv)] & o); }
function Ag(e, t) { return !(e & 2) && !(e & 1 && t); }
function Vd(e) { return e._lView; }
function fi(e) { return e._tNode; }
var Me = class {
    _tNode;
    _lView;
    constructor(t, n) { this._tNode = t, this._lView = n; }
    get(t, n, o) { return lv(this._tNode, this._lView, t, un(o), n); }
};
function ON() { return new Me(_(), g()); }
function dv(e) { return Et(() => { let t = e.prototype.constructor, n = t[$e] || Pu(t), o = Object.prototype, r = Object.getPrototypeOf(e.prototype).constructor; for (; r && r !== o;) {
    let i = r[$e] || Pu(r);
    if (i && i !== n)
        return i;
    r = Object.getPrototypeOf(r);
} return i => new i; }); }
function Pu(e) { return lr(e) ? () => { let t = Pu(L(e)); return t && t(); } : Ut(e); }
function PN(e, t, n, o, r) { let i = e, s = t; for (; i !== null && s !== null && s[w] & 2048 && !lt(s);) {
    let a = uv(i, s, n, o | 2, yt);
    if (a !== yt)
        return a;
    let c = i.parent;
    if (!c) {
        let l = s[Nl];
        if (l) {
            let u = l.get(n, yt, o & -5);
            if (u !== yt)
                return u;
        }
        c = fv(s), s = s[hn];
    }
    i = c;
} return r; }
function fv(e) { let t = e[m], n = t.type; return n === 2 ? t.declTNode : n === 1 ? e[ce] : null; }
function _a(e) { return RN(_(), e); }
var LN = () => (typeof requestIdleCallback < "u" ? requestIdleCallback : e => setTimeout(e)).bind(globalThis), FN = () => (typeof requestIdleCallback < "u" ? cancelIdleCallback : clearTimeout).bind(globalThis), Sa = new C("", { factory: () => new Lu });
function jN(e) { return Le([{ provide: Sa, useExisting: e }]); }
var Lu = class {
    requestIdleCallback = LN();
    cancelIdleCallback = FN();
    requestOnIdle(t, n) { return this.requestIdleCallback(t, n); }
    cancelOnIdle(t) { return this.cancelIdleCallback(t); }
}, fo = "__annotations__", po = "__parameters__", ho = "__prop__metadata__";
function Ro(e, t, n, o, r) { return Et(() => { let i = Hd(t); function s(...a) { if (this instanceof s)
    return i.call(this, ...a), this; let c = new s(...a); return function (u) { return r && r(u, ...a), (u.hasOwnProperty(fo) ? u[fo] : Object.defineProperty(u, fo, { value: [] })[fo]).push(c), u; }; } return n && (s.prototype = Object.create(n.prototype)), s.prototype.ngMetadataName = e, s.annotationCls = s, s; }); }
function Hd(e) { return function (...n) { if (e) {
    let o = e(...n);
    for (let r in o)
        this[r] = o[r];
} }; }
function ko(e, t, n) { return Et(() => { let o = Hd(t); function r(...i) { if (this instanceof r)
    return o.apply(this, i), this; let s = new r(...i); return a.annotation = s, a; function a(c, l, u) { let d = c.hasOwnProperty(po) ? c[po] : Object.defineProperty(c, po, { value: [] })[po]; for (; d.length <= u;)
    d.push(null); return (d[u] = d[u] || []).push(s), c; } } return r.prototype.ngMetadataName = e, r.annotationCls = r, r; }); }
function Ot(e, t, n, o) { return Et(() => { let r = Hd(t); function i(...s) { if (this instanceof i)
    return r.apply(this, s), this; let a = new i(...s); function c(l, u) { if (l === void 0)
    throw new Error("Standard Angular field decorators are not supported in JIT mode."); let d = l.constructor, f = d.hasOwnProperty(ho) ? d[ho] : Object.defineProperty(d, ho, { value: {} })[ho]; f[u] = f.hasOwnProperty(u) && f[u] || [], f[u].unshift(a); } return c; } return n && (i.prototype = Object.create(n.prototype)), i.prototype.ngMetadataName = e, i.annotationCls = i, i; }); }
function X(e) { let t = Pe.ng; if (t && t.\u0275compilerFacade)
    return t.\u0275compilerFacade; throw new Error("JIT compiler unavailable"); }
function Pt(e) { return { token: e.token, providedIn: e.autoProvided === !1 ? null : "root", factory: e.factory, value: void 0 }; }
var na = { \u0275\u0275defineInjectable: Y, \u0275\u0275defineInjector: ur, \u0275\u0275defineService: Pt, \u0275\u0275inject: he, \u0275\u0275invalidFactoryDep: as, resolveForwardRef: L }, pv = Function;
function bs(e) { return typeof e == "function"; }
var VN = /^function\s+\S+\(\)\s*{[\s\S]+\.apply\(this,\s*(arguments|(?:[^()]+\(\[\],)?[^()]+\(arguments\).*)\)/, HN = /^class\s+[A-Za-z\d$_]*\s*extends\s+[^{]+{/, BN = /^class\s+[A-Za-z\d$_]*\s*extends\s+[^{]+{[\s\S]*constructor\s*\(/, $N = /^class\s+[A-Za-z\d$_]*\s*extends\s+[^{]+{[\s\S]*constructor\s*\(\)\s*{[^}]*super\(\.\.\.arguments\)/;
function UN(e) { return VN.test(e) || $N.test(e) || HN.test(e) && !BN.test(e); }
var oa = class {
    _reflect;
    constructor(t) { this._reflect = t || Pe.Reflect; }
    factory(t) { return (...n) => new t(...n); }
    _zipTypesAndAnnotations(t, n) { let o; typeof t > "u" ? o = vr(n.length) : o = vr(t.length); for (let r = 0; r < o.length; r++)
        typeof t > "u" ? o[r] = [] : t[r] && t[r] != Object ? o[r] = [t[r]] : o[r] = [], n && n[r] != null && (o[r] = o[r].concat(n[r])); return o; }
    _ownParameters(t, n) { let o = t.toString(); if (UN(o))
        return null; if (t.parameters && t.parameters !== n.parameters)
        return t.parameters; let r = t.ctorParameters; if (r && r !== n.ctorParameters) {
        let a = typeof r == "function" ? r() : r, c = a.map(u => u && u.type), l = a.map(u => u && du(u.decorators));
        return this._zipTypesAndAnnotations(c, l);
    } let i = t.hasOwnProperty(po) && t[po], s = this._reflect && this._reflect.getOwnMetadata && this._reflect.getOwnMetadata("design:paramtypes", t); return s || i ? this._zipTypesAndAnnotations(s, i) : vr(t.length); }
    parameters(t) { if (!bs(t))
        return []; let n = As(t), o = this._ownParameters(t, n); return !o && n !== Object && (o = this.parameters(n)), o || []; }
    _ownAnnotations(t, n) { if (t.annotations && t.annotations !== n.annotations) {
        let o = t.annotations;
        return typeof o == "function" && o.annotations && (o = o.annotations), o;
    } return t.decorators && t.decorators !== n.decorators ? du(t.decorators) : t.hasOwnProperty(fo) ? t[fo] : null; }
    annotations(t) { if (!bs(t))
        return []; let n = As(t), o = this._ownAnnotations(t, n) || []; return (n !== Object ? this.annotations(n) : []).concat(o); }
    _ownPropMetadata(t, n) { if (t.propMetadata && t.propMetadata !== n.propMetadata) {
        let o = t.propMetadata;
        return typeof o == "function" && o.propMetadata && (o = o.propMetadata), o;
    } if (t.propDecorators && t.propDecorators !== n.propDecorators) {
        let o = t.propDecorators, r = {};
        return Object.keys(o).forEach(i => { r[i] = du(o[i]); }), r;
    } return t.hasOwnProperty(ho) ? t[ho] : null; }
    propMetadata(t) { if (!bs(t))
        return {}; let n = As(t), o = {}; if (n !== Object) {
        let i = this.propMetadata(n);
        Object.keys(i).forEach(s => { o[s] = i[s]; });
    } let r = this._ownPropMetadata(t, n); return r && Object.keys(r).forEach(i => { let s = []; o.hasOwnProperty(i) && s.push(...o[i]), s.push(...r[i]), o[i] = s; }), o; }
    ownPropMetadata(t) { return bs(t) ? this._ownPropMetadata(t, As(t)) || {} : {}; }
    hasLifecycleHook(t, n) { return t instanceof pv && n in t.prototype; }
};
function du(e) { return e ? e.map(t => { let o = t.type.annotationCls, r = t.args ? t.args : []; return new o(...r); }) : []; }
function As(e) { let t = e.prototype ? Object.getPrototypeOf(e.prototype) : null; return (t ? t.constructor : null) || Object; }
var hv = Yn(ko("Inject", e => ({ token: e })), -1), gv = Yn(ko("Optional"), 8), mv = Yn(ko("Self"), 2), vv = Yn(ko("SkipSelf"), 4), yv = Yn(ko("Host"), 1), Ev = ko("Attribute", e => ({ attributeName: e, __NG_ELEMENT_ID__: () => _a(e) })), Rg = null;
function Bd() { return Rg = Rg || new oa; }
function pi(e) { return Iv(Bd().parameters(e)); }
function Iv(e) { return e.map(t => qN(t)); }
function qN(e) { let t = { token: null, attribute: null, host: !1, optional: !1, self: !1, skipSelf: !1 }; if (Array.isArray(e) && e.length > 0)
    for (let n = 0; n < e.length; n++) {
        let o = e[n];
        if (o === void 0)
            continue;
        let r = Object.getPrototypeOf(o);
        if (o instanceof gv || r.ngMetadataName === "Optional")
            t.optional = !0;
        else if (o instanceof vv || r.ngMetadataName === "SkipSelf")
            t.skipSelf = !0;
        else if (o instanceof mv || r.ngMetadataName === "Self")
            t.self = !0;
        else if (o instanceof yv || r.ngMetadataName === "Host")
            t.host = !0;
        else if (o instanceof hv)
            t.token = o.token;
        else if (o instanceof Ev) {
            if (o.attributeName === void 0)
                throw new D(-204, !1);
            t.attribute = o.attributeName;
        }
        else
            t.token = o;
    }
else
    e === void 0 || Array.isArray(e) && e.length === 0 ? t.token = null : t.token = e; return t; }
function GN(e, t) { let n = null, o = null; e.hasOwnProperty(Wt) || Object.defineProperty(e, Wt, { get: () => (n === null && (n = X({ usage: 0, kind: "injectable", type: e }).compileInjectable(na, `ng:///${e.name}/\u0275prov.js`, ZN(e, t))), n) }), e.hasOwnProperty($e) || Object.defineProperty(e, $e, { get: () => { if (o === null) {
        let r = X({ usage: 0, kind: "injectable", type: e });
        o = r.compileFactory(na, `ng:///${e.name}/\u0275fac.js`, { name: e.name, type: e, typeArgumentCount: 0, deps: pi(e), target: r.FactoryTarget.Injectable });
    } return o; }, configurable: !0 }); }
var WN = j({ provide: String, useValue: j });
function kg(e) { return e.useClass !== void 0; }
function zN(e) { return WN in e; }
function xg(e) { return e.useFactory !== void 0; }
function QN(e) { return e.useExisting !== void 0; }
function ZN(e, t) { let n = t || { providedIn: null }, o = { name: e.name, type: e, typeArgumentCount: 0, providedIn: n.providedIn }; return (kg(n) || xg(n)) && n.deps !== void 0 && (o.deps = Iv(n.deps)), kg(n) ? o.useClass = n.useClass : zN(n) ? o.useValue = n.useValue : xg(n) ? o.useFactory = n.useFactory : QN(n) && (o.useExisting = n.useExisting), o; }
var YN = Ro("Injectable", void 0, void 0, void 0, (e, t) => GN(e, t));
function KN(e, t) { let n = null, o = null; e.hasOwnProperty(Wt) || Object.defineProperty(e, Wt, { get: () => (n === null && (n = X({ usage: 0, kind: "service", type: e }).compileService(na, `ng:///${e.name}/\u0275prov.js`, JN(e, t))), n) }), e.hasOwnProperty($e) || Object.defineProperty(e, $e, { get: () => { if (o === null) {
        let r = X({ usage: 0, kind: "service", type: e });
        o = r.compileFactory(na, `ng:///${e.name}/\u0275fac.js`, { name: e.name, type: e, typeArgumentCount: 0, deps: pi(e), target: r.FactoryTarget.Service });
    } return o; }, configurable: !0 }); }
function JN(e, t) { return { name: e.name, type: e, typeArgumentCount: 0, autoProvided: t?.autoProvided, factory: t?.factory }; }
var XN = Ro("Service", void 0, void 0, void 0, (e, t) => KN(e, t));
function e_() { return xo(_(), g()); }
function xo(e, t) { return new hi(ie(e, t)); }
var hi = (() => { class e {
    nativeElement;
    constructor(n) { this.nativeElement = n; }
    static __NG_ELEMENT_ID__ = e_;
} return e; })();
function Dv(e) { return e instanceof hi ? e.nativeElement : e; }
function t_() { return this._results[Symbol.iterator](); }
var ra = class {
    _emitDistinctChangesOnly;
    dirty = !0;
    _onDirty = void 0;
    _results = [];
    _changesDetected = !1;
    _changes = void 0;
    length = 0;
    first = void 0;
    last = void 0;
    get changes() { return this._changes ??= new zm; }
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
    reset(t, n) { this.dirty = !1; let o = nt(t); (this._changesDetected = !Yh(this._results, o, n)) && (this._results = o, this.length = o.length, this.last = o[this.length - 1], this.first = o[0]); }
    notifyOnChanges() { this._changes !== void 0 && (this._changesDetected || !this._emitDistinctChangesOnly) && this._changes.next(this); }
    onDirty(t) { this._onDirty = t; }
    setDirty() { this.dirty = !0, this._onDirty?.(); }
    destroy() { this._changes !== void 0 && (this._changes.complete(), this._changes.unsubscribe()); }
    [Symbol.iterator] = t_;
}, jn = "ngSkipHydration", n_ = "ngskiphydration";
function $d(e) { let t = e.mergedAttrs; if (t === null)
    return !1; for (let n = 0; n < t.length; n += 2) {
    let o = t[n];
    if (typeof o == "number")
        return !1;
    if (typeof o == "string" && o.toLowerCase() === n_)
        return !0;
} return !1; }
function Tv(e) { return e.hasAttribute(jn); }
function zr(e) { return (e.flags & 128) === 128; }
function Oo(e) { if (zr(e))
    return !0; let t = e.parent; for (; t;) {
    if (zr(e) || $d(t))
        return !0;
    t = t.parent;
} return !1; }
function Cv(e) { return zr(e) || $d(e) || Oo(e); }
var ba = (function (e) { return e[e.OnPush = 0] = "OnPush", e[e.Eager = 1] = "Eager", e[e.Default = 1] = "Default", e; })(ba || {}), Aa = new Map, o_ = 0;
function r_() { return o_++; }
function i_(e) { Aa.set(e[Fe], e); }
function Mv(e) { return Aa.get(e) || null; }
function Fu(e) { Aa.delete(e[Fe]); }
function s_() { return Aa; }
var ia = class {
    lViewId;
    nodeIndex;
    native;
    component;
    directives;
    localRefs;
    get lView() { return Mv(this.lViewId); }
    constructor(t, n, o) { this.lViewId = t, this.nodeIndex = n, this.native = o; }
};
function we(e) { let t = qs(e); if (t) {
    if (J(t)) {
        let n = t, o, r, i;
        if (wv(e)) {
            if (o = u_(n, e), o == -1)
                throw new Error("The provided component was not found in the application");
            r = e;
        }
        else if (c_(e)) {
            if (o = d_(n, e), o == -1)
                throw new Error("The provided directive was not found in the application");
            i = Nv(o, n);
        }
        else if (o = Pg(n, e), o == -1)
            return null;
        let s = O(n[o]), a = qs(s), c = a && !Array.isArray(a) ? a : Og(n, o, s);
        if (r && c.component === void 0 && (c.component = r, Ze(c.component, c)), i && c.directives === void 0) {
            c.directives = i;
            for (let l = 0; l < i.length; l++)
                Ze(i[l], c);
        }
        Ze(c.native, c), t = c;
    }
}
else {
    let n = e, o = n;
    for (; o = o.parentNode;) {
        let r = qs(o);
        if (r) {
            let i = Array.isArray(r) ? r : r.lView;
            if (!i)
                return null;
            let s = Pg(i, n);
            if (s >= 0) {
                let a = O(i[s]), c = Og(i, s, a);
                Ze(a, c), t = c;
                break;
            }
        }
    }
} return t || null; }
function Og(e, t, n) { return new ia(e[Fe], t, n); }
var ju = "__ngContext__";
function Ze(e, t) { J(t) ? (e[ju] = t[Fe], i_(t)) : e[ju] = t; }
function qs(e) { let t = e[ju]; return typeof t == "number" ? Mv(t) : t || null; }
function a_(e) { let t = qs(e); return t ? J(t) ? t : t.lView : null; }
function wv(e) { return e && e.constructor && e.constructor.\u0275cmp; }
function c_(e) { return e && e.constructor && e.constructor.\u0275dir; }
function Pg(e, t) { let n = e[m]; for (let o = I; o < n.bindingStartIndex; o++)
    if (O(e[o]) === t)
        return o; return -1; }
function l_(e) { if (e.child)
    return e.child; if (e.next)
    return e.next; for (; e.parent && !e.parent.next;)
    e = e.parent; return e.parent && e.parent.next; }
function u_(e, t) { let n = e[m].components; if (n)
    for (let o = 0; o < n.length; o++) {
        let r = n[o];
        if (me(r, e)[B] === t)
            return r;
    }
else if (me(I, e)[B] === t)
    return I; return -1; }
function d_(e, t) { let n = e[m].firstChild; for (; n;) {
    let o = n.directiveStart, r = n.directiveEnd;
    for (let i = o; i < r; i++)
        if (e[i] === t)
            return n.index;
    n = l_(n);
} return -1; }
function Nv(e, t) { let n = t[m].data[e]; if (n.directiveStart === 0)
    return F; let o = []; for (let r = n.directiveStart; r < n.directiveEnd; r++) {
    let i = t[r];
    wv(i) || o.push(i);
} return o; }
function f_(e, t) { let n = t[m].data[e]; return Ce(n) ? t[n.directiveStart + n.componentOffset] : null; }
function p_(e, t) { let n = e[m].data[t]; if (n && n.localNames) {
    let o = {}, r = n.index + 1;
    for (let i = 0; i < n.localNames.length; i += 2)
        o[n.localNames[i]] = e[r], r++;
    return o;
} return null; }
function _v(e) { return bv(e[Qt]); }
function Sv(e) { return bv(e[ge]); }
function bv(e) { for (; e !== null && !K(e);)
    e = e[ge]; return e; }
function* h_(e, t) { let n = e.child; for (; n;)
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
function* g_(e) { let n = e[m].firstChild; for (; n;)
    yield* Zc(Av(n, e)), n = n.next; }
function* Av(e, t) { yield [e, t]; for (let [n, o] of h_(e, t))
    yield* Zc(Av(n, o)); }
function* Ud(e) { for (let [t, n] of g_(e))
    t.directiveEnd > t.directiveStart && (yield [t, n]); }
function Lg(e) { let t = we(e); if (t === null)
    return null; if (t.component === void 0) {
    let n = t.lView;
    if (n === null)
        return null;
    t.component = f_(t.nodeIndex, n);
} return t.component; }
function m_(e) { w_(e); let t = we(e), n = t ? t.lView : null; return n === null ? null : n[B]; }
function v_(e) { let t = we(e), n = t ? t.lView : null; if (n === null)
    return null; let o; for (; n[m].type === 2 && (o = et(n));)
    n = o; return lt(n) ? null : n[B]; }
function qd(e) { let t = we(e), n = t ? t.lView : null; if (n === null)
    return oe.NULL; let o = n[m].data[t.nodeIndex]; return new Me(o, n); }
function y_(e) { let t = we(e), n = t ? t.lView : null; if (n === null)
    return []; let o = n[m], r = o.data[t.nodeIndex], i = [], s = r.providerIndexes & 1048575, a = r.directiveEnd; for (let c = s; c < a; c++) {
    let l = o.data[c];
    M_(l) && (l = l.type), i.push(l);
} return i; }
function E_(e) { if (e instanceof Text)
    return []; let t = we(e), n = t ? t.lView : null; if (n === null)
    return []; let o = n[m], r = t.nodeIndex; return o?.data[r] ? (t.directives === void 0 && (t.directives = Nv(r, n)), t.directives === null ? [] : [...t.directives]) : []; }
var Rv = (function (e) { return e[e.Default = 0] = "Default", e[e.OnPush = 1] = "OnPush", e; })(Rv || {}), kv = (function (e) { return e[e.Emulated = 0] = "Emulated", e[e.None = 1] = "None", e; })(kv || {});
function I_(e) { let t = we(e); if (t === null)
    return {}; if (t.localRefs === void 0) {
    let n = t.lView;
    if (n === null)
        return {};
    t.localRefs = p_(n, t.nodeIndex);
} return t.localRefs || {}; }
function D_(e) { return we(e).native; }
function T_(e) { let t = we(e), n = t === null ? null : t.lView; if (n === null)
    return []; let o = n[m], r = n[zt], i = o.cleanup, s = []; if (i && r)
    for (let a = 0; a < i.length;) {
        let c = i[a++], l = i[a++];
        if (typeof c == "string") {
            let u = c, d = O(n[l]), f = r[i[a++]], p = i[a++], h = typeof p == "boolean" || p >= 0 ? "dom" : "output", v = typeof p == "boolean" ? p : !1;
            e == d && s.push({ element: e, name: u, callback: f, useCapture: v, type: h });
        }
    } return s.sort(C_), s; }
function C_(e, t) { return e.name == t.name ? 0 : e.name < t.name ? -1 : 1; }
function M_(e) { return e.type !== void 0 && e.declaredInputs !== void 0 && e.resolveHostDirectives !== void 0; }
function w_(e) { if (typeof Element < "u" && !(e instanceof Element))
    throw new Error("Expecting instance of DOM Element"); }
var Vu;
function N_(e) { Vu = e; }
function gi() { if (Vu !== void 0)
    return Vu; if (typeof document < "u")
    return document; throw new D(210, !1); }
var Gd = "h", Wd = "b", xv = "f", Ov = "n", mi = "e", Ra = "t", Po = "c", vi = "x", kt = "r", ka = "i", yi = "n", Lo = "d", xa = "l", Oa = "di", Ei = "s", zd = "p", Ii = "t", Vn = new C(""), Pv = !1, Qd = new C("", { factory: () => Pv }), Zd = new C(""), Pa = new C(""), Yd = !1, Lv = new C("", { factory: () => [] }), Kd = new C(""), Di = new C("", { factory: () => new Map }), __ = new C(""), sa = { passive: !0, capture: !0 }, fu = new WeakMap, pu = new WeakMap, en = new WeakMap, aa = ["click", "keydown"], ca = ["mouseenter", "mouseover", "focusin"], Rs = new Map, Qr = class {
    callbacks = new Set;
    listener = () => { for (let t of this.callbacks)
        t(); };
};
function Fv(e, t) { let n = pu.get(e); if (!n) {
    n = new Qr, pu.set(e, n);
    for (let o of aa)
        e.addEventListener(o, n.listener, sa);
} return n.callbacks.add(t), () => { let { callbacks: o, listener: r } = n; if (o.delete(t), o.size === 0) {
    pu.delete(e);
    for (let i of aa)
        e.removeEventListener(i, r, sa);
} }; }
function jv(e, t) { let n = fu.get(e); if (!n) {
    n = new Qr, fu.set(e, n);
    for (let o of ca)
        e.addEventListener(o, n.listener, sa);
} return n.callbacks.add(t), () => { let { callbacks: o, listener: r } = n; if (o.delete(t), o.size === 0) {
    for (let i of ca)
        e.removeEventListener(i, r, sa);
    fu.delete(e);
} }; }
function S_(e) { let t = Vv(e); return new IntersectionObserver(n => { for (let o of n)
    o.isIntersecting && en.has(o.target) && en.get(o.target)?.get(t)?.listener(); }, e); }
function b_(e, t, n, o) { let r = Vv(o), i = en.get(e)?.get(r); Rs.has(r) || Rs.set(r, { observer: n(o), count: 0 }); let s = Rs.get(r); if (!i) {
    i = new Qr, s.observer.observe(e);
    let a = en.get(e);
    a ? a.set(r, i) : (a = new Map, en.set(e, a)), a.set(r, i), s.count++;
} return i.callbacks.add(t), () => { if (en.get(e)?.has(r)) {
    if (i.callbacks.delete(t), i.callbacks.size === 0) {
        s.observer.unobserve(e), s.count--;
        let a = en.get(e);
        a && (a.delete(r), a.size === 0 && en.delete(e));
    }
    s.count === 0 && (s.observer.disconnect(), Rs.delete(r));
} }; }
function Vv(e) {
    return e ? `${e.rootMargin}/${typeof e.threshold == "number" ? e.threshold : e.threshold?.join(`
`)}` : "";
}
var Fo = "ngb";
function Jd(e, t, n = null) { if (t.length === 0 || e.nodeType !== Node.ELEMENT_NODE)
    return; let o = e.getAttribute(co.JSACTION), r = t.reduce((s, a) => (o?.indexOf(a) ?? -1) === -1 ? s + a + ":;" : s, ""); e.setAttribute(co.JSACTION, `${o ?? ""}${r}`); let i = n ?? ""; i !== "" && r.length > 0 && e.setAttribute(Fo, i); }
var Hv = (e, t, n) => { let o = e, r = o.__jsaction_fns ?? new Map, i = r.get(t) ?? []; i.push(n), r.set(t, i), o.__jsaction_fns = r; }, Xd = (e, t) => { let n = e, o = n.getAttribute(Fo) ?? "", r = t.get(o) ?? new Set; r.has(n) || r.add(n), t.set(o, r); };
function A_(e, t) { if (e.length > 0) {
    let n = [];
    for (let r of e)
        t.has(r) && (n = [...n, ...t.get(r)]);
    new Set(n).forEach(ef);
} }
var ef = e => { e.removeAttribute(co.JSACTION), e.removeAttribute(Fo), e.__jsaction_fns = void 0; }, tf = new C("", { factory: () => ({}) }), Hu = new WeakMap;
function R_(e, t) { if (e == null || typeof e != "object")
    return; let n = Hu.get(e); n || (n = new WeakSet, Hu.set(e, n)), n.add(t); }
function nf(e, t) { let n = t?.__jsaction_fns?.get(e.type); if (!(!n || !t?.isConnected) && !(t && Hu.get(e)?.has(t)))
    for (let o of n)
        o(e); }
var Bu = new Map;
function Bv(e, t) { return Bu.set(e, t), () => Bu.delete(e); }
var Fg = !1, $v = (e, t, n, o) => { };
function k_(e, t, n, o) { $v(e, t, n, o); }
function Uv() { Fg || ($v = (e, t, n, o) => { let r = e[x].get(vt); Bu.get(r)?.(t, n, o); }, Fg = !0); }
var Lt = new C(""), x_ = (() => { class e {
    registry = new Map;
    cleanupFns = new Map;
    jsActionMap = E(Di);
    contract = E(tf);
    add(n, o) { if (this.registry.set(n, o), this.awaitingCallbacks.has(n)) {
        let r = this.awaitingCallbacks.get(n);
        for (let i of r)
            i();
    } }
    get(n) { return this.registry.get(n) ?? null; }
    has(n) { return this.registry.has(n); }
    cleanup(n) { A_(n, this.jsActionMap); for (let o of n)
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
function jo(e) { return (e.flags & 32) === 32; }
var qv = "__nghData__", La = qv, Gv = "__nghDeferData__", Fa = Gv;
function O_(e) { return e === qv || e === Gv; }
var yo = "ngh", Wv = "nghm", zv = () => null;
function P_(e, t, n = !1) { let o = e.getAttribute(yo); if (o == null)
    return null; let [r, i] = o.split("|"); if (o = n ? i : r, !o)
    return null; let s = i ? `|${i}` : "", a = n ? r : s, c = {}; if (o !== "") {
    let u = t.get(St, null, { optional: !0 });
    u !== null && (c = u.get(La, [])[Number(o)]);
} let l = { data: c, firstChild: e.firstChild ?? null }; return n && (l.firstChild = e, ja(l, 0, e.nextSibling)), a ? e.setAttribute(yo, a) : e.removeAttribute(yo), l; }
function Qv() { zv = P_; }
function Zv(e, t, n = !1) { return zv(e, t, n); }
function of(e) { let t = e._lView; return t[m].type === 2 ? null : (lt(t) && (t = t[I]), t); }
function L_(e) { return e.textContent?.replace(/\s/gm, ""); }
function F_(e) { let t = gi(), n = t.createNodeIterator(e, NodeFilter.SHOW_COMMENT, { acceptNode(i) { let s = L_(i); return s === "ngetn" || s === "ngtns" ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } }), o, r = []; for (; o = n.nextNode();)
    r.push(o); for (let i of r)
    i.textContent === "ngetn" ? i.replaceWith(t.createTextNode("")) : i.remove(); }
var Yv = (function (e) { return e.Hydrated = "hydrated", e.Skipped = "skipped", e.Mismatched = "mismatched", e; })(Yv || {}), j_ = "__ngDebugHydrationInfo__";
function V_(e) { return e[j_] ?? null; }
function ja(e, t, n) { e.segmentHeads ??= {}, e.segmentHeads[t] = n; }
function $u(e, t) { return e.segmentHeads?.[t] ?? null; }
function Ti(e) { return e.get(Kd, !1, { optional: !0 }); }
var H_ = !1;
function B_() { H_ = !1; }
function Kv(e, t) { let n = e.data, o = n[mi]?.[t] ?? null; return o === null && n[Po]?.[t] && (o = rf(e, t)), o; }
function $_(e, t) { return e.data[mi]?.[t] !== void 0; }
function Jv(e, t) { return e.data[Po]?.[t] ?? null; }
function rf(e, t) { let n = Jv(e, t) ?? [], o = 0; for (let r of n)
    o += r[kt] * (r[vi] ?? 1); return o; }
function Xv(e) { if (typeof e.disconnectedNodes > "u") {
    let t = e.data[Lo];
    e.disconnectedNodes = t ? new Set(t) : null;
} return e.disconnectedNodes; }
function Va(e, t) { if (typeof e.disconnectedNodes > "u") {
    let n = e.data[Lo];
    e.disconnectedNodes = n ? new Set(n) : null;
} return !!Xv(e)?.has(t); }
function Ha(e, t) { let n = e[fe]; return n !== null && !Nr() && !jo(t) && !Va(n, t.index - I); }
function sf(e, t) { let n = t, o = e.corruptedTextNodes; n.textContent === "" ? o.set(n, "ngetn") : n.nextSibling?.nodeType === Node.TEXT_NODE && o.set(n, "ngtns"); }
function ey(e) { let t = []; return e !== null && (e.has(4) && t.push(...ca), e.has(3) && t.push(...aa)), t; }
function U_(e, t) { let n = t.get(Lt), r = t.get(St).get(Fa, {}), i = !1, s = e, a = null, c = []; for (; !i && s;) {
    i = n.has(s);
    let l = n.hydrating.get(s);
    if (a === null && l != null) {
        a = l.promise;
        break;
    }
    c.unshift(s), s = r[s][zd];
} return { parentBlockPromise: a, hydrationQueue: c }; }
function q_(e) { let t = e.body.querySelectorAll("[jsaction]"), n = new Set, o = [ca.join(":;"), aa.join(":;")].join("|"); for (let r of t) {
    let i = r.getAttribute("jsaction"), s = r.getAttribute("ngb");
    i?.match(o) && s !== null && n.add(r);
} return n; }
function G_(e, t) { let n = q_(e), o = t.get(Di); for (let r of n)
    Xd(r, o); }
var ty = () => ({});
function W_(e) { let t = e.get(St, null, { optional: !0 }); return t !== null ? t.get(Fa, {}) : {}; }
function z_() { ty = W_; }
function Q_(e) { return ty(e); }
function Z_(e) { return typeof e == "object" && e.trigger === 5; }
function Y_(e) { return e[Ii]?.find(n => Z_(n))?.delay ?? null; }
function K_(e) { let t = e[Ii]; if (t)
    for (let n of t) {
        if (n === 2)
            return !0;
        if (typeof n == "object" && n.trigger === 2)
            return n.intersectionObserverOptions || !0;
    } return null; }
function jg(e, t) { return e[Ii]?.includes(t) ?? !1; }
function J_(e) { return { data: e, hydrate: { idle: jg(e, 0), immediate: jg(e, 1), timer: Y_(e), viewport: K_(e) } }; }
function X_(e) { let t = Q_(e), n = new Map; for (let o in t)
    n.set(o, J_(t[o])); return n; }
function hu(e) { return !!e && e.nodeType === Node.COMMENT_NODE && e.textContent?.trim() === Wv; }
function Vg(e) { for (; e && e.nodeType === Node.TEXT_NODE;)
    e = e.previousSibling; return e; }
function ny(e) { for (let o of e.body.childNodes)
    if (hu(o))
        return; let t = Vg(e.body.previousSibling); if (hu(t))
    return; let n = Vg(e.head.lastChild); if (!hu(n))
    throw new D(-507, !1); }
function oy(e, t) { let n = e.contentQueries; if (n !== null) {
    let o = k(null);
    try {
        for (let r = 0; r < n.length; r += 2) {
            let i = n[r], s = n[r + 1];
            if (s !== -1) {
                let a = e.data[s];
                _r(i), a.contentQueries(2, t[s], s);
            }
        }
    }
    finally {
        k(o);
    }
} }
function Uu(e, t, n) { _r(0); let o = k(null); try {
    t(e, n);
}
finally {
    k(o);
} }
function af(e, t, n) { if (Sl(t)) {
    let o = k(null);
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
        k(o);
    }
} }
var Ye = (function (e) { return e[e.Emulated = 0] = "Emulated", e[e.None = 2] = "None", e[e.ShadowDom = 3] = "ShadowDom", e[e.ExperimentalIsolatedShadowDom = 4] = "ExperimentalIsolatedShadowDom", e; })(Ye || {}), eS = { name: "custom-elements" }, tS = { name: "no-errors-schema" }, ry = !1;
function nS(e) { ry = e; }
function oS() { return ry; }
var iy = !1;
function rS(e) { iy = e; }
function iS() { return iy; }
var ks;
function sy() { if (ks === void 0 && (ks = null, Pe.trustedTypes))
    try {
        ks = Pe.trustedTypes.createPolicy("angular", { createHTML: e => e, createScript: e => e, createScriptURL: e => e });
    }
    catch { } return ks; }
function Vo(e) { return sy()?.createHTML(e) || e; }
function sS(e) { return sy()?.createScriptURL(e) || e; }
var xs;
function cf() { if (xs === void 0 && (xs = null, Pe.trustedTypes))
    try {
        xs = Pe.trustedTypes.createPolicy("angular#unsafe-bypass", { createHTML: e => e, createScript: e => e, createScriptURL: e => e });
    }
    catch { } return xs; }
function Hg(e) { return cf()?.createHTML(e) || e; }
function Bg(e) { return cf()?.createScript(e) || e; }
function $g(e) { return cf()?.createScriptURL(e) || e; }
var xt = class {
    changingThisBreaksApplicationSecurity;
    constructor(t) { this.changingThisBreaksApplicationSecurity = t; }
    toString() { return `SafeValue must use [property]=binding: ${this.changingThisBreaksApplicationSecurity} (see ${ts})`; }
}, qu = class extends xt {
    getTypeName() { return "HTML"; }
}, Gu = class extends xt {
    getTypeName() { return "Style"; }
}, Wu = class extends xt {
    getTypeName() { return "Script"; }
}, zu = class extends xt {
    getTypeName() { return "URL"; }
}, Qu = class extends xt {
    getTypeName() { return "ResourceURL"; }
};
function Ft(e) { return e instanceof xt ? e.changingThisBreaksApplicationSecurity : e; }
function Ho(e, t) { let n = ay(e); if (n != null && n !== t) {
    if (n === "ResourceURL" && t === "URL")
        return !0;
    throw new Error(`Required a safe ${t}, got a ${n} (see ${ts})`);
} return n === t; }
function ay(e) { return e instanceof xt && e.getTypeName() || null; }
function aS(e) { return new qu(e); }
function cS(e) { return new Gu(e); }
function lS(e) { return new Wu(e); }
function uS(e) { return new zu(e); }
function dS(e) { return new Qu(e); }
function cy(e) { let t = new Yu(e); return fS() ? new Zu(t) : t; }
var Zu = class {
    inertDocumentHelper;
    constructor(t) { this.inertDocumentHelper = t; }
    getInertBodyElement(t) { t = "<body><remove></remove>" + t; try {
        let n = new window.DOMParser().parseFromString(Vo(t), "text/html").body;
        return n === null ? this.inertDocumentHelper.getInertBodyElement(t) : (n.firstChild?.remove(), n);
    }
    catch {
        return null;
    } }
}, Yu = class {
    defaultDoc;
    inertDocument;
    constructor(t) { this.defaultDoc = t, this.inertDocument = this.defaultDoc.implementation.createHTMLDocument("sanitization-inert"); }
    getInertBodyElement(t) { let n = this.inertDocument.createElement("template"); return n.innerHTML = Vo(t), n; }
};
function fS() { try {
    return !!new window.DOMParser().parseFromString(Vo(""), "text/html");
}
catch {
    return !1;
} }
var pS = /^(?!javascript:)(?:[a-z0-9+.-]+:|[^&:\/?#]*(?:[\/?#]|$))/i;
function Ba(e) { return e = String(e), e.match(pS) ? e : "unsafe:" + e; }
function jt(e) { let t = {}; for (let n of e.split(","))
    t[n] = !0; return t; }
function Ci(...e) { let t = {}; for (let n of e)
    for (let o in n)
        n.hasOwnProperty(o) && (t[o] = !0); return t; }
var ly = jt("area,br,col,hr,img,wbr"), uy = jt("colgroup,dd,dt,li,p,tbody,td,tfoot,th,thead,tr"), dy = jt("rp,rt"), hS = Ci(dy, uy), gS = Ci(uy, jt("address,article,aside,blockquote,caption,center,del,details,dialog,dir,div,dl,figure,figcaption,footer,h1,h2,h3,h4,h5,h6,header,hgroup,hr,ins,main,map,menu,nav,ol,pre,section,summary,table,ul")), mS = Ci(dy, jt("a,abbr,acronym,audio,b,bdi,bdo,big,br,cite,code,del,dfn,em,font,i,img,ins,kbd,label,map,mark,picture,q,ruby,rp,rt,s,samp,small,source,span,strike,strong,sub,sup,time,track,tt,u,var,video")), Ku = Ci(ly, gS, mS, hS), fy = jt("background,cite,href,itemtype,longdesc,poster,src,xlink:href"), vS = jt("abbr,accesskey,align,alt,autoplay,axis,bgcolor,border,cellpadding,cellspacing,class,clear,color,cols,colspan,compact,controls,coords,datetime,default,dir,download,face,headers,height,hidden,hreflang,hspace,ismap,itemscope,itemprop,kind,label,lang,language,loop,media,muted,nohref,nowrap,open,preload,rel,rev,role,rows,rowspan,rules,scope,scrolling,shape,size,sizes,span,srclang,srcset,start,summary,tabindex,target,title,translate,type,usemap,valign,value,vspace,width"), yS = jt("aria-activedescendant,aria-atomic,aria-autocomplete,aria-busy,aria-checked,aria-colcount,aria-colindex,aria-colspan,aria-controls,aria-current,aria-describedby,aria-details,aria-disabled,aria-dropeffect,aria-errormessage,aria-expanded,aria-flowto,aria-grabbed,aria-haspopup,aria-hidden,aria-invalid,aria-keyshortcuts,aria-label,aria-labelledby,aria-level,aria-live,aria-modal,aria-multiline,aria-multiselectable,aria-orientation,aria-owns,aria-placeholder,aria-posinset,aria-pressed,aria-readonly,aria-relevant,aria-required,aria-roledescription,aria-rowcount,aria-rowindex,aria-rowspan,aria-selected,aria-setsize,aria-sort,aria-valuemax,aria-valuemin,aria-valuenow,aria-valuetext"), Ju = Ci(fy, vS, yS), ES = jt("script,style,template"), Xu = class {
    sanitizedSomething = !1;
    buf = [];
    sanitizeChildren(t) { let n = t.firstChild, o = !0, r = []; for (; n;) {
        if (n.nodeType === Node.ELEMENT_NODE ? o = this.startElement(n) : n.nodeType === Node.TEXT_NODE ? this.chars(n.nodeValue) : this.sanitizedSomething = !0, o && n.firstChild) {
            r.push(n), n = TS(n);
            continue;
        }
        for (; n;) {
            n.nodeType === Node.ELEMENT_NODE && this.endElement(n);
            let i = DS(n);
            if (i) {
                n = i;
                break;
            }
            n = r.pop();
        }
    } return this.buf.join(""); }
    startElement(t) { let n = Ug(t).toLowerCase(); if (!Ku.hasOwnProperty(n))
        return this.sanitizedSomething = !0, !ES.hasOwnProperty(n); this.buf.push("<"), this.buf.push(n); let o = t.attributes; for (let r = 0; r < o.length; r++) {
        let i = o.item(r), s = i.name, a = s.toLowerCase();
        if (!Ju.hasOwnProperty(a)) {
            this.sanitizedSomething = !0;
            continue;
        }
        let c = i.value;
        fy[a] && (c = Ba(c)), this.buf.push(" ", s, '="', qg(c), '"');
    } return this.buf.push(">"), !0; }
    endElement(t) { let n = Ug(t).toLowerCase(); Ku.hasOwnProperty(n) && !ly.hasOwnProperty(n) && (this.buf.push("</"), this.buf.push(n), this.buf.push(">")); }
    chars(t) { this.buf.push(qg(t)); }
};
function IS(e, t) { return (e.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_CONTAINED_BY) !== Node.DOCUMENT_POSITION_CONTAINED_BY; }
function DS(e) { let t = e.nextSibling; if (t && e !== t.previousSibling)
    throw py(t); return t; }
function TS(e) { let t = e.firstChild; if (t && IS(e, t))
    throw py(t); return t; }
function Ug(e) { let t = e.nodeName; return typeof t == "string" ? t : "FORM"; }
function py(e) { return new Error(`Failed to sanitize html because the element is clobbered: ${e.outerHTML}`); }
var CS = /[\uD800-\uDBFF][\uDC00-\uDFFF]/g, MS = /([^\#-~ |!])/g;
function qg(e) { return e.replace(/&/g, "&amp;").replace(CS, function (t) { let n = t.charCodeAt(0), o = t.charCodeAt(1); return "&#" + ((n - 55296) * 1024 + (o - 56320) + 65536) + ";"; }).replace(MS, function (t) { return "&#" + t.charCodeAt(0) + ";"; }).replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
var Os;
function hy(e, t) { let n = null; try {
    Os = Os || cy(e);
    let o = t ? String(t) : "";
    n = Os.getInertBodyElement(o);
    let r = 5, i = o;
    do {
        if (r === 0)
            throw new Error("Failed to sanitize html because the input is unstable");
        r--, o = i, i = n.innerHTML, n = Os.getInertBodyElement(o);
    } while (o !== i);
    let a = new Xu().sanitizeChildren(ed(n) || n);
    return Vo(a);
}
finally {
    if (n) {
        let o = ed(n) || n;
        for (; o.firstChild;)
            o.firstChild.remove();
    }
} }
function ed(e) { return "content" in e && wS(e) ? e.content : null; }
function wS(e) { return e.nodeType === Node.ELEMENT_NODE && e.nodeName === "TEMPLATE"; }
var NS = /^>|^->|<!--|-->|--!>|<!-$/g, _S = /(<|>)/g, SS = "\u200B$1\u200B";
function bS(e) { return e.replace(NS, t => t.replace(_S, SS)); }
function lf(e, t) { return e.createText(t); }
function gy(e, t, n) { e.setValue(t, n); }
function uf(e, t) { return e.createComment(bS(t)); }
function $a(e, t, n) { return e.createElement(t, n); }
function _n(e, t, n, o, r) { e.insertBefore(t, n, o, r); }
function my(e, t, n) { e.appendChild(t, n); }
function Gg(e, t, n, o, r) { o !== null ? _n(e, t, n, o, r) : my(e, t, n); }
function Mi(e, t, n, o) { e.removeChild(null, t, n, o); }
function vy(e) { e.textContent = ""; }
function AS(e, t, n) { e.setAttribute(t, "style", n); }
function RS(e, t, n) { n === "" ? e.removeAttribute(t, "class") : e.setAttribute(t, "class", n); }
function yy(e, t, n) { let { mergedAttrs: o, classes: r, styles: i } = n; o !== null && wN(e, t, o), r !== null && RS(e, t, r), i !== null && AS(e, t, i); }
function kS(e) { let t = g(); e.src = "", e.srcdoc = Vo(""), Mi(t[N], e); }
var ee = (function (e) { return e[e.NONE = 0] = "NONE", e[e.HTML = 1] = "HTML", e[e.STYLE = 2] = "STYLE", e[e.SCRIPT = 3] = "SCRIPT", e[e.URL = 4] = "URL", e[e.RESOURCE_URL = 5] = "RESOURCE_URL", e[e.ATTRIBUTE_NO_BINDING = 6] = "ATTRIBUTE_NO_BINDING", e; })(ee || {}), Gs, Wg = "svg", xS = "math";
function OS() { return Gs || (Gs = {}, Jt(ee.HTML, void 0, [["iframe", ["srcdoc"]], ["*", ["innerHTML", "outerHTML"]]]), Jt(ee.STYLE, void 0, [["*", ["style"]]]), Jt(ee.URL, void 0, [["*", ["formAction"]], ["area", ["href"]], ["a", ["href", "xlink:href"]], ["form", ["action"]], ["img", ["src"]], ["video", ["src"]]]), Jt(ee.URL, xS, [["annotation", ["href", "xlink:href"]], ["annotation-xml", ["href", "xlink:href"]], ["maction", ["href", "xlink:href"]], ["malignmark", ["href", "xlink:href"]], ["math", ["href", "xlink:href"]], ["mroot", ["href", "xlink:href"]], ["msqrt", ["href", "xlink:href"]], ["merror", ["href", "xlink:href"]], ["mfrac", ["href", "xlink:href"]], ["mglyph", ["href", "xlink:href"]], ["msub", ["href", "xlink:href"]], ["msup", ["href", "xlink:href"]], ["msubsup", ["href", "xlink:href"]], ["mmultiscripts", ["href", "xlink:href"]], ["mprescripts", ["href", "xlink:href"]], ["mi", ["href", "xlink:href"]], ["mn", ["href", "xlink:href"]], ["mo", ["href", "xlink:href"]], ["mpadded", ["href", "xlink:href"]], ["mphantom", ["href", "xlink:href"]], ["mrow", ["href", "xlink:href"]], ["ms", ["href", "xlink:href"]], ["mspace", ["href", "xlink:href"]], ["mstyle", ["href", "xlink:href"]], ["mtable", ["href", "xlink:href"]], ["mtd", ["href", "xlink:href"]], ["mtr", ["href", "xlink:href"]], ["mtext", ["href", "xlink:href"]], ["mover", ["href", "xlink:href"]], ["munder", ["href", "xlink:href"]], ["munderover", ["href", "xlink:href"]], ["semantics", ["href", "xlink:href"]], ["none", ["href", "xlink:href"]]]), Jt(ee.RESOURCE_URL, void 0, [["base", ["href"]], ["embed", ["src"]], ["frame", ["src"]], ["iframe", ["src"]], ["link", ["href"]], ["object", ["codebase", "data"]]]), Jt(ee.URL, Wg, [["a", ["href", "xlink:href"]]]), Jt(ee.ATTRIBUTE_NO_BINDING, Wg, [["animate", ["attributeName", "values", "to", "from"]], ["set", ["to", "attributeName"]], ["animateMotion", ["attributeName"]], ["animateTransform", ["attributeName"]]]), Jt(ee.ATTRIBUTE_NO_BINDING, void 0, [["unknown", ["attributeName", "values", "to", "from", "sandbox", "allow", "allowFullscreen", "referrerPolicy", "csp", "fetchPriority"]], ["iframe", ["sandbox", "allow", "allowFullscreen", "referrerPolicy", "csp", "fetchPriority"]]])), Gs; }
function Jt(e, t, n) { for (let [o, r] of n) {
    let i = t && o !== "*" && o !== "unknown" ? `:${t}:${o}` : o;
    i = i.toLowerCase();
    for (let s of r)
        Gs[`${i}|${s.toLowerCase()}`] = e;
} }
function df(e) { let t = wi(); return t ? Hg(t.sanitize(ee.HTML, e) || "") : Ho(e, "HTML") ? Hg(Ft(e)) : hy(gi(), b(e)); }
function ff(e) { let t = wi(); return t ? t.sanitize(ee.STYLE, e) || "" : Ho(e, "Style") ? Ft(e) : b(e); }
function pf(e) { let t = wi(); return t ? t.sanitize(ee.URL, e) || "" : Ho(e, "URL") ? Ft(e) : Ba(b(e)); }
function Ua(e) { let t = wi(); if (t)
    return $g(t.sanitize(ee.RESOURCE_URL, e) || ""); if (Ho(e, "ResourceURL"))
    return $g(Ft(e)); throw new D(904, !1); }
function hf(e) { let t = wi(); if (t)
    return Bg(t.sanitize(ee.SCRIPT, e) || ""); if (Ho(e, "Script"))
    return Bg(Ft(e)); throw new D(905, !1); }
function Ey(e) { return Vo(e[0]); }
function Iy(e) { return sS(e[0]); }
var PS = { embed: { src: !0 }, frame: { src: !0 }, iframe: { src: !0 }, media: { src: !0 }, base: { href: !0 }, link: { href: !0 }, object: { data: !0, codebase: !0 } };
function LS(e, t) { return PS[e.toLowerCase()]?.[t.toLowerCase()] === !0 ? Ua : pf; }
function Dy(e, t, n) { return LS(t, n)(e); }
function wi() { let e = g(); return e && e[We].sanitizer; }
var Ps = new Set(["href", "xlink:href"]), FS = { iframe: { sandbox: !0, allow: !0, allowfullscreen: !0, referrerpolicy: !0, csp: !0, fetchpriority: !0 }, ":svg:animate": { attributename: !0, to: Ps, values: Ps, from: Ps }, ":svg:set": { attributename: !0, to: Ps }, ":svg:animatemotion": { attributename: !0 }, ":svg:animatetransform": { attributename: !0 } };
function gf(e, t, n) { let o = t.toLowerCase(), r = n.toLowerCase(), s = le() === -1 ? null : Ve(); if (s && s.type !== 2)
    return e; let a = o[0] !== ":" && s?.namespace ? `:${s.namespace}:${o}` : o, c = FS[a]?.[r]; if (!c)
    return e; let l = g(); if (s && o === "iframe") {
    let f = ie(s, l);
    kS(f);
} let u = t[0] === ":" ? t.split(":").pop() : t; if (typeof c != "boolean") {
    if (!s)
        throw new D(-910, !1);
    let p = ie(s, l).getAttribute("attributeName");
    if (p && c.has(p.toLowerCase()))
        throw new D(-910, !1);
    return e;
} let d = !1; throw new D(-910, d); }
function jS() { return Le([]); }
function Ty(e) { return e.ownerDocument.defaultView; }
function Cy(e) { return e.ownerDocument; }
function mf(e) { return e.ownerDocument.body; }
var VS = "\uFFFD";
function kr(e) { return e instanceof Function ? e() : e; }
function HS(e, t, n) { let o = e.length; for (;;) {
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
var My = "ng-template";
function BS(e, t, n, o) { let r = 0; if (o) {
    for (; r < t.length && typeof t[r] == "string"; r += 2)
        if (t[r] === "class" && HS(t[r + 1].toLowerCase(), n, 0) !== -1)
            return !0;
}
else if (vf(e))
    return !1; if (r = t.indexOf(1, r), r > -1) {
    let i;
    for (; ++r < t.length && typeof (i = t[r]) == "string";)
        if (i.toLowerCase() === n)
            return !0;
} return !1; }
function vf(e) { return e.type === 4 && e.value !== My; }
function $S(e, t, n) { let o = e.type === 4 && !n ? My : e.value; return t === o; }
function US(e, t, n) { let o = 4, r = e.attrs, i = r !== null ? WS(r) : 0, s = !1; for (let a = 0; a < t.length; a++) {
    let c = t[a];
    if (typeof c == "number") {
        if (!s && !it(o) && !it(c))
            return !1;
        if (s && it(c))
            continue;
        s = !1, o = c | o & 1;
        continue;
    }
    if (!s)
        if (o & 4) {
            if (o = 2 | o & 1, c !== "" && !$S(e, c, n) || c === "" && t.length === 1) {
                if (it(o))
                    return !1;
                s = !0;
            }
        }
        else if (o & 8) {
            if (r === null || !BS(e, r, c, n)) {
                if (it(o))
                    return !1;
                s = !0;
            }
        }
        else {
            let l = t[++a], u = qS(c, r, vf(e), n);
            if (u === -1) {
                if (it(o))
                    return !1;
                s = !0;
                continue;
            }
            if (l !== "") {
                let d;
                if (u > i ? d = "" : d = r[u + 1].toLowerCase(), o & 2 && l !== d) {
                    if (it(o))
                        return !1;
                    s = !0;
                }
            }
        }
} return it(o) || s; }
function it(e) { return (e & 1) === 0; }
function qS(e, t, n, o) { if (t === null)
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
    return zS(t, e); }
function wy(e, t, n = !1) { for (let o = 0; o < t.length; o++)
    if (US(e, t[o], n))
        return !0; return !1; }
function GS(e) { let t = e.attrs; if (t != null) {
    let n = t.indexOf(5);
    if ((n & 1) === 0)
        return t[n + 1];
} return null; }
function WS(e) { for (let t = 0; t < e.length; t++) {
    let n = e[t];
    if (nv(n))
        return t;
} return e.length; }
function zS(e, t) { let n = e.indexOf(4); if (n > -1)
    for (n++; n < e.length;) {
        let o = e[n];
        if (typeof o == "number")
            return -1;
        if (o === t)
            return n;
        n++;
    } return -1; }
function QS(e, t) { e: for (let n = 0; n < t.length; n++) {
    let o = t[n];
    if (e.length === o.length) {
        for (let r = 0; r < e.length; r++)
            if (e[r] !== o[r])
                continue e;
        return !0;
    }
} return !1; }
function zg(e, t) { return e ? ":not(" + t.trim() + ")" : t; }
function ZS(e) { let t = e[0], n = 1, o = 2, r = "", i = !1; for (; n < e.length;) {
    let s = e[n];
    if (typeof s == "string")
        if (o & 2) {
            let a = e[++n];
            r += "[" + s + (a.length > 0 ? '="' + a + '"' : "") + "]";
        }
        else
            o & 8 ? r += "." + s : o & 4 && (r += " " + s);
    else
        r !== "" && !it(s) && (t += zg(i, r), r = ""), o = s, i = i || !it(o);
    n++;
} return r !== "" && (t += zg(i, r)), t; }
function YS(e) { return e.map(ZS).join(","); }
function KS(e) { let t = [], n = [], o = 1, r = 2; for (; o < e.length;) {
    let i = e[o];
    if (typeof i == "string")
        r === 2 ? i !== "" && t.push(i, e[++o]) : r === 8 && n.push(i);
    else {
        if (!it(r))
            break;
        r = i;
    }
    o++;
} return n.length && t.push(1, ...n), t; }
var $ = {};
function yf(e, t, n, o, r, i, s, a, c, l, u) { let d = I + o, f = d + r, p = JS(d, f), h = typeof l == "function" ? l() : l; return p[m] = { type: e, blueprint: p, template: n, queries: null, viewQuery: a, declTNode: t, data: p.slice().fill(null, d), bindingStartIndex: d, expandoStartIndex: f, hostBindingOpCodes: null, firstCreatePass: !0, firstUpdatePass: !0, staticViewQueries: !1, staticContentQueries: !1, preOrderHooks: null, preOrderCheckHooks: null, contentHooks: null, contentCheckHooks: null, viewHooks: null, viewCheckHooks: null, destroyHooks: null, cleanup: null, contentQueries: null, components: null, directiveRegistry: typeof i == "function" ? i() : i, pipeRegistry: typeof s == "function" ? s() : s, firstChild: null, schemas: c, consts: h, incompleteFirstPass: !1, ssrId: u }; }
function JS(e, t) { let n = []; for (let o = 0; o < t; o++)
    n.push(o < e ? null : $); return n; }
function Ny(e) { let t = e.tView; return t === null || t.incompleteFirstPass ? e.tView = yf(1, null, e.template, e.decls, e.vars, e.directiveDefs, e.pipeDefs, e.viewQuery, e.schemas, e.consts, e.id) : t; }
function qa(e, t, n, o, r, i, s, a, c, l, u) { let d = t.blueprint.slice(); return d[H] = r, d[w] = o | 4 | 128 | 8 | 64 | 1024, (l !== null || e && e[w] & 2048) && (d[w] |= 2048), Rl(d), d[z] = d[hn] = e, d[B] = n, d[We] = s || e && e[We], d[N] = a || e && e[N], d[x] = c || e && e[x] || null, d[ce] = i, d[Fe] = r_(), d[fe] = u, d[Nl] = l, d[re] = t.type == 2 ? e[re] : d, d; }
function XS(e, t, n) { let o = ie(t, e), r = Ny(n), i = e[We].rendererFactory, s = If(e, qa(e, r, null, Ef(n), o, t, null, i.createRenderer(o, n), null, null, null)); return e[t.index] = s; }
function Ef(e) { let t = 16; return e.signals ? t = 4096 : e.onPush && (t = 64), t; }
function Ni(e, t, n, o) { if (n === 0)
    return -1; let r = t.length; for (let i = 0; i < n; i++)
    t.push(o), e.blueprint.push(o), e.data.push(null); return r; }
function If(e, t) { return e[Qt] ? e[Dr][ge] = t : e[Qt] = t, e[Dr] = t, t; }
function _y(e = 1) { Sy(A(), g(), le() + e, !1); }
function Sy(e, t, n, o) { if (!o)
    if ((t[w] & 3) === 3) {
        let i = e.preOrderCheckHooks;
        i !== null && Bs(t, i, n);
    }
    else {
        let i = e.preOrderHooks;
        i !== null && $s(t, i, 0, n);
    } ht(n); }
var Ga = (function (e) { return e[e.None = 0] = "None", e[e.SignalBased = 1] = "SignalBased", e[e.HasDecoratorInputTransform = 2] = "HasDecoratorInputTransform", e; })(Ga || {});
function Sn(e, t, n, o) { let r = k(null); try {
    let [i, s, a] = e.inputs[n], c = null;
    (s & Ga.SignalBased) !== 0 && (c = t[i][ae]), c !== null && c.transformFn !== void 0 ? o = c.transformFn(o) : a !== null && (o = a.call(t, o)), e.setInput !== null ? e.setInput(t, c, o, n, i) : Qm(t, c, i, o);
}
finally {
    k(r);
} }
var la = (function (e) { return e[e.Important = 1] = "Important", e[e.DashCase = 2] = "DashCase", e; })(la || {}), td;
function Df(e, t) { return td(e, t); }
function eb(e) { td === void 0 && (td = e()); }
var by = new C("", { factory: () => !1 }), Ay = new C("", { factory: () => tb }), tb = 4e3, nb = !1, Hn = (typeof ngServerMode > "u" || !ngServerMode) && typeof document < "u" && typeof document?.documentElement?.getAnimations == "function";
function Wa(e) { return e[x].get(by, nb); }
function ob(e, t, n) { let o = Co.get(e); if (o) {
    for (let r of t)
        o.classList.push(r);
    for (let r of n)
        o.cleanupFns.push(r);
}
else
    Co.set(e, { classList: t, cleanupFns: n }); }
function Tf(e) { let t = Co.get(e); if (t) {
    for (let n of t.cleanupFns)
        n();
    Co.delete(e);
} wn.delete(e); }
var rb = () => { }, Co = new WeakMap, wn = new WeakMap, Zr = new WeakMap, xr = new WeakSet;
function nd(e, t) { let n = Zr.get(e); if (n && n.length > 0) {
    let o = n.findIndex(r => r === t);
    o > -1 && n.splice(o, 1);
} n?.length === 0 && Zr.delete(e); }
function ib(e, t) { let n = Zr.get(e); if (!n || n.length === 0)
    return; let o = t.parentNode, r = t.previousSibling; for (let i = n.length - 1; i >= 0; i--) {
    let s = n[i], a = s.parentNode;
    s === t ? (n.splice(i, 1), xr.add(s), s.dispatchEvent(new CustomEvent("animationend", { detail: { cancel: !0 } }))) : (r && s === r || a && o && a !== o) && (n.splice(i, 1), s.dispatchEvent(new CustomEvent("animationend", { detail: { cancel: !0 } })), s.parentNode?.removeChild(s));
} }
function Cf(e, t) { let n = Zr.get(e); n ? n.includes(t) || n.push(t) : Zr.set(e, [t]); }
function ua(e) { let t = e[ze] ??= {}; return t.enter ??= new Map; }
function bn(e) { let t = e[ze] ??= {}; return t.leave ??= new Map; }
function Ry(e) { let t = typeof e == "function" ? e() : e, n = Array.isArray(t) ? t : null; return typeof t == "string" && (n = t.trim().split(/\s+/).filter(o => o)), n; }
function sb(e, t) { if (!Hn)
    return; let n = Co.get(e); if (n && n.classList.length > 0 && ab(e, n.classList))
    for (let o of n.classList)
        t.removeClass(e, o); Tf(e); }
function ab(e, t) { for (let n of t)
    if (e.classList.contains(n))
        return !0; return !1; }
function Yr(e) { return e.composedPath ? e.composedPath()[0] : e.target; }
function Mf(e, t) { let n = wn.get(t); return n === void 0 ? !0 : t === Yr(e) && (n.animationName !== void 0 && e.animationName === n.animationName || n.propertyName !== void 0 && (n.propertyName === "all" || e.propertyName === n.propertyName)); }
function za(e, t, n) { let o = e.get(t.index) ?? { animateFns: [] }; o.animateFns.push(n), e.set(t.index, o); }
function od(e, t) { if (e)
    for (let n of e)
        n(); for (let n of t)
    n(); }
function rd(e, t) { let n = bn(e).get(t.index); n && (n.resolvers = void 0); }
function Ls(e, t, n, o, r) { nd(t, n), od(o, r), rd(e, t); }
function da(e) { if (!e)
    return 0; let t = e.toLowerCase().indexOf("ms") > -1 ? 1 : 1e3; return parseFloat(e) * t; }
function Cn(e, t) { return e.getPropertyValue(t).split(",").map(o => o.trim()); }
function cb(e) { let t = Cn(e, "transition-property"), n = Cn(e, "transition-duration"), o = Cn(e, "transition-delay"), r = { propertyName: "", duration: 0, animationName: void 0 }; for (let i = 0; i < t.length; i++) {
    let s = da(o[i]) + da(n[i]);
    s > r.duration && (r.propertyName = t[i], r.duration = s);
} return r; }
function lb(e) { let t = Cn(e, "animation-name"), n = Cn(e, "animation-delay"), o = Cn(e, "animation-duration"), r = Cn(e, "animation-iteration-count"), i = { animationName: "", propertyName: void 0, duration: 0 }; for (let s = 0; s < t.length; s++) {
    let a = da(n[s]) + da(o[s]), c = r[s];
    a > i.duration && c !== "infinite" && (i.animationName = t[s], i.duration = a);
} return i; }
function ky(e, t) { return e !== void 0 && e.duration > t.duration; }
function xy(e) { return (e.animationName != null || e.propertyName != null) && e.duration > 0; }
function ub(e, t) { let n = getComputedStyle(e), o = lb(n), r = cb(n), i = o.duration > r.duration ? o : r; ky(t.get(e), i) || xy(i) && t.set(e, i); }
function Oy(e, t, n) { if (!n)
    return; let o = e.getAnimations(); return o.length === 0 ? ub(e, t) : db(e, t, o); }
function db(e, t, n) { let o = { animationName: void 0, propertyName: void 0, duration: 0 }; for (let r of n) {
    let i = r.effect?.getTiming();
    if (i?.iterations === 1 / 0)
        continue;
    let s = typeof i?.duration == "number" ? i.duration : 0, a = (i?.delay ?? 0) + s, c = r.playbackRate;
    c !== void 0 && c !== 0 && c !== 1 && (a /= Math.abs(c));
    let l, u;
    r.animationName ? u = r.animationName : l = r.transitionProperty, a >= o.duration && (o = { animationName: u, propertyName: l, duration: a });
} ky(t.get(e), o) || xy(o) && t.set(e, o); }
var on = new Set, Qa = (function (e) { return e[e.CHANGE_DETECTION = 0] = "CHANGE_DETECTION", e[e.AFTER_NEXT_RENDER = 1] = "AFTER_NEXT_RENDER", e; })(Qa || {}), Bn = new C(""), Qg = new Set;
function te(e) { Qg.has(e) || (Qg.add(e), performance?.mark?.("mark_feature_usage", { detail: { feature: e } })); }
var Za = (() => { class e {
    impl = null;
    execute() { this.impl?.execute(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })(), wf = [0, 1, 2, 3], Nf = (() => { class e {
    ngZone = E(G);
    scheduler = E(Ue);
    errorHandler = E(Mt, { optional: !0 });
    sequences = new Set;
    deferredRegistrations = new Set;
    executing = !1;
    constructor() { E(Bn, { optional: !0 }); }
    execute() { let n = this.sequences.size > 0; n && V(P.AfterRenderHooksStart), this.executing = !0; for (let o of wf)
        for (let r of this.sequences)
            if (!(r.erroredOrDestroyed || !r.hooks[o]))
                try {
                    r.pipelinedValue = this.ngZone.runOutsideAngular(() => this.maybeTrace(() => { let i = r.hooks[o]; return i(r.pipelinedValue); }, r.snapshot));
                }
                catch (i) {
                    r.erroredOrDestroyed = !0, this.errorHandler?.handleError(i);
                } this.executing = !1; for (let o of this.sequences)
        o.afterRun(), o.once && (this.sequences.delete(o), o.destroy()); for (let o of this.deferredRegistrations)
        this.sequences.add(o); this.deferredRegistrations.size > 0 && this.scheduler.notify(7), this.deferredRegistrations.clear(), n && V(P.AfterRenderHooksEnd); }
    register(n) { let { view: o } = n; o !== void 0 ? ((o[mn] ??= []).push(n), En(o), o[w] |= 8192) : this.executing ? this.deferredRegistrations.add(n) : this.addSequence(n); }
    addSequence(n) { this.sequences.add(n), this.scheduler.notify(7); }
    unregister(n) { this.executing && this.sequences.has(n) ? (n.erroredOrDestroyed = !0, n.pipelinedValue = void 0, n.once = !0) : (this.sequences.delete(n), this.deferredRegistrations.delete(n)); }
    maybeTrace(n, o) { return o ? o.run(Qa.AFTER_NEXT_RENDER, n) : n(); }
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
function Py(e, t) { let n = t?.injector ?? E(oe); return typeof ngServerMode < "u" && ngServerMode ? Ya : (te("NgAfterRender"), Ly(e, n, t, !1)); }
function _f(e, t) { let n = t?.injector ?? E(oe); return typeof ngServerMode < "u" && ngServerMode ? Ya : (te("NgAfterNextRender"), Ly(e, n, t, !0)); }
function fb(e) { return e instanceof Function ? [void 0, void 0, e, void 0] : [e.earlyRead, e.write, e.mixedReadWrite, e.read]; }
function Ly(e, t, n, o) { let r = t.get(Za); r.impl ??= t.get(Nf); let i = t.get(Bn, null, { optional: !0 }), s = n?.manualCleanup !== !0 ? t.get(Re) : null, a = t.get(io, null, { optional: !0 }), c = new Kr(r.impl, fb(e), a?.view, o, s, i?.snapshot(null)); return r.impl.register(c), c; }
var Ya = { destroy() { } }, _i = new C("", { factory: () => { let e = E(be), t = new Set; return e.onDestroy(() => t.clear()), { queue: t, isScheduled: !1, scheduler: null, injector: e }; } });
function Fy(e, t, n) { let o = e.get(_i); if (Array.isArray(t))
    for (let r of t)
        o.queue.add(r), n?.detachedLeaveAnimationFns?.push(r);
else
    o.queue.add(t), n?.detachedLeaveAnimationFns?.push(t); o.scheduler && o.scheduler(e); }
function pb(e, t) { let n = e.get(_i); if (Array.isArray(t))
    for (let o of t)
        n.queue.delete(o);
else
    n.queue.delete(t); }
function hb(e, t) { let n = e.get(_i); if (t.detachedLeaveAnimationFns) {
    for (let o of t.detachedLeaveAnimationFns)
        n.queue.delete(o);
    t.detachedLeaveAnimationFns = void 0;
} }
function gb(e) { let t = e.get(_i); t.isScheduled || (_f(() => { t.isScheduled = !1; for (let n of t.queue)
    n(); t.queue.clear(); }, { injector: t.injector }), t.isScheduled = !0); }
function Ka(e) { let t = e.get(_i); t.scheduler = gb, t.scheduler(e); }
function Sf(e, t) { for (let [n, o] of t)
    Fy(e, o.animateFns); }
function Zg(e, t, n, o) { let r = e?.[ze]?.enter; t !== null && r && r.has(n.index) && Sf(o, r); }
function Yg(e, t, n, o) { try {
    n.get(Er);
}
catch {
    return o(!1);
} let r = e?.[ze]; r?.enter?.has(t.index) && pb(n, r.enter.get(t.index).animateFns); let i = mb(e, t, r); if (i.size === 0) {
    let s = !1;
    if (e) {
        let a = [];
        Ja(e, t, a), s = a.length > 0;
    }
    if (!s)
        return o(!1);
} e && on.add(e[Fe]), Fy(n, () => vb(e, t, r || void 0, i, o), r || void 0); }
function mb(e, t, n) { let o = new Map, r = n?.leave; if (r && r.has(t.index) && o.set(t.index, r.get(t.index)), e && r)
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
function vb(e, t, n, o, r) { let i = []; if (n && n.leave)
    for (let [s] of o) {
        if (!n.leave.has(s))
            continue;
        let a = n.leave.get(s);
        for (let c of a.animateFns) {
            let { promise: l } = c();
            i.push(l);
        }
        n.detachedLeaveAnimationFns = void 0;
    } if (e && Ja(e, t, i), i.length > 0) {
    let s = n || e?.[ze];
    if (s) {
        let a = s.running;
        a && i.push(a), s.running = Promise.allSettled(i), Eb(e, s.running, r);
    }
    else
        Promise.allSettled(i).then(() => { e && on.delete(e[Fe]), r(!0); });
}
else
    e && on.delete(e[Fe]), r(!1); }
function Ja(e, t, n) { if (t.type & 12) {
    let r = e[t.index];
    if (K(r))
        for (let i = U; i < r.length; i++) {
            let s = r[i];
            s[m].type === 2 && yb(s, n);
        }
} let o = t.child; for (; o;)
    Ja(e, o, n), o = o.next; }
function yb(e, t) { let n = e[ze]; if (n && n.leave)
    for (let r of n.leave.values())
        for (let i of r.animateFns) {
            let { promise: s } = i();
            t.push(s);
        } let o = e[m].firstChild; for (; o;)
    Ja(e, o, t), o = o.next; }
function Eb(e, t, n) { t.then(() => { e[ze]?.running === t && (e[ze].running = void 0, on.delete(e[Fe])), n(!0); }); }
function go(e, t, n, o, r, i, s, a) { if (r != null) {
    let c, l = !1;
    K(r) ? c = r : J(r) && (l = !0, r = r[H]);
    let u = O(r);
    e === 0 && o !== null ? (Zg(a, o, i, n), s == null ? my(t, o, u) : _n(t, o, u, s || null, !0)) : e === 1 && o !== null ? (Zg(a, o, i, n), _n(t, o, u, s || null, !0), ib(i, u)) : e === 2 ? (a?.[ze]?.leave?.has(i.index) && Cf(i, u), xr.delete(u), Yg(a, i, n, d => { if (xr.has(u)) {
        xr.delete(u);
        return;
    } Mi(t, u, l, d); })) : e === 3 && (xr.delete(u), Yg(a, i, n, () => { t.destroyNode(u); })), c != null && wb(t, e, n, c, i, o, s);
} }
function jy(e, t) { Vy(e, t), t[H] = null, t[ce] = null; }
function Ib(e, t, n, o, r, i) { o[H] = r, o[ce] = t, Xa(e, o, n, 1, r, i); }
function Vy(e, t) { t[We].changeDetectionScheduler?.notify(9), Xa(e, t, t[N], 2, null, null); }
function Db(e) { let t = e[Qt]; if (!t)
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
function bf(e, t) { let n = e[vn], o = n.indexOf(t); n.splice(o, 1); }
function Si(e, t) { if (ut(t))
    return; let n = t[N]; n.destroyNode && Xa(e, t, n, 3, null, null), Db(t); }
function gu(e, t) { if (ut(t))
    return; let n = k(null); try {
    t[w] &= -129, t[w] |= 256, t[Ae] && $t(t[Ae]), Cb(e, t), Tb(e, t), t[m].type === 1 && t[N].destroy();
    let o = t[Zt];
    if (o !== null && K(t[z])) {
        o !== t[z] && bf(o, t);
        let r = t[ct];
        r !== null && r.detachView(e);
    }
    Fu(t);
}
finally {
    k(n);
} }
function Tb(e, t) { let n = e.cleanup, o = t[zt]; if (n !== null)
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
function Cb(e, t) { let n; if (e != null && (n = e.destroyHooks) != null)
    for (let o = 0; o < n.length; o += 2) {
        let r = t[n[o]];
        if (!(r instanceof Nn)) {
            let i = n[o + 1];
            if (Array.isArray(i))
                for (let s = 0; s < i.length; s += 2) {
                    let a = r[i[s]], c = i[s + 1];
                    V(P.LifecycleHookStart, a, c);
                    try {
                        c.call(a);
                    }
                    finally {
                        V(P.LifecycleHookEnd, a, c);
                    }
                }
            else {
                V(P.LifecycleHookStart, r, i);
                try {
                    i.call(r);
                }
                finally {
                    V(P.LifecycleHookEnd, r, i);
                }
            }
        }
    } }
function Af(e, t, n) { return Hy(e, t.parent, n); }
function Hy(e, t, n) { let o = t; for (; o !== null && o.type & 168;)
    t = o, o = t.parent; if (o === null)
    return n[H]; if (Ce(o)) {
    let { encapsulation: r } = e.data[o.directiveStart + o.componentOffset];
    if (r === Ye.None || r === Ye.Emulated)
        return null;
} return ie(o, n); }
function By(e, t, n) { return Uy(e, t, n); }
function $y(e, t, n) { return e.type & 40 ? ie(e, n) : null; }
var Uy = $y, id;
function qy(e, t) { Uy = e, id = t; }
function Rf(e, t, n, o) { let r = Af(e, o, t), i = t[N], s = o.parent || t[ce], a = By(s, o, t); if (r != null)
    if (Array.isArray(n))
        for (let c = 0; c < n.length; c++)
            Gg(i, r, n[c], a, !1);
    else
        Gg(i, r, n, a, !1); id !== void 0 && id(i, o, t, n, r); }
function Mn(e, t) { if (t !== null) {
    let n = t.type;
    if (n & 3)
        return ie(t, e);
    if (n & 4)
        return sd(-1, e[t.index]);
    if (n & 8) {
        let o = t.child;
        if (o !== null)
            return Mn(e, o);
        {
            let r = e[t.index];
            return K(r) ? sd(-1, r) : O(r);
        }
    }
    else {
        if (n & 128)
            return Mn(e, t.next);
        if (n & 32)
            return Df(t, e)() || O(e[t.index]);
        {
            let o = Gy(e, t);
            if (o !== null) {
                if (Array.isArray(o))
                    return o[0];
                let r = et(e[re]);
                return Mn(r, o);
            }
            else
                return Mn(e, t.next);
        }
    }
} return null; }
function Gy(e, t) { if (t !== null) {
    let o = e[re][ce], r = t.projection;
    return o.projection[r];
} return null; }
function sd(e, t) { let n = U + e + 1; if (n < t.length) {
    let o = t[n], r = o[m].firstChild;
    if (r !== null)
        return Mn(o, r);
} return t[ot]; }
function kf(e, t, n, o, r, i, s) { for (; n != null;) {
    let a = o[x];
    if (n.type === 128) {
        n = n.next;
        continue;
    }
    let c = o[n.index], l = n.type;
    if (s && t === 0 && (c && Ze(O(c), o), n.flags |= 2), !jo(n))
        if (l & 8)
            kf(e, t, n.child, o, r, i, !1), go(t, e, a, r, c, n, i, o);
        else if (l & 32) {
            let u = Df(n, o), d;
            for (; d = u();)
                go(t, e, a, r, d, n, i, o);
            go(t, e, a, r, c, n, i, o);
        }
        else
            l & 16 ? Wy(e, t, o, n, r, i) : go(t, e, a, r, c, n, i, o);
    n = s ? n.projectionNext : n.next;
} }
function Xa(e, t, n, o, r, i) { kf(n, o, e.firstChild, t, r, i, !1); }
function Mb(e, t, n) { let o = t[N], r = Af(e, n, t), i = n.parent || t[ce], s = By(i, n, t); Wy(o, 0, t, n, r, s); }
function Wy(e, t, n, o, r, i) { let s = n[re], c = s[ce].projection[o.projection]; if (Array.isArray(c))
    for (let l = 0; l < c.length; l++) {
        let u = c[l];
        go(t, e, n[x], r, u, o, i, n);
    }
else {
    let l = c, u = s[z];
    zr(o) && (l.flags |= 128), kf(e, t, l, u, r, i, !0);
} }
function wb(e, t, n, o, r, i, s) { let a = o[ot], c = O(o); a !== c && go(t, e, n, i, a, r, s); for (let l = U; l < o.length; l++) {
    let u = o[l];
    Xa(u[m], u, e, t, i, a);
} }
function Nb(e, t, n, o, r) { if (t)
    r ? e.addClass(n, o) : e.removeClass(n, o);
else {
    let i = o.indexOf("-") === -1 ? void 0 : la.DashCase;
    r == null ? e.removeStyle(n, o, i) : (typeof r == "string" && r.endsWith("!important") && (r = r.slice(0, -10), i |= la.Important), e.setStyle(n, o, r, i));
} }
function zy(e, t, n, o, r) { let i = le(), s = o & 2; try {
    ht(-1), s && t.length > I && Sy(e, t, I, !1);
    let a = s ? P.TemplateUpdateStart : P.TemplateCreateStart;
    V(a, r, n), n(o, r);
}
finally {
    ht(i);
    let a = s ? P.TemplateUpdateEnd : P.TemplateCreateEnd;
    V(a, r, n);
} }
function ec(e, t, n) { Rb(e, t, n), (n.flags & 64) === 64 && kb(e, t, n); }
function Bo(e, t, n = ie) { let o = t.localNames; if (o !== null) {
    let r = t.index + 1;
    for (let i = 0; i < o.length; i += 2) {
        let s = o[i + 1], a = s === -1 ? n(t, e) : e[s];
        e[r++] = a;
    }
} }
function _b(e, t, n, o) { let i = o.get(Qd, Pv) || n === Ye.ShadowDom || n === Ye.ExperimentalIsolatedShadowDom, s = e.selectRootElement(t, i); if (s.tagName.toLowerCase() === "script")
    throw new D(905, !1); return Sb(s), s; }
function Sb(e) { Qy(e); }
var Qy = () => null;
function bb(e) { Tv(e) ? vy(e) : F_(e); }
function Zy() { Qy = bb; }
function Ab(e) { return e === "class" ? "className" : e === "for" ? "htmlFor" : e === "formaction" ? "formAction" : e === "innerHtml" ? "innerHTML" : e === "readonly" ? "readOnly" : e === "tabindex" ? "tabIndex" : e; }
function xf(e, t, n, o, r, i) { let s = t[m]; if (rc(e, s, t, n, o)) {
    Ce(e) && Yy(t, e.index);
    return;
} e.type & 3 && (n = Ab(n)), Of(e, t, n, o, r, i); }
function Of(e, t, n, o, r, i) { if (e.type & 3) {
    let s = ie(e, t);
    o = i != null ? i(o, e.value || "", n) : o, r.setProperty(s, n, o);
}
else
    e.type & 12; }
function Yy(e, t) { let n = me(t, e); n[w] & 16 || (n[w] |= 64); }
function Rb(e, t, n) { let o = n.directiveStart, r = n.directiveEnd; Ce(n) && XS(t, n, e.data[o + n.componentOffset]), e.firstCreatePass || ta(n, t); let i = n.initialInputs; for (let s = o; s < r; s++) {
    let a = e.data[s], c = Wr(t, e, s, n);
    if (Ze(c, t), i !== null && Pb(t, s - o, c, a, n, i), Qe(a)) {
        let l = me(n.index, t);
        l[B] = Wr(t, e, s, n);
    }
} }
function kb(e, t, n) { let o = n.directiveStart, r = n.directiveEnd, i = n.index, s = pg(); try {
    ht(i);
    for (let a = o; a < r; a++) {
        let c = e.data[a], l = t[a];
        Es(a), (c.hostBindings !== null || c.hostVars !== 0 || c.hostAttrs !== null) && xb(c, l);
    }
}
finally {
    ht(-1), Es(s);
} }
function xb(e, t) { e.hostBindings !== null && e.hostBindings(1, t); }
function Pf(e, t) { let n = e.directiveRegistry, o = null; if (n)
    for (let r = 0; r < n.length; r++) {
        let i = n[r];
        wy(t, i.selectors, !1) && (o ??= [], Qe(i) ? o.unshift(i) : o.push(i));
    } return o; }
function Ob(e, t, n, o, r, i) { let s = ie(e, t); tc(t[N], s, i, e.value, n, o, r); }
function tc(e, t, n, o, r, i, s) { if (i == null)
    e.removeAttribute(t, r, n);
else {
    let a = s == null ? b(i) : s(i, o || "", r);
    e.setAttribute(t, r, a, n);
} }
function Pb(e, t, n, o, r, i) { let s = i[t]; if (s !== null)
    for (let a = 0; a < s.length; a += 2) {
        let c = s[a], l = s[a + 1];
        Sn(o, n, c, l);
    } }
function nc(e, t, n, o, r) { let i = I + n, s = t[m], a = r(s, t, e, o, n); t[i] = a, dt(e, !0); let c = e.type === 2; return c ? (yy(t[N], a, e), (cg() === 0 || Xn(e)) && Ze(a, t), lg()) : Ze(a, t), Sr() && (!c || !jo(e)) && Rf(s, t, a, e), e; }
function oc(e) { let t = e; return Ul() ? ql() : (t = t.parent, dt(t, !1)), t; }
function Ky(e, t, n) { return (e === null || Qe(e)) && (n = Cr(n[t.index])), n[N]; }
function Lf(e, t) { let n = e[x]; if (!n)
    return; let o; try {
    o = n.get(_t, null);
}
catch {
    o = null;
} o?.(t); }
function rc(e, t, n, o, r) { let i = e.inputs?.[o], s = e.hostDirectiveInputs?.[o], a = !1; if (s)
    for (let c = 0; c < s.length; c += 2) {
        let l = s[c], u = s[c + 1], d = t.data[l];
        Sn(d, n[l], u, r), a = !0;
    } if (i)
    for (let c of i) {
        let l = n[c], u = t.data[c];
        Sn(u, l, o, r), a = !0;
    } return a; }
function Jy(e, t, n, o, r, i) { let s = null, a = null, c = null, l = !1, u = e.directiveToIndex.get(o.type); if (typeof u == "number" ? s = u : [s, a, c] = u, a !== null && c !== null && e.hostDirectiveInputs?.hasOwnProperty(r)) {
    let d = e.hostDirectiveInputs[r];
    for (let f = 0; f < d.length; f += 2) {
        let p = d[f];
        if (p >= a && p <= c) {
            let h = t.data[p], v = d[f + 1];
            Sn(h, n[p], v, i), l = !0;
        }
        else if (p > c)
            break;
    }
} return s !== null && o.inputs.hasOwnProperty(r) && (Sn(o, n[s], r, i), l = !0), l; }
function Lb(e, t) { let n = me(t, e), o = n[m]; Fb(o, n); let r = n[H]; r !== null && n[fe] === null && (n[fe] = Zv(r, n[x])), V(P.ComponentStart); try {
    ic(o, n, n[B]);
}
finally {
    V(P.ComponentEnd, n[B]);
} }
function Fb(e, t) { for (let n = t.length; n < e.blueprint.length; n++)
    t.push(e.blueprint[n]); }
function ic(e, t, n) { Ts(t); try {
    let o = e.viewQuery;
    o !== null && Uu(1, o, n);
    let r = e.template;
    r !== null && zy(e, t, r, 1, n), e.firstCreatePass && (e.firstCreatePass = !1), t[ct]?.finishViewCreation(e), e.staticContentQueries && oy(e, t), e.staticViewQueries && Uu(2, e.viewQuery, n);
    let i = e.components;
    i !== null && jb(t, i);
}
catch (o) {
    throw e.firstCreatePass && (e.incompleteFirstPass = !0, e.firstCreatePass = !1), o;
}
finally {
    t[w] &= -5, Cs();
} }
function jb(e, t) { for (let n = 0; n < t.length; n++)
    Lb(e, t[n]); }
function $o(e, t, n, o) { let r = k(null); try {
    let i = t.tView, a = e[w] & 4096 ? 4096 : 16, c = qa(e, i, n, a, null, t, null, null, o?.injector ?? null, o?.embeddedViewInjector ?? null, o?.dehydratedView ?? null), l = e[t.index];
    c[Zt] = l;
    let u = e[ct];
    return u !== null && (c[ct] = u.createEmbeddedView(i)), ic(i, c, n), c;
}
finally {
    k(r);
} }
function An(e, t) { return !t || t.firstChild === null || zr(e); }
function Mo(e, t, n, o, r = !1) { for (; n !== null;) {
    if (n.type === 128) {
        n = r ? n.projectionNext : n.next;
        continue;
    }
    let i = t[n.index];
    i !== null && o.push(O(i)), K(i) && sc(i, o);
    let s = n.type;
    if (s & 8)
        Mo(e, t, n.child, o);
    else if (s & 32) {
        let a = Df(n, t), c;
        for (; c = a();)
            o.push(c);
    }
    else if (s & 16) {
        let a = Gy(t, n);
        if (Array.isArray(a))
            o.push(...a);
        else {
            let c = et(t[re]);
            Mo(c[m], c, a, o, !0);
        }
    }
    n = r ? n.projectionNext : n.next;
} return o; }
function sc(e, t) { for (let n = U; n < e.length; n++) {
    let o = e[n], r = o[m].firstChild;
    r !== null && Mo(o[m], o, r, t);
} e[ot] !== e[H] && t.push(e[ot]); }
function Xy(e) { if (e[mn] !== null) {
    for (let t of e[mn])
        t.impl.addSequence(t);
    e[mn].length = 0;
} }
var eE = [];
function Vb(e) { return e[Ae] ?? Hb(e); }
function Hb(e) { let t = eE.pop() ?? Object.create($b); return t.lView = e, t; }
function Bb(e) { e.lView[Ae] !== e && (e.lView = null, eE.push(e)); }
var $b = Ie(q({}, Yc), { consumerIsAlwaysLive: !0, kind: "template", consumerMarkedDirty: e => { En(e.lView); }, consumerOnSignalRead() { this.lView[Ae] = this; } });
function Ub(e) { let t = e[Ae] ?? Object.create(qb); return t.lView = e, t; }
var qb = Ie(q({}, Yc), { consumerIsAlwaysLive: !0, kind: "template", consumerMarkedDirty: e => { let t = et(e.lView); for (; t && !tE(t[m]);)
        t = et(t); t && wr(t); }, consumerOnSignalRead() { this.lView[Ae] = this; } });
function tE(e) { return e.type !== 2; }
function nE(e) { if (e[qt] === null)
    return; let t = !0; for (; t;) {
    let n = !1;
    for (let o of e[qt])
        o.dirty && (n = !0, o.zone === null || Zone.current === o.zone ? o.run() : o.zone.run(() => o.run()));
    t = n && !!(e[w] & 8192);
} }
var Gb = 100;
function oE(e, t = 0) { let o = e[We].rendererFactory, r = !1; r || o.begin?.(); try {
    Wb(e, t);
}
finally {
    r || o.end?.();
} }
function Wb(e, t) { let n = Wl(); try {
    nr(!0), ad(e, t);
    let o = 0;
    for (; eo(e);) {
        if (o === Gb)
            throw new D(103, !1);
        o++, ad(e, 1);
    }
}
finally {
    nr(n);
} }
function rE(e, t, n, o) { if (ut(t))
    return; let r = t[w], i = !1, s = !1; Ts(t); let a = !0, c = null, l = null; i || (tE(e) ? (l = Vb(t), c = Ko(l)) : qi() === null ? (a = !1, l = Ub(t), c = Ko(l)) : t[Ae] && ($t(t[Ae]), t[Ae] = null)); try {
    Rl(t), zl(e.bindingStartIndex), n !== null && zy(e, t, n, 2, o);
    let u = (r & 3) === 3;
    if (!i)
        if (u) {
            let p = e.preOrderCheckHooks;
            p !== null && Bs(t, p, null);
        }
        else {
            let p = e.preOrderHooks;
            p !== null && $s(t, p, 0, null), lu(t, 0);
        }
    if (s || zb(t), nE(t), iE(t, 0), e.contentQueries !== null && oy(e, t), !i)
        if (u) {
            let p = e.contentCheckHooks;
            p !== null && Bs(t, p);
        }
        else {
            let p = e.contentHooks;
            p !== null && $s(t, p, 1), lu(t, 1);
        }
    Zb(e, t);
    let d = e.components;
    d !== null && aE(t, d, 0);
    let f = e.viewQuery;
    if (f !== null && Uu(2, f, o), !i)
        if (u) {
            let p = e.viewCheckHooks;
            p !== null && Bs(t, p);
        }
        else {
            let p = e.viewHooks;
            p !== null && $s(t, p, 2), lu(t, 2);
        }
    if (e.firstUpdatePass === !0 && (e.firstUpdatePass = !1), t[fs]) {
        for (let p of t[fs])
            p();
        t[fs] = null;
    }
    i || (Xy(t), t[w] &= -73);
}
catch (u) {
    throw i || En(t), u;
}
finally {
    l !== null && (Wi(l, c), a && Bb(l)), Cs();
} }
function iE(e, t) { for (let n = _v(e); n !== null; n = Sv(n))
    for (let o = U; o < n.length; o++) {
        let r = n[o];
        sE(r, t);
    } }
function zb(e) { for (let t = _v(e); t !== null; t = Sv(t)) {
    if (!(t[w] & 2))
        continue;
    let n = t[vn];
    for (let o = 0; o < n.length; o++) {
        let r = n[o];
        wr(r);
    }
} }
function Qb(e, t, n) { V(P.ComponentStart); let o = me(t, e); try {
    sE(o, n);
}
finally {
    V(P.ComponentEnd, o[B]);
} }
function sE(e, t) { gs(e) && ad(e, t); }
function ad(e, t) { let o = e[m], r = e[w], i = e[Ae], s = !!(t === 0 && r & 16); if (s ||= !!(r & 64 && t === 0), s ||= !!(r & 1024), s ||= !!(i?.dirty && zi(i)), s ||= !1, i && (i.dirty = !1), e[w] &= -9217, s)
    rE(o, e, o.template, e[B]);
else if (r & 8192) {
    let a = k(null);
    try {
        nE(e), iE(e, 1);
        let c = o.components;
        c !== null && aE(e, c, 1), Xy(e);
    }
    finally {
        k(a);
    }
} }
function aE(e, t, n) { for (let o = 0; o < t.length; o++)
    Qb(e, t[o], n); }
function Zb(e, t) { let n = e.hostBindingOpCodes; if (n !== null)
    try {
        for (let o = 0; o < n.length; o++) {
            let r = n[o];
            if (r < 0)
                ht(~r);
            else {
                let i = r, s = n[++o], a = n[++o];
                fg(s, i);
                let c = t[i];
                V(P.HostBindingsUpdateStart, c);
                try {
                    a(2, c);
                }
                finally {
                    V(P.HostBindingsUpdateEnd, c);
                }
            }
        }
    }
    finally {
        ht(-1);
    } }
function ac(e, t) { let n = Wl() ? 64 : 1088; for (e[We].changeDetectionScheduler?.notify(t); e;) {
    e[w] |= n;
    let o = et(e);
    if (lt(e) && !o)
        return e;
    e = o;
} return null; }
function cE(e, t, n, o) { return [e, !0, 0, t, null, o, null, n, null, null]; }
function lE(e, t) { let n = U + t; if (n < e.length)
    return e[n]; }
function Uo(e, t, n, o = !0) { let r = t[m]; if (Yb(r, t, e, n), o) {
    let s = sd(n, e), a = t[N], c = a.parentNode(e[ot]);
    c !== null && Ib(r, e[ce], a, t, c, s);
} let i = t[fe]; i !== null && i.firstChild !== null && (i.firstChild = null); }
function Ff(e, t) { let n = Jr(e, t); return n !== void 0 && Si(n[m], n), n; }
function Jr(e, t) { if (e.length <= U)
    return; let n = U + t, o = e[n]; if (o) {
    let r = o[Zt];
    r !== null && r !== e && bf(r, o), t > 0 && (e[n - 1][ge] = o[ge]);
    let i = mr(e, U + t);
    jy(o[m], o);
    let s = i[ct];
    s !== null && s.detachView(i[m]), o[z] = null, o[ge] = null, o[w] &= -129;
} return o; }
function Yb(e, t, n, o) { let r = U + o, i = n.length; o > 0 && (n[r - 1][ge] = t), o < i - U ? (t[ge] = n[r], El(n, U + o, t)) : (n.push(t), t[ge] = null), t[z] = n; let s = t[Zt]; s !== null && n !== s && uE(s, t); let a = t[ct]; a !== null && a.insertView(e), ms(t), t[w] |= 128; }
function uE(e, t) { let n = e[vn], o = t[z]; if (J(o))
    e[w] |= 2;
else {
    let r = o[z][re];
    t[re] !== r && (e[w] |= 2);
} n === null ? e[vn] = [t] : n.push(t); }
var rn = class {
    _lView;
    _cdRefInjectingView;
    _appRef = null;
    _attachedToViewContainer = !1;
    exhaustive;
    get rootNodes() { let t = this._lView, n = t[m]; return Mo(n, t, n.firstChild, []); }
    constructor(t, n) { this._lView = t, this._cdRefInjectingView = n; }
    get context() { return this._lView[B]; }
    set context(t) { this._lView[B] = t; }
    get destroyed() { return ut(this._lView); }
    destroy() { if (this._appRef)
        this._appRef.detachView(this);
    else if (this._attachedToViewContainer) {
        let t = this._lView[z];
        if (K(t)) {
            let n = t[Tr], o = n ? n.indexOf(this) : -1;
            o > -1 && (Jr(t, o), mr(n, o));
        }
        this._attachedToViewContainer = !1;
    } Si(this._lView[m], this._lView); }
    onDestroy(t) { to(this._lView, t); }
    markForCheck() { ac(this._cdRefInjectingView || this._lView, 4); }
    detach() { this._lView[w] &= -129; }
    reattach() { ms(this._lView), this._lView[w] |= 128; }
    detectChanges() { this._lView[w] |= 1024, oE(this._lView); }
    checkNoChanges() { }
    attachToViewContainerRef() { if (this._appRef)
        throw new D(902, !1); this._attachedToViewContainer = !0; }
    detachFromAppRef() { this._appRef = null; let t = lt(this._lView), n = this._lView[Zt]; n !== null && !t && bf(n, this._lView), Vy(this._lView[m], this._lView); }
    attachToAppRef(t) { if (this._attachedToViewContainer)
        throw new D(902, !1); this._appRef = t; let n = lt(this._lView), o = this._lView[Zt]; o !== null && !n && uE(o, this._lView), ms(this._lView); }
};
function Kb(e) { return eo(e._lView) || !!(e._lView[w] & 64); }
function Jb(e) { wr(e._lView); }
var Xr = (() => { class e {
    _declarationLView;
    _declarationTContainer;
    elementRef;
    static __NG_ELEMENT_ID__ = Xb;
    constructor(n, o, r) { this._declarationLView = n, this._declarationTContainer = o, this.elementRef = r; }
    get ssrId() { return this._declarationTContainer.tView?.ssrId || null; }
    createEmbeddedView(n, o) { return this.createEmbeddedViewImpl(n, o); }
    createEmbeddedViewImpl(n, o, r) { let i = $o(this._declarationLView, this._declarationTContainer, n, { embeddedViewInjector: o, dehydratedView: r }); return new rn(i); }
} return e; })();
function Xb() { return cc(_(), g()); }
function cc(e, t) { return e.type & 4 ? new Xr(t, e, xo(e, t)) : null; }
var cd = "<-- AT THIS LOCATION", eA = "/guide/hydration#third-party-scripts-with-dom-manipulation";
function tA(e) { switch (e) {
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
function nA(e, t) {
    let n = `During serialization, Angular was unable to find an element in the DOM:

`, o = `${sA(e, t, !1)}

`, r = cA();
    throw new D(-502, n + o + r);
}
function dE(e) {
    let t = "During serialization, Angular detected DOM nodes that were created outside of Angular context and provided as projectable nodes (likely via `ViewContainerRef.createComponent` or `createComponent` APIs). Hydration is not supported for such cases, consider refactoring the code to avoid this pattern or using `ngSkipHydration` on the host element of the component.\n\n", n = `${aA(e)}

`, o = t + n + lA();
    return new D(-503, o);
}
function oA(e) { let t = []; if (e.attrs)
    for (let n = 0; n < e.attrs.length;) {
        let o = e.attrs[n++];
        if (typeof o == "number")
            break;
        let r = e.attrs[n++];
        t.push(`${o}="${fa(r)}"`);
    } return t.join(" "); }
var rA = new Set(["ngh", "ng-version", "ng-server-context"]);
function iA(e) { let t = []; for (let n = 0; n < e.attributes.length; n++) {
    let o = e.attributes[n];
    rA.has(o.name) || t.push(`${o.name}="${fa(o.value)}"`);
} return t.join(" "); }
function mu(e, t = "\u2026") { switch (e.type) {
    case 1: return `#text${e.value ? `(${e.value})` : ""}`;
    case 2:
        let o = oA(e), r = e.value.toLowerCase();
        return `<${r}${o ? " " + o : ""}>${t}</${r}>`;
    case 8: return "<!-- ng-container -->";
    case 4: return "<!-- container -->";
    default: return `#node(${tA(e.type)})`;
} }
function Ws(e, t = "\u2026") { let n = e; switch (n.nodeType) {
    case Node.ELEMENT_NODE:
        let o = n.tagName.toLowerCase(), r = iA(n);
        return `<${o}${r ? " " + r : ""}>${t}</${o}>`;
    case Node.TEXT_NODE:
        let i = n.textContent ? fa(n.textContent) : "";
        return `#text${i ? `(${i})` : ""}`;
    case Node.COMMENT_NODE: return `<!-- ${fa(n.textContent ?? "")} -->`;
    default: return `#node(${n.nodeType})`;
} }
function sA(e, t, n) {
    let r = "";
    t.prev ? (r += `  \u2026
`, r += "  " + mu(t.prev) + `
`) : t.type && t.type & 12 && (r += `  \u2026
`), n ? (r += "  " + mu(t) + `
`, r += `  <!-- container -->  ${cd}
`) : r += "  " + mu(t) + `  ${cd}
`, r += `  \u2026
`;
    let i = t.type ? Af(e[m], t, e) : null;
    return i && (r = Ws(i, `
` + r)), r;
}
function aA(e) {
    let n = "", o = e;
    return o.previousSibling && (n += `  \u2026
`, n += "  " + Ws(o.previousSibling) + `
`), n += "  " + Ws(o) + `  ${cd}
`, e.nextSibling && (n += `  \u2026
`), e.parentNode && (n = Ws(o.parentNode, `
` + n)), n;
}
function cA(e) {
    return `To fix this problem:
  * check ${e ? `the "${e}"` : "corresponding"} component for hydration-related issues
  * check to see if your template has valid HTML structure
  * check if there are any third-party scripts that manipulate the DOM. More info: ${es}${eA}
  * or skip hydration by adding the \`ngSkipHydration\` attribute to its host node in a template

`;
}
function lA() {
    return `Note: attributes are only displayed to better represent the DOM but have no effect on hydration mismatches.

`;
}
function uA(e) { return e.replace(/\s+/gm, ""); }
function fa(e, t = 50) { return e ? (e = uA(e), e.length > t ? `${e.substring(0, t - 1)}\u2026` : e) : ""; }
function fE(e, t, n) { let o = t.insertBeforeIndex, r = Array.isArray(o) ? o[0] : o; return r === null ? $y(e, t, n) : O(n[r]); }
function pE(e, t, n, o, r) { let i = t.insertBeforeIndex; if (Array.isArray(i)) {
    let s = o, a = null;
    if (t.type & 3 || (a = s, s = r), s !== null && t.componentOffset === -1)
        for (let c = 1; c < i.length; c++) {
            let l = n[i[c]];
            _n(e, s, l, a, !1);
        }
} }
function $n(e, t, n, o, r) { let i = e.data[t]; if (i === null)
    i = jf(e, t, n, o, r), dg() && (i.flags |= 32);
else if (i.type & 64) {
    i.type = n, i.value = o, i.attrs = r;
    let s = no();
    i.injectorIndex = s === null ? -1 : s.injectorIndex;
} return dt(i, !0), i; }
function jf(e, t, n, o, r) { let i = $l(), s = Ul(), a = s ? i : i && i.parent, c = e.data[t] = fA(e, a, n, t, o, r); return dA(e, c, i, s), c; }
function dA(e, t, n, o) { e.firstChild === null && (e.firstChild = t), n !== null && (o ? n.child == null && t.parent !== null && (n.child = t) : n.next === null && (n.next = t, t.prev = n)); }
function fA(e, t, n, o, r, i) { let s = t ? t.injectorIndex : -1, a = 0; return Nr() && (a |= 128), { type: n, index: o, insertBeforeIndex: null, injectorIndex: s, directiveStart: -1, directiveEnd: -1, directiveStylingLast: -1, componentOffset: -1, controlDirectiveIndex: -1, customControlIndex: -1, propertyBindings: null, flags: a, providerIndexes: 0, value: r, namespace: Ms(), attrs: i, mergedAttrs: null, localNames: null, initialInputs: null, inputs: null, hostDirectiveInputs: null, outputs: null, hostDirectiveOutputs: null, directiveToIndex: null, tView: null, next: null, prev: null, projectionNext: null, child: null, parent: t, projection: null, styles: null, stylesWithoutHost: null, residualStyles: void 0, classes: null, classesWithoutHost: null, residualClasses: void 0, classBindings: 0, styleBindings: 0 }; }
function hE(e, t) { if (e.push(t), e.length > 1)
    for (let n = e.length - 2; n >= 0; n--) {
        let o = e[n];
        gE(o) || pA(o, t) && hA(o) === null && gA(o, t.index);
    } }
function gE(e) { return !(e.type & 64); }
function pA(e, t) { return gE(t) || e.index > t.index; }
function hA(e) { let t = e.insertBeforeIndex; return Array.isArray(t) ? t[0] : t; }
function gA(e, t) { let n = e.insertBeforeIndex; Array.isArray(n) ? n[0] = t : (qy(fE, pE), e.insertBeforeIndex = t); }
function Pr(e, t) { let n = e.data[t]; return n === null || typeof n == "string" ? null : n.hasOwnProperty("currentCaseLViewIndex") ? n : n.value; }
function mA(e, t, n) { let o = e.data[t]; o === null ? e.data[t] = n : o.value = n; }
function vA(e, t) { let n = e.insertBeforeIndex; n === null ? (qy(fE, pE), n = e.insertBeforeIndex = [null, t]) : (hl(Array.isArray(n), !0, "Expecting array here"), n.push(t)); }
function yA(e, t, n) { let o = jf(e, n, 64, null, null); return hE(t, o), o; }
function lc(e, t) { let n = t[e.currentCaseLViewIndex]; return n === null ? n : n < 0 ? ~n : n; }
function EA(e) { return e >>> 17; }
function IA(e) { return (e & 131070) >>> 1; }
function DA(e, t, n) { return e | t << 17 | n << 1; }
function mE(e) { return e === -1; }
function Vf(e, t, n) { e.index = 0; let o = lc(t, n); o !== null ? e.removes = t.remove[o] : e.removes = F; }
function pa(e) { if (e.index < e.removes.length) {
    let t = e.removes[e.index++];
    if (t > 0)
        return e.lView[t];
    {
        e.stack.push(e.index, e.removes);
        let n = ~t, o = e.lView[m].data[n];
        return Vf(e, o, e.lView), pa(e);
    }
}
else
    return e.stack.length === 0 ? (e.lView = void 0, null) : (e.removes = e.stack.pop(), e.index = e.stack.pop(), pa(e)); }
function TA() { let e = { stack: [], index: -1 }; function t(n, o) { for (e.lView = o; e.stack.length;)
    e.stack.pop(); return Vf(e, n.value, o), pa.bind(null, e); } return t; }
function CA(e, t) { let n = { stack: [], index: -1, lView: t }; return Vf(n, e, t), pa.bind(null, n); }
var MA = new RegExp(`^(\\d+)*(${Wd}|${Gd})*(.*)`);
function wA(e, t) { let n = [e]; for (let o of t) {
    let r = n.length - 1;
    if (r > 0 && n[r - 1] === o) {
        let i = n[r] || 1;
        n[r] = i + 1;
    }
    else
        n.push(o, "");
} return n.join(""); }
function NA(e) { let t = e.match(MA), [n, o, r, i] = t, s = o ? parseInt(o, 10) : r, a = []; for (let [c, l, u] of i.matchAll(/(f|n)(\d*)/g)) {
    let d = parseInt(u, 10) || 1;
    a.push(l, d);
} return [s, ...a]; }
function _A(e) { return !e.prev && e.parent?.type === 8; }
function vu(e) { return e.index - I; }
function qo(e, t) { return !(e.type & 144) && !!t[e.index] && vE(O(t[e.index])); }
function vE(e) { return !!e && !e.isConnected; }
function yE(e, t) { let n = e.i18nNodes; if (n)
    return n.get(t); }
function SA(e, t, n) { let r = e.data[yi]?.[n]; return r ? EE(r, t) : null; }
function bi(e, t, n, o) { let r = vu(o), i = yE(e, r); if (i === void 0) {
    let s = e.data[yi];
    if (s?.[r])
        i = EE(s[r], n);
    else if (t.firstChild === o)
        i = e.firstChild;
    else {
        let a = o.prev === null, c = o.prev ?? o.parent;
        if (_A(o)) {
            let l = vu(o.parent);
            i = $u(e, l);
        }
        else {
            let l = ie(c, n);
            if (a)
                i = l.firstChild;
            else {
                let u = vu(c), d = $u(e, u);
                if (c.type === 2 && d) {
                    let p = rf(e, u) + 1;
                    i = uc(p, d);
                }
                else
                    i = l.nextSibling;
            }
        }
    }
} return i; }
function uc(e, t) { let n = t; for (let o = 0; o < e; o++)
    n = n.nextSibling; return n; }
function bA(e, t) { let n = e; for (let o = 0; o < t.length; o += 2) {
    let r = t[o], i = t[o + 1];
    for (let s = 0; s < i; s++)
        switch (r) {
            case xv:
                n = n.firstChild;
                break;
            case Ov:
                n = n.nextSibling;
                break;
        }
} return n; }
function EE(e, t) { let [n, ...o] = NA(e), r; if (n === Gd)
    r = t[re][H];
else if (n === Wd)
    r = mf(t[re][H]);
else {
    let i = Number(n);
    r = O(t[i + I]);
} return bA(r, o); }
function ld(e, t) { if (e === t)
    return []; if (e.parentElement == null || t.parentElement == null)
    return null; if (e.parentElement === t.parentElement)
    return AA(e, t); {
    let n = t.parentElement, o = ld(e, n), r = ld(n.firstChild, t);
    return !o || !r ? null : [...o, xv, ...r];
} }
function AA(e, t) { let n = [], o = null; for (o = e; o != null && o !== t; o = o.nextSibling)
    n.push(Ov); return o == null ? null : n; }
function Kg(e, t, n) { let o = ld(e, t); return o === null ? null : wA(n, o); }
function IE(e, t, n) { let o = e.parent, r, i, s; for (; o !== null && (qo(o, t) || n?.has(o.index));)
    o = o.parent; o === null || !(o.type & 3) ? (r = s = Gd, i = t[re][H]) : (r = o.index, i = O(t[r]), s = b(r - I)); let a = O(t[e.index]); if (e.type & 44) {
    let l = Mn(t, e);
    l && (a = l);
} let c = Kg(i, a, s); if (c === null && i !== a) {
    let l = i.ownerDocument.body;
    if (c = Kg(l, a, Wd), c === null)
        throw nA(t, e);
} return c; }
function RA(e, t) { let n = e.createNodeIterator(t, NodeFilter.SHOW_COMMENT, { acceptNode: kA }), o, r = new Map; for (; o = n.nextNode();) {
    let i = "ngh=", s = o?.textContent, a = s?.indexOf(i) ?? -1;
    if (a > -1) {
        let c = s.substring(a + i.length).trim();
        r.set(c, o);
    }
} return r; }
function kA(e) { return e.textContent?.trimStart().startsWith("ngh=") ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
var DE = !1, TE = () => { };
function Hf(e) { DE = e; }
function dc() { return DE; }
function xA(e, t, n, o) { TE(e, t, n, o); }
function CE() { TE = jA; }
function ME(e) { return e = e ?? E(oe), e.get(Zd, !1); }
function wE(e, t) { let n = t.i18nChildren.get(e); return n === void 0 && (n = OA(e), t.i18nChildren.set(e, n)), n; }
function OA(e) { let t = new Set; function n(o) { switch (t.add(o.index), o.kind) {
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
function NE(e, t, n) { if (!n.isI18nHydrationEnabled)
    return null; let o = e[m], r = o.data[t]; if (!r || !r.ast)
    return null; let i = o.data[r.parentTNodeIndex]; if (i && Cv(i))
    return null; let s = { caseQueue: [], disconnectedNodes: new Set, disjointNodes: new Set }; return ud(e, s, n, r.ast), s.caseQueue.length === 0 && s.disconnectedNodes.size === 0 && s.disjointNodes.size === 0 ? null : s; }
function ud(e, t, n, o) { let r = null; for (let i of o) {
    let s = LA(e, t, n, i);
    s && (PA(r, s) && t.disjointNodes.add(i.index - I), r = s);
} return r; }
function PA(e, t) { return e && e.nextSibling !== t; }
function LA(e, t, n, o) { let r = O(e[o.index]); if (!r || vE(r))
    return t.disconnectedNodes.add(o.index - I), null; let i = r; switch (o.kind) {
    case 0: {
        sf(n, i);
        break;
    }
    case 1:
    case 2: {
        ud(e, t, n, o.children);
        break;
    }
    case 3: {
        let s = e[o.currentCaseLViewIndex];
        if (s != null) {
            let a = s < 0 ? ~s : s;
            t.caseQueue.push(a), ud(e, t, n, o.cases[a]);
        }
        break;
    }
} return FA(e, o); }
function FA(e, t) { let o = e[m].data[t.index]; return Na(o) ? Mn(e, o) : t.kind === 3 ? CA(o, e)() ?? O(e[t.index]) : O(e[t.index]) ?? null; }
function In(e, t) { e.currentNode = t; }
function Ar(e, t, n) { let o = n.index - I, { disconnectedNodes: r } = e, i = t.currentNode; return t.isConnected ? (e.i18nNodes.set(o, i), r.delete(o)) : r.add(o), i; }
function yu(e, t) { let n = e.currentNode; for (let o = 0; o < t && n; o++)
    n = n?.nextSibling ?? null; return n; }
function Eu(e, t) { return { currentNode: t, isConnected: e.isConnected }; }
function jA(e, t, n, o) { let r = e[fe]; if (!r || !dc() || n && (Cv(n) || Va(r, n.index - I)))
    return; let i = e[m], s = i.data[t]; function a() { if (mE(o)) {
    let p = bi(r, i, e, n);
    return n.type & 8 ? p : p.firstChild;
} return r?.firstChild; } let c = a(), l = Xv(r) ?? new Set, u = r.i18nNodes ??= new Map, d = r.data[xa]?.[t - I] ?? [], f = r.dehydratedIcuData ??= new Map; lo({ hydrationInfo: r, lView: e, i18nNodes: u, disconnectedNodes: l, caseQueue: d, dehydratedIcuData: f }, { currentNode: c, isConnected: !0 }, s.ast), r.disconnectedNodes = l.size === 0 ? null : l; }
function lo(e, t, n) { if (Array.isArray(n)) {
    let o = t;
    for (let r of n) {
        let i = SA(e.hydrationInfo, e.lView, r.index - I);
        i && (o = Eu(t, i)), lo(e, o, r);
    }
}
else {
    if (e.disconnectedNodes.has(n.index - I))
        return;
    switch (n.kind) {
        case 0: {
            let o = Ar(e, t, n);
            In(t, o?.nextSibling ?? null);
            break;
        }
        case 1: {
            lo(e, Eu(t, t.currentNode?.firstChild ?? null), n.children);
            let o = Ar(e, t, n);
            In(t, o?.nextSibling ?? null);
            break;
        }
        case 2: {
            let o = n.index - I, { hydrationInfo: r } = e, i = Kv(r, o);
            switch (n.type) {
                case 0: {
                    let s = Ar(e, t, n);
                    if ($_(r, o)) {
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
                    Ar(e, t, n);
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
            let i = Ar(e, t, n);
            In(t, i?.nextSibling ?? null);
            break;
        }
    }
} }
var _E = () => { };
function VA(e, t, n) { _E(e, t, n); }
function SE() { _E = HA; }
function HA(e, t, n) { let o = e[fe]?.dehydratedIcuData; o && o.get(t)?.case === n && o.delete(t); }
function BA(e) { let t = e[fe]; if (t) {
    let { i18nNodes: n, dehydratedIcuData: o } = t;
    if (n && o) {
        let r = e[N];
        for (let i of o.values())
            $A(r, n, i);
    }
    t.i18nNodes = void 0, t.dehydratedIcuData = void 0;
} }
function $A(e, t, n) { for (let o of n.node.cases[n.case]) {
    let r = t.get(o.index - I);
    r && Mi(e, r, !1);
} }
function fc(e) { let t = e[je] ?? [], o = e[z][N], r = []; for (let i of t)
    i.data[Oa] !== void 0 ? r.push(i) : bE(i, o); e[je] = r; }
function UA(e) { let { lContainer: t } = e, n = t[je]; if (n === null)
    return; let r = t[z][N]; for (let i of n)
    bE(i, r); }
function bE(e, t) { let n = 0, o = e.firstChild; if (o) {
    let r = e.data[kt];
    for (; n < r;) {
        let i = o.nextSibling;
        Mi(t, o, !1), o = i, n++;
    }
} }
function pc(e) { fc(e); let t = e[H]; J(t) && ei(t); for (let n = U; n < e.length; n++)
    ei(e[n]); }
function ei(e) { BA(e); let t = e[m]; for (let n = I; n < t.bindingStartIndex; n++)
    if (K(e[n])) {
        let o = e[n];
        pc(o);
    }
    else
        J(e[n]) && ei(e[n]); }
function Bf(e) { let t = e._views; for (let n of t) {
    let o = of(n);
    o !== null && o[H] !== null && (J(o) ? ei(o) : pc(o));
} }
function qA(e, t, n, o) { e !== null && (n.cleanup(t), pc(e.lContainer), Bf(o)); }
function GA(e, t) { let n = []; for (let o of t)
    for (let r = 0; r < (o[vi] ?? 1); r++) {
        let i = { data: o, firstChild: null };
        o[kt] > 0 && (i.firstChild = e, e = uc(o[kt], e)), n.push(i);
    } return [e, n]; }
var AE = () => null, RE = () => null;
function kE() { AE = WA, RE = zA; }
function WA(e, t) { return OE(e, t) ? e[je].shift() : (fc(e), null); }
function ti(e, t) { return AE(e, t); }
function zA(e, t, n) { if (t.tView.ssrId === null)
    return null; let o = ti(e, t.tView.ssrId); return n[m].firstUpdatePass && o === null && QA(n, t), o; }
function xE(e, t, n) { return RE(e, t, n); }
function QA(e, t) { let n = t; for (; n;) {
    if (Jg(e, n))
        return;
    if ((n.flags & 256) === 256)
        break;
    n = n.prev;
} for (n = t.next; n && (n.flags & 512) === 512;) {
    if (Jg(e, n))
        return;
    n = n.next;
} }
function OE(e, t) { let n = e[je]; return !t || n === null || n.length === 0 ? !1 : n[0].data[ka] === t; }
function Jg(e, t) { let n = t.tView?.ssrId; if (n == null)
    return !1; let o = e[t.index]; return K(o) && OE(o, n) ? (fc(o), !0) : !1; }
var PE = class {
}, ni = class {
}, ZA = (() => { class e {
    destroyNode = null;
    static __NG_ELEMENT_ID__ = () => YA();
} return e; })();
function YA() { let e = g(), t = _(), n = me(t.index, e); return (J(n) ? n : e)[N]; }
var LE = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => null });
} return e; })();
function $f(e) { return e.ngModule !== void 0; }
function Dn(e) { return !!Zn(e); }
function Fs(e) { return !!tt(e); }
function Xg(e) { return !!Oe(e); }
function Lr(e) { return !!W(e); }
function KA(e) { return W(e) ? "component" : Oe(e) ? "directive" : tt(e) ? "pipe" : "type"; }
function JA(e, t) { if (lr(e) && (e = L(e), !e))
    throw new Error(`Expected forwardRef function, imported from "${qe(t)}", to return a standalone entity or NgModule but got "${qe(e) || e}".`); if (Zn(e) == null) {
    let n = W(e) || Oe(e) || tt(e);
    if (n != null) {
        if (!n.standalone) {
            let o = KA(e);
            throw new Error(`The "${qe(e)}" ${o}, imported from "${qe(t)}", is not standalone. Does the ${o} have the standalone: false flag?`);
        }
    }
    else
        throw $f(e) ? new Error(`A module with providers was imported from "${qe(t)}". Modules with providers are not supported in standalone components imports.`) : new Error(`The "${qe(e)}" type, imported from "${qe(t)}", must be a standalone component / directive / pipe or an NgModule. Did you forget to add the required @Component / @Directive / @Pipe or @NgModule annotation?`);
} }
var dd = class {
    ownerNgModule = new WeakMap;
    ngModulesWithSomeUnresolvedDecls = new Set;
    ngModulesScopeCache = new WeakMap;
    standaloneComponentsScopeCache = new WeakMap;
    resolveNgModulesDecls() { if (this.ngModulesWithSomeUnresolvedDecls.size !== 0) {
        for (let t of this.ngModulesWithSomeUnresolvedDecls) {
            let n = Zn(t);
            if (n?.declarations)
                for (let o of kr(n.declarations))
                    Lr(o) && this.ownerNgModule.set(o, t);
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
    computeNgModuleScope(t) { let n = rs(t), o = { exported: { directives: new Set, pipes: new Set }, compilation: { directives: new Set, pipes: new Set } }; for (let r of kr(n.imports))
        if (Dn(r)) {
            let i = this.getNgModuleScope(r);
            Xt(i.exported.directives, o.compilation.directives), Xt(i.exported.pipes, o.compilation.pipes);
        }
        else if (hr(r))
            if (Xg(r) || Lr(r))
                o.compilation.directives.add(r);
            else if (Fs(r))
                o.compilation.pipes.add(r);
            else
                throw new D(980, "The standalone imported type is neither a component nor a directive nor a pipe");
        else {
            o.compilation.isPoisoned = !0;
            break;
        } if (!o.compilation.isPoisoned)
        for (let r of kr(n.declarations)) {
            if (Dn(r) || hr(r)) {
                o.compilation.isPoisoned = !0;
                break;
            }
            Fs(r) ? o.compilation.pipes.add(r) : o.compilation.directives.add(r);
        } for (let r of kr(n.exports))
        if (Dn(r)) {
            let i = this.getNgModuleScope(r);
            Xt(i.exported.directives, o.exported.directives), Xt(i.exported.pipes, o.exported.pipes), Xt(i.exported.directives, o.compilation.directives), Xt(i.exported.pipes, o.compilation.pipes);
        }
        else
            Fs(r) ? o.exported.pipes.add(r) : o.exported.directives.add(r); return o; }
    getStandaloneComponentScope(t, n) { if (this.standaloneComponentsScopeCache.has(t))
        return this.standaloneComponentsScopeCache.get(t); let o = this.computeStandaloneComponentScope(t, n); return this.standaloneComponentsScopeCache.set(t, o), o; }
    computeStandaloneComponentScope(t, n) { let o = { compilation: { directives: new Set([t]), pipes: new Set, ngModules: new Set } }; for (let r of nt(n ?? [])) {
        let i = L(r);
        try {
            JA(i, t);
        }
        catch {
            return o.compilation.isPoisoned = !0, o;
        }
        if (Dn(i)) {
            o.compilation.ngModules.add(i);
            let s = this.getNgModuleScope(i);
            if (s.exported.isPoisoned)
                return o.compilation.isPoisoned = !0, o;
            Xt(s.exported.directives, o.compilation.directives), Xt(s.exported.pipes, o.compilation.pipes);
        }
        else if (Fs(i))
            o.compilation.pipes.add(i);
        else if (Xg(i) || Lr(i))
            o.compilation.directives.add(i);
        else
            return o.compilation.isPoisoned = !0, o;
    } return o; }
    isOrphanComponent(t) { let n = W(t); return !n || n.standalone ? !1 : (this.resolveNgModulesDecls(), !this.ownerNgModule.has(t)); }
};
function Xt(e, t) { for (let n of e)
    t.add(n); }
var wo = new dd;
function XA(e, t) { let n = e; for (; n;) {
    let o = a_(n);
    if (o !== null)
        for (let r = I; r < o.length; r++) {
            let i = o[r];
            if (!J(i) && !K(i) || i[H] !== n)
                continue;
            let s = o[m], a = Yt(s, r);
            if (Ce(a)) {
                let c = s.data[a.directiveStart + a.componentOffset], l = Uf(c);
                if (l !== null && (!t || t(n, l)))
                    return l;
                break;
            }
        }
    n = n.parentNode;
} return null; }
function Uf(e) { return e.debugInfo?.className || e.type.name || null; }
var zs = {}, tn = class {
    injector;
    parentInjector;
    constructor(t, n) { this.injector = t, this.parentInjector = n; }
    get(t, n, o) { let r = this.injector.get(t, zs, o); return r !== zs || n === zs ? r : this.parentInjector.get(t, n, o); }
};
function oi(e) { return hc(e) ? Array.isArray(e) || !(e instanceof Map) && Symbol.iterator in e : !1; }
function eR(e, t, n) { let o = e[Symbol.iterator](), r = t[Symbol.iterator](); for (;;) {
    let i = o.next(), s = r.next();
    if (i.done && s.done)
        return !0;
    if (i.done || s.done || !n(i.value, s.value))
        return !1;
} }
function FE(e, t) { if (Array.isArray(e))
    for (let n = 0; n < e.length; n++)
        t(e[n]);
else {
    let n = e[Symbol.iterator](), o;
    for (; !(o = n.next()).done;)
        t(o.value);
} }
function hc(e) { return e !== null && (typeof e == "function" || typeof e == "object"); }
function jE(e, t) { let n = oi(e), o = oi(t); return n && o ? eR(e, t, jE) : !n && (e && (typeof e == "object" || typeof e == "function")) && !o && (t && (typeof t == "object" || typeof t == "function")) ? !0 : Object.is(e, t); }
function st(e, t, n) { return e[t] = n; }
function Go(e, t) { return e[t]; }
function Z(e, t, n) { if (n === $)
    return !1; let o = e[t]; return Object.is(o, n) ? !1 : (e[t] = n, !0); }
function Rn(e, t, n, o) { let r = Z(e, t, n); return Z(e, t + 1, o) || r; }
function gc(e, t, n, o, r) { let i = Rn(e, t, n, o); return Z(e, t + 2, r) || i; }
function Ke(e, t, n, o, r, i) { let s = Rn(e, t, n, o); return Rn(e, t + 2, r, i) || s; }
function nn(e, t, n) { return function o(r) { let i = o.__ngNativeEl__; i !== void 0 && R_(r, i); let s = Ce(e) ? me(e.index, t) : t; ac(s, 5); let a = t[B], c = em(t, a, n, r), l = o.__ngNextListenerFn__; for (; l;)
    c = em(t, a, l, r) && c, l = l.__ngNextListenerFn__; return c; }; }
function em(e, t, n, o) { let r = uo(null); try {
    return V(P.OutputStart, t, n), n(o) !== !1;
}
catch (i) {
    return Lf(e, i), !1;
}
finally {
    V(P.OutputEnd, t, n), uo(r);
} }
function qf(e, t, n, o, r, i, s, a) { let c = Xn(e), l = !1, u = null; if (!o && c && (u = nR(t, n, i, e.index)), u !== null) {
    let d = u.__ngLastListenerFn__ || u;
    d.__ngNextListenerFn__ = s, u.__ngLastListenerFn__ = s, l = !0;
}
else {
    let d = ie(e, n), f = o ? o(d) : d;
    k_(n, f, i, a), o || (a.__ngNativeEl__ = d);
    let p = r.listen(f, i, a);
    if (!tR(i)) {
        let h = o ? v => o(O(v[e.index])) : e.index;
        VE(h, t, n, i, a, p, !1);
    }
} return l; }
function tR(e) { return e.startsWith("animation") || e.startsWith("transition"); }
function nR(e, t, n, o) { let r = e.cleanup; if (r != null)
    for (let i = 0; i < r.length - 1; i += 2) {
        let s = r[i];
        if (s === n && r[i + 1] === o) {
            let a = t[zt], c = r[i + 2];
            return a && a.length > c ? a[c] : null;
        }
        typeof s == "string" && (i += 2);
    } return null; }
function VE(e, t, n, o, r, i, s) { let a = t.firstCreatePass ? Ol(t) : null, c = xl(n), l = c.length; c.push(r, i), a && a.push(o, e, l, (l + 1) * (s ? -1 : 1)); }
function oR(e, t, n, o, r) { let i = nn(e, t, n), s = fd(e, t, o, r, i); }
function fd(e, t, n, o, r) { let i = null, s = null, a = null, c = !1, l = e.directiveToIndex.get(n.type); if (typeof l == "number" ? i = l : [i, s, a] = l, s !== null && a !== null && e.hostDirectiveOutputs?.hasOwnProperty(o)) {
    let u = e.hostDirectiveOutputs[o];
    for (let d = 0; d < u.length; d += 2) {
        let f = u[d];
        if (f >= s && f <= a)
            c = !0, ha(e, t, f, u[d + 1], o, r);
        else if (f > a)
            break;
    }
} return n.outputs.hasOwnProperty(o) && (c = !0, ha(e, t, i, o, o, r)), c; }
function ha(e, t, n, o, r, i) { let s = t[n], a = t[m], l = a.data[n].outputs[o], d = s[l].subscribe(i); VE(e.index, a, t, r, i, d, !0); }
function HE() { BE(); }
function BE() { let e = g(), t = A(), n = _(); if (t.firstCreatePass && rR(t, n), n.controlDirectiveIndex === -1)
    return; te("NgSignalForms"); let o = e[n.controlDirectiveIndex]; t.data[n.controlDirectiveIndex].controlDef.create(o, new ga(e, t, n)); }
function $E() { UE(); }
function UE() { let e = g(), t = A(), n = Ve(); if (n.controlDirectiveIndex === -1)
    return; let o = t.data[n.controlDirectiveIndex].controlDef, r = e[n.controlDirectiveIndex]; o.update(r, new ga(e, t, n)); }
var ga = class {
    lView;
    tView;
    tNode;
    hasPassThrough;
    constructor(t, n, o) { this.lView = t, this.tView = n, this.tNode = o, this.hasPassThrough = !!(o.flags & 4096); }
    get customControl() { return this.tNode.customControlIndex !== -1 ? this.lView[this.tNode.customControlIndex] : void 0; }
    get nativeElement() { return ie(this.tNode, this.lView); }
    get descriptor() { return `<${this.tNode.value}>`; }
    listenToCustomControlOutput(t, n) { let o = this.tView.data[this.tNode.customControlIndex]; fd(this.tNode, this.lView, o, t, nn(this.tNode, this.lView, n)); }
    listenToCustomControlModel(t) { let n = this.tNode.flags & 1024 ? "valueChange" : "checkedChange", o = this.tView.data[this.tNode.customControlIndex]; fd(this.tNode, this.lView, o, n, nn(this.tNode, this.lView, t)); }
    listenToDom(t, n) { qf(this.tNode, this.tView, this.lView, void 0, this.lView[N], t, n, nn(this.tNode, this.lView, n)); }
    setInputOnDirectives(t, n) { let o = this.tNode.inputs?.[t], r = this.tNode.hostDirectiveInputs?.[t]; if (!o && !r)
        return !1; let i = !1; if (o)
        for (let s of o) {
            if (s === this.tNode.controlDirectiveIndex)
                continue;
            let a = this.tView.data[s], c = this.lView[s];
            Sn(a, c, t, n), i = !0;
        } if (r)
        for (let s = 0; s < r.length; s += 2) {
            let a = r[s];
            if (a === this.tNode.controlDirectiveIndex)
                continue;
            let c = r[s + 1], l = this.tView.data[a], u = this.lView[a];
            Sn(l, u, c, n), i = !0;
        } return i; }
    setCustomControlModelInput(t) { let n = this.tView.data[this.tNode.customControlIndex], o = this.tNode.flags & 1024 ? "value" : "checked"; Jy(this.tNode, this.tView, this.lView, n, o, t); }
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
                let i = tm(r.directive);
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
                let s = tm(i.directive);
                s !== null && o.push(...s);
            }
        }
    } return n; }
};
function tm(e) { return typeof e == "function" && "\u0275dir" in e ? e.\u0275dir.hostDirectives ?? null : null; }
function rR(e, t, n) { for (let r = t.directiveStart; r < t.directiveEnd; r++)
    if (e.data[r].controlDef) {
        t.controlDirectiveIndex = r;
        break;
    } if (t.controlDirectiveIndex === -1)
    return; let o = e.data[t.controlDirectiveIndex].controlDef; if (o.passThroughInput && (t.inputs?.[o.passThroughInput]?.length ?? 0) > 1) {
    t.flags |= 4096;
    return;
} iR(e, t); }
function iR(e, t) { for (let n = t.directiveStart; n < t.directiveEnd; n++) {
    let o = e.data[n];
    if (!(t.directiveToIndex && !t.directiveToIndex.has(o.type))) {
        if (nm(o, "value")) {
            t.flags |= 1024, t.customControlIndex = n;
            return;
        }
        if (nm(o, "checked")) {
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
function nm(e, t) { return sR(e, t) && aR(e, t + "Change"); }
function sR(e, t) { return t in e.inputs; }
function aR(e, t) { return t in e.outputs; }
var Rt = Symbol("BINDING"), om = { kind: "input", requiredVars: 1 }, cR = { kind: "output", requiredVars: 0 };
function rm(e, t, n) { let o = g(), r = De(); if (Z(o, r, n)) {
    let i = o[m], s = Ve(), a = me(s.index, o);
    ac(a, 1);
    let c = i.directiveRegistry[e], l = Jy(s, i, o, c, t, n);
} }
function qE(e, t) { if (e === "formField") {
    let o = { [Rt]: om, create: () => { BE(); }, update: () => { rm(o.targetIdx, e, t()), UE(); } };
    return o;
} let n = { [Rt]: om, update: () => rm(n.targetIdx, e, t()) }; return n; }
function GE(e, t) { let n = { [Rt]: cR, create: () => { let o = g(), r = _(), s = o[m].directiveRegistry[n.targetIdx]; oR(r, o, t, s, e); } }; return n; }
function lR(e, t) { let n = qE(e, t), o = GE(e + "Change", i => t.set(i)); return { [Rt]: { kind: "twoWay", requiredVars: n[Rt].requiredVars + o[Rt].requiredVars }, set targetIdx(i) { n.targetIdx = i, o.targetIdx = i; }, create: o.create, update: n.update }; }
var WE = new C("");
function ma(e, t, n) { let o = n ? e.styles : null, r = n ? e.classes : null, i = 0; if (t !== null)
    for (let s = 0; s < t.length; s++) {
        let a = t[s];
        if (typeof a == "number")
            i = a;
        else if (i == 1)
            r = ns(r, a);
        else if (i == 2) {
            let c = a, l = t[++s];
            o = ns(o, c + ": " + l + ";");
        }
    } n ? e.styles = o : e.stylesWithoutHost = o, n ? e.classes = r : e.classesWithoutHost = r; }
function Wo(e, t = 0) { let n = g(); if (n === null)
    return he(e, t); let o = _(); return lv(o, n, L(e), t); }
function zE() { let e = "invalid"; throw new Error(e); }
function QE(e, t, n, o, r) { let i = o === null ? null : { "": -1 }, s = r(e, n); if (s !== null) {
    let a = s, c = null, l = null;
    for (let u of s)
        if (u.resolveHostDirectives !== null) {
            [a, c, l] = u.resolveHostDirectives(s);
            break;
        }
    fR(e, t, n, a, i, c, l);
} i !== null && o !== null && uR(n, o, i); }
function uR(e, t, n) { let o = e.localNames = []; for (let r = 0; r < t.length; r += 2) {
    let i = n[t[r + 1]];
    if (i == null)
        throw new D(-301, !1);
    o.push(t[r], i);
} }
function dR(e, t, n) { t.componentOffset = n, (e.components ??= []).push(t.index); }
function fR(e, t, n, o, r, i, s) { let a = o.length, c = null; for (let f = 0; f < a; f++) {
    let p = o[f];
    c === null && Qe(p) && (c = p, dR(e, n, f)), Ou(ta(n, t), e, p.type);
} yR(n, e.data.length, a), c?.viewProvidersResolver && c.viewProvidersResolver(c); for (let f = 0; f < a; f++) {
    let p = o[f];
    p.providersResolver && p.providersResolver(p);
} let l = !1, u = !1, d = Ni(e, t, a, null); a > 0 && (n.directiveToIndex = new Map); for (let f = 0; f < a; f++) {
    let p = o[f];
    if (n.mergedAttrs = To(n.mergedAttrs, p.hostAttrs), hR(e, n, t, d, p), vR(d, p, r), s !== null && s.has(p)) {
        let [v, y] = s.get(p);
        n.directiveToIndex.set(p.type, [d, v + n.directiveStart, y + n.directiveStart]);
    }
    else
        (i === null || !i.has(p)) && n.directiveToIndex.set(p.type, d);
    p.contentQueries !== null && (n.flags |= 4), (p.hostBindings !== null || p.hostAttrs !== null || p.hostVars !== 0) && (n.flags |= 64);
    let h = p.type.prototype;
    !l && (h.ngOnChanges || h.ngOnInit || h.ngDoCheck) && ((e.preOrderHooks ??= []).push(n.index), l = !0), !u && (h.ngOnChanges || h.ngDoCheck) && ((e.preOrderCheckHooks ??= []).push(n.index), u = !0), d++;
} pR(e, n, i); }
function pR(e, t, n) { for (let o = t.directiveStart; o < t.directiveEnd; o++) {
    let r = e.data[o];
    if (n === null || !n.has(r))
        im(0, t, r, o), im(1, t, r, o), am(t, o, !1);
    else {
        let i = n.get(r);
        sm(0, t, i, o), sm(1, t, i, o), am(t, o, !0);
    }
} }
function im(e, t, n, o) { let r = e === 0 ? n.inputs : n.outputs; for (let i in r)
    if (r.hasOwnProperty(i)) {
        let s;
        e === 0 ? s = t.inputs ??= {} : s = t.outputs ??= {}, s[i] ??= [], s[i].push(o), ZE(t, i);
    } }
function sm(e, t, n, o) { let r = e === 0 ? n.inputs : n.outputs; for (let i in r)
    if (r.hasOwnProperty(i)) {
        let s = r[i], a;
        e === 0 ? a = t.hostDirectiveInputs ??= {} : a = t.hostDirectiveOutputs ??= {}, a[s] ??= [], a[s].push(o, i), ZE(t, s);
    } }
function ZE(e, t) { t === "class" ? e.flags |= 8 : t === "style" && (e.flags |= 16); }
function am(e, t, n) { let { attrs: o, inputs: r, hostDirectiveInputs: i } = e; if (o === null || !n && r === null || n && i === null || vf(e)) {
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
function hR(e, t, n, o, r) { e.data[o] = r; let i = r.factory || (r.factory = Ut(r.type, !0)), s = new Nn(i, Qe(r), Wo, null); e.blueprint[o] = s, n[o] = s, gR(e, t, o, Ni(e, n, r.hostVars, $), r); }
function gR(e, t, n, o, r) { let i = r.hostBindings; if (i) {
    let s = e.hostBindingOpCodes;
    s === null && (s = e.hostBindingOpCodes = []);
    let a = ~t.index;
    mR(s) != a && s.push(a), s.push(n, o, i);
} }
function mR(e) { let t = e.length; for (; t > 0;) {
    let n = e[--t];
    if (typeof n == "number" && n < 0)
        return n;
} return 0; }
function vR(e, t, n) { if (n) {
    if (t.exportAs)
        for (let o = 0; o < t.exportAs.length; o++)
            n[t.exportAs[o]] = e;
    Qe(t) && (n[""] = e);
} }
function yR(e, t, n) { e.flags |= 1, e.directiveStart = t, e.directiveEnd = t + n, e.providerIndexes = t; }
function Gf(e, t, n, o, r, i, s, a) { let c = t[m], l = c.consts, u = ve(l, s), d = $n(c, e, n, o, u); return i && QE(c, t, d, ve(l, a), r), d.mergedAttrs = To(d.mergedAttrs, d.attrs), d.attrs !== null && ma(d, d.attrs, !1), d.mergedAttrs !== null && ma(d, d.mergedAttrs, !0), c.queries !== null && c.queries.elementStart(c, d), d; }
function Wf(e, t) { Xm(e, t), Sl(t) && e.queries.elementEnd(t); }
function YE(e, t, n, o, r, i) { let s = t.consts, a = ve(s, r), c = $n(t, e, n, o, a); if (c.mergedAttrs = To(c.mergedAttrs, c.attrs), i != null) {
    let l = ve(s, i);
    c.localNames = [];
    for (let u = 0; u < l.length; u += 2)
        c.localNames.push(l[u], -1);
} return c.attrs !== null && ma(c, c.attrs, !1), c.mergedAttrs !== null && ma(c, c.mergedAttrs, !0), t.queries !== null && t.queries.elementStart(t, c), c; }
var KE = typeof ShadowRoot < "u", ER = typeof Document < "u";
function IR(e) { return Object.keys(e).map(t => { let [n, o, r] = e[t], i = { propName: n, templateName: t, isSignal: (o & Ga.SignalBased) !== 0 }; return r && (i.transform = r), i; }); }
function DR(e) { return Object.keys(e).map(t => ({ propName: e[t], templateName: t })); }
function TR(e, t, n) { let o = t instanceof be ? t : t?.injector; return o && e.getStandaloneInjector !== null && (o = e.getStandaloneInjector(o) || o), o ? new tn(n, o) : n; }
function CR(e) { let t = e.get(ni, null); if (t === null)
    throw new D(407, !1); let n = e.get(LE, null), o = e.get(Ue, null), r = e.get(Bn, null, { optional: !0 }); return { rendererFactory: t, sanitizer: n, changeDetectionScheduler: o, ngReflect: !1, tracingService: r }; }
function MR(e, t) { let n = JE(e); return $a(t, n, n === "svg" ? ps : n === "math" ? hs : null); }
function JE(e) { return (e.selectors[0][0] || "div").toLowerCase(); }
var kn = class {
    componentDef;
    ngModule;
    selector;
    componentType;
    ngContentSelectors;
    isBoundToModule;
    cachedInputs = null;
    cachedOutputs = null;
    get inputs() { return this.cachedInputs ??= IR(this.componentDef.inputs), this.cachedInputs; }
    get outputs() { return this.cachedOutputs ??= DR(this.componentDef.outputs), this.cachedOutputs; }
    constructor(t, n) { this.componentDef = t, this.ngModule = n, this.componentType = t.type, this.selector = YS(t.selectors), this.ngContentSelectors = t.ngContentSelectors ?? [], this.isBoundToModule = !!n; }
    create(t, n, o, r, i, s) { V(P.DynamicComponentStart); let a = k(null); try {
        let c = this.componentDef, l = TR(c, r || this.ngModule, t), u = CR(l), d = u.tracingService;
        return d && d.componentCreate ? d.componentCreate(Uf(c), () => this.createComponentRef(u, l, n, o, i, s)) : this.createComponentRef(u, l, n, o, i, s);
    }
    finally {
        k(a);
    } }
    createComponentRef(t, n, o, r, i, s) { let a = this.componentDef, c = wR(r, a, s, i), l = t.rendererFactory.createRenderer(null, a), u = r ? _b(l, r, a.encapsulation, n) : MR(a, l), d = n.get(WE, null), f = NR(u, () => n.get(Nt, null) ?? gi()); d && d.addHost(f); let p = s?.some(cm) || i?.some(y => typeof y != "function" && y.bindings.some(cm)), h = qa(null, c, null, 512 | Ef(a), null, null, t, l, n, null, Zv(u, n, !0)); d && KE && f instanceof ShadowRoot && to(h, () => { d.removeHost(f); }), h[I] = u, Ts(h); let v = null; try {
        let y = Gf(I, h, 2, "#host", () => c.directiveRegistry, !0, 0);
        yy(l, u, y), Ze(u, h), ec(c, h, y), af(c, y, h), Wf(c, y), o !== void 0 && SR(y, this.ngContentSelectors, o), v = me(y.index, h), h[B] = v[B], ic(c, h, null);
    }
    catch (y) {
        throw v !== null && Fu(v), Fu(h), y;
    }
    finally {
        V(P.DynamicComponentEnd), Cs();
    } return new va(this.componentType, h, !!p); }
};
function wR(e, t, n, o) { let r = e ? ["ng-version", "22.0.0"] : KS(t.selectors[0]), i = null, s = null, a = 0; if (n)
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
    } return yf(0, null, _R(i, s), 1, a, c, null, null, null, [r], null); }
function NR(e, t) { let n = e.getRootNode?.(); return ER && n instanceof Document ? n.head : n && KE && n instanceof ShadowRoot ? n : t().head; }
function _R(e, t) { return !e && !t ? null : n => { if (n & 1 && e)
    for (let o of e)
        o.create(); if (n & 2 && t)
    for (let o of t)
        o.update(); }; }
function cm(e) { let t = e[Rt].kind; return t === "input" || t === "twoWay"; }
var va = class extends PE {
    _rootLView;
    _hasInputBindings;
    instance;
    hostView;
    changeDetectorRef;
    componentType;
    location;
    previousInputValues = null;
    _tNode;
    constructor(t, n, o) { super(), this._rootLView = n, this._hasInputBindings = o, this._tNode = Yt(n[m], I), this.location = xo(this._tNode, n), this.instance = me(this._tNode.index, n)[B], this.hostView = this.changeDetectorRef = new rn(n, void 0), this.componentType = t; }
    setInput(t, n) { this._hasInputBindings; let o = this._tNode; if (this.previousInputValues ??= new Map, this.previousInputValues.has(t) && Object.is(this.previousInputValues.get(t), n))
        return; let r = this._rootLView, i = rc(o, r[m], r, t, n); this.previousInputValues.set(t, n); let s = me(o.index, r); ac(s, 1); }
    get injector() { return new Me(this._tNode, this._rootLView); }
    destroy() { this.hostView.destroy(); }
    onDestroy(t) { this.hostView.onDestroy(t); }
};
function SR(e, t, n) { let o = e.projection = []; for (let r = 0; r < t.length; r++) {
    let i = n[r];
    o.push(i != null && i.length ? Array.from(i) : null);
} }
var mc = (() => { class e {
    static __NG_ELEMENT_ID__ = bR;
} return e; })();
function bR() { let e = _(); return XE(e, g()); }
var pd = class e extends mc {
    _lContainer;
    _hostTNode;
    _hostLView;
    constructor(t, n, o) { super(), this._lContainer = t, this._hostTNode = n, this._hostLView = o; }
    get element() { return xo(this._hostTNode, this._hostLView); }
    get injector() { return new Me(this._hostTNode, this._hostLView); }
    get parentInjector() { let t = jd(this._hostTNode, this._hostLView); if (ov(t)) {
        let n = Xs(t, this._hostLView), o = Js(t), r = n[m].data[o + 8];
        return new Me(r, n);
    }
    else
        return new Me(null, this._hostLView); }
    clear() { for (; this.length > 0;)
        this.remove(this.length - 1); }
    get(t) { let n = lm(this._lContainer); return n !== null && n[t] || null; }
    get length() { return this._lContainer.length - U; }
    createEmbeddedView(t, n, o) { let r, i; typeof o == "number" ? r = o : o != null && (r = o.index, i = o.injector); let s = ti(this._lContainer, t.ssrId), a = t.createEmbeddedViewImpl(n || {}, i, s); return this.insertImpl(a, r, An(this._hostTNode, s)), a; }
    createComponent(t, n, o, r, i, s, a) { let c, l = n || {}; c = l.index, o = l.injector, r = l.projectableNodes, i = l.environmentInjector || l.ngModuleRef, s = l.directives, a = l.bindings; let u = new kn(W(t)), d = o || this.parentInjector; if (!i && u.ngModule == null) {
        let T = this.parentInjector.get(be, null);
        T && (i = T);
    } let f = W(u.componentType ?? {}), p = ti(this._lContainer, f?.id ?? null), h = p?.firstChild ?? null, v = u.create(d, r, h, i, s, a); return this.insertImpl(v.hostView, c, An(this._hostTNode, p)), v; }
    insert(t, n) { return this.insertImpl(t, n, !0); }
    insertImpl(t, n, o) { let r = t._lView; if (sg(r)) {
        let a = this.indexOf(t);
        if (a !== -1)
            this.detach(a);
        else {
            let c = r[z], l = new e(c, c[ce], c[z]);
            l.detach(l.indexOf(t));
        }
    } let i = this._adjustIndex(n), s = this._lContainer; return Uo(s, r, i, o), t.attachToViewContainerRef(), El(Iu(s), i, t), t; }
    move(t, n) { return this.insert(t, n); }
    indexOf(t) { let n = lm(this._lContainer); return n !== null ? n.indexOf(t) : -1; }
    remove(t) { let n = this._adjustIndex(t, -1), o = Jr(this._lContainer, n); o && (mr(Iu(this._lContainer), n), Si(o[m], o)); }
    detach(t) { let n = this._adjustIndex(t, -1), o = Jr(this._lContainer, n); return o && mr(Iu(this._lContainer), n) != null ? new rn(o) : null; }
    _adjustIndex(t, n = 0) { return t ?? this.length + n; }
};
function lm(e) { return e[Tr]; }
function Iu(e) { return e[Tr] || (e[Tr] = []); }
function XE(e, t) { let n, o = t[e.index]; return K(o) ? n = o : (n = cE(o, t, null, e), t[e.index] = n, If(t, n)), eI(n, t, e, o), new pd(n, e, t); }
function AR(e, t) { let n = e[N], o = n.createComment(""), r = ie(t, e), i = n.parentNode(r); return _n(n, i, o, n.nextSibling(r), !1), o; }
var eI = nI, zf = () => !1;
function tI(e, t, n) { return zf(e, t, n); }
function nI(e, t, n, o) { if (e[ot])
    return; let r; n.type & 8 ? r = O(o) : r = AR(t, n), e[ot] = r; }
function RR(e, t, n) { if (e[ot] && e[je])
    return !0; let o = n[fe], r = t.index - I; if (!o || Oo(t) || Va(o, r))
    return !1; let s = $u(o, r), a = o.data[Po]?.[r]; if (a === void 0)
    return !1; let [c, l] = GA(s, a); return e[ot] = c, e[je] = l, !0; }
function kR(e, t, n, o) { zf(e, n, t) || nI(e, t, n, o); }
function oI() { eI = kR, zf = RR; }
var hd = class e {
    queryList;
    matches = null;
    constructor(t) { this.queryList = t; }
    clone() { return new e(this.queryList); }
    setDirty() { this.queryList.setDirty(); }
}, gd = class e {
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
        Zf(t, n).matches !== null && this.queries[n].setDirty(); }
}, ya = class {
    flags;
    read;
    predicate;
    constructor(t, n, o = null) { this.flags = n, this.read = o, typeof t == "string" ? this.predicate = FR(t) : this.predicate = t; }
}, md = class e {
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
}, vd = class e {
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
            this.matchTNodeWithReadOption(t, n, xR(n, i)), this.matchTNodeWithReadOption(t, n, Us(n, t, i, !1, !1));
        }
    else
        o === Xr ? n.type & 4 && this.matchTNodeWithReadOption(t, n, -1) : this.matchTNodeWithReadOption(t, n, Us(n, t, o, !1, !1)); }
    matchTNodeWithReadOption(t, n, o) { if (o !== null) {
        let r = this.metadata.read;
        if (r !== null)
            if (r === hi || r === mc || r === Xr && n.type & 4)
                this.addMatch(n.index, -2);
            else {
                let i = Us(n, t, r, !1, !1);
                i !== null && this.addMatch(n.index, i);
            }
        else
            this.addMatch(n.index, o);
    } }
    addMatch(t, n) { this.matches === null ? this.matches = [t, n] : this.matches.push(t, n); }
};
function xR(e, t) { let n = e.localNames; if (n !== null) {
    for (let o = 0; o < n.length; o += 2)
        if (n[o] === t)
            return n[o + 1];
} return null; }
function OR(e, t) { return e.type & 11 ? xo(e, t) : e.type & 4 ? cc(e, t) : null; }
function PR(e, t, n, o) { return n === -1 ? OR(t, e) : n === -2 ? LR(e, t, o) : Wr(e, e[m], n, t); }
function LR(e, t, n) { if (n === hi)
    return xo(t, e); if (n === Xr)
    return cc(t, e); if (n === mc)
    return XE(t, e); }
function rI(e, t, n, o) { let r = t[ct].queries[o]; if (r.matches === null) {
    let i = e.data, s = n.matches, a = [];
    for (let c = 0; s !== null && c < s.length; c += 2) {
        let l = s[c];
        if (l < 0)
            a.push(null);
        else {
            let u = i[l];
            a.push(PR(t, u, s[c + 1], n.metadata.read));
        }
    }
    r.matches = a;
} return r.matches; }
function yd(e, t, n, o) { let r = e.queries.getByIndex(n), i = r.matches; if (i !== null) {
    let s = rI(e, t, r, n);
    for (let a = 0; a < i.length; a += 2) {
        let c = i[a];
        if (c > 0)
            o.push(s[a / 2]);
        else {
            let l = i[a + 1], u = t[-c];
            for (let d = U; d < u.length; d++) {
                let f = u[d];
                f[Zt] === f[z] && yd(f[m], f, l, o);
            }
            if (u[vn] !== null) {
                let d = u[vn];
                for (let f = 0; f < d.length; f++) {
                    let p = d[f];
                    yd(p[m], p, l, o);
                }
            }
        }
    }
} return o; }
function Qf(e, t) { return e[ct].queries[t].queryList; }
function iI(e, t, n) { let o = new ra((n & 4) === 4); return ag(e, t, o, o.destroy), (t[ct] ??= new gd).queries.push(new hd(o)) - 1; }
function sI(e, t, n) { let o = A(); return o.firstCreatePass && (cI(o, new ya(e, t, n), -1), (t & 2) === 2 && (o.staticViewQueries = !0)), iI(o, g(), t); }
function aI(e, t, n, o) { let r = A(); if (r.firstCreatePass) {
    let i = _();
    cI(r, new ya(t, n, o), i.index), jR(r, e), (n & 2) === 2 && (r.staticContentQueries = !0);
} return iI(r, g(), n); }
function FR(e) { return e.split(",").map(t => t.trim()); }
function cI(e, t, n) { e.queries === null && (e.queries = new md), e.queries.track(new vd(t, n)); }
function jR(e, t) { let n = e.contentQueries || (e.contentQueries = []), o = n.length ? n[n.length - 1] : -1; t !== o && n.push(e.queries.length - 1, t); }
function Zf(e, t) { return e.queries.getByIndex(t); }
function lI(e, t) { let n = e[m], o = Zf(n, t); return o.crossesNgTemplate ? yd(n, e, t, []) : rI(n, e, o, t); }
function Yf(e, t, n) { let o, r = Qi(() => { o._dirtyCounter(); let i = VR(o, e); if (t && i === void 0)
    throw new D(-951, !1); return i; }); return o = r[ae], o._dirtyCounter = mt(0), o._flatValue = void 0, r; }
function Kf(e) { return Yf(!0, !1, e); }
function Jf(e) { return Yf(!0, !0, e); }
function Xf(e) { return Yf(!1, !1, e); }
function uI(e, t) { let n = e[ae]; n._lView = g(), n._queryIndex = t, n._queryList = Qf(n._lView, t), n._queryList.onDirty(() => n._dirtyCounter.update(o => o + 1)); }
function VR(e, t) { let n = e._lView, o = e._queryIndex; if (n === void 0 || o === void 0 || n[w] & 4)
    return t ? void 0 : F; let r = Qf(n, o), i = lI(n, o); return r.reset(i, Dv), t ? r.first : r._changesDetected || e._flatValue === void 0 ? e._flatValue = r.toArray() : e._flatValue; }
function ep(e) { return !!e && typeof e.then == "function"; }
function dI(e) { return !!e && typeof e.subscribe == "function"; }
var xn = class {
}, fI = class {
};
function HR(e, t) { return new No(e, t ?? null, []); }
var No = class extends xn {
    ngModuleType;
    _parent;
    _bootstrapComponents = [];
    _r3Injector;
    instance;
    destroyCbs = [];
    constructor(t, n, o, r = !0) { super(), this.ngModuleType = t, this._parent = n; let i = Zn(t); this._bootstrapComponents = kr(i.bootstrap), this._r3Injector = eu(t, n, [{ provide: xn, useValue: this }, ...o], ar(t), new Set(["environment"])), r && this.resolveInjectorInitializers(); }
    resolveInjectorInitializers() { this._r3Injector.resolveInjectorInitializers(), this.instance = this._r3Injector.get(this.ngModuleType); }
    get injector() { return this._r3Injector; }
    destroy() { let t = this._r3Injector; !t.destroyed && t.destroy(), this.destroyCbs.forEach(n => n()), this.destroyCbs = null; }
    onDestroy(t) { this.destroyCbs.push(t); }
}, _o = class extends fI {
    moduleType;
    constructor(t) { super(), this.moduleType = t; }
    create(t) { return new No(this.moduleType, t, []); }
};
function pI(e, t, n) { return new No(e, t, n, !1); }
var ri = class extends xn {
    injector;
    instance = null;
    constructor(t) { super(); let n = new Xe([...t.providers, { provide: xn, useValue: this }], t.parent || Jn(), t.debugName, new Set(["environment"])); this.injector = n, t.runEnvironmentInitializers && n.resolveInjectorInitializers(); }
    destroy() { this.injector.destroy(); }
    onDestroy(t) { this.injector.onDestroy(t); }
};
function tp(e, t, n = null) { return new ri({ providers: e, parent: t, debugName: n, runEnvironmentInitializers: !0 }).injector; }
var BR = (() => { class e {
    _injector;
    cachedInjectors = new Map;
    constructor(n) { this._injector = n; }
    getOrCreateStandaloneInjector(n) { if (!n.standalone)
        return null; if (!this.cachedInjectors.has(n)) {
        let o = us(!1, n.type), r = o.length > 0 ? tp([o], this._injector, "") : null;
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
function hI(e) { return Et(() => { let t = yI(e), n = Ie(q({}, t), { decls: e.decls, vars: e.vars, template: e.template, consts: e.consts || null, ngContentSelectors: e.ngContentSelectors, onPush: e.changeDetection !== ba.Eager, directiveDefs: null, pipeDefs: null, dependencies: t.standalone && e.dependencies || null, getStandaloneInjector: t.standalone ? r => r.get(BR).getOrCreateStandaloneInjector(n) : null, getExternalStyles: null, signals: e.signals ?? !1, data: e.data || {}, encapsulation: e.encapsulation || Ye.Emulated, styles: e.styles || F, _: null, schemas: e.schemas || null, tView: null, id: "" }); t.standalone && te("NgStandalone"), EI(n); let o = e.dependencies; return n.directiveDefs = Ea(o, gI), n.pipeDefs = Ea(o, tt), n.id = GR(n), n; }); }
function gI(e) { return W(e) || Oe(e); }
function np(e) { return Et(() => ({ type: e.type, bootstrap: e.bootstrap || F, declarations: e.declarations || F, imports: e.imports || F, exports: e.exports || F, transitiveCompileScopes: null, schemas: e.schemas || null, id: e.id || null })); }
function $R(e, t) { if (e == null)
    return wt; let n = {}; for (let o in e)
    if (e.hasOwnProperty(o)) {
        let r = e[o], i, s, a, c;
        Array.isArray(r) ? (a = r[0], i = r[1], s = r[2] ?? i, c = r[3] || null) : (i = r, s = r, a = Ga.None, c = null), n[i] = [o, a, c], t[i] = s;
    } return n; }
function UR(e) { if (e == null)
    return wt; let t = {}; for (let n in e)
    e.hasOwnProperty(n) && (t[e[n]] = n); return t; }
function mI(e) { return Et(() => { let t = yI(e); return EI(t), t; }); }
function vI(e) { return { type: e.type, name: e.name, factory: null, pure: e.pure !== !1, standalone: e.standalone ?? !0, onDestroy: e.type.prototype.ngOnDestroy || null }; }
function yI(e) { let t = {}; return { type: e.type, providersResolver: null, viewProvidersResolver: null, factory: null, hostBindings: e.hostBindings || null, hostVars: e.hostVars || 0, hostAttrs: e.hostAttrs || null, contentQueries: e.contentQueries || null, declaredInputs: t, inputConfig: e.inputs || wt, exportAs: e.exportAs || null, standalone: e.standalone ?? !0, signals: e.signals === !0, selectors: e.selectors || F, viewQuery: e.viewQuery || null, features: e.features || null, setInput: null, resolveHostDirectives: null, hostDirectives: null, controlDef: null, signalFormsInputPresence: null, inputs: $R(e.inputs, t), outputs: UR(e.outputs), debugInfo: null }; }
function EI(e) { e.features?.forEach(t => t(e)); }
function Ea(e, t) { return e ? () => { let n = typeof e == "function" ? e() : e, o = []; for (let r of n) {
    let i = t(r);
    i !== null && o.push(i);
} return o; } : null; }
var qR = new Map;
function GR(e) { let t = 0, n = typeof e.consts == "function" ? "" : e.consts, o = [e.selectors, e.ngContentSelectors, e.hostVars, e.hostAttrs, n, e.vars, e.decls, e.encapsulation, e.standalone, e.signals, e.exportAs, JSON.stringify(e.inputs), JSON.stringify(e.outputs), Object.getOwnPropertyNames(e.type.prototype), !!e.contentQueries, !!e.viewQuery]; for (let i of o.join("|"))
    t = Math.imul(31, t) + i.charCodeAt(0) << 0; return t += 2147483648, "c" + t; }
var Fr = "__ngAsyncComponentMetadataFn__", II = "__ngAsyncMetadataLoaded__";
function WR(e) { let t = e; return t[Fr] === II ? null : t[Fr] ?? null; }
function DI(e, t, n) { let o = e; return o[Fr] = () => Promise.all(t()).then(r => (n(...r), o[Fr] = II, r)), o[Fr]; }
function op(e, t, n, o) { return Et(() => { let r = e; t !== null && (r.hasOwnProperty("decorators") && r.decorators !== void 0 ? r.decorators.push(...t) : r.decorators = t), n !== null && (r.ctorParameters = n), o !== null && (r.hasOwnProperty("propDecorators") && r.propDecorators !== void 0 ? r.propDecorators = q(q({}, r.propDecorators), o) : r.propDecorators = o); }); }
var rp = new C("");
function TI(e) { return Le([{ provide: rp, multi: !0, useValue: e }]); }
var ip = (() => { class e {
    resolve;
    reject;
    initialized = !1;
    done = !1;
    donePromise = new Promise((n, o) => { this.resolve = n, this.reject = o; });
    appInits = E(rp, { optional: !0 }) ?? [];
    injector = E(oe);
    constructor() { }
    runInitializers() { if (this.initialized)
        return; let n = []; for (let r of this.appInits) {
        let i = Ir(this.injector, r);
        if (ep(i))
            n.push(i);
        else if (dI(i)) {
            let s = new Promise((a, c) => { i.subscribe({ complete: a, error: c }); });
            n.push(s);
        }
    } let o = () => { this.done = !0, this.resolve(); }; Promise.all(n).then(() => { o(); }).catch(r => { this.reject(r); }), n.length === 0 && o(), this.initialized = !0; }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Pt({ token: e, factory: e.\u0275fac });
} return e; })(), On = new Map, ii = new Set;
function CI(e) { return Se(this, null, function* () { let t = On; On = new Map; let n = new Map; function o(i) { let s = n.get(i); if (s)
    return s; let a = e(i).then(c => KR(i, c)); return n.set(i, a), a; } let r = Array.from(t).map(a => Se(null, [a], function* ([i, s]) { if (s.styleUrl && s.styleUrls?.length)
    throw new Error("@Component cannot define both `styleUrl` and `styleUrls`. Use `styleUrl` if the component has one stylesheet, or `styleUrls` if it has multiple"); let c = []; s.templateUrl && c.push(o(s.templateUrl).then(f => { s.template = f; })); let l = typeof s.styles == "string" ? [s.styles] : s.styles ?? []; s.styles = l; let { styleUrl: u, styleUrls: d } = s; if (u && (d = [u], s.styleUrl = void 0), d?.length) {
    let f = Promise.all(d.map(p => o(p))).then(p => { l.push(...p), s.styleUrls = void 0; });
    c.push(f);
} yield Promise.all(c), ii.delete(i); })); yield Promise.all(r); }); }
function zR(e, t) { MI(t) && (On.set(e, t), ii.add(e)); }
function QR(e) { return ii.has(e); }
function MI(e) { return !!(e.templateUrl && !e.hasOwnProperty("template") || e.styleUrls?.length || e.styleUrl); }
function ZR() { let e = On; return On = new Map, e; }
function YR(e) { ii.clear(); for (let t of e.keys())
    ii.add(t); On = e; }
function wI() { return On.size === 0; }
function KR(e, t) { return Se(this, null, function* () { if (typeof t == "string")
    return t; if (t.status !== void 0 && t.status !== 200)
    throw new D(918, !1); return t.text(); }); }
var Ed = new Map, NI = !0;
function JR(e, t, n) { if (t && t !== n && NI)
    throw new D(921, !1); }
function sp(e, t) { let n = Ed.get(t) || null; JR(t, n, e), Ed.set(t, e); }
function ap(e) { return Ed.get(e); }
function XR(e) { NI = !e; }
function _I(e) { return t => { t.controlDef = { create: (n, o) => { n?.\u0275ngControlCreate(o); }, update: (n, o) => { n?.\u0275ngControlUpdate?.(o); }, passThroughInput: e }; }; }
function SI(e) { let t = n => { let o = Array.isArray(e); n.hostDirectives === null ? (n.resolveHostDirectives = ek, n.hostDirectives = o ? e.map(Id) : [e]) : o ? n.hostDirectives.unshift(...e.map(Id)) : n.hostDirectives.unshift(e); }; return t.ngInherit = !0, t; }
function ek(e) { let t = [], n = !1, o = null, r = null; for (let i = 0; i < e.length; i++) {
    let s = e[i];
    if (s.hostDirectives !== null) {
        let a = t.length;
        o ??= new Map, r ??= new Map, bI(s, t, o, e), r.set(s, [a, t.length - 1]);
    }
    i === 0 && Qe(s) && (n = !0, t.push(s));
} for (let i = n ? 1 : 0; i < e.length; i++)
    t.push(e[i]); return o !== null && o.forEach((i, s) => { tk(s.declaredInputs, i.inputs); }), [t, o, r]; }
function bI(e, t, n, o) { if (e.hostDirectives !== null)
    for (let r of e.hostDirectives)
        if (typeof r == "function") {
            let i = r();
            for (let s of i)
                um(Id(s), t, n, o);
        }
        else
            um(r, t, n, o); }
function um(e, t, n, o) { let r = Oe(e.directive); if (bI(r, t, n, o), n.has(r)) {
    let i = n.get(r);
    dm(i, e.inputs, "input"), dm(i, e.outputs, "output");
}
else
    o.includes(r) || (n.set(r, e), t.push(r)); }
function dm(e, t, n) { let o = n === "input" ? e.inputs : e.outputs; Object.keys(t).forEach(r => { let i = t[r]; (!o.hasOwnProperty(r) || o[r] === i) && (o[r] = i); }); }
function Id(e) { return typeof e == "function" ? { directive: L(e), inputs: {}, outputs: {} } : { directive: L(e.directive), inputs: fm(e.inputs), outputs: fm(e.outputs) }; }
function fm(e) { let t = {}; if (e !== void 0 && e.length > 0)
    for (let n = 0; n < e.length; n += 2)
        t[e[n]] = e[n + 1]; return t; }
function tk(e, t) { for (let n in t)
    if (t.hasOwnProperty(n)) {
        let o = t[n], r = e[n];
        e[o] = r;
    } }
function nk(e) { return Object.getPrototypeOf(e.prototype).constructor; }
function cp(e) { let t = nk(e.type), n = !0, o = [e]; for (; t;) {
    let r;
    if (Qe(e))
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
            a && ak(e, a);
            let c = r.viewQuery, l = r.contentQueries;
            if (c && ik(e, c), l && sk(e, l), ok(e, r), Wh(e.outputs, r.outputs), Qe(r) && r.data.animation) {
                let u = e.data;
                u.animation = (u.animation || []).concat(r.data.animation);
            }
        }
        let i = r.features;
        if (i)
            for (let s = 0; s < i.length; s++) {
                let a = i[s];
                a && a.ngInherit && a(e), a === cp && (n = !1);
            }
    }
    t = Object.getPrototypeOf(t);
} rk(o); }
function ok(e, t) { for (let n in t.inputs) {
    if (!t.inputs.hasOwnProperty(n) || e.inputs.hasOwnProperty(n))
        continue;
    let o = t.inputs[n];
    o !== void 0 && (e.inputs[n] = o, e.declaredInputs[n] = t.declaredInputs[n]);
} }
function rk(e) { let t = 0, n = null; for (let o = e.length - 1; o >= 0; o--) {
    let r = e[o];
    r.hostVars = t += r.hostVars, r.hostAttrs = To(r.hostAttrs, n = To(n, r.hostAttrs));
} }
function Du(e) { return e === wt ? {} : e === F ? [] : e; }
function ik(e, t) { let n = e.viewQuery; n ? e.viewQuery = (o, r) => { t(o, r), n(o, r); } : e.viewQuery = t; }
function sk(e, t) { let n = e.contentQueries; n ? e.contentQueries = (o, r, i) => { t(o, r, i), n(o, r, i); } : e.contentQueries = t; }
function ak(e, t) { let n = e.hostBindings; n ? e.hostBindings = (o, r) => { t(o, r), n(o, r); } : e.hostBindings = t; }
function AI(e, t, n, o, r, i, s, a) { if (n.firstCreatePass) {
    e.mergedAttrs = To(e.mergedAttrs, e.attrs);
    let u = e.tView = yf(2, e, r, i, s, n.directiveRegistry, n.pipeRegistry, null, n.schemas, n.consts, null);
    n.queries !== null && (n.queries.template(n, e), u.queries = n.queries.embeddedTView(e));
} a && (e.flags |= a), dt(e, !1); let c = RI(n, t, e, o); Sr() && Rf(n, t, c, e), Ze(c, t); let l = cE(c, t, c, e); t[o + I] = l, If(t, l), tI(l, e, t); }
function ck(e, t, n, o, r, i, s, a, c, l, u) { let d = n + I, f; return t.firstCreatePass ? (f = $n(t, d, 4, s || null, a || null), ys() && QE(t, e, f, ve(t.consts, l), Pf), Xm(t, f)) : f = t.data[d], AI(f, e, t, n, o, r, i, c), Xn(f) && ec(t, e, f), l != null && Bo(e, f, u), f; }
function Pn(e, t, n, o, r, i, s, a, c, l, u) { let d = n + I, f; if (t.firstCreatePass) {
    if (f = $n(t, d, 4, s || null, a || null), l != null) {
        let p = ve(t.consts, l);
        f.localNames = [];
        for (let h = 0; h < p.length; h += 2)
            f.localNames.push(p[h], -1);
    }
}
else
    f = t.data[d]; return AI(f, e, t, n, o, r, i, c), l != null && Bo(e, f, u), f; }
function lp(e, t, n, o, r, i, s, a) { let c = g(), l = A(), u = ve(l.consts, i); return ck(c, l, e, t, n, o, r, u, void 0, s, a), lp; }
function up(e, t, n, o, r, i, s, a) { let c = g(), l = A(), u = ve(l.consts, i); return Pn(c, l, e, t, n, o, r, u, void 0, s, a), up; }
var RI = kI;
function kI(e, t, n, o) { return rt(!0), t[N].createComment(""); }
function lk(e, t, n, o) { let r = !Ha(t, n); rt(r); let i = t[fe]?.data[Ra]?.[o] ?? null; if (i !== null && n.tView !== null && n.tView.ssrId === null && (n.tView.ssrId = i), r)
    return kI(e, t); let s = t[fe], a = bi(s, e, t, n); ja(s, o, a); let c = rf(s, o); return uc(c, a); }
function xI() { RI = lk; }
var ue = (function (e) { return e[e.NOT_STARTED = 0] = "NOT_STARTED", e[e.IN_PROGRESS = 1] = "IN_PROGRESS", e[e.COMPLETE = 2] = "COMPLETE", e[e.FAILED = 3] = "FAILED", e; })(ue || {}), pm = 0, uk = 1, Q = (function (e) { return e[e.Placeholder = 0] = "Placeholder", e[e.Loading = 1] = "Loading", e[e.Complete = 2] = "Complete", e[e.Error = 3] = "Error", e; })(Q || {}), si = (function (e) { return e[e.Initial = -1] = "Initial", e; })(si || {}), Eo = 0, Vt = 1, Or = 2, js = 3, dk = 4, fk = 5, vc = 6, pk = 7, Io = 8, hk = 9, dp = (function (e) { return e[e.Manual = 0] = "Manual", e[e.Playthrough = 1] = "Playthrough", e; })(dp || {});
function Ai(e, t, n) { let o = PI(e); t[o] === null && (t[o] = []), t[o].push(n); }
function Qs(e, t) { let n = PI(e), o = t[n]; if (o !== null) {
    for (let r of o)
        r();
    t[n] = null;
} }
function OI(e) { Qs(1, e), Qs(0, e), Qs(2, e); }
function PI(e) { let t = dk; return e === 1 ? t = fk : e === 2 && (t = hk), t; }
function Ri(e) { return e + 1; }
function Ne(e, t) { let n = e[m], o = Ri(t.index); return e[o]; }
function gk(e, t, n) { let o = e[m], r = Ri(t); e[r] = n; }
function pe(e, t) { let n = Ri(t.index); return e.data[n]; }
function mk(e, t, n) { let o = Ri(t); e.data[o] = n; }
function vk(e, t, n) { let o = t[m], r = pe(o, n); switch (e) {
    case Q.Complete: return r.primaryTmplIndex;
    case Q.Loading: return r.loadingTmplIndex;
    case Q.Error: return r.errorTmplIndex;
    case Q.Placeholder: return r.placeholderTmplIndex;
    default: return null;
} }
function Dd(e, t) { return t === Q.Placeholder ? e.placeholderBlockConfig?.[pm] ?? null : t === Q.Loading ? e.loadingBlockConfig?.[pm] ?? null : null; }
function LI(e) { return e.loadingBlockConfig?.[uk] ?? null; }
function hm(e, t) { if (!e || e.length === 0)
    return t; let n = new Set(e); for (let o of t)
    n.add(o); return e.length === n.size ? e : Array.from(n); }
function yk(e, t) { let n = t.primaryTmplIndex + I; return Yt(e, n); }
function FI(e) { return e !== null && typeof e == "object" && typeof e.primaryTmplIndex == "number"; }
function jI(e, t) { let n = null, o = Ri(t.index); return I < o && o < e.bindingStartIndex && (n = pe(e, t)), !!n && FI(n); }
var Ek = (() => { class e {
    cachedInjectors = new Map;
    getOrCreateInjector(n, o, r, i) { if (!this.cachedInjectors.has(n)) {
        let s = r.length > 0 ? tp(r, o, i) : null;
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
function yc(e) { return (t, n) => VI(e, t, n); }
function VI(e, t, n) { let o = n.get(HI), r = n.get(G), i = () => o.remove(t); return o.add(e, t, r), i; }
var HI = (() => { class e {
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
        } Dl(n, i, o, r); }
    removeFromQueue(n, o) { let r = -1; for (let i = 0; i < n.length; i += 2)
        if (n[i + 1] === o) {
            r = i;
            break;
        } return r > -1 && Il(n, r, 2), r; }
    scheduleTimer(n) { let o = () => { this.clearTimeout(), this.executingCallbacks = !0; let i = [...this.current], s = Date.now(); for (let c = 0; c < i.length; c += 2) {
        let l = i[c], u = i[c + 1];
        if (l <= s)
            u();
        else
            break;
    } let a = -1; for (let c = 0; c < this.current.length && this.current[c] <= s; c += 2)
        a = c + 1; if (a >= 0 && Il(this.current, 0, a + 1), this.executingCallbacks = !1, this.deferred.length > 0) {
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
} return e; })(), Ik = new C("DEFER_BLOCK_DEPENDENCY_INTERCEPTOR"), BI = new C("");
function Tu(e, t, n) { return e.get(Ek).getOrCreateInjector(t, e, n, ""); }
function Dk(e, t, n) { if (e instanceof tn) {
    let r = e.injector, i = e.parentInjector, s = Tu(i, t, n);
    return new tn(r, s);
} let o = e.get(be); if (o !== e) {
    let r = Tu(o, t, n);
    return new tn(e, r);
} return Tu(e, t, n); }
function At(e, t, n, o = !1) { let r = n[z], i = r[m]; if (ut(r))
    return; let s = Ne(r, t), a = s[Vt], c = s[pk]; if (!(c !== null && e < c) && mm(a, e) && mm(s[Eo] ?? -1, e)) {
    let l = pe(i, t), d = !o && (typeof ngServerMode > "u" || !ngServerMode) && (LI(l) !== null || Dd(l, Q.Loading) !== null || Dd(l, Q.Placeholder)) ? Td : $I;
    try {
        d(e, s, n, t, r);
    }
    catch (f) {
        Lf(r, f);
    }
} }
function Tk(e, t) { let n = e[je]?.findIndex(r => r.data[Ei] === t[Vt]) ?? -1; return { dehydratedView: n > -1 ? e[je][n] : null, dehydratedViewIx: n }; }
function $I(e, t, n, o, r) { V(P.DeferBlockStateStart); let i = vk(e, r, o); if (i !== null) {
    t[Vt] = e;
    let s = r[m], a = i + I, c = Yt(s, a), l = 0;
    Ff(n, l);
    let u;
    if (e === Q.Complete) {
        let h = pe(s, o), v = h.providers;
        v && v.length > 0 && (u = Dk(r[x], h, v));
    }
    let { dehydratedView: d, dehydratedViewIx: f } = Tk(n, t), p = $o(r, c, null, { injector: u, dehydratedView: d });
    if (Uo(n, p, l, An(c, d)), wr(p), f > -1 && n[je]?.splice(f, 1), (e === Q.Complete || e === Q.Error) && Array.isArray(t[Io])) {
        for (let h of t[Io])
            h();
        t[Io] = null;
    }
} V(P.DeferBlockStateEnd); }
function Ck(e, t, n, o, r) { let i = Date.now(), s = r[m], a = pe(s, o); if (t[Or] === null || t[Or] <= i) {
    t[Or] = null;
    let c = LI(a), l = t[js] !== null;
    if (e === Q.Loading && c !== null && !l) {
        t[Eo] = e;
        let u = gm(c, t, o, n, r);
        t[js] = u;
    }
    else {
        e > Q.Loading && l && (t[js](), t[js] = null, t[Eo] = null), $I(e, t, n, o, r);
        let u = Dd(a, e);
        u !== null && (t[Or] = i + u, gm(u, t, o, n, r));
    }
}
else
    t[Eo] = e; }
function gm(e, t, n, o, r) { return VI(e, () => { let s = t[Eo]; t[Or] = null, t[Eo] = null, s !== null && At(s, n, o); }, r[x]); }
function mm(e, t) { return e < t; }
function zo(e, t) { let n = e[t.index]; At(Q.Placeholder, t, n); }
function vm(e, t, n) { e.loadingPromise.then(() => { e.loadingState === ue.COMPLETE ? At(Q.Complete, t, n) : e.loadingState === ue.FAILED && At(Q.Error, t, n); }); }
var Td = null;
function UI(e, t, n, o) { let r = e.consts; n != null && (t.placeholderBlockConfig = ve(r, n)), o != null && (t.loadingBlockConfig = ve(r, o)), Td === null && (Td = Ck); }
function fp(e, t) { return !(e === 0 && typeof ngServerMode < "u" && ngServerMode || t[x].get(BI, null, { optional: !0 })?.behavior === dp.Manual); }
function pp(e, t, n, o) { let r = n.get(G); return b_(e, () => r.run(t), i => r.runOutsideAngular(() => S_(i)), o); }
function Mk(e, t, n) { return n == null ? e : n >= 0 ? kl(n, e) : e[t.index][U] ?? null; }
function wk(e, t) { return yn(I + t, e); }
function Qo(e, t, n, o, r, i, s, a) { if (!fp(s, e))
    return; let c = e[x], l = c.get(G), u; function d() { if (ut(e)) {
    u.destroy();
    return;
} let f = Ne(e, t), p = f[Vt]; if (p !== si.Initial && p !== Q.Placeholder) {
    u.destroy();
    return;
} let h = Mk(e, t, o); if (!h || (u.destroy(), ut(h)))
    return; let v = wk(h, n), y = r(v, () => { l.run(() => { e !== h && vs(h, y), i(); }); }, c, a); e !== h && to(h, y), Ai(s, f, y); } u = Py({ read: d }, { injector: c }); }
var Nk = (() => { class e {
    log(n) { console.log(n); }
    warn(n) { console.warn(n); }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac, providedIn: "platform" });
} return e; })(), Cd = class {
    resolverToTokenToDependencies = new WeakMap;
    resolverToProviders = new WeakMap;
    resolverToEffects = new WeakMap;
    standaloneInjectorToComponent = new WeakMap;
    reset() { this.resolverToTokenToDependencies = new WeakMap, this.resolverToProviders = new WeakMap, this.standaloneInjectorToComponent = new WeakMap; }
}, _k = new Cd;
function Ec() { return _k; }
var qI = (function (e) { return e[e.Defer = 0] = "Defer", e[e.For = 1] = "For", e; })(qI || {});
function Sk(e) { let { standaloneInjectorToComponent: t } = Ec(); if (t.has(e))
    return t.get(e); let n = e.get(xn, null, { self: !0, optional: !0 }); return n === null || n.instance === null ? null : n.instance.constructor; }
function bk(e) { let t = fi(e), { resolverToProviders: n } = Ec(), o = n.get(t) ?? [], r = Array.from(Eg()).map(i => ({ token: i, isViewProvider: !1, provider: i })); return [...o, ...r]; }
function Ak(e) { let t = new Map, o = Rk(t, new Set); return tr(e, o, [], new Set), t; }
function Rk(e, t) { return (n, o) => { if (e.has(n) || e.set(n, [o]), !t.has(o))
    for (let r of e.keys()) {
        let i = e.get(r), s = Xo(o);
        if (!s) {
            let l = o.ngModule;
            s = Xo(l);
        }
        if (!s)
            return;
        let a = i[0], c = !1;
        gr(s.imports, l => { c || (c = l.ngModule === a || l === a, c && e.get(r)?.unshift(o)); });
    } t.add(o); }; }
function kk(e) { let t = Ec().resolverToProviders.get(e) ?? []; if (xk(e))
    return t; let n = Sk(e); if (n === null)
    return t; let o = Ak(n), r = []; for (let i of t) {
    let s = i.provider, a = s.provide;
    if (a === Ge || a === ls)
        continue;
    let c = o.get(s) ?? [];
    W(n)?.standalone && (c = [n, ...c]), r.push(Ie(q({}, i), { importPath: c }));
} return r; }
function xk(e) { return e instanceof Xe && e.scopes.has("platform"); }
function GI(e) { if (e instanceof Me)
    return bk(e); if (e instanceof be)
    return kk(e); Gt("getInjectorProviders only supports NodeInjector and EnvironmentInjector"); }
function WI(e) { if (e instanceof Me) {
    let t = Vd(e), n = fi(e);
    return ng(n, t), { type: "element", source: ie(n, t) };
} return e instanceof Xe ? { type: "environment", source: e.source ?? null } : e instanceof Ct ? { type: "null", source: null } : null; }
function Ok(e) { return e.kind === "computed"; }
function Pk(e) { return e.kind === "template"; }
function Lk(e) { return e.kind === "signal"; }
function Fk(e) { let t = fi(e); Al(t); let n = Vd(e); og(n); let o = n[t.index]; return J(o) ? o[Ae] ?? null : null; }
var ym = new WeakMap, Em = 0;
function jk(e) { let t = Array.from(e.keys()), n = [], o = []; for (let [r, i] of e.entries()) {
    let s = t.indexOf(r), a = ym.get(r);
    a || (Em++, a = Em.toString(), ym.set(r, a)), Ok(r) ? n.push({ label: r.debugName, value: r.value, kind: r.kind, epoch: r.version, debuggableFn: r.computation, id: a }) : Lk(r) ? n.push({ label: r.debugName, value: r.value, kind: r.kind, epoch: r.version, id: a }) : Pk(r) ? n.push({ label: r.debugName ?? r.lView?.[H]?.tagName?.toLowerCase?.(), kind: r.kind, epoch: r.version, debuggableFn: r.lView?.[B]?.constructor, id: a }) : n.push({ label: r.debugName, kind: r.kind, epoch: r.version, id: a });
    for (let c of i)
        o.push({ consumer: s, producer: t.indexOf(c) });
} return { nodes: n, edges: o }; }
function Vk(e) { let t = e; return e instanceof Me && (t = Vd(e)), (Ec().resolverToEffects.get(t) ?? []).map(r => r instanceof ir ? r[ae] : r.signal[ae]); }
function zI(e, t = new Map) { for (let n of e) {
    if (t.has(n))
        continue;
    let o = [];
    for (let r = n.producers; r !== void 0; r = r.nextProducer) {
        let i = r.producer;
        o.push(i);
    }
    t.set(n, o), zI(o, t);
} return t; }
function QI(e) { let t = null; if (!(e instanceof Me) && !(e instanceof Xe))
    return Gt("getSignalGraph must be called with a NodeInjector or R3Injector"); e instanceof Me && (t = Fk(e)); let n = Vk(e), o = t ? [t, ...n] : n, r = zI(o); return jk(r); }
function Hk() { return te("Chrome DevTools profiling"), () => { }; }
function Bk(e) { let t = e.get(Nt), n = e.get(vt), o = cu(t, n), r = {}; for (let [i, s] of Object.entries(o))
    O_(i) || (r[i] = s); return r; }
var Im = "ng";
function $k(e, t) { Uk(e, t); }
function Uk(e, t) { if (typeof COMPILED > "u" || !COMPILED) {
    let n = Pe;
    n[Im] ??= {}, n[Im][e] = t;
} }
var ZI = new C(""), YI = new C(""), KI = new C("USE_PENDING_TASKS", { providedIn: "root", factory: () => typeof Zone > "u" }), qk = (() => { class e {
    _ngZone;
    registry;
    _isZoneStable = !0;
    _callbacks = [];
    _taskTrackingZone = null;
    _destroyRef;
    pendingTasksInternal = E(gt);
    _usePendingTasks = E(KI);
    constructor(n, o, r) { this._ngZone = n, this.registry = o, ds() && (this._destroyRef = E(Re, { optional: !0 }) ?? void 0), hp || (XI(r), r.addToWindow(o)), this._watchAngularEvents(), n.run(() => { this._taskTrackingZone = typeof Zone > "u" ? null : Zone.current.get("TaskTrackingZone"); }); }
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
    static \u0275fac = function (o) { return new (o || e)(he(G), he(JI), he(YI)); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac });
} return e; })(), JI = (() => { class e {
    _applications = new Map;
    registerApplication(n, o) { this._applications.set(n, o); }
    unregisterApplication(n) { this._applications.delete(n); }
    unregisterAllApplications() { this._applications.clear(); }
    getTestability(n) { return this._applications.get(n) || null; }
    getAllTestabilities() { return Array.from(this._applications.values()); }
    getAllRootElements() { return Array.from(this._applications.keys()); }
    findTestabilityInTree(n, o = !0) { return hp?.findTestabilityInTree(this, n, o) ?? null; }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac, providedIn: "platform" });
} return e; })();
function XI(e) { hp = e; }
var hp, ki = new C("");
function gp() { Oh(() => { let e = ""; throw new D(600, e); }); }
var Gk = 10;
function mp(e, t) { return Array.isArray(t) ? t.reduce(mp, e) : q(q({}, e), t); }
var He = (() => { class e {
    _runningTick = !1;
    _destroyed = !1;
    _destroyListeners = [];
    _views = [];
    internalErrorHandler = E(_t);
    afterRenderManager = E(Za);
    zonelessEnabled = E(so);
    rootEffectScheduler = E(Ns);
    dirtyFlags = 0;
    tracingSnapshot = null;
    allTestViews = new Set;
    autoDetectTestViews = new Set;
    includeAllTestViews = !1;
    afterTick = new zm;
    get allViews() { return [...(this.includeAllTestViews ? this.allTestViews : this.autoDetectTestViews).keys(), ...this._views]; }
    get destroyed() { return this._destroyed; }
    componentTypes = [];
    components = [];
    internalPendingTask = E(gt);
    get isStable() { return this.internalPendingTask.hasPendingTasksObservable.pipe(vN(n => !n)); }
    constructor() { E(Bn, { optional: !0 }); }
    whenStable() { let n; return new Promise(o => { n = this.isStable.subscribe({ next: r => { r && o(); } }); }).finally(() => { n.unsubscribe(); }); }
    _injector = E(be);
    _rendererFactory = null;
    get injector() { return this._injector; }
    bootstrap(n, o) { return this.bootstrapImpl(n, o); }
    bootstrapImpl(n, o, r = oe.NULL) { return this._injector.get(G).run(() => { if (V(P.BootstrapComponentStart), !this._injector.get(ip).done) {
        let T = "";
        throw new D(405, T);
    } let a = W(n), c = this._injector.get(xn), l = new kn(a, c); this.componentTypes.push(n); let { hostElement: u, directives: d, bindings: f } = Wk(o), p = u || l.selector, h = l.create(r, [], p, c.injector, d, f), v = h.location.nativeElement, y = h.injector.get(ZI, null); return y?.registerApplication(v), h.onDestroy(() => { this.detachView(h.hostView), jr(this.components, h), y?.unregisterApplication(v); }), this._loadComponent(h), V(P.BootstrapComponentEnd, h), h; }); }
    tick() { this.zonelessEnabled || (this.dirtyFlags |= 1), this._tick(); }
    _tick() { V(P.ChangeDetectionStart), this.tracingSnapshot !== null ? this.tracingSnapshot.run(Qa.CHANGE_DETECTION, this.tickImpl) : this.tickImpl(); }
    tickImpl = () => { if (this._runningTick)
        throw V(P.ChangeDetectionEnd), new D(101, !1); let n = k(null); try {
        this._runningTick = !0, this.synchronize();
    }
    finally {
        this._runningTick = !1, this.tracingSnapshot?.dispose(), this.tracingSnapshot = null, k(n), this.afterTick.next(), V(P.ChangeDetectionEnd);
    } };
    synchronize() { this._rendererFactory === null && !this._injector.destroyed && (this._rendererFactory = this._injector.get(ni, null, { optional: !0 })); let n = 0; for (; this.dirtyFlags !== 0 && n++ < Gk;) {
        V(P.ChangeDetectionSyncStart);
        try {
            this.synchronizeOnce();
        }
        finally {
            V(P.ChangeDetectionSyncEnd);
        }
    } }
    synchronizeOnce() { this.dirtyFlags & 16 && (this.dirtyFlags &= -17, this.rootEffectScheduler.flush()); let n = !1; if (this.dirtyFlags & 7) {
        let o = !!(this.dirtyFlags & 1);
        this.dirtyFlags &= -8, this.dirtyFlags |= 8;
        for (let { _lView: r } of this.allViews) {
            if (!o && !eo(r))
                continue;
            let i = o && !this.zonelessEnabled ? 0 : 1;
            oE(r, i), n = !0;
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
    static \u0275prov = Pt({ token: e, factory: e.\u0275fac });
} return e; })();
function Wk(e) { return e === void 0 || typeof e == "string" || e instanceof Element ? { hostElement: e } : e; }
function jr(e, t) { let n = e.indexOf(t); n > -1 && e.splice(n, 1); }
function eD(e, t, n) { let o = t.get(zk), r = () => o.remove(e); return o.add(e, n), r; }
function vp(e) { return (t, n) => eD(t, n, e); }
var zk = (() => { class e {
    buckets = new Map;
    callbackBucket = new Map;
    applicationRef = E(He);
    ngZone = E(G);
    idleService = E(Sa);
    add(n, o) { let r = Dm(o); this.callbackBucket.set(n, r); let i = this.buckets.get(r); i == null && (i = { idleId: null, queue: new Set }, this.buckets.set(r, i)), i.queue.add(n), this.scheduleBucket(i, o); }
    remove(n) { let o = this.callbackBucket.get(n); if (o === void 0)
        return; this.callbackBucket.delete(n); let r = this.buckets.get(o); r && (r.queue.delete(n), r.queue.size === 0 && (this.cancelBucket(r), this.buckets.delete(o))); }
    scheduleBucket(n, o) { if (n.idleId !== null)
        return; let r = Dm(o), i = s => { this.cancelBucket(n); for (let a of n.queue)
        if (a(), this.applicationRef._tick(), n.queue.delete(a), this.callbackBucket.delete(a), s && s.timeRemaining() === 0 && !s.didTimeout)
            break; n.queue.size > 0 ? this.scheduleBucket(n, o) : this.buckets.delete(r); }; n.idleId = this.idleService.requestOnIdle(s => this.ngZone.run(() => i(s)), o); }
    cancelBucket(n) { n.idleId !== null && (this.idleService.cancelOnIdle(n.idleId), n.idleId = null); }
    ngOnDestroy() { for (let n of this.buckets.values())
        this.cancelBucket(n); this.buckets.clear(), this.callbackBucket.clear(); }
    static \u0275prov = Y({ token: e, providedIn: "root", factory: () => new e });
} return e; })();
function Dm(e) { return !e || e.timeout == null ? "" : `${e.timeout}`; }
function tD(e) { let t = g(), n = _(); if (zo(t, n), !fp(0, t))
    return; let o = t[x], r = Ne(t, n), i = e(() => _e(0, t, n), o); Ai(0, r, i); }
function nD(e) { if (typeof ngServerMode < "u" && ngServerMode)
    return; let t = g(), n = t[x], o = _(), r = t[m], i = pe(r, o); if (i.loadingState === ue.NOT_STARTED) {
    let s = Ne(t, o), c = e(() => xi(i, t, o), n);
    Ai(1, s, c);
} }
function oD(e, t, n) { if (typeof ngServerMode < "u" && ngServerMode)
    return; let o = t[x], r = Ne(t, n), i = r[vc], s = e(() => Ht(o, i), o); Ai(2, r, s); }
function xi(e, t, n) { Ic(e, t, n); }
function Ic(e, t, n) { let o = t[x], r = t[m]; if (e.loadingState !== ue.NOT_STARTED)
    return e.loadingPromise ?? Promise.resolve(); let i = Ne(t, n), s = yk(r, e); e.loadingState = ue.IN_PROGRESS, Qs(1, i); let a = e.dependencyResolverFn, c = o.get(br).add(); return a ? (e.loadingPromise = Promise.allSettled(a()).then(l => { let u = !1, d = null, f = [], p = []; for (let h = 0; h < l.length; h++) {
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
        Lf(t, y);
    }
}
else {
    e.loadingState = ue.COMPLETE;
    let h = s.tView;
    if (f.length > 0) {
        h.directiveRegistry = hm(h.directiveRegistry, f);
        let v = f.map(T => T.type), y = us(!1, ...v);
        e.providers = y;
    }
    p.length > 0 && (h.pipeRegistry = hm(h.pipeRegistry, p));
} }), e.loadingPromise.finally(() => { e.loadingPromise = null, c(); })) : (e.loadingPromise = Promise.resolve().then(() => { e.loadingPromise = null, e.loadingState = ue.COMPLETE, c(); }), e.loadingPromise); }
function _e(e, t, n) { let o = t[m], r = t[n.index]; if (!fp(e, t))
    return; let i = Ne(t, n), s = pe(o, n); switch (OI(i), s.loadingState) {
    case ue.NOT_STARTED:
        At(Q.Loading, n, r), Ic(s, t, n), s.loadingState === ue.IN_PROGRESS && vm(s, n, r);
        break;
    case ue.IN_PROGRESS:
        At(Q.Loading, n, r), vm(s, n, r);
        break;
    case ue.COMPLETE:
        At(Q.Complete, n, r);
        break;
    case ue.FAILED:
        At(Q.Error, n, r);
        break;
    default:
} }
function Ht(e, t, n) { return Se(this, null, function* () { let o = e.get(Lt); if (o.hydrating.has(t))
    return; let { parentBlockPromise: i, hydrationQueue: s } = U_(t, e); if (s.length === 0)
    return; i !== null && s.shift(), Yk(o, s), i !== null && (yield i); let a = s[0]; o.has(a) ? yield Tm(e, s, n) : o.awaitParentBlock(a, () => Se(null, null, function* () { return yield Tm(e, s, n); })); }); }
function Tm(e, t, n) { return Se(this, null, function* () { let o = e.get(Lt), r = o.hydrating, i = e.get(gt), s = i.add(); for (let c = 0; c < t.length; c++) {
    let l = t[c], u = o.get(l);
    if (u != null) {
        if (yield Jk(u), yield Kk(e), Qk(u)) {
            UA(u), Cm(t.slice(c), o);
            break;
        }
        r.get(l).resolve();
    }
    else {
        Zk(c, t, o), Cm(t.slice(c), o);
        break;
    }
} let a = t[t.length - 1]; yield r.get(a)?.promise, i.remove(s), n && n(t), qA(o.get(a), t, o, e.get(He)); }); }
function Qk(e) { return Ne(e.lView, e.tNode)[Vt] === Q.Error; }
function Zk(e, t, n) { let o = e - 1, r = o > -1 ? n.get(t[o]) : null; r && pc(r.lContainer); }
function Cm(e, t) { let n = t.hydrating; for (let o in e)
    n.get(o)?.reject(); t.cleanup(e); }
function Yk(e, t) { for (let n of t)
    e.hydrating.set(n, oo()); }
function Kk(e) { return new Promise(t => _f(t, { injector: e })); }
function Jk(e) { return Se(this, null, function* () { let { tNode: t, lView: n } = e, o = Ne(n, t); return new Promise(r => { Xk(o, r), _e(2, n, t); }); }); }
function Xk(e, t) { Array.isArray(e[Io]) || (e[Io] = []), e[Io].push(t); }
function ne(e, t, n) { return e === 0 ? Mm(t, n) : e === 2 ? !Mm(t, n) : !(typeof ngServerMode < "u" && ngServerMode); }
function ex(e) { return e != null && (e & 1) === 1; }
function Mm(e, t) { let n = e[x], o = pe(e[m], t), r = Ti(n), i = ex(o.flags); if (typeof ngServerMode < "u" && ngServerMode)
    return !r || !i; let a = Ne(e, t)[vc] !== null; return !(i && a && r); }
function sn(e, t) { let n = pe(e, t); return n.hydrateTriggers ??= new Map; }
function tx(e, t, n) { let o = [], r = [], i = [], s = []; for (let [a, c] of t) {
    let l = n.get(a);
    if (l !== void 0) {
        let u = c.data[kt], d = l;
        for (let f = 0; f < u; f++) {
            if (d = d.previousSibling, d.nodeType !== Node.ELEMENT_NODE)
                continue;
            let p = { el: d, blockName: a };
            c.hydrate.idle && o.push(p), c.hydrate.immediate && s.push(p), c.hydrate.timer !== null && (p.delay = c.hydrate.timer, r.push(p)), c.hydrate.viewport && (typeof c.hydrate.viewport != "boolean" && (p.intersectionObserverOptions = c.hydrate.viewport), i.push(p));
        }
    }
} nx(e, o), ix(e, s), ox(e, i), rx(e, r); }
function nx(e, t) { for (let n of t) {
    let o = e.get(Lt), i = eD(() => Ht(e, n.blockName), e);
    o.addCleanupFn(n.blockName, i);
} }
function ox(e, t) { if (t.length > 0) {
    let n = e.get(Lt);
    for (let o of t) {
        let r = pp(o.el, () => Ht(e, o.blockName), e, o.intersectionObserverOptions);
        n.addCleanupFn(o.blockName, r);
    }
} }
function rx(e, t) { for (let n of t) {
    let o = e.get(Lt), r = () => Ht(e, n.blockName), s = yc(n.delay)(r, e);
    o.addCleanupFn(n.blockName, s);
} }
function ix(e, t) { for (let n of t)
    Ht(e, n.blockName); }
function rD(e, t, n, o, r, i, s, a, c, l) { let u = g(), d = A(), f = e + I, p = Pn(u, d, e, null, 0, 0), h = u[x], v = Ti(h); if (d.firstCreatePass) {
    te("NgDefer");
    let It = { primaryTmplIndex: t, loadingTmplIndex: o ?? null, placeholderTmplIndex: r ?? null, errorTmplIndex: i ?? null, placeholderBlockConfig: null, loadingBlockConfig: null, dependencyResolverFn: n ?? null, loadingState: ue.NOT_STARTED, loadingPromise: null, providers: null, hydrateTriggers: null, debug: null, flags: l ?? 0 };
    c?.(d, It, a, s), mk(d, f, It);
} let y = u[f]; tI(y, p, u); let T = null, R = null; if (y[je]?.length > 0) {
    let It = y[je][0].data;
    R = It[Oa] ?? null, T = It[Ei];
} let se = [null, si.Initial, null, null, null, null, R, T, null, null]; gk(u, f, se); let Je = null; R !== null && v && (Je = h.get(Lt), Je.add(R, { lView: u, tNode: p, lContainer: y })); let Be = () => { OI(se), R !== null && Je?.cleanup([R]); }; Ai(0, se, () => vs(u, Be)), to(u, Be); }
function iD(e) { let t = g(), n = Ve(); if (!ne(0, t, n))
    return; let o = De(); if (Z(t, o, e)) {
    let r = k(null);
    try {
        let i = !!e, a = Ne(t, n)[Vt];
        i === !1 && a === si.Initial ? zo(t, n) : i === !0 && (a === si.Initial || a === Q.Placeholder) && _e(0, t, n);
    }
    finally {
        k(r);
    }
} }
function sD(e) { let t = g(), n = Ve(); if (!ne(1, t, n))
    return; let o = De(); if (Z(t, o, e)) {
    let r = k(null);
    try {
        let i = !!e, s = t[m], a = pe(s, n);
        i === !0 && a.loadingState === ue.NOT_STARTED && xi(a, t, n);
    }
    finally {
        k(r);
    }
} }
function aD(e) { let t = g(), n = Ve(); if (!ne(2, t, n))
    return; let o = De(), r = A(); if (sn(r, n).set(6, null), Z(t, o, e))
    if (typeof ngServerMode < "u" && ngServerMode)
        _e(2, t, n);
    else {
        let s = t[x], a = k(null);
        try {
            if (!!e === !0) {
                let u = Ne(t, n)[vc];
                Ht(s, u);
            }
        }
        finally {
            k(a);
        }
    } }
function cD() { let e = g(), t = _(); if (!ne(2, e, t))
    return; sn(A(), t).set(7, null), typeof ngServerMode < "u" && ngServerMode && _e(2, e, t); }
function lD(e) { let t = g(), n = _(); ne(0, t, n) && tD(vp({ timeout: e })); }
function uD(e) { let t = g(), n = _(); ne(1, t, n) && nD(vp({ timeout: e })); }
function dD(e) { let t = g(), n = _(); if (!ne(2, t, n))
    return; sn(A(), n).set(0, null), typeof ngServerMode < "u" && ngServerMode ? _e(2, t, n) : oD(vp({ timeout: e }), t, n); }
function fD() { let e = g(), t = _(); if (!ne(0, e, t))
    return; pe(e[m], t).loadingTmplIndex === null && zo(e, t), _e(0, e, t); }
function pD() { let e = g(), t = _(); if (!ne(1, e, t))
    return; let n = e[m], o = pe(n, t); o.loadingState === ue.NOT_STARTED && Ic(o, e, t); }
function hD() { let e = g(), t = _(); if (!ne(2, e, t))
    return; if (sn(A(), t).set(1, null), typeof ngServerMode < "u" && ngServerMode)
    _e(2, e, t);
else {
    let o = e[x], i = Ne(e, t)[vc];
    Ht(o, i);
} }
function gD(e) { let t = g(), n = _(); ne(0, t, n) && tD(yc(e)); }
function mD(e) { let t = g(), n = _(); ne(1, t, n) && nD(yc(e)); }
function vD(e) { let t = g(), n = _(); if (!ne(2, t, n))
    return; sn(A(), n).set(5, { type: 5, delay: e }), typeof ngServerMode < "u" && ngServerMode ? _e(2, t, n) : oD(yc(e), t, n); }
function yD(e, t) { let n = g(), o = _(); ne(0, n, o) && (zo(n, o), typeof ngServerMode < "u" && ngServerMode || Qo(n, o, e, t, jv, () => _e(0, n, o), 0)); }
function ED(e, t) { let n = g(), o = _(); if (!ne(1, n, o))
    return; let r = n[m], i = pe(r, o); i.loadingState === ue.NOT_STARTED && Qo(n, o, e, t, jv, () => xi(i, n, o), 1); }
function ID() { let e = g(), t = _(); if (!ne(2, e, t))
    return; sn(A(), t).set(4, null), typeof ngServerMode < "u" && ngServerMode && _e(2, e, t); }
function DD(e, t) { let n = g(), o = _(); ne(0, n, o) && (zo(n, o), typeof ngServerMode < "u" && ngServerMode || Qo(n, o, e, t, Fv, () => _e(0, n, o), 0)); }
function TD(e, t) { let n = g(), o = _(); if (!ne(1, n, o))
    return; let r = n[m], i = pe(r, o); i.loadingState === ue.NOT_STARTED && Qo(n, o, e, t, Fv, () => xi(i, n, o), 1); }
function CD() { let e = g(), t = _(); if (!ne(2, e, t))
    return; sn(A(), t).set(3, null), typeof ngServerMode < "u" && ngServerMode && _e(2, e, t); }
function MD(e, t, n) { let o = g(), r = _(); ne(0, o, r) && (zo(o, r), typeof ngServerMode < "u" && ngServerMode || Qo(o, r, e, t, pp, () => _e(0, o, r), 0, n)); }
function wD(e, t, n) { let o = g(), r = _(); if (!ne(1, o, r))
    return; let i = o[m], s = pe(i, r); s.loadingState === ue.NOT_STARTED && Qo(o, r, e, t, pp, () => xi(s, o, r), 1, n); }
function ND(e) { let t = g(), n = _(); if (!ne(2, t, n))
    return; sn(A(), n).set(2, e ? { type: 2, intersectionObserverOptions: e } : null), typeof ngServerMode < "u" && ngServerMode && _e(2, t, n); }
function yp(e, t) { let n = g(), o = De(); if (Z(n, o, t)) {
    let r = A(), i = Ve();
    if (rc(i, r, n, e, t))
        Ce(i) && Yy(n, i.index);
    else {
        let a = ie(i, n);
        tc(n[N], a, null, i.value, e, t, null);
    }
} return yp; }
function Ep(e, t, n, o) { let r = g(), i = De(); if (Z(r, i, t)) {
    let s = A(), a = Ve();
    Ob(a, r, e, t, n, o);
} return Ep; }
function Vr(e) { if (te("NgAnimateEnter"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Vr; let t = g(); if (Wa(t))
    return Vr; let n = _(), o = t[x].get(G); return za(ua(t), n, () => sx(t, n, e, o)), Ka(t[x]), Sf(t[x], ua(t)), Vr; }
function sx(e, t, n, o) { let r = ie(t, e), i = e[N], s = Ry(n), a = [], c = !1, l = d => { if (Yr(d) !== r)
    return; let f = d instanceof AnimationEvent ? "animationend" : "transitionend"; o.runOutsideAngular(() => { i.listen(r, f, u); }); }, u = d => { Yr(d) === r && (Mf(d, r) && (c = !0), ax(d, r, i)); }; if (s && s.length > 0) {
    o.runOutsideAngular(() => { a.push(i.listen(r, "animationstart", l)), a.push(i.listen(r, "transitionstart", l)); }), ob(r, s, a);
    for (let d of s)
        i.addClass(r, d);
    o.runOutsideAngular(() => { requestAnimationFrame(() => { if (!c && (Oy(r, wn, Hn), !wn.has(r))) {
        for (let d of s)
            i.removeClass(r, d);
        Tf(r);
    } }); });
} }
function ax(e, t, n) { let o = Co.get(t); if (!(Yr(e) !== t || !o) && Mf(e, t)) {
    e.stopPropagation();
    for (let r of o.classList)
        n.removeClass(t, r);
    Tf(t);
} }
function Hr(e) { if (te("NgAnimateEnter"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Hr; let t = g(); if (Wa(t))
    return Hr; let n = _(); return za(ua(t), n, () => cx(t, n, e)), Ka(t[x]), Sf(t[x], ua(t)), Hr; }
function cx(e, t, n) { let o = ie(t, e); n.call(e[B], { target: o, animationComplete: rb }); }
function Br(e) { if (te("NgAnimateLeave"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Br; let t = g(); if (Wa(t))
    return Br; let o = _(), r = t[x].get(G); return za(bn(t), o, () => lx(t, o, e, r)), Ka(t[x]), Br; }
function lx(e, t, n, o) { let { promise: r, resolve: i } = oo(), s = ie(t, e), a = e[N]; on.add(e[Fe]), (bn(e).get(t.index).resolvers ??= []).push(i); let c = Ry(n); return c && c.length > 0 ? ux(s, t, e, c, a, o) : i(), { promise: r, resolve: i }; }
function ux(e, t, n, o, r, i) { sb(e, r); let s = [], a = bn(n).get(t.index)?.resolvers, c, l = !1, u = d => { if (!(Yr(d) !== e && d.type !== "animation-fallback") && (d.type === "animation-fallback" || Mf(d, e))) {
    if (l = !0, c && clearTimeout(c), d.type !== "animation-fallback" && d.stopPropagation(), wn.delete(e), nd(t, e), Array.isArray(t.projection))
        for (let p of o)
            r.removeClass(e, p);
    od(a, s), rd(n, t);
} }; i.runOutsideAngular(() => { s.push(r.listen(e, "animationend", u)), s.push(r.listen(e, "transitionend", u)); }), Cf(t, e); for (let d of o)
    r.addClass(e, d); i.runOutsideAngular(() => { requestAnimationFrame(() => { if (l)
    return; Oy(e, wn, Hn); let d = wn.get(e); d ? (c = setTimeout(() => { u(new CustomEvent("animation-fallback")); }, d.duration + 50), s.push(() => clearTimeout(c))) : (nd(t, e), od(a, s), rd(n, t)); }); }); }
function Ia(e) { if (te("NgAnimateLeave"), typeof ngServerMode < "u" && ngServerMode || !Hn)
    return Ia; let t = g(), n = _(); on.add(t[Fe]); let o = t[x].get(G), r = t[x].get(Ay); return za(bn(t), n, () => dx(t, n, e, o, r)), Ka(t[x]), Ia; }
function dx(e, t, n, o, r) { let { promise: i, resolve: s } = oo(), a = ie(t, e), c = [], l = e[N], u = Wa(e); (bn(e).get(t.index).resolvers ??= []).push(s); let d = bn(e).get(t.index)?.resolvers; if (u)
    Ls(e, t, a, d, c);
else {
    let f = setTimeout(() => Ls(e, t, a, d, c), r), p = { target: a, animationComplete: () => { Ls(e, t, a, d, c), clearTimeout(f); } };
    Cf(t, a), o.runOutsideAngular(() => { c.push(l.listen(a, "animationend", () => { Ls(e, t, a, d, c), clearTimeout(f); }, { once: !0 })); }), n.call(e[B], p);
} return { promise: i, resolve: s }; }
function _D() { return g()[re][B]; }
var Md = class {
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
function fx(e, t, n, o) { let r, i, s = 0, a = e.length - 1, c = void 0; if (Array.isArray(t)) {
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
        if (r ??= new Da, i ??= Nm(e, s, a, n), wd(e, r, s, R))
            e.updateValue(s, d), s++, a++;
        else if (i.has(R))
            r.set(y, e.detach(s)), a--;
        else {
            let se = e.create(s, t[s]);
            e.attach(s, se), s++, a++;
        }
    }
    for (; s <= l;)
        wm(e, r, n, s, t[s]), s++;
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
            r ??= new Da, i ??= Nm(e, s, a, n);
            let h = n(s, f);
            if (wd(e, r, s, h))
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
        wm(e, r, n, e.length, u.value), u = l.next();
} for (; s <= a;)
    e.destroy(e.detach(a--)); r?.forEach(l => { e.destroy(l); }); }
function wd(e, t, n, o) { return t !== void 0 && t.has(o) ? (e.attach(n, t.get(o)), t.delete(o), !0) : !1; }
function wm(e, t, n, o, r) { if (wd(e, t, o, n(o, r)))
    e.updateValue(o, r);
else {
    let i = e.create(o, r);
    e.attach(o, i);
} }
function Nm(e, t, n, o) { let r = new Set; for (let i = t; i <= n; i++)
    r.add(o(i, e.at(i))); return r; }
var Da = class {
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
function SD(e, t, n, o, r, i, s, a) { te("NgControlFlow"); let c = g(), l = A(), u = ve(l.consts, i); return Pn(c, l, e, t, n, o, r, u, 256, s, a), Dc; }
function Dc(e, t, n, o, r, i, s, a) { te("NgControlFlow"); let c = g(), l = A(), u = ve(l.consts, i); return Pn(c, l, e, t, n, o, r, u, 512, s, a), Dc; }
function bD(e, t) { te("NgControlFlow"); let n = g(), o = De(), r = n[o] !== $ ? n[o] : -1, i = r !== -1 ? Ta(n, I + r) : void 0, s = 0; if (Z(n, o, e)) {
    let a = k(null);
    try {
        if (i !== void 0 && Ff(i, s), e !== -1) {
            let c = I + e, l = Ta(n, c), u = bd(n[m], c), d = xE(l, u, n), f = $o(n, u, t, { dehydratedView: d });
            Uo(l, f, s, An(u, d));
        }
    }
    finally {
        k(a);
    }
}
else if (i !== void 0) {
    let a = lE(i, s);
    a !== void 0 && (a[B] = t);
} }
var Nd = class {
    lContainer;
    $implicit;
    $index;
    constructor(t, n, o) { this.lContainer = t, this.$implicit = n, this.$index = o; }
    get $count() { return this.lContainer.length - U; }
};
function AD(e) { return e; }
function RD(e, t) { return t; }
var _d = class {
    hasEmptyBlock;
    trackByFn;
    liveCollection;
    constructor(t, n, o) { this.hasEmptyBlock = t, this.trackByFn = n, this.liveCollection = o; }
};
function kD(e, t, n, o, r, i, s, a, c, l, u, d, f) { te("NgControlFlow"); let p = g(), h = A(), v = c !== void 0, y = g(), T = a ? s.bind(y[re][B]) : s, R = new _d(v, T); y[I + e] = R, Pn(p, h, e + 1, t, n, o, r, ve(h.consts, i), 256), v && Pn(p, h, e + 2, c, l, u, d, ve(h.consts, f), 512); }
var Sd = class extends Md {
    lContainer;
    hostLView;
    templateTNode;
    operationsCounter = void 0;
    needsIndexUpdate = !1;
    constructor(t, n, o) { super(), this.lContainer = t, this.hostLView = n, this.templateTNode = o; }
    get length() { return this.lContainer.length - U; }
    at(t) { return this.getLView(t)[B].$implicit; }
    attach(t, n) { let o = n[fe]; this.needsIndexUpdate ||= t !== this.length, Uo(this.lContainer, n, t, An(this.templateTNode, o)), px(this.lContainer, t); }
    detach(t) { return this.needsIndexUpdate ||= t !== this.length - 1, hx(this.lContainer, t), gx(this.lContainer, t); }
    create(t, n) { let o = ti(this.lContainer, this.templateTNode.tView.ssrId); return $o(this.hostLView, this.templateTNode, new Nd(this.lContainer, n, t), { dehydratedView: o }); }
    destroy(t) { Si(t[m], t); }
    updateValue(t, n) { this.getLView(t)[B].$implicit = n; }
    reset() { this.needsIndexUpdate = !1; }
    updateIndexes() { if (this.needsIndexUpdate)
        for (let t = 0; t < this.length; t++)
            this.getLView(t)[B].$index = t; }
    getLView(t) { return mx(this.lContainer, t); }
};
function xD(e) { let t = k(null), n = le(); try {
    let o = g(), r = o[m], i = o[n], s = n + 1, a = Ta(o, s);
    if (i.liveCollection === void 0) {
        let l = bd(r, s);
        i.liveCollection = new Sd(a, o, l);
    }
    else
        i.liveCollection.reset();
    let c = i.liveCollection;
    if (fx(c, e, i.trackByFn, t), c.updateIndexes(), i.hasEmptyBlock) {
        let l = De(), u = c.length === 0;
        if (Z(o, l, u)) {
            let d = n + 2, f = Ta(o, d);
            if (u) {
                let p = bd(r, d), h = xE(f, p, o), v = $o(o, p, void 0, { dehydratedView: h });
                Uo(f, v, 0, An(p, h));
            }
            else
                r.firstUpdatePass && fc(f), Ff(f, 0);
        }
    }
}
finally {
    k(t);
} }
function Ta(e, t) { return e[t]; }
function px(e, t) { if (e.length <= U)
    return; let n = U + t, o = e[n], r = o ? o[ze] : void 0; if (o && r && r.detachedLeaveAnimationFns && r.detachedLeaveAnimationFns.length > 0) {
    let i = o[x];
    hb(i, r), on.delete(o[Fe]), r.detachedLeaveAnimationFns = void 0;
} }
function hx(e, t) { if (e.length <= U)
    return; let n = U + t, o = e[n], r = o ? o[ze] : void 0; r && r.leave && r.leave.size > 0 && (r.detachedLeaveAnimationFns = []); }
function gx(e, t) { return Jr(e, t); }
function mx(e, t) { return lE(e, t); }
function bd(e, t) { return Yt(e, t); }
function Ip(e, t, n) { let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve();
    xf(s, o, e, t, o[N], n);
} return Ip; }
function Ad(e, t, n, o, r) { rc(t, e, n, r ? "class" : "style", o); }
function ai(e, t, n, o) { let r = g(), i = r[m], s = e + I, a = i.firstCreatePass ? Gf(s, r, 2, t, Pf, ys(), n, o) : i.data[s]; if (Ce(a)) {
    let c = r[We].tracingService;
    if (c && c.componentCreate) {
        let l = i.data[a.directiveStart + a.componentOffset];
        return c.componentCreate(Uf(l), () => (_m(e, t, r, a, o), ai));
    }
} return _m(e, t, r, a, o), ai; }
function _m(e, t, n, o, r) { if (nc(o, n, e, t, Cp), Xn(o)) {
    let i = n[m];
    ec(i, n, o), af(i, o, n);
} r != null && Bo(n, o); }
function Tc() { let e = A(), t = _(), n = oc(t); return e.firstCreatePass && Wf(e, n), Ll(n) && Vl(), Pl(), n.classesWithoutHost != null && CN(n) && Ad(e, n, g(), n.classesWithoutHost, !0), n.stylesWithoutHost != null && MN(n) && Ad(e, n, g(), n.stylesWithoutHost, !1), Tc; }
function Dp(e, t, n, o) { return ai(e, t, n, o), Tc(), Dp; }
function Cc(e, t, n, o) { let r = g(), i = r[m], s = e + I, a = i.firstCreatePass ? YE(s, i, 2, t, n, o) : i.data[s]; return nc(a, r, e, t, Cp), o != null && Bo(r, a), Cc; }
function Mc() { let e = _(), t = oc(e); return Ll(t) && Vl(), Pl(), Mc; }
function Tp(e, t, n, o) { return Cc(e, t, n, o), Mc(), Tp; }
var Cp = (e, t, n, o, r) => (rt(!0), $a(t[N], o, Ms()));
function vx(e, t, n, o, r) { let i = !Ha(t, n); if (rt(i), i)
    return $a(t[N], o, Ms()); let s = t[fe], a = bi(s, e, t, n); return Jv(s, r) && ja(s, r, a.nextSibling), s && ($d(n) || Tv(a)) && Ce(n) && (ug(n), vy(a)), a; }
function OD() { Cp = vx; }
function wc(e, t, n) { let o = g(), r = o[m], i = e + I, s = r.firstCreatePass ? Gf(i, o, 8, "ng-container", Pf, ys(), t, n) : r.data[i]; if (nc(s, o, e, "ng-container", _p), Xn(s)) {
    let a = o[m];
    ec(a, o, s), af(a, s, o);
} return n != null && Bo(o, s), wc; }
function Oi() { let e = A(), t = _(), n = oc(t); return e.firstCreatePass && Wf(e, n), Oi; }
function Mp(e, t, n) { return wc(e, t, n), Oi(), Mp; }
function Nc(e, t, n) { let o = g(), r = o[m], i = e + I, s = r.firstCreatePass ? YE(i, r, 8, "ng-container", t, n) : r.data[i]; return nc(s, o, e, "ng-container", _p), n != null && Bo(o, s), Nc; }
function wp() { let e = _(), t = oc(e); return Oi; }
function Np(e, t, n) { return Nc(e, t, n), wp(), Np; }
var _p = (e, t, n, o, r) => (rt(!0), uf(t[N], ""));
function yx(e, t, n, o, r) { let i, s = !Ha(t, n); if (rt(s), s)
    return uf(t[N], ""); let a = t[fe], c = bi(a, e, t, n), l = Kv(a, r); return ja(a, r, c), i = uc(l, c), i; }
function PD() { _p = yx; }
function LD() { return g(); }
function Sp(e, t, n) { let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve();
    Of(s, o, e, t, o[N], n);
} return Sp; }
function bp(e, t, n) { let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve(), a = Is(i.data), c = Ky(a, s, o);
    Of(s, o, e, t, c, n);
} return bp; }
var Rr = void 0;
function Ex(e) { let t = Math.floor(Math.abs(e)), n = e.toString().replace(/^[^.]*\.?/, "").length; return t === 1 && n === 0 ? 1 : 5; }
var Ix = ["en", [["a", "p"], ["AM", "PM"]], [["AM", "PM"]], [["S", "M", "T", "W", "T", "F", "S"], ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]], Rr, [["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"], ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]], Rr, [["B", "A"], ["BC", "AD"], ["Before Christ", "Anno Domini"]], 0, [6, 0], ["M/d/yy", "MMM d, y", "MMMM d, y", "EEEE, MMMM d, y"], ["h:mm\u202Fa", "h:mm:ss\u202Fa", "h:mm:ss\u202Fa z", "h:mm:ss\u202Fa zzzz"], ["{1}, {0}", Rr, Rr, Rr], [".", ",", ";", "%", "+", "-", "E", "\xD7", "\u2030", "\u221E", "NaN", ":"], ["#,##0.###", "#,##0%", "\xA4#,##0.00", "#E0"], "USD", "$", "US Dollar", {}, "ltr", Ex], Do = Object.create(null);
function Dx(e, t, n) { typeof t != "string" && (n = t, t = e[So.LocaleId]), t = t.toLowerCase().replace(/_/g, "-"), Do[t] = e, n && (Do[t][So.ExtraData] = n); }
function Ap(e) { let t = Mx(e), n = Sm(t); if (n)
    return n; let o = t.split("-")[0]; if (n = Sm(o), n)
    return n; if (o === "en")
    return Ix; throw new D(701, !1); }
function Tx(e) { return Ap(e)[So.CurrencyCode] || null; }
function FD(e) { return Ap(e)[So.PluralCase]; }
function Sm(e) { return e in Do || (Do[e] = Pe.ng && Pe.ng.common && Pe.ng.common.locales && Pe.ng.common.locales[e]), Do[e]; }
function Cx() { Do = Object.create(null); }
var So = (function (e) { return e[e.LocaleId = 0] = "LocaleId", e[e.DayPeriodsFormat = 1] = "DayPeriodsFormat", e[e.DayPeriodsStandalone = 2] = "DayPeriodsStandalone", e[e.DaysFormat = 3] = "DaysFormat", e[e.DaysStandalone = 4] = "DaysStandalone", e[e.MonthsFormat = 5] = "MonthsFormat", e[e.MonthsStandalone = 6] = "MonthsStandalone", e[e.Eras = 7] = "Eras", e[e.FirstDayOfWeek = 8] = "FirstDayOfWeek", e[e.WeekendRange = 9] = "WeekendRange", e[e.DateFormat = 10] = "DateFormat", e[e.TimeFormat = 11] = "TimeFormat", e[e.DateTimeFormat = 12] = "DateTimeFormat", e[e.NumberSymbols = 13] = "NumberSymbols", e[e.NumberFormats = 14] = "NumberFormats", e[e.CurrencyCode = 15] = "CurrencyCode", e[e.CurrencySymbol = 16] = "CurrencySymbol", e[e.CurrencyName = 17] = "CurrencyName", e[e.Currencies = 18] = "Currencies", e[e.Directionality = 19] = "Directionality", e[e.PluralCase = 20] = "PluralCase", e[e.ExtraData = 21] = "ExtraData", e; })(So || {});
function Mx(e) { return e.toLowerCase().replace(/_/g, "-"); }
var wx = ["zero", "one", "two", "few", "many"];
function Nx(e, t) { let n = FD(t)(parseInt(e, 10)), o = wx[n]; return o !== void 0 ? o : "other"; }
var Pi = "en-US", _x = "USD", jD = { marker: "element" }, VD = { marker: "ICU" }, bt = (function (e) { return e[e.SHIFT = 2] = "SHIFT", e[e.APPEND_EAGERLY = 1] = "APPEND_EAGERLY", e[e.COMMENT = 2] = "COMMENT", e; })(bt || {}), HD = Pi;
function BD(e) { typeof e == "string" && (HD = e.toLowerCase().replace(/_/g, "-")); }
function Sx() { return HD; }
var ci = 0, $r = 0;
function bx(e) { e && (ci = ci | 1 << Math.min($r, 31)), $r++; }
function Ax(e, t, n) { try {
    if ($r > 0) {
        let o = e.data[n], r = Array.isArray(o) ? o : o.update, i = ft() - $r - 1;
        GD(e, t, r, i, ci);
    }
}
finally {
    ci = 0, $r = 0;
} }
function $D(e, t, n) { let o = e[N]; switch (n) {
    case Node.COMMENT_NODE: return uf(o, t);
    case Node.TEXT_NODE: return lf(o, t);
    case Node.ELEMENT_NODE: return $a(o, t, null);
} }
var Ur = (e, t, n, o) => (rt(!0), $D(e, n, o));
function Rx(e, t, n, o) { let r = e[fe], i = t - I, s = !dc() || !r || Nr() || Va(r, i); return rt(s), s ? $D(e, n, o) : yE(r, i); }
function UD() { Ur = Rx; }
function kx(e, t, n, o) { let r = e[N]; for (let i = 0; i < t.length; i++) {
    let s = t[i++], a = t[i], c = (s & bt.COMMENT) === bt.COMMENT, l = (s & bt.APPEND_EAGERLY) === bt.APPEND_EAGERLY, u = s >>> bt.SHIFT, d = e[u], f = !1;
    d === null && (d = e[u] = Ur(e, u, a, c ? Node.COMMENT_NODE : Node.TEXT_NODE), f = Sr()), l && n !== null && f && _n(r, n, d, o, !1);
} }
function qD(e, t, n, o) { let r = n[N], i = null, s; for (let a = 0; a < t.length; a++) {
    let c = t[a];
    if (typeof c == "string") {
        let l = t[++a];
        n[l] === null && (n[l] = Ur(n, l, c, Node.TEXT_NODE));
    }
    else if (typeof c == "number")
        switch (c & 1) {
            case 0:
                let l = EA(c);
                i === null && (i = l, s = r.parentNode(o));
                let u, d;
                if (l === i ? (u = o, d = s) : (u = null, d = O(n[l])), d !== null) {
                    let v = IA(c), y = n[v];
                    _n(r, d, y, u, !1);
                    let T = Pr(e, v);
                    if (T !== null && typeof T == "object") {
                        let R = lc(T, n);
                        R !== null && qD(e, T.create[R], n, n[T.anchorIdx]);
                    }
                }
                break;
            case 1:
                let f = c >>> 1, p = t[++a], h = t[++a];
                tc(r, yn(f, n), null, null, p, h, null);
                break;
            default:
        }
    else
        switch (c) {
            case VD:
                let l = t[++a], u = t[++a];
                if (n[u] === null) {
                    let p = n[u] = Ur(n, u, l, Node.COMMENT_NODE);
                    Ze(p, n);
                }
                break;
            case jD:
                let d = t[++a], f = t[++a];
                if (n[f] === null) {
                    let p = n[f] = Ur(n, f, d, Node.ELEMENT_NODE);
                    Ze(p, n);
                }
                break;
            default:
        }
} }
function GD(e, t, n, o, r) { for (let i = 0; i < n.length; i++) {
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
                                tc(t[N], t[d], null, h, f, c, p);
                            else {
                                let y = le();
                                ht(d);
                                try {
                                    xf(h, t, f, c, t[N], p);
                                }
                                finally {
                                    ht(y);
                                }
                            }
                            break;
                        case 0:
                            let v = t[d];
                            v !== null && gy(t[N], v, c);
                            break;
                        case 2:
                            xx(e, Pr(e, d), t, c);
                            break;
                        case 3:
                            bm(e, Pr(e, d), o, t);
                            break;
                    }
                }
        }
    }
    else {
        let c = n[i + 1];
        if (c > 0 && (c & 3) === 3) {
            let l = c >>> 2, u = Pr(e, l);
            t[u.currentCaseLViewIndex] < 0 && bm(e, u, o, t);
        }
    }
    i += a;
} }
function bm(e, t, n, o) { let r = o[t.currentCaseLViewIndex]; if (r !== null) {
    let i = ci;
    r < 0 && (r = o[t.currentCaseLViewIndex] = ~r, i = -1), GD(e, o, t.update[r], n, i);
} }
function xx(e, t, n, o) { let r = Ox(t, o); if (lc(t, n) !== r && (WD(e, t, n), n[t.currentCaseLViewIndex] = r === null ? null : ~r, r !== null)) {
    let s = n[t.anchorIdx];
    s && qD(e, t.create[r], n, s), VA(n, t.anchorIdx, r);
} }
function WD(e, t, n) { let o = lc(t, n); if (o !== null) {
    let r = t.remove[o];
    for (let i = 0; i < r.length; i++) {
        let s = r[i];
        if (s > 0) {
            let a = yn(s, n);
            a !== null && Mi(n[N], a);
        }
        else
            WD(e, Pr(e, ~s), n);
    }
} }
function Ox(e, t) { let n = e.cases.indexOf(t); if (n === -1)
    switch (e.type) {
        case 1: {
            let o = Nx(t, Sx());
            n = e.cases.indexOf(o), n === -1 && o !== "other" && (n = e.cases.indexOf("other"));
            break;
        }
        case 0: {
            n = e.cases.indexOf("other");
            break;
        }
    } return n === -1 ? null : n; }
var Ca = /�(\d+):?\d*�/gi, Px = /({\s*�\d+:?\d*�\s*,\s*\S{6}\s*,[\s\S]*})/gi, Lx = /�(\d+)�/, zD = /^\s*(�\d+:?\d*�)\s*,\s*(select|plural)\s*,/, qr = "\uFFFD", Fx = /�\/?\*(\d+:\d+)�/gi, jx = /�(\/?[#*]\d+):?\d*�/gi, Vx = /\uE500/g;
function Hx(e) { return e.replace(Vx, " "); }
function Bx(e, t, n, o, r, i) { let s = no(), a = [], c = [], l = [[]], u = [[]]; r = Gx(r, i); let d = Hx(r).split(jx); for (let f = 0; f < d.length; f++) {
    let p = d[f];
    if ((f & 1) === 0) {
        let h = Rd(p);
        for (let v = 0; v < h.length; v++) {
            let y = h[v];
            if ((v & 1) === 0) {
                let T = y;
                T !== "" && $x(u[0], e, s, l[0], a, c, n, T);
            }
            else {
                let T = y;
                if (typeof T != "object")
                    throw new Error(`Unable to parse ICU expression in "${r}" message.`);
                let se = QD(e, s, l[0], n, a, "", !0).index;
                YD(u[0], e, n, c, t, T, se);
            }
        }
    }
    else {
        let h = p.charCodeAt(0) === 47, v = p.charCodeAt(h ? 1 : 0), y = I + Number.parseInt(p.substring(h ? 2 : 1));
        if (h)
            l.shift(), u.shift(), dt(no(), !1);
        else {
            let T = yA(e, l[0], y);
            l.unshift([]), dt(T, !0);
            let R = { kind: 2, index: y, children: [], type: v === 35 ? 0 : 1 };
            u[0].push(R), u.unshift(R.children);
        }
    }
} e.data[o] = { create: a, update: c, ast: u[0], parentTNodeIndex: t }; }
function QD(e, t, n, o, r, i, s) { let a = Ni(e, o, 1, null), c = a << bt.SHIFT, l = no(); t === l && (l = null), l === null && (c |= bt.APPEND_EAGERLY), s && (c |= bt.COMMENT, eb(TA)), r.push(c, i === null ? "" : i); let u = jf(e, a, s ? 32 : 1, i === null ? "" : i, null); hE(n, u); let d = u.index; return dt(u, !1), l !== null && t !== l && vA(l, d), u; }
function $x(e, t, n, o, r, i, s, a) { let c = a.match(Ca), u = QD(t, n, o, s, r, c ? null : a, !1).index; c && Ma(i, a, u, null, 0, null), e.push({ kind: 0, index: u }); }
function Ux(e, t, n) { let o = _(), r = o.index, i = []; if (e.firstCreatePass && e.data[t] === null) {
    for (let s = 0; s < n.length; s += 2) {
        let a = n[s], c = n[s + 1];
        if (c !== "") {
            if (Px.test(c))
                throw new Error(`ICU expressions are not supported in attributes. Message: "${c}".`);
            let l = o.namespace ? `:${o.namespace}:${o.value}` : o.value;
            Ma(i, c, r, a, qx(i), kd(a, l));
        }
    }
    e.data[t] = i;
} }
function Ma(e, t, n, o, r, i) { let s = e.length, a = s + 1; e.push(null, null); let c = s + 2, l = t.split(Ca), u = 0; for (let d = 0; d < l.length; d++) {
    let f = l[d];
    if (d & 1) {
        let p = r + parseInt(f, 10);
        e.push(-1 - p), u = u | ZD(p);
    }
    else
        f !== "" && e.push(f);
} return e.push(n << 2 | (o ? 1 : 0)), o && e.push(o, i), e[s] = u, e[a] = e.length - c, u; }
function qx(e) { let t = 0; for (let n = 0; n < e.length; n++) {
    let o = e[n];
    typeof o == "number" && o < 0 && t++;
} return t; }
function ZD(e) { return 1 << Math.min(e, 31); }
function Am(e) { let t, n = "", o = 0, r = !1, i; for (; (t = Fx.exec(e)) !== null;)
    r ? t[0] === `${qr}/*${i}${qr}` && (o = t.index, r = !1) : (n += e.substring(o, t.index + t[0].length), i = t[1], r = !0); return n += e.slice(o), n; }
function Gx(e, t) { if (mE(t))
    return Am(e); {
    let n = e.indexOf(`:${t}${qr}`) + 2 + t.toString().length, o = e.search(new RegExp(`${qr}\\/\\*\\d+:${t}${qr}`));
    return Am(e.substring(n, o));
} }
function YD(e, t, n, o, r, i, s) { let a = 0, c = { type: i.type, currentCaseLViewIndex: Ni(t, n, 1, null), anchorIdx: s, cases: [], create: [], remove: [], update: [] }; Zx(o, i, s), mA(t, s, c); let l = i.values, u = []; for (let d = 0; d < l.length; d++) {
    let f = l[d], p = [];
    for (let v = 0; v < f.length; v++) {
        let y = f[v];
        if (typeof y != "string") {
            let T = p.push(y) - 1;
            f[v] = `<!--\uFFFD${T}\uFFFD-->`;
        }
    }
    let h = [];
    u.push(h), a = zx(h, t, c, n, o, r, i.cases[d], f.join(""), p) | a;
} a && Yx(o, a, s), e.push({ kind: 3, index: s, cases: u, currentCaseLViewIndex: c.currentCaseLViewIndex }); }
function Wx(e) { let t = [], n = [], o = 1, r = 0; e = e.replace(zD, function (s, a, c) { return c === "select" ? o = 0 : o = 1, r = parseInt(a.slice(1), 10), ""; }); let i = Rd(e); for (let s = 0; s < i.length;) {
    let a = i[s++].trim();
    o === 1 && (a = a.replace(/\s*(?:=)?(\w+)\s*/, "$1")), a.length && t.push(a);
    let c = Rd(i[s++]);
    t.length > n.length && n.push(c);
} return { type: o, mainBinding: r, cases: t, values: n }; }
function Rd(e) { if (!e)
    return []; let t = 0, n = [], o = [], r = /[{}]/g; r.lastIndex = 0; let i; for (; i = r.exec(e);) {
    let a = i.index;
    if (i[0] == "}") {
        if (n.pop(), n.length == 0) {
            let c = e.substring(t, a);
            zD.test(c) ? o.push(Wx(c)) : o.push(c), t = a + 1;
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
function zx(e, t, n, o, r, i, s, a, c) { let l = [], u = [], d = []; n.cases.push(s), n.create.push(l), n.remove.push(u), n.update.push(d); let p = cy(gi()).getInertBodyElement(a), h = ed(p) || p; return h ? KD(e, t, n, o, r, l, u, d, h, i, c, 0) : 0; }
function KD(e, t, n, o, r, i, s, a, c, l, u, d) { let f = 0, p = c.firstChild; for (; p;) {
    let h = Ni(t, o, 1, null);
    switch (p.nodeType) {
        case Node.ELEMENT_NODE:
            let v = p, y = v.tagName.toLowerCase();
            if (Ku.hasOwnProperty(y)) {
                Mu(i, jD, y, l, h), t.data[h] = y;
                let Je = v.attributes;
                for (let It = 0; It < Je.length; It++) {
                    let cn = Je.item(It), Ui = cn.name.toLowerCase(), dw = !!cn.value.match(Ca), Rh = v.namespaceURI, kh = Rh === "http://www.w3.org/2000/svg" ? `:svg:${y}` : Rh === "http://www.w3.org/1998/Math/MathML" ? `:math:${y}` : y;
                    if (dw)
                        Ju.hasOwnProperty(Ui) && Ma(a, cn.value, h, cn.name, 0, kd(Ui, kh));
                    else if (Ju[Ui]) {
                        let fw = cn.value;
                        kd(Ui, kh) ? km(i, h, cn.name, "unsafe:blocked") : km(i, h, cn.name, fw);
                    }
                }
                let Be = { kind: 1, index: h, children: [] };
                e.push(Be), f = KD(Be.children, t, n, o, r, i, s, a, p, h, u, d + 1) | f, Rm(s, h, d);
            }
            break;
        case Node.TEXT_NODE:
            let T = p.textContent || "", R = T.match(Ca);
            Mu(i, null, R ? "" : T, l, h), Rm(s, h, d), R && (f = Ma(a, T, h, null, 0, null) | f), e.push({ kind: 0, index: h });
            break;
        case Node.COMMENT_NODE:
            let se = Lx.exec(p.textContent || "");
            if (se) {
                let Je = parseInt(se[1], 10), Be = u[Je];
                Mu(i, VD, "", l, h), YD(e, t, o, r, l, Be, h), Qx(s, h, d);
            }
            break;
    }
    p = p.nextSibling;
} return f; }
function Rm(e, t, n) { n === 0 && e.push(t); }
function Qx(e, t, n) { n === 0 && (e.push(~t), e.push(t)); }
function Zx(e, t, n) { e.push(ZD(t.mainBinding), 2, -1 - t.mainBinding, n << 2 | 2); }
function Yx(e, t, n) { e.push(t, 1, n << 2 | 3); }
function Mu(e, t, n, o, r) { t !== null && e.push(t), e.push(n, r, DA(0, o, r)); }
function km(e, t, n, o) { e.push(t << 1 | 1, n, o); }
function Kx(e, t = !0) { if (e[0] != ":")
    return [null, e]; let n = e.indexOf(":", 1); if (n === -1) {
    if (t)
        throw new Error(`Unsupported format "${e}" expecting ":namespace:name"`);
    return [null, e];
} return [e.slice(1, n), e.slice(n + 1)]; }
function Jx(e) { let t = e.toLowerCase(), [n, o] = Kx(t, !1); return n === ps || n === hs ? `:${n}:${o}` : o; }
function kd(e, t) { let n = e.toLowerCase(), o = t ? Jx(t) : "*", r = OS(); switch (r[`${o}|${n}`] || r[`*|${n}`] || ee.NONE) {
    case ee.HTML: return df;
    case ee.STYLE: return ff;
    case ee.SCRIPT: return hf;
    case ee.URL: return Ba;
    case ee.RESOURCE_URL: return Ua;
    case ee.ATTRIBUTE_NO_BINDING: return gf;
    default: return null;
} }
var xm = 0, Xx = /\[(�.+?�?)\]/, eO = /\[(�.+?�?)\]|(�\/?\*\d+:\d+�)/g, tO = /({\s*)(VAR_(PLURAL|SELECT)(_\d+)?)(\s*,)/g, nO = /{([A-Z0-9_]+)}/g, oO = /�I18N_EXP_(ICU(_\d+)?)�/g, rO = /\/\*/, iO = /\d+\:(\d+)/;
function sO(e, t = {}) { let n = e; if (Xx.test(e)) {
    let o = {}, r = [xm];
    n = n.replace(eO, (i, s, a) => { let c = s || a, l = o[c] || []; if (l.length || (c.split("|").forEach(v => { let y = v.match(iO), T = y ? parseInt(y[1], 10) : xm, R = rO.test(v); l.push([T, R, v]); }), o[c] = l), !l.length)
        throw new Error(`i18n postprocess: unmatched placeholder - ${c}`); let u = r[r.length - 1], d = 0; for (let v = 0; v < l.length; v++)
        if (l[v][0] === u) {
            d = v;
            break;
        } let [f, p, h] = l[d]; return p ? r.pop() : u !== f && r.push(f), l.splice(d, 1), h; });
} return Object.keys(t).length && (n = n.replace(tO, (o, r, i, s, a, c) => t.hasOwnProperty(i) ? `${r}${t[i]}${c}` : o), n = n.replace(nO, (o, r) => t.hasOwnProperty(r) ? t[r] : o), n = n.replace(oO, (o, r) => { if (t.hasOwnProperty(r)) {
    let i = t[r];
    if (!i.length)
        throw new Error(`i18n postprocess: unmatched ICU - ${o} with key: ${r}`);
    return i.shift();
} return o; })), n; }
function Rp(e, t, n = -1) { let o = A(), r = g(), i = I + e, s = ve(o.consts, t), a = no(); if (o.firstCreatePass && Bx(o, a === null ? 0 : a.index, r, i, s, n), o.type === 2) {
    let f = r[re];
    f[w] |= 32;
}
else
    r[w] |= 32; let c = o.data[i], l = a === r[ce] ? null : a, u = Hy(o, l, r), d = a && a.type & 8 ? r[a.index] : null; xA(r, i, a, n), kx(r, c.create, u, d), Ql(!0); }
function kp() { Ql(!1); }
function JD(e, t, n) { Rp(e, t, n), kp(); }
function XD(e, t) { let n = A(), o = ve(n.consts, t); Ux(n, e + I, o); }
function xp(e) { let t = g(); return bx(Z(t, De(), e)), xp; }
function eT(e) { Ax(A(), g(), e + I); }
function tT(e, t = {}) { return sO(e, t); }
function Op(e, t, n) { let o = g(), r = A(), i = _(); return Fp(r, o, o[N], i, e, t, n), Op; }
function Pp(e, t) { let n = _(), o = g(), r = A(), i = Is(r.data), s = Ky(i, n, o); return Fp(r, o, s, n, e, t), Pp; }
function Lp(e, t, n) { let o = g(), r = A(), i = _(); return (i.type & 3 || n) && qf(i, r, o, n, o[N], e, t, nn(i, o, t)), Lp; }
function Fp(e, t, n, o, r, i, s) { let a = !0, c = null; if ((o.type & 3 || s) && (c ??= nn(o, t, i), qf(o, e, t, s, n, r, i, c) && (a = !1)), a) {
    let l = o.outputs?.[r], u = o.hostDirectiveOutputs?.[r];
    if (u && u.length)
        for (let d = 0; d < u.length; d += 2) {
            let f = u[d], p = u[d + 1];
            c ??= nn(o, t, i), ha(o, t, f, p, r, c);
        }
    if (l && l.length)
        for (let d of l)
            c ??= nn(o, t, i), ha(o, t, d, r, r, c);
} }
function nT(e = 1) { return vg(e); }
function aO(e, t) { let n = null, o = GS(e); for (let r = 0; r < t.length; r++) {
    let i = t[r];
    if (i === "*") {
        n = r;
        continue;
    }
    if (o === null ? wy(e, i, !0) : QS(o, i))
        return r;
} return n; }
function oT(e) { let t = g()[re][ce]; if (!t.projection) {
    let n = e ? e.length : 1, o = t.projection = vr(n, null), r = o.slice(), i = t.child;
    for (; i !== null;) {
        if (i.type !== 128) {
            let s = e ? aO(i, e) : 0;
            s !== null && (r[s] ? r[s].projectionNext = i : o[s] = i, r[s] = i);
        }
        i = i.next;
    }
} }
function rT(e, t = 0, n, o, r, i) { let s = g(), a = A(), c = o ? e + 1 : null; c !== null && Pn(s, a, c, o, r, i, null, n); let l = $n(a, I + e, 16, null, n || null); l.projection === null && (l.projection = t), ql(); let d = !s[fe] || Nr(); s[re][ce].projection[l.projection] === null && c !== null ? cO(s, a, c) : d && !jo(l) && Mb(a, s, l); }
function cO(e, t, n) { let o = I + n, r = t.data[o], i = e[o], s = ti(i, r.tView.ssrId), a = $o(e, r, void 0, { dehydratedView: s }); Uo(i, a, 0, An(r, s)); }
function jp(e, t, n, o) { return aI(e, t, n, o), jp; }
function Vp(e, t, n) { return sI(e, t, n), Vp; }
function iT(e) { let t = g(), n = A(), o = Ds(); _r(o + 1); let r = Zf(n, o); if (e.dirty && ig(t) === ((r.metadata.flags & 2) === 2)) {
    if (r.matches === null)
        e.reset([]);
    else {
        let i = lI(t, o);
        e.reset(i, Dv), e.notifyOnChanges();
    }
    return !0;
} return !1; }
function sT() { return Qf(g(), Ds()); }
function Hp(e, t, n, o, r) { return uI(t, aI(e, n, o, r)), Hp; }
function Bp(e, t, n, o) { return uI(e, sI(t, n, o)), Bp; }
function aT(e = 1) { _r(Ds() + e); }
function cT(e) { let t = Gl(); return Kt(t, I + e); }
function Vs(e, t) { return e << 17 | t << 2; }
function Ln(e) { return e >> 17 & 32767; }
function lO(e) { return (e & 2) == 2; }
function uO(e, t) { return e & 131071 | t << 17; }
function xd(e) { return e | 2; }
function bo(e) { return (e & 131068) >> 2; }
function wu(e, t) { return e & -131069 | t << 2; }
function dO(e) { return (e & 1) === 1; }
function Od(e) { return e | 1; }
function fO(e, t, n, o, r, i) { let s = i ? t.classBindings : t.styleBindings, a = Ln(s), c = bo(s); e[o] = n; let l = !1, u; if (Array.isArray(n)) {
    let d = n;
    u = d[1], (u === null || Kn(d, u) > 0) && (l = !0);
}
else
    u = n; if (r)
    if (c !== 0) {
        let f = Ln(e[a + 1]);
        e[o + 1] = Vs(f, a), f !== 0 && (e[f + 1] = wu(e[f + 1], o)), e[a + 1] = uO(e[a + 1], o);
    }
    else
        e[o + 1] = Vs(a, 0), a !== 0 && (e[a + 1] = wu(e[a + 1], o)), a = o;
else
    e[o + 1] = Vs(c, 0), a === 0 ? a = o : e[c + 1] = wu(e[c + 1], o), c = o; l && (e[o + 1] = xd(e[o + 1])), Om(e, u, o, !0), Om(e, u, o, !1), pO(t, u, e, o, i), s = Vs(a, c), i ? t.classBindings = s : t.styleBindings = s; }
function pO(e, t, n, o, r) { let i = r ? e.residualClasses : e.residualStyles; i != null && typeof t == "string" && Kn(i, t) >= 0 && (n[o + 1] = Od(n[o + 1])); }
function Om(e, t, n, o) { let r = e[n + 1], i = t === null, s = o ? Ln(r) : bo(r), a = !1; for (; s !== 0 && (a === !1 || i);) {
    let c = e[s], l = e[s + 1];
    hO(c, t) && (a = !0, e[s + 1] = o ? Od(l) : xd(l)), s = o ? Ln(l) : bo(l);
} a && (e[n + 1] = o ? xd(r) : Od(r)); }
function hO(e, t) { return e === null || t == null || (Array.isArray(e) ? e[1] : e) === t ? !0 : Array.isArray(e) && typeof t == "string" ? Kn(e, t) >= 0 : !1; }
var de = { textEnd: 0, key: 0, keyEnd: 0, value: 0, valueEnd: 0 };
function lT(e) { return e.substring(de.key, de.keyEnd); }
function gO(e) { return e.substring(de.value, de.valueEnd); }
function mO(e) { return fT(e), uT(e, Ao(e, 0, de.textEnd)); }
function uT(e, t) { let n = de.textEnd; return n === t ? -1 : (t = de.keyEnd = yO(e, de.key = t, n), Ao(e, t, n)); }
function vO(e) { return fT(e), dT(e, Ao(e, 0, de.textEnd)); }
function dT(e, t) { let n = de.textEnd, o = de.key = Ao(e, t, n); return n === o ? -1 : (o = de.keyEnd = EO(e, o, n), o = Pm(e, o, n, 58), o = de.value = Ao(e, o, n), o = de.valueEnd = IO(e, o, n), Pm(e, o, n, 59)); }
function fT(e) { de.key = 0, de.keyEnd = 0, de.value = 0, de.valueEnd = 0, de.textEnd = e.length; }
function Ao(e, t, n) { for (; t < n && e.charCodeAt(t) <= 32;)
    t++; return t; }
function yO(e, t, n) { for (; t < n && e.charCodeAt(t) > 32;)
    t++; return t; }
function EO(e, t, n) { let o; for (; t < n && ((o = e.charCodeAt(t)) === 45 || o === 95 || (o & -33) >= 65 && (o & -33) <= 90 || o >= 48 && o <= 57);)
    t++; return t; }
function Pm(e, t, n, o) { return t = Ao(e, t, n), t < n && t++, t; }
function IO(e, t, n) { let o = -1, r = -1, i = -1, s = t, a = s; for (; s < n;) {
    let c = e.charCodeAt(s++);
    if (c === 59)
        return a;
    c === 34 || c === 39 ? a = s = Lm(e, c, s, n) : t === s - 4 && i === 85 && r === 82 && o === 76 && c === 40 ? a = s = Lm(e, 41, s, n) : c > 32 && (a = s), i = r, r = o, o = c & -33;
} return a; }
function Lm(e, t, n, o) { let r = -1, i = n; for (; i < o;) {
    let s = e.charCodeAt(i++);
    if (s == t && r !== 92)
        return i;
    s == 92 && r === 92 ? r = 0 : r = s;
} throw new Error; }
function $p(e, t, n) { return gT(e, t, n, !1), $p; }
function Up(e, t) { return gT(e, t, null, !0), Up; }
function pT(e) { mT(ET, DO, e, !1); }
function DO(e, t) { for (let n = vO(t); n >= 0; n = dT(t, n))
    ET(e, lT(t), gO(t)); }
function hT(e) { mT(SO, TO, e, !0); }
function TO(e, t) { for (let n = mO(t); n >= 0; n = uT(t, n))
    yr(e, lT(t), !0); }
function gT(e, t, n, o) { let r = g(), i = A(), s = pt(2); if (i.firstUpdatePass && yT(i, e, s, o), t !== $ && Z(r, s, t)) {
    let a = i.data[le()];
    IT(i, a, r, r[N], e, r[s + 1] = AO(t, n), o, s);
} }
function mT(e, t, n, o) { let r = A(), i = pt(2); r.firstUpdatePass && yT(r, null, i, o); let s = g(); if (n !== $ && Z(s, i, n)) {
    let a = r.data[le()];
    if (DT(a, o) && !vT(r, i)) {
        let c = o ? a.classesWithoutHost : a.stylesWithoutHost;
        c !== null && (n = ns(c, n || "")), Ad(r, a, s, n, o);
    }
    else
        bO(r, a, s, s[N], s[i + 1], s[i + 1] = _O(e, t, n), o, i);
} }
function vT(e, t) { return t >= e.expandoStartIndex; }
function yT(e, t, n, o) { let r = e.data; if (r[n + 1] === null) {
    let i = r[le()], s = vT(e, n);
    DT(i, o) && t === null && !s && (t = !1), t = CO(r, i, t, o), fO(r, i, t, n, s, o);
} }
function CO(e, t, n, o) { let r = Is(e), i = o ? t.residualClasses : t.residualStyles; if (r === null)
    (o ? t.classBindings : t.styleBindings) === 0 && (n = Nu(null, e, t, n, o), n = li(n, t.attrs, o), i = null);
else {
    let s = t.directiveStylingLast;
    if (s === -1 || e[s] !== r)
        if (n = Nu(r, e, t, n, o), i === null) {
            let c = MO(e, t, o);
            c !== void 0 && Array.isArray(c) && (c = Nu(null, e, t, c[1], o), c = li(c, t.attrs, o), wO(e, t, o, c));
        }
        else
            i = NO(e, t, o);
} return i !== void 0 && (o ? t.residualClasses = i : t.residualStyles = i), n; }
function MO(e, t, n) { let o = n ? t.classBindings : t.styleBindings; if (bo(o) !== 0)
    return e[Ln(o)]; }
function wO(e, t, n, o) { let r = n ? t.classBindings : t.styleBindings; e[Ln(r)] = o; }
function NO(e, t, n) { let o, r = t.directiveEnd; for (let i = 1 + t.directiveStylingLast; i < r; i++) {
    let s = e[i].hostAttrs;
    o = li(o, s, n);
} return li(o, t.attrs, n); }
function Nu(e, t, n, o, r) { let i = null, s = n.directiveEnd, a = n.directiveStylingLast; for (a === -1 ? a = n.directiveStart : a++; a < s && (i = t[a], o = li(o, i.hostAttrs, r), i !== e);)
    a++; return e !== null && (n.directiveStylingLast = a), o; }
function li(e, t, n) { let o = n ? 1 : 2, r = -1; if (t !== null)
    for (let i = 0; i < t.length; i++) {
        let s = t[i];
        typeof s == "number" ? r = s : r === o && (Array.isArray(e) || (e = e === void 0 ? [] : ["", e]), yr(e, s, n ? !0 : t[++i]));
    } return e === void 0 ? null : e; }
function _O(e, t, n) { if (n == null || n === "")
    return F; let o = [], r = Ft(n); if (Array.isArray(r))
    for (let i = 0; i < r.length; i++)
        e(o, r[i], !0);
else if (r instanceof Set)
    for (let i of r)
        e(o, i, !0);
else if (typeof r == "object")
    for (let i in r)
        r.hasOwnProperty(i) && e(o, i, r[i]);
else
    typeof r == "string" && t(o, r); return o; }
function ET(e, t, n) { yr(e, t, Ft(n)); }
function SO(e, t, n) { let o = String(t); o !== "" && !o.includes(" ") && yr(e, o, n); }
function bO(e, t, n, o, r, i, s, a) { r === $ && (r = F); let c = 0, l = 0, u = 0 < r.length ? r[0] : null, d = 0 < i.length ? i[0] : null; for (; u !== null || d !== null;) {
    let f = c < r.length ? r[c + 1] : void 0, p = l < i.length ? i[l + 1] : void 0, h = null, v;
    u === d ? (c += 2, l += 2, f !== p && (h = d, v = p)) : d === null || u !== null && u < d ? (c += 2, h = u) : (l += 2, h = d, v = p), h !== null && IT(e, t, n, o, h, v, s, a), u = c < r.length ? r[c] : null, d = l < i.length ? i[l] : null;
} }
function IT(e, t, n, o, r, i, s, a) { if (!(t.type & 3))
    return; let c = e.data, l = c[a + 1], u = dO(l) ? Fm(c, t, n, r, bo(l), s) : void 0; if (!wa(u)) {
    wa(i) || lO(l) && (i = Fm(c, null, n, r, a, s));
    let d = yn(le(), n);
    Nb(o, s, d, r, i);
} }
function Fm(e, t, n, o, r, i) { let s = t === null, a; for (; r > 0;) {
    let c = e[r], l = Array.isArray(c), u = l ? c[1] : c, d = u === null, f = n[r + 1];
    f === $ && (f = d ? F : void 0);
    let p = d ? cs(f, o) : u === o ? f : void 0;
    if (l && !wa(p) && (p = cs(c, o)), wa(p) && (a = p, s))
        return a;
    let h = e[r + 1];
    r = s ? Ln(h) : bo(h);
} if (t !== null) {
    let c = i ? t.residualClasses : t.residualStyles;
    c != null && (a = cs(c, o));
} return a; }
function wa(e) { return e !== void 0; }
function AO(e, t) { return e == null || e === "" || (typeof t == "string" ? e = e + t : typeof e == "object" && (e = ar(Ft(e)))), e; }
function DT(e, t) { return (e.flags & (t ? 8 : 16)) !== 0; }
function TT(e, t = "") { let n = g(), o = A(), r = e + I, i = o.firstCreatePass ? $n(o, r, 1, t, null) : o.data[r], s = CT(o, n, i, t); n[r] = s, Sr() && Rf(o, n, s, i), dt(i, !1); }
var CT = (e, t, n, o) => (rt(!0), lf(t[N], o));
function RO(e, t, n, o) { let r = !Ha(t, n); if (rt(r), r)
    return lf(t[N], o); let i = t[fe]; return bi(i, e, t, n); }
function MT() { CT = RO; }
function wT(e, t) { let n = !1, o = ft(); for (let i = 1; i < t.length; i += 2)
    n = Z(e, o++, t[i]) || n; if (zl(o), !n)
    return $; let r = t[0]; for (let i = 1; i < t.length; i += 2)
    r += b(t[i]) + (i + 1 !== t.length ? t[i + 1] : ""); return r; }
function NT(e, t, n, o = "") { return Z(e, De(), n) ? t + b(n) + o : $; }
function _T(e, t, n, o, r, i = "") { let s = ft(), a = Rn(e, s, n, r); return pt(2), a ? t + b(n) + o + b(r) + i : $; }
function ST(e, t, n, o, r, i, s, a = "") { let c = ft(), l = gc(e, c, n, r, s); return pt(3), l ? t + b(n) + o + b(r) + i + b(s) + a : $; }
function bT(e, t, n, o, r, i, s, a, c, l = "") { let u = ft(), d = Ke(e, u, n, r, s, c); return pt(4), d ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l : $; }
function AT(e, t, n, o, r, i, s, a, c, l, u, d = "") { let f = ft(), p = Ke(e, f, n, r, s, c); return p = Z(e, f + 4, u) || p, pt(5), p ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d : $; }
function RT(e, t, n, o, r, i, s, a, c, l, u, d, f, p = "") { let h = ft(), v = Ke(e, h, n, r, s, c); return v = Rn(e, h + 4, u, f) || v, pt(6), v ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d + b(f) + p : $; }
function kT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v = "") { let y = ft(), T = Ke(e, y, n, r, s, c); return T = gc(e, y + 4, u, f, h) || T, pt(7), T ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d + b(f) + p + b(h) + v : $; }
function xT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y, T = "") { let R = ft(), se = Ke(e, R, n, r, s, c); return se = Ke(e, R + 4, u, f, h, y) || se, pt(8), se ? t + b(n) + o + b(r) + i + b(s) + a + b(c) + l + b(u) + d + b(f) + p + b(h) + v + b(y) + T : $; }
function qp(e) { return _c("", e), qp; }
function _c(e, t, n) { let o = g(), r = NT(o, e, t, n); return r !== $ && Bt(o, le(), r), _c; }
function Gp(e, t, n, o, r) { let i = g(), s = _T(i, e, t, n, o, r); return s !== $ && Bt(i, le(), s), Gp; }
function Wp(e, t, n, o, r, i, s) { let a = g(), c = ST(a, e, t, n, o, r, i, s); return c !== $ && Bt(a, le(), c), Wp; }
function zp(e, t, n, o, r, i, s, a, c) { let l = g(), u = bT(l, e, t, n, o, r, i, s, a, c); return u !== $ && Bt(l, le(), u), zp; }
function Qp(e, t, n, o, r, i, s, a, c, l, u) { let d = g(), f = AT(d, e, t, n, o, r, i, s, a, c, l, u); return f !== $ && Bt(d, le(), f), Qp; }
function Zp(e, t, n, o, r, i, s, a, c, l, u, d, f) { let p = g(), h = RT(p, e, t, n, o, r, i, s, a, c, l, u, d, f); return h !== $ && Bt(p, le(), h), Zp; }
function Yp(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h) { let v = g(), y = kT(v, e, t, n, o, r, i, s, a, c, l, u, d, f, p, h); return y !== $ && Bt(v, le(), y), Yp; }
function Kp(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y) { let T = g(), R = xT(T, e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y); return R !== $ && Bt(T, le(), R), Kp; }
function Jp(e) { let t = g(), n = wT(t, e); return n !== $ && Bt(t, le(), n), Jp; }
function Bt(e, t, n) { let o = yn(t, e); gy(e[N], o, n); }
function Xp(e, t, n) { Ss(t) && (t = t()); let o = g(), r = De(); if (Z(o, r, t)) {
    let i = A(), s = Ve();
    xf(s, o, e, t, o[N], n);
} return Xp; }
function OT(e, t) { let n = Ss(e); return n && e.set(t), n; }
function eh(e, t) { let n = g(), o = A(), r = _(); return Fp(o, n, n[N], r, e, t), eh; }
var PT = {};
function th(e) { te("NgLet"); let t = A(), n = g(), o = e + I, r = $n(t, o, 128, null, null); return dt(r, !1), Mr(t, n, o, PT), th; }
function LT(e) { let t = A(), n = g(), o = le(); return Mr(t, n, o, e), e; }
function FT(e) { let t = Gl(), n = Kt(t, I + e); if (n === PT)
    throw new D(314, !1); return n; }
function jT(e, t) { let n = A(), o = g(), r = o[N], i = "data-ng-source-location"; for (let [s, a, c, l] of t) {
    let u = Yt(n, s + I), d = yn(s + I, o);
    if (!d.hasAttribute(i)) {
        let f = `${e}@o:${a},l:${c},c:${l}`;
        r.setAttribute(d, i, f);
    }
} }
function VT(e) { return Z(g(), De(), e) ? b(e) : $; }
function HT(e, t, n = "") { return NT(g(), e, t, n); }
function BT(e, t, n, o, r = "") { return _T(g(), e, t, n, o, r); }
function $T(e, t, n, o, r, i, s = "") { return ST(g(), e, t, n, o, r, i, s); }
function UT(e, t, n, o, r, i, s, a, c = "") { return bT(g(), e, t, n, o, r, i, s, a, c); }
function qT(e, t, n, o, r, i, s, a, c, l, u = "") { return AT(g(), e, t, n, o, r, i, s, a, c, l, u); }
function GT(e, t, n, o, r, i, s, a, c, l, u, d, f = "") { return RT(g(), e, t, n, o, r, i, s, a, c, l, u, d, f); }
function WT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h = "") { return kT(g(), e, t, n, o, r, i, s, a, c, l, u, d, f, p, h); }
function zT(e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y = "") { return xT(g(), e, t, n, o, r, i, s, a, c, l, u, d, f, p, h, v, y); }
function QT(e) { return wT(g(), e); }
function ZT(e, t, n) { let o = ye() + e, r = g(); return r[o] === $ ? st(r, o, t(n, r)) : Go(r, o); }
function jm(e, t, n) { let o = A(); o.firstCreatePass && YT(t, o.data, o.blueprint, Qe(e), n); }
function YT(e, t, n, o, r) { if (e = L(e), Array.isArray(e))
    for (let i = 0; i < e.length; i++)
        YT(e[i], t, n, o, r);
else {
    let i = A(), s = g(), a = _(), c = dn(e) ? e : L(e.provide), l = wl(e), u = a.providerIndexes & 1048575, d = a.directiveStart, f = a.providerIndexes >> 20;
    if (dn(e) || !e.multi) {
        let p = new Nn(l, r, Wo, null), h = Su(c, t, r ? u : u + f, d);
        h === -1 ? (Ou(ta(a, s), i, c), _u(i, e, t.length), t.push(c), a.directiveStart++, a.directiveEnd++, r && (a.providerIndexes += 1048576), n.push(p), s.push(p)) : (n[h] = p, s[h] = p);
    }
    else {
        let p = Su(c, t, u + f, d), h = Su(c, t, u, u + f), v = p >= 0 && n[p], y = h >= 0 && n[h];
        if (r && !y || !r && !v) {
            Ou(ta(a, s), i, c);
            let T = OO(r ? xO : kO, n.length, r, o, l, e);
            !r && y && (n[h].providerFactory = T), _u(i, e, t.length, 0), t.push(c), a.directiveStart++, a.directiveEnd++, r && (a.providerIndexes += 1048576), n.push(T), s.push(T);
        }
        else {
            let T = KT(n[r ? h : p], l, !r && o);
            _u(i, e, p > -1 ? p : h, T);
        }
        !r && o && y && n[h].componentProviders++;
    }
} }
function _u(e, t, n, o) { let r = dn(t), i = eg(t); if (r || i) {
    let c = (i ? L(t.useClass) : t).prototype.ngOnDestroy;
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
function KT(e, t, n) { return n && e.componentProviders++, e.multi.push(t) - 1; }
function Su(e, t, n, o) { for (let r = n; r < o; r++)
    if (t[r] === e)
        return r; return -1; }
function kO(e, t, n, o, r) { return Pd(this.multi, []); }
function xO(e, t, n, o, r) { let i = this.multi, s; if (this.providerFactory) {
    let a = this.providerFactory.componentProviders, c = Wr(o, o[m], this.providerFactory.index, r);
    s = c.slice(0, a), Pd(i, s);
    for (let l = a; l < c.length; l++)
        s.push(c[l]);
}
else
    s = [], Pd(i, s); return s; }
function Pd(e, t) { for (let n = 0; n < e.length; n++) {
    let o = e[n];
    t.push(o());
} return t; }
function OO(e, t, n, o, r, i) { let s = new Nn(e, n, Wo, null); return s.multi = [], s.index = t, s.componentProviders = 0, KT(s, r, o && !n), s; }
function JT(e, t) { return n => { n.providersResolver = (o, r) => jm(o, r ? r(e) : e, !1), t && (n.viewProvidersResolver = (o, r) => jm(o, r ? r(t) : t, !0)); }; }
function XT(e) { return t => { e.length < 1 || (t.getExternalStyles = n => e.map(r => r + "?ngcomp" + (n ? "=" + encodeURIComponent(n) : "") + "&e=" + t.encapsulation)); }; }
function eC(e, t, n) { let o = e.\u0275cmp; o.directiveDefs = Ea(t, gI), o.pipeDefs = Ea(n, tt); }
function tC(e, t) { return Et(() => { let n = rs(e); n.declarations = Hs(t.declarations || F), n.imports = Hs(t.imports || F), n.exports = Hs(t.exports || F), t.bootstrap && (n.bootstrap = Hs(t.bootstrap)), wo.registerNgModule(e, t); }); }
function Hs(e) { if (typeof e == "function")
    return e; let t = nt(e); return t.some(lr) ? () => t.map(L).map(Vm) : t.map(Vm); }
function Vm(e) { return $f(e) ? e.ngModule : e; }
var nC = () => null, oC = () => { }, Hm = !1;
function rC() { return nC(); }
function iC(e, t) { oC(e, t); }
function sC() { Hm || (Hm = !0, z_(), te("NgIncrementalHydration"), nC = () => new x_, oC = (e, t) => { let n = X_(e), o = RA(t, t.body); tx(e, n, o), G_(t, e); }); }
function aC(e, t) { let n = ye() + e, o = g(); return o[n] === $ ? st(o, n, t()) : Go(o, n); }
function cC(e, t, n) { return vC(g(), ye(), e, t, n); }
function lC(e, t, n, o) { return yC(g(), ye(), e, t, n, o); }
function uC(e, t, n, o, r) { return EC(g(), ye(), e, t, n, o, r); }
function dC(e, t, n, o, r, i, s) { return IC(g(), ye(), e, t, n, o, r, i); }
function fC(e, t, n, o, r, i, s) { let a = ye() + e, c = g(), l = Ke(c, a, n, o, r, i); return Z(c, a + 4, s) || l ? st(c, a + 5, t(n, o, r, i, s)) : Go(c, a + 5); }
function pC(e, t, n, o, r, i, s, a) { let c = ye() + e, l = g(), u = Ke(l, c, n, o, r, i); return Rn(l, c + 4, s, a) || u ? st(l, c + 6, t(n, o, r, i, s, a)) : Go(l, c + 6); }
function hC(e, t, n, o, r, i, s, a, c) { let l = ye() + e, u = g(), d = Ke(u, l, n, o, r, i); return gc(u, l + 4, s, a, c) || d ? st(u, l + 7, t(n, o, r, i, s, a, c)) : Go(u, l + 7); }
function gC(e, t, n, o, r, i, s, a, c, l) { let u = ye() + e, d = g(), f = Ke(d, u, n, o, r, i); return Ke(d, u + 4, s, a, c, l) || f ? st(d, u + 8, t(n, o, r, i, s, a, c, l)) : Go(d, u + 8); }
function mC(e, t, n) { return DC(g(), ye(), e, t, n); }
function Li(e, t) { let n = e[t]; return n === $ ? void 0 : n; }
function vC(e, t, n, o, r, i) { let s = t + n; return Z(e, s, r) ? st(e, s + 1, i ? o.call(i, r) : o(r)) : Li(e, s + 1); }
function yC(e, t, n, o, r, i, s) { let a = t + n; return Rn(e, a, r, i) ? st(e, a + 2, s ? o.call(s, r, i) : o(r, i)) : Li(e, a + 2); }
function EC(e, t, n, o, r, i, s, a) { let c = t + n; return gc(e, c, r, i, s) ? st(e, c + 3, a ? o.call(a, r, i, s) : o(r, i, s)) : Li(e, c + 3); }
function IC(e, t, n, o, r, i, s, a, c) { let l = t + n; return Ke(e, l, r, i, s, a) ? st(e, l + 4, c ? o.call(c, r, i, s, a) : o(r, i, s, a)) : Li(e, l + 4); }
function DC(e, t, n, o, r, i) { let s = t + n, a = !1; for (let c = 0; c < r.length; c++)
    Z(e, s++, r[c]) && (a = !0); return a ? st(e, s, o.apply(i, r)) : Li(e, s); }
function TC(e, t) { let n = A(), o, r = e + I; n.firstCreatePass ? (o = PO(t, n.pipeRegistry), n.data[r] = o, o.onDestroy && (n.destroyHooks ??= []).push(r, o.onDestroy)) : o = n.data[r]; let i = o.factory || (o.factory = Ut(o.type, !0)), s, a = Te(Wo); try {
    let c = ea(!1), l = i();
    return ea(c), Mr(n, g(), r, l), l;
}
finally {
    Te(a);
} }
function PO(e, t) { if (t)
    for (let n = t.length - 1; n >= 0; n--) {
        let o = t[n];
        if (e === o.name)
            return o;
    } }
function CC(e, t, n) { let o = e + I, r = g(), i = Kt(r, o); return Fi(r, o) ? vC(r, ye(), t, i.transform, n, i) : i.transform(n); }
function MC(e, t, n, o) { let r = e + I, i = g(), s = Kt(i, r); return Fi(i, r) ? yC(i, ye(), t, s.transform, n, o, s) : s.transform(n, o); }
function wC(e, t, n, o, r) { let i = e + I, s = g(), a = Kt(s, i); return Fi(s, i) ? EC(s, ye(), t, a.transform, n, o, r, a) : a.transform(n, o, r); }
function NC(e, t, n, o, r, i) { let s = e + I, a = g(), c = Kt(a, s); return Fi(a, s) ? IC(a, ye(), t, c.transform, n, o, r, i, c) : c.transform(n, o, r, i); }
function _C(e, t, n) { let o = e + I, r = g(), i = Kt(r, o); return Fi(r, o) ? DC(r, ye(), t, i.transform, n, i) : i.transform.apply(i, n); }
function Fi(e, t) { return e[m].data[t].pure; }
function SC(e, t) { return cc(e, t); }
function bC(e, t) { return () => { try {
    return wo.getComponentDependencies(e, t).dependencies;
}
catch (n) {
    throw console.error(`Computing dependencies in local compilation mode for the component "${e.name}" failed with the exception:`, n), n;
} }; }
function AC(e, t) { let n = W(e); n !== null && (n.debugInfo = t); }
function RC(e, t, n) { let o = `./@ng/component?c=${e}&t=${encodeURIComponent(t)}`; return new URL(o, n).href; }
function kC(e, t, n, o, r = null, i = null) { let s = W(e); t.apply(null, [e, n, ...o]); let { newDef: a, oldDef: c } = LO(s, W(e)); if (e[fn] = a, c.tView) {
    let l = s_().values();
    for (let u of l)
        lt(u) && u[z] === null && Zs(r, i, a, c, u);
} }
function LO(e, t) { let n = q({}, e); return { newDef: Object.assign(e, t, { directiveDefs: n.directiveDefs, pipeDefs: n.pipeDefs, setInput: n.setInput, type: n.type }), oldDef: n }; }
function Zs(e, t, n, o, r) { let i = r[m]; if (i === o.tView) {
    jO(e, t, n, o, r);
    return;
} for (let s = I; s < i.bindingStartIndex; s++) {
    let a = r[s];
    if (K(a)) {
        J(a[H]) && Zs(e, t, n, o, a[H]);
        for (let c = U; c < a.length; c++)
            Zs(e, t, n, o, a[c]);
    }
    else
        J(a) && Zs(e, t, n, o, a);
} }
function FO(e, t) { e.componentReplaced?.(t.id); }
function jO(e, t, n, o, r) { let i = r[B], s = r[H], a = r[z], c = r[ce], l = r[x].get(G, null), u = () => { if (o.encapsulation === Ye.ShadowDom || o.encapsulation === Ye.ExperimentalIsolatedShadowDom) {
    let h = s.cloneNode(!1);
    s.replaceWith(h), s = h;
} let d = Ny(n), f = qa(a, d, i, Ef(n), s, c, null, null, null, null, null); VO(a, r, f, c.index), Si(r[m], r), ei(r); let p = r[We].rendererFactory; FO(p, o), f[N] = p.createRenderer(s, n), jy(r[m], r), HO(c), ic(d, f, i), rE(d, f, d.template, i); }; l === null ? Bm(e, t, u) : l.run(() => Bm(e, t, u)); }
function Bm(e, t, n) {
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
function VO(e, t, n, o) { for (let r = I; r < e[m].bindingStartIndex; r++) {
    let i = e[r];
    if ((J(i) || K(i)) && i[ge] === t) {
        i[ge] = n;
        break;
    }
} e[Qt] === t && (e[Qt] = n), e[Dr] === t && (e[Dr] = n), n[ge] = t[ge], t[ge] = null, e[o] = n; }
function HO(e) { if (e.projection !== null) {
    for (let t of e.projection)
        Na(t) && (t.projectionNext = null, t.flags &= -3);
    e.projection = null;
} }
var Ee = { \u0275\u0275animateEnter: Vr, \u0275\u0275animateEnterListener: Hr, \u0275\u0275animateLeave: Br, \u0275\u0275animateLeaveListener: Ia, \u0275\u0275attribute: Ep, \u0275\u0275defineComponent: hI, \u0275\u0275defineDirective: mI, \u0275\u0275defineInjectable: Y, \u0275\u0275defineInjector: ur, \u0275\u0275defineNgModule: np, \u0275\u0275defineService: Pt, \u0275\u0275definePipe: vI, \u0275\u0275directiveInject: Wo, \u0275\u0275getInheritedFactory: dv, \u0275\u0275inject: he, \u0275\u0275injectAttribute: _a, \u0275\u0275invalidFactory: zE, \u0275\u0275invalidFactoryDep: as, \u0275\u0275templateRefExtractor: SC, \u0275\u0275resetView: Bl, \u0275\u0275HostDirectivesFeature: SI, \u0275\u0275NgOnChangesFeature: Zm, \u0275\u0275ControlFeature: _I, \u0275\u0275ProvidersFeature: JT, \u0275\u0275InheritDefinitionFeature: cp, \u0275\u0275ExternalStylesFeature: XT, \u0275\u0275nextContext: nT, \u0275\u0275namespaceHTML: Xl, \u0275\u0275namespaceMathML: Jl, \u0275\u0275namespaceSVG: Kl, \u0275\u0275enableBindings: Fl, \u0275\u0275disableBindings: jl, \u0275\u0275elementStart: ai, \u0275\u0275elementEnd: Tc, \u0275\u0275element: Dp, \u0275\u0275elementContainerStart: wc, \u0275\u0275elementContainerEnd: Oi, \u0275\u0275domElement: Tp, \u0275\u0275domElementStart: Cc, \u0275\u0275domElementEnd: Mc, \u0275\u0275domElementContainer: Np, \u0275\u0275domElementContainerStart: Nc, \u0275\u0275domElementContainerEnd: wp, \u0275\u0275domTemplate: up, \u0275\u0275domListener: Lp, \u0275\u0275elementContainer: Mp, \u0275\u0275pureFunction0: aC, \u0275\u0275pureFunction1: cC, \u0275\u0275pureFunction2: lC, \u0275\u0275pureFunction3: uC, \u0275\u0275pureFunction4: dC, \u0275\u0275pureFunction5: fC, \u0275\u0275pureFunction6: pC, \u0275\u0275pureFunction7: hC, \u0275\u0275pureFunction8: gC, \u0275\u0275pureFunctionV: mC, \u0275\u0275getCurrentView: LD, \u0275\u0275restoreView: Hl, \u0275\u0275listener: Op, \u0275\u0275projection: rT, \u0275\u0275syntheticHostProperty: bp, \u0275\u0275syntheticHostListener: Pp, \u0275\u0275pipeBind1: CC, \u0275\u0275pipeBind2: MC, \u0275\u0275pipeBind3: wC, \u0275\u0275pipeBind4: NC, \u0275\u0275pipeBindV: _C, \u0275\u0275projectionDef: oT, \u0275\u0275domProperty: Sp, \u0275\u0275ariaProperty: yp, \u0275\u0275property: Ip, \u0275\u0275control: $E, \u0275\u0275controlCreate: HE, \u0275\u0275pipe: TC, \u0275\u0275queryRefresh: iT, \u0275\u0275queryAdvance: aT, \u0275\u0275viewQuery: Vp, \u0275\u0275viewQuerySignal: Bp, \u0275\u0275loadQuery: sT, \u0275\u0275contentQuery: jp, \u0275\u0275contentQuerySignal: Hp, \u0275\u0275reference: cT, \u0275\u0275classMap: hT, \u0275\u0275styleMap: pT, \u0275\u0275styleProp: $p, \u0275\u0275classProp: Up, \u0275\u0275advance: _y, \u0275\u0275template: lp, \u0275\u0275conditional: bD, \u0275\u0275conditionalCreate: SD, \u0275\u0275conditionalBranchCreate: Dc, \u0275\u0275defer: rD, \u0275\u0275deferWhen: iD, \u0275\u0275deferOnIdle: lD, \u0275\u0275deferOnImmediate: fD, \u0275\u0275deferOnTimer: gD, \u0275\u0275deferOnHover: yD, \u0275\u0275deferOnInteraction: DD, \u0275\u0275deferOnViewport: MD, \u0275\u0275deferPrefetchWhen: sD, \u0275\u0275deferPrefetchOnIdle: uD, \u0275\u0275deferPrefetchOnImmediate: pD, \u0275\u0275deferPrefetchOnTimer: mD, \u0275\u0275deferPrefetchOnHover: ED, \u0275\u0275deferPrefetchOnInteraction: TD, \u0275\u0275deferPrefetchOnViewport: wD, \u0275\u0275deferHydrateWhen: aD, \u0275\u0275deferHydrateNever: cD, \u0275\u0275deferHydrateOnIdle: dD, \u0275\u0275deferHydrateOnImmediate: hD, \u0275\u0275deferHydrateOnTimer: vD, \u0275\u0275deferHydrateOnHover: ID, \u0275\u0275deferHydrateOnInteraction: CD, \u0275\u0275deferHydrateOnViewport: ND, \u0275\u0275deferEnableTimerScheduling: UI, \u0275\u0275enableIncrementalHydrationRuntime: sC, \u0275\u0275repeater: xD, \u0275\u0275repeaterCreate: kD, \u0275\u0275repeaterTrackByIndex: AD, \u0275\u0275repeaterTrackByIdentity: RD, \u0275\u0275componentInstance: _D, \u0275\u0275text: TT, \u0275\u0275textInterpolate: qp, \u0275\u0275textInterpolate1: _c, \u0275\u0275textInterpolate2: Gp, \u0275\u0275textInterpolate3: Wp, \u0275\u0275textInterpolate4: zp, \u0275\u0275textInterpolate5: Qp, \u0275\u0275textInterpolate6: Zp, \u0275\u0275textInterpolate7: Yp, \u0275\u0275textInterpolate8: Kp, \u0275\u0275textInterpolateV: Jp, \u0275\u0275i18n: JD, \u0275\u0275i18nAttributes: XD, \u0275\u0275i18nExp: xp, \u0275\u0275i18nStart: Rp, \u0275\u0275i18nEnd: kp, \u0275\u0275i18nApply: eT, \u0275\u0275i18nPostprocess: tT, \u0275\u0275resolveWindow: Ty, \u0275\u0275resolveDocument: Cy, \u0275\u0275resolveBody: mf, \u0275\u0275setComponentScope: eC, \u0275\u0275setNgModuleScope: tC, \u0275\u0275registerNgModuleType: sp, \u0275\u0275getComponentDepsFactory: bC, \u0275setClassDebugInfo: AC, \u0275\u0275declareLet: th, \u0275\u0275storeLet: LT, \u0275\u0275arrowFunction: ZT, \u0275\u0275readContextLet: FT, \u0275\u0275attachSourceLocations: jT, \u0275\u0275interpolate: VT, \u0275\u0275interpolate1: HT, \u0275\u0275interpolate2: BT, \u0275\u0275interpolate3: $T, \u0275\u0275interpolate4: UT, \u0275\u0275interpolate5: qT, \u0275\u0275interpolate6: GT, \u0275\u0275interpolate7: WT, \u0275\u0275interpolate8: zT, \u0275\u0275interpolateV: QT, \u0275\u0275sanitizeHtml: df, \u0275\u0275sanitizeStyle: ff, \u0275\u0275sanitizeResourceUrl: Ua, \u0275\u0275sanitizeScript: hf, \u0275\u0275validateAttribute: gf, \u0275\u0275sanitizeUrl: pf, \u0275\u0275sanitizeUrlOrResourceUrl: Dy, \u0275\u0275trustConstantHtml: Ey, \u0275\u0275trustConstantResourceUrl: Iy, forwardRef: cr, resolveForwardRef: L, \u0275\u0275twoWayProperty: Xp, \u0275\u0275twoWayBindingSet: OT, \u0275\u0275twoWayListener: eh, \u0275\u0275replaceMetadata: kC, \u0275\u0275getReplaceMetadataURL: RC }, mo = null;
function xC(e) { mo !== null && (e.defaultEncapsulation !== mo.defaultEncapsulation || e.preserveWhitespaces !== mo.preserveWhitespaces) || (mo = e); }
function BO() { return mo; }
function $O() { mo = null; }
var Gr = [];
function UO(e, t) { Gr.push({ moduleType: e, ngModule: t }); }
var bu = !1;
function OC() { if (!bu) {
    bu = !0;
    try {
        for (let e = Gr.length - 1; e >= 0; e--) {
            let { moduleType: t, ngModule: n } = Gr[e];
            n.declarations && n.declarations.every(PC) && (Gr.splice(e, 1), QO(t, n));
        }
    }
    finally {
        bu = !1;
    }
} }
function PC(e) { return Array.isArray(e) ? e.every(PC) : !!L(e); }
function LC(e, t = {}) { FC(e, t), t.id !== void 0 && sp(e, t.id), UO(e, t); }
function FC(e, t, n = !1) { let o = nt(t.declarations || F), r = null; Object.defineProperty(e, os, { configurable: !0, get: () => (r === null && (r = X({ usage: 0, kind: "NgModule", type: e }).compileNgModule(Ee, `ng:///${e.name}/\u0275mod.js`, { type: e, bootstrap: nt(t.bootstrap || F).map(L), declarations: o.map(L), imports: nt(t.imports || F).map(L).map($m), exports: nt(t.exports || F).map(L).map($m), schemas: t.schemas ? nt(t.schemas) : null, id: t.id || null }), r.schemas || (r.schemas = [])), r) }); let i = null; Object.defineProperty(e, $e, { get: () => { if (i === null) {
        let a = X({ usage: 0, kind: "NgModule", type: e });
        i = a.compileFactory(Ee, `ng:///${e.name}/\u0275fac.js`, { name: e.name, type: e, deps: pi(e), target: a.FactoryTarget.NgModule, typeArgumentCount: 0 });
    } return i; }, configurable: !1 }); let s = null; Object.defineProperty(e, er, { get: () => { if (s === null) {
        let a = { name: e.name, type: e, providers: t.providers || F, imports: [(t.imports || F).map(L), (t.exports || F).map(L)] };
        s = X({ usage: 0, kind: "NgModule", type: e }).compileInjector(Ee, `ng:///${e.name}/\u0275inj.js`, a);
    } return s; }, configurable: !1 }); }
function qO(e, t) { let n = `Unexpected "${qe(e)}" found in the "declarations" array of the`, o = `"${qe(e)}" is marked as standalone and can't be declared in any NgModule - did you intend to import it instead (by adding it to the "imports" array)?`; return `${n} ${t}, ${o}`; }
var GO = new WeakMap, WO = new WeakMap;
function zO() { GO = new WeakMap, WO = new WeakMap, Gr.length = 0, qR.clear(); }
function QO(e, t) { let n = nt(t.declarations || F), o = oh(e); n.forEach(r => { if (r = L(r), r.hasOwnProperty(fn)) {
    let s = W(r);
    nh(s, o);
}
else
    !r.hasOwnProperty(fr) && !r.hasOwnProperty(pr) && (r.ngSelectorScope = e); }); }
function nh(e, t) { e.directiveDefs = () => Array.from(t.compilation.directives).map(n => n.hasOwnProperty(fn) ? W(n) : Oe(n)).filter(n => !!n), e.pipeDefs = () => Array.from(t.compilation.pipes).map(n => tt(n)), e.schemas = t.schemas, e.tView = null; }
function oh(e) { if (Dn(e)) {
    let t = wo.getNgModuleScope(e), n = rs(e);
    return q({ schemas: n.schemas || null }, t);
}
else if (hr(e)) {
    if ((W(e) || Oe(e)) !== null)
        return { schemas: null, compilation: { directives: new Set, pipes: new Set }, exported: { directives: new Set([e]), pipes: new Set } };
    if (tt(e) !== null)
        return { schemas: null, compilation: { directives: new Set, pipes: new Set }, exported: { directives: new Set, pipes: new Set([e]) } };
} throw new Error(`${e.name} does not have a module def (\u0275mod property)`); }
function $m(e) { return $f(e) ? e.ngModule : e; }
var Au = 0;
function jC(e, t) {
    let n = null;
    zR(e, t), HC(e, t), Object.defineProperty(e, fn, { get: () => {
            if (n === null) {
                let o = X({ usage: 0, kind: "component", type: e });
                if (MI(t)) {
                    let u = [`Component '${e.name}' is not resolved:`];
                    throw t.templateUrl && u.push(` - templateUrl: ${t.templateUrl}`), t.styleUrls && t.styleUrls.length && u.push(` - styleUrls: ${JSON.stringify(t.styleUrls)}`), t.styleUrl && u.push(` - styleUrl: ${t.styleUrl}`), u.push("Did you run and wait for 'resolveComponentResources()'?"), new Error(u.join(`
`));
                }
                let r = BO(), i = t.preserveWhitespaces;
                i === void 0 && (r !== null && r.preserveWhitespaces !== void 0 ? i = r.preserveWhitespaces : i = !1);
                let s = t.encapsulation;
                s === void 0 && (r !== null && r.defaultEncapsulation !== void 0 ? s = r.defaultEncapsulation : s = Ye.Emulated);
                let a = t.templateUrl || `ng:///${e.name}/template.html`, c = BC(e, t), l = Ie(q({}, c), { typeSourceSpan: o.createParseSourceSpan("Component", e.name, a), template: t.template || "", preserveWhitespaces: i, styles: typeof t.styles == "string" ? [t.styles] : t.styles || F, animations: t.animations, declarations: [], changeDetection: t.changeDetection, encapsulation: s, viewProviders: t.viewProviders || null, hasDirectiveDependencies: !c.isStandalone || t.imports != null && t.imports.length > 0 });
                Au++;
                try {
                    if (l.usesInheritance && $C(e), n = o.compileComponent(Ee, a, l), l.isStandalone) {
                        let u = nt(t.imports || F), { directiveDefs: d, pipeDefs: f } = ZO(e, u);
                        n.directiveDefs = d, n.pipeDefs = f, n.dependencies = () => u.map(L);
                    }
                }
                finally {
                    Au--;
                }
                if (Au === 0 && OC(), YO(e)) {
                    let u = oh(e.ngSelectorScope);
                    nh(n, u);
                }
                if (t.schemas)
                    if (l.isStandalone)
                        n.schemas = t.schemas;
                    else
                        throw new Error(`The 'schemas' was specified for the ${qe(e)} but is only valid on a component that is standalone.`);
                else
                    l.isStandalone && (n.schemas = []);
            }
            return n;
        }, set: o => { n = o; }, configurable: !1 });
}
function ZO(e, t) { return { directiveDefs: () => Lr(e) ? [...wo.getStandaloneComponentScope(e, t).compilation.directives].map(i => W(i) || Oe(i)).filter(i => i !== null) : [], pipeDefs: () => Lr(e) ? [...wo.getStandaloneComponentScope(e, t).compilation.pipes].map(i => tt(i)).filter(i => i !== null) : [] }; }
function YO(e) { return e.ngSelectorScope !== void 0; }
function rh(e, t) { let n = null; HC(e, t || {}), Object.defineProperty(e, fr, { get: () => { if (n === null) {
        let o = VC(e, t || {});
        n = X({ usage: 0, kind: "directive", type: e }).compileDirective(Ee, o.sourceMapUrl, o.metadata);
    } return n; }, configurable: !1 }); }
function VC(e, t) { let n = e && e.name, o = `ng:///${n}/\u0275dir.js`, r = X({ usage: 0, kind: "directive", type: e }), i = BC(e, t); return i.typeSourceSpan = r.createParseSourceSpan("Directive", n, o), i.usesInheritance && $C(e), { metadata: i, sourceMapUrl: o }; }
function HC(e, t) { let n = null; Object.defineProperty(e, $e, { get: () => { if (n === null) {
        let o = VC(e, t), r = X({ usage: 0, kind: "directive", type: e });
        n = r.compileFactory(Ee, `ng:///${e.name}/\u0275fac.js`, { name: o.metadata.name, type: o.metadata.type, typeArgumentCount: 0, deps: pi(e), target: r.FactoryTarget.Directive });
    } return n; }, configurable: !1 }); }
function KO(e) { return Object.getPrototypeOf(e.prototype) === Object.prototype; }
function BC(e, t) { let n = Bd(), o = n.ownPropMetadata(e); return { name: e.name, legacyOptionalChaining: !1, type: e, selector: t.selector !== void 0 ? t.selector : null, host: t.host || wt, propMetadata: o, inputs: t.inputs || F, outputs: t.outputs || F, queries: Um(e, o, UC), lifecycle: { usesOnChanges: n.hasLifecycleHook(e, "ngOnChanges") }, controlCreate: n.hasLifecycleHook(e, "\u0275ngControlCreate") ? { passThroughInput: null } : null, typeSourceSpan: null, usesInheritance: !KO(e), exportAs: eP(t.exportAs), providers: t.providers || null, viewQueries: Um(e, o, qC), isStandalone: t.standalone === void 0 ? !0 : !!t.standalone, isSignal: !!t.signals, hostDirectives: t.hostDirectives?.map(r => typeof r == "function" ? { directive: r } : r) || null }; }
function $C(e) { let t = Object.prototype, n = Object.getPrototypeOf(e.prototype).constructor; for (; n && n !== t;)
    !Oe(n) && !W(n) && nP(n) && rh(n, null), n = Object.getPrototypeOf(n); }
function JO(e) { return typeof e == "string" ? WC(e) : L(e); }
function XO(e, t) { return { propertyName: e, predicate: JO(t.selector), descendants: t.descendants, first: t.first, read: t.read ? t.read : null, static: !!t.static, emitDistinctChangesOnly: !!t.emitDistinctChangesOnly, isSignal: !!t.isSignal }; }
function Um(e, t, n) { let o = [], r = []; for (let i in t)
    if (t.hasOwnProperty(i)) {
        let s = t[i];
        s.forEach(a => { if (n(a)) {
            if (!a.selector)
                throw new Error(`Can't construct a query for the property "${i}" of "${qe(e)}" since the query selector wasn't defined.`);
            if (s.some(GC))
                throw new Error("Cannot combine @Input decorators with query decorators");
            let c = XO(i, a);
            c.isSignal ? o.push(c) : r.push(c);
        } });
    } return [...o, ...r]; }
function eP(e) { return e === void 0 ? null : WC(e); }
function UC(e) { let t = e.ngMetadataName; return t === "ContentChild" || t === "ContentChildren"; }
function qC(e) { let t = e.ngMetadataName; return t === "ViewChild" || t === "ViewChildren"; }
function GC(e) { return e.ngMetadataName === "Input"; }
function WC(e) { return e.split(",").map(t => t.trim()); }
var tP = ["ngOnChanges", "ngOnInit", "ngOnDestroy", "ngDoCheck", "ngAfterViewInit", "ngAfterViewChecked", "ngAfterContentInit", "ngAfterContentChecked"];
function nP(e) { let t = Bd(); if (tP.some(o => t.hasLifecycleHook(e, o)))
    return !0; let n = t.propMetadata(e); for (let o in n) {
    let r = n[o];
    for (let i = 0; i < r.length; i++) {
        let s = r[i], a = s.ngMetadataName;
        if (GC(s) || UC(s) || qC(s) || a === "Output" || a === "HostBinding" || a === "HostListener")
            return !0;
    }
} return !1; }
function zC(e, t) { let n = null, o = null; Object.defineProperty(e, $e, { get: () => { if (o === null) {
        let r = qm(e, t), i = X({ usage: 0, kind: "pipe", type: r.type });
        o = i.compileFactory(Ee, `ng:///${r.name}/\u0275fac.js`, { name: r.name, type: r.type, typeArgumentCount: 0, deps: pi(e), target: i.FactoryTarget.Pipe });
    } return o; }, configurable: !1 }), Object.defineProperty(e, pr, { get: () => { if (n === null) {
        let r = qm(e, t);
        n = X({ usage: 0, kind: "pipe", type: r.type }).compilePipe(Ee, `ng:///${r.name}/\u0275pipe.js`, r);
    } return n; }, configurable: !1 }); }
function qm(e, t) { return { type: e, name: e.name, pipeName: t.name, pure: t.pure !== void 0 ? t.pure : !0, isStandalone: t.standalone === void 0 ? !0 : !!t.standalone }; }
var QC = Ro("Directive", (e = {}) => e, void 0, void 0, (e, t) => rh(e, t)), oP = Ro("Component", (e = {}) => q({ changeDetection: ba.Eager }, e), QC, void 0, (e, t) => jC(e, t)), rP = Ro("Pipe", e => q({ pure: !0 }, e), void 0, void 0, (e, t) => zC(e, t)), iP = Ot("Input", e => e ? typeof e == "string" ? { alias: e } : e : {}), sP = Ot("Output", e => ({ alias: e })), aP = Ot("HostBinding", e => ({ hostPropertyName: e })), cP = Ot("HostListener", (e, t) => ({ eventName: e, args: t })), lP = Ro("NgModule", e => e, void 0, void 0, (e, t) => LC(e, t));
var ZC = (() => { class e {
    applicationErrorHandler = E(_t);
    appRef = E(He);
    taskService = E(gt);
    ngZone = E(G);
    zonelessEnabled = E(so);
    tracing = E(Bn, { optional: !0 });
    zoneIsDefined = typeof Zone < "u" && !!Zone.root.run;
    schedulerTickApplyArgs = [{ data: { __scheduler_tick__: !0 } }];
    subscriptions = new mN;
    angularZoneId = this.zoneIsDefined ? this.ngZone._inner?.get(or) : null;
    scheduleInRootZone = !this.zonelessEnabled && this.zoneIsDefined && (E(ws, { optional: !0 }) ?? !1);
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
        return; let o = this.useMicrotaskScheduler ? Ig : ou; this.pendingRenderTaskId = this.taskService.add(), this.scheduleInRootZone ? this.cancelScheduledCallback = Zone.root.run(() => o(() => this.tick())) : this.cancelScheduledCallback = this.ngZone.runOutsideAngular(() => o(() => this.tick())); }
    shouldScheduleTick() { return !(this.appRef.destroyed || this.pendingRenderTaskId !== null || this.runningTick || this.appRef._runningTick || !this.zonelessEnabled && this.zoneIsDefined && Zone.current.get(or + this.angularZoneId)); }
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
    static \u0275prov = Pt({ token: e, factory: e.\u0275fac });
} return e; })();
function uP() { return te("NgZoneless"), Le([...Sc(), []]); }
function Sc() { return [{ provide: Ue, useExisting: ZC }, { provide: G, useClass: rr }, { provide: so, useValue: !0 }]; }
var dP = (() => { class e {
    compileModuleSync(n) { return new _o(n); }
    compileModuleAsync(n) { return Promise.resolve(this.compileModuleSync(n)); }
    clearCache() { }
    clearCacheFor(n) { }
    getModuleId(n) { }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Pt({ token: e, factory: e.\u0275fac });
} return e; })(), YC = new C(""), Ld = class {
};
function fP() { return typeof ngI18nClosureMode < "u" && ngI18nClosureMode && typeof goog < "u" && goog.LOCALE !== "en" ? goog.LOCALE : typeof $localize < "u" && $localize.locale || Pi; }
var ih = new C("", { factory: () => E(ih, { optional: !0, skipSelf: !0 }) || fP() }), pP = new C("", { factory: () => _x }), hP = new C(""), gP = new C(""), KC = (function (e) { return e[e.Error = 0] = "Error", e[e.Warning = 1] = "Warning", e[e.Ignore = 2] = "Ignore", e; })(KC || {});
function Ys(e, t) { let n = e[m]; for (let o = I; o < n.bindingStartIndex; o++)
    if (K(e[o])) {
        let r = e[o];
        if (!(o === n.bindingStartIndex - 1)) {
            let s = n.data[o], a = pe(n, s);
            if (FI(a)) {
                t.push({ lContainer: r, lView: e, tNode: s, tDetails: a });
                continue;
            }
        }
        J(r[H]) && Ys(r[H], t);
        for (let s = U; s < r.length; s++)
            Ys(r[s], t);
    }
    else
        J(e[o]) && Ys(e[o], t); }
var Fd = class {
    name;
    callback;
    constructor(t, n) { this.name = t, this.callback = n; }
};
function mP(e) { return e.map(t => t.nativeElement); }
var ui = class {
    nativeNode;
    constructor(t) { this.nativeNode = t; }
    get parent() { let t = this.nativeNode.parentNode; return t ? new Fn(t) : null; }
    get injector() { return qd(this.nativeNode); }
    get componentInstance() { let t = this.nativeNode; return t && (Lg(t) || v_(t)); }
    get context() { return Lg(this.nativeNode) || m_(this.nativeNode); }
    get listeners() { return T_(this.nativeNode).filter(t => t.type === "dom"); }
    get references() { return I_(this.nativeNode); }
    get providerTokens() { return y_(this.nativeNode); }
}, Fn = class extends ui {
    constructor(t) { super(t); }
    get nativeElement() { return this.nativeNode.nodeType == Node.ELEMENT_NODE ? this.nativeNode : null; }
    get name() { let t = we(this.nativeNode), n = t ? t.lView : null; return n !== null ? n[m].data[t.nodeIndex].value : this.nativeNode.nodeName; }
    get properties() { let t = we(this.nativeNode), n = t ? t.lView : null; if (n === null)
        return {}; let o = n[m].data, r = o[t.nodeIndex], i = {}; return vP(this.nativeElement, i), EP(i, r, n, o), i; }
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
        n.push(di(r));
    } return n; }
    get children() { let t = this.nativeElement; if (!t)
        return []; let n = t.children, o = []; for (let r = 0; r < n.length; r++) {
        let i = n[r];
        o.push(di(i));
    } return o; }
    query(t) { return this.queryAll(t)[0] || null; }
    queryAll(t) { let n = []; return Gm(this, t, n, !0), n; }
    queryAllNodes(t) { let n = []; return Gm(this, t, n, !1), n; }
    triggerEventHandler(t, n) { let o = this.nativeNode, r = []; this.listeners.forEach(i => { if (i.name === t) {
        let s = i.callback;
        s.call(o, n), r.push(s);
    } }), typeof o.eventListeners == "function" && o.eventListeners(t).forEach(i => { if (i.toString().indexOf("__ngUnwrap__") !== -1) {
        let s = i("__ngUnwrap__");
        return r.indexOf(s) === -1 && s.call(o, n);
    } }); }
};
function vP(e, t) { if (e) {
    let n = Object.getPrototypeOf(e), o = Node.prototype;
    for (; n !== null && n !== o;) {
        let r = Object.getOwnPropertyDescriptors(n);
        for (let i in r)
            if (!i.startsWith("__") && !i.startsWith("on")) {
                let s = e[i];
                yP(s) && (t[i] = s);
            }
        n = Object.getPrototypeOf(n);
    }
} }
function yP(e) { return typeof e == "string" || typeof e == "boolean" || typeof e == "number" || e === null; }
function Gm(e, t, n, o) { let r = we(e.nativeNode), i = r ? r.lView : null; if (i !== null) {
    let s = i[m].data[r.nodeIndex];
    Tn(s, i, t, n, o, e.nativeNode);
}
else
    sh(e.nativeNode, t, n, o); }
function Tn(e, t, n, o, r, i) { let s = rg(e, t); if (e.type & 11) {
    if (Ru(s, n, o, r, i), Ce(e)) {
        let c = me(e.index, t);
        c && c[m].firstChild && Tn(c[m].firstChild, c, n, o, r, i);
    }
    else
        e.child && Tn(e.child, t, n, o, r, i), s && sh(s, n, o, r);
    let a = t[e.index];
    K(a) && Wm(a, n, o, r, i);
}
else if (e.type & 4) {
    let a = t[e.index];
    Ru(a[ot], n, o, r, i), Wm(a, n, o, r, i);
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
function Wm(e, t, n, o, r) { for (let i = U; i < e.length; i++) {
    let s = e[i], a = s[m].firstChild;
    a && Tn(a, s, t, n, o, r);
} }
function Ru(e, t, n, o, r) { if (r !== e) {
    let i = di(e);
    if (!i)
        return;
    (o && i instanceof Fn && t(i) && n.indexOf(i) === -1 || !o && t(i) && n.indexOf(i) === -1) && n.push(i);
} }
function sh(e, t, n, o) { let r = e.childNodes, i = r.length; for (let s = 0; s < i; s++) {
    let a = r[s], c = di(a);
    c && ((o && c instanceof Fn && t(c) && n.indexOf(c) === -1 || !o && t(c) && n.indexOf(c) === -1) && n.push(c), sh(a, t, n, o));
} }
function EP(e, t, n, o) { let r = t.propertyBindings; if (r !== null)
    for (let i = 0; i < r.length; i++) {
        let s = r[i], c = o[s].split(VS), l = c[0];
        if (c.length > 1) {
            let u = c[1];
            for (let d = 1; d < c.length - 1; d++)
                u += b(n[s + d - 1]) + c[d + 1];
            e[l] = u;
        }
        else
            e[l] = n[s];
    } }
var ku = "__ng_debug__";
function di(e) { return e instanceof Node ? (e.hasOwnProperty(ku) || (e[ku] = e.nodeType == Node.ELEMENT_NODE ? new Fn(e) : new ui(e)), e[ku]) : null; }
var ji = class {
    destroyed = !1;
    listeners = null;
    errorHandler = E(Mt, { optional: !0 });
    destroyRef = E(Re);
    constructor() { this.destroyRef.onDestroy(() => { this.destroyed = !0, this.listeners = null; }); }
    subscribe(t) { if (this.destroyed)
        throw new D(953, !1); return (this.listeners ??= []).push(t), { unsubscribe: () => { let n = this.listeners?.indexOf(t); n !== void 0 && n !== -1 && this.listeners?.splice(n, 1); } }; }
    emit(t) { if (this.destroyed) {
        console.warn(sr(953, !1));
        return;
    } if (this.listeners === null)
        return; let n = k(null); try {
        for (let o of this.listeners)
            try {
                o(t);
            }
            catch (r) {
                this.errorHandler?.handleError(r);
            }
    }
    finally {
        k(n);
    } }
};
function IP(e) { return e.destroyRef; }
var tM = new C("");
function xe(e, t) { return Qi(e, t?.equal); }
function ke(e) { return Hh(e); }
var bc = class extends Error {
    dependency;
    constructor(t) { super("Dependency error", { cause: t.error() }), this.name = "ResourceDependencyError", this.dependency = t; }
}, Un = class e extends Error {
    _brand;
    constructor(t) { super(t); }
    static IDLE = new e("IDLE");
    static LOADING = new e("LOADING");
}, DP = e => e;
function Ac(e, t) { if (typeof e == "function") {
    let n = tl(e, DP, t?.equal);
    return JC(n, t?.debugName);
}
else {
    let n = tl(e.source, e.computation, e.equal);
    return JC(n, e.debugName);
} }
function JC(e, t) { let n = e[ae], o = e; return o.set = r => jh(n, r), o.update = r => Vh(n, r), o.asReadonly = ro.bind(e), o; }
function TP(e) { let t = e.request, n = e.params ?? t ?? (() => null); return new Rc(n, MP(e), e.defaultValue, e.equal ? CP(e.equal) : void 0, e.debugName, e.injector ?? E(oe), e.id); }
var ah = class {
    value;
    isLoading;
    constructor(t, n) { this.value = t, this.value.set = this.set.bind(this), this.value.update = this.update.bind(this), this.value.asReadonly = ro, this.isLoading = xe(() => this.status() === "loading" || this.status() === "reloading", void 0); }
    isError = xe(() => this.status() === "error");
    update(t) { this.set(t(ke(this.value))); }
    isValueDefined = xe(() => this.isError() ? !1 : this.value() !== void 0);
    _snapshot;
    get snapshot() { return this._snapshot ??= xe(() => { let t = this.status(); return t === "error" ? { status: "error", error: this.error() } : { status: t, value: this.value() }; }); }
    hasValue() { return this.isValueDefined(); }
    asReadonly() { return this; }
}, Rc = class extends ah {
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
    constructor(t, n, o, r, i, s, a, c) { if (lh())
        throw uh(); super(xe(() => { let u = this.state().stream?.(); if (!u || this.state().status === "loading" && this.error())
        return o; if (!kc(u))
        throw new Vi(this.error()); return u.value; }, { equal: r }), i), this.loaderFn = n, this.equal = r, this.debugName = i, this.transferCacheKey = a; let l = s.get(tM, void 0, { optional: !0 }) ?? { isActive: !1 }; this.transferState = s.get(St, void 0, { optional: !0 }) ?? void 0, this.extRequest = Ac(() => { try {
        return qn(!0), { request: t(_P), reload: 0 };
    }
    catch (u) {
        return Hi(u), u === Un.IDLE ? { status: "idle", reload: 0 } : u === Un.LOADING ? { status: "loading", reload: 0 } : { error: u, reload: 0 };
    }
    finally {
        qn(!1);
    } }, void 0), this.state = Ac({ source: this.extRequest, computation: (u, d) => { let { request: f, status: p, error: h } = u, v; if (h)
            p = "resolved", v = mt({ error: xc(h) }, void 0);
        else if (!p)
            if (d)
                p = f === void 0 ? "idle" : "loading", d.value.extRequest.request === f && (v = d.value.stream);
            else {
                let y = this.transferState, T = this.transferCacheKey;
                l.isActive && T && y && f !== void 0 && y.hasKey(T) && (v = mt({ value: y.get(T, o) }, void 0)), v || (v = c?.(u.request)), c = void 0, p = f === void 0 ? "idle" : v ? "resolved" : "loading";
            } return { extRequest: u, status: p, previousStatus: d ? eM(d.value) : "idle", stream: v }; } }), this.effectRef = _s(this.loadEffect.bind(this), { injector: s, manualCleanup: !0 }), this.pendingTasks = s.get(br), this.unregisterOnDestroy = s.get(Re).onDestroy(() => this.destroy()), this.status = xe(() => eM(this.state()), void 0), this.error = xe(() => { let u = this.state().stream?.(); return u && !kc(u) ? u.error : void 0; }, void 0); }
    set(t) { if (this.destroyed)
        return; let n = ke(this.error), o = ke(this.state); if (!n) {
        let r = ke(this.value);
        if (o.status === "local" && (this.equal ? this.equal(r, t) : r === t))
            return;
    } this.state.set({ extRequest: o.extRequest, status: "local", previousStatus: "local", stream: mt({ value: t }, void 0) }), this.abortInProgressLoad(); }
    reload() { let { status: t } = ke(this.state); return t === "idle" || t === "loading" ? !1 : (this.extRequest.update(({ request: n, reload: o }) => ({ request: n, reload: o + 1 })), !0); }
    destroy() { this.destroyed = !0, this.unregisterOnDestroy(), this.effectRef.destroy(), this.abortInProgressLoad(), this.state.set({ extRequest: { request: void 0, reload: 0 }, status: "idle", previousStatus: "idle", stream: void 0 }); }
    loadEffect() { return Se(this, null, function* () { let t = this.extRequest(), { status: n, previousStatus: o } = ke(this.state); if (t.request === void 0)
        return; if (n !== "loading")
        return; this.abortInProgressLoad(); let r = this.resolvePendingTask = this.pendingTasks.add(), { signal: i } = this.pendingController = new AbortController; try {
        let s = ke(() => this.loaderFn({ params: t.request, abortSignal: i, previous: { status: o } })), a = () => i.aborted || ke(this.extRequest) !== t;
        if (ao(s)) {
            if (a())
                return;
            this.state.set({ extRequest: t, status: "resolved", previousStatus: "resolved", stream: s });
            let c = ke(s);
            typeof ngServerMode < "u" && ngServerMode && XC(c, this.transferCacheKey, this.transferState);
        }
        else {
            let c = yield s;
            if (a())
                return;
            this.state.set({ extRequest: t, status: "resolved", previousStatus: "resolved", stream: c });
            let l = c ? ke(c) : void 0;
            typeof ngServerMode < "u" && ngServerMode && XC(l, this.transferCacheKey, this.transferState);
        }
    }
    catch (s) {
        if (Hi(s), i.aborted || ke(this.extRequest) !== t)
            return;
        this.state.set({ extRequest: t, status: "resolved", previousStatus: "error", stream: mt({ error: xc(s) }, void 0) });
    }
    finally {
        r?.(), r = void 0;
    } }); }
    abortInProgressLoad() { ke(() => this.pendingController?.abort()), this.pendingController = void 0, this.resolvePendingTask?.(), this.resolvePendingTask = void 0; }
};
function XC(e, t, n) { t && n && e && kc(e) && n.set(t, e.value); }
function CP(e) { return (t, n) => t === void 0 || n === void 0 ? t === n : e(t, n); }
function MP(e) { return wP(e) ? e.stream : t => Se(null, null, function* () { try {
    return mt({ value: yield e.loader(t) }, void 0);
}
catch (n) {
    return mt({ error: xc(n) }, void 0);
} }); }
function wP(e) { return !!e.stream; }
function eM(e) { switch (e.status) {
    case "loading": return e.extRequest.reload === 0 ? "loading" : "reloading";
    case "resolved": return kc(e.stream()) ? "resolved" : "error";
    default: return e.status;
} }
function kc(e) { return e.error === void 0; }
function xc(e) { return NP(e) ? e : new ch(e); }
function NP(e) { return e instanceof Error || typeof e == "object" && typeof e.name == "string" && typeof e.message == "string"; }
var Vi = class extends Error {
    constructor(t) { super(t.message, { cause: t }); }
}, ch = class extends Error {
    constructor(t) { super(String(t), { cause: t }); }
};
function nM(e) { switch (e.status()) {
    case "idle": throw Un.IDLE;
    case "error": throw new bc(e);
    case "loading":
    case "reloading": throw Un.LOADING;
} return e.value(); }
var _P = { chain: nM }, oM = !1;
function lh() { return oM; }
function qn(e) { oM = e; }
function uh() { return new D(992, !1); }
function Hi(e) { if (e instanceof D && e.code === 992)
    throw e; }
import { Subscription as aL } from "rxjs";
var gh = { JSACTION: "__jsaction", OWNER: "__owner" }, aM = {};
function SP(e) { return e[gh.JSACTION]; }
function rM(e, t) { e[gh.JSACTION] = t; }
function bP(e) { return aM[e]; }
function AP(e, t) { aM[e] = t; }
var M = { CLICK: "click", CLICKMOD: "clickmod", DBLCLICK: "dblclick", FOCUS: "focus", FOCUSIN: "focusin", BLUR: "blur", FOCUSOUT: "focusout", SUBMIT: "submit", KEYDOWN: "keydown", KEYPRESS: "keypress", KEYUP: "keyup", MOUSEOVER: "mouseover", MOUSEOUT: "mouseout", MOUSEENTER: "mouseenter", MOUSELEAVE: "mouseleave", POINTEROVER: "pointerover", POINTEROUT: "pointerout", POINTERENTER: "pointerenter", POINTERLEAVE: "pointerleave", ERROR: "error", LOAD: "load", TOUCHSTART: "touchstart", TOUCHEND: "touchend", TOUCHMOVE: "touchmove", TOGGLE: "toggle" }, RP = [M.MOUSEENTER, M.MOUSELEAVE, "pointerenter", "pointerleave"], kP = [M.CLICK, M.DBLCLICK, M.FOCUSIN, M.FOCUSOUT, M.KEYDOWN, M.KEYUP, M.KEYPRESS, M.MOUSEOVER, M.MOUSEOUT, M.SUBMIT, M.TOUCHSTART, M.TOUCHEND, M.TOUCHMOVE, "touchcancel", "auxclick", "change", "compositionstart", "compositionupdate", "compositionend", "beforeinput", "input", "select", "copy", "cut", "paste", "mousedown", "mouseup", "wheel", "contextmenu", "dragover", "dragenter", "dragleave", "drop", "dragstart", "dragend", "pointerdown", "pointermove", "pointerup", "pointercancel", "pointerover", "pointerout", "gotpointercapture", "lostpointercapture", "ended", "loadedmetadata", "pagehide", "pageshow", "visibilitychange", "beforematch"], cM = [M.FOCUS, M.BLUR, M.ERROR, M.LOAD, M.TOGGLE], Vc = e => cM.indexOf(e) >= 0, xP = kP.concat(cM), lM = e => xP.indexOf(e) >= 0;
function OP(e) { return e === M.MOUSEENTER ? M.MOUSEOVER : e === M.MOUSELEAVE ? M.MOUSEOUT : e === M.POINTERENTER ? M.POINTEROVER : e === M.POINTERLEAVE ? M.POINTEROUT : e; }
function PP(e, t, n, o) { let r = !1; Vc(t) && (r = !0); let i = typeof o == "boolean" ? { capture: r, passive: o } : r; return e.addEventListener(t, n, i), { eventType: t, handler: n, capture: r, passive: o }; }
function LP(e, t) { if (e.removeEventListener) {
    let n = typeof t.passive == "boolean" ? { capture: t.capture } : t.capture;
    e.removeEventListener(t.eventType, t.handler, n);
}
else
    e.detachEvent && e.detachEvent(`on${t.eventType}`, t.handler); }
function FP(e) { e.preventDefault ? e.preventDefault() : e.returnValue = !1; }
var iM = typeof navigator < "u" && /Macintosh/.test(navigator.userAgent);
function jP(e) { return e.which === 2 || e.which == null && e.button === 4; }
function VP(e) { return iM && e.metaKey || !iM && e.ctrlKey || jP(e) || e.shiftKey; }
function HP(e, t, n) { let o = e.relatedTarget; return (e.type === M.MOUSEOVER && t === M.MOUSEENTER || e.type === M.MOUSEOUT && t === M.MOUSELEAVE || e.type === M.POINTEROVER && t === M.POINTERENTER || e.type === M.POINTEROUT && t === M.POINTERLEAVE) && (!o || o !== n && !n.contains(o)); }
function BP(e, t) { let n = {}; for (let o in e) {
    if (o === "srcElement" || o === "target")
        continue;
    let r = o, i = e[r];
    typeof i != "function" && (n[r] = i);
} return e.type === M.MOUSEOVER ? n.type = M.MOUSEENTER : e.type === M.MOUSEOUT ? n.type = M.MOUSELEAVE : e.type === M.POINTEROVER ? n.type = M.POINTERENTER : n.type = M.POINTERLEAVE, n.target = n.srcElement = t, n.bubbles = !1, n._originalEvent = e, n; }
var Fc = class {
    element;
    handlerInfos = [];
    constructor(t) { this.element = t; }
    addEventListener(t, n, o) { this.handlerInfos.push(PP(this.element, t, n(this.element), o)); }
    cleanUp() { for (let t = 0; t < this.handlerInfos.length; t++)
        LP(this.element, this.handlerInfos[t]); this.handlerInfos = []; }
}, $P = { EVENT_ACTION_SEPARATOR: ":" };
function an(e) { return e.eventType; }
function mh(e, t) { e.eventType = t; }
function Pc(e) { return e.event; }
function uM(e, t) { e.event = t; }
function dM(e) { return e.targetElement; }
function fM(e, t) { e.targetElement = t; }
function pM(e) { return e.eic; }
function UP(e, t) { e.eic = t; }
function qP(e) { return e.timeStamp; }
function GP(e, t) { e.timeStamp = t; }
function Lc(e) { return e.eia; }
function hM(e, t, n) { e.eia = [t, n]; }
function dh(e) { e.eia = void 0; }
function Oc(e) { return e[1]; }
function WP(e) { return e.eirp; }
function gM(e, t) { e.eirp = t; }
function mM(e) { return e.eir; }
function vM(e, t) { e.eir = t; }
function yM(e) { return { eventType: e.eventType, event: e.event, targetElement: e.targetElement, eic: e.eic, eia: e.eia, timeStamp: e.timeStamp, eirp: e.eirp, eiack: e.eiack, eir: e.eir }; }
function zP(e, t, n, o, r, i, s, a) { return { eventType: e, event: t, targetElement: n, eic: o, timeStamp: r, eia: i, eirp: s, eiack: a }; }
var fh = class e {
    eventInfo;
    constructor(t) { this.eventInfo = t; }
    getEventType() { return an(this.eventInfo); }
    setEventType(t) { mh(this.eventInfo, t); }
    getEvent() { return Pc(this.eventInfo); }
    setEvent(t) { uM(this.eventInfo, t); }
    getTargetElement() { return dM(this.eventInfo); }
    setTargetElement(t) { fM(this.eventInfo, t); }
    getContainer() { return pM(this.eventInfo); }
    setContainer(t) { UP(this.eventInfo, t); }
    getTimestamp() { return qP(this.eventInfo); }
    setTimestamp(t) { GP(this.eventInfo, t); }
    getAction() { let t = Lc(this.eventInfo); if (t)
        return { name: t[0], element: t[1] }; }
    setAction(t) { if (!t) {
        dh(this.eventInfo);
        return;
    } hM(this.eventInfo, t.name, t.element); }
    getIsReplay() { return WP(this.eventInfo); }
    setIsReplay(t) { gM(this.eventInfo, t); }
    getResolved() { return mM(this.eventInfo); }
    setResolved(t) { vM(this.eventInfo, t); }
    clone() { return new e(yM(this.eventInfo)); }
}, QP = {}, ZP = /\s*;\s*/, YP = M.CLICK, ph = class {
    a11yClickSupport = !1;
    clickModSupport = !0;
    syntheticMouseEventSupport;
    updateEventInfoForA11yClick = void 0;
    preventDefaultForA11yClick = void 0;
    populateClickOnlyAction = void 0;
    constructor({ syntheticMouseEventSupport: t = !1, clickModSupport: n = !0 } = {}) { this.syntheticMouseEventSupport = t, this.clickModSupport = n; }
    resolveEventType(t) { this.clickModSupport && an(t) === M.CLICK && VP(Pc(t)) ? mh(t, M.CLICKMOD) : this.a11yClickSupport && this.updateEventInfoForA11yClick(t); }
    resolveAction(t) { mM(t) || (this.populateAction(t, dM(t)), vM(t, !0)); }
    resolveParentAction(t) { let n = Lc(t), o = n && Oc(n); dh(t); let r = o && this.getParentNode(o); r && this.populateAction(t, r); }
    populateAction(t, n) { let o = n; for (; o && o !== pM(t) && (o.nodeType === Node.ELEMENT_NODE && this.populateActionOnElement(o, t), !Lc(t));)
        o = this.getParentNode(o); let r = Lc(t); if (r && (this.a11yClickSupport && this.preventDefaultForA11yClick(t), this.syntheticMouseEventSupport && (an(t) === M.MOUSEENTER || an(t) === M.MOUSELEAVE || an(t) === M.POINTERENTER || an(t) === M.POINTERLEAVE)))
        if (HP(Pc(t), an(t), Oc(r))) {
            let i = BP(Pc(t), Oc(r));
            uM(t, i), fM(t, Oc(r));
        }
        else
            dh(t); }
    getParentNode(t) { let n = t[gh.OWNER]; if (n)
        return n; let o = t.parentNode; return o?.nodeName === "#document-fragment" ? o?.host ?? null : o; }
    populateActionOnElement(t, n) { let o = this.parseActions(t), r = o[an(n)]; r !== void 0 && hM(n, r, t), this.a11yClickSupport && this.populateClickOnlyAction(t, n, o); }
    parseActions(t) { let n = SP(t); if (!n) {
        let o = t.getAttribute(co.JSACTION);
        if (!o)
            n = QP, rM(t, n);
        else {
            if (n = bP(o), !n) {
                n = {};
                let r = o.split(ZP);
                for (let i = 0; i < r.length; i++) {
                    let s = r[i];
                    if (!s)
                        continue;
                    let a = s.indexOf($P.EVENT_ACTION_SEPARATOR), c = a !== -1, l = c ? s.substr(0, a).trim() : YP, u = c ? s.substr(a + 1).trim() : s;
                    n[l] = u;
                }
                AP(o, n);
            }
            rM(t, n);
        }
    } return n; }
    addA11yClickSupport(t, n, o) { this.a11yClickSupport = !0, this.updateEventInfoForA11yClick = t, this.preventDefaultForA11yClick = n, this.populateClickOnlyAction = o; }
}, EM = (function (e) { return e[e.I_AM_THE_JSACTION_FRAMEWORK = 0] = "I_AM_THE_JSACTION_FRAMEWORK", e; })(EM || {}), hh = class {
    dispatchDelegate;
    actionResolver;
    eventReplayer;
    eventReplayScheduled = !1;
    replayEventInfoWrappers = [];
    constructor(t, { actionResolver: n, eventReplayer: o } = {}) { this.dispatchDelegate = t, this.actionResolver = n, this.eventReplayer = o; }
    dispatch(t) { let n = new fh(t); this.actionResolver?.resolveEventType(t), this.actionResolver?.resolveAction(t); let o = n.getAction(); if (o && KP(o.element, n) && FP(n.getEvent()), this.eventReplayer && n.getIsReplay()) {
        this.scheduleEventInfoWrapperReplay(n);
        return;
    } this.dispatchDelegate(n); }
    scheduleEventInfoWrapperReplay(t) { this.replayEventInfoWrappers.push(t), !this.eventReplayScheduled && (this.eventReplayScheduled = !0, Promise.resolve().then(() => { this.eventReplayScheduled = !1, this.eventReplayer(this.replayEventInfoWrappers); })); }
};
function KP(e, t) { return e.tagName === "A" && (t.getEventType() === M.CLICK || t.getEventType() === M.CLICKMOD); }
var IM = Symbol.for("propagationStopped"), vh = { REPLAY: 101 };
var JP = "`preventDefault` called during event replay.";
var XP = "`composedPath` called during event replay.", jc = class {
    dispatchDelegate;
    clickModSupport;
    actionResolver;
    dispatcher;
    constructor(t, n = !0) { this.dispatchDelegate = t, this.clickModSupport = n, this.actionResolver = new ph({ clickModSupport: n }), this.dispatcher = new hh(o => { this.dispatchToDelegate(o); }, { actionResolver: this.actionResolver }); }
    dispatch(t) { this.dispatcher.dispatch(t); }
    dispatchToDelegate(t) { for (t.getIsReplay() && nL(t), eL(t); t.getAction();) {
        if (oL(t), Vc(t.getEventType()) && t.getAction().element !== t.getTargetElement() || (this.dispatchDelegate(t.getEvent(), t.getAction().name), tL(t)))
            return;
        this.actionResolver.resolveParentAction(t.eventInfo);
    } }
};
function eL(e) { let t = e.getEvent(), n = e.getEvent().stopPropagation.bind(t), o = () => { t[IM] = !0, n(); }; Gn(t, "stopPropagation", o), Gn(t, "stopImmediatePropagation", o); }
function tL(e) { return !!e.getEvent()[IM]; }
function nL(e) { let t = e.getEvent(), n = e.getTargetElement(), o = t.preventDefault.bind(t); Gn(t, "target", n), Gn(t, "eventPhase", vh.REPLAY), Gn(t, "preventDefault", () => { throw o(), new Error(JP + ""); }), Gn(t, "composedPath", () => { throw new Error(XP + ""); }); }
function oL(e) { let t = e.getEvent(), n = e.getAction()?.element; n && Gn(t, "currentTarget", n, { configurable: !0 }); }
function Gn(e, t, n, { configurable: o = !1 } = {}) { Object.defineProperty(e, t, { value: n, configurable: o }); }
function DM(e, t) { e.ecrd(n => { t.dispatch(n); }, EM.I_AM_THE_JSACTION_FRAMEWORK); }
function rL(e) { return e?.q ?? []; }
function iL(e) { e && (sM(e.c, e.et, e.h), sM(e.c, e.etc, e.h, !0)); }
function sM(e, t, n, o) { for (let r = 0; r < t.length; r++)
    e.removeEventListener(t[r], n, o); }
var sL = !1, TM = (() => { class e {
    static MOUSE_SPECIAL_SUPPORT = sL;
    containerManager;
    eventHandlers = {};
    browserEventTypeToExtraEventTypes = {};
    dispatcher = null;
    queuedEventInfos = [];
    constructor(n) { this.containerManager = n; }
    handleEvent(n, o, r) { let i = zP(n, o, o.target, r, Date.now()); this.handleEventInfo(i); }
    handleEventInfo(n) { if (!this.dispatcher) {
        gM(n, !0), this.queuedEventInfos?.push(n);
        return;
    } this.dispatcher(n); }
    addEvent(n, o, r) { if (n in this.eventHandlers || !this.containerManager || !e.MOUSE_SPECIAL_SUPPORT && RP.indexOf(n) >= 0)
        return; let i = (a, c, l) => { this.handleEvent(a, c, l); }; this.eventHandlers[n] = i; let s = OP(o || n); if (s !== n) {
        let a = this.browserEventTypeToExtraEventTypes[s] || [];
        a.push(n), this.browserEventTypeToExtraEventTypes[s] = a;
    } this.containerManager.addEventListener(s, a => c => { i(n, c, a); }, r); }
    replayEarlyEvents(n = window._ejsa) { n && (this.replayEarlyEventInfos(n.q), iL(n), delete window._ejsa); }
    replayEarlyEventInfos(n) { for (let o = 0; o < n.length; o++) {
        let r = n[o], i = this.getEventTypesForBrowserEventType(r.eventType);
        for (let s = 0; s < i.length; s++) {
            let a = yM(r);
            mh(a, i[s]), this.handleEventInfo(a);
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
function CM(e, t = window) { return rL(t._ejsas?.[e]); }
function yh(e, t = window) { t._ejsas && (t._ejsas[e] = void 0); }
import "@angular/core/primitives/signals";
import "@angular/core/primitives/di";
import "rxjs/operators";
typeof globalThis.ngServerMode > "u" && (globalThis.ngServerMode = typeof window > "u");
var Wc = Symbol("InputSignalNode#UNSET"), UM = Ie(q({}, Jc), { transformFn: void 0, applyValueToInputSignal(e, t) { Kc(e, t); } }), e0 = Symbol();
function qM(e, t) { let n = Object.create(UM); n.value = e, n.transformFn = t?.transform; function o() { if (Gi(n), n.value === Wc) {
    let r = null;
    throw new D(-950, r);
} return n.value; } return o[ae] = n, o; }
var cL = (function (e) { return e.Angular = "angular", e.ACX = "acx", e.Wiz = "wiz", e; })(cL || {}), MM = class {
    attributeName;
    constructor(t) { this.attributeName = t; }
    __NG_ELEMENT_ID__ = () => _a(this.attributeName);
    toString() { return `HostAttributeToken ${this.attributeName}`; }
}, t0 = (() => { let e = new C(""); return e.__NG_ELEMENT_ID__ = t => { let n = _(); if (n === null)
    throw new D(-204, !1); if (n.type & 2)
    return n.value; if (t & 8)
    return null; throw new D(-204, !1); }, e; })();
function lL(e) { return uL(e) ? e.default : e; }
function uL(e) { return e && typeof e == "object" && "default" in e; }
function n0(e, t) { let n = E(oe), o = null, r = () => (o || (o = e()), o); return t?.prefetch && t.prefetch().then(() => r()), () => r().then(i => n.get(lL(i))); }
function o0(e) { let t = E(Sa), { promise: n, resolve: o } = oo(); return t.requestOnIdle(() => o(), e), n; }
var Wn = (function (e) { return e[e.Directive = 0] = "Directive", e[e.Component = 1] = "Component", e[e.Injectable = 2] = "Injectable", e[e.Pipe = 3] = "Pipe", e[e.NgModule = 4] = "NgModule", e[e.Service = 5] = "Service", e; })(Wn || {});
function r0(e) { return new ji; }
function wM(e, t) { return qM(e, t); }
function dL(e) { return qM(Wc, e); }
var i0 = (wM.required = dL, wM);
function GM(e, t) { let n = Object.create(UM), o = new ji; n.value = e; function r() { return Gi(n), NM(n.value), n.value; } return r[ae] = n, r.asReadonly = ro.bind(r), r.set = i => { n.equal(n.value, i) || (Kc(n, i), o.emit(i)); }, r.update = i => { NM(n.value), r.set(i(n.value)); }, r.subscribe = o.subscribe.bind(o), r.destroyRef = o.destroyRef, r; }
function NM(e) { if (e === Wc)
    throw new D(952, !1); }
function _M(e, t) { return GM(e, t); }
function fL(e) { return GM(Wc, e); }
var s0 = (_M.required = fL, _M);
function SM(e, t) { return Kf(t); }
function pL(e, t) { return Jf(t); }
var a0 = (SM.required = pL, SM);
function c0(e, t) { return Xf(t); }
function bM(e, t) { return Kf(t); }
function hL(e, t) { return Jf(t); }
var l0 = (bM.required = hL, bM);
function u0(e, t) { return Xf(t); }
function d0(...e) { return e.reduce((t, n) => Object.assign(t, n, { providers: [...t.providers, ...n.providers] }), { providers: [] }); }
var WM = !0, Yo = class {
}, f0 = Ot("ContentChildren", (e, t = {}) => q({ selector: e, first: !1, isViewQuery: !1, descendants: !1, emitDistinctChangesOnly: WM }, t), Yo), p0 = Ot("ContentChild", (e, t = {}) => q({ selector: e, first: !0, isViewQuery: !1, descendants: !0 }, t), Yo), h0 = Ot("ViewChildren", (e, t = {}) => q({ selector: e, first: !1, isViewQuery: !0, descendants: !0, emitDistinctChangesOnly: WM }, t), Yo), g0 = Ot("ViewChild", (e, t) => q({ selector: e, first: !0, isViewQuery: !0, descendants: !0 }, t), Yo), m0 = (() => { class e {
    constructor(n) { }
    static \u0275fac = function (o) { return new (o || e)(he(He)); };
    static \u0275mod = np({ type: e });
    static \u0275inj = ur({});
} return e; })(), v0 = new C("", { providedIn: "platform", factory: () => null }), y0 = new C("", { providedIn: "platform", factory: () => null }), E0 = new C("", { providedIn: "platform", factory: () => null }), Hc = new WeakSet, AM = "";
function RM(e) { return e.get(Pa, Yd); }
function gL() { let e = [{ provide: Pa, useFactory: () => { let t = !0; if (typeof ngServerMode > "u" || !ngServerMode) {
            let n = E(vt);
            t = !!window._ejsas?.[n];
        } return t && te("NgEventReplay"), t; } }]; return (typeof ngServerMode > "u" || !ngServerMode) && e.push({ provide: Ge, useValue: () => { let t = E(He), { injector: n } = t; if (!Hc.has(t)) {
        let o = E(Di);
        if (RM(n)) {
            Uv();
            let r = n.get(vt), i = Bv(r, (s, a, c) => { s.nodeType === Node.ELEMENT_NODE && (Hv(s, a, c), Xd(s, o)); });
            t.onDestroy(i);
        }
    } }, multi: !0 }, { provide: ki, useFactory: () => { let t = E(He), { injector: n } = t; return () => { if (!RM(n) || Hc.has(t))
        return; Hc.add(t); let o = n.get(vt); t.onDestroy(() => { Hc.delete(t), typeof ngServerMode < "u" && !ngServerMode && yh(o); }), t.whenStable().then(() => { if (t.destroyed)
        return; let r = n.get(tf); mL(r, n); let i = n.get(Di); i.get(AM)?.forEach(ef), i.delete(AM); let s = r.instance; Ti(n) ? t.onDestroy(() => s.cleanUp()) : s.cleanUp(); }); }; }, multi: !0 }), e; }
var mL = (e, t) => { let n = t.get(vt), o = window._ejsas[n], r = e.instance = new TM(new Fc(o.c)); for (let a of o.et)
    r.addEvent(a); for (let a of o.etc)
    r.addEvent(a); let i = CM(n); r.replayEarlyEventInfos(i), yh(n); let s = new jc(a => { yL(t, a, a.currentTarget); }); DM(r, s); };
function vL(e, t, n) { let o = new Map, r = t[zt], i = e.cleanup; if (!i || !r)
    return o; for (let s = 0; s < i.length;) {
    let a = i[s++], c = i[s++];
    if (typeof a != "string")
        continue;
    let l = a;
    if (!lM(l))
        continue;
    Vc(l) ? n.capture.add(l) : n.regular.add(l);
    let u = O(t[c]);
    s++;
    let d = i[s++];
    (typeof d == "boolean" || d >= 0) && (o.has(u) ? o.get(u).push(l) : o.set(u, [l]));
} return o; }
function yL(e, t, n) { let o = (n && n.getAttribute(Fo)) ?? ""; /d\d+/.test(o) ? EL(o, e, t, n) : t.eventPhase === vh.REPLAY && nf(t, n); }
function EL(e, t, n, o) { let r = t.get(Lv); r.push({ event: n, currentTarget: o }), Ht(t, e, IL(r)); }
function IL(e) { return t => { let n = new Set(t), o = []; for (let { event: r, currentTarget: i } of e) {
    let s = i.getAttribute(Fo);
    n.has(s) ? nf(r, i) : o.push({ event: r, currentTarget: i });
} e.length = 0, e.push(...o); }; }
var kM = !1, xM = !1, DL = 1e4;
function TL() { kM || (kM = !0, Qv(), OD(), MT(), PD(), xI(), oI(), kE(), Zy()); }
function CL() { xM || (xM = !0, UD(), CE(), SE()); }
function ML(e) { return e.whenStable(); }
var I0 = "ngcm";
function D0() { let e = [{ provide: Vn, useFactory: () => { let t = !0; return (typeof ngServerMode > "u" || !ngServerMode) && (t = !!E(St, { optional: !0 })?.get(La, null)), t && te("NgHydration"), t; } }, { provide: Ge, useValue: () => { if (Hf(!1), typeof ngServerMode < "u" && ngServerMode)
            return; let t = E(Nt); E(Vn) && (ny(t), TL()); }, multi: !0 }]; return (typeof ngServerMode > "u" || !ngServerMode) && e.push({ provide: Qd, useFactory: () => E(Vn) }, { provide: ki, useFactory: () => { let t = E(Ue); if (E(Vn)) {
        let n = E(He);
        return () => { ML(n).then(() => { n.destroyed || (Bf(n), t.notify(7)); }); };
    } return () => { }; }, multi: !0 }), Le(e); }
function T0() { return [{ provide: Zd, useFactory: () => E(Vn) }, { provide: Ge, useValue: () => { E(Vn) && (CL(), Hf(!0), te("NgI18nHydration")); }, multi: !0 }]; }
function C0() { let e = [gL(), { provide: Kd, useValue: !0 }, { provide: Lt, useFactory: rC }]; return (typeof ngServerMode > "u" || !ngServerMode) && e.push({ provide: ki, useFactory: () => { let t = E(oe), n = E(Nt); return () => { iC(t, n); }; }, multi: !0 }), e; }
var OM = DL - 1e3, Dh = class {
    openTasks = new Map;
    add(t) { this.openTasks.set(t, new Error("Task stack tracking error")); }
    remove(t) { this.openTasks.delete(t); }
};
function M0() { let e = new Dh, { openTasks: t } = e; return Le([{ provide: nu, useValue: e }, TI(() => { console.warn("Stability debugging utility was provided in production mode. This will cause debug code to be included in production bundles. If this is intentional because you are debugging stability issues in a production environment, you can ignore this warning."); let n = E(G), o = E(He), r = null; typeof Zone < "u" && n.run(() => { r = Zone.current.get("TaskTrackingZone"); }), n.runOutsideAngular(() => { let i = setTimeout(() => { if (console.debug(`---- Application did not stabilize within ${OM / 1e3} seconds ----`), typeof Zone < "u" && !r && console.info('Zone.js is present but no TaskTrackingZone found. To enable better debugging of tasks in the Angular Zone, import "zone.js/plugins/task-tracking" in your application.'), r?.macroTasks?.length) {
        console.group("Macrotasks keeping Angular Zone unstable:");
        for (let s of r?.macroTasks ?? [])
            console.debug(s.creationLocation.stack);
        console.groupEnd();
    } console.group("PendingTasks keeping application unstable:"); for (let s of t.values())
        console.debug(s.stack); console.groupEnd(); }, OM); o.whenStable().then(() => { clearTimeout(i); }); }); })]); }
var Bc = class {
    supports(t) { return oi(t); }
    create(t) { return new Th(t); }
}, wL = (e, t) => t, Th = class {
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
    constructor(t) { this._trackByFn = t || wL; }
    forEachItem(t) { let n; for (n = this._itHead; n !== null; n = n._next)
        t(n); }
    forEachOperation(t) { let n = this._itHead, o = this._removalsHead, r = 0, i = null; for (; n || o;) {
        let s = !o || n && n.currentIndex < PM(o, r, i) ? n : o, a = PM(s, r, i), c = s.currentIndex;
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
        r = 0, FE(t, a => { s = this._trackByFn(r, a), n === null || !Object.is(n.trackById, s) ? (n = this._mismatch(n, a, s, r), o = !0) : (o && (n = this._verifyReinsertion(n, a, s, r)), Object.is(n.item, a) || this._addIdentityChange(n, a)), n = n._next, r++; }), this.length = r; return this._truncate(n), this.collection = t, this.isDirty; }
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
    _mismatch(t, n, o, r) { let i; return t === null ? i = this._itTail : (i = t._prev, this._remove(t)), t = this._unlinkedRecords === null ? null : this._unlinkedRecords.get(o, null), t !== null ? (Object.is(t.item, n) || this._addIdentityChange(t, n), this._reinsertAfter(t, i, r)) : (t = this._linkedRecords === null ? null : this._linkedRecords.get(o, r), t !== null ? (Object.is(t.item, n) || this._addIdentityChange(t, n), this._moveAfter(t, i, r)) : t = this._addAfter(new Ch(n, o), i, r)), t; }
    _verifyReinsertion(t, n, o, r) { let i = this._unlinkedRecords === null ? null : this._unlinkedRecords.get(o, null); return i !== null ? t = this._reinsertAfter(i, t._prev, r) : t.currentIndex != r && (t.currentIndex = r, this._addToMoves(t, r)), t; }
    _truncate(t) { for (; t !== null;) {
        let n = t._next;
        this._addToRemovals(this._unlink(t)), t = n;
    } this._unlinkedRecords !== null && this._unlinkedRecords.clear(), this._additionsTail !== null && (this._additionsTail._nextAdded = null), this._movesTail !== null && (this._movesTail._nextMoved = null), this._itTail !== null && (this._itTail._next = null), this._removalsTail !== null && (this._removalsTail._nextRemoved = null), this._identityChangesTail !== null && (this._identityChangesTail._nextIdentityChange = null); }
    _reinsertAfter(t, n, o) { this._unlinkedRecords !== null && this._unlinkedRecords.remove(t); let r = t._prevRemoved, i = t._nextRemoved; return r === null ? this._removalsHead = i : r._nextRemoved = i, i === null ? this._removalsTail = r : i._prevRemoved = r, this._insertAfter(t, n, o), this._addToMoves(t, o), t; }
    _moveAfter(t, n, o) { return this._unlink(t), this._insertAfter(t, n, o), this._addToMoves(t, o), t; }
    _addAfter(t, n, o) { return this._insertAfter(t, n, o), this._additionsTail === null ? this._additionsTail = this._additionsHead = t : this._additionsTail = this._additionsTail._nextAdded = t, t; }
    _insertAfter(t, n, o) { let r = n === null ? this._itHead : n._next; return t._next = r, t._prev = n, r === null ? this._itTail = t : r._prev = t, n === null ? this._itHead = t : n._next = t, this._linkedRecords === null && (this._linkedRecords = new $c), this._linkedRecords.put(t), t.currentIndex = o, t; }
    _remove(t) { return this._addToRemovals(this._unlink(t)); }
    _unlink(t) { this._linkedRecords !== null && this._linkedRecords.remove(t); let n = t._prev, o = t._next; return n === null ? this._itHead = o : n._next = o, o === null ? this._itTail = n : o._prev = n, t; }
    _addToMoves(t, n) { return t.previousIndex === n || (this._movesTail === null ? this._movesTail = this._movesHead = t : this._movesTail = this._movesTail._nextMoved = t), t; }
    _addToRemovals(t) { return this._unlinkedRecords === null && (this._unlinkedRecords = new $c), this._unlinkedRecords.put(t), t.currentIndex = null, t._nextRemoved = null, this._removalsTail === null ? (this._removalsTail = this._removalsHead = t, t._prevRemoved = null) : (t._prevRemoved = this._removalsTail, this._removalsTail = this._removalsTail._nextRemoved = t), t; }
    _addIdentityChange(t, n) { return t.item = n, this._identityChangesTail === null ? this._identityChangesTail = this._identityChangesHead = t : this._identityChangesTail = this._identityChangesTail._nextIdentityChange = t, t; }
}, Ch = class {
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
}, Mh = class {
    _head = null;
    _tail = null;
    add(t) { this._head === null ? (this._head = this._tail = t, t._nextDup = null, t._prevDup = null) : (this._tail._nextDup = t, t._prevDup = this._tail, t._nextDup = null, this._tail = t); }
    get(t, n) { let o; for (o = this._head; o !== null; o = o._nextDup)
        if ((n === null || n <= o.currentIndex) && Object.is(o.trackById, t))
            return o; return null; }
    remove(t) { let n = t._prevDup, o = t._nextDup; return n === null ? this._head = o : n._nextDup = o, o === null ? this._tail = n : o._prevDup = n, this._head === null; }
}, $c = class {
    map = new Map;
    put(t) { let n = t.trackById, o = this.map.get(n); o || (o = new Mh, this.map.set(n, o)), o.add(t); }
    get(t, n) { let o = t, r = this.map.get(o); return r ? r.get(t, n) : null; }
    remove(t) { let n = t.trackById; return this.map.get(n).remove(t) && this.map.delete(n), t; }
    get isEmpty() { return this.map.size === 0; }
    clear() { this.map.clear(); }
};
function PM(e, t, n) { let o = e.previousIndex; if (o === null)
    return o; let r = 0; return n && o < n.length && (r = n[o]), o + t + r; }
var Uc = class {
    supports(t) { return t instanceof Map || hc(t); }
    create() { return new wh; }
}, wh = class {
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
    else if (!(t instanceof Map || hc(t)))
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
    } let o = new Nh(t); return this._records.set(t, o), o.currentValue = n, this._addToAdditions(o), o; }
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
}, Nh = class {
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
function LM() { return new zM([new Bc]); }
var zM = (() => { class e {
    factories;
    static \u0275prov = Y({ token: e, providedIn: "root", factory: LM });
    constructor(n) { this.factories = n; }
    static create(n, o) { if (o != null) {
        let r = o.factories.slice();
        n = n.concat(r);
    } return new e(n); }
    static extend(n) { return { provide: e, useFactory: () => { let o = E(e, { optional: !0, skipSelf: !0 }); return e.create(n, o || LM()); } }; }
    find(n) { let o = this.factories.find(r => r.supports(n)); if (o != null)
        return o; throw new D(901, !1); }
} return e; })();
function FM() { return new QM([new Uc]); }
var QM = (() => { class e {
    static \u0275prov = Y({ token: e, providedIn: "root", factory: FM });
    factories;
    constructor(n) { this.factories = n; }
    static create(n, o) { if (o) {
        let r = o.factories.slice();
        n = n.concat(r);
    } return new e(n); }
    static extend(n) { return { provide: e, useFactory: () => { let o = E(e, { optional: !0, skipSelf: !0 }); return e.create(n, o || FM()); } }; }
    find(n) { let o = this.factories.find(r => r.supports(n)); if (o)
        return o; throw new D(901, !1); }
} return e; })(), NL = (() => { class e {
    static __NG_ELEMENT_ID__ = _L;
} return e; })();
function _L(e) { return SL(_(), g(), (e & 16) === 16); }
function SL(e, t, n) { if (Ce(e) && !n) {
    let o = me(e.index, t);
    return new rn(o, o);
}
else if (e.type & 175) {
    let o = t[re];
    return new rn(o, t);
} return null; }
var bL = [new Uc], AL = [new Bc], w0 = new zM(AL), N0 = new QM(bL);
function _0(e) { return Le([]); }
var RL = (() => { class e {
    zone = E(G);
    changeDetectionScheduler = E(Ue);
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
    static \u0275prov = Pt({ token: e, factory: e.\u0275fac });
} return e; })(), kL = new C("", { factory: () => !1 });
function xL({ ngZoneFactory: e, scheduleInRootZone: t }) { return e ??= () => new G(Ie(q({}, ZM()), { scheduleInRootZone: t })), [{ provide: so, useValue: !1 }, { provide: G, useFactory: e }, { provide: Ge, multi: !0, useFactory: () => { let n = E(RL, { optional: !0 }); return () => n.initialize(); } }, { provide: Ge, multi: !0, useFactory: () => { let n = E(OL); return () => { n.initialize(); }; } }, { provide: ws, useValue: t ?? tu }]; }
function S0(e) { let t = e?.scheduleInRootZone, n = xL({ ngZoneFactory: () => { let o = ZM(e); return o.scheduleInRootZone = t, o.shouldCoalesceEventChangeDetection && te("NgZone_CoalesceEvent"), new G(o); }, scheduleInRootZone: t }); return Le([{ provide: kL, useValue: !0 }, n]); }
function ZM(e) { return { enableLongStackTrace: !1, shouldCoalesceEventChangeDetection: e?.eventCoalescing ?? !1, shouldCoalesceRunChangeDetection: e?.runCoalescing ?? !1 }; }
var OL = (() => { class e {
    subscription = new aL;
    initialized = !1;
    zone = E(G);
    pendingTasks = E(gt);
    initialize() { if (this.initialized)
        return; this.initialized = !0; let n = null; !this.zone.isStable && !this.zone.hasPendingMacrotasks && !this.zone.hasPendingMicrotasks && (n = this.pendingTasks.add()), this.zone.runOutsideAngular(() => { this.subscription.add(this.zone.onStable.subscribe(() => { G.assertNotInAngularZone(), queueMicrotask(() => { n !== null && !this.zone.hasPendingMacrotasks && !this.zone.hasPendingMicrotasks && (this.pendingTasks.remove(n), n = null); }); })); }), this.subscription.add(this.zone.onUnstable.subscribe(() => { G.assertInAngularZone(), n ??= this.pendingTasks.add(); })); }
    ngOnDestroy() { this.subscription.unsubscribe(); }
    static \u0275fac = function (o) { return new (o || e); };
    static \u0275prov = Pt({ token: e, factory: e.\u0275fac });
} return e; })();
function PL(e, t, n) { let o = new _o(n); return Promise.resolve(o); }
function jM(e) { for (let t = e.length - 1; t >= 0; t--)
    if (e[t] !== void 0)
        return e[t]; }
var qc = new C(""), LL = new C("");
function Bi(e) { return !e.moduleRef; }
function YM(e) { let t = Bi(e) ? e.r3Injector : e.moduleRef.injector, n = t.get(G); return n.run(() => { Bi(e) ? e.r3Injector.resolveInjectorInitializers() : e.moduleRef.resolveInjectorInitializers(); let o = t.get(_t), r; if (n.runOutsideAngular(() => { r = n.onError.subscribe({ next: o }); }), Bi(e)) {
    let i = () => t.destroy(), s = e.platformInjector.get(qc);
    s.add(i), t.onDestroy(() => { r.unsubscribe(), s.delete(i); });
}
else {
    let i = () => e.moduleRef.destroy(), s = e.platformInjector.get(qc);
    s.add(i), e.moduleRef.onDestroy(() => { jr(e.allPlatformModules, e.moduleRef), r.unsubscribe(), s.delete(i); });
} return jL(o, n, () => { let i = t.get(gt), s = i.add(), a = t.get(ip); return a.runInitializers(), a.donePromise.then(() => { let c = t.get(ih, Pi); if (BD(c || Pi), !t.get(LL, !0))
    return Bi(e) ? t.get(He) : (e.allPlatformModules.push(e.moduleRef), e.moduleRef); if (Bi(e)) {
    let u = t.get(He);
    return e.rootComponent !== void 0 && u.bootstrap(e.rootComponent), u;
}
else
    return KM?.(e.moduleRef, e.allPlatformModules), e.moduleRef; }).finally(() => { i.remove(s); }); }); }); }
var KM;
function VM() { KM = FL; }
function FL(e, t) { let n = e.injector.get(He); if (e._bootstrapComponents.length > 0)
    e._bootstrapComponents.forEach(o => n.bootstrap(o));
else if (e.instance.ngDoBootstrap)
    e.instance.ngDoBootstrap(n);
else
    throw new D(-403, !1); t.push(e); }
function jL(e, t, n) { try {
    let o = n();
    return ep(o) ? o.catch(r => { throw t.runOutsideAngular(() => e(r)), r; }) : o;
}
catch (o) {
    throw t.runOutsideAngular(() => e(o)), o;
} }
var JM = (() => { class e {
    _injector;
    _modules = [];
    _destroyListeners = [];
    _destroyed = !1;
    constructor(n) { this._injector = n; }
    bootstrapModuleFactory(n, o) { let r = [Sc(), ...o?.applicationProviders ?? [], su], i = pI(n.moduleType, this.injector, r); return VM(), YM({ moduleRef: i, allPlatformModules: this._modules, platformInjector: this.injector }); }
    bootstrapModule(n, o = []) { let r = mp({}, o); return VM(), PL(this.injector, r, n).then(i => this.bootstrapModuleFactory(i, r)); }
    onDestroy(n) { this._destroyListeners.push(n); }
    get injector() { return this._injector; }
    destroy() { if (this._destroyed)
        throw new D(404, !1); this._modules.slice().forEach(o => o.destroy()), this._destroyListeners.forEach(o => o()); let n = this._injector.get(qc, null); n && (n.forEach(o => o()), n.clear()), this._destroyed = !0; }
    get destroyed() { return this._destroyed; }
    static \u0275fac = function (o) { return new (o || e)(he(oe)); };
    static \u0275prov = Y({ token: e, factory: e.\u0275fac, providedIn: "platform" });
} return e; })();
function XM(e) { let t = WI(e); if (t?.type === "null")
    return { name: "Null Injector", type: "null", providers: [], children: [] }; let n = []; if ((t?.type === "element" || t?.type === "environment") && (n = GI(e).map(o => ({ token: o.token, value: e.get(o.token, null, { optional: !0, self: !0 }) }))), t?.type === "element") {
    let o = fi(e), r = o ? o.providerIndexes >> 20 : 0, i = n.slice(0, r), s = n.slice(r);
    return { name: e.constructor.name, type: "element", providers: s, viewProviders: i, children: [], hostElement: t.source };
} return { name: t?.source ?? e.constructor.name ?? "Unknown Injector", type: "environment", providers: n, children: [] }; }
var b0 = { name: "angular:di_graph", description: "\nExposes the Angular Dependency Injection (DI) graph of the application.\n\nThis tool extracts both the element injector tree (associated with DOM elements and components)\nand the environment injector tree (associated with modules and standalone application roots).\nIt captures the relationship structure and the providers resolved at each level.\n\nReturns:\n- `elementInjectorRoots`: An array of root element injectors (one for each Angular application\n  root found). Each node forms a tree hierarchy:\n  - `name`: The constructor name of this injector.\n  - `type`: 'element'.\n  - `providers`: Array of providers configured on this injector.\n    - `token`: The DI token.\n    - `value`: The resolved value of that provider if it was instantiated.\n  - `hostElement`: The DOM element that this injector is associated with.\n  - `children`: Array of child element injectors.\n- `environmentInjectorRoot`: The root environment injector. It forms a tree hierarchy of nodes\n  representing all environment injectors:\n  - `name`: The identifier for the environment injector.\n  - `type`: 'environment' or 'null'.\n  - `providers`: Array of providers configured on this injector.\n    - `token`: The DI token.\n    - `value`: The resolved value of that provider if it was instantiated.\n  - `children`: Array of child environment injectors.\n  ".trim(), inputSchema: { type: "object", properties: {} }, execute: () => Se(null, null, function* () { let e = Array.from(document.querySelectorAll("[ng-version]")); if (e.length === 0)
        throw new Error("Could not find Angular root element ([ng-version]) on the page."); return VL(e); }) };
function VL(e) { let t = e.map(n => { let o = we(n); if (!o?.lView)
    throw new Error(`Could not find an \`LView\` for root \`<${n.tagName.toLowerCase()}>\`, is it an Angular component?`); return o.lView; }); return { elementInjectorRoots: t.map(n => HL(n)), environmentInjectorRoot: BL(t) }; }
function HL(e) { if (e[m].type !== 0)
    throw new Error(`Expected a root LView but got type: \`${e[m].type}\`.`); let t = []; for (let [o, r] of Ud(e)) {
    let i = new Me(o, r), s = XM(i);
    for (; t.length > 0;) {
        let [a, c, l] = t[t.length - 1], u = ew(o, a), d = $L(r, c, a);
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
function BL(e) { let t = new Map, n; function o(r) { let i = t.get(r); if (i)
    return i; let s = XM(r); t.set(r, s); let a = UL(r); if (a)
    o(a).children.push(s);
else if (!n)
    n = s;
else if (n !== s)
    throw new Error("Expected only one root environment injector, but found multiple.", { cause: { firstRoot: n, secondRoot: s } }); return s; } for (let r of e)
    for (let [, i] of Ud(r))
        o(i[x]); if (!n)
    throw new Error("Expected a root environment injector but did not find one."); return n; }
function ew(e, t) { let n = e; for (; n;) {
    if (n === t)
        return !0;
    n = n.parent;
} return !1; }
function $L(e, t, n) { let o = e, r = null; for (; o && o !== t;)
    r = o[ce], o = et(o); return o === t && r !== null && ew(r, n); }
function UL(e) { if (e instanceof tn)
    return e.parentInjector; if (e instanceof Xe)
    return e.parent; if (e instanceof Ct)
    return; throw new Error(`Unknown injector type: "${e.constructor.name}".`); }
var A0 = { name: "angular:signal_graph", description: "\nExposes the Angular signal dependency graph for a given DOM element.\n\nThis tool extracts the reactive dependency graph (signals, computeds, and effects) that\nare transitive dependencies of the effects of that element. It will include signals\nauthored in other components/services and depended upon by the target component, but\nwill *not* include signals only used in descendant components effects.\n\nParams:\n- `target`: The element to get the signal graph for. Must be the host element of an\n  Angular component.\n\nReturns:\n- `nodes`: An array of reactive nodes discovered in the context. Each node contains:\n  - `kind`: The type of reactive node ('signal', 'computed', 'effect', or 'template'\n    for component template effects).\n  - `value`: The current evaluated value of the node (if applicable).\n  - `label`: The symbol name of the associated signal if available (ex.\n    `const foo = signal(0);` has `label: 'foo'`).\n  - `epoch`: The internal version number of the node's value.\n- `edges`: An array of dependency links representing which nodes read from which other\n  nodes.\n  - `consumer`: The index in the `nodes` array of the node that depends on the value.\n  - `producer`: The index in the `nodes` array of the node that provides the value.\n\nExample: An edge with `{consumer: 2, producer: 0}` means that `nodes[2]` (e.g. an\n`effect`) reads the value of `nodes[0]` (e.g. a `signal`).\n  ".trim(), inputSchema: { type: "object", properties: { target: { type: "object", description: "The element to get the signal graph for.", "x-mcp-type": "HTMLElement" } }, required: ["target"] }, execute: t => Se(null, [t], function* ({ target: e }) { if (!(e instanceof HTMLElement))
        throw new Error('Invalid input: "target" must be an HTMLElement.'); let n = qd(e); if (n instanceof Ct)
        throw new Error('Invalid input: "target" is not the host element of an Angular component.'); let o = QI(n); return { nodes: o.nodes.map(a => { var c = a, { id: r, debuggableFn: i } = c, s = xh(c, ["id", "debuggableFn"]); return s; }), edges: o.edges }; }) };
var Zo = null;
function qL(e) { if (zc())
    throw new D(400, !1); gp(), Zo = typeof ngServerMode > "u" || !ngServerMode ? e : null; let t = e.get(JM); return nw(e), t; }
function GL(e, t, n = []) { let o = `Platform: ${t}`, r = new C(o); return (i = []) => { let s = zc(); if (!s) {
    let a = [...n, ...i, { provide: r, useValue: !0 }];
    s = e?.(a) ?? qL(tw(a, o));
} return typeof ngServerMode < "u" && ngServerMode ? s : WL(r); }; }
function tw(e = [], t) { return oe.create({ name: t, providers: [{ provide: Ml, useValue: "platform" }, { provide: qc, useValue: new Set([() => Zo = null]) }, ...e] }); }
function WL(e) { let t = zc(); if (!t)
    throw new D(-401, !1); return t; }
function zc() { return typeof ngServerMode < "u" && ngServerMode ? null : Zo?.get(JM) ?? null; }
function R0() { zc()?.destroy(); }
function zL(e = []) { if (Zo)
    return Zo; let t = tw(e); return (typeof ngServerMode > "u" || !ngServerMode) && (Zo = t), gp(), nw(t), t; }
function k0(e) { return { provide: au, useValue: e, multi: !0 }; }
function nw(e) { let t = e.get(au, null); Ir(e, () => { t?.forEach(n => n()); }); }
function x0(e) { let { rootComponent: t, appProviders: n, platformProviders: o, platformRef: r } = e; if (V(P.BootstrapApplicationStart), typeof ngServerMode < "u" && ngServerMode && !r)
    throw new D(-401, !1); try {
    let i = r?.injector ?? zL(o), s = [Sc(), su, ...n || []], a = new ri({ providers: s, parent: i, debugName: "", runEnvironmentInitializers: !1 });
    return YM({ r3Injector: a.injector, platformInjector: i, rootComponent: t });
}
catch (i) {
    return Promise.reject(i);
}
finally {
    V(P.BootstrapApplicationEnd);
} }
var _h = class {
    views = [];
    indexByContent = new Map;
    add(t) { let n = JSON.stringify(t); if (!this.indexByContent.has(n)) {
        let o = this.views.length;
        return this.views.push(t), this.indexByContent.set(n, o), o;
    } return this.indexByContent.get(n); }
    getAll() { return this.views; }
}, QL = 0;
function ow(e) { return e.ssrId || (e.ssrId = `t${QL++}`), e.ssrId; }
function rw(e, t, n) { let o = []; return Mo(e, t, n, o), o.length; }
function ZL(e) { let t = []; return sc(e, t), t.length; }
function iw(e, t) { let n = e[H]; return n && !n.hasAttribute(jn) ? Gc(n, e, null, t) : null; }
function sw(e, t) { let n = Cr(e[H]), o = iw(n, t); if (o === null)
    return; let r = O(n[H]), i = e[z], s = Gc(r, i, null, t), a = n[N], c = `${o}|${s}`; a.setAttribute(r, yo, c); }
function O0(e, t) { let n = e.injector, o = ME(n), r = Ti(n), i = new _h, s = new Map, a = e._views, c = n.get(Pa, Yd), l = { regular: new Set, capture: new Set }, u = new Map; e.injector.get(vt); for (let p of a) {
    let h = of(p);
    if (h !== null) {
        let v = { serializedViewCollection: i, corruptedTextNodes: s, isI18nHydrationEnabled: o, isIncrementalHydrationEnabled: r, i18nChildren: new Map, eventTypesToReplay: l, shouldReplayEvents: c, deferBlocks: u };
        K(h) ? sw(h, v) : iw(h, v), eF(s, t);
    }
} let d = i.getAll(), f = n.get(St); if (f.set(La, d), u.size > 0) {
    let p = {};
    for (let [h, v] of u.entries())
        p[h] = v;
    f.set(Fa, p);
} return l; }
function YL(e, t, n, o, r) { let i = [], s = ""; for (let a = U; a < e.length; a++) {
    let c = e[a], l, u, d;
    if (lt(c) && (c = c[I], K(c))) {
        u = ZL(c) + 1, sw(c, r);
        let p = Cr(c[H]);
        d = { [ka]: p[m].ssrId, [kt]: u };
    }
    if (!d) {
        let p = c[m];
        p.type === 1 ? (l = p.ssrId, u = 1) : (l = ow(p), u = rw(p, c, p.firstChild)), d = { [ka]: l, [kt]: u };
        let h = !1;
        if (jI(n[m], t)) {
            let v = Ne(n, t), y = pe(n[m], t);
            if (r.isIncrementalHydrationEnabled && y.hydrateTriggers !== null) {
                let T = `d${r.deferBlocks.size}`;
                y.hydrateTriggers.has(7) && (h = !0);
                let R = [];
                sc(e, R);
                let se = { [kt]: R.length, [Ei]: v[Vt] }, Je = KL(y.hydrateTriggers);
                Je.length > 0 && (se[Ii] = Je), o !== null && (se[zd] = o), r.deferBlocks.set(T, se);
                let Be = O(e);
                Be !== void 0 ? Be.nodeType === Node.COMMENT_NODE && HM(Be, T) : HM(Be, T), h || nF(y, R, T, r), o = T, d[Oa] = T;
            }
            d[Ei] = v[Vt];
        }
        if (!h) {
            let v = O(c[H]);
            (c[m].type !== 1 || v === null || !v.hasAttribute(jn)) && Object.assign(d, aw(e[a], o, r));
        }
    }
    let f = JSON.stringify(d);
    if (i.length > 0 && f === s) {
        let p = i[i.length - 1];
        p[vi] ??= 1, p[vi]++;
    }
    else
        s = f, i.push(d);
} return i; }
function KL(e) { let t = new Set([0, 1, 2, 5]), n = []; for (let [o, r] of e)
    t.has(o) && (r === null ? n.push(o) : r.type === 5 ? n.push({ trigger: o, delay: r.delay }) : n.push({ trigger: o, intersectionObserverOptions: r.intersectionObserverOptions })); return n; }
function $i(e, t, n, o) { let r = t.index - I; e[yi] ??= {}, e[yi][r] ??= IE(t, n, o); }
function Eh(e, t) { let n = typeof t == "number" ? t : t.index - I; e[Lo] ??= [], e[Lo].includes(n) || e[Lo].push(n); }
function aw(e, t = null, n) { let o = {}, r = e[m], i = wE(r, n), s = n.shouldReplayEvents ? vL(r, e, n.eventTypesToReplay) : null; for (let a = I; a < r.bindingStartIndex; a++) {
    let c = r.data[a], l = a - I, u = NE(e, a, n);
    if (u) {
        o[xa] ??= {}, o[xa][l] = u.caseQueue;
        for (let d of u.disconnectedNodes)
            Eh(o, d);
        for (let d of u.disjointNodes) {
            let f = r.data[d + I];
            $i(o, f, e, i);
        }
        continue;
    }
    if (Na(c) && !jo(c)) {
        if (K(e[a]) && c.tView && (o[Ra] ??= {}, o[Ra][l] = ow(c.tView)), qo(c, e) && tF(c)) {
            Eh(o, c);
            continue;
        }
        if (Array.isArray(c.projection)) {
            for (let d of c.projection)
                if (d)
                    if (!Array.isArray(d))
                        !bl(d) && !Oo(d) && (qo(d, e) ? Eh(o, d) : $i(o, d, e, i));
                    else
                        throw dE(O(e[a]));
        }
        if (JL(o, c, e, i), K(e[a])) {
            let d = e[a][H];
            if (Array.isArray(d)) {
                let f = O(d);
                f.hasAttribute(jn) || Gc(f, d, t, n);
            }
            o[Po] ??= {}, o[Po][l] = YL(e[a], c, e, t, n);
        }
        else if (Array.isArray(e[a]) && !tv(c)) {
            let d = O(e[a][H]);
            d.hasAttribute(jn) || Gc(d, e[a], t, n);
        }
        else if (c.type & 8)
            o[mi] ??= {}, o[mi][l] = rw(r, e, c.child);
        else if (c.type & 144) {
            let d = c.next;
            for (; d !== null && d.type & 144;)
                d = d.next;
            d && !Oo(d) && $i(o, d, e, i);
        }
        else if (c.type & 1) {
            let d = O(e[a]);
            sf(n, d);
        }
        if (s && c.type & 2) {
            let d = O(e[a]);
            s.has(d) && Jd(d, s.get(d), t);
        }
    }
} return o; }
function JL(e, t, n, o) { bl(t) || (t.projectionNext && t.projectionNext !== t.next && !Oo(t.projectionNext) && $i(e, t.projectionNext, n, o), t.prev === null && t.parent !== null && qo(t.parent, n) && !qo(t, n) && $i(e, t, n, o)); }
function XL(e) { let t = e[B]; if (!t?.constructor)
    return !1; let n = W(t.constructor); return n?.encapsulation === Ye.ShadowDom || n?.encapsulation === Ye.ExperimentalIsolatedShadowDom; }
function Gc(e, t, n, o) { let r = t[N]; if (tg(t) && !dc() || XL(t))
    return r.setAttribute(e, jn, ""), null; {
    let i = aw(t, n, o), s = o.serializedViewCollection.add(i);
    return r.setAttribute(e, yo, s.toString()), s;
} }
function HM(e, t) { e.textContent = `ngh=${t}`; }
function eF(e, t) { for (let [n, o] of e)
    n.after(t.createComment(o)); }
function tF(e) { let t = e; for (; t != null;) {
    if (Ce(t))
        return !0;
    t = t.parent;
} return !1; }
function nF(e, t, n, o) { let r = ey(e.hydrateTriggers); for (let i of r)
    o.eventTypesToReplay.regular.add(i); if (r.length > 0) {
    let i = t.filter(s => s.nodeType === Node.ELEMENT_NODE);
    for (let s of i)
        Jd(s, r, n);
} }
var oF = "\u{1F170}\uFE0F", Qc = !1;
function P0(e) { if (!Qc)
    return; let { startLabel: t } = cw(e); performance.mark(t); }
function L0(e) { if (!Qc)
    return; let { startLabel: t, labelName: n, endLabel: o } = cw(e); performance.mark(o), performance.measure(n, t, o), performance.clearMarks(t), performance.clearMarks(o); }
function cw(e) { let t = `${oF}:${e}`; return { labelName: t, startLabel: `start:${t}`, endLabel: `end:${t}` }; }
var BM = !1;
function F0() { if (!BM && (typeof performance > "u" || !performance.mark || !performance.measure)) {
    BM = !0, console.warn("Performance API is not supported on this platform");
    return;
} Qc = !0; }
function j0() { Qc = !1; }
function V0(e) { }
function H0(e) { return typeof e == "boolean" ? e : e != null && e !== "false"; }
function B0(e, t = NaN) { return !isNaN(parseFloat(e)) && !isNaN(Number(e)) ? Number(e) : t; }
var Ih = Symbol("NOT_SET"), lw = new Set, rF = Ie(q({}, Jc), { kind: "afterRenderEffectPhase", consumerIsAlwaysLive: !0, consumerAllowSignalWrites: !0, value: Ih, cleanup: null, consumerMarkedDirty() { if (this.sequence.impl.executing) {
        if (this.sequence.lastPhase === null || this.sequence.lastPhase < this.phase)
            return;
        this.sequence.erroredOrDestroyed = !0;
    } this.sequence.scheduler.notify(7); }, phaseFn(e) { if (this.sequence.lastPhase = this.phase, !this.dirty)
        return this.signal; if (this.dirty = !1, this.value !== Ih && !zi(this))
        return this.signal; try {
        for (let r of this.cleanup ?? lw)
            r();
    }
    finally {
        this.cleanup?.clear();
    } let t = []; e !== void 0 && t.push(e), t.push(this.registerCleanupFn); let n = Ko(this), o; try {
        o = this.userFn.apply(null, t);
    }
    finally {
        Wi(this, n);
    } return (this.value === Ih || !this.equal(this.value, o)) && (this.value = o, this.version++), this.signal; } }), Sh = class extends Kr {
    scheduler;
    lastPhase = null;
    nodes = [void 0, void 0, void 0, void 0];
    onDestroyFns = null;
    constructor(t, n, o, r, i, s = null) { super(t, [void 0, void 0, void 0, void 0], o, !1, i.get(Re), s), this.scheduler = r; for (let a of wf) {
        let c = n[a];
        if (c === void 0)
            continue;
        let l = Object.create(rF);
        l.sequence = this, l.phase = a, l.userFn = c, l.dirty = !0, l.signal = () => (Gi(l), l.value), l.signal[ae] = l, l.registerCleanupFn = u => (l.cleanup ??= new Set).add(u), this.nodes[a] = l, this.hooks[a] = u => l.phaseFn(u);
    } }
    afterRun() { super.afterRun(), this.lastPhase = null; }
    destroy() { if (this.onDestroyFns !== null)
        for (let t of this.onDestroyFns)
            t(); super.destroy(); for (let t of this.nodes)
        if (t)
            try {
                for (let n of t.cleanup ?? lw)
                    n();
            }
            finally {
                $t(t);
            } }
};
function $0(e, t) { if (typeof ngServerMode < "u" && ngServerMode)
    return Ya; let n = t?.injector ?? E(oe), o = n.get(Ue), r = n.get(Za), i = n.get(Bn, null, { optional: !0 }); r.impl ??= n.get(Nf); let s = e; typeof s == "function" && (s = { mixedReadWrite: e }); let a = n.get(io, null, { optional: !0 }), c = new Sh(r.impl, [s.earlyRead, s.write, s.mixedReadWrite, s.read], a?.view, o, n, i?.snapshot(null)); return r.impl.register(c), c; }
function U0(e) { return X({ usage: 1, kind: "directive", type: e.type }).compileDirectiveDeclaration(Ee, `ng:///${e.type.name}/\u0275fac.js`, e); }
function q0(e) { op(e.type, e.decorators, e.ctorParameters ?? null, e.propDecorators ?? null); }
function G0(e) { DI(e.type, e.resolveDeferredDeps, (...t) => { let n = e.resolveMetadata(...t); op(e.type, n.decorators, n.ctorParameters, n.propDecorators); }); }
function W0(e) { return X({ usage: 1, kind: "component", type: e.type }).compileComponentDeclaration(Ee, `ng:///${e.type.name}/\u0275cmp.js`, e); }
function z0(e) { return X({ usage: 1, kind: iF(e.target), type: e.type }).compileFactoryDeclaration(Ee, `ng:///${e.type.name}/\u0275fac.js`, e); }
function iF(e) { switch (e) {
    case Wn.Directive: return "directive";
    case Wn.Component: return "component";
    case Wn.Injectable: return "injectable";
    case Wn.Pipe: return "pipe";
    case Wn.NgModule: return "NgModule";
    case Wn.Service: return "service";
} }
function Q0(e) { return X({ usage: 1, kind: "injectable", type: e.type }).compileInjectableDeclaration(Ee, `ng:///${e.type.name}/\u0275prov.js`, e); }
function Z0(e) { return X({ usage: 1, kind: "NgModule", type: e.type }).compileInjectorDeclaration(Ee, `ng:///${e.type.name}/\u0275inj.js`, e); }
function Y0(e) { return X({ usage: 1, kind: "NgModule", type: e.type }).compileNgModuleDeclaration(Ee, `ng:///${e.type.name}/\u0275mod.js`, e); }
function K0(e) { return X({ usage: 1, kind: "pipe", type: e.type }).compilePipeDeclaration(Ee, `ng:///${e.type.name}/\u0275pipe.js`, e); }
function J0(e) { return X({ usage: 1, kind: "service", type: e.type }).compileServiceDeclaration(Ee, `ng:///${e.type.name}/\u0275prov.js`, e); }
function X0(e) { let t = ap(e); if (!t)
    throw uw(e); return new _o(t); }
function ej(e) { let t = ap(e); if (!t)
    throw uw(e); return t; }
function uw(e) { return new D(920, !1); }
var bh = class extends NL {
}, $M = class extends bh {
}, tj = GL(null, "core", []);
function nj(e, t) { let n = W(e), o = t.elementInjector || Jn(); return new kn(n).create(o, t.projectableNodes, t.hostElement, t.environmentInjector, t.directives, t.bindings); }
function oj(e) { let t = W(e); if (!t)
    return null; let n = new kn(t); return { get selector() { return n.selector; }, get type() { return n.componentType; }, get inputs() { return n.inputs; }, get outputs() { return n.outputs; }, get ngContentSelectors() { return n.ngContentSelectors; }, get isStandalone() { return t.standalone; }, get isSignal() { return t.signals; } }; }
function sF(e) { return new Ah(ao(e) ? e : xe(e)); }
var Ah = class {
    snapshot;
    constructor(t) { this.snapshot = t; }
    get state() { return this.snapshot(); }
    value = xe(() => { if (this.state.status === "error")
        throw new Vi(this.state.error); return this.state.value; });
    status = xe(() => this.state.status);
    error = xe(() => this.state.status === "error" ? this.state.error : void 0);
    isLoading = xe(() => this.state.status === "loading" || this.state.status === "reloading");
    isValueDefined = xe(() => this.state.status !== "error" && this.state.value !== void 0);
    hasValue() { return this.isValueDefined(); }
};
function rj(e, t, n) { if (lh())
    throw uh(); let o = n?.injector ?? E(oe), r, i; o.get(Re).onDestroy(() => { r = void 0; }); let s = Ac({ source: () => { try {
        return qn(!0), { value: e(), thrown: !1 };
    }
    catch (a) {
        return Hi(a), { error: a, thrown: !0 };
    }
    finally {
        qn(!1);
    } }, computation: (a, c) => c !== void 0 ? c.value : a.thrown ? { status: "error", error: a.error } : { status: "resolved", value: a.value } }); return _s(() => { let a; try {
    qn(!0), a = e();
}
catch (f) {
    Hi(f), s.set({ status: "error", error: f }), r = i = void 0;
    return;
}
finally {
    qn(!1);
} let c = ke(s), l = n?.equal ?? Object.is; if (c.status === "reloading" || c.status === "loading") {
    if (l(a, i))
        return;
}
else if (c.status === "resolved" && l(a, c.value))
    return; let d = (typeof t == "number" ? () => new Promise(f => setTimeout(f, t)) : t)(a, c); d === void 0 ? (s.set({ status: "resolved", value: a }), r = i = void 0) : (c.status !== "loading" && c.status !== "error" && s.set({ status: "loading", value: c.value }), r = d, i = a, d.then(() => { r === d && (s.set({ status: "resolved", value: a }), r = i = void 0); })); }, { injector: o }), sF(s); }
function ij() { return !1; }
function sj() { }
function aF(e, t) { let n = globalThis.document.modelContext ?? globalThis.navigator.modelContext; if (!n)
    return; let o = t ?? E(oe), r = o.get(Re), i = new AbortController, s = Ie(q({}, e), { execute: (a, c) => Ir(o, () => e.execute(a, Ie(q({}, c), { signal: i.signal }))) }); n.registerTool(s, { signal: i.signal }), r.onDestroy(() => { i.abort(); }); }
function aj(e) { return Le([Tl(() => { for (let t of e)
        aF(t); })]); }
export { sN as ANIMATION_MODULE_TYPE, ki as APP_BOOTSTRAP_LISTENER, vt as APP_ID, rp as APP_INITIALIZER, ip as ApplicationInitStatus, m0 as ApplicationModule, He as ApplicationRef, Ev as Attribute, YC as COMPILER_OPTIONS, aN as CSP_NONCE, eS as CUSTOM_ELEMENTS_SCHEMA, ba as ChangeDetectionStrategy, NL as ChangeDetectorRef, dP as Compiler, Ld as CompilerFactory, oP as Component, PE as ComponentRef, p0 as ContentChild, f0 as ContentChildren, pP as DEFAULT_CURRENCY_CODE, Nt as DOCUMENT, Fn as DebugElement, Fd as DebugEventListener, ui as DebugNode, Th as DefaultIterableDiffer, Re as DestroyRef, QC as Directive, Ge as ENVIRONMENT_INITIALIZER, hi as ElementRef, $M as EmbeddedViewRef, be as EnvironmentInjector, Mt as ErrorHandler, Dt as EventEmitter, t0 as HOST_TAG_NAME, yv as Host, MM as HostAttributeToken, aP as HostBinding, cP as HostListener, Er as INJECTOR, hv as Inject, YN as Injectable, C as InjectionToken, oe as Injector, iP as Input, zM as IterableDiffers, QM as KeyValueDiffers, ih as LOCALE_ID, Ay as MAX_ANIMATION_TIMEOUT, KC as MissingTranslationStrategy, tS as NO_ERRORS_SCHEMA, lP as NgModule, fI as NgModuleFactory, xn as NgModuleRef, G as NgZone, gv as Optional, sP as Output, ji as OutputEmitterRef, iN as PLATFORM_ID, au as PLATFORM_INITIALIZER, br as PendingTasks, rP as Pipe, JM as PlatformRef, Yo as Query, ra as QueryList, v0 as REQUEST, E0 as REQUEST_CONTEXT, y0 as RESPONSE_INIT, ZA as Renderer2, ni as RendererFactory2, la as RendererStyleFlags2, bc as ResourceDependencyError, Un as ResourceParamsStatus, LE as Sanitizer, ee as SecurityContext, mv as Self, XN as Service, Ks as SimpleChange, vv as SkipSelf, hP as TRANSLATIONS, gP as TRANSLATIONS_FORMAT, Xr as TemplateRef, qk as Testability, JI as TestabilityRegistry, St as TransferState, pv as Type, Ki as VERSION, Yi as Version, g0 as ViewChild, h0 as ViewChildren, mc as ViewContainerRef, Ye as ViewEncapsulation, bh as ViewRef, Py as afterEveryRender, _f as afterNextRender, $0 as afterRenderEffect, mP as asNativeElements, Uw as assertInInjectionContext, lN as assertNotInReactiveContext, WL as assertPlatform, H0 as booleanAttribute, xe as computed, l0 as contentChild, u0 as contentChildren, nj as createComponent, tp as createEnvironmentInjector, HR as createNgModule, qL as createPlatform, GL as createPlatformFactory, rj as debounced, aF as declareExperimentalWebMcpTool, R0 as destroyPlatform, _s as effect, sj as enableProdMode, Hk as enableProfiling, cr as forwardRef, di as getDebugNode, X0 as getModuleFactory, ej as getNgModuleById, zc as getPlatform, Kh as importProvidersFrom, E as inject, n0 as injectAsync, i0 as input, qE as inputBinding, ij as isDevMode, ao as isSignal, hr as isStandalone, Ss as isWritableSignal, Ac as linkedSignal, Le as makeEnvironmentProviders, Cg as makeStateKey, d0 as mergeApplicationConfig, s0 as model, B0 as numberAttribute, o0 as onIdle, r0 as output, GE as outputBinding, tj as platformCore, TI as provideAppInitializer, nN as provideBrowserGlobalErrorListeners, _0 as provideCheckNoChangesConfig, Tl as provideEnvironmentInitializer, aj as provideExperimentalWebMcpTools, jN as provideIdleServiceWith, jS as provideNgReflectAttributes, k0 as providePlatformInitializer, M0 as provideStabilityDebugging, S0 as provideZoneChangeDetection, uP as provideZonelessChangeDetection, oj as reflectComponentType, L as resolveForwardRef, TP as resource, sF as resourceFromSnapshots, Ir as runInInjectionContext, XI as setTestabilityGetter, mt as signal, lR as twoWayBinding, ke as untracked, a0 as viewChild, c0 as viewChildren, by as \u0275ANIMATIONS_DISABLED, Rv as \u0275AcxChangeDetectionStrategy, kv as \u0275AcxViewEncapsulation, Za as \u0275AfterRenderManager, tM as \u0275CACHE_ACTIVE, I0 as \u0275CLIENT_RENDER_MODE_FLAG, U as \u0275CONTAINER_HEADER_OFFSET, Ue as \u0275ChangeDetectionScheduler, Nk as \u0275Console, qI as \u0275ControlFlowBlockType, Pi as \u0275DEFAULT_LOCALE_ID, BI as \u0275DEFER_BLOCK_CONFIG, Ik as \u0275DEFER_BLOCK_DEPENDENCY_INTERCEPTOR, Lt as \u0275DEHYDRATED_BLOCK_REGISTRY, dp as \u0275DeferBlockBehavior, Q as \u0275DeferBlockState, LL as \u0275ENABLE_ROOT_COMPONENT_BOOTSTRAP, Lv as \u0275EVENT_REPLAY_QUEUE, Ns as \u0275EffectScheduler, cL as \u0275Framework, Yv as \u0275HydrationStatus, cN as \u0275IMAGE_CONFIG, Tg as \u0275IMAGE_CONFIG_DEFAULTS, Ml as \u0275INJECTOR_SCOPE, e0 as \u0275INPUT_SIGNAL_BRAND_WRITE_TYPE, _t as \u0275INTERNAL_APPLICATION_ERROR_HANDLER, __ as \u0275IS_ENABLED_BLOCKING_INITIAL_NAVIGATION, Vn as \u0275IS_HYDRATION_DOM_REUSE_ENABLED, Kd as \u0275IS_INCREMENTAL_HYDRATION_ENABLED, Di as \u0275JSACTION_BLOCK_ELEMENT_MAP, tf as \u0275JSACTION_EVENT_CONTRACT, ia as \u0275LContext, So as \u0275LocaleDataIndex, fn as \u0275NG_COMP_DEF, fr as \u0275NG_DIR_DEF, pn as \u0275NG_ELEMENT_ID, er as \u0275NG_INJ_DEF, os as \u0275NG_MOD_DEF, pr as \u0275NG_PIPE_DEF, Wt as \u0275NG_PROV_DEF, zs as \u0275NOT_FOUND_CHECK_ONLY_ELEMENT_INJECTOR, $ as \u0275NO_CHANGE, _o as \u0275NgModuleFactory, rr as \u0275NoopNgZone, oF as \u0275PERFORMANCE_MARK_PREFIX, kL as \u0275PROVIDED_NG_ZONE, dN as \u0275PROVIDED_ZONELESS, gt as \u0275PendingTasksInternal, P as \u0275ProfilerEvent, Xe as \u0275R3Injector, oa as \u0275ReflectionCapabilities, kn as \u0275Render3ComponentFactory, va as \u0275Render3ComponentRef, No as \u0275Render3NgModuleRef, Rc as \u0275ResourceImpl, D as \u0275RuntimeError, WE as \u0275SHARED_STYLES_HOST, ae as \u0275SIGNAL, Wv as \u0275SSR_CONTENT_INTEGRITY_MARKER, ZI as \u0275TESTABILITY, YI as \u0275TESTABILITY_GETTER, HI as \u0275TimerScheduler, Qa as \u0275TracingAction, Bn as \u0275TracingService, KI as \u0275USE_PENDING_TASKS, rn as \u0275ViewRef, ts as \u0275XSS_SECURITY_URL, so as \u0275ZONELESS_ENABLED, hy as \u0275_sanitizeHtml, Ba as \u0275_sanitizeUrl, on as \u0275allLeavingAnimations, Ho as \u0275allowSanitizationBypassAndThrow, O0 as \u0275annotateForHydration, V0 as \u0275assertType, aS as \u0275bypassSanitizationTrustHtml, dS as \u0275bypassSanitizationTrustResourceUrl, lS as \u0275bypassSanitizationTrustScript, cS as \u0275bypassSanitizationTrustStyle, uS as \u0275bypassSanitizationTrustUrl, nM as \u0275chain, ZR as \u0275clearResolutionOfComponentResourcesQueue, jC as \u0275compileComponent, rh as \u0275compileDirective, LC as \u0275compileNgModule, FC as \u0275compileNgModuleDefs, PL as \u0275compileNgModuleFactory, zC as \u0275compilePipe, un as \u0275convertToBitFlags, ul as \u0275createInjector, zL as \u0275createOrReusePlatformInjector, w0 as \u0275defaultIterableDiffers, N0 as \u0275defaultKeyValueDiffers, wo as \u0275depsTracker, jE as \u0275devModeEqual, j0 as \u0275disableProfiling, F0 as \u0275enableProfiling, xc as \u0275encapsulateResourceError, Ap as \u0275findLocaleData, OC as \u0275flushModuleScopingQueueAsMuchAsPossible, sr as \u0275formatRuntimeError, qO as \u0275generateStandaloneInDeclarationsError, WR as \u0275getAsyncClassMetadataFn, XA as \u0275getClosestComponentName, W as \u0275getComponentDef, Ys as \u0275getDeferBlocks, E_ as \u0275getDirectives, gi as \u0275getDocument, D_ as \u0275getHostElement, dr as \u0275getInjectableDef, we as \u0275getLContext, Tx as \u0275getLocaleCurrencyCode, FD as \u0275getLocalePluralCase, IP as \u0275getOutputDestroyRef, ay as \u0275getSanitizationBypassType, Bk as \u0275getTransferState, oS as \u0275getUnknownElementStrictMode, iS as \u0275getUnknownPropertyStrictMode, Pe as \u0275global, JE as \u0275inferTagNameFromDefinition, _L as \u0275injectChangeDetectorRef, x0 as \u0275internalCreateApplication, xL as \u0275internalProvideZoneChangeDetection, QR as \u0275isComponentDefPendingResolution, ml as \u0275isEnvironmentProviders, Cw as \u0275isInjectable, Dn as \u0275isNgModule, ep as \u0275isPromise, dI as \u0275isSubscribable, Kb as \u0275isViewDirty, Jb as \u0275markForRefresh, lL as \u0275maybeUnwrapDefaultExport, Et as \u0275noSideEffects, nh as \u0275patchComponentDefWithScope, te as \u0275performanceMarkFeature, oo as \u0275promiseWithResolvers, Sc as \u0275provideZonelessChangeDetectionInternal, $k as \u0275publishNonCoreGlobalUtil, V_ as \u0275readHydrationInfo, Dx as \u0275registerLocaleData, At as \u0275renderDeferBlockState, zO as \u0275resetCompiledComponents, B_ as \u0275resetIncrementalHydrationEnabledWarnedForTests, $O as \u0275resetJitOptions, CI as \u0275resolveComponentResources, YR as \u0275restoreComponentResolutionQueue, XR as \u0275setAllowDuplicateNgModuleIdsForTest, pw as \u0275setAlternateWeakRefImpl, AC as \u0275setClassDebugInfo, op as \u0275setClassMetadata, DI as \u0275setClassMetadataAsync, at as \u0275setCurrentInjector, N_ as \u0275setDocument, Nw as \u0275setInjectorProfilerContext, BD as \u0275setLocaleId, nS as \u0275setUnknownElementStrictMode, rS as \u0275setUnknownPropertyStrictMode, P0 as \u0275startMeasuring, L0 as \u0275stopMeasuring, Mr as \u0275store, ar as \u0275stringify, oh as \u0275transitiveScopesFor, Ic as \u0275triggerResourceLoading, Dw as \u0275truncateMiddle, Cx as \u0275unregisterLocaleData, Ft as \u0275unwrapSafeValue, oN as \u0275unwrapWritableSignal, D0 as \u0275withDomHydration, gL as \u0275withEventReplay, T0 as \u0275withI18nSupport, C0 as \u0275withIncrementalHydration, _I as \u0275\u0275ControlFeature, XT as \u0275\u0275ExternalStylesFeature, Wn as \u0275\u0275FactoryTarget, SI as \u0275\u0275HostDirectivesFeature, cp as \u0275\u0275InheritDefinitionFeature, Zm as \u0275\u0275NgOnChangesFeature, JT as \u0275\u0275ProvidersFeature, _y as \u0275\u0275advance, Vr as \u0275\u0275animateEnter, Hr as \u0275\u0275animateEnterListener, Br as \u0275\u0275animateLeave, Ia as \u0275\u0275animateLeaveListener, yp as \u0275\u0275ariaProperty, ZT as \u0275\u0275arrowFunction, jT as \u0275\u0275attachSourceLocations, Ep as \u0275\u0275attribute, hT as \u0275\u0275classMap, Up as \u0275\u0275classProp, _D as \u0275\u0275componentInstance, bD as \u0275\u0275conditional, Dc as \u0275\u0275conditionalBranchCreate, SD as \u0275\u0275conditionalCreate, jp as \u0275\u0275contentQuery, Hp as \u0275\u0275contentQuerySignal, $E as \u0275\u0275control, HE as \u0275\u0275controlCreate, th as \u0275\u0275declareLet, rD as \u0275\u0275defer, UI as \u0275\u0275deferEnableTimerScheduling, cD as \u0275\u0275deferHydrateNever, ID as \u0275\u0275deferHydrateOnHover, dD as \u0275\u0275deferHydrateOnIdle, hD as \u0275\u0275deferHydrateOnImmediate, CD as \u0275\u0275deferHydrateOnInteraction, vD as \u0275\u0275deferHydrateOnTimer, ND as \u0275\u0275deferHydrateOnViewport, aD as \u0275\u0275deferHydrateWhen, yD as \u0275\u0275deferOnHover, lD as \u0275\u0275deferOnIdle, fD as \u0275\u0275deferOnImmediate, DD as \u0275\u0275deferOnInteraction, gD as \u0275\u0275deferOnTimer, MD as \u0275\u0275deferOnViewport, ED as \u0275\u0275deferPrefetchOnHover, uD as \u0275\u0275deferPrefetchOnIdle, pD as \u0275\u0275deferPrefetchOnImmediate, TD as \u0275\u0275deferPrefetchOnInteraction, mD as \u0275\u0275deferPrefetchOnTimer, wD as \u0275\u0275deferPrefetchOnViewport, sD as \u0275\u0275deferPrefetchWhen, iD as \u0275\u0275deferWhen, hI as \u0275\u0275defineComponent, mI as \u0275\u0275defineDirective, Y as \u0275\u0275defineInjectable, ur as \u0275\u0275defineInjector, np as \u0275\u0275defineNgModule, vI as \u0275\u0275definePipe, Pt as \u0275\u0275defineService, Wo as \u0275\u0275directiveInject, jl as \u0275\u0275disableBindings, Tp as \u0275\u0275domElement, Np as \u0275\u0275domElementContainer, wp as \u0275\u0275domElementContainerEnd, Nc as \u0275\u0275domElementContainerStart, Mc as \u0275\u0275domElementEnd, Cc as \u0275\u0275domElementStart, Lp as \u0275\u0275domListener, Sp as \u0275\u0275domProperty, up as \u0275\u0275domTemplate, Dp as \u0275\u0275element, Mp as \u0275\u0275elementContainer, Oi as \u0275\u0275elementContainerEnd, wc as \u0275\u0275elementContainerStart, Tc as \u0275\u0275elementEnd, ai as \u0275\u0275elementStart, Fl as \u0275\u0275enableBindings, sC as \u0275\u0275enableIncrementalHydrationRuntime, bC as \u0275\u0275getComponentDepsFactory, LD as \u0275\u0275getCurrentView, dv as \u0275\u0275getInheritedFactory, RC as \u0275\u0275getReplaceMetadataURL, JD as \u0275\u0275i18n, eT as \u0275\u0275i18nApply, XD as \u0275\u0275i18nAttributes, kp as \u0275\u0275i18nEnd, xp as \u0275\u0275i18nExp, tT as \u0275\u0275i18nPostprocess, Rp as \u0275\u0275i18nStart, he as \u0275\u0275inject, _a as \u0275\u0275injectAttribute, VT as \u0275\u0275interpolate, HT as \u0275\u0275interpolate1, BT as \u0275\u0275interpolate2, $T as \u0275\u0275interpolate3, UT as \u0275\u0275interpolate4, qT as \u0275\u0275interpolate5, GT as \u0275\u0275interpolate6, WT as \u0275\u0275interpolate7, zT as \u0275\u0275interpolate8, QT as \u0275\u0275interpolateV, zE as \u0275\u0275invalidFactory, as as \u0275\u0275invalidFactoryDep, Op as \u0275\u0275listener, sT as \u0275\u0275loadQuery, Xl as \u0275\u0275namespaceHTML, Jl as \u0275\u0275namespaceMathML, Kl as \u0275\u0275namespaceSVG, nT as \u0275\u0275nextContext, q0 as \u0275\u0275ngDeclareClassMetadata, G0 as \u0275\u0275ngDeclareClassMetadataAsync, W0 as \u0275\u0275ngDeclareComponent, U0 as \u0275\u0275ngDeclareDirective, z0 as \u0275\u0275ngDeclareFactory, Q0 as \u0275\u0275ngDeclareInjectable, Z0 as \u0275\u0275ngDeclareInjector, Y0 as \u0275\u0275ngDeclareNgModule, K0 as \u0275\u0275ngDeclarePipe, J0 as \u0275\u0275ngDeclareService, TC as \u0275\u0275pipe, CC as \u0275\u0275pipeBind1, MC as \u0275\u0275pipeBind2, wC as \u0275\u0275pipeBind3, NC as \u0275\u0275pipeBind4, _C as \u0275\u0275pipeBindV, rT as \u0275\u0275projection, oT as \u0275\u0275projectionDef, Ip as \u0275\u0275property, aC as \u0275\u0275pureFunction0, cC as \u0275\u0275pureFunction1, lC as \u0275\u0275pureFunction2, uC as \u0275\u0275pureFunction3, dC as \u0275\u0275pureFunction4, fC as \u0275\u0275pureFunction5, pC as \u0275\u0275pureFunction6, hC as \u0275\u0275pureFunction7, gC as \u0275\u0275pureFunction8, mC as \u0275\u0275pureFunctionV, aT as \u0275\u0275queryAdvance, iT as \u0275\u0275queryRefresh, FT as \u0275\u0275readContextLet, cT as \u0275\u0275reference, sp as \u0275\u0275registerNgModuleType, xD as \u0275\u0275repeater, kD as \u0275\u0275repeaterCreate, RD as \u0275\u0275repeaterTrackByIdentity, AD as \u0275\u0275repeaterTrackByIndex, kC as \u0275\u0275replaceMetadata, Bl as \u0275\u0275resetView, mf as \u0275\u0275resolveBody, Cy as \u0275\u0275resolveDocument, Ty as \u0275\u0275resolveWindow, Hl as \u0275\u0275restoreView, df as \u0275\u0275sanitizeHtml, Ua as \u0275\u0275sanitizeResourceUrl, hf as \u0275\u0275sanitizeScript, ff as \u0275\u0275sanitizeStyle, pf as \u0275\u0275sanitizeUrl, Dy as \u0275\u0275sanitizeUrlOrResourceUrl, eC as \u0275\u0275setComponentScope, tC as \u0275\u0275setNgModuleScope, LT as \u0275\u0275storeLet, pT as \u0275\u0275styleMap, $p as \u0275\u0275styleProp, Pp as \u0275\u0275syntheticHostListener, bp as \u0275\u0275syntheticHostProperty, lp as \u0275\u0275template, SC as \u0275\u0275templateRefExtractor, TT as \u0275\u0275text, qp as \u0275\u0275textInterpolate, _c as \u0275\u0275textInterpolate1, Gp as \u0275\u0275textInterpolate2, Wp as \u0275\u0275textInterpolate3, zp as \u0275\u0275textInterpolate4, Qp as \u0275\u0275textInterpolate5, Zp as \u0275\u0275textInterpolate6, Yp as \u0275\u0275textInterpolate7, Kp as \u0275\u0275textInterpolate8, Jp as \u0275\u0275textInterpolateV, Ey as \u0275\u0275trustConstantHtml, Iy as \u0275\u0275trustConstantResourceUrl, OT as \u0275\u0275twoWayBindingSet, eh as \u0275\u0275twoWayListener, Xp as \u0275\u0275twoWayProperty, gf as \u0275\u0275validateAttribute, Vp as \u0275\u0275viewQuery, Bp as \u0275\u0275viewQuerySignal };
/*! Bundled license information:

@angular/core/fesm2022/_pending_tasks-chunk.mjs:
@angular/core/fesm2022/_attribute-chunk.mjs:
@angular/core/fesm2022/_debug_node-chunk.mjs:
@angular/core/fesm2022/_resource-chunk.mjs:
@angular/core/fesm2022/primitives-event-dispatch.mjs:
@angular/core/fesm2022/core.mjs:
  (**
   * @license Angular v22.0.0
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
