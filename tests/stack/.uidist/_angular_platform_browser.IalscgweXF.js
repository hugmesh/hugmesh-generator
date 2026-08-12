import { a as I, b as q, d as j } from "@nf-internal/chunk-PZNONLPT";
import { \u0275DomAdapter as Ye, \u0275setRootDomAdapter as Ke, \u0275parseCookieValue as Ze, \u0275getDOM as fe, DOCUMENT as pe, CommonModule as We, \u0275PLATFORM_BROWSER_ID as Je } from "@angular/common";
import * as m from "@angular/core";
import { \u0275global as g, \u0275RuntimeError as Xe, InjectionToken as Xt, ApplicationModule as qe, \u0275INJECTOR_SCOPE as Qe, ErrorHandler as he, \u0275SHARED_STYLES_HOST as ce, RendererFactory2 as et, \u0275TESTABILITY_GETTER as Y, NgZone as le, TestabilityRegistry as de, Testability as K, \u0275TESTABILITY as tt, \u0275internalCreateApplication as me, createPlatformFactory as nt, platformCore as rt, PLATFORM_ID as ot, PLATFORM_INITIALIZER as st, \u0275USE_PENDING_TASKS as it, \u0275resolveComponentResources as qt, \u0275setDocument as at } from "@angular/core";
import { DOCUMENT as $, \u0275getDOM as Pe } from "@angular/common";
import * as c from "@angular/core";
import { InjectionToken as ne, \u0275RuntimeError as F, APP_ID as re, CSP_NONCE as oe, PLATFORM_ID as ke, ViewEncapsulation as E, \u0275SHARED_STYLES_HOST as Ue, \u0275TracingService as xe, RendererStyleFlags2 as O, \u0275allLeavingAnimations as Be } from "@angular/core";
var v = class {
    _doc;
    constructor(r) { this._doc = r; }
    manager;
}, w = (() => { class n extends v {
    constructor(e) { super(e); }
    supports(e) { return !0; }
    addEventListener(e, t, o, s) { return e.addEventListener(t, o, s), () => this.removeEventListener(e, t, o, s); }
    removeEventListener(e, t, o, s) { return e.removeEventListener(t, o, s); }
    static \u0275fac = function (t) { return new (t || n)(c.\u0275\u0275inject($)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: n, factory: n.\u0275fac });
} return n; })(), R = new ne(""), H = (() => { class n {
    _zone;
    _plugins;
    _eventNameToPlugin = new Map;
    constructor(e, t) { this._zone = t, e.forEach(i => { i.manager = this; }); let o = e.filter(i => !(i instanceof w)); this._plugins = o.slice().reverse(); let s = e.find(i => i instanceof w); s && this._plugins.push(s); }
    addEventListener(e, t, o, s) { return this._findPluginFor(t).addEventListener(e, t, o, s); }
    getZone() { return this._zone; }
    _findPluginFor(e) { let t = this._eventNameToPlugin.get(e); if (t)
        return t; if (t = this._plugins.find(s => s.supports(e)), !t)
        throw new F(-5101, !1); return this._eventNameToPlugin.set(e, t), t; }
    static \u0275fac = function (t) { return new (t || n)(c.\u0275\u0275inject(R), c.\u0275\u0275inject(c.NgZone)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: n, factory: n.\u0275fac });
} return n; })(), b = "ng-app-id";
function Q(n) { for (let r of n)
    r.remove(); }
function ee(n, r) { let e = r.createElement("style"); return e.textContent = n, e; }
function je(n, r, e, t) { let o = n.head?.querySelectorAll(`style[${b}="${r}"],link[${b}="${r}"]`); if (!o || o.length === 0)
    return !1; for (let s of o)
    s.removeAttribute(b), s instanceof HTMLLinkElement ? t.set(s.href.slice(s.href.lastIndexOf("/") + 1), { usage: 0, elements: [s] }) : s.textContent && e.set(s.textContent, { usage: 0, elements: [s] }); return !0; }
