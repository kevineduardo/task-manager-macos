import XCTest
@testable import TaskManager

final class FormatTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.percent(0.04), "0%")
        XCTAssertEqual(Format.percent(5.24), "5.2%")
        XCTAssertEqual(Format.percent(150), "100.0%")
    }

    func testMemoryUsesMegabytesWithGrouping() {
        XCTAssertEqual(Format.memoryMB(130 * 1_048_576 + 314_573), "130.3 MB")
        XCTAssertEqual(Format.memoryMB(2_431 * 1_048_576), "2,431.0 MB")
    }

    func testRates() {
        XCTAssertEqual(Format.diskRate(0), "0 MB/s")
        XCTAssertEqual(Format.diskRate(1_048_576 * 1.5), "1.5 MB/s")
        XCTAssertEqual(Format.networkRate(0), "0 Mbps")
        XCTAssertEqual(Format.networkRate(125_000), "1.0 Mbps")
        XCTAssertEqual(Format.bitRate(1_400_000), "1.4 Mbps")
        XCTAssertEqual(Format.bitRate(120_000), "120 Kbps")
    }

    func testDurations() {
        XCTAssertEqual(Format.uptime(5 * 86_400 + 7 * 3600 + 55 * 60), "5:07:55:00")
        XCTAssertEqual(Format.cpuTime(3725), "1:02:05")
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(1536), "1.5 KB")
        XCTAssertEqual(Format.bytes(32 * 1_073_741_824), "32.0 GB")
    }
}

final class StartupCatalogTests: XCTestCase {
    func testKnownLabel() {
        let decoded = StartupCatalog.decode("com.google.keystone.agent")
        XCTAssertEqual(decoded.vendorKey, "google")
        XCTAssertEqual(decoded.vendor, "Google")
        XCTAssertEqual(decoded.displayName, "Google Keystone Agent")
    }

    func testUnknownLabelIsHumanized() {
        let decoded = StartupCatalog.decode("com.example.MySyncHelper")
        XCTAssertEqual(decoded.vendor, "Example")
        XCTAssertEqual(decoded.displayName, "Example My Sync Helper")
    }

    func testVendorPrefixIsNotRepeated() {
        let decoded = StartupCatalog.decode("com.docker.docker-desktop")
        XCTAssertEqual(decoded.displayName, "Docker Desktop")
    }

    func testVersionTokensAreDropped() {
        let decoded = StartupCatalog.decode("com.acme.updater.v2")
        XCTAssertEqual(decoded.displayName, "Acme Updater")
    }

    func testBundlesInPath() {
        let path = "/Applications/Foo.app/Contents/Library/LoginItems/Bar.app/Contents/MacOS/Bar"
        XCTAssertEqual(StartupCatalog.bundles(in: path), [
            "/Applications/Foo.app",
            "/Applications/Foo.app/Contents/Library/LoginItems/Bar.app",
        ])
        XCTAssertEqual(StartupCatalog.bundles(in: "/Applications/Foo.application/x"), [])
    }

    func testParseDisabled() {
        let output = """
        disabled services = {
            "com.apple.foo" => enabled
            "com.google.keystone.agent" => disabled
            "com.example.old" => true
        }
        """
        XCTAssertEqual(StartupProvider.parseDisabled(output), ["com.google.keystone.agent", "com.example.old"])
    }
}

