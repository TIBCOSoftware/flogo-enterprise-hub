"use strict";
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
Object.defineProperty(exports, "__esModule", { value: true });
var http_1 = require("@angular/http");
var core_1 = require("@angular/core");
var common_1 = require("@angular/common");
var activity_1 = require("./activity");
var wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib");
var ImageCreateActivityModule = (function () {
    function ImageCreateActivityModule() {
    }
    ImageCreateActivityModule = __decorate([
        core_1.NgModule({
            imports: [
                common_1.CommonModule,
                http_1.HttpModule
            ],
            providers: [
                {
                    provide: wi_contrib_1.WiServiceContribution,
                    useClass: activity_1.ImageCreateActivityContribution
                }
            ]
        })
    ], ImageCreateActivityModule);
    return ImageCreateActivityModule;
}());
exports.default = ImageCreateActivityModule;

//# sourceMappingURL=activity.module.js.map