function z(n, r) { let e = r.createElement("link"); return e.setAttribute("rel", "stylesheet"), e.setAttribute("href", n), e; }
var P = (() => { class n {
    doc;
    appId;
    nonce;
    inline = new Map;
    external = new Map;
    hosts = new Set;
    constructor(e, t, o, s = {}) { this.doc = e, this.appId = t, this.nonce = o, je(e, t, this.inline, this.external) && this.hosts.add(e.head); }
    addStyles(e, t) { for (let o of e)
        this.addUsage(o, this.inline, ee); t?.forEach(o => this.addUsage(o, this.external, z)); }
    removeStyles(e, t) { for (let o of e)
        this.removeUsage(o, this.inline); t?.forEach(o => this.removeUsage(o, this.external)); }
    addUsage(e, t, o) { let s = t.get(e); s ? s.usage++ : t.set(e, { usage: 1, elements: [...this.hosts].map(i => this.addElement(i, o(e, this.doc))) }); }
    removeUsage(e, t) { let o = t.get(e); o && (o.usage--, o.usage <= 0 && (Q(o.elements), t.delete(e))); }
    ngOnDestroy() { for (let [, { elements: e }] of [...this.inline, ...this.external])
        Q(e); this.hosts.clear(); }
    addHost(e) { if (!this.hosts.has(e)) {
        this.hosts.add(e);
        for (let [t, { elements: o }] of this.inline)
            o.push(this.addElement(e, ee(t, this.doc)));
        for (let [t, { elements: o }] of this.external)
            o.push(this.addElement(e, z(t, this.doc)));
    } }
    removeHost(e) { this.hosts.delete(e); for (let t of [...this.inline.values(), ...this.external.values()]) {
        let o = [];
        for (let s of t.elements)
            s.parentNode === e ? s.remove() : o.push(s);
        t.elements = o;
    } }
    addElement(e, t) { return this.nonce && t.setAttribute("nonce", this.nonce), typeof ngServerMode < "u" && ngServerMode && t.setAttribute(b, this.appId), e.appendChild(t); }
    static \u0275fac = function (t) { return new (t || n)(c.\u0275\u0275inject($), c.\u0275\u0275inject(re), c.\u0275\u0275inject(oe, 8), c.\u0275\u0275inject(ke)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: n, factory: n.\u0275fac });
} return n; })(), V = { svg: "http://www.w3.org/2000/svg", xhtml: "http://www.w3.org/1999/xhtml", xlink: "http://www.w3.org/1999/xlink", xml: "http://www.w3.org/XML/1998/namespace", xmlns: "http://www.w3.org/2000/xmlns/", math: "http://www.w3.org/1998/Math/MathML" }, G = /%COMP%/g;
var se = "%COMP%", Ve = `_nghost-${se}`, Fe = `_ngcontent-${se}`, ze = !0, ie = new ne("", { factory: () => ze });
function $e(n) { return Fe.replace(G, n); }
function Ge(n) { return Ve.replace(G, n); }
function ae(n, r) { return r.map(e => e.replace(G, n)); }
var k = (() => { class n {
    eventManager;
    sharedStylesHost;
    appId;
    removeStylesOnCompDestroy;
    doc;
    ngZone;
    nonce;
    tracingService;
    rendererByCompId = new Map;
    defaultRenderer;
    constructor(e, t, o, s, i, a, l = null, d = null) { this.eventManager = e, this.sharedStylesHost = t, this.appId = o, this.removeStylesOnCompDestroy = s, this.doc = i, this.ngZone = a, this.nonce = l, this.tracingService = d, this.defaultRenderer = new _(e, i, a, this.tracingService); }
    createRenderer(e, t) { if (!e || !t)
        return this.defaultRenderer; typeof ngServerMode < "u" && ngServerMode && (t.encapsulation === E.ShadowDom || t.encapsulation === E.ExperimentalIsolatedShadowDom) && (t = q(I({}, t), { encapsulation: E.Emulated })); let o = this.getOrCreateRenderer(e, t); return o instanceof L ? o.applyToHost(e) : o instanceof M && o.applyStyles(), o; }
    getOrCreateRenderer(e, t) { let o = this.rendererByCompId, s = o.get(t.id); if (!s) {
        let i = this.doc, a = this.ngZone, l = this.eventManager, d = this.sharedStylesHost, f = this.removeStylesOnCompDestroy, p = this.tracingService;
        switch (t.encapsulation) {
            case E.Emulated:
                s = new L(l, d, t, this.appId, f, i, a, p);
                break;
            case E.ShadowDom: return new N(l, e, t, i, a, this.nonce, p, d);
            case E.ExperimentalIsolatedShadowDom: return new N(l, e, t, i, a, this.nonce, p);
            default:
                s = new M(l, d, t, f, i, a, p);
                break;
        }
        o.set(t.id, s);
    } return s; }
    ngOnDestroy() { this.rendererByCompId.clear(); }
    componentReplaced(e) { this.rendererByCompId.delete(e); }
    static \u0275fac = function (t) { return new (t || n)(c.\u0275\u0275inject(H), c.\u0275\u0275inject(Ue), c.\u0275\u0275inject(re), c.\u0275\u0275inject(ie), c.\u0275\u0275inject($), c.\u0275\u0275inject(c.NgZone), c.\u0275\u0275inject(oe), c.\u0275\u0275inject(xe, 8)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: n, factory: n.\u0275fac });
} return n; })(), _ = class {
    eventManager;
    doc;
    ngZone;
    tracingService;
    data = Object.create(null);
    throwOnSyntheticProps = !0;
    constructor(r, e, t, o) { this.eventManager = r, this.doc = e, this.ngZone = t, this.tracingService = o; }
    destroy() { }
    destroyNode = null;
    createElement(r, e) { return e ? this.doc.createElementNS(V[e] || e, r) : this.doc.createElement(r); }
    createComment(r) { return this.doc.createComment(r); }
    createText(r) { return this.doc.createTextNode(r); }
    appendChild(r, e) { (te(r) ? r.content : r).appendChild(e); }
    insertBefore(r, e, t) { r && (te(r) ? r.content : r).insertBefore(e, t); }
    removeChild(r, e) { e.remove(); }
    selectRootElement(r, e) { let t = typeof r == "string" ? this.doc.querySelector(r) : r; if (!t)
        throw new F(-5104, !1); return e || (t.textContent = ""), t; }
    parentNode(r) { return r.parentNode; }
    nextSibling(r) { return r.nextSibling; }
    setAttribute(r, e, t, o) { if (o) {
        e = o + ":" + e;
        let s = V[o];
        s ? r.setAttributeNS(s, e, t) : r.setAttribute(e, t);
    }
    else
        r.setAttribute(e, t); }
    removeAttribute(r, e, t) { if (t) {
        let o = V[t];
        o ? r.removeAttributeNS(o, e) : r.removeAttribute(`${t}:${e}`);
    }
    else
        r.removeAttribute(e); }
    addClass(r, e) { r.classList.add(e); }
    removeClass(r, e) { r.classList.remove(e); }
    setStyle(r, e, t, o) { o & (O.DashCase | O.Important) ? r.style.setProperty(e, t, o & O.Important ? "important" : "") : r.style[e] = t; }
    removeStyle(r, e, t) { t & O.DashCase ? r.style.removeProperty(e) : r.style[e] = ""; }
    setProperty(r, e, t) { r != null && (r[e] = t); }
    setValue(r, e) { r.nodeValue = e; }
    listen(r, e, t, o) { if (typeof r == "string" && (r = Pe().getGlobalEventTarget(this.doc, r), !r))
        throw new F(-5102, !1); let s = this.decoratePreventDefault(t); return this.tracingService?.wrapEventListener && (s = this.tracingService.wrapEventListener(r, e, s)), this.eventManager.addEventListener(r, e, s, o); }
    decoratePreventDefault(r) { return e => { if (e === "__ngUnwrap__")
        return r; (typeof ngServerMode < "u" && ngServerMode ? this.ngZone.runGuarded(() => r(e)) : r(e)) === !1 && e.preventDefault(); }; }
};
function te(n) { return n.tagName === "TEMPLATE" && n.content !== void 0; }
var N = class extends _ {
    hostEl;
    sharedStylesHost;
    shadowRoot;
    constructor(r, e, t, o, s, i, a, l) { super(r, o, s, a), this.hostEl = e, this.sharedStylesHost = l, this.shadowRoot = e.attachShadow({ mode: "open" }), this.sharedStylesHost && this.sharedStylesHost.addHost(this.shadowRoot); let d = t.styles; d = ae(t.id, d); for (let p of d) {
        let y = document.createElement("style");
        i && y.setAttribute("nonce", i), y.textContent = p, this.shadowRoot.appendChild(y);
    } let f = t.getExternalStyles?.(); if (f)
        for (let p of f) {
            let y = z(p, o);
            i && y.setAttribute("nonce", i), this.shadowRoot.appendChild(y);
        } }
    nodeOrShadowRoot(r) { return r === this.hostEl ? this.shadowRoot : r; }
    appendChild(r, e) { return super.appendChild(this.nodeOrShadowRoot(r), e); }
    insertBefore(r, e, t) { return super.insertBefore(this.nodeOrShadowRoot(r), e, t); }
    removeChild(r, e) { return super.removeChild(null, e); }
    parentNode(r) { return this.nodeOrShadowRoot(super.parentNode(this.nodeOrShadowRoot(r))); }
    destroy() { this.sharedStylesHost && this.sharedStylesHost.removeHost(this.shadowRoot); }
}, M = class extends _ {
    sharedStylesHost;
    removeStylesOnCompDestroy;
    styles;
    styleUrls;
    constructor(r, e, t, o, s, i, a, l) { super(r, s, i, a), this.sharedStylesHost = e, this.removeStylesOnCompDestroy = o; let d = t.styles; this.styles = l ? ae(l, d) : d, this.styleUrls = t.getExternalStyles?.(l); }
    applyStyles() { this.sharedStylesHost.addStyles(this.styles, this.styleUrls); }
    destroy() { this.removeStylesOnCompDestroy && Be.size === 0 && this.sharedStylesHost.removeStyles(this.styles, this.styleUrls); }
}, L = class extends M {
    contentAttr;
    hostAttr;
    constructor(r, e, t, o, s, i, a, l) { let d = o + "-" + t.id; super(r, e, t, s, i, a, l, d), this.contentAttr = $e(d), this.hostAttr = Ge(d); }
    applyToHost(r) { this.applyStyles(), this.setAttribute(r, this.hostAttr, ""); }
    createElement(r, e) { let t = super.createElement(r, e); return super.setAttribute(t, this.contentAttr, ""), t; }
};
var U = class n extends Ye {
    supportsDOMEvents = !0;
    static makeCurrent() { Ke(new n); }
    onAndCancel(r, e, t, o) { return r.addEventListener(e, t, o), () => { r.removeEventListener(e, t, o); }; }
    dispatchEvent(r, e) { r.dispatchEvent(e); }
    remove(r) { r.remove(); }
    createElement(r, e) { return e = e || this.getDefaultDocument(), e.createElement(r); }
    createHtmlDocument() { return document.implementation.createHTMLDocument("fakeTitle"); }
    getDefaultDocument() { return document; }
    isElementNode(r) { return r.nodeType === Node.ELEMENT_NODE; }
    isShadowRoot(r) { return r instanceof DocumentFragment; }
    getGlobalEventTarget(r, e) { return e === "window" ? window : e === "document" ? r : e === "body" ? r.body : null; }
    getBaseHref(r) { let e = ct(); return e == null ? null : lt(e); }
    resetBaseElement() { D = null; }
    getUserAgent() { return window.navigator.userAgent; }
    getCookie(r) { return Ze(document.cookie, r); }
}, D = null;
function ct() { return D = D || document.head.querySelector("base"), D ? D.getAttribute("href") : null; }
function lt(n) { return new URL(n, document.baseURI).pathname; }
var x = class {
    addToWindow(r) { g.getAngularTestability = (t, o = !0) => { let s = r.findTestabilityInTree(t, o); if (s == null)
        throw new Xe(5103, !1); return s; }, g.getAllAngularTestabilities = () => r.getAllTestabilities(), g.getAllAngularRootElements = () => r.getAllRootElements(); let e = t => { let o = g.getAllAngularTestabilities(), s = o.length, i = function () { s--, s == 0 && t(); }; o.forEach(a => { a.whenStable(i); }); }; g.frameworkStabilizers || (g.frameworkStabilizers = []), g.frameworkStabilizers.push(e); }
    findTestabilityInTree(r, e, t) { if (e == null)
        return null; let o = r.getTestability(e); return o ?? (t ? fe().isShadowRoot(e) ? this.findTestabilityInTree(r, e.host, !0) : this.findTestabilityInTree(r, e.parentElement, !0) : null); }
}, ue = ["alt", "control", "meta", "shift"], dt = { "\b": "Backspace", "	": "Tab", "\x7F": "Delete", "\x1B": "Escape", Del: "Delete", Esc: "Escape", Left: "ArrowLeft", Right: "ArrowRight", Up: "ArrowUp", Down: "ArrowDown", Menu: "ContextMenu", Scroll: "ScrollLock", Win: "OS" }, ut = { alt: n => n.altKey, control: n => n.ctrlKey, meta: n => n.metaKey, shift: n => n.shiftKey }, ge = (() => { class n extends v {
    constructor(e) { super(e); }
    supports(e) { return n.parseEventName(e) != null; }
    addEventListener(e, t, o, s) { let i = n.parseEventName(t), a = n.eventCallback(i.fullKey, o, this.manager.getZone()); return this.manager.getZone().runOutsideAngular(() => fe().onAndCancel(e, i.domEventName, a, s)); }
    static parseEventName(e) { let t = e.toLowerCase().split("."), o = t.shift(); if (t.length === 0 || !(o === "keydown" || o === "keyup"))
        return null; let s = n._normalizeKey(t.pop()), i = "", a = t.indexOf("code"); if (a > -1 && (t.splice(a, 1), i = "code."), ue.forEach(d => { let f = t.indexOf(d); f > -1 && (t.splice(f, 1), i += d + "."); }), i += s, t.length != 0 || s.length === 0)
        return null; let l = {}; return l.domEventName = o, l.fullKey = i, l; }
    static matchEventFullKeyCode(e, t) { let o = dt[e.key] || e.key, s = ""; return t.indexOf("code.") > -1 && (o = e.code, s = "code."), o == null || !o ? !1 : (o = o.toLowerCase(), o === " " ? o = "space" : o === "." && (o = "dot"), ue.forEach(i => { if (i !== o) {
        let a = ut[i];
        a(e) && (s += i + ".");
    } }), s += o, s === t); }
    static eventCallback(e, t, o) { return s => { n.matchEventFullKeyCode(s, e) && o.runGuarded(() => t(s)); }; }
    static _normalizeKey(e) { return e === "esc" ? "escape" : e; }
    static \u0275fac = function (t) { return new (t || n)(m.\u0275\u0275inject(pe)); };
    static \u0275prov = m.\u0275\u0275defineInjectable({ token: n, factory: n.\u0275fac });
} return n; })();
function ft(n, r, e) { return j(this, null, function* () { let t = I({ rootComponent: n }, ye(r, e)); return me(t); }); }
function pt(n, r) { return j(this, null, function* () { return me(ye(n, r)); }); }
function ye(n, r) { return { platformRef: r?.platformRef, appProviders: [...Se, ...n?.providers ?? []], platformProviders: Ee }; }
function ht(n = {}) { return [...ve, n?.usePendingTasksForStability !== void 0 ? { provide: it, useValue: n.usePendingTasksForStability ?? !1 } : []]; }
function mt() { U.makeCurrent(); }
function gt() { return new he; }
function yt() { return at(document), document; }
var Ee = [{ provide: ot, useValue: Je }, { provide: st, useValue: mt, multi: !0 }, { provide: pe, useFactory: yt }], Et = nt(rt, "browser", Ee);
var ve = [{ provide: Y, useClass: x }, { provide: tt, useClass: K, deps: [le, de, Y] }, { provide: K, useClass: K, deps: [le, de, Y] }], Se = [{ provide: Qe, useValue: "root" }, { provide: he, useFactory: gt }, { provide: R, useClass: w, multi: !0 }, { provide: R, useClass: ge, multi: !0 }, k, { provide: ce, useClass: P }, { provide: P, useExisting: ce }, H, { provide: et, useExisting: k }, []], vt = (() => { class n {
    constructor() { }
    static \u0275fac = function (t) { return new (t || n); };
    static \u0275mod = m.\u0275\u0275defineNgModule({ type: n });
    static \u0275inj = m.\u0275\u0275defineInjector({ providers: [...Se, ...ve], imports: [We, qe] });
} return n; })();
import { DOCUMENT as X, \u0275getDOM as Ae } from "@angular/common";
import { \u0275getDOM as Nn } from "@angular/common";
import * as h from "@angular/core";
import { inject as B, \u0275global as Te, ApplicationRef as Ie, \u0275RuntimeError as Z, makeEnvironmentProviders as St, \u0275CACHE_ACTIVE as we, APP_BOOTSTRAP_LISTENER as Tt, \u0275withDomHydration as wt, \u0275withIncrementalHydration as Oe, \u0275withEventReplay as _t, \u0275withI18nSupport as Mt, ENVIRONMENT_INITIALIZER as dn, \u0275IS_ENABLED_BLOCKING_INITIAL_NAVIGATION as un, \u0275Console as fn, \u0275formatRuntimeError as pn, SecurityContext as S, \u0275allowSanitizationBypassAndThrow as C, \u0275unwrapSafeValue as A, \u0275_sanitizeUrl as Rt, \u0275_sanitizeHtml as Dt, \u0275bypassSanitizationTrustHtml as Ct, \u0275bypassSanitizationTrustStyle as At, \u0275bypassSanitizationTrustScript as It, \u0275bypassSanitizationTrustUrl as Ot, \u0275bypassSanitizationTrustResourceUrl as bt, Version as Nt } from "@angular/core";
import { \u0275withHttpTransferCache as be } from "@angular/common/http";
var yn = (() => { class n {
    _doc = B(X);
    _dom = Ae();
    _cachedHead;
    addTag(e, t = !1) { return e ? this._getOrCreateElement(e, t) : null; }
    addTags(e, t = !1) { return e.filter(o => !!o).map(o => this._getOrCreateElement(o, t)); }
    getTag(e) { if (!e)
        return null; let t = this._doc.querySelector(_e(e)); return De(t) ? t : null; }
    getTags(e) { if (!e)
        return []; let t = this._doc.querySelectorAll(_e(e)); return t ? Array.from(t).filter(o => De(o)) : []; }
    updateTag(e, t) { t ??= Re(e); let o = this.getTag(t); return o ? (Me(e, o), o) : this._getOrCreateElement(e, !0); }
    removeTag(e) { this.removeTagElement(this.getTag(e)); }
    removeTagElement(e) { e && this._dom.remove(e); }
    _getOrCreateElement(e, t = !1) { if (!t) {
        let i = Re(e), a = this.getTags(i).filter(l => Ht(e, l))[0];
        if (a !== void 0)
            return a;
    } let o = this._dom.createElement("meta"); return Me(e, o), this._doc.getElementsByTagName("head")[0].appendChild(o), o; }
    static \u0275fac = function (t) { return new (t || n); };
    static \u0275prov = h.\u0275\u0275defineService({ token: n, factory: n.\u0275fac });
} return n; })();
function _e(n) { return `meta[${n}]`; }
function Me(n, r) { Object.keys(n).forEach(e => r.setAttribute(Ne(e), n[e])); }
function Re(n) { let r = n.name ? "name" : "property"; return `${r}=${Lt(String(n[r]))}`; }
function Lt(n) { return `"${n.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`; }
function Ht(n, r) { return Object.keys(n).every(e => r.getAttribute(Ne(e)) === n[e]); }
function Ne(n) { return Pt[n] || n; }
function De(n) { return n?.nodeName.toLowerCase() === "meta"; }
var Pt = { httpEquiv: "http-equiv" }, En = (() => { class n {
    _doc;
    constructor(e) { this._doc = e; }
    getTitle() { return this._doc.title; }
    setTitle(e) { this._doc.title = e || ""; }
    static \u0275fac = function (t) { return new (t || n)(h.\u0275\u0275inject(X)); };
    static \u0275prov = h.\u0275\u0275defineInjectable({ token: n, factory: n.\u0275fac, providedIn: "root" });
} return n; })();
function Le(n, r) { if (typeof COMPILED > "u" || !COMPILED) {
    let e = Te.ng = Te.ng || {};
    e[n] = r;
} }
var W = class {
    msPerTick;
    numTicks;
    constructor(r, e) { this.msPerTick = r, this.numTicks = e; }
}, J = class {
    appRef;
    constructor(r) { this.appRef = r.injector.get(Ie); }
    timeChangeDetection(r) { let e = r && r.record, t = "Change Detection"; e && "profile" in console && typeof console.profile == "function" && console.profile(t); let o = performance.now(), s = 0; for (; s < 5 || performance.now() - o < 500;)
        this.appRef.tick(), s++; let i = performance.now(); e && "profileEnd" in console && typeof console.profileEnd == "function" && console.profileEnd(t); let a = (i - o) / s; return console.log(`ran ${s} change detection cycles`), console.log(`${a.toFixed(2)} ms per check`), new W(a, s); }
}, He = "profiler";
function vn(n) { return Le(He, new J(n)), n; }
function Sn() { Le(He, null); }
var Ce = class {
    static all() { return () => !0; }
    static css(r) { return e => e.nativeElement != null ? kt(e.nativeElement, r) : !1; }
    static directive(r) { return e => e.providerTokens.indexOf(r) !== -1; }
};
function kt(n, r) { return Ae().isElementNode(n) ? n.matches && n.matches(r) || n.msMatchesSelector && n.msMatchesSelector(r) || n.webkitMatchesSelector && n.webkitMatchesSelector(r) : !1; }
var u = (function (n) { return n[n.NoHttpTransferCache = 0] = "NoHttpTransferCache", n[n.HttpTransferCacheOptions = 1] = "HttpTransferCacheOptions", n[n.I18nSupport = 2] = "I18nSupport", n[n.EventReplay = 3] = "EventReplay", n[n.IncrementalHydration = 4] = "IncrementalHydration", n[n.NoIncrementalHydration = 5] = "NoIncrementalHydration", n; })(u || {});
function T(n, r = [], e = {}) { return { \u0275kind: n, \u0275providers: r }; }
function Tn() { return T(u.NoHttpTransferCache); }
function wn(n) { return T(u.HttpTransferCacheOptions, be(n)); }
function _n() { return T(u.I18nSupport, Mt()); }
function Mn() { return T(u.EventReplay, _t()); }
function Rn() { return T(u.IncrementalHydration, Oe()); }
function Dn() { return T(u.NoIncrementalHydration); }
function Cn(...n) { let r = [], e = new Set; for (let { \u0275providers: o, \u0275kind: s } of n)
    e.add(s), o.length && r.push(o); let t = e.has(u.HttpTransferCacheOptions); return St([[], [], wt(), e.has(u.NoHttpTransferCache) || t ? [] : be({}), e.has(u.NoIncrementalHydration) ? [] : Oe(), r, { provide: we, useValue: { isActive: !0 } }, { provide: Tt, multi: !0, useFactory: () => { let o = B(Ie), s = B(we); return () => { o.whenStable().then(() => { s.isActive = !1; }); }; } }]); }
