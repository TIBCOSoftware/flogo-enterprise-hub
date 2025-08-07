"use strict";
var _this = this;
Object.defineProperty(exports, "__esModule", { value: !0 });
var core_1 = require("@angular/core"),
    http_1 = require("@angular/http"),
    testing_1 = require("@angular/core/testing"),
    testing_2 = require("@angular/http/testing"),
    runHandler_1 = require("./runHandler"),
    index_1 = require("wi-studio/index"),
    TypeMoq = require("typemoq");
exports.t1 = describe("runHandler tests", function () {
    beforeEach(function () {
        testing_1.TestBed.configureTestingModule({
            imports: [http_1.HttpModule],
            providers: [
                { provide: index_1.WiServiceContribution, useClass: runHandler_1.runHandler },
                { provide: http_1.XHRBackend, useClass: testing_2.MockBackend },
            ],
        });
    }),
        describe("runHandler", function () {
            it("should return runHandler", function () {
                testing_1.inject([core_1.Injector, http_1.Http], function (e, t) {
                    var n = new runHandler_1.runHandler(e, t);
                    expect(null !== n).toBeTruthy("runHandler not found");
                })();
            });
        }),
        describe("connectionRefFieldProvider", function () {
            it(
                "should return a field provider for :Connection Name",
                testing_1.fakeAsync(function () {
                    testing_1.inject([core_1.Injector, http_1.Http, http_1.XHRBackend], function (e, t, n) {
                        var i = [{ connector: { isValid: !0, id: "123", settings: [{ name: "name", value: "connection1" }] } }, { connector: { isValid: !0, id: "456", settings: [{ name: "name", value: "connection2" }] } }],
                            o = [
                                { unique_id: "123", name: "connection1" },
                                { unique_id: "456", name: "connection2" },
                            ];
                        expect(null !== n).toBeTruthy("Backend not found"),
                            (_this.lastConnection = null),
                            (_this.backend = n),
                            _this.backend.connections.subscribe(function (e) {
                                (_this.lastConnection = e), e.mockRespond(new http_1.Response(new http_1.ResponseOptions({ body: i })));
                            });
                        var r = new runHandler_1.runHandler(e, t),
                            c = TypeMoq.Mock.ofType();
                        r.value("SSH Connection", c.object).subscribe(
                            function (e) {
                                expect(null !== e).toBeTruthy("Result is null"), expect(e).toEqual(o, "Did not return string[]");
                            },
                            function (e) {
                                expect(null === e).toBeTruthy("error is not null");
                            }
                        );
                    })();
                })
            );
        });
});
//# sourceMappingURL=run.spec.js.map
