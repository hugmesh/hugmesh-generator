import { a as I, b as q, d as B } from "@nf-internal/chunk-PZNONLPT";
import { \u0275DomAdapter as Ve, \u0275setRootDomAdapter as Fe, \u0275parseCookieValue as ze, \u0275getDOM as fe, DOCUMENT as pe, CommonModule as $e, \u0275PLATFORM_BROWSER_ID as Ge } from "@angular/common";
import * as m from "@angular/core";
import { \u0275global as g, \u0275RuntimeError as Ye, InjectionToken as $t, ApplicationModule as Ke, \u0275INJECTOR_SCOPE as Ze, ErrorHandler as he, \u0275SHARED_STYLES_HOST as ce, RendererFactory2 as We, \u0275TESTABILITY_GETTER as G, NgZone as le, TestabilityRegistry as de, Testability as Y, \u0275TESTABILITY as Je, \u0275internalCreateApplication as me, createPlatformFactory as Xe, platformCore as qe, PLATFORM_ID as Qe, PLATFORM_INITIALIZER as et, \u0275USE_PENDING_TASKS as tt, \u0275resolveComponentResources as Gt, \u0275setDocument as nt } from "@angular/core";
import { DOCUMENT as z, \u0275getDOM as Oe } from "@angular/common";
import * as c from "@angular/core";
import { InjectionToken as ne, \u0275RuntimeError as V, APP_ID as re, CSP_NONCE as oe, PLATFORM_ID as be, ViewEncapsulation as E, \u0275SHARED_STYLES_HOST as Ne, \u0275TracingService as Le, RendererStyleFlags2 as O, \u0275allLeavingAnimations as He } from "@angular/core";
var v = class {
    _doc;
    constructor(n) { this._doc = n; }
    manager;
}, _ = (() => { class r extends v {
    constructor(e) { super(e); }
    supports(e) { return !0; }
    addEventListener(e, t, o, s) { return e.addEventListener(t, o, s), () => this.removeEventListener(e, t, o, s); }
    removeEventListener(e, t, o, s) { return e.removeEventListener(t, o, s); }
    static \u0275fac = function (t) { return new (t || r)(c.\u0275\u0275inject(z)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac });
} return r; })(), R = new ne(""), H = (() => { class r {
    _zone;
    _plugins;
    _eventNameToPlugin = new Map;
    constructor(e, t) { this._zone = t, e.forEach(i => { i.manager = this; }); let o = e.filter(i => !(i instanceof _)); this._plugins = o.slice().reverse(); let s = e.find(i => i instanceof _); s && this._plugins.push(s); }
    addEventListener(e, t, o, s) { return this._findPluginFor(t).addEventListener(e, t, o, s); }
    getZone() { return this._zone; }
    _findPluginFor(e) { let t = this._eventNameToPlugin.get(e); if (t)
        return t; if (t = this._plugins.find(s => s.supports(e)), !t)
        throw new V(5101, !1); return this._eventNameToPlugin.set(e, t), t; }
    static \u0275fac = function (t) { return new (t || r)(c.\u0275\u0275inject(R), c.\u0275\u0275inject(c.NgZone)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac });
} return r; })(), b = "ng-app-id";
function Q(r) { for (let n of r)
    n.remove(); }
function ee(r, n) { let e = n.createElement("style"); return e.textContent = r, e; }
function Pe(r, n, e, t) { let o = r.head?.querySelectorAll(`style[${b}="${n}"],link[${b}="${n}"]`); if (!o || o.length === 0)
    return !1; for (let s of o)
    s.removeAttribute(b), s instanceof HTMLLinkElement ? t.set(s.href.slice(s.href.lastIndexOf("/") + 1), { usage: 0, elements: [s] }) : s.textContent && e.set(s.textContent, { usage: 0, elements: [s] }); return !0; }
