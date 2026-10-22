//
//  reader.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct device {
    public let vendor: String?
    public let model: String
    public let pci: String
    public var used: Bool
}

let vendors: [Data: String] = [
    Data.init([0x86, 0x80, 0x00, 0x00]): "Intel",
    Data.init([0x02, 0x10, 0x00, 0x00]): "AMD"
]

private func maxANEPower(for platform: Platform?) -> Double {
    switch platform {
    case .m1, .m1Pro, .m1Max:       return 2.0
    case .m1Ultra:                  return 4.0
    case .m2, .m2Pro, .m2Max:       return 2.5
    case .m2Ultra:                  return 5.0
    case .m3, .m3Pro, .m3Max:       return 3.0
    case .m3Ultra:                  return 6.0
    case .m4, .m4Pro, .m4Max:       return 6.0
    case .m5, .m5Pro, .m5Max:       return 8.0
    case .m5Ultra:                  return 16.0
    case .m6, .m6Pro, .m6Max:       return 16.0
    default:                        return 8.0
    }
}

internal class InfoReader: Reader<GPUs> {
    private var gpus: GPUs = GPUs()
    private var displays: [gpu_s] = []
    private var devices: [device] = []

    private var aneChannels: CFMutableDictionary? = nil
    private var aneSubscription: IOReportSubscriptionRef? = nil
    private var previousANEEnergy: Double = 0
    private var previousANERead: Date? = nil
    private var aneMaxPower: Double = 8.0

    private var framesChannels: CFMutableDictionary? = nil
    private var framesSubscription: IOReportSubscriptionRef? = nil
    private var previousFramesCount: Int64 = 0
    private var previousFramesTime: CFAbsoluteTime = 0
    
    public override func setup() {
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        
        guard let PCIdevices = fetchIOService("IOPCIDevice") else {
            return
        }
        let devices = PCIdevices.filter{ $0.object(forKey: "IOName") as? String == "display" }
        
        #if arch(arm64)
        self.aneMaxPower = maxANEPower(for: SystemKit.shared.device.platform)
        self.setupANE()
        self.setupFrames()
        #endif
        
        devices.forEach { (dict: NSDictionary) in
            guard let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data else {
                error("device-id or vendor-id not found", log: self.log)
                return
            }
            let pci = "0x" + Data([deviceID[1], deviceID[0], vendorID[1], vendorID[0]]).map { String(format: "%02hhX", $0) }.joined().lowercased()
            
            guard let modelData = dict["model"] as? Data, let modelName = String(data: modelData, encoding: .ascii) else {
                error("GPU model not found", log: self.log)
                return
            }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            
            var vendor: String? = nil
            if let v = vendors.first(where: { $0.key == vendorID }) {
                vendor = v.value
            }
            
            self.devices.append(device(
                vendor: vendor,
                model: model,
                pci: pci,
                used: false
            ))
        }
    }
    
    public override func read() {
        guard let accelerators = fetchIOService(kIOAcceleratorClassName) else {
            return
        }
        var devices = self.devices
        
        for (index, accelerator) in accelerators.enumerated() {
            guard let IOClass = accelerator.object(forKey: "IOClass") as? String else {
                error("IOClass not found", log: self.log)
                continue
            }
            
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else {
                error("PerformanceStatistics not found", log: self.log)
                continue
            }
            
            var id: String = ""
            var vendor: String? = nil
            var model: String = ""
            var cores: Int? = nil
            let accMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? "").lowercased()
            
            for (i, device) in devices.enumerated() {
                if accMatch.range(of: device.pci) != nil && !device.used {
                    model = device.model
                    vendor = device.vendor
                    id = "\(model) #\(index)"
                    devices[i].used = true
                    break
                }
            }
            
            let ioClass = IOClass.lowercased()
            var predictModel = ""
            var type: GPU_types = .unknown
            
            let utilization: Int? = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil
            let renderUtilization: Int? = stats["Renderer Utilization %"] as? Int ?? nil
            let tilerUtilization: Int? = stats["Tiler Utilization %"] as? Int ?? nil
            var temperature: Int? = stats["Temperature(C)"] as? Int ?? nil
            let fanSpeed: Int? = stats["Fan Speed(%)"] as? Int ?? nil
            let coreClock: Int? = stats["Core Clock(MHz)"] as? Int ?? nil
            let memoryClock: Int? = stats["Memory Clock(MHz)"] as? Int ?? nil
            
            if ioClass == "nvaccelerator" || ioClass.contains("nvidia") { // nvidia
                predictModel = "Nvidia Graphics"
                type = .discrete
            } else if ioClass.contains("amd") { // amd
                predictModel = "AMD Graphics"
                type = .discrete
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TGDD"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("intel") { // intel
                predictModel = "Intel Graphics"
                type = .integrated
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TCGC"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("agx") { // apple
                predictModel = stats["model"] as? String ?? "Apple Graphics"
                if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                    if let name = display.name {
                        predictModel = name
                    }
                    if let num = display.cores {
                        cores = num
                    }
                }
                type = .integrated
            } else {
                predictModel = "Unknown"
                type = .unknown
            }
            