var Ut = (() => { class n {
    static \u0275fac = function (t) { return new (t || n); };
    static \u0275prov = h.\u0275\u0275defineInjectable({ token: n, factory: function (t) { let o = null; return t ? o = new (t || n) : o = h.\u0275\u0275inject(xt), o; }, providedIn: "root" });
} return n; })(), xt = (() => { class n extends Ut {
    _doc = B(X);
    sanitize(e, t) { if (t == null)
        return null; switch (e) {
        case S.NONE: return t;
        case S.HTML: return C(t, "HTML") ? A(t) : Dt(this._doc, String(t)).toString();
        case S.STYLE: return C(t, "Style") ? A(t) : t;
        case S.SCRIPT:
            if (C(t, "Script"))
                return A(t);
            throw new Z(5200, !1);
        case S.URL: return C(t, "URL") ? A(t) : Rt(String(t));
        case S.RESOURCE_URL:
            if (C(t, "ResourceURL"))
                return A(t);
            throw new Z(-5201, !1);
        default: throw new Z(5202, !1);
    } }
    bypassSecurityTrustHtml(e) { return Ct(e); }
    bypassSecurityTrustStyle(e) { return At(e); }
    bypassSecurityTrustScript(e) { return It(e); }
    bypassSecurityTrustUrl(e) { return Ot(e); }
    bypassSecurityTrustResourceUrl(e) { return bt(e); }
    static \u0275fac = function (t) { return new (t || n); };
    static \u0275prov = h.\u0275\u0275defineService({ token: n, factory: n.\u0275fac });
} return n; })(), An = new Nt("22.0.7");
export { vt as BrowserModule, Ce as By, Ut as DomSanitizer, R as EVENT_MANAGER_PLUGINS, H as EventManager, v as EventManagerPlugin, u as HydrationFeatureKind, yn as Meta, ie as REMOVE_STYLES_ON_COMPONENT_DESTROY, En as Title, An as VERSION, ft as bootstrapApplication, pt as createApplication, Sn as disableDebugTools, vn as enableDebugTools, Et as platformBrowser, Cn as provideClientHydration, ht as provideProtractorTestingSupport, Mn as withEventReplay, wn as withHttpTransferCacheOptions, _n as withI18nSupport, Rn as withIncrementalHydration, Tn as withNoHttpTransferCache, Dn as withNoIncrementalHydration, U as \u0275BrowserDomAdapter, x as \u0275BrowserGetTestability, w as \u0275DomEventsPlugin, k as \u0275DomRendererFactory2, xt as \u0275DomSanitizerImpl, ge as \u0275KeyEventsPlugin, P as \u0275SharedStylesHost, Nn as \u0275getDOM };
/*! Bundled license information:

@angular/platform-browser/fesm2022/_dom_renderer-chunk.mjs:
@angular/platform-browser/fesm2022/_browser-chunk.mjs:
@angular/platform-browser/fesm2022/platform-browser.mjs:
  (**
   * @license Angular v22.0.7
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
