import { a as p, b as m } from "@nf-internal/chunk-PZNONLPT";
var i = null, C = !1, l = 1, N = null, S = Symbol("SIGNAL");
function d(e) { let r = i; return i = e, r; }
function H() { return i; }
function J() { return C; }
function Q(e) { return e[S] !== void 0; }
var y = { version: 0, lastCleanEpoch: 0, dirty: !1, producers: void 0, producersTail: void 0, consumers: void 0, consumersTail: void 0, recomputing: !1, consumerAllowSignalWrites: !1, consumerIsAlwaysLive: !1, kind: "unknown", producerMustRecompute: () => !1, producerRecomputeValue: () => { }, consumerMarkedDirty: () => { }, consumerOnSignalRead: () => { } };
function h(e) { if (C)
    throw new Error(""); if (i === null)
    return; i.consumerOnSignalRead(e); let r = i.producersTail; if (r !== void 0 && r.producer === e)
    return; let n, u = i.recomputing; if (u && (n = r !== void 0 ? r.nextProducer : i.producers, n !== void 0 && n.producer === e)) {
    i.producersTail = n, n.lastReadVersion = e.version, n.knownValidAtEpoch = l;
    return;
} let t = e.consumersTail; if (t !== void 0 && t.consumer === i && (!u || t.knownValidAtEpoch === l))
    return; let o = g(i), c = { producer: e, consumer: i, nextProducer: n, prevConsumer: void 0, knownValidAtEpoch: l, lastReadVersion: e.version, nextConsumer: void 0 }; i.producersTail = c, r !== void 0 ? r.nextProducer = c : i.producers = c, o && I(e, c); }
function U() { l++; }
function v(e) { if (!(g(e) && !e.dirty) && !(!e.dirty && e.lastCleanEpoch === l)) {
    if (!e.producerMustRecompute(e) && !L(e)) {
        E(e);
        return;
    }
    e.producerRecomputeValue(e), E(e);
} }
function M(e) { if (e.consumers === void 0)
    return; let r = C; C = !0; try {
    for (let n = e.consumers; n !== void 0; n = n.nextConsumer) {
        let u = n.consumer;
        u.dirty || G(u);
    }
}
finally {
    C = r;
} }
function x() { return i?.consumerAllowSignalWrites !== !1; }
function G(e) { e.dirty = !0, M(e), e.consumerMarkedDirty?.(e); }
function E(e) { e.dirty = !1, e.lastCleanEpoch = l; }
function A(e) { return e && q(e), d(e); }
function q(e) { if (e.producersTail?.knownValidAtEpoch === l) {
    let r = e.producers;
    for (; r !== void 0;)
        r.knownValidAtEpoch = null, r = r.nextProducer;
} e.producersTail = void 0, e.recomputing = !0; }
function T(e, r) { d(r), e && _(e); }
function _(e) { e.recomputing = !1; let r = e.producersTail, n = r !== void 0 ? r.nextProducer : e.producers; if (n !== void 0) {
    if (g(e))
        do
            n = V(n);
        while (n !== void 0);
    r !== void 0 ? r.nextProducer = void 0 : e.producers = void 0;
} }
function L(e) { for (let r = e.producers; r !== void 0; r = r.nextProducer) {
    let n = r.producer, u = r.lastReadVersion;
    if (u !== n.version || (v(n), u !== n.version))
        return !0;
} return !1; }
function X(e) { if (g(e)) {
    let r = e.producers;
    for (; r !== void 0;)
        r = V(r);
} e.producers = void 0, e.producersTail = void 0, e.consumers = void 0, e.consumersTail = void 0; }
function I(e, r) { let n = e.consumersTail, u = g(e); if (n !== void 0 ? (r.nextConsumer = n.nextConsumer, n.nextConsumer = r) : (r.nextConsumer = void 0, e.consumers = r), r.prevConsumer = n, e.consumersTail = r, !u)
    for (let t = e.producers; t !== void 0; t = t.nextProducer)
        I(t.producer, t); }
