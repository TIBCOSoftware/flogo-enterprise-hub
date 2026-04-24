"use strict";
var __extends = this && this.__extends || function () {
    var e = function (t, i) {
        return (e = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function (e, t) { e.__proto__ = t; } || function (e, t) { for (var i in t) Object.prototype.hasOwnProperty.call(t, i) && (e[i] = t[i]); })(t, i);
    };
    return function (t, i) {
        if ("function" != typeof i && null !== i) throw new TypeError("Class extends value " + String(i) + " is not a constructor or null");
        function a() { this.constructor = t; }
        e(t, i), t.prototype = null === i ? Object.create(i) : (a.prototype = i.prototype, new a());
    };
}();
var __decorate = this && this.__decorate || function (e, t, i, a) {
    var n, r = arguments.length, s = r < 3 ? t : null === a ? a = Object.getOwnPropertyDescriptor(t, i) : a;
    if ("object" == typeof Reflect && "function" == typeof Reflect.decorate) s = Reflect.decorate(e, t, i, a);
    else for (var o = e.length - 1; o >= 0; o--) (n = e[o]) && (s = (r < 3 ? n(s) : r > 3 ? n(t, i, s) : n(t, i)) || s);
    return r > 3 && s && Object.defineProperty(t, i, s), s;
};
var __metadata = this && this.__metadata || function (e, t) {
    if ("object" == typeof Reflect && "function" == typeof Reflect.metadata) return Reflect.metadata(e, t);
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.PostgresListenerHandler = void 0;

var core_1 = require("@angular/core");
var http_1 = require("@angular/http");
var wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib");
var validation_1 = require("wi-studio/common/models/validation");

var PostgresListenerHandler = function (e) {
    function t(t, i, a) {
        var n = e.call(this, t, i, a) || this;
        n.injector = t;
        n.http = i;
        n.contribModelService = a;

        // No connection dropdowns — nothing to populate dynamically.
        n.value = function (fieldName, settings) {
            return null;
        };

        // Control field visibility based on the "Enable TLS Configuration" toggle.
        //
        // When tlsConfig = false (default):
        //   • sslMode is visible     — user picks plain SSL mode (disable/require/verify-*)
        //   • tlsMode, cacert, clientcert, clientkey are hidden
        //
        // When tlsConfig = true:
        //   • sslMode is hidden      — SSL mode is derived from tlsMode instead
        //   • tlsMode, cacert, clientcert, clientkey are visible
        n.validate = function (fieldName, settings) {
            var tlsConfigField = settings.getField("tlsConfig");
            var tlsEnabled = tlsConfigField &&
                (tlsConfigField.value === true || tlsConfigField.value === "true");

            switch (fieldName) {
                case "sslMode":
                    return validation_1.ValidationResult.newValidationResult().setVisible(!tlsEnabled);

                case "tlsMode":
                case "cacert":
                case "clientcert":
                case "clientkey":
                    return validation_1.ValidationResult.newValidationResult().setVisible(!!tlsEnabled);

                default:
                    return null;
            }
        };

        // No wizard actions needed for this trigger.
        n.action = function (actionName, settings) {
            return null;
        };

        return n;
    }

    __extends(t, e);
    t = __decorate([
        wi_contrib_1.WiContrib({}),
        core_1.Injectable(),
        __metadata("design:paramtypes", [core_1.Injector, http_1.Http, wi_contrib_1.WiContribModelService])
    ], t);
    return t;
}(wi_contrib_1.WiServiceHandlerContribution);

exports.PostgresListenerHandler = PostgresListenerHandler;
