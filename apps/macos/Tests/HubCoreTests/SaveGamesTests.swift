import XCTest
@testable import HubCore

final class SaveTableTests: XCTestCase {
    func testEveryCatalogGameHasARow() {
        for e in Catalog.entries { XCTAssertNotNil(SaveTable.location(for: e.target), e.target) }
    }
}

final class DeviceJSONTests: XCTestCase {
    func testFilesListing() throws {
        let json = """
        {"result":{"files":[
          {"relativePath":"alyx","metadata":{"size":96},"resources":{"isDirectory":true,"isSymbolicLink":false}},
          {"relativePath":"alyx/a.sav","metadata":{"size":1234},"resources":{"isDirectory":false,"isSymbolicLink":false}}
        ]}}
        """
        let files = try XCTUnwrap(DeviceJSON.files(Data(json.utf8), subdirectory: "Documents/games"))
        XCTAssertEqual(files, [RemoteFile(path: "Documents/games/alyx", size: 96, isDirectory: true),
                               RemoteFile(path: "Documents/games/alyx/a.sav", size: 1234)])
        XCTAssertNil(DeviceJSON.files(Data(#"{"error":{"code":3}}"#.utf8), subdirectory: "x"))
    }

    func testRunningCheck() {
        let apps = #"{"result":{"apps":[{"bundleIdentifier":"com.example.Hub","url":"file:///private/var/containers/Bundle/Application/U/KleptonHub.app/"}]}}"#
        let url = DeviceJSON.appURL(Data(apps.utf8), bundle: "com.example.Hub")
        XCTAssertEqual(url, "file:///private/var/containers/Bundle/Application/U/KleptonHub.app/")
        XCTAssertNil(DeviceJSON.appURL(Data(apps.utf8), bundle: "com.example.Other"))
        let procs = #"{"result":{"runningProcesses":[{"executable":"file:///sbin/launchd"},{"executable":"file:///private/var/containers/Bundle/Application/U/KleptonHub.app/KleptonHub"}]}}"#
        let exes = DeviceJSON.processExecutables(Data(procs.utf8)) ?? []
        XCTAssertTrue(DeviceJSON.isRunning(appURL: url!, executables: exes))
        XCTAssertFalse(DeviceJSON.isRunning(appURL: url!, executables: ["file:///sbin/launchd"]))
        XCTAssertFalse(DeviceJSON.isRunning(appURL: "file:///x/KleptonHub.app", executables: ["file:///x/KleptonHub.app2/KleptonHub"]))
    }
}
