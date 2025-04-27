//
//  ContentView.swift
//  CarshTransfrom
//
//  Created by LongJiang on 2025/4/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @State private var selectedTab: TabType = .whole

    @State private var crashLogFile: URL?
    @State private var xcarchiveFile: URL?
    @State private var dSYMFile: URL?
    @State private var outputLog: String = ""
    @State private var searchText: String?
    @State private var searchTrigger: Bool?
    @State private var isLoading = false
    @State private var loadAddress: String = ""
    @State private var signalOutputLog: String = ""

    var body: some View {
        VStack(spacing: 20) {
            // 顶部基础数据区
            VStack(spacing: 20) {
                Text("基础数据")
                    .font(.title2)
                    .padding(.top)
                
                HStack(spacing: 20) {
                    FileDropArea(title: "拖入 .ips / .log / .xccrashpoint 文件", fileURL: $crashLogFile, allowedTypes: ["ips", "log", "xccrashpoint"])
                    FileDropArea(title: "拖入 .xcarchive / .app.DSYM 文件", fileURL: $xcarchiveFile, allowedTypes: ["xcarchive", "dSYM"])
                        .onChange(of: xcarchiveFile) { oldValue, newValue in
                            if let xcarchive = newValue {
                                parseXCArchive(xcarchive)
                            }
                        }
                }
                .padding(.horizontal, 20)
                .padding(.bottom)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.gray, lineWidth: 2)
            )

            // 分段控制
            CustomSegmentedControl(selection: $selectedTab)

            // 根据选中的tab切换显示
            Group {
                switch selectedTab {
                case .whole:
                    VStack {
                        HStack(spacing: 20) {
                            ActionButton(title: "开始解析",
                                             isEnabled: crashLogFile != nil && dSYMFile != nil,
                                             action: startSymbolicate)
                                
                                ActionButton(title: "导出日志",
                                             isEnabled: !outputLog.isEmpty,
                                             action: exportLog)
                        }
                        .padding(.top)
                        
                        HStack {
                            TextField("搜索日志", text: Binding(
                                get: { searchText ?? "" },
                                set: { searchText = $0.isEmpty ? nil : $0 }
                            ))
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 200)
                            ActionButton(title: "搜索",
                                             isEnabled: !(searchText ?? "").isEmpty,
                                             width: 60,
                                             height: 30,
                                             action: {
                                                 searchTrigger = true
                                             })
                        }
                        .frame(alignment: .leading)

                        LogTextView(text: $outputLog, searchText: $searchText, searchTrigger: $searchTrigger)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                case .single:
                    VStack(spacing: 10) {
                        HStack {
                            Text("输入崩溃日志地址:")
                            TextField("例如 0x0000000103385dfc 0x102ed4000", text: $loadAddress)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Button("符号化单地址") {
                                symbolicateWithAtos()
                            }
                            Button("清空解析日志") {
                                signalOutputLog = ""
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top)
                        
                        LogTextView(text: $signalOutputLog, searchText: $searchText, searchTrigger: $searchTrigger)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.gray, lineWidth: 2)
            )
            .frame(maxHeight: .infinity)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 800)
        .overlay(
            Group {
                if isLoading {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(
                            ProgressView("解析中...")
                                .progressViewStyle(CircularProgressViewStyle())
                                .foregroundColor(.white)
                                .padding()
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(12)
                        )
                        .zIndex(2)
                }
            }
        )
    }
}


//MARK: 各类方法
extension ContentView {
    
