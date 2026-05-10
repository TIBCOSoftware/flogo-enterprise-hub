"use strict";
var __extends =
        (this && this.__extends) ||
        (function () {
            var e =
                Object.setPrototypeOf ||
                ({ __proto__: [] } instanceof Array &&
                    function (e, t) {
                        e.__proto__ = t;
                    }) ||
                function (e, t) {
                    for (var n in t) t.hasOwnProperty(n) && (e[n] = t[n]);
                };
            return function (t, n) {
                function i() {
                    this.constructor = t;
                }
                e(t, n), (t.prototype = null === n ? Object.create(n) : ((i.prototype = n.prototype), new i()));
            };
        })(),
    __decorate =
        (this && this.__decorate) ||
        function (e, t, n, i) {
            var r,
                o = arguments.length,
                c = o < 3 ? t : null === i ? (i = Object.getOwnPropertyDescriptor(t, n)) : i;
            if ("object" == typeof Reflect && "function" == typeof Reflect.decorate) c = Reflect.decorate(e, t, n, i);
            else for (var a = e.length - 1; a >= 0; a--) (r = e[a]) && (c = (o < 3 ? r(c) : o > 3 ? r(t, n, c) : r(t, n)) || c);
            return o > 3 && c && Object.defineProperty(t, n, c), c;
        },
    __metadata =
        (this && this.__metadata) ||
        function (e, t) {
            if ("object" == typeof Reflect && "function" == typeof Reflect.metadata) return Reflect.metadata(e, t);
        };
Object.defineProperty(exports, "__esModule", { value: !0 });
var core_1 = require("@angular/core"),
    http_1 = require("@angular/http"),
    Observable_1 = require("rxjs/Observable"),
    wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib"),
    Connection = (function () {
        return function () {};
    })();
exports.Connection = Connection;
var connectionHandler = (function (e) {
    function t(t, n) {
        var i = e.call(this, t, n) || this;
        return (
            (i.injector = t),
            (i.http = n),
            (i.value = function (e, t) {
                return null;
            }),
            (i.validate = function (e, t) {
                return "password" === e
                    ? Observable_1.Observable.create(function (e) {
                          i.connection(t.settings).subscribe(function (t) {
                              var n = wi_contrib_1.ValidationResult.newValidationResult();
                              !0 === t.publicKeyFlag ? n.setVisible(!1) : n.setVisible(!0), e.next(n), e.complete();
                          });
                      })
                    : "privateKey" === e
                    ? Observable_1.Observable.create(function (e) {
                          i.connection(t.settings).subscribe(function (t) {
                              var n = wi_contrib_1.ValidationResult.newValidationResult();
                              !0 === t.publicKeyFlag ? n.setVisible(!0) : n.setVisible(!1), e.next(n), e.complete();
                          });
                      })
                    : "privateKeyPassword" === e
                    ? Observable_1.Observable.create(function (e) {
                          i.connection(t.settings).subscribe(function (t) {
                              var n = wi_contrib_1.ValidationResult.newValidationResult();
                              !0 === t.publicKeyFlag ? n.setVisible(!0) : n.setVisible(!1), e.next(n), e.complete();
                          });
                      })
                    : "knownHostFile" === e
                    ? Observable_1.Observable.create(function (e) {
                          i.connection(t.settings).subscribe(function (t) {
                              var n = wi_contrib_1.ValidationResult.newValidationResult();
                              !0 === t.hostKeyFlag ? n.setVisible(!0) : n.setVisible(!1), e.next(n), e.complete();
                          });
                      })
                    : "retryCount" === e
                    ? Observable_1.Observable.create(function (e) {
                          i.connection(t.settings).subscribe(function (n) {
                              var i = wi_contrib_1.ValidationResult.newValidationResult();
                              t.getField("retryCount").value < 0 && i.setError("SSH-1001", "Connection Retry Count must be a non-negative number"), e.next(i), e.complete();
                          });
                      })
                    : "retryInterval" === e
                    ? Observable_1.Observable.create(function (e) {
                          i.connection(t.settings).subscribe(function (n) {
                              var i = wi_contrib_1.ValidationResult.newValidationResult();
                              t.getField("retryInterval").value < 0 && i.setError("SSH-1002", "Connection Retry Interval must be a non-negative number"), e.next(i), e.complete();
                          });
                      })
                    : null;
            }),
            (i.action = function (e, t) {
                if ("Save" === e)
                    return i.connection(t.settings).switchMap(function (e) {
                        return i.isDuplicate(e, wi_contrib_1.WiContributionUtils.getUniqueId(t)).switchMap(function (n) {
                            if (n)
                                return Observable_1.Observable.of(
                                    wi_contrib_1.ActionResult.newActionResult()
                                        .setSuccess(!1)
                                        .setResult(new wi_contrib_1.ValidationError("SSH-CONNECTION-1001", "Connection with name " + e.name + " already exists"))
                                );
                            var i = { context: t, authType: wi_contrib_1.AUTHENTICATION_TYPE.BASIC, authData: {} };
                            return Observable_1.Observable.of(wi_contrib_1.ActionResult.newActionResult().setSuccess(!0).setResult(i));
                        });
                    });
            }),
            (i.connection = function (e) {
                var t = new Connection();
                return Observable_1.Observable.from(e).reduce(function (e, t) {
                    return (e[t.name] = t.value), e;
                }, t);
            }),
            (i.isDuplicate = function (e, t) {
                return wi_contrib_1.WiContributionUtils.getConnections(i.http, i.category)
                    .mergeMap(function (e) {
                        return e;
                    })
                    .map(function (e) {
                        return { id: wi_contrib_1.WiContributionUtils.getUniqueId(e), ction: i.connection(e.settings) };
                    })
                    .filter(function (e) {
                        return e.id !== t;
                    })
                    .mergeMap(function (e) {
                        return e.ction;
                    })
                    .filter(function (t) {
                        return t.name === e.name;
                    })
                    .reduce(function (e, t) {
                        return e.push(t), e;
                    }, [])
                    .map(function (e) {
                        return e.length > 0;
                    });
            }),
            (i.category = "SSH"),
            i
        );
    }
    return __extends(t, e), t;
})(wi_contrib_1.WiServiceHandlerContribution);
(connectionHandler = __decorate([wi_contrib_1.WiContrib({}), core_1.Injectable(), __metadata("design:paramtypes", [core_1.Injector, http_1.Http])], connectionHandler)), (exports.connectionHandler = connectionHandler);
//# sourceMappingURL=connectionHandler.js.map