function V(e) { let r = e.producer, n = e.nextProducer, u = e.nextConsumer, t = e.prevConsumer; if (e.nextConsumer = void 0, e.prevConsumer = void 0, u !== void 0 ? u.prevConsumer = t : r.consumersTail = t, t !== void 0)
    t.nextConsumer = u;
else if (r.consumers = u, !g(r)) {
    let o = r.producers;
    for (; o !== void 0;)
        o = V(o);
} return n; }
function g(e) { return e.consumerIsAlwaysLive || e.consumers !== void 0; }
function D(e) { N?.(e); }
function Y(e) { let r = N; return N = e, r; }
function P(e, r) { return Object.is(e, r); }
function Z(e, r) { let n = Object.create(W); n.computation = e, r !== void 0 && (n.equal = r); let u = () => { if (v(n), h(n), n.value === s)
    throw n.error; return n.value; }; return u[S] = n, D(n), u; }
var a = Symbol("UNSET"), f = Symbol("COMPUTING"), s = Symbol("ERRORED"), W = m(p({}, y), { value: a, dirty: !0, error: null, equal: P, kind: "computed", producerMustRecompute(e) { return e.value === a || e.value === f; }, producerRecomputeValue(e) { if (e.value === f)
        throw new Error(""); let r = e.value; e.value = f; let n = A(e), u, t = !1; try {
        u = e.computation(), d(null), t = r !== a && r !== s && u !== s && e.equal(r, u);
    }
    catch (o) {
        u = s, e.error = o;
    }
    finally {
        T(e, n);
    } if (t) {
        e.value = r;
        return;
    } e.value = u, e.version++; } });
function $() { throw new Error; }
var O = $;
function F(e) { O(e); }
function ee(e) { O = e; }
var w = null;
function re(e, r) { let n = Object.create(B); n.value = e, r !== void 0 && (n.equal = r); let u = () => j(n); return u[S] = n, D(n), [u, c => R(n, c), c => k(n, c)]; }
function ne(e) { let r = w; return w = e, r; }
function j(e) { return h(e), e.value; }
function R(e, r) { x() || F(e), e.equal(e.value, r) || (e.value = r, z(e)); }
function k(e, r) { x() || F(e), R(e, r(e.value)); }
function ue(e) { w?.(e); }
var B = m(p({}, y), { equal: P, value: void 0, kind: "signal" });
function z(e) { e.version++, U(), M(e), w?.(e); }
var te = m(p({}, y), { consumerIsAlwaysLive: !0, consumerAllowSignalWrites: !0, dirty: !0, kind: "effect" });
function oe(e) { if (e.dirty = !1, e.version > 0 && !L(e))
    return; e.version++; let r = A(e); try {
    e.cleanup(), e.fn();
}
finally {
    T(e, r);
} }
function le(e, r, n) { let u = Object.create(K); u.source = e, u.computation = r, n != null && (u.equal = n); let o = () => { if (v(u), h(u), u.value === s)
    throw u.error; return u.value; }; return o[S] = u, D(u), o; }
function ae(e, r) { v(e), R(e, r), E(e); }
function fe(e, r) { if (v(e), e.value === s)
    throw e.error; k(e, r), E(e); }
var K = m(p({}, y), { value: a, dirty: !0, error: null, equal: P, kind: "linkedSignal", producerMustRecompute(e) { return e.value === a || e.value === f; }, producerRecomputeValue(e) { if (e.value === f)
        throw new Error(""); let r = e.value; e.value = f; let n = A(e), u, t = !1; try {
        let o = e.source(), c = r !== a && r !== s, b = c ? { source: e.sourceValue, value: r } : void 0;
        u = e.computation(o, b), e.sourceValue = o, d(null), t = c && u !== s && e.equal(r, u);
    }
    catch (o) {
        u = s, e.error = o;
    }
    finally {
        T(e, n);
    } if (t) {
        e.value = r;
        return;
    } e.value = u, e.version++; } });
function de(e) { let r = d(null); try {
    return e();
}
finally {
    d(r);
} }
function ve(e) { }
export { S as a, d as b, H as c, J as d, Q as e, y as f, h as g, U as h, v as i, M as j, x as k, G as l, E as m, A as n, q as o, T as p, _ as q, L as r, X as s, D as t, Y as u, P as v, Z as w, ee as x, re as y, ne as z, j as A, R as B, k as C, ue as D, B as E, te as F, oe as G, le as H, ae as I, fe as J, de as K, ve as L };
/*! Bundled license information:

@angular/core/fesm2022/_effect-chunk.mjs:
@angular/core/fesm2022/_untracked-chunk.mjs:
@angular/core/fesm2022/_weak_ref-chunk.mjs:
  (**
   * @license Angular v22.0.7
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