final class ProcessClassifierTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(ProcessClassifier.kind(pid: 0, uid: 0, path: nil, isRegularApp: false), .system)
        XCTAssertEqual(ProcessClassifier.kind(pid: 500, uid: 501, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", isRegularApp: false), .system)
        XCTAssertEqual(ProcessClassifier.kind(pid: 500, uid: 501, path: "/usr/local/bin/node", isRegularApp: false), .background)
        XCTAssertEqual(ProcessClassifier.kind(pid: 500, uid: 0, path: "/Library/PrivilegedHelperTools/com.docker.vmnetd", isRegularApp: false), .background)
        XCTAssertEqual(ProcessClassifier.kind(pid: 500, uid: 501, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", isRegularApp: true), .app)
    }

    func testBundles() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(ProcessClassifier.outerBundle(of: helper), "/Applications/Google Chrome.app")
        XCTAssertEqual(ProcessClassifier.innerBundle(of: helper)?.hasSuffix("Google Chrome Helper (Renderer).app"), true)
        XCTAssertEqual(ProcessClassifier.outerBundle(of: "/usr/bin/top"), nil)
        XCTAssertEqual(ProcessClassifier.bundleName("/Applications/Google Chrome.app"), "Google Chrome")
    }
}

final class ProcessGroupingTests: XCTestCase {
    private func record(_ pid: Int32, _ name: String, ppid: Int32 = 1, responsible: Int32? = nil, path: String? = nil,
                        regular: Bool = false, kind: ProcessKind = .background, cpu: Double = 0, memory: UInt64 = 0) -> ProcessRecord {
        var r = ProcessRecord(pid: pid, ppid: ppid, responsiblePid: responsible ?? pid, uid: 501, user: "me", name: name,
                              executableName: name, path: path, bundlePath: ProcessClassifier.outerBundle(of: path),
                              bundleIdentifier: nil, isRegularApp: regular, kind: kind)
        r.cpu = cpu
        r.memory = memory
        return r
    }

    func testHelpersJoinTheirApp() {
        let records = [
            record(100, "Chrome", path: "/Applications/Chrome.app/Contents/MacOS/Chrome", regular: true, kind: .app, cpu: 2, memory: 100),
            record(101, "Chrome Helper", ppid: 100, path: "/Applications/Chrome.app/Contents/Frameworks/H.app/Contents/MacOS/H", cpu: 3, memory: 50),
            record(200, "zsh", ppid: 300, path: "/bin/zsh", kind: .system),
            record(300, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", regular: true, kind: .app),
            record(301, "node", ppid: 300, path: "/usr/local/bin/node"),
            record(400, "mdworker", path: "/System/Library/mdworker", kind: .system),
            record(401, "mdworker", path: "/System/Library/mdworker", kind: .system),
        ]
        let nodes = ProcessGrouping.build(records)

        let chrome = nodes.first { $0.name == "Chrome" }
        XCTAssertEqual(chrome?.members.map(\.pid).sorted(), [100, 101])
        XCTAssertEqual(chrome?.cpu, 5)
        XCTAssertEqual(chrome?.memory, 150)
        XCTAssertEqual(chrome?.kind, .app)

        let terminal = nodes.first { $0.name == "Terminal" }
        XCTAssertEqual(terminal?.members.map(\.pid).sorted(), [300, 301], "non-system children follow the parent app")

        let workers = nodes.first { $0.name == "mdworker" }
        XCTAssertEqual(workers?.members.count, 2)
        XCTAssertEqual(workers?.kind, .system)

        XCTAssertNotNil(nodes.first { $0.id == "pid:200" }, "system children stay in System processes")
        XCTAssertEqual(nodes.flatMap(\.members).count, records.count, "every process appears exactly once")
    }

    func testResponsibleProcessGrouping() {
        let records = [
            record(10, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", regular: true, kind: .app),
            record(11, "WebContent", responsible: 10, path: "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent", kind: .system),
        ]
        let nodes = ProcessGrouping.build(records)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].members.count, 2)
    }

    func testFilterAndRows() {
        let records = [
            record(10, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", regular: true, kind: .app),
            record(11, "Safari Helper", ppid: 10, path: "/Applications/Safari.app/Contents/MacOS/Helper"),
            record(20, "launchd", path: "/sbin/launchd", kind: .system),
        ]
        let nodes = ProcessGrouping.build(records)
        let filtered = ProcessTableBuilder.filter(nodes, query: "helper")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].members.map(\.pid), [11])

        let rows = ProcessTableBuilder.rows(nodes: nodes, groupByType: true, expanded: [], collapsedSections: [], forceExpand: false)
        XCTAssertEqual(rows.map(\.id), ["section:0", "app:/Applications/Safari.app", "section:2", "pid:20"])

        let expanded = ProcessTableBuilder.rows(nodes: nodes, groupByType: false, expanded: ["app:/Applications/Safari.app"],
                                                collapsedSections: [], forceExpand: false)
        XCTAssertEqual(expanded.count, 4)
    }

    func testSorting() {
        let nodes = ProcessGrouping.build([
            record(1, "B", path: "/x/B", cpu: 1),
            record(2, "A", path: "/x/A", cpu: 9),
            record(3, "C", path: "/x/C", cpu: 5),
        ])
        XCTAssertEqual(ProcessTableBuilder.sorted(nodes, column: .cpu, ascending: false).map(\.name), ["A", "C", "B"])
        XCTAssertEqual(ProcessTableBuilder.sorted(nodes, column: .name, ascending: true).map(\.name), ["A", "B", "C"])
    }

    func testProcessTree() {
        let records = [record(1, "root"), record(2, "child", ppid: 1), record(3, "grandchild", ppid: 2), record(4, "other", ppid: 9)]
        XCTAssertEqual(ProcessActions.processTree(of: 1, in: records).map(\.pid), [3, 2, 1])
    }
}

