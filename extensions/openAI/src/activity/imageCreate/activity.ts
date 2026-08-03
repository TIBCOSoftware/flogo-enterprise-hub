/*
 * Copyright © 2024. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */

import { Observable } from "rxjs/Observable";
import "rxjs/add/observable/of";
import { Injectable, Injector, Inject } from "@angular/core";
import { Http } from "@angular/http";
import {
    WiContrib,
    WiServiceHandlerContribution,
    IValidationResult,
    ValidationResult,
    IFieldDefinition,
    IActivityContribution,
    IConnectorContribution,
    WiContributionUtils
} from "wi-studio/app/contrib/wi-contrib";

@WiContrib({})
@Injectable()
export class ImageCreateActivityContribution extends WiServiceHandlerContribution {
    constructor(@Inject(Injector) injector, private http: Http) {
        super(injector, http);
    }

    // Source of truth for supported image generation models.
    // DALL·E 2 and DALL·E 3 were deprecated by OpenAI on May 12, 2026.
    private static readonly MODELS_URL: string[] = [
        "gpt-image-1",
        "gpt-image-1-mini",
        "gpt-image-1.5",
        "gpt-image-2"
    ];

    value = (fieldName: string, context: IActivityContribution): Observable<any> | any => {
        if (fieldName === "model") {
            return ImageCreateActivityContribution.MODELS_URL;
        }
        if (fieldName === "size") {
            // All currently supported models (gpt-image family) share the
            // same standard size options. gpt-image-2 also accepts arbitrary
            // WxH values, which are handled by validate() below.
            return ["", "1024x1024", "1024x1536", "1536x1024", "auto"];
        }
        return null;
    }

    validate = (fieldName: string, context: IActivityContribution): Observable<IValidationResult> | IValidationResult => {
        const vResult = ValidationResult.newValidationResult();

        // Helper: classify the model into a family.
        // DALL·E 2 and DALL·E 3 were deprecated by OpenAI on May 12, 2026 and
        // are no longer supported. Only gpt-image-* models remain.
        const modelFamily = (m: string): "gpt-image" | "gpt-image-2" | "" => {
            if (!m) return "gpt-image";
            if (m.indexOf("gpt-image-2") === 0) return "gpt-image-2";
            if (m.indexOf("gpt-image") === 0) return "gpt-image";
            return "";
        };

        const model = String(context.getField("model").value || "");
        const family = modelFamily(model);
        const val = (n: string): string => {
            const f = context.getField(n);
            return f && f.value !== null && f.value !== undefined ? String(f.value) : "";
        };

        // -------------------- model --------------------
        if (fieldName === "model" && model !== "" && family === "") {
            return vResult.setError("OPENAI-IMG-CREATE-1000",
                "Unsupported model. DALL\u00b7E 2 and DALL\u00b7E 3 were deprecated by OpenAI on May 12, 2026. Use gpt-image-1 or gpt-image-1-mini instead.");
        }

        // -------------------- numberOfImages --------------------
        if (fieldName === "numberOfImages") {
            const raw = context.getField("numberOfImages").value;
            const n = Number(raw);
            if (raw !== null && raw !== undefined && String(raw) !== "") {
                if (!Number.isFinite(n) || n < 1 || n > 10) {
                    return vResult.setError("OPENAI-IMG-CREATE-1001",
                        "Number of Images must be between 1 and 10.");
                }
            }
        }

        // -------------------- size --------------------
        if (fieldName === "size") {
            const size = val("size");
            if (size !== "") {
                const gptStd = ["1024x1024", "1024x1536", "1536x1024", "auto"];

                if (family === "gpt-image" && gptStd.indexOf(size) < 0) {
                    return vResult.setError("OPENAI-IMG-CREATE-1012",
                        "For gpt-image models, Size must be one of: " + gptStd.join(", ") + ".");
                }
                if (family === "gpt-image-2") {
                    // Standard values OR arbitrary WxH (multiples of 16, AR 1:3-3:1, <= 3840x2160).
                    if (gptStd.indexOf(size) < 0) {
                        const m = /^(\d+)x(\d+)$/.exec(size);
                        if (!m) {
                            return vResult.setError("OPENAI-IMG-CREATE-1013",
                                "Size must be a standard preset or an arbitrary WxH value.");
                        }
                        const w = parseInt(m[1], 10);
                        const h = parseInt(m[2], 10);
                        if (w % 16 !== 0 || h % 16 !== 0) {
                            return vResult.setError("OPENAI-IMG-CREATE-1014",
                                "For 'gpt-image-2', custom width and height must be multiples of 16.");
                        }
                        if (w > 3840 || h > 2160) {
                            return vResult.setError("OPENAI-IMG-CREATE-1015",
                                "For 'gpt-image-2', custom size must not exceed 3840x2160.");
                        }
                        const ar = w / h;
                        if (ar < 1 / 3 || ar > 3) {
                            return vResult.setError("OPENAI-IMG-CREATE-1016",
                                "For 'gpt-image-2', custom aspect ratio must be between 1:3 and 3:1.");
                        }
                    }
                }
            }
        }

        // -------------------- quality --------------------
        if (fieldName === "quality") {
            const q = val("quality");
            if (q !== "") {
                const allowed = ["low", "medium", "high", "auto"];
                if (allowed.indexOf(q) < 0) {
                    return vResult.setError("OPENAI-IMG-CREATE-1022",
                        "Quality must be one of: " + allowed.join(", ") + ".");
                }
            }
        }

        // -------------------- background (transparent requires png/webp) --------------------
        if (fieldName === "background") {
            const bg = val("background");
            const of = val("outputFormat");
            if (bg === "transparent" && of !== "" && of !== "png" && of !== "webp") {
                return vResult.setError("OPENAI-IMG-CREATE-1061",
                    "Background 'transparent' requires Output Format 'png' or 'webp' (or empty).");
            }
        }

        // -------------------- outputCompression (1-100, needs webp/jpeg) --------------------
        if (fieldName === "outputCompression") {
            const raw = context.getField("outputCompression").value;
            if (raw !== null && raw !== undefined && String(raw) !== "") {
                const n = Number(raw);
                if (n !== 0) {
                    if (!Number.isFinite(n) || n < 1 || n > 100) {
                        return vResult.setError("OPENAI-IMG-CREATE-1071",
                            "Output Compression must be between 1 and 100.");
                    }
                    const of = val("outputFormat");
                    if (of !== "" && of !== "webp" && of !== "jpeg") {
                        return vResult.setError("OPENAI-IMG-CREATE-1072",
                            "Output Compression only applies when Output Format is 'webp' or 'jpeg'.");
                    }
                }
            }
        }

        return null;
    }
}
