"use strict";
var _this = this;
Object.defineProperty(exports, "__esModule", { value: !0 });
var core_1 = require("@angular/core"),
    http_1 = require("@angular/http"),
    testing_1 = require("@angular/core/testing"),
    testing_2 = require("@angular/http/testing"),
    connectionHandler_1 = require("./connectionHandler"),
    index_1 = require("wi-studio/index"),
    TypeMoq = require("typemoq");
exports.t1 = describe("connectionHandler tests", function () {
    beforeEach(function () {
        testing_1.TestBed.configureTestingModule({
            imports: [http_1.HttpModule],
            providers: [
                { provide: index_1.WiServiceContribution, useClass: connectionHandler_1.connectionHandler },
                { provide: http_1.XHRBackend, useClass: testing_2.MockBackend },
            ],
        });
    }),
        describe("connectionHandler", function () {
            it("should return connectionHandler", function () {
                testing_1.inject([core_1.Injector, http_1.Http], function (n, e) {
                    var t = new connectionHandler_1.connectionHandler(n, e);
                    expect(null !== t).toBeTruthy("connectionHandler not found");
                })();
            });
        }),
        describe("connectionRefFieldProvider", function () {
            it(
                "should return a field provider for :Connection Name",
                testing_1.fakeAsync(function () {
                    testing_1.inject([core_1.Injector, http_1.Http, http_1.XHRBackend], function (n, e, t) {
                        var o = [{ connector: { isValid: !0, id: "123", settings: [{ name: "name", value: "connection1" }] } }, { connector: { isValid: !0, id: "456", settings: [{ name: "name", value: "connection2" }] } }],
                            i = [
                                { unique_id: "123", name: "connection1" },
                                { unique_id: "456", name: "connection2" },
                            ];
                        expect(null !== t).toBeTruthy("Backend not found"),
                            (_this.lastConnection = null),
                            (_this.backend = t),
                            _this.backend.connections.subscribe(function (n) {
                                (_this.lastConnection = n), n.mockRespond(new http_1.Response(new http_1.ResponseOptions({ body: o })));
                            });
                        var c = new connectionHandler_1.connectionHandler(n, e),
                            r = TypeMoq.Mock.ofType();
                        c.value("Connection Name", r.object).subscribe(
                            function (n) {
                                expect(null !== n).toBeTruthy("Result is null"), expect(n).toEqual(i, "Did not return string[]");
                            },
                            function (n) {
                                expect(null === n).toBeTruthy("error is not null");
                            }
                        );
                    })();
                })
            );
        });
});
//# sourceMappingURL=connection.spec.js.map
