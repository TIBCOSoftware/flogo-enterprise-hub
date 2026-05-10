"use strict";
var __decorate =
    (this && this.__decorate) ||
    function (e, o, t, n) {
        var r,
            c = arguments.length,
            i = c < 3 ? o : null === n ? (n = Object.getOwnPropertyDescriptor(o, t)) : n;
        if ("object" == typeof Reflect && "function" == typeof Reflect.decorate) i = Reflect.decorate(e, o, t, n);
        else for (var u = e.length - 1; u >= 0; u--) (r = e[u]) && (i = (c < 3 ? r(i) : c > 3 ? r(o, t, i) : r(o, t)) || i);
        return c > 3 && i && Object.defineProperty(o, t, i), i;
    };
Object.defineProperty(exports, "__esModule", { value: !0 });
var wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib"),
    core_1 = require("@angular/core"),
    common_1 = require("@angular/common"),
    http_1 = require("@angular/http"),
    connectionHandler_1 = require("./connectionHandler"),
    connectionModule = (function () {
        return function () {};
    })();
(connectionModule = __decorate(
    [
        core_1.NgModule({
            imports: [common_1.CommonModule, http_1.HttpModule],
            exports: [],
            declarations: [],
            entryComponents: [],
            providers: [{ provide: wi_contrib_1.WiServiceContribution, useClass: connectionHandler_1.connectionHandler }],
            bootstrap: [],
        }),
    ],
    connectionModule
)),
    (exports.default = connectionModule);
//# sourceMappingURL=connection.module.js.map
