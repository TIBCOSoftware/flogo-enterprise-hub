"use strict";
var __extends = (this && this.__extends) || (function () {
    var extendStatics = function (d, b) {
        extendStatics = Object.setPrototypeOf ||
            ({ __proto__: [] } instanceof Array && function (d, b) { d.__proto__ = b; }) ||
            function (d, b) { for (var p in b) if (b.hasOwnProperty(p)) d[p] = b[p]; };
        return extendStatics(d, b);
    };
    return function (d, b) {
        extendStatics(d, b);
        function __() { this.constructor = d; }
        d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
    };
})();
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
var __metadata = (this && this.__metadata) || function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
};
var __param = (this && this.__param) || function (paramIndex, decorator) {
    return function (target, key) { decorator(target, key, paramIndex); }
};
Object.defineProperty(exports, "__esModule", { value: true });
require("rxjs/add/observable/of");
var core_1 = require("@angular/core");
var http_1 = require("@angular/http");
var wi_contrib_1 = require("wi-studio/app/contrib/wi-contrib");
var ImageCreateActivityContribution = (function (_super) {
    __extends(ImageCreateActivityContribution, _super);
    function ImageCreateActivityContribution(injector, http) {
        var _this = _super.call(this, injector, http) || this;
        _this.http = http;
        _this.value = function (fieldName, context) {
            if (fieldName === "model") {
                return ImageCreateActivityContribution_1.MODELS_URL;
            }
            if (fieldName === "size") {
                return ["", "1024x1024", "1024x1536", "1536x1024", "auto"];
            }
            return null;
        };
        _this.validate = function (fieldName, context) {
            var vResult = wi_contrib_1.ValidationResult.newValidationResult();
            var modelFamily = function (m) {
                if (!m)
                    return "gpt-image";
                if (m.indexOf("gpt-image-2") === 0)
                    return "gpt-image-2";
                if (m.indexOf("gpt-image") === 0)
                    return "gpt-image";
                return "";
            };
            var model = String(context.getField("model").value || "");
            var family = modelFamily(model);
            var val = function (n) {
                var f = context.getField(n);
                return f && f.value !== null && f.value !== undefined ? String(f.value) : "";
            };
            if (fieldName === "model" && model !== "" && family === "") {
                return vResult.setError("OPENAI-IMG-CREATE-1000", "Unsupported model. DALL\u00b7E 2 and DALL\u00b7E 3 were deprecated by OpenAI on May 12, 2026. Use gpt-image-1 or gpt-image-1-mini instead.");
            }
            if (fieldName === "numberOfImages") {
                var raw = context.getField("numberOfImages").value;
                var n = Number(raw);
                if (raw !== null && raw !== undefined && String(raw) !== "") {
                    if (!Number.isFinite(n) || n < 1 || n > 10) {
                        return vResult.setError("OPENAI-IMG-CREATE-1001", "Number of Images must be between 1 and 10.");
                    }
                }
            }
            if (fieldName === "size") {
                var size = val("size");
                if (size !== "") {
                    var gptStd = ["1024x1024", "1024x1536", "1536x1024", "auto"];
                    if (family === "gpt-image" && gptStd.indexOf(size) < 0) {
                        return vResult.setError("OPENAI-IMG-CREATE-1012", "For gpt-image models, Size must be one of: " + gptStd.join(", ") + ".");
                    }
                    if (family === "gpt-image-2") {
                        if (gptStd.indexOf(size) < 0) {
                            var m = /^(\d+)x(\d+)$/.exec(size);
                            if (!m) {
                                return vResult.setError("OPENAI-IMG-CREATE-1013", "Size must be a standard preset or an arbitrary WxH value.");
                            }
                            var w = parseInt(m[1], 10);
                            var h = parseInt(m[2], 10);
                            if (w % 16 !== 0 || h % 16 !== 0) {
                                return vResult.setError("OPENAI-IMG-CREATE-1014", "For 'gpt-image-2', custom width and height must be multiples of 16.");
                            }
                            if (w > 3840 || h > 2160) {
                                return vResult.setError("OPENAI-IMG-CREATE-1015", "For 'gpt-image-2', custom size must not exceed 3840x2160.");
                            }
                            var ar = w / h;
                            if (ar < 1 / 3 || ar > 3) {
                                return vResult.setError("OPENAI-IMG-CREATE-1016", "For 'gpt-image-2', custom aspect ratio must be between 1:3 and 3:1.");
                            }
                        }
                    }
                }
            }
            if (fieldName === "quality") {
                var q = val("quality");
                if (q !== "") {
                    var allowed = ["low", "medium", "high", "auto"];
                    if (allowed.indexOf(q) < 0) {
                        return vResult.setError("OPENAI-IMG-CREATE-1022", "Quality must be one of: " + allowed.join(", ") + ".");
                    }
                }
            }
            if (fieldName === "background") {
                var bg = val("background");
                var of = val("outputFormat");
                if (bg === "transparent" && of !== "" && of !== "png" && of !== "webp") {
                    return vResult.setError("OPENAI-IMG-CREATE-1061", "Background 'transparent' requires Output Format 'png' or 'webp' (or empty).");
                }
            }
            if (fieldName === "outputCompression") {
                var raw = context.getField("outputCompression").value;
                if (raw !== null && raw !== undefined && String(raw) !== "") {
                    var n = Number(raw);
                    if (n !== 0) {
                        if (!Number.isFinite(n) || n < 1 || n > 100) {
                            return vResult.setError("OPENAI-IMG-CREATE-1071", "Output Compression must be between 1 and 100.");
                        }
                        var of = val("outputFormat");
                        if (of !== "" && of !== "webp" && of !== "jpeg") {
                            return vResult.setError("OPENAI-IMG-CREATE-1072", "Output Compression only applies when Output Format is 'webp' or 'jpeg'.");
                        }
                    }
                }
            }
            return null;
        };
        return _this;
    }
    ImageCreateActivityContribution_1 = ImageCreateActivityContribution;
    var ImageCreateActivityContribution_1;
    ImageCreateActivityContribution.MODELS_URL = [
        "gpt-image-1",
        "gpt-image-1-mini",
        "gpt-image-1.5",
        "gpt-image-2"
    ];
    ImageCreateActivityContribution = ImageCreateActivityContribution_1 = __decorate([
        wi_contrib_1.WiContrib({}),
        core_1.Injectable(),
        __param(0, core_1.Inject(core_1.Injector)),
        __metadata("design:paramtypes", [Object, http_1.Http])
    ], ImageCreateActivityContribution);
    return ImageCreateActivityContribution;
}(wi_contrib_1.WiServiceHandlerContribution));
exports.ImageCreateActivityContribution = ImageCreateActivityContribution;

//# sourceMappingURL=activity.js.map