final class ParserTests: XCTestCase {
    func testPsTime() {
        XCTAssertEqual(ProcessSampler.parseCPUTime("0:01.50"), 1.5, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.parseCPUTime("12:34.56"), 754.56, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.parseCPUTime("1:02:03.00"), 3723, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.parseCPUTime("2-01:00:00"), 176_400, accuracy: 0.001)
    }

    func testPsOutput() {
        let parsed = ProcessSampler.parsePs("  1   0:10.00  12000\n 88  1:00.00   2048\n")
        XCTAssertEqual(parsed[1]?.rss, 12_000 * 1024)
        XCTAssertEqual(parsed[88]?.cpuSeconds ?? 0, 60, accuracy: 0.001)
    }

    func testNetTop() {
        let output = """
        ,bytes_in,bytes_out,
        Google Chrome H.1234,5120,2048,
        mDNSResponder.300,100,50,
        Google Chrome H.1234,10,0,
        """
        let totals = NetTopReader.parse(output)
        XCTAssertEqual(totals[1234], 7178)
        XCTAssertEqual(totals[300], 150)
    }

    func testLaunchctlList() {
        let output = "PID\tStatus\tLabel\n123\t0\tcom.example.agent\n-\t78\tcom.example.stopped\n"
        let items = ServicesProvider.parseList(output)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].pid, 123)
        XCTAssertTrue(items[0].isRunning)
        XCTAssertNil(items[1].pid)
        XCTAssertEqual(items[1].lastExitStatus, 78)
    }

    func testLaunchctlPrint() {
        let output = """
        system = {
            services = {
                     0      -   com.apple.idle
                   345      0   com.apple.running
            }
        }
        """
        let items = ServicesProvider.parsePrintServices(output, domain: .system)
        XCTAssertEqual(items.map(\.label), ["com.apple.idle", "com.apple.running"])
        XCTAssertEqual(items[1].pid, 345)
        XCTAssertFalse(items[0].isRunning)
    }

    func testGPUCreator() {
        XCTAssertEqual(GPUSampler.pid(fromCreator: "pid 412, WindowServer"), 412)
        XCTAssertNil(GPUSampler.pid(fromCreator: "WindowServer"))
    }

    func testChartScale() {
        XCTAssertEqual(ChartScale.niceCeiling(0), 1)
        XCTAssertEqual(ChartScale.niceCeiling(0.8), 1)
        XCTAssertEqual(ChartScale.niceCeiling(130), 200)
        XCTAssertEqual(ChartScale.niceCeiling(4_100_000), 5_000_000)
    }

    func testPowerLevels() {
        XCTAssertEqual(PowerLevel.estimate(watts: 0.05, cpuPercent: 50), .veryLow)
        XCTAssertEqual(PowerLevel.estimate(watts: nil, cpuPercent: 30), .veryHigh)
        XCTAssertEqual(PowerLevel.estimate(watts: 3, cpuPercent: 0), .high)
    }
}

final class SamplerSmokeTests: XCTestCase {
    func testSamplersReturnPlausibleData() {
        let cpu = CPUSampler()
        _ = cpu.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let sample = cpu.sample()
        XCTAssertEqual(sample.perCore.count, MachineInfo.current.logicalCores)
        XCTAssertTrue((0...100).contains(sample.total))

        let memory = MemorySampler().sample()
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)

        let processes = ProcessSampler().sample(options: .init(includeNetwork: false), apps: [:], efficiencyPids: [])
        XCTAssertGreaterThan(processes.count, 10)
        XCTAssertTrue(processes.contains { $0.pid == getpid() })
        XCTAssertTrue(processes.contains { $0.pid == 1 && $0.kind == .system })

        _ = NetworkSampler().sample()
        _ = DiskSampler().sample()
        _ = GPUSampler().sample(includePerProcess: true)
    }

    func testAppHistoryAccumulates() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = AppHistoryStore(fileURL: url)
        var r = ProcessRecord(pid: 42, ppid: 1, responsiblePid: 42, uid: 501, user: "me", name: "App", executableName: "App",
                              path: "/Applications/App.app/Contents/MacOS/App", bundlePath: "/Applications/App.app",
                              bundleIdentifier: nil, isRegularApp: true, kind: .app)
        r.cpuTime = 10
        store.ingest(ProcessGrouping.build([r]))
        XCTAssertTrue(store.entries.isEmpty, "first sighting is only a baseline")
        r.cpuTime = 12.5
        store.ingest(ProcessGrouping.build([r]))
        XCTAssertEqual(store.entries["app:/Applications/App.app"]?.cpuTime ?? 0, 2.5, accuracy: 0.001)
        store.save()
        let reloaded = AppHistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 1)
        try? FileManager.default.removeItem(at: url)
    }
}