function F(r, n) { let e = n.createElement("link"); return e.setAttribute("rel", "stylesheet"), e.setAttribute("href", r), e; }
var P = (() => { class r {
    doc;
    appId;
    nonce;
    inline = new Map;
    external = new Map;
    hosts = new Set;
    constructor(e, t, o, s = {}) { this.doc = e, this.appId = t, this.nonce = o, Pe(e, t, this.inline, this.external) && this.hosts.add(e.head); }
    addStyles(e, t) { for (let o of e)
        this.addUsage(o, this.inline, ee); t?.forEach(o => this.addUsage(o, this.external, F)); }
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
            o.push(this.addElement(e, F(t, this.doc)));
    } }
    removeHost(e) { this.hosts.delete(e); for (let t of [...this.inline.values(), ...this.external.values()]) {
        let o = [];
        for (let s of t.elements)
            s.parentNode === e ? s.remove() : o.push(s);
        t.elements = o;
    } }
    addElement(e, t) { return this.nonce && t.setAttribute("nonce", this.nonce), typeof ngServerMode < "u" && ngServerMode && t.setAttribute(b, this.appId), e.appendChild(t); }
    static \u0275fac = function (t) { return new (t || r)(c.\u0275\u0275inject(z), c.\u0275\u0275inject(re), c.\u0275\u0275inject(oe, 8), c.\u0275\u0275inject(be)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac });
} return r; })(), j = { svg: "http://www.w3.org/2000/svg", xhtml: "http://www.w3.org/1999/xhtml", xlink: "http://www.w3.org/1999/xlink", xml: "http://www.w3.org/XML/1998/namespace", xmlns: "http://www.w3.org/2000/xmlns/", math: "http://www.w3.org/1998/Math/MathML" }, $ = /%COMP%/g;
var se = "%COMP%", ke = `_nghost-${se}`, Ue = `_ngcontent-${se}`, xe = !0, ie = new ne("", { factory: () => xe });
function Be(r) { return Ue.replace($, r); }
function je(r) { return ke.replace($, r); }
function ae(r, n) { return n.map(e => e.replace($, r)); }
var k = (() => { class r {
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
    constructor(e, t, o, s, i, a, l = null, d = null) { this.eventManager = e, this.sharedStylesHost = t, this.appId = o, this.removeStylesOnCompDestroy = s, this.doc = i, this.ngZone = a, this.nonce = l, this.tracingService = d, this.defaultRenderer = new w(e, i, a, this.tracingService); }
    createRenderer(e, t) { if (!e || !t)
        return this.defaultRenderer; typeof ngServerMode < "u" && ngServerMode && (t.encapsulation === E.ShadowDom || t.encapsulation === E.ExperimentalIsolatedShadowDom) && (t = q(I({}, t), { encapsulation: E.Emulated })); let o = this.getOrCreateRenderer(e, t); return o instanceof L ? o.applyToHost(e) : o instanceof M && o.applyStyles(), o; }
    getOrCreateRenderer(e, t) { let o = this.rendererByCompId, s = o.get(t.id); if (!s) {
        let i = this.doc, a = this.ngZone, l = this.eventManager, d = this.sharedStylesHost, p = this.removeStylesOnCompDestroy, h = this.tracingService;
        switch (t.encapsulation) {
            case E.Emulated:
                s = new L(l, d, t, this.appId, p, i, a, h);
                break;
            case E.ShadowDom: return new N(l, e, t, i, a, this.nonce, h, d);
            case E.ExperimentalIsolatedShadowDom: return new N(l, e, t, i, a, this.nonce, h);
            default:
                s = new M(l, d, t, p, i, a, h);
                break;
        }
        o.set(t.id, s);
    } return s; }
    ngOnDestroy() { this.rendererByCompId.clear(); }
    componentReplaced(e) { this.rendererByCompId.delete(e); }
    static \u0275fac = function (t) { return new (t || r)(c.\u0275\u0275inject(H), c.\u0275\u0275inject(Ne), c.\u0275\u0275inject(re), c.\u0275\u0275inject(ie), c.\u0275\u0275inject(z), c.\u0275\u0275inject(c.NgZone), c.\u0275\u0275inject(oe), c.\u0275\u0275inject(Le, 8)); };
    static \u0275prov = c.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac });
} return r; })(), w = class {
    eventManager;
    doc;
    ngZone;
    tracingService;
    data = Object.create(null);
    throwOnSyntheticProps = !0;
    constructor(n, e, t, o) { this.eventManager = n, this.doc = e, this.ngZone = t, this.tracingService = o; }
    destroy() { }
    destroyNode = null;
    createElement(n, e) { return e ? this.doc.createElementNS(j[e] || e, n) : this.doc.createElement(n); }
    createComment(n) { return this.doc.createComment(n); }
    createText(n) { return this.doc.createTextNode(n); }
    appendChild(n, e) { (te(n) ? n.content : n).appendChild(e); }
    insertBefore(n, e, t) { n && (te(n) ? n.content : n).insertBefore(e, t); }
    removeChild(n, e) { e.remove(); }
    selectRootElement(n, e) { let t = typeof n == "string" ? this.doc.querySelector(n) : n; if (!t)
        throw new V(-5104, !1); return e || (t.textContent = ""), t; }
    parentNode(n) { return n.parentNode; }
    nextSibling(n) { return n.nextSibling; }
    setAttribute(n, e, t, o) { if (o) {
        e = o + ":" + e;
        let s = j[o];
        s ? n.setAttributeNS(s, e, t) : n.setAttribute(e, t);
    }
    else
        n.setAttribute(e, t); }
    removeAttribute(n, e, t) { if (t) {
        let o = j[t];
        o ? n.removeAttributeNS(o, e) : n.removeAttribute(`${t}:${e}`);
    }
    else
        n.removeAttribute(e); }
    addClass(n, e) { n.classList.add(e); }
    removeClass(n, e) { n.classList.remove(e); }
    setStyle(n, e, t, o) { o & (O.DashCase | O.Important) ? n.style.setProperty(e, t, o & O.Important ? "important" : "") : n.style[e] = t; }
    removeStyle(n, e, t) { t & O.DashCase ? n.style.removeProperty(e) : n.style[e] = ""; }
    setProperty(n, e, t) { n != null && (n[e] = t); }
    setValue(n, e) { n.nodeValue = e; }
    listen(n, e, t, o) { if (typeof n == "string" && (n = Oe().getGlobalEventTarget(this.doc, n), !n))
        throw new V(5102, !1); let s = this.decoratePreventDefault(t); return this.tracingService?.wrapEventListener && (s = this.tracingService.wrapEventListener(n, e, s)), this.eventManager.addEventListener(n, e, s, o); }
    decoratePreventDefault(n) { return e => { if (e === "__ngUnwrap__")
        return n; (typeof ngServerMode < "u" && ngServerMode ? this.ngZone.runGuarded(() => n(e)) : n(e)) === !1 && e.preventDefault(); }; }
};
function te(r) { return r.tagName === "TEMPLATE" && r.content !== void 0; }
var N = class extends w {
    hostEl;
    sharedStylesHost;
    shadowRoot;
    constructor(n, e, t, o, s, i, a, l) { super(n, o, s, a), this.hostEl = e, this.sharedStylesHost = l, this.shadowRoot = e.attachShadow({ mode: "open" }), this.sharedStylesHost && this.sharedStylesHost.addHost(this.shadowRoot); let d = t.styles; d = ae(t.id, d); for (let h of d) {
        let y = document.createElement("style");
        i && y.setAttribute("nonce", i), y.textContent = h, this.shadowRoot.appendChild(y);
    } let p = t.getExternalStyles?.(); if (p)
        for (let h of p) {
            let y = F(h, o);
            i && y.setAttribute("nonce", i), this.shadowRoot.appendChild(y);
        } }
    nodeOrShadowRoot(n) { return n === this.hostEl ? this.shadowRoot : n; }
    appendChild(n, e) { return super.appendChild(this.nodeOrShadowRoot(n), e); }
    insertBefore(n, e, t) { return super.insertBefore(this.nodeOrShadowRoot(n), e, t); }
    removeChild(n, e) { return super.removeChild(null, e); }
    parentNode(n) { return this.nodeOrShadowRoot(super.parentNode(this.nodeOrShadowRoot(n))); }
    destroy() { this.sharedStylesHost && this.sharedStylesHost.removeHost(this.shadowRoot); }
}, M = class extends w {
    sharedStylesHost;
    removeStylesOnCompDestroy;
    styles;
    styleUrls;
    constructor(n, e, t, o, s, i, a, l) { super(n, s, i, a), this.sharedStylesHost = e, this.removeStylesOnCompDestroy = o; let d = t.styles; this.styles = l ? ae(l, d) : d, this.styleUrls = t.getExternalStyles?.(l); }
    applyStyles() { this.sharedStylesHost.addStyles(this.styles, this.styleUrls); }
    destroy() { this.removeStylesOnCompDestroy && He.size === 0 && this.sharedStylesHost.removeStyles(this.styles, this.styleUrls); }
}, L = class extends M {
    contentAttr;
    hostAttr;
    constructor(n, e, t, o, s, i, a, l) { let d = o + "-" + t.id; super(n, e, t, s, i, a, l, d), this.contentAttr = Be(d), this.hostAttr = je(d); }
    applyToHost(n) { this.applyStyles(), this.setAttribute(n, this.hostAttr, ""); }
    createElement(n, e) { let t = super.createElement(n, e); return super.setAttribute(t, this.contentAttr, ""), t; }
};
var U = class r extends Ve {
    supportsDOMEvents = !0;
    static makeCurrent() { Fe(new r); }
    onAndCancel(n, e, t, o) { return n.addEventListener(e, t, o), () => { n.removeEventListener(e, t, o); }; }
    dispatchEvent(n, e) { n.dispatchEvent(e); }
    remove(n) { n.remove(); }
    createElement(n, e) { return e = e || this.getDefaultDocument(), e.createElement(n); }
    createHtmlDocument() { return document.implementation.createHTMLDocument("fakeTitle"); }
    getDefaultDocument() { return document; }
    isElementNode(n) { return n.nodeType === Node.ELEMENT_NODE; }
    isShadowRoot(n) { return n instanceof DocumentFragment; }
    getGlobalEventTarget(n, e) { return e === "window" ? window : e === "document" ? n : e === "body" ? n.body : null; }
    getBaseHref(n) { let e = rt(); return e == null ? null : ot(e); }
    resetBaseElement() { D = null; }
    getUserAgent() { return window.navigator.userAgent; }
    getCookie(n) { return ze(document.cookie, n); }
}, D = null;
function rt() { return D = D || document.head.querySelector("base"), D ? D.getAttribute("href") : null; }
function ot(r) { return new URL(r, document.baseURI).pathname; }
var x = class {
    addToWindow(n) { g.getAngularTestability = (t, o = !0) => { let s = n.findTestabilityInTree(t, o); if (s == null)
        throw new Ye(5103, !1); return s; }, g.getAllAngularTestabilities = () => n.getAllTestabilities(), g.getAllAngularRootElements = () => n.getAllRootElements(); let e = t => { let o = g.getAllAngularTestabilities(), s = o.length, i = function () { s--, s == 0 && t(); }; o.forEach(a => { a.whenStable(i); }); }; g.frameworkStabilizers || (g.frameworkStabilizers = []), g.frameworkStabilizers.push(e); }
    findTestabilityInTree(n, e, t) { if (e == null)
        return null; let o = n.getTestability(e); return o ?? (t ? fe().isShadowRoot(e) ? this.findTestabilityInTree(n, e.host, !0) : this.findTestabilityInTree(n, e.parentElement, !0) : null); }
}, ue = ["alt", "control", "meta", "shift"], st = { "\b": "Backspace", "	": "Tab", "\x7F": "Delete", "\x1B": "Escape", Del: "Delete", Esc: "Escape", Left: "ArrowLeft", Right: "ArrowRight", Up: "ArrowUp", Down: "ArrowDown", Menu: "ContextMenu", Scroll: "ScrollLock", Win: "OS" }, it = { alt: r => r.altKey, control: r => r.ctrlKey, meta: r => r.metaKey, shift: r => r.shiftKey }, ge = (() => { class r extends v {
    constructor(e) { super(e); }
    supports(e) { return r.parseEventName(e) != null; }
    addEventListener(e, t, o, s) { let i = r.parseEventName(t), a = r.eventCallback(i.fullKey, o, this.manager.getZone()); return this.manager.getZone().runOutsideAngular(() => fe().onAndCancel(e, i.domEventName, a, s)); }
    static parseEventName(e) { let t = e.toLowerCase().split("."), o = t.shift(); if (t.length === 0 || !(o === "keydown" || o === "keyup"))
        return null; let s = r._normalizeKey(t.pop()), i = "", a = t.indexOf("code"); if (a > -1 && (t.splice(a, 1), i = "code."), ue.forEach(d => { let p = t.indexOf(d); p > -1 && (t.splice(p, 1), i += d + "."); }), i += s, t.length != 0 || s.length === 0)
        return null; let l = {}; return l.domEventName = o, l.fullKey = i, l; }
    static matchEventFullKeyCode(e, t) { let o = st[e.key] || e.key, s = ""; return t.indexOf("code.") > -1 && (o = e.code, s = "code."), o == null || !o ? !1 : (o = o.toLowerCase(), o === " " ? o = "space" : o === "." && (o = "dot"), ue.forEach(i => { if (i !== o) {
        let a = it[i];
        a(e) && (s += i + ".");
    } }), s += o, s === t); }
    static eventCallback(e, t, o) { return s => { r.matchEventFullKeyCode(s, e) && o.runGuarded(() => t(s)); }; }
    static _normalizeKey(e) { return e === "esc" ? "escape" : e; }
    static \u0275fac = function (t) { return new (t || r)(m.\u0275\u0275inject(pe)); };
    static \u0275prov = m.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac });
} return r; })();
function at(r, n, e) { return B(this, null, function* () { let t = I({ rootComponent: r }, ye(n, e)); return me(t); }); }
function ct(r, n) { return B(this, null, function* () { return me(ye(r, n)); }); }
function ye(r, n) { return { platformRef: n?.platformRef, appProviders: [...Se, ...r?.providers ?? []], platformProviders: Ee }; }
function lt(r = {}) { return [...ve, r?.usePendingTasksForStability !== void 0 ? { provide: tt, useValue: r.usePendingTasksForStability ?? !1 } : []]; }
function dt() { U.makeCurrent(); }
function ut() { return new he; }
function ft() { return nt(document), document; }
var Ee = [{ provide: Qe, useValue: Ge }, { provide: et, useValue: dt, multi: !0 }, { provide: pe, useFactory: ft }], pt = Xe(qe, "browser", Ee);
var ve = [{ provide: G, useClass: x }, { provide: Je, useClass: Y, deps: [le, de, G] }, { provide: Y, useClass: Y, deps: [le, de, G] }], Se = [{ provide: Ze, useValue: "root" }, { provide: he, useFactory: ut }, { provide: R, useClass: _, multi: !0 }, { provide: R, useClass: ge, multi: !0 }, k, { provide: ce, useClass: P }, { provide: P, useExisting: ce }, H, { provide: We, useExisting: k }, []], ht = (() => { class r {
    constructor() { }
    static \u0275fac = function (t) { return new (t || r); };
    static \u0275mod = m.\u0275\u0275defineNgModule({ type: r });
    static \u0275inj = m.\u0275\u0275defineInjector({ providers: [...Se, ...ve], imports: [$e, Ke] });
} return r; })();
import { \u0275getDOM as Me, DOCUMENT as X } from "@angular/common";
import { \u0275getDOM as Rn } from "@angular/common";
import * as f from "@angular/core";
import { \u0275global as Te, ApplicationRef as Re, \u0275RuntimeError as K, makeEnvironmentProviders as mt, \u0275CACHE_ACTIVE as _e, APP_BOOTSTRAP_LISTENER as gt, \u0275withDomHydration as yt, \u0275withIncrementalHydration as De, inject as Z, \u0275withEventReplay as Et, \u0275withI18nSupport as vt, ENVIRONMENT_INITIALIZER as tn, \u0275IS_ENABLED_BLOCKING_INITIAL_NAVIGATION as nn, \u0275Console as rn, \u0275formatRuntimeError as on, SecurityContext as S, \u0275allowSanitizationBypassAndThrow as C, \u0275unwrapSafeValue as A, \u0275_sanitizeUrl as St, \u0275_sanitizeHtml as Tt, \u0275bypassSanitizationTrustHtml as _t, \u0275bypassSanitizationTrustStyle as wt, \u0275bypassSanitizationTrustScript as Mt, \u0275bypassSanitizationTrustUrl as Rt, \u0275bypassSanitizationTrustResourceUrl as Dt, Version as Ct } from "@angular/core";
import { \u0275withHttpTransferCache as Ce } from "@angular/common/http";
var dn = (() => { class r {
    _doc;
    _dom;
    constructor(e) { this._doc = e, this._dom = Me(); }
    addTag(e, t = !1) { return e ? this._getOrCreateElement(e, t) : null; }
    addTags(e, t = !1) { return e ? e.reduce((o, s) => (s && o.push(this._getOrCreateElement(s, t)), o), []) : []; }
    getTag(e) { if (!e)
        return null; let t = this._doc.querySelector(`meta[${e}]`); return t?.nodeName.toLowerCase() === "meta" ? t : null; }
    getTags(e) { if (!e)
        return []; let t = this._doc.querySelectorAll(`meta[${e}]`); return t ? [].slice.call(t).filter(o => o.nodeName.toLowerCase() === "meta") : []; }
    updateTag(e, t) { if (!e)
        return null; t = t || this._parseSelector(e); let o = this.getTag(t); return o ? this._setMetaElementAttributes(e, o) : this._getOrCreateElement(e, !0); }
    removeTag(e) { this.removeTagElement(this.getTag(e)); }
    removeTagElement(e) { e && this._dom.remove(e); }
    _getOrCreateElement(e, t = !1) { if (!t) {
        let i = this._parseSelector(e), a = this.getTags(i).filter(l => this._containsAttributes(e, l))[0];
        if (a !== void 0)
            return a;
    } let o = this._dom.createElement("meta"); return this._setMetaElementAttributes(e, o), this._doc.getElementsByTagName("head")[0].appendChild(o), o; }
    _setMetaElementAttributes(e, t) { return Object.keys(e).forEach(o => t.setAttribute(this._getMetaKeyMap(o), e[o])), t; }
    _parseSelector(e) { let t = e.name ? "name" : "property"; return `${t}=${this._escapeSelectorValue(String(e[t]))}`; }
    _escapeSelectorValue(e) { return `"${e.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`; }
    _containsAttributes(e, t) { return Object.keys(e).every(o => t.getAttribute(this._getMetaKeyMap(o)) === e[o]); }
    _getMetaKeyMap(e) { return At[e] || e; }
    static \u0275fac = function (t) { return new (t || r)(f.\u0275\u0275inject(X)); };
    static \u0275prov = f.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac, providedIn: "root" });
} return r; })(), At = { httpEquiv: "http-equiv" }, un = (() => { class r {
    _doc;
    constructor(e) { this._doc = e; }
    getTitle() { return this._doc.title; }
    setTitle(e) { this._doc.title = e || ""; }
    static \u0275fac = function (t) { return new (t || r)(f.\u0275\u0275inject(X)); };
    static \u0275prov = f.\u0275\u0275defineInjectable({ token: r, factory: r.\u0275fac, providedIn: "root" });
} return r; })();
function Ae(r, n) { if (typeof COMPILED > "u" || !COMPILED) {
    let e = Te.ng = Te.ng || {};
    e[r] = n;
} }
var W = class {
    msPerTick;
    numTicks;
    constructor(n, e) { this.msPerTick = n, this.numTicks = e; }
}, J = class {
    appRef;
    constructor(n) { this.appRef = n.injector.get(Re); }
    timeChangeDetection(n) { let e = n && n.record, t = "Change Detection"; e && "profile" in console && typeof console.profile == "function" && console.profile(t); let o = performance.now(), s = 0; for (; s < 5 || performance.now() - o < 500;)
        this.appRef.tick(), s++; let i = performance.now(); e && "profileEnd" in console && typeof console.profileEnd == "function" && console.profileEnd(t); let a = (i - o) / s; return console.log(`ran ${s} change detection cycles`), console.log(`${a.toFixed(2)} ms per check`), new W(a, s); }
}, Ie = "profiler";
function fn(r) { return Ae(Ie, new J(r)), r; }
function pn() { Ae(Ie, null); }
var we = class {
    static all() { return () => !0; }
    static css(n) { return e => e.nativeElement != null ? It(e.nativeElement, n) : !1; }
    static directive(n) { return e => e.providerTokens.indexOf(n) !== -1; }
};
function It(r, n) { return Me().isElementNode(r) ? r.matches && r.matches(n) || r.msMatchesSelector && r.msMatchesSelector(n) || r.webkitMatchesSelector && r.webkitMatchesSelector(n) : !1; }
var u = (function (r) { return r[r.NoHttpTransferCache = 0] = "NoHttpTransferCache", r[r.HttpTransferCacheOptions = 1] = "HttpTransferCacheOptions", r[r.I18nSupport = 2] = "I18nSupport", r[r.EventReplay = 3] = "EventReplay", r[r.IncrementalHydration = 4] = "IncrementalHydration", r[r.NoIncrementalHydration = 5] = "NoIncrementalHydration", r; })(u || {});
function T(r, n = [], e = {}) { return { \u0275kind: r, \u0275providers: n }; }
function hn() { return T(u.NoHttpTransferCache); }
function mn(r) { return T(u.HttpTransferCacheOptions, Ce(r)); }
function gn() { return T(u.I18nSupport, vt()); }
function yn() { return T(u.EventReplay, Et()); }
function En() { return T(u.IncrementalHydration, De()); }
function vn() { return T(u.NoIncrementalHydration); }
function Sn(...r) { let n = [], e = new Set; for (let { \u0275providers: o, \u0275kind: s } of r)
    e.add(s), o.length && n.push(o); let t = e.has(u.HttpTransferCacheOptions); return mt([[], [], yt(), e.has(u.NoHttpTransferCache) || t ? [] : Ce({}), e.has(u.NoIncrementalHydration) ? [] : De(), n, { provide: _e, useValue: { isActive: !0 } }, { provide: gt, multi: !0, useFactory: () => { let o = Z(Re), s = Z(_e); return () => { o.whenStable().then(() => { s.isActive = !1; }); }; } }]); }
