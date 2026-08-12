import { a as c, b as f } from "@nf-internal/chunk-PZNONLPT";
import * as s from "@angular/core";
import { InjectionToken as b, forwardRef as l, \u0275isPromise as ft, \u0275RuntimeError as ne, Version as gt, signal as w, untracked as g, computed as S, EventEmitter as _, booleanAttribute as oe, DestroyRef as Ne, ChangeDetectorRef as ae, effect as pt, inject as I, ApplicationRef as mt, afterNextRender as vt } from "@angular/core";
import { from as _t, forkJoin as yt, Subject as Ct, Subscription as Vt } from "rxjs";
import { map as Dt } from "rxjs/operators";
import { \u0275getDOM as Ce } from "@angular/common";
var Se = (() => { class n {
    _renderer;
    _elementRef;
    onChange = e => { };
    onTouched = () => { };
    constructor(e, i) { this._renderer = e, this._elementRef = i; }
    setProperty(e, i) { this._renderer.setProperty(this._elementRef.nativeElement, e, i); }
    registerOnTouched(e) { this.onTouched = e; }
    registerOnChange(e) { this.onChange = e; }
    setDisabledState(e) { this.setProperty("disabled", e); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(s.Renderer2), s.\u0275\u0275directiveInject(s.ElementRef)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n });
} return n; })(), A = (() => { class n extends Se {
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, features: [s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), v = new b(""), bt = { provide: v, useExisting: l(() => At), multi: !0 }, At = (() => { class n extends A {
    writeValue(e) { this.setProperty("checked", e); }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "checkbox", "formControlName", "", 3, "ngNoCva", ""], ["input", "type", "checkbox", "formControl", "", 3, "ngNoCva", ""], ["input", "type", "checkbox", "ngModel", "", 3, "ngNoCva", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("change", function (a) { return r.onChange(a.target.checked); })("blur", function () { return r.onTouched(); }); }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([bt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), Mt = { provide: v, useExisting: l(() => Ie), multi: !0 };
function Et() { let n = Ce() ? Ce().getUserAgent() : ""; return /android (\d+)/.test(n.toLowerCase()); }
var Ft = new b(""), Ie = (() => { class n extends Se {
    _compositionMode;
    _composing = !1;
    constructor(e, i, r) { super(e, i), this._compositionMode = r, this._compositionMode == null && (this._compositionMode = !Et()); }
    writeValue(e) { let i = e ?? ""; this.setProperty("value", i); }
    _handleInput(e) { (!this._compositionMode || this._compositionMode && !this._composing) && this.onChange(e); }
    _compositionStart() { this._composing = !0; }
    _compositionEnd(e) { this._composing = !1, this._compositionMode && this.onChange(e); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(s.Renderer2), s.\u0275\u0275directiveInject(s.ElementRef), s.\u0275\u0275directiveInject(Ft, 8)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "formControlName", "", 3, "type", "checkbox", 3, "ngNoCva", ""], ["textarea", "formControlName", "", 3, "ngNoCva", ""], ["input", "formControl", "", 3, "type", "checkbox", 3, "ngNoCva", ""], ["textarea", "formControl", "", 3, "ngNoCva", ""], ["input", "ngModel", "", 3, "type", "checkbox", 3, "ngNoCva", ""], ["textarea", "ngModel", "", 3, "ngNoCva", ""], ["", "ngDefaultControl", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("input", function (a) { return r._handleInput(a.target.value); })("blur", function () { return r.onTouched(); })("compositionstart", function () { return r._compositionStart(); })("compositionend", function (a) { return r._compositionEnd(a.target.value); }); }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Mt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })();
function le(n) { return n == null || ue(n) === 0; }
function ue(n) { return n == null ? null : Array.isArray(n) || typeof n == "string" ? n.length : n instanceof Set ? n.size : null; }
var d = new b(""), V = new b(""), wt = /^(?=.{1,254}$)(?=.{1,64}@)[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+)*@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/, ie = class {
    static min(t) { return Oe(t); }
    static max(t) { return xe(t); }
    static required(t) { return Re(t); }
    static requiredTrue(t) { return Pe(t); }
    static email(t) { return ke(t); }
    static minLength(t) { return Te(t); }
    static maxLength(t) { return je(t); }
    static pattern(t) { return Be(t); }
    static nullValidator(t) { return L(); }
    static compose(t) { return qe(t); }
    static composeAsync(t) { return $e(t); }
};
function Oe(n) { return t => { if (t.value == null || n == null)
    return null; let e = parseFloat(t.value); return !isNaN(e) && e < n ? { min: { min: n, actual: t.value } } : null; }; }
function xe(n) { return t => { if (t.value == null || n == null)
    return null; let e = parseFloat(t.value); return !isNaN(e) && e > n ? { max: { max: n, actual: t.value } } : null; }; }
function Re(n) { return le(n.value) ? { required: !0 } : null; }
function Pe(n) { return n.value === !0 ? null : { required: !0 }; }
function ke(n) { return le(n.value) || wt.test(n.value) ? null : { email: !0 }; }
function Te(n) { return t => { let e = t.value?.length ?? ue(t.value); return e === null || e === 0 ? null : e < n ? { minlength: { requiredLength: n, actualLength: e } } : null; }; }
function je(n) { return t => { let e = t.value?.length ?? ue(t.value); return e !== null && e > n ? { maxlength: { requiredLength: n, actualLength: e } } : null; }; }
function Be(n) { if (!n)
    return L; let t, e; return typeof n == "string" ? (e = "", n.charAt(0) !== "^" && (e += "^"), e += n, n.charAt(n.length - 1) !== "$" && (e += "$"), t = new RegExp(e)) : (e = n.toString(), t = n), i => { if (le(i.value))
    return null; let r = i.value; return t.test(r) ? null : { pattern: { requiredPattern: e, actualValue: r } }; }; }
function L(n) { return null; }
function Ge(n) { return n != null; }
function Ue(n) { return ft(n) ? _t(n) : n; }
function He(n) { let t = {}; return n.forEach(e => { t = e != null ? c(c({}, t), e) : t; }), Object.keys(t).length === 0 ? null : t; }
function Le(n, t) { return t.map(e => e(n)); }
function Nt(n) { return !n.validate; }
function We(n) { return n.map(t => Nt(t) ? t : e => t.validate(e)); }
function qe(n) { if (!n)
    return null; let t = n.filter(Ge); return t.length == 0 ? null : function (e) { return He(Le(e, t)); }; }
function de(n) { return n != null ? qe(We(n)) : null; }
function $e(n) { if (!n)
    return null; let t = n.filter(Ge); return t.length == 0 ? null : function (e) { let i = Le(e, t).map(Ue); return yt(i).pipe(Dt(He)); }; }
function ce(n) { return n != null ? $e(We(n)) : null; }
function Ve(n, t) { return n === null ? [t] : Array.isArray(n) ? [...n, t] : [n, t]; }
function ze(n) { return n._rawValidators; }
function Ze(n) { return n._rawAsyncValidators; }
function re(n) { return n ? Array.isArray(n) ? n : [n] : []; }
function W(n, t) { return Array.isArray(n) ? n.includes(t) : n === t; }
function De(n, t) { let e = re(t); return re(n).forEach(r => { W(e, r) || e.push(r); }), e; }
function be(n, t) { return re(t).filter(e => !W(n, e)); }
var q = class {
    get value() { return this.control ? this.control.value : null; }
    get valid() { return this.control ? this.control.valid : null; }
    get invalid() { return this.control ? this.control.invalid : null; }
    get pending() { return this.control ? this.control.pending : null; }
    get disabled() { return this.control ? this.control.disabled : null; }
    get enabled() { return this.control ? this.control.enabled : null; }
    get errors() { return this.control ? this.control.errors : null; }
    get pristine() { return this.control ? this.control.pristine : null; }
    get dirty() { return this.control ? this.control.dirty : null; }
    get touched() { return this.control ? this.control.touched : null; }
    get status() { return this.control ? this.control.status : null; }
    get untouched() { return this.control ? this.control.untouched : null; }
    get statusChanges() { return this.control ? this.control.statusChanges : null; }
    get valueChanges() { return this.control ? this.control.valueChanges : null; }
    get path() { return null; }
    _composedValidatorFn;
    _composedAsyncValidatorFn;
    _rawValidators = [];
    _rawAsyncValidators = [];
    _setValidators(t) { this._rawValidators = t || [], this._composedValidatorFn = de(this._rawValidators); }
    _setAsyncValidators(t) { this._rawAsyncValidators = t || [], this._composedAsyncValidatorFn = ce(this._rawAsyncValidators); }
    get validator() { return this._composedValidatorFn || null; }
    get asyncValidator() { return this._composedAsyncValidatorFn || null; }
    _onDestroyCallbacks = [];
    _registerOnDestroy(t) { this._onDestroyCallbacks.push(t); }
    _invokeOnDestroyCallbacks() { this._onDestroyCallbacks.forEach(t => t()), this._onDestroyCallbacks = []; }
    reset(t = void 0) { this.control?.reset(t); }
    hasError(t, e) { return this.control ? this.control.hasError(t, e) : !1; }
    getError(t, e) { return this.control ? this.control.getError(t, e) : null; }
}, u = class extends q {
    name;
    get formDirective() { return null; }
    get path() { return null; }
};
var zn = new gt("22.0.7");
var P = "VALID", H = "INVALID", F = "PENDING", k = "DISABLED", y = class {
}, $ = class extends y {
    value;
    source;
    constructor(t, e) { super(), this.value = t, this.source = e; }
}, j = class extends y {
    pristine;
    source;
    constructor(t, e) { super(), this.pristine = t, this.source = e; }
}, B = class extends y {
    touched;
    source;
    constructor(t, e) { super(), this.touched = t, this.source = e; }
}, N = class extends y {
    status;
    source;
    constructor(t, e) { super(), this.status = t, this.source = e; }
}, z = class extends y {
    source;
    constructor(t) { super(), this.source = t; }
}, D = class extends y {
    source;
    constructor(t) { super(), this.source = t; }
};
function he(n) { return (ee(n) ? n.validators : n) || null; }
function St(n) { return Array.isArray(n) ? de(n) : n || null; }
function fe(n, t) { return (ee(t) ? t.asyncValidators : n) || null; }
function It(n) { return Array.isArray(n) ? ce(n) : n || null; }
function ee(n) { return n != null && !Array.isArray(n) && typeof n == "object"; }
function Xe(n, t, e) { let i = n.controls; if (!(t ? Object.keys(i) : i).length)
    throw new ne(1e3, ""); if (!Ke(i, e))
    throw new ne(1001, ""); }
function Ye(n, t, e) { n._forEachChild((i, r) => { if (e[r] === void 0)
    throw new ne(-1002, ""); }); }
var x = class {
    _pendingDirty = !1;
    _hasOwnPendingAsyncValidator = null;
    _pendingTouched = !1;
    _onCollectionChange = () => { };
    _updateOn;
    _hasRequired = w(!1);
    _parent = null;
    _asyncValidationSubscription;
    _composedValidatorFn;
    _composedAsyncValidatorFn;
    _rawValidators;
    _rawAsyncValidators;
    value;
    constructor(t, e) { this._assignValidators(t), this._assignAsyncValidators(e); }
    get validator() { return this._composedValidatorFn; }
    set validator(t) { this._rawValidators = this._composedValidatorFn = t, this._updateHasRequiredValidator(); }
    get asyncValidator() { return this._composedAsyncValidatorFn; }
    set asyncValidator(t) { this._rawAsyncValidators = this._composedAsyncValidatorFn = t; }
    get parent() { return this._parent; }
    get status() { return g(this.statusReactive); }
    set status(t) { g(() => this.statusReactive.set(t)); }
    _status = S(() => this.statusReactive());
    statusReactive = w(void 0);
    get valid() { return this.status === P; }
    get invalid() { return this.status === H; }
    get pending() { return this.status === F; }
    get disabled() { return this.status === k; }
    get enabled() { return this.status !== k; }
    errors;
    get pristine() { return g(this.pristineReactive); }
    set pristine(t) { g(() => this.pristineReactive.set(t)); }
    _pristine = S(() => this.pristineReactive());
    pristineReactive = w(!0);
    get dirty() { return !this.pristine; }
    get touched() { return g(this.touchedReactive); }
    set touched(t) { g(() => this.touchedReactive.set(t)); }
    _touched = S(() => this.touchedReactive());
    touchedReactive = w(!1);
    get untouched() { return !this.touched; }
    _events = new Ct;
    events = this._events.asObservable();
    valueChanges;
    statusChanges;
    get updateOn() { return this._updateOn ? this._updateOn : this.parent ? this.parent.updateOn : "change"; }
    setValidators(t) { this._assignValidators(t); }
    setAsyncValidators(t) { this._assignAsyncValidators(t); }
    addValidators(t) { this.setValidators(De(t, this._rawValidators)); }
    addAsyncValidators(t) { this.setAsyncValidators(De(t, this._rawAsyncValidators)); }
    removeValidators(t) { this.setValidators(be(t, this._rawValidators)); }
    removeAsyncValidators(t) { this.setAsyncValidators(be(t, this._rawAsyncValidators)); }
    hasValidator(t) { return W(this._rawValidators, t); }
    hasAsyncValidator(t) { return W(this._rawAsyncValidators, t); }
    clearValidators() { this.validator = null; }
    clearAsyncValidators() { this.asyncValidator = null; }
    markAsTouched(t = {}) { let e = this.touched === !1; this.touched = !0; let i = t.sourceControl ?? this; t.onlySelf || this._parent?.markAsTouched(f(c({}, t), { sourceControl: i })), e && t.emitEvent !== !1 && this._events.next(new B(!0, i)); }
    markAllAsDirty(t = {}) { this.markAsDirty({ onlySelf: !0, emitEvent: t.emitEvent, sourceControl: this }), this._forEachChild(e => e.markAllAsDirty(t)); }
    markAllAsTouched(t = {}) { this.markAsTouched({ onlySelf: !0, emitEvent: t.emitEvent, sourceControl: this }), this._forEachChild(e => e.markAllAsTouched(t)); }
    markAsUntouched(t = {}) { let e = this.touched === !0; this.touched = !1, this._pendingTouched = !1; let i = t.sourceControl ?? this; this._forEachChild(r => { r.markAsUntouched({ onlySelf: !0, emitEvent: t.emitEvent, sourceControl: i }); }), t.onlySelf || this._parent?._updateTouched(t, i), e && t.emitEvent !== !1 && this._events.next(new B(!1, i)); }
    markAsDirty(t = {}) { let e = this.pristine === !0; this.pristine = !1; let i = t.sourceControl ?? this; t.onlySelf || this._parent?.markAsDirty(f(c({}, t), { sourceControl: i })), e && t.emitEvent !== !1 && this._events.next(new j(!1, i)); }
    markAsPristine(t = {}) { let e = this.pristine === !1; this.pristine = !0, this._pendingDirty = !1; let i = t.sourceControl ?? this; this._forEachChild(r => { r.markAsPristine({ onlySelf: !0, emitEvent: t.emitEvent }); }), t.onlySelf || this._parent?._updatePristine(t, i), e && t.emitEvent !== !1 && this._events.next(new j(!0, i)); }
    markAsPending(t = {}) { this.status = F; let e = t.sourceControl ?? this; t.emitEvent !== !1 && (this._events.next(new N(this.status, e)), this.statusChanges.emit(this.status)), t.onlySelf || this._parent?.markAsPending(f(c({}, t), { sourceControl: e })); }
    disable(t = {}) { let e = this._parentMarkedDirty(t.onlySelf); this.status = k, this.errors = null, this._forEachChild(r => { r.disable(f(c({}, t), { onlySelf: !0 })); }), this._updateValue(); let i = t.sourceControl ?? this; t.emitEvent !== !1 && (this._events.next(new $(this.value, i)), this._events.next(new N(this.status, i)), this.valueChanges.emit(this.value), this.statusChanges.emit(this.status)), this._updateAncestors(f(c({}, t), { skipPristineCheck: e }), this), this._onDisabledChange.forEach(r => r(!0)); }
    enable(t = {}) { let e = this._parentMarkedDirty(t.onlySelf); this.status = P, this._forEachChild(i => { i.enable(f(c({}, t), { onlySelf: !0 })); }), this.updateValueAndValidity({ onlySelf: !0, emitEvent: t.emitEvent }), this._updateAncestors(f(c({}, t), { skipPristineCheck: e }), this), this._onDisabledChange.forEach(i => i(!1)); }
    _updateAncestors(t, e) { t.onlySelf || (this._parent?.updateValueAndValidity(t), t.skipPristineCheck || this._parent?._updatePristine({}, e), this._parent?._updateTouched({}, e)); }
    setParent(t) { this._parent = t; }
    getRawValue() { return this.value; }
    updateValueAndValidity(t = {}) { if (this._setInitialStatus(), this._updateValue(), this.enabled) {
        let i = this._cancelExistingSubscription();
        this.errors = this._runValidator(), this.status = this._calculateStatus(), (this.status === P || this.status === F) && this._runAsyncValidator(i, t.emitEvent);
    } let e = t.sourceControl ?? this; t.emitEvent !== !1 && (this._events.next(new $(this.value, e)), this._events.next(new N(this.status, e)), this.valueChanges.emit(this.value), this.statusChanges.emit(this.status)), t.onlySelf || this._parent?.updateValueAndValidity(f(c({}, t), { sourceControl: e })); }
    _updateTreeValidity(t = { emitEvent: !0 }) { this._forEachChild(e => e._updateTreeValidity(t)), this.updateValueAndValidity({ onlySelf: !0, emitEvent: t.emitEvent }); }
    _setInitialStatus() { this.status = this._allControlsDisabled() ? k : P; }
    _runValidator() { return this.validator ? this.validator(this) : null; }
    _runAsyncValidator(t, e) { if (this.asyncValidator) {
        this.status = F, this._hasOwnPendingAsyncValidator = { emitEvent: e !== !1, shouldHaveEmitted: t !== !1 };
        let i = Ue(this.asyncValidator(this));
        this._asyncValidationSubscription = i.subscribe(r => { this._hasOwnPendingAsyncValidator = null, this.setErrors(r, { emitEvent: e, shouldHaveEmitted: t }); });
    } }
    _cancelExistingSubscription() { if (this._asyncValidationSubscription) {
        this._asyncValidationSubscription.unsubscribe();
        let t = (this._hasOwnPendingAsyncValidator?.emitEvent || this._hasOwnPendingAsyncValidator?.shouldHaveEmitted) ?? !1;
        return this._hasOwnPendingAsyncValidator = null, t;
    } return !1; }
    setErrors(t, e = {}) { this.errors = t, this._updateControlsErrors(e.emitEvent !== !1, this, e.shouldHaveEmitted); }
    get(t) { let e = t; return e == null || (Array.isArray(e) || (e = e.split(".")), e.length === 0) ? null : e.reduce((i, r) => i && i._find(r), this); }
    getError(t, e) { let i = e ? this.get(e) : this; return i?.errors ? i.errors[t] : null; }
    hasError(t, e) { return !!this.getError(t, e); }
    get root() { let t = this; for (; t._parent;)
        t = t._parent; return t; }
    _updateControlsErrors(t, e, i) { this.status = this._calculateStatus(), t && this.statusChanges.emit(this.status), (t || i) && this._events.next(new N(this.status, e)), this._parent && this._parent._updateControlsErrors(t, e, i); }
    _initObservables() { this.valueChanges = new _, this.statusChanges = new _; }
    _calculateStatus() { return this._allControlsDisabled() ? k : this.errors ? H : this._hasOwnPendingAsyncValidator || this._anyControlsHaveStatus(F) ? F : this._anyControlsHaveStatus(H) ? H : P; }
    _anyControlsHaveStatus(t) { return this._anyControls(e => e.status === t); }
    _anyControlsDirty() { return this._anyControls(t => t.dirty); }
    _anyControlsTouched() { return this._anyControls(t => t.touched); }
    _updatePristine(t, e) { let i = !this._anyControlsDirty(), r = this.pristine !== i; this.pristine = i, t.onlySelf || this._parent?._updatePristine(t, e), r && this._events.next(new j(this.pristine, e)); }
    _updateTouched(t = {}, e) { this.touched = this._anyControlsTouched(), this._events.next(new B(this.touched, e)), t.onlySelf || this._parent?._updateTouched(t, e); }
    _onDisabledChange = [];
    _registerOnCollectionChange(t) { this._onCollectionChange = t; }
    _setUpdateStrategy(t) { ee(t) && t.updateOn != null && (this._updateOn = t.updateOn); }
    _parentMarkedDirty(t) { return !t && !!this._parent?.dirty && !this._parent._anyControlsDirty(); }
    _find(t) { return null; }
    _assignValidators(t) { this._rawValidators = Array.isArray(t) ? t.slice() : t, this._composedValidatorFn = St(this._rawValidators), this._updateHasRequiredValidator(); }
    _assignAsyncValidators(t) { this._rawAsyncValidators = Array.isArray(t) ? t.slice() : t, this._composedAsyncValidatorFn = It(this._rawAsyncValidators); }
    _updateHasRequiredValidator() { g(() => this._hasRequired.set(this.hasValidator(ie.required))); }
};
function Ke(n, t) { return Object.hasOwn(n, t); }
function Ot(n) { return n.tagName === "INPUT" || n.tagName === "SELECT" || n.tagName === "TEXTAREA"; }
function Zn(n) { if (n.tagName !== "INPUT")
    return !1; let t = n.type; return t === "number" || t === "range" || t === "date" || t === "month"; }
function Xn(n) { return n.tagName === "INPUT" || n.tagName === "TEXTAREA"; }
function xt(n, t, e, i) { switch (e) {
    case "name":
        n.setAttribute(t, e, i);
        break;
    case "disabled":
    case "readonly":
    case "required":
        i ? n.setAttribute(t, e, "") : n.removeAttribute(t, e);
        break;
    case "max":
    case "min":
    case "minLength":
    case "maxLength":
        i !== void 0 ? n.setAttribute(t, e, i.toString()) : n.removeAttribute(t, e);
        break;
} }
var se = class {
    kind;
    context;
    control;
    message;
    constructor({ kind: t, context: e, control: i }) { this.kind = t, this.context = e, this.control = i; }
};
function Je(n) { return typeof n == "number" ? n : parseInt(n, 10); }
function Qe(n) { return typeof n == "number" ? n : parseFloat(n); }
var M = (() => { class n {
    _validator = L;
    _onChange;
    _enabled;
    ngOnChanges(e) { if (this.inputName in e) {
        let i = this.normalizeInput(e[this.inputName].currentValue);
        this._enabled = this.enabled(i), this._validator = this._enabled ? this.createValidator(i) : L, this._onChange?.();
    } }
    validate(e) { return this._validator(e); }
    registerOnValidatorChange(e) { this._onChange = e; }
    enabled(e) { return e != null; }
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, features: [s.\u0275\u0275NgOnChangesFeature] });
} return n; })(), Rt = { provide: d, useExisting: l(() => Pt), multi: !0 }, Pt = (() => { class n extends M {
    max;
    inputName = "max";
    normalizeInput = e => Qe(e);
    createValidator = e => xe(e);
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "number", "max", "", "formControlName", ""], ["input", "type", "number", "max", "", "formControl", ""], ["input", "type", "number", "max", "", "ngModel", ""]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("max", r._enabled ? r.max : null); }, inputs: { max: "max" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Rt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), kt = { provide: d, useExisting: l(() => Tt), multi: !0 }, Tt = (() => { class n extends M {
    min;
    inputName = "min";
    normalizeInput = e => Qe(e);
    createValidator = e => Oe(e);
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "number", "min", "", "formControlName", ""], ["input", "type", "number", "min", "", "formControl", ""], ["input", "type", "number", "min", "", "ngModel", ""]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("min", r._enabled ? r.min : null); }, inputs: { min: "min" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([kt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), jt = { provide: d, useExisting: l(() => ge), multi: !0 }, Bt = { provide: d, useExisting: l(() => Gt), multi: !0 }, ge = (() => { class n extends M {
    required;
    inputName = "required";
    normalizeInput = oe;
    createValidator = e => Re;
    enabled(e) { return e; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "required", "", "formControlName", "", 3, "type", "checkbox"], ["", "required", "", "formControl", "", 3, "type", "checkbox"], ["", "required", "", "ngModel", "", 3, "type", "checkbox"]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("required", r._enabled ? "" : null); }, inputs: { required: "required" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([jt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), Gt = (() => { class n extends ge {
    createValidator = e => Pe;
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "checkbox", "required", "", "formControlName", ""], ["input", "type", "checkbox", "required", "", "formControl", ""], ["input", "type", "checkbox", "required", "", "ngModel", ""]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("required", r._enabled ? "" : null); }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Bt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), Ut = { provide: d, useExisting: l(() => Ht), multi: !0 }, Ht = (() => { class n extends M {
    email;
    inputName = "email";
    normalizeInput = oe;
    createValidator = e => ke;
    enabled(e) { return e; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "email", "", "formControlName", ""], ["", "email", "", "formControl", ""], ["", "email", "", "ngModel", ""]], inputs: { email: "email" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Ut]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), Lt = { provide: d, useExisting: l(() => Wt), multi: !0 }, Wt = (() => { class n extends M {
    minlength;
    inputName = "minlength";
    normalizeInput = e => Je(e);
    createValidator = e => Te(e);
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "minlength", "", "formControlName", ""], ["", "minlength", "", "formControl", ""], ["", "minlength", "", "ngModel", ""]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("minlength", r._enabled ? r.minlength : null); }, inputs: { minlength: "minlength" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Lt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), qt = { provide: d, useExisting: l(() => $t), multi: !0 }, $t = (() => { class n extends M {
    maxlength;
    inputName = "maxlength";
    normalizeInput = e => Je(e);
    createValidator = e => je(e);
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "maxlength", "", "formControlName", ""], ["", "maxlength", "", "formControl", ""], ["", "maxlength", "", "ngModel", ""]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("maxlength", r._enabled ? r.maxlength : null); }, inputs: { maxlength: "maxlength" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([qt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), zt = { provide: d, useExisting: l(() => Zt), multi: !0 }, Zt = (() => { class n extends M {
    pattern;
    inputName = "pattern";
    normalizeInput = e => e;
    createValidator = e => Be(e);
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "pattern", "", "formControlName", ""], ["", "pattern", "", "formControl", ""], ["", "pattern", "", "ngModel", ""]], hostVars: 1, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275attribute("pattern", r._enabled ? r.pattern : null); }, inputs: { pattern: "pattern" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([zt]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), Xt = new b(""), E = new b("", { factory: () => U }), U = "always";
function te(n, t) { return [...t.path, n]; }
function Z(n, t, e = U) { pe(n, t), t.valueAccessor.writeValue(n.value), (n.disabled || e === "always") && t.valueAccessor.setDisabledState?.(n.disabled), Kt(n, t), Qt(n, t), Jt(n, t), Yt(n, t); }
function X(n, t, e = !0) { let i = () => { }; t?.valueAccessor?.registerOnChange(i), t?.valueAccessor?.registerOnTouched(i), K(n, t), n && (t._invokeOnDestroyCallbacks(), n._registerOnCollectionChange(() => { })); }
function Y(n, t) { n.forEach(e => { e.registerOnValidatorChange && e.registerOnValidatorChange(t); }); }
function Yt(n, t) { if (t.valueAccessor.setDisabledState) {
    let e = i => { t.valueAccessor.setDisabledState(i); };
    n.registerOnDisabledChange(e), t._registerOnDestroy(() => { n._unregisterOnDisabledChange(e); });
} }
function pe(n, t) { let e = ze(n); t.validator !== null ? n.setValidators(Ve(e, t.validator)) : typeof e == "function" && n.setValidators([e]); let i = Ze(n); t.asyncValidator !== null ? n.setAsyncValidators(Ve(i, t.asyncValidator)) : typeof i == "function" && n.setAsyncValidators([i]); let r = () => n.updateValueAndValidity(); Y(t._rawValidators, r), Y(t._rawAsyncValidators, r); }
function K(n, t) { let e = !1; if (n !== null) {
    if (t.validator !== null) {
        let r = ze(n);
        if (Array.isArray(r) && r.length > 0) {
            let o = r.filter(a => a !== t.validator);
            o.length !== r.length && (e = !0, n.setValidators(o));
        }
    }
    if (t.asyncValidator !== null) {
        let r = Ze(n);
        if (Array.isArray(r) && r.length > 0) {
            let o = r.filter(a => a !== t.asyncValidator);
            o.length !== r.length && (e = !0, n.setAsyncValidators(o));
        }
    }
} let i = () => { }; return Y(t._rawValidators, i), Y(t._rawAsyncValidators, i), e; }
function Kt(n, t) { t.valueAccessor.registerOnChange(e => { n._pendingValue = e, n._pendingChange = !0, n._pendingDirty = !0, n.updateOn === "change" && et(n, t); }); }
function Jt(n, t) { t.valueAccessor.registerOnTouched(() => { n._pendingTouched = !0, n.updateOn === "blur" && n._pendingChange && et(n, t), n.updateOn !== "submit" && n.markAsTouched(); }); }
function et(n, t) { n._pendingDirty && n.markAsDirty(), n.setValue(n._pendingValue, { emitModelToViewChange: !1 }), t.viewToModelUpdate(n._pendingValue), n._pendingChange = !1; }
function Qt(n, t) { let e = (i, r) => { t.valueAccessor.writeValue(i), r && t.viewToModelUpdate(i); }; n.registerOnChange(e), t._registerOnDestroy(() => { n._unregisterOnChange(e); }); }
function tt(n, t) { n == null, pe(n, t); }
function en(n, t) { return K(n, t); }
function me(n, t) { if (!n.hasOwnProperty("model"))
    return !1; let e = n.model; return e.isFirstChange() ? !0 : !Object.is(t, e.currentValue); }
function tn(n) { return Object.getPrototypeOf(n.constructor) === A; }
function nt(n, t) { n._syncPendingControls(), t.forEach(e => { let i = e.control; i.updateOn === "submit" && i._pendingChange && (e.viewToModelUpdate(i._pendingValue), i._pendingChange = !1); }); }
function nn(n, t) { if (!t)
    return null; Array.isArray(t); let e, i, r; return t.forEach(o => { o.constructor === Ie ? e = o : tn(o) ? i = o : r = o; }), r || i || e || null; }
function rn(n, t) { let e = n.indexOf(t); e > -1 && n.splice(e, 1); }
var ve = { provide: Xt, useFactory: () => { let n = I(p, { self: !0 }); return { setParseErrors: t => { n.setParseErrorSource(t); }, set onReset(t) { n.onReset = t; } }; } }, p = class extends q {
    _parent = null;
    name = null;
    valueAccessor = null;
    isCustomControlBased = !1;
    userOnReset;
    resetSubscription;
    set onReset(t) { this.userOnReset = t, this.resetSubscription?.unsubscribe(), this.resetSubscription = void 0, this.control && (this.resetSubscription = this.control.events.subscribe(e => { e instanceof D && this.control && this.userOnReset?.(this.control.value); }), this.subscription?.add(this.resetSubscription)); }
    isNativeFormElement = !1;
    rawValueAccessors;
    _selectedValueAccessor = null;
    get selectedValueAccessor() { return this._selectedValueAccessor ??= nn(this, this.rawValueAccessors); }
    parseErrorsValidator = null;
    renderer;
    injector;
    requiredValidatorViaDi;
    subscription;
    customControlBindings = null;
    constructor(t, e, i) { super(), this.injector = t, this.renderer = e, this.rawValueAccessors = i, this.injector?.get(Ne)?.onDestroy(() => { this.removeParseErrorsValidator(this.control), this.subscription?.unsubscribe(); }); }
    setupCustomControl() { this.subscription?.unsubscribe(); let t = this.injector?.get(ae); if (!this.control || !t)
        return; let e = t.markForCheck.bind(t); this.subscription = new Vt, this.subscription.add(this.control.valueChanges.subscribe(e)), this.subscription.add(this.control.statusChanges.subscribe(e)), this.resetSubscription?.unsubscribe(), this.resetSubscription = void 0, this.userOnReset && (this.resetSubscription = this.control.events.subscribe(i => { i instanceof D && this.control && this.userOnReset?.(this.control.value); }), this.subscription.add(this.resetSubscription)), this.parseErrorsValidator && this.control.addValidators(this.parseErrorsValidator); }
    ngControlCreate(t) { !t.nativeElement.hasAttribute?.("ngNoCva") && (this.rawValueAccessors && this.rawValueAccessors.length > 0 || this.valueAccessor !== null) || !t.customControl || (this.isCustomControlBased = !0, t.listenToCustomControlModel(r => { this.control?.setValue(r, { emitModelToViewChange: !1 }), this.control?.markAsDirty(), this.viewToModelUpdate(r); }), t.listenToCustomControlOutput("touch", () => { this.control?.markAsTouched(); }), this.customControlBindings = {}, this.isNativeFormElement = Ot(t.nativeElement), this.requiredValidatorViaDi = this._rawValidators.find(r => r instanceof ge)); }
    ngControlUpdate(t, e) { if (!this.isCustomControlBased)
        return; let i = this.control, r = this.customControlBindings; Object.is(r.value, i.value) || (r.value = i.value, t.setCustomControlModelInput(i.value)), this.bindControlProperty(t, r, "touched", i.touched), this.bindControlProperty(t, r, "dirty", i.dirty), this.bindControlProperty(t, r, "valid", i.valid), this.bindControlProperty(t, r, "invalid", i.invalid), this.bindControlProperty(t, r, "pending", i.pending), this.bindControlProperty(t, r, "disabled", i.disabled), this.shouldBindRequired && this.bindControlProperty(t, r, "required", this.isRequired); let o = i.errors; if (r.errors !== o) {
        r.errors = o;
        let a = this._convertErrors(o);
        t.setInputOnDirectives("errors", a);
    } }
    get isRequired() { return (this.requiredValidatorViaDi?._enabled || this.control?._hasRequired()) ?? !1; }
    get shouldBindRequired() { return !0; }
    bindControlProperty(t, e, i, r) { if (e[i] === r)
        return; e[i] = r; let o = t.setInputOnDirectives(i, r); this.isNativeFormElement && !o && (i === "disabled" || i === "required") && this.renderer && xt(this.renderer, t.nativeElement, i, r); }
    _convertErrors(t) { if (t === null)
        return []; let e = this.control; return Object.entries(t).map(([i, r]) => new se({ context: r, kind: i, control: e })); }
    setParseErrorSource(t) { if (t === void 0)
        return; let e = null, i = S(() => { let r = t(); return r.length === 0 ? null : r.reduce((o, a) => (o[a.kind] = a, o), {}); }); this.parseErrorsValidator = (() => e).bind(this), pt(() => { e = i(), this.control?.updateValueAndValidity({ emitEvent: !1 }); }, { injector: this.injector }); }
    removeParseErrorsValidator(t) { this.parseErrorsValidator && (t?.removeValidators(this.parseErrorsValidator), t?.updateValueAndValidity({ emitEvent: !1 })); }
}, J = class {
    _cd;
    constructor(t) { this._cd = t; }
    get isTouched() { return this._cd?.control?._touched?.(), !!this._cd?.control?.touched; }
    get isUntouched() { return !!this._cd?.control?.untouched; }
    get isPristine() { return this._cd?.control?._pristine?.(), !!this._cd?.control?.pristine; }
    get isDirty() { return !!this._cd?.control?.dirty; }
    get isValid() { return this._cd?.control?._status?.(), !!this._cd?.control?.valid; }
    get isInvalid() { return !!this._cd?.control?.invalid; }
    get isPending() { return !!this._cd?.control?.pending; }
    get isSubmitted() { return this._cd?._submitted?.(), !!this._cd?.submitted; }
};
var Yn = (() => { class n extends J {
    constructor(e) { super(e); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(p, 2)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formControlName", ""], ["", "ngModel", ""], ["", "formControl", ""]], hostVars: 14, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275classProp("ng-untouched", r.isUntouched)("ng-touched", r.isTouched)("ng-pristine", r.isPristine)("ng-dirty", r.isDirty)("ng-valid", r.isValid)("ng-invalid", r.isInvalid)("ng-pending", r.isPending); }, standalone: !1, features: [s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), Kn = (() => { class n extends J {
    constructor(e) { super(e); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(u, 10)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formGroupName", ""], ["", "formArrayName", ""], ["", "ngModelGroup", ""], ["", "formGroup", ""], ["", "formArray", ""], ["form", 3, "ngNoForm", ""], ["", "ngForm", ""]], hostVars: 16, hostBindings: function (i, r) { i & 2 && s.\u0275\u0275classProp("ng-untouched", r.isUntouched)("ng-touched", r.isTouched)("ng-pristine", r.isPristine)("ng-dirty", r.isDirty)("ng-valid", r.isValid)("ng-invalid", r.isInvalid)("ng-pending", r.isPending)("ng-submitted", r.isSubmitted); }, standalone: !1, features: [s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), C = class extends x {
    constructor(t, e, i) { super(he(e), fe(i, e)), this.controls = t, this._initObservables(), this._setUpdateStrategy(e), this._setUpControls(), this.updateValueAndValidity({ onlySelf: !0, emitEvent: !!this.asyncValidator }); }
    controls;
    registerControl(t, e) { let i = this._find(t); return i || (this.controls[t] = e, e.setParent(this), e._registerOnCollectionChange(this._onCollectionChange), e); }
    addControl(t, e, i = {}) { this.registerControl(t, e), this.updateValueAndValidity({ emitEvent: i.emitEvent }), this._onCollectionChange(); }
    removeControl(t, e = {}) { let i = this._find(t); i && i._registerOnCollectionChange(() => { }), delete this.controls[t], this.updateValueAndValidity({ emitEvent: e.emitEvent }), this._onCollectionChange(); }
    setControl(t, e, i = {}) { let r = this._find(t); r && r._registerOnCollectionChange(() => { }), delete this.controls[t], e && this.registerControl(t, e), this.updateValueAndValidity({ emitEvent: i.emitEvent }), this._onCollectionChange(); }
    contains(t) { return this._find(t)?.enabled === !0; }
    setValue(t, e = {}) { g(() => { Ye(this, !0, t), Object.keys(t).forEach(i => { Xe(this, !0, i), this.controls[i].setValue(t[i], { onlySelf: !0, emitEvent: e.emitEvent }); }), this.updateValueAndValidity(e); }); }
    patchValue(t, e = {}) { t != null && (Object.keys(t).forEach(i => { let r = this._find(i); r && r.patchValue(t[i], { onlySelf: !0, emitEvent: e.emitEvent }); }), this.updateValueAndValidity(e)); }
    reset(t = {}, e = {}) { this._forEachChild((i, r) => { i.reset(t ? t[r] : null, f(c({}, e), { onlySelf: !0 })); }), this._updatePristine(e, this), this._updateTouched(e, this), this.updateValueAndValidity(e), e?.emitEvent !== !1 && this._events.next(new D(this)); }
    getRawValue() { return this._reduceChildren({}, (t, e, i) => (t[i] = e.getRawValue(), t)); }
    _syncPendingControls() { let t = this._reduceChildren(!1, (e, i) => i._syncPendingControls() ? !0 : e); return t && this.updateValueAndValidity({ onlySelf: !0 }), t; }
    _forEachChild(t) { Object.keys(this.controls).forEach(e => { let i = this.controls[e]; i && t(i, e); }); }
    _setUpControls() { this._forEachChild(t => { t.setParent(this), t._registerOnCollectionChange(this._onCollectionChange); }); }
    _updateValue() { this.value = this._reduceValue(); }
    _anyControls(t) { for (let [e, i] of Object.entries(this.controls))
        if (this.contains(e) && t(i))
            return !0; return !1; }
    _reduceValue() { let t = {}; return this._reduceChildren(t, (e, i, r) => ((i.enabled || this.disabled) && (e[r] = i.value), e)); }
    _reduceChildren(t, e) { let i = t; return this._forEachChild((r, o) => { i = e(i, r, o); }), i; }
    _allControlsDisabled() { for (let t of Object.keys(this.controls))
        if (this.controls[t].enabled)
            return !1; return Object.keys(this.controls).length > 0 || this.disabled; }
    _find(t) { return Ke(this.controls, t) ? this.controls[t] : null; }
};
var Jn = C, Qn = n => n instanceof C, Q = class extends C {
}, ei = n => n instanceof Q, sn = { provide: u, useExisting: l(() => it) }, T = Promise.resolve(), it = (() => { class n extends u {
    callSetDisabledState;
    get submitted() { return g(this.submittedReactive); }
    _submitted = S(() => this.submittedReactive());
    submittedReactive = w(!1);
    _directives = new Set;
    form;
    ngSubmit = new _;
    options;
    constructor(e, i, r) { super(), this.callSetDisabledState = r, this.form = new C({}, de(e), ce(i)); }
    ngAfterViewInit() { this._setUpdateStrategy(); }
    get formDirective() { return this; }
    get control() { return this.form; }
    get path() { return []; }
    get controls() { return this.form.controls; }
    addControl(e) { T.then(() => { let i = this._findContainer(e.path); e.control = i.registerControl(e.name, e.control), e._setupWithForm(this.callSetDisabledState), e.control.updateValueAndValidity({ emitEvent: !1 }), this._directives.add(e); }); }
    getControl(e) { return this.form.get(e.path); }
    removeControl(e) { T.then(() => { this._findContainer(e.path)?.removeControl(e.name), this._directives.delete(e); }); }
    addFormGroup(e) { T.then(() => { let i = this._findContainer(e.path), r = new C({}); tt(r, e), i.registerControl(e.name, r), r.updateValueAndValidity({ emitEvent: !1 }); }); }
    removeFormGroup(e) { T.then(() => { this._findContainer(e.path)?.removeControl?.(e.name); }); }
    getFormGroup(e) { return this.form.get(e.path); }
    updateModel(e, i) { T.then(() => { this.form.get(e.path).setValue(i); }); }
    setValue(e) { this.control.setValue(e); }
    onSubmit(e) { return this.submittedReactive.set(!0), nt(this.form, this._directives), this.ngSubmit.emit(e), this.form._events.next(new z(this.control)), e?.target?.method === "dialog"; }
    onReset() { this.resetForm(); }
    resetForm(e = void 0) { this.form.reset(e), this.submittedReactive.set(!1); }
    _setUpdateStrategy() { this.options && this.options.updateOn != null && (this.form._updateOn = this.options.updateOn); }
    _findContainer(e) { return e.pop(), e.length ? this.form.get(e) : this.form; }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10), s.\u0275\u0275directiveInject(E, 8)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["form", 3, "ngNoForm", "", 3, "formGroup", "", 3, "formArray", ""], ["ng-form"], ["", "ngForm", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("submit", function (a) { return r.onSubmit(a); })("reset", function () { return r.onReset(); }); }, inputs: { options: [0, "ngFormOptions", "options"] }, outputs: { ngSubmit: "ngSubmit" }, exportAs: ["ngForm"], standalone: !1, features: [s.\u0275\u0275ProvidersFeature([sn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })();
function Ae(n, t) { let e = n.indexOf(t); e > -1 && n.splice(e, 1); }
function Me(n) { return typeof n == "object" && n !== null && Object.keys(n).length === 2 && "value" in n && "disabled" in n; }
var O = class extends x {
    defaultValue = null;
    _onChange = [];
    _pendingValue;
    _pendingChange = !1;
    constructor(t = null, e, i) { super(he(e), fe(i, e)), this._applyFormState(t), this._setUpdateStrategy(e), this._initObservables(), this.updateValueAndValidity({ onlySelf: !0, emitEvent: !!this.asyncValidator }), ee(e) && (e.nonNullable || e.initialValueIsDefault) && (Me(t) ? this.defaultValue = t.value : this.defaultValue = t); }
    setValue(t, e = {}) { g(() => { this.value = this._pendingValue = t, this._onChange.length && e.emitModelToViewChange !== !1 && this._onChange.forEach(i => i(this.value, e.emitViewToModelChange !== !1)), this.updateValueAndValidity(e); }); }
    patchValue(t, e = {}) { this.setValue(t, e); }
    reset(t = this.defaultValue, e = {}) { this._applyFormState(t), this.markAsPristine(e), this.markAsUntouched(e), this.setValue(this.value, e), e.overwriteDefaultValue && (this.defaultValue = this.value), this._pendingChange = !1, e?.emitEvent !== !1 && this._events.next(new D(this)); }
    _updateValue() { }
    _anyControls(t) { return !1; }
    _allControlsDisabled() { return this.disabled; }
    registerOnChange(t) { this._onChange.push(t); }
    _unregisterOnChange(t) { Ae(this._onChange, t); }
    registerOnDisabledChange(t) { this._onDisabledChange.push(t); }
    _unregisterOnDisabledChange(t) { Ae(this._onDisabledChange, t); }
    _forEachChild(t) { }
    _syncPendingControls() { return this.updateOn === "submit" && (this._pendingDirty && this.markAsDirty(), this._pendingTouched && this.markAsTouched(), this._pendingChange) ? (this.setValue(this._pendingValue, { onlySelf: !0, emitModelToViewChange: !1 }), !0) : !1; }
    _applyFormState(t) { Me(t) ? (this.value = this._pendingValue = t.value, t.disabled ? this.disable({ onlySelf: !0, emitEvent: !1 }) : this.enable({ onlySelf: !0, emitEvent: !1 })) : this.value = this._pendingValue = t; }
}, ni = O, on = n => n instanceof O, rt = (() => { class n extends u {
    _parent;
    ngOnInit() { this._checkParentType(), this.formDirective.addFormGroup(this); }
    ngOnDestroy() { this.formDirective?.removeFormGroup(this); }
    get control() { return this.formDirective.getFormGroup(this); }
    get path() { return te(this.name == null ? this.name : this.name.toString(), this._parent); }
    get formDirective() { return this._parent ? this._parent.formDirective : null; }
    _checkParentType() { }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, standalone: !1, features: [s.\u0275\u0275InheritDefinitionFeature] });
} return n; })();
var an = { provide: u, useExisting: l(() => ln) }, ln = (() => { class n extends rt {
    name = "";
    constructor(e, i, r) { super(), this._parent = e, this._setValidators(i), this._setAsyncValidators(r); }
    _checkParentType() { !(this._parent instanceof n) && this._parent instanceof it; }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(u, 5), s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "ngModelGroup", ""]], inputs: { name: [0, "ngModelGroup", "name"] }, exportAs: ["ngModelGroup"], standalone: !1, features: [s.\u0275\u0275ProvidersFeature([an]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), un = { provide: p, useExisting: l(() => dn) }, Ee = Promise.resolve(), dn = (() => { class n extends p {
    _changeDetectorRef;
    callSetDisabledState;
    control = new O;
    static ngAcceptInputType_isDisabled;
    _registered = !1;
    viewModel;
    name = "";
    isDisabled;
    model;
    options;
    update = new _;
    constructor(e, i, r, o, a, h, m, R) { super(m, R, o), this._changeDetectorRef = a, this.callSetDisabledState = h, this._parent = e, this._setValidators(i), this._setAsyncValidators(r); }
    ngOnChanges(e) { if (this._checkForErrors(), !this._registered || "name" in e) {
        if (this._registered && (this._checkName(), this.formDirective)) {
            let i = e.name.previousValue;
            this.formDirective.removeControl({ name: i, path: this._getPath(i) });
        }
        this._setUpControl();
    } "isDisabled" in e && this._updateDisabled(e), me(e, this.viewModel) && (this._updateValue(this.model), this.viewModel = this.model); }
    ngOnDestroy() { this.formDirective?.removeControl(this); }
    \u0275ngControlCreate(e) { super.ngControlCreate(e); }
    \u0275ngControlUpdate(e) { super.ngControlUpdate(e, !1); }
    get shouldBindRequired() { return !1; }
    get path() { return this._getPath(this.name); }
    get formDirective() { return this._parent ? this._parent.formDirective : null; }
    viewToModelUpdate(e) { this.viewModel = e, this.update.emit(e); }
    _setUpControl() { this._setUpdateStrategy(), this._isStandalone() ? this._setUpStandalone() : this.formDirective.addControl(this), this._registered = !0; }
    _setUpdateStrategy() { this.options && this.options.updateOn != null && (this.control._updateOn = this.options.updateOn); }
    _isStandalone() { return !this._parent || !!(this.options && this.options.standalone); }
    _setUpStandalone() { this.isCustomControlBased ? this.setupCustomControl() : (this.valueAccessor ??= this.selectedValueAccessor, Z(this.control, this, this.callSetDisabledState)), this.control.updateValueAndValidity({ emitEvent: !1 }); }
    _setupWithForm(e) { this.isCustomControlBased ? this.setupCustomControl() : (this.valueAccessor ??= this.selectedValueAccessor, Z(this.control, this, e)); }
    _checkForErrors() { this._checkName(); }
    _checkName() { this.options && this.options.name && (this.name = this.options.name), !this._isStandalone() && this.name; }
    _updateValue(e) { Ee.then(() => { this.control.setValue(e, { emitViewToModelChange: !1 }), this._changeDetectorRef?.markForCheck(); }); }
    _updateDisabled(e) { let i = e.isDisabled.currentValue, r = i !== 0 && oe(i); Ee.then(() => { r && !this.control.disabled ? this.control.disable() : !r && this.control.disabled && this.control.enable(), this._changeDetectorRef?.markForCheck(); }); }
    _getPath(e) { return this._parent ? te(e, this._parent) : [e]; }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(u, 9), s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10), s.\u0275\u0275directiveInject(v, 10), s.\u0275\u0275directiveInject(ae, 8), s.\u0275\u0275directiveInject(E, 8), s.\u0275\u0275directiveInject(s.Injector, 8), s.\u0275\u0275directiveInject(s.Renderer2, 8)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "ngModel", "", 3, "formControlName", "", 3, "formControl", ""]], inputs: { name: "name", isDisabled: [0, "disabled", "isDisabled"], model: [0, "ngModel", "model"], options: [0, "ngModelOptions", "options"] }, outputs: { update: "ngModelChange" }, exportAs: ["ngModel"], standalone: !1, features: [s.\u0275\u0275ProvidersFeature([un, ve]), s.\u0275\u0275InheritDefinitionFeature, s.\u0275\u0275NgOnChangesFeature, s.\u0275\u0275ControlFeature(null)] });
} return n; })();
var ii = (() => { class n {
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["form", 3, "ngNoForm", "", 3, "ngNativeValidate", ""]], hostAttrs: ["novalidate", ""], standalone: !1 });
} return n; })(), cn = { provide: v, useExisting: l(() => hn), multi: !0 }, hn = (() => { class n extends A {
    writeValue(e) { let i = e ?? ""; this.setProperty("value", i); }
    registerOnChange(e) { this.onChange = i => { e(i == "" ? null : parseFloat(i)); }; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "number", "formControlName", "", 3, "ngNoCva", ""], ["input", "type", "number", "formControl", "", 3, "ngNoCva", ""], ["input", "type", "number", "ngModel", "", 3, "ngNoCva", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("input", function (a) { return r.onChange(a.target.value); })("blur", function () { return r.onTouched(); }); }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([cn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), fn = { provide: v, useExisting: l(() => pn), multi: !0 };
var gn = (() => { class n {
    _accessors = [];
    add(e, i) { this._accessors.push([e, i]); }
    remove(e) { for (let i = this._accessors.length - 1; i >= 0; --i)
        if (this._accessors[i][1] === e) {
            this._accessors.splice(i, 1);
            return;
        } }
    select(e) { this._accessors.forEach(i => { this._isSameGroup(i, e) && i[1] !== e && i[1].fireUncheck(e.value); }); }
    _isSameGroup(e, i) { return e[0].control ? e[0]._parent === i._control._parent && e[1].name === i.name : !1; }
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275prov = s.\u0275\u0275defineService({ token: n, factory: n.\u0275fac });
} return n; })(), pn = (() => { class n extends A {
    _registry;
    _injector;
    _state;
    _control;
    _fn;
    setDisabledStateFired = !1;
    onChange = () => { };
    name;
    formControlName;
    value;
    callSetDisabledState = I(E, { optional: !0 }) ?? U;
    constructor(e, i, r, o) { super(e, i), this._registry = r, this._injector = o; }
    ngOnInit() { this._control = this._injector.get(p), this._checkName(), this._registry.add(this._control, this); }
    ngOnDestroy() { this._registry.remove(this); }
    writeValue(e) { this._state = e === this.value, this.setProperty("checked", this._state); }
    registerOnChange(e) { this._fn = e, this.onChange = () => { e(this.value), this._registry.select(this); }; }
    setDisabledState(e) { (this.setDisabledStateFired || e || this.callSetDisabledState === "whenDisabledForLegacyCode") && this.setProperty("disabled", e), this.setDisabledStateFired = !0; }
    fireUncheck(e) { this.writeValue(e); }
    _checkName() { this.name && this.formControlName && (this.name, this.formControlName), !this.name && this.formControlName && (this.name = this.formControlName); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(s.Renderer2), s.\u0275\u0275directiveInject(s.ElementRef), s.\u0275\u0275directiveInject(gn), s.\u0275\u0275directiveInject(s.Injector)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "radio", "formControlName", "", 3, "ngNoCva", ""], ["input", "type", "radio", "formControl", "", 3, "ngNoCva", ""], ["input", "type", "radio", "ngModel", "", 3, "ngNoCva", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("change", function () { return r.onChange(); })("blur", function () { return r.onTouched(); }); }, inputs: { name: "name", formControlName: "formControlName", value: "value" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([fn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), mn = { provide: v, useExisting: l(() => vn), multi: !0 }, vn = (() => { class n extends A {
    writeValue(e) { this.setProperty("value", parseFloat(e)); }
    registerOnChange(e) { this.onChange = i => { e(i == "" ? null : parseFloat(i)); }; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["input", "type", "range", "formControlName", "", 3, "ngNoCva", ""], ["input", "type", "range", "formControl", "", 3, "ngNoCva", ""], ["input", "type", "range", "ngModel", "", 3, "ngNoCva", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("change", function (a) { return r.onChange(a.target.value); })("input", function (a) { return r.onChange(a.target.value); })("blur", function () { return r.onTouched(); }); }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([mn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), G = class extends x {
    constructor(t, e, i) { super(he(e), fe(i, e)), this.controls = t, this._initObservables(), this._setUpdateStrategy(e), this._setUpControls(), this.updateValueAndValidity({ onlySelf: !0, emitEvent: !!this.asyncValidator }); }
    controls;
    at(t) { return this.controls[this._adjustIndex(t)]; }
    push(t, e = {}) { Array.isArray(t) ? t.forEach(i => { this.controls.push(i), this._registerControl(i); }) : (this.controls.push(t), this._registerControl(t)), this.updateValueAndValidity({ emitEvent: e.emitEvent }), this._onCollectionChange(); }
    insert(t, e, i = {}) { this.controls.splice(t, 0, e), this._registerControl(e), this.updateValueAndValidity({ emitEvent: i.emitEvent }); }
    removeAt(t, e = {}) { let i = this._adjustIndex(t); i < 0 && (i = 0), this.controls[i] && this.controls[i]._registerOnCollectionChange(() => { }), this.controls.splice(i, 1), this.updateValueAndValidity({ emitEvent: e.emitEvent }); }
    setControl(t, e, i = {}) { let r = this._adjustIndex(t); r < 0 && (r = 0), this.controls[r] && this.controls[r]._registerOnCollectionChange(() => { }), this.controls.splice(r, 1), e && (this.controls.splice(r, 0, e), this._registerControl(e)), this.updateValueAndValidity({ emitEvent: i.emitEvent }), this._onCollectionChange(); }
    get length() { return this.controls.length; }
    setValue(t, e = {}) { g(() => { Ye(this, !1, t), t.forEach((i, r) => { Xe(this, !1, r), this.at(r).setValue(i, { onlySelf: !0, emitEvent: e.emitEvent }); }), this.updateValueAndValidity(e); }); }
    patchValue(t, e = {}) { t != null && (t.forEach((i, r) => { this.at(r) && this.at(r).patchValue(i, { onlySelf: !0, emitEvent: e.emitEvent }); }), this.updateValueAndValidity(e)); }
    reset(t = [], e = {}) { this._forEachChild((i, r) => { i.reset(t[r], f(c({}, e), { onlySelf: !0 })); }), this._updatePristine(e, this), this._updateTouched(e, this), this.updateValueAndValidity(e), e?.emitEvent !== !1 && this._events.next(new D(this)); }
    getRawValue() { return this.controls.map(t => t.getRawValue()); }
    clear(t = {}) { this.controls.length < 1 || (this._forEachChild(e => e._registerOnCollectionChange(() => { })), this.controls.splice(0), this.updateValueAndValidity({ emitEvent: t.emitEvent })); }
    _adjustIndex(t) { return t < 0 ? t + this.length : t; }
    _syncPendingControls() { let t = this.controls.reduce((e, i) => i._syncPendingControls() ? !0 : e, !1); return t && this.updateValueAndValidity({ onlySelf: !0 }), t; }
    _forEachChild(t) { this.controls.forEach((e, i) => { t(e, i); }); }
    _updateValue() { this.value = this.controls.filter(t => t.enabled || this.disabled).map(t => t.value); }
    _anyControls(t) { return this.controls.some(e => e.enabled && t(e)); }
    _setUpControls() { this._forEachChild(t => this._registerControl(t)); }
    _allControlsDisabled() { for (let t of this.controls)
        if (t.enabled)
            return !1; return this.controls.length > 0 || this.disabled; }
    _registerControl(t) { t.setParent(this), t._registerOnCollectionChange(this._onCollectionChange); }
    _find(t) { return this.at(t) ?? null; }
}, ri = G, si = n => n instanceof G, _e = (() => { class n extends u {
    callSetDisabledState;
    get submitted() { return g(this._submittedReactive); }
    set submitted(e) { this._submittedReactive.set(e); }
    _submitted = S(() => this._submittedReactive());
    _submittedReactive = w(!1);
    _oldForm;
    _onCollectionChange = () => this._updateDomValue();
    directives = [];
    constructor(e, i, r) { super(), this.callSetDisabledState = r, this._setValidators(e), this._setAsyncValidators(i); }
    ngOnChanges(e) { this.onChanges(e); }
    ngOnDestroy() { this.onDestroy(); }
    onChanges(e) { this._checkFormPresent(), e.hasOwnProperty("form") && (this._updateValidators(), this._updateDomValue(), this._updateRegistrations(), this._oldForm = this.form); }
    onDestroy() { this.form && (K(this.form, this), this.form._onCollectionChange === this._onCollectionChange && this.form._registerOnCollectionChange(() => { })); }
    get formDirective() { return this; }
    get path() { return []; }
    addControl(e) { let i = this.form.get(e.path); return e._setupWithForm(i, this.callSetDisabledState), i.updateValueAndValidity({ emitEvent: !1 }), this.directives.push(e), i; }
    getControl(e) { return this.form.get(e.path); }
    removeControl(e) { X(e.control || null, e, !1), rn(this.directives, e); }
    addFormGroup(e) { this._setUpFormContainer(e); }
    removeFormGroup(e) { this._cleanUpFormContainer(e); }
    getFormGroup(e) { return this.form.get(e.path); }
    getFormArray(e) { return this.form.get(e.path); }
    addFormArray(e) { this._setUpFormContainer(e); }
    removeFormArray(e) { this._cleanUpFormContainer(e); }
    updateModel(e, i) { this.form.get(e.path).setValue(i); }
    onReset() { this.resetForm(); }
    resetForm(e = void 0, i = {}) { this.form.reset(e, i), this._submittedReactive.set(!1); }
    onSubmit(e) { return this.submitted = !0, nt(this.form, this.directives), this.ngSubmit.emit(e), this.form._events.next(new z(this.control)), e?.target?.method === "dialog"; }
    _updateDomValue() { this.directives.forEach(e => { let i = e.control, r = this.form.get(e.path); i !== r && (X(i || null, e), on(r) && e._setupWithForm(r, this.callSetDisabledState)); }), this.form._updateTreeValidity({ emitEvent: !1 }); }
    _setUpFormContainer(e) { let i = this.form.get(e.path); tt(i, e), i.updateValueAndValidity({ emitEvent: !1 }); }
    _cleanUpFormContainer(e) { let i = this.form?.get(e.path); i && en(i, e) && i.updateValueAndValidity({ emitEvent: !1 }); }
    _updateRegistrations() { this.form._registerOnCollectionChange(this._onCollectionChange), this._oldForm?._registerOnCollectionChange(() => { }); }
    _updateValidators() { pe(this.form, this), this._oldForm && K(this._oldForm, this); }
    _checkFormPresent() { this.form; }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10), s.\u0275\u0275directiveInject(E, 8)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, features: [s.\u0275\u0275InheritDefinitionFeature, s.\u0275\u0275NgOnChangesFeature] });
} return n; })(), _n = { provide: u, useExisting: l(() => yn) }, yn = (() => { class n extends _e {
    form = null;
    ngSubmit = new _;
    get control() { return this.form; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formArray", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("submit", function (a) { return r.onSubmit(a); })("reset", function () { return r.onReset(); }); }, inputs: { form: [0, "formArray", "form"] }, outputs: { ngSubmit: "ngSubmit" }, exportAs: ["ngForm"], standalone: !1, features: [s.\u0275\u0275ProvidersFeature([_n]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), ye = new b(""), Cn = { provide: p, useExisting: l(() => Vn) }, Vn = (() => { class n extends p {
    _ngModelWarningConfig;
    callSetDisabledState;
    viewModel;
    form;
    set isDisabled(e) { }
    model;
    update = new _;
    static _ngModelWarningSentOnce = !1;
    _ngModelWarningSent = !1;
    constructor(e, i, r, o, a, h, m) { super(m, h, r), this._ngModelWarningConfig = o, this.callSetDisabledState = a, this._setValidators(e), this._setAsyncValidators(i); }
    ngOnChanges(e) { if (this._isControlChanged(e)) {
        let i = e.form.previousValue;
        i && (X(i, this, !1), this.removeParseErrorsValidator(i)), this.isCustomControlBased ? this.setupCustomControl() : (this.valueAccessor ??= this.selectedValueAccessor, Z(this.form, this, this.callSetDisabledState)), this.form.updateValueAndValidity({ emitEvent: !1 });
    } me(e, this.viewModel) && (this.form.setValue(this.model), this.viewModel = this.model); }
    ngOnDestroy() { this.form && X(this.form, this, !1); }
    get path() { return []; }
    get control() { return this.form; }
    viewToModelUpdate(e) { this.viewModel = e, this.update.emit(e); }
    _isControlChanged(e) { return e.hasOwnProperty("form"); }
    \u0275ngControlCreate(e) { super.ngControlCreate(e); }
    \u0275ngControlUpdate(e) { super.ngControlUpdate(e, !0); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10), s.\u0275\u0275directiveInject(v, 10), s.\u0275\u0275directiveInject(ye, 8), s.\u0275\u0275directiveInject(E, 8), s.\u0275\u0275directiveInject(s.Renderer2, 8), s.\u0275\u0275directiveInject(s.Injector, 8)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formControl", ""]], inputs: { form: [0, "formControl", "form"], isDisabled: [0, "disabled", "isDisabled"], model: [0, "ngModel", "model"] }, outputs: { update: "ngModelChange" }, exportAs: ["ngForm"], standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Cn, ve]), s.\u0275\u0275InheritDefinitionFeature, s.\u0275\u0275NgOnChangesFeature, s.\u0275\u0275ControlFeature(null)] });
} return n; })(), Dn = { provide: u, useExisting: l(() => st) }, st = (() => { class n extends rt {
    name = null;
    constructor(e, i, r) { super(), this._parent = e, this._setValidators(i), this._setAsyncValidators(r); }
    _checkParentType() { at(this._parent); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(u, 13), s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formGroupName", ""]], inputs: { name: [0, "formGroupName", "name"] }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Dn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), bn = { provide: u, useExisting: l(() => ot) }, ot = (() => { class n extends u {
    _parent;
    name = null;
    constructor(e, i, r) { super(), this._parent = e, this._setValidators(i), this._setAsyncValidators(r); }
    ngOnInit() { at(this._parent), this.formDirective.addFormArray(this); }
    ngOnDestroy() { this.formDirective?.removeFormArray(this); }
    get control() { return this.formDirective.getFormArray(this); }
    get formDirective() { return this._parent ? this._parent.formDirective : null; }
    get path() { return te(this.name == null ? this.name : this.name.toString(), this._parent); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(u, 13), s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formArrayName", ""]], inputs: { name: [0, "formArrayName", "name"] }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([bn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })();
function at(n) { return !(n instanceof st) && !(n instanceof _e) && !(n instanceof ot); }
var An = { provide: p, useExisting: l(() => Mn) }, Mn = (() => { class n extends p {
    _ngModelWarningConfig;
    _added = !1;
    viewModel;
    control;
    name = null;
    set isDisabled(e) { }
    model;
    update = new _;
    static _ngModelWarningSentOnce = !1;
    _ngModelWarningSent = !1;
    constructor(e, i, r, o, a, h, m) { super(m, h, o), this._ngModelWarningConfig = a, this._parent = e, this._setValidators(i), this._setAsyncValidators(r); }
    _setupWithForm(e, i) { this.control = e, this.isCustomControlBased ? this.setupCustomControl() : (this.valueAccessor ??= this.selectedValueAccessor, Z(e, this, i)); }
    ngOnChanges(e) { this._added || this._setUpControl(), me(e, this.viewModel) && (this.viewModel = this.model, this.formDirective.updateModel(this, this.model)); }
    ngOnDestroy() { this.formDirective?.removeControl(this); }
    viewToModelUpdate(e) { this.viewModel = e, this.update.emit(e); }
    get path() { return te(this.name == null ? this.name : this.name.toString(), this._parent); }
    get formDirective() { return this._parent ? this._parent.formDirective : null; }
    _setUpControl() { this.control = this.formDirective.addControl(this), this._added = !0; }
    \u0275ngControlCreate(e) { super.ngControlCreate(e); }
    \u0275ngControlUpdate(e) { this.isCustomControlBased && (this._added || this._setUpControl(), super.ngControlUpdate(e, !0)); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(u, 13), s.\u0275\u0275directiveInject(d, 10), s.\u0275\u0275directiveInject(V, 10), s.\u0275\u0275directiveInject(v, 10), s.\u0275\u0275directiveInject(ye, 8), s.\u0275\u0275directiveInject(s.Renderer2, 8), s.\u0275\u0275directiveInject(s.Injector, 8)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formControlName", ""]], inputs: { name: [0, "formControlName", "name"], isDisabled: [0, "disabled", "isDisabled"], model: [0, "ngModel", "model"] }, outputs: { update: "ngModelChange" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([An, ve]), s.\u0275\u0275InheritDefinitionFeature, s.\u0275\u0275NgOnChangesFeature, s.\u0275\u0275ControlFeature(null)] });
} return n; })();
var En = { provide: u, useExisting: l(() => Fn) }, Fn = (() => { class n extends _e {
    form = null;
    ngSubmit = new _;
    get control() { return this.form; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["", "formGroup", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("submit", function (a) { return r.onSubmit(a); })("reset", function () { return r.onReset(); }); }, inputs: { form: [0, "formGroup", "form"] }, outputs: { ngSubmit: "ngSubmit" }, exportAs: ["ngForm"], standalone: !1, features: [s.\u0275\u0275ProvidersFeature([En]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), wn = { provide: v, useExisting: l(() => ut), multi: !0 };
function lt(n, t) { return n == null ? `${t}` : (t && typeof t == "object" && (t = "Object"), `${n}: ${t}`.slice(0, 50)); }
function Nn(n) { return n.split(":")[0]; }
var ut = (() => { class n extends A {
    value;
    _optionMap = new Map;
    _idCounter = 0;
    set compareWith(e) { this._compareWith = e; }
    _compareWith = Object.is;
    appRefInjector = I(mt).injector;
    destroyRef = I(Ne);
    cdr = I(ae);
    _queuedWrite = !1;
    _writeValueAfterRender() { this._queuedWrite || this.appRefInjector.destroyed || (this._queuedWrite = !0, vt({ write: () => { this.destroyRef.destroyed || (this._queuedWrite = !1, this.writeValue(this.value)); } }, { injector: this.appRefInjector })); }
    writeValue(e) { this.cdr.markForCheck(), this.value = e; let i = this._getOptionId(e), r = lt(i, e); this.setProperty("value", r); }
    registerOnChange(e) { this.onChange = i => { this.value = this._getOptionValue(i), e(this.value); }; }
    _registerOption() { return (this._idCounter++).toString(); }
    _getOptionId(e) { for (let i of this._optionMap.keys())
        if (this._compareWith(this._optionMap.get(i), e))
            return i; return null; }
    _getOptionValue(e) { let i = Nn(e); return this._optionMap.has(i) ? this._optionMap.get(i) : e; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["select", "formControlName", "", 3, "multiple", "", 3, "ngNoCva", ""], ["select", "formControl", "", 3, "multiple", "", 3, "ngNoCva", ""], ["select", "ngModel", "", 3, "multiple", "", 3, "ngNoCva", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("change", function (a) { return r.onChange(a.target.value); })("blur", function () { return r.onTouched(); }); }, inputs: { compareWith: "compareWith" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([wn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), oi = (() => { class n {
    _element;
    _renderer;
    _select;
    id;
    constructor(e, i, r) { this._element = e, this._renderer = i, this._select = r, this._select && (this.id = this._select._registerOption()); }
    set ngValue(e) { this._select != null && (this._select._optionMap.set(this.id, e), this._setElementValue(lt(this.id, e)), this._select._writeValueAfterRender()); }
    set value(e) { this._setElementValue(e), this._select?._writeValueAfterRender(); }
    _setElementValue(e) { this._renderer.setProperty(this._element.nativeElement, "value", e); }
    ngOnDestroy() { this._select?._optionMap.delete(this.id), this._select?._writeValueAfterRender(); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(s.ElementRef), s.\u0275\u0275directiveInject(s.Renderer2), s.\u0275\u0275directiveInject(ut, 9)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["option"]], inputs: { ngValue: "ngValue", value: "value" }, standalone: !1 });
} return n; })(), Sn = { provide: v, useExisting: l(() => dt), multi: !0 };
function Fe(n, t) { return n == null ? `${t}` : (typeof t == "string" && (t = `'${t}'`), t && typeof t == "object" && (t = "Object"), `${n}: ${t}`.slice(0, 50)); }
function In(n) { return n.split(":")[0]; }
var dt = (() => { class n extends A {
    value;
    _optionMap = new Map;
    _idCounter = 0;
    set compareWith(e) { this._compareWith = e; }
    _compareWith = Object.is;
    writeValue(e) { this.value = e; let i; if (Array.isArray(e)) {
        let r = e.map(o => this._getOptionId(o));
        i = (o, a) => { o._setSelected(r.indexOf(a) > -1); };
    }
    else
        i = r => { r._setSelected(!1); }; this._optionMap.forEach(i); }
    registerOnChange(e) { this.onChange = i => { let r = [], o = i.selectedOptions; if (o !== void 0) {
        let a = o;
        for (let h = 0; h < a.length; h++) {
            let m = a[h], R = this._getOptionValue(m.value);
            r.push(R);
        }
    }
    else {
        let a = i.options;
        for (let h = 0; h < a.length; h++) {
            let m = a[h];
            if (m.selected) {
                let R = this._getOptionValue(m.value);
                r.push(R);
            }
        }
    } this.value = r, e(r); }; }
    _registerOption(e) { let i = (this._idCounter++).toString(); return this._optionMap.set(i, e), i; }
    _getOptionId(e) { for (let i of this._optionMap.keys())
        if (this._compareWith(this._optionMap.get(i)._value, e))
            return i; return null; }
    _getOptionValue(e) { let i = In(e); return this._optionMap.has(i) ? this._optionMap.get(i)._value : e; }
    static \u0275fac = (() => { let e; return function (r) { return (e || (e = s.\u0275\u0275getInheritedFactory(n)))(r || n); }; })();
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["select", "multiple", "", "formControlName", "", 3, "ngNoCva", ""], ["select", "multiple", "", "formControl", "", 3, "ngNoCva", ""], ["select", "multiple", "", "ngModel", "", 3, "ngNoCva", ""]], hostBindings: function (i, r) { i & 1 && s.\u0275\u0275listener("change", function (a) { return r.onChange(a.target); })("blur", function () { return r.onTouched(); }); }, inputs: { compareWith: "compareWith" }, standalone: !1, features: [s.\u0275\u0275ProvidersFeature([Sn]), s.\u0275\u0275InheritDefinitionFeature] });
} return n; })(), ai = (() => { class n {
    _element;
    _renderer;
    _select;
    id;
    _value;
    constructor(e, i, r) { this._element = e, this._renderer = i, this._select = r, this._select && (this.id = this._select._registerOption(this)); }
    set ngValue(e) { this._select != null && (this._value = e, this._setElementValue(Fe(this.id, e)), this._select.writeValue(this._select.value)); }
    set value(e) { this._select ? (this._value = e, this._setElementValue(Fe(this.id, e)), this._select.writeValue(this._select.value)) : this._setElementValue(e); }
    _setElementValue(e) { this._renderer.setProperty(this._element.nativeElement, "value", e); }
    _setSelected(e) { this._renderer.setProperty(this._element.nativeElement, "selected", e); }
    ngOnDestroy() { this._select && (this._select._optionMap.delete(this.id), this._select.writeValue(this._select.value)); }
    static \u0275fac = function (i) { return new (i || n)(s.\u0275\u0275directiveInject(s.ElementRef), s.\u0275\u0275directiveInject(s.Renderer2), s.\u0275\u0275directiveInject(dt, 9)); };
    static \u0275dir = s.\u0275\u0275defineDirective({ type: n, selectors: [["option"]], inputs: { ngValue: "ngValue", value: "value" }, standalone: !1 });
} return n; })();
var ct = (() => { class n {
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275mod = s.\u0275\u0275defineNgModule({ type: n });
    static \u0275inj = s.\u0275\u0275defineInjector({});
} return n; })();
function we(n) { return !!n && (n.asyncValidators !== void 0 || n.validators !== void 0 || n.updateOn !== void 0); }
var ht = (() => { class n {
    useNonNullable = !1;
    get nonNullable() { let e = new n; return e.useNonNullable = !0, e; }
    group(e, i = null) { let r = this._reduceControls(e), o = {}; return we(i) ? o = i : i !== null && (o.validators = i.validator, o.asyncValidators = i.asyncValidator), new C(r, o); }
    record(e, i = null) { let r = this._reduceControls(e); return new Q(r, i); }
    control(e, i, r) { let o = {}; return this.useNonNullable ? (we(i) ? o = i : (o.validators = i, o.asyncValidators = r), new O(e, f(c({}, o), { nonNullable: !0 }))) : new O(e, i, r); }
    array(e, i, r) { let o = e.map(a => this._createControl(a)); return new G(o, i, r); }
    _reduceControls(e) { let i = {}; return Object.keys(e).forEach(r => { i[r] = this._createControl(e[r]); }), i; }
    _createControl(e) { if (e instanceof O)
        return e; if (e instanceof x)
        return e; if (Array.isArray(e)) {
        let i = e[0], r = e.length > 1 ? e[1] : null, o = e.length > 2 ? e[2] : null;
        return this.control(i, r, o);
    }
    else
        return this.control(e); }
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275prov = s.\u0275\u0275defineService({ token: n, factory: n.\u0275fac });
} return n; })(), li = (() => { class n {
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275prov = s.\u0275\u0275defineService({ token: n, factory: () => I(ht).nonNullable });
} return n; })(), ui = (() => { class n extends ht {
    group(e, i = null) { return super.group(e, i); }
    control(e, i, r) { return super.control(e, i, r); }
    array(e, i, r) { return super.array(e, i, r); }
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275prov = s.\u0275\u0275defineService({ token: n, factory: n.\u0275fac });
} return n; })(), di = (() => { class n {
    static withConfig(e) { return { ngModule: n, providers: [{ provide: E, useValue: e.callSetDisabledState ?? U }] }; }
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275mod = s.\u0275\u0275defineNgModule({ type: n });
    static \u0275inj = s.\u0275\u0275defineInjector({ imports: [ct] });
} return n; })(), ci = (() => { class n {
    static withConfig(e) { return { ngModule: n, providers: [{ provide: ye, useValue: e.warnOnNgModelWithFormControl ?? "always" }, { provide: E, useValue: e.callSetDisabledState ?? U }] }; }
    static \u0275fac = function (i) { return new (i || n); };
    static \u0275mod = s.\u0275\u0275defineNgModule({ type: n });
    static \u0275inj = s.\u0275\u0275defineInjector({ imports: [ct] });
} return n; })();
export { x as AbstractControl, q as AbstractControlDirective, _e as AbstractFormDirective, rt as AbstractFormGroupDirective, Ft as COMPOSITION_BUFFER_MODE, At as CheckboxControlValueAccessor, Gt as CheckboxRequiredValidator, u as ControlContainer, y as ControlEvent, Ie as DefaultValueAccessor, Ht as EmailValidator, G as FormArray, yn as FormArrayDirective, ot as FormArrayName, ht as FormBuilder, O as FormControl, Vn as FormControlDirective, Mn as FormControlName, C as FormGroup, Fn as FormGroupDirective, st as FormGroupName, Q as FormRecord, D as FormResetEvent, z as FormSubmittedEvent, di as FormsModule, $t as MaxLengthValidator, Pt as MaxValidator, Wt as MinLengthValidator, Tt as MinValidator, V as NG_ASYNC_VALIDATORS, d as NG_VALIDATORS, v as NG_VALUE_ACCESSOR, p as NgControl, Yn as NgControlStatus, Kn as NgControlStatusGroup, it as NgForm, dn as NgModel, ln as NgModelGroup, oi as NgSelectOption, li as NonNullableFormBuilder, hn as NumberValueAccessor, Zt as PatternValidator, j as PristineChangeEvent, pn as RadioControlValueAccessor, vn as RangeValueAccessor, ci as ReactiveFormsModule, ge as RequiredValidator, ut as SelectControlValueAccessor, dt as SelectMultipleControlValueAccessor, N as StatusChangeEvent, B as TouchedChangeEvent, ri as UntypedFormArray, ui as UntypedFormBuilder, ni as UntypedFormControl, Jn as UntypedFormGroup, zn as VERSION, ie as Validators, $ as ValueChangeEvent, si as isFormArray, on as isFormControl, Qn as isFormGroup, ei as isFormRecord, Xt as \u0275FORM_CONTROL_INTEGRATION, ct as \u0275InternalFormsSharedModule, ii as \u0275NgNoValidate, ai as \u0275NgSelectMultipleOption, Zn as \u0275elementAcceptsMinMax, Ot as \u0275isNativeFormElement, Xn as \u0275isTextualFormElement, nn as \u0275selectValueAccessor, xt as \u0275setNativeDomProperty };
/*! Bundled license information:

@angular/forms/fesm2022/forms.mjs:
  (**
   * @license Angular v22.0.7
   * (c) 2010-2026 Google LLC. https://angular.dev/
   * License: MIT
   *)
*/
