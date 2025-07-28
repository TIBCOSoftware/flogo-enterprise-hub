"use strict";
var __extends =
        (this && this.__extends) ||
        (function () {
            var t =
                Object.setPrototypeOf ||
                ({ __proto__: [] } instanceof Array &&
                    function (t, e) {
                        t.__proto__ = e;
                    }) ||
                function (t, e) {
                    for (var n in e) e.hasOwnProperty(n) && (t[n] = e[n]);
                };
            return function (e, n) {
                function r() {
                    this.constructor = e;
                }
                t(e, n), (e.prototype = null === n ? Object.create(n) : ((r.prototype = n.prototype), new r()));
            };
        })(),
    __decorate =
        (this && this.__decorate) ||
        function (t, e, n, r) {
            var i,
                o = arguments.length,
                a = o < 3 ? e : null === r ? (r = Object.runOwnPropertyDescriptor(e, n)) : r;
            if ("object" == typeof Reflect && "function" == typeof Reflect.decorate) a = Reflect.decorate(t, e, n, r);
            else for (var c = t.length - 1; c >= 0; c--) (i = t[c]) && (a = (o < 3 ? i(a) : o > 3 ? i(e, n, a) : i(e, n)) || a);
            return o > 3 && a && Object.defineProperty(e, n, a), a;
        },
    __metadata =
        (this && this.__metadata) ||
        function (t, e) {
            if ("object" == typeof Reflect && "function" == typeof Reflect.metadata) return Reflect.metadata(t, e);
        };
Object.defineProperty(exports, "__esModule", { value: !0 });
var core_1 = require("@angular/core"),
    http_1 = require("@angular/http"),
    Observable_1 = require("rxjs/Observable"),
    wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib"),
    //activity_jsonschema_1 = require("./activity.jsonschema"),
    runHandler = (function (t) {
        function e(e, n) {
            var r = t.call(this, e, n) || this;
            return (
                (r.injector = e),
                (r.http = n),
                (r.value = function (t, e) {
                    r.getContextVar(e, "SSH Connection");
                    //var n = r.getContextVarBool(e, "processdata"),
                    //    i = r.getContextVarBool(e, "binary");
                    switch (t) {
                        case "SSH Connection":
                            return Observable_1.Observable.create(function (t) {
                                var e = [];
                                wi_contrib_1.WiContributionUtils.getConnections(r.http, "SSH").subscribe(function (n) {
                                    n.forEach(function (t) {
                                        for (var n = 0; n < t.settings.length; n++)
                                            if ("name" === t.settings[n].name) {
                                                e.push({ unique_id: wi_contrib_1.WiContributionUtils.getUniqueId(t), name: t.settings[n].value });
                                                break;
                                            }
                                    }),
                                        t.next(e);
                                });
                            });
                        case "input":
                            return null;
                            // return Observable_1.Observable.create(function (t) {
                            //    !0 === n ? t.next(JSON.stringify(activity_jsonschema_1.Schema.PROCESS_DATA_INPUT)) : t.next(JSON.stringify(activity_jsonschema_1.Schema.FILE_TRANSFER_INPUT));
                            //});
                        case "output":
                            return null;
                            //return Observable_1.Observable.create(function (t) {
                            //    !0 === n && !0 === i
                            //        ? t.next(JSON.stringify(activity_jsonschema_1.Schema.PROCESS_DATA_BINARY_OUTPUT))
                            //        : !0 === n && !1 === i
                            //        ? t.next(JSON.stringify(activity_jsonschema_1.Schema.PROCESS_DATA_OUTPUT))
                            //        : t.next(JSON.stringify(activity_jsonschema_1.Schema.FILE_TRANSFER_OUTPUT));
                            //});
                        default:
                            return null;
                    }
                }),
                (r.validate = function (t, e) {
                    if ("SSH Connection" === t && null === r.getContextVar(e, "SSH Connection")) return wi_contrib_1.ValidationResult.newValidationResult().setError("SSH-GET-1001", "SSH Connection must be configured");
                    return null;
                }),
                (r.action = function (t, e) {
                    return Observable_1.Observable.create(function (t) {
                        var e = wi_contrib_1.ActionResult.newActionResult();
                        t.next(e);
                    });
                }),
                (r.category = "SSH"),
                r
            );
        }
        return (
            __extends(e, t),
            (e.prototype.getContextVar = function (t, e) {
                return t.getField(e) ? t.getField(e).value : "";
            }),
            (e.prototype.getContextVarBool = function (t, e) {
                var n = t.getField(e);
                return !(!n || !n.value) && n.value;
            }),
            e
        );
    })(wi_contrib_1.WiServiceHandlerContribution);
(runHandler = __decorate([wi_contrib_1.WiContrib({}), core_1.Injectable(), __metadata("design:paramtypes", [core_1.Injector, http_1.Http])], runHandler)), (exports.runHandler = runHandler);
//# sourceMappingURL=runHandler.js.map