    func startSymbolicate() {
        guard let crashLog = crashLogFile, let dSYM = dSYMFile else {
            outputLog += "请拖入崩溃日志和 .xcarchive 文件"
            return
        }
        isLoading = true
        
        let dsymPath = dSYM.path
        
        let ext = crashLog.pathExtension.lowercased()
        
        if ext == "log" {
            parseLogWithAtos(logURL: crashLog, dsymPath: dsymPath)
            return
        }


        DispatchQueue.global(qos: .userInitiated).async {
            // 目标路径 = crashLog 文件的所在目录 + "symbolicated.crash"
            let tempOutput = crashLog.deletingLastPathComponent().appendingPathComponent("symbolicated.crash")
            if FileManager.default.isDeletableFile(atPath: tempOutput.path) {
                do {
                    try FileManager.default.removeItem(at: tempOutput)
                } catch {}
            }
            FileManager.default.createFile(atPath: tempOutput.path, contents: nil, attributes: nil)
            
            let symbolicatePath = "/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/symbolicatecrash"
            let environment = [
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "DEVELOPER_SYMBOL_PATH": dsymPath
            ]
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: symbolicatePath)
            process.arguments = ["-v", crashLog.path]
            process.environment = environment
            process.standardOutput = try? FileHandle(forWritingTo: tempOutput)
            
            do {
                try process.run()
                process.waitUntilExit()
                let log = try String(contentsOf: tempOutput, encoding: .utf8)
                DispatchQueue.main.async {
                    outputLog = log
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    outputLog = "符号化失败: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    func symbolicateWithAtos() {
        isLoading = true
        guard let dsym = dSYMFile else {
            signalOutputLog = "缺少 dSYM 文件"
            isLoading = false
            return
        }
        
        let input = loadAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 匹配格式：0x0000000103385dfc 0x102ed4000
        let pattern = #"0x([a-fA-F0-9]+)\s+0x([a-fA-F0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges == 3,  // 整个匹配 + 两个组
              let crashRange = Range(match.range(at: 1), in: input),
              let loadRange = Range(match.range(at: 2), in: input) else {
            signalOutputLog += "\n输入格式错误，请使用: 崩溃地址 加载地址"
            isLoading = false
            return
        }
        
        let crashAddrStr = "0x" + input[crashRange]
        let loadAddrStr = "0x" + input[loadRange]
        
        guard let crashAddr = UInt64(crashAddrStr.dropFirst(2), radix: 16),
              let loadAddr = UInt64(loadAddrStr.dropFirst(2), radix: 16) else {
            signalOutputLog += "\n地址转换失败"
            isLoading = false
            return
        }
        
        let atos = Process()
        atos.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        atos.arguments = ["-arch", "arm64", "-o", dsym.path, "-l", loadAddrStr, crashAddrStr]
        
        let pipe = Pipe()
        atos.standardOutput = pipe
        atos.standardError = pipe
        
        do {
            try atos.run()
            atos.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(decoding: data, as: UTF8.self)
            signalOutputLog += "\n[atos 符号化结果]: \(result)"
            isLoading = false
        } catch {
            signalOutputLog += "\natos 符号化失败: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    func parseLogWithAtos(logURL: URL, dsymPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async {
                    isLoading = false
                }
            }
            
            let dwarfPath = dsymPath
            
            guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
                DispatchQueue.main.async {
                    outputLog = "无法读取日志文件"
                }
                return
            }
            
            let regex = try! NSRegularExpression(pattern: "0x[0-9a-fA-F]+", options: [])
            let lines = content.components(separatedBy: .newlines)
            var symbolicatedLines: [String] = []
            
            for line in lines {
                let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
                var symbolicatedLine = line
                
                for match in matches.reversed() {
                    let range = Range(match.range, in: line)!
                    let address = String(line[range])
                    
                    let atos = Process()
                    let pipe = Pipe()
                    atos.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
                    atos.arguments = ["-o", dwarfPath, "-arch", "arm64", address]
                    atos.standardOutput = pipe
                    do {
                        try atos.run()
                        atos.waitUntilExit()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let symbol = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        symbolicatedLine = symbolicatedLine.replacingOccurrences(of: address, with: symbol)
                    } catch {
                        // do nothing, keep original
                    }
                }
                symbolicatedLines.append(symbolicatedLine)
                outputLog = symbolicatedLines.joined()
            }
            
            DispatchQueue.main.async {
                outputLog = symbolicatedLines.joined(separator: "\n")
                isLoading = false
            }
        }
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.title = "导出符号化日志"
        panel.allowedContentTypes = [UTType(filenameExtension: "crash")!]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "symbolicated_\(timestamp).crash"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try outputLog.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                outputLog = "导出失败: \(error.localizedDescription)"
            }
        }
    }
    
    /// 在.xcarchive文件中查找 .DSYM 和 .app
    /// - Parameter xcarchive: 文件路径
    func parseXCArchive(_ xcarchive: URL) {
        outputLog = ""
        if xcarchive.lastPathComponent.hasSuffix(".app.dSYM") {
            let fileUrl = findMatchingDsymExecutable(in: xcarchive)
            dSYMFile = fileUrl
            return
        } else {
            let dSYMsPath = xcarchive.appendingPathComponent("dSYMs")
            if let dsyms = try? FileManager.default.contentsOfDirectory(at: dSYMsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
               let dsym = dsyms.first(where: { $0.lastPathComponent.contains(".app.dSYM") }) {
                dSYMFile = dsym
            } else {
                outputLog += "\n未找到 .dSYM 文件"
            }
        }
    }

    
    /// 查找命中对应路径中 atos
    /// - Returns: atos 路径
    func findAtosPath() -> String {
        let possiblePaths = ["/usr/bin/atos", "/usr/local/bin/atos", "/opt/homebrew/bin/atos"]
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return ""
    }
    
    /// 在给定 dSYM 路径中查找 DWARF 可执行文件（包含递归子目录查找）
    /// 在 dSYM 或其子路径中查找与主应用同名的 DWARF 可执行文件
    func findMatchingDsymExecutable(in dsymURL: URL) -> URL? {
        var appName = dsymURL.deletingPathExtension().lastPathComponent
        if appName.hasSuffix(".app") {
            appName = String(appName.dropLast(4)) // 去掉 .app
        }
        // 检查主路径
        let mainDWARFPath = dsymURL.appendingPathComponent("Contents/Resources/DWARF")
        if let contents = try? FileManager.default.contentsOfDirectory(at: mainDWARFPath, includingPropertiesForKeys: nil),
           let match = contents.first(where: { $0.lastPathComponent == appName }) {
            return match
        }

        // 检查子路径中的 .dSYM 包
        if let subDsyms = try? FileManager.default.contentsOfDirectory(at: dsymURL, includingPropertiesForKeys: nil) {
            for sub in subDsyms where sub.pathExtension == "dSYM" {
                let dwarfPath = sub.appendingPathComponent("Contents/Resources/DWARF")
                if let dwarfFiles = try? FileManager.default.contentsOfDirectory(at: dwarfPath, includingPropertiesForKeys: nil),
                   let match = dwarfFiles.first(where: { $0.lastPathComponent == appName }) {
                    return match
                }
            }
        }

        return nil
    }
}

#Preview {
    ContentView()
}
