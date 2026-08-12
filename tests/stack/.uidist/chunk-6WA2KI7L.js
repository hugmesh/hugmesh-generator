import * as s from "@angular/core";
import { InjectionToken as f, inject as d, DOCUMENT as u } from "@angular/core";
var l = null;
function a() { return l; }
function w(t) { l ??= t; }
var c = class {
}, p = (() => { class t {
    historyGo(e) { throw new Error(""); }
    static \u0275fac = function (o) { return new (o || t); };
    static \u0275prov = s.\u0275\u0275defineInjectable({ token: t, factory: () => d(v), providedIn: "platform" });
} return t; })(), I = new f(""), v = (() => { class t extends p {
    _location;
    _history;
    _doc = d(u);
    constructor() { super(), this._location = window.location, this._history = window.history; }
    getBaseHrefFromDOM() { return a().getBaseHref(this._doc); }
    onPopState(e) { let o = a().getGlobalEventTarget(this._doc, "window"); return o.addEventListener("popstate", e, !1), () => o.removeEventListener("popstate", e); }
    onHashChange(e) { let o = a().getGlobalEventTarget(this._doc, "window"); return o.addEventListener("hashchange", e, !1), () => o.removeEventListener("hashchange", e); }
    get href() { return this._location.href; }
    get protocol() { return this._location.protocol; }
    get hostname() { return this._location.hostname; }
    get port() { return this._location.port; }
    get pathname() { return this._location.pathname; }
    get search() { return this._location.search; }
    get hash() { return this._location.hash; }
    set pathname(e) { this._location.pathname = e; }
    pushState(e, o, n) { this._history.pushState(e, o, n); }
    replaceState(e, o, n) { this._history.replaceState(e, o, n); }
    forward() { this._history.forward(); }
    back() { this._history.back(); }
    historyGo(e = 0) { this._history.go(e); }
    getState() { return this._history.state; }
    static \u0275fac = function (o) { return new (o || t); };
    static \u0275prov = s.\u0275\u0275defineInjectable({ token: t, factory: () => new t, providedIn: "platform" });
} return t; })();
import * as r from "@angular/core";
import "@angular/core";
function b(t, i) { i = encodeURIComponent(i); for (let e of t.split(";")) {
    let o = e.indexOf("="), [n, h] = o == -1 ? [e, ""] : [e.slice(0, o), e.slice(o + 1)];
    if (n.trim() === i)
        return decodeURIComponent(h);
} return null; }
var g = (() => { class t {
    build() { return new XMLHttpRequest; }
    static \u0275fac = function (o) { return new (o || t); };
    static \u0275prov = r.\u0275\u0275defineService({ token: t, factory: t.\u0275fac });
} return t; })(), E = (() => { class t {
    static \u0275fac = function (o) { return new (o || t); };
    static \u0275prov = r.\u0275\u0275defineInjectable({ token: t, factory: function (o) { let n = null; return o ? n = new (o || t) : n = r.\u0275\u0275inject(g), n; }, providedIn: "root" });
} return t; })();
export { a, w as b, c, p as d, I as e, v as f, b as g, E as h };
/*! Bundled license information:

@angular/common/fesm2022/_platform_location-chunk.mjs:
@angular/common/fesm2022/_xhr-chunk.mjs:
  (**
   * @license Angular v22.0.7
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
