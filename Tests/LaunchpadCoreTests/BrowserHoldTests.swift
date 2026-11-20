import XCTest
@testable import LaunchpadCore

final class BrowserHoldTests: XCTestCase {
    private func object(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    func testTheMessagesAreTheOnesTheRealServerAnswered() {
        let i = object(BrowserHold.initialize())
        XCTAssertEqual(i["method"] as? String, "initialize")
        XCTAssertEqual((i["params"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual(object(BrowserHold.initialized())["method"] as? String, "notifications/initialized")
        XCTAssertNil(object(BrowserHold.initialized())["id"])                                   // a notification has no id
        XCTAssertEqual(object(BrowserHold.ping())["method"] as? String, "ping")
        let open = object(BrowserHold.openBrowser())["params"] as? [String: Any]
        XCTAssertEqual(open?["name"] as? String, "browser_tabs")                                  // listing tabs starts the browser
        XCTAssertEqual((open?["arguments"] as? [String: Any])?["action"] as? String, "list")
        XCTAssertEqual((object(BrowserHold.closeBrowser())["params"] as? [String: Any])?["name"] as? String, "browser_close")
    }

    func testOnlyAnExplicitCloseEverClosesTheBrowser() {
        // Opening, checking and initialising never call browser_close.
        for body in [BrowserHold.initialize(), BrowserHold.initialized(), BrowserHold.ping(), BrowserHold.openBrowser()] {
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("browser_close"))
        }
    }

    func testReadingTheAnswer() {
        XCTAssertTrue(BrowserHold.succeeded(#"{"result":{"content":[{"type":"text","text":"ok"}]},"jsonrpc":"2.0","id":2}"#))
        XCTAssertTrue(BrowserHold.succeeded("event: message\ndata: {\"result\":{\"content\":[]},\"jsonrpc\":\"2.0\",\"id\":2}\n\n"))
        XCTAssertTrue(BrowserHold.succeeded(#"{"result":{},"jsonrpc":"2.0","id":4}"#))                  // a ping's answer
        XCTAssertFalse(BrowserHold.succeeded(#"{"error":{"code":-32000,"message":"Session not found"},"jsonrpc":"2.0","id":4}"#))
        XCTAssertFalse(BrowserHold.succeeded(#"{"result":{"content":[{"type":"text","text":"Error: Browser is already in use"}],"isError":true},"id":2}"#))
        XCTAssertFalse(BrowserHold.succeeded(""))
        XCTAssertFalse(BrowserHold.succeeded("not json"))
        XCTAssertFalse(BrowserHold.succeeded(#"{"jsonrpc":"2.0","id":2}"#))
    }

    func testSharedModeStaysOnSoTwoBotsDontCollide() {
        let c = Connector(id: "playwright", name: "Browser", kind: .stdio, command: "npx", args: ["-y", "@playwright/mcp@latest", "--isolated", "--headless"])
        let args = SharedBrowser.serverArguments(from: c, port: 8931, profileDir: "/p")
        XCTAssertTrue(args.contains("--shared-browser-context"))                                    // without it a second bot gets "Browser already in use"
        XCTAssertFalse(args.contains("--isolated")); XCTAssertFalse(args.contains("--headless"))     // a window you can sign in to
        XCTAssertEqual(args.last, "/p")
    }
}