            if model == "" {
                model = predictModel
            }
            if let v = vendor {
                model = model.removedRegexMatches(pattern: v, replaceWith: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if self.gpus.list.first(where: { $0.id == id }) == nil {
                self.gpus.list.append(GPU_Info(
                    id: id,
                    type: type.rawValue,
                    IOClass: IOClass,
                    vendor: vendor,
                    model: model,
                    cores: cores
                ))
            }
            guard let idx = self.gpus.list.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            if let agcInfo = accelerator["AGCInfo"] as? [String: Int], let state = agcInfo["poweredOffByAGC"] {
                self.gpus.list[idx].state = state == 0
            }
            
            if var value = utilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].utilization = Double(value)/100
            }
            if var value = renderUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].renderUtilization = Double(value)/100
            }
            if var value = tilerUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].tilerUtilization = Double(value)/100
            }
            if let value = temperature {
                self.gpus.list[idx].temperature = Double(value)
            }
            if let value = fanSpeed {
                self.gpus.list[idx].fanSpeed = value
            }
            if let value = coreClock {
                self.gpus.list[idx].coreClock = value
            }
            if let value = memoryClock {
                self.gpus.list[idx].memoryClock = value
            }
        }
        
        #if arch(arm64)
        let anePower = self.readANEPower()
        let aneUtil = anePower.map { min(1.0, max(0.0, $0 / self.aneMaxPower)) }
        let fpsValue = self.readFrames()
        for i in self.gpus.list.indices where self.gpus.list[i].IOClass.lowercased().contains("agx") {
            self.gpus.list[i].aneUtilization = aneUtil ?? 0
            self.gpus.list[i].fps = fpsValue
        }
        #endif
        
        self.gpus.list.sort{ !$0.state && $1.state }
        self.callback(self.gpus)
    }
    
    // MARK: - FPS
    
    private func setupFrames() {
        let groups = ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]
        var merged: CFMutableDictionary? = nil
        
        for group in groups {
            guard let channel = IOReportCopyChannelsInGroup(group as CFString, "swap" as CFString, 0, 0, 0)?.takeRetainedValue() else { continue }
            if merged == nil {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channel)
            } else {
                IOReportMergeChannels(merged, channel, nil)
            }
        }
        
        guard let merged, let dict = merged as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.framesChannels = merged
        var sub: Unmanaged<CFMutableDictionary>?
        self.framesSubscription = IOReportCreateSubscription(nil, merged, &sub, 0, nil)
        sub?.release()
    }
    
    private func readFrames() -> Double? {
        guard let subscription = self.framesSubscription,
              let channels = self.framesChannels,
              let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = sample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        
        var total: Int64 = 0
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group.hasPrefix("DCP"),
                  let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as? String,
                  sub == "swap" else { continue }
            total += IOReportSimpleGetIntegerValue(item, 0)
        }
        
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            self.previousFramesCount = total
            self.previousFramesTime = now
        }
        
        guard self.previousFramesTime != 0 else { return nil }
        let elapsed = now - self.previousFramesTime
        guard elapsed > 0 else { return nil }
        let delta = total - self.previousFramesCount
        guard delta >= 0 else { return nil }
        return Double(delta) / elapsed
    }
    
    // MARK: - ANE power
    
    private func setupANE() {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        
        let size = CFDictionaryGetCount(channel)
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, channel),
              let dict = mutable as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.aneChannels = mutable
        var sub: Unmanaged<CFMutableDictionary>?
        self.aneSubscription = IOReportCreateSubscription(nil, mutable, &sub, 0, nil)
        sub?.release()
    }
    
    private func readANEPower() -> Double? {
        guard let subscription = self.aneSubscription,
              let channels = self.aneChannels,
              let reportSample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = reportSample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        
        var currentEnergy: Double = 0
        var found = false
        
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String,
                  channel.starts(with: "ANE") else { continue }
            
            let raw = Double(IOReportSimpleGetIntegerValue(item, 0))
            let unit = (IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            
            let joules: Double
            switch unit.lowercased() {
            case "mj":       joules = raw / 1e3
            case "uj", "µj": joules = raw / 1e6
            case "nj":       joules = raw / 1e9
            case "pj":       joules = raw / 1e12
            default:         joules = raw / 1e9
            }
            
            currentEnergy += joules
            found = true
        }
        
        guard found else { return nil }
        
        let now = Date()
        defer {
            self.previousANEEnergy = currentEnergy
            self.previousANERead = now
        }
        
        guard let previousRead = self.previousANERead else { return 0 }
        let elapsed = now.timeIntervalSince(previousRead)
        guard elapsed > 0 else { return 0 }
        return (currentEnergy - self.previousANEEnergy) / elapsed
    }
}

