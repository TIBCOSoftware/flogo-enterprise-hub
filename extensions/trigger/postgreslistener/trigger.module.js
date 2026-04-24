"use strict";
var __decorate = this && this.__decorate || function (e, t, i, a) {
    var n, r = arguments.length, s = r < 3 ? t : null === a ? a = Object.getOwnPropertyDescriptor(t, i) : a;
    if ("object" == typeof Reflect && "function" == typeof Reflect.decorate) s = Reflect.decorate(e, t, i, a);
    else for (var o = e.length - 1; o >= 0; o--) (n = e[o]) && (s = (r < 3 ? n(s) : r > 3 ? n(t, i, s) : n(t, i)) || s);
    return r > 3 && s && Object.defineProperty(t, i, s), s;
};
Object.defineProperty(exports, "__esModule", { value: true });

var wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib");
var core_1 = require("@angular/core");
var common_1 = require("@angular/common");
var http_1 = require("@angular/http");
var handler_1 = require("./trigger");

var PostgresListenerModule = function () {
    function e() { }
    return e = __decorate([core_1.NgModule({
        imports: [common_1.CommonModule, http_1.HttpModule],
        exports: [],
        declarations: [],
        entryComponents: [],
        providers: [{ provide: wi_contrib_1.WiServiceContribution, useClass: handler_1.PostgresListenerHandler }],
        bootstrap: []
    })], e);
}();

exports.default = PostgresListenerModule;