var Ot = (() => { class r {
    static \u0275fac = function (t) { return new (t || r); };
    static \u0275prov = f.\u0275\u0275defineInjectable({ token: r, factory: function (t) { let o = null; return t ? o = new (t || r) : o = f.\u0275\u0275inject(bt), o; }, providedIn: "root" });
} return r; })(), bt = (() => { class r extends Ot {
    _doc = Z(X);
    sanitize(e, t) { if (t == null)
        return null; switch (e) {
        case S.NONE: return t;
        case S.HTML: return C(t, "HTML") ? A(t) : Tt(this._doc, String(t)).toString();
        case S.STYLE: return C(t, "Style") ? A(t) : t;
        case S.SCRIPT:
            if (C(t, "Script"))
                return A(t);
            throw new K(5200, !1);
        case S.URL: return C(t, "URL") ? A(t) : St(String(t));
        case S.RESOURCE_URL:
            if (C(t, "ResourceURL"))
                return A(t);
            throw new K(5201, !1);
        default: throw new K(5202, !1);
    } }
    bypassSecurityTrustHtml(e) { return _t(e); }
    bypassSecurityTrustStyle(e) { return wt(e); }
    bypassSecurityTrustScript(e) { return Mt(e); }
    bypassSecurityTrustUrl(e) { return Rt(e); }
    bypassSecurityTrustResourceUrl(e) { return Dt(e); }
    static \u0275fac = function (t) { return new (t || r); };
    static \u0275prov = f.\u0275\u0275defineService({ token: r, factory: r.\u0275fac });
} return r; })(), Tn = new Ct("22.0.2");
export { ht as BrowserModule, we as By, Ot as DomSanitizer, R as EVENT_MANAGER_PLUGINS, H as EventManager, v as EventManagerPlugin, u as HydrationFeatureKind, dn as Meta, ie as REMOVE_STYLES_ON_COMPONENT_DESTROY, un as Title, Tn as VERSION, at as bootstrapApplication, ct as createApplication, pn as disableDebugTools, fn as enableDebugTools, pt as platformBrowser, Sn as provideClientHydration, lt as provideProtractorTestingSupport, yn as withEventReplay, mn as withHttpTransferCacheOptions, gn as withI18nSupport, En as withIncrementalHydration, hn as withNoHttpTransferCache, vn as withNoIncrementalHydration, U as \u0275BrowserDomAdapter, x as \u0275BrowserGetTestability, _ as \u0275DomEventsPlugin, k as \u0275DomRendererFactory2, bt as \u0275DomSanitizerImpl, ge as \u0275KeyEventsPlugin, P as \u0275SharedStylesHost, Rn as \u0275getDOM };
/*! Bundled license information:

@angular/platform-browser/fesm2022/_dom_renderer-chunk.mjs:
@angular/platform-browser/fesm2022/_browser-chunk.mjs:
@angular/platform-browser/fesm2022/platform-browser.mjs:
  (**
   * @license Angular v22.0.2
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