// MARK: - Top processes

// Per-process GPU usage, the same source Activity Monitor's "% GPU" column uses.
// Every app that talks to the GPU owns one or more user clients under the IOAccelerator
// service in the IORegistry. Each client exposes "IOUserClientCreator" ("pid 123, Name") and
// an "AppUsage" array with the GPU time (ns) its command queues have consumed so far.
// Usage % = GPU time gained during the interval / wall time of the interval. No root needed.
public class ProcessReader: Reader<[TopProcess]> {
    private let title: String = "GPU"
    
    private struct Client {
        let id: UInt64
        let pid: Int
        let name: String
        let gpuTime: UInt64
    }
    
    private let readLock = NSLock()
    private var previousClients: [UInt64: UInt64] = [:]
    private var previousTimestamp: UInt64 = 0
    private let minimumWindow: UInt64 = 250_000_000
    
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 8)
    }
    
    public override func setup() {
        self.popup = true
        self.preview = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 1))
    }
    
    public override func read() {
        let limit = self.numberOfProcesses
        if limit == 0 {
            return
        }
        
        self.readLock.lock()
        defer { self.readLock.unlock() }
        
        // nil means the registry changed mid-walk; skip this tick rather than diff against a partial list.
        guard let clients = self.readClients() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        
        // Without a recent baseline (first read, or the popup was closed for a while) there is nothing
        // to diff against: keep this sample and measure again shortly, without blocking the caller.
        let staleAfter = UInt64(max(self.interval ?? 1, 1) * 3 * 1_000_000_000)
        if self.previousTimestamp == 0 || now - self.previousTimestamp > staleAfter {
            self.store(clients, at: now)
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.read()
            }
            return
        }
        
        // Two reads landing back to back (timer tick + settings change) would give a meaningless window.
        let elapsed = now - self.previousTimestamp
        guard elapsed >= self.minimumWindow else { return }
        
        var delta: [Int: UInt64] = [:]
        var total: [Int: UInt64] = [:]
        var names: [Int: String] = [:]
        
        for client in clients {
            // A client missing from the last sample has no baseline yet, so it starts counting from here.
            var gained: UInt64 = 0
            if let before = self.previousClients[client.id], client.gpuTime > before {
                gained = client.gpuTime - before
            }
            delta[client.pid, default: 0] += gained
            total[client.pid, default: 0] += client.gpuTime
            if names[client.pid] == nil || names[client.pid]?.isEmpty == true {
                names[client.pid] = client.name
            }
        }
        
        self.store(clients, at: now)
        
        let ranked = delta.keys.map { pid -> (pid: Int, usage: Double, total: UInt64) in
            let percent = min(Double(delta[pid] ?? 0) / Double(elapsed) * 100, 100)
            return (pid, (percent * 10).rounded() / 10, total[pid] ?? 0)
        }.sorted {
            // Busiest right now first; ties (usually idle apps at 0%) by lifetime GPU time.
            $0.usage != $1.usage ? $0.usage > $1.usage : $0.total > $1.total
        }.prefix(limit)
        
        let processes = ranked.map { item in
            TopProcess(pid: item.pid, name: self.processName(item.pid, fallback: names[item.pid] ?? ""), usage: item.usage)
        }
        
        self.callback(processes)
    }
    
    private func store(_ clients: [Client], at timestamp: UInt64) {
        var list: [UInt64: UInt64] = [:]
        clients.forEach { list[$0.id] = $0.gpuTime }
        self.previousClients = list
        self.previousTimestamp = timestamp
    }
    
    private func readClients() -> [Client]? {
        var iterator: io_iterator_t = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOAcceleratorClassName), &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        
        var list: [Client] = []
        var seen: Set<UInt64> = []
        var complete = true
        
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            complete = self.collect(accelerator, creator: nil, depth: 0, seen: &seen, into: &list) && complete
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(iterator)
        }
        
        guard complete, IOIteratorIsValid(iterator) != 0 else { return nil }
        return list
    }
    
    // Apple Silicon keeps "AppUsage" on the user clients right under the accelerator. Look one level
    // deeper only when a node doesn't report it itself, so the same GPU time is never counted twice.
    // Returns false if an iterator was invalidated by a registry change during the walk.
    private func collect(_ entry: io_registry_entry_t, creator inherited: (pid: Int, name: String)?, depth: Int, seen: inout Set<UInt64>, into list: inout [Client]) -> Bool {
        let creator = self.creator(entry) ?? inherited
        
        if let creator, let gpuTime = self.gpuTime(entry) {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == kIOReturnSuccess, seen.insert(id).inserted {
                list.append(Client(id: id, pid: creator.pid, name: creator.name, gpuTime: gpuTime))
            }
            return true
        }
        
        guard depth < 2 else { return true }
        
        var children: io_iterator_t = io_iterator_t()
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == kIOReturnSuccess else { return true }
        defer { IOObjectRelease(children) }
        
        var complete = true
        var child = IOIteratorNext(children)
        while child != 0 {
            complete = self.collect(child, creator: creator, depth: depth + 1, seen: &seen, into: &list) && complete
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        
        return complete && IOIteratorIsValid(children) != 0
    }
    
    // "IOUserClientCreator" looks like "pid 173, WindowServer"
    private func creator(_ entry: io_registry_entry_t) -> (pid: Int, name: String)? {
        guard let property = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0),
              let value = property.takeRetainedValue() as? String, value.hasPrefix("pid ") else {
            return nil
        }
        let parts = value.dropFirst(4).split(separator: ",", maxSplits: 1)
        guard let first = parts.first, let pid = Int(first.trimmingCharacters(in: .whitespaces)), pid > 0 else {
            return nil
        }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (pid, name)
    }
    
    private func gpuTime(_ entry: io_registry_entry_t) -> UInt64? {
        guard let property = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0),
              let usage = property.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        return usage.reduce(UInt64(0)) { sum, queue in
            sum + ((queue["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
    }
    
    // The creator string is capped at 16 characters, so prefer the app name or the executable name.
    private func processName(_ pid: Int, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        if length > 0 {
            let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
            if !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        return fallback.isEmpty ? "\(pid)" : fallback
    }
}
