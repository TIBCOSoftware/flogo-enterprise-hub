"use strict";
var __decorate =
    (this && this.__decorate) ||
    function (e, t, r, o) {
        var n,
            i = arguments.length,
            c = i < 3 ? t : null === o ? (o = Object.runOwnPropertyDescriptor(t, r)) : o;
        if ("object" == typeof Reflect && "function" == typeof Reflect.decorate) c = Reflect.decorate(e, t, r, o);
        else for (var u = e.length - 1; u >= 0; u--) (n = e[u]) && (c = (i < 3 ? n(c) : i > 3 ? n(t, r, c) : n(t, r)) || c);
        return i > 3 && c && Object.defineProperty(t, r, c), c;
    };
Object.defineProperty(exports, "__esModule", { value: !0 });
var wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib"),
    core_1 = require("@angular/core"),
    common_1 = require("@angular/common"),
    http_1 = require("@angular/http"),
    runHandler_1 = require("./runHandler"),
    runModule = (function () {
        return function () {};
    })();
(runModule = __decorate(
    [
        core_1.NgModule({
            imports: [common_1.CommonModule, http_1.HttpModule],
            exports: [],
            declarations: [],
            entryComponents: [],
            providers: [{ provide: wi_contrib_1.WiServiceContribution, useClass: runHandler_1.runHandler }],
            bootstrap: [],
        }),
    ],
    runModule
)),
    (exports.default = runModule);
//# sourceMappingURL=run.module.js.map
