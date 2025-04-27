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
    @State private var crashLogFile: URL?
    @State private var dSYMFile: URL?
    @State private var ipaFile: URL?
    @State private var outputLog: String = ""
    @State private var isLoading = false
    @State private var loadAddress: String = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Text("拖拽 .ips / .log / .xccrashpoint / .dSYM / .ipa 到窗口中")
                    .font(.title2)
                    .padding(.top)

                FileDropArea(title: "拖入 .ips / .log / .xccrashpoint 文件", fileURL: $crashLogFile, allowedTypes: ["ips", "log", "xccrashpoint"])
                FileDropArea(title: "拖入 .dSYM 文件夹", fileURL: $dSYMFile, allowedTypes: ["dSYM"])
                FileDropArea(title: "可选: 拖入 .ipa 或 .app 文件", fileURL: $ipaFile, allowedTypes: ["ipa", "app"])

                HStack(spacing: 20) {
                    Button("开始解析") {
                        startSymbolicate()
                    }
                    .disabled(crashLogFile == nil || dSYMFile == nil)

                    Button("导出日志") {
                        exportLog()
                    }
                    .disabled(outputLog.isEmpty)
                }
                .padding(.bottom)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .zIndex(1)

            Divider()

            LogTextView(text: $outputLog)
                .frame(maxHeight: .infinity)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("输入加载地址（load address）：")
                HStack {
                    TextField("例如 0x0000000103385dfc 0x102ed4000", text: $loadAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("符号化单地址") {
                        symbolicateWithAtos()
                    }
                }
            }
            .padding()
            .frame(height: 100)

        }
        .padding()
        .frame(minWidth: 600, minHeight: 700)
        .overlay(
            Group {
                if isLoading {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(
                            ProgressView(label: {
                                Text("解析中").foregroundColor(.white)
                            })
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
        .onAppear {
            
        }
    }
}

//MARK: 各类方法
extension ContentView {
    
    func startSymbolicate() {
        outputLog = "解析中..."
        guard let crashLog = crashLogFile, let dsym = dSYMFile else {
            outputLog = "请拖入崩溃日志和 dSYM 文件"
            return
        }
        
        isLoading = true
        
        // 判断DSYM是否有可执行文件
        guard let executableURL = findMatchingDsymExecutable(in: dsym) else {
            DispatchQueue.main.async {
                outputLog = "未能在 dSYM 或其子路径中找到可执行文件，解析失败"
                isLoading = false
            }
            return
        }
        let lastDsymPath = executableURL.path
        
        let ext = crashLog.pathExtension.lowercased()
        
        if ext == "log" {
            parseLogWithAtos(logURL: crashLog, dsymPath: lastDsymPath)
            return
        }


        DispatchQueue.global(qos: .userInitiated).async {
            let tempOutput = FileManager.default.temporaryDirectory.appendingPathComponent("symbolicated.crash")
            
            let symbolicatePath = "/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/symbolicatecrash"
            let environment = [
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "DEVELOPER_SYMBOL_PATH": lastDsymPath
            ]
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: symbolicatePath)
            process.arguments = [crashLog.path]
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
        guard let dsym = dSYMFile else {
            outputLog = "缺少 dSYM 文件"
            return
        }
        // 判断DSYM是否有可执行文件
        guard let executableURL = findMatchingDsymExecutable(in: dsym) else {
            DispatchQueue.main.async {
                outputLog = "未能在 dSYM 或其子路径中找到可执行文件，解析失败"
                isLoading = false
            }
            return
        }
        let lastDsymPath = executableURL.path
        
        let input = loadAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 匹配格式：0x0000000103385dfc 0x102ed4000
        let pattern = #"0x([a-fA-F0-9]+)\s+0x([a-fA-F0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges == 3,  // 整个匹配 + 两个组
              let crashRange = Range(match.range(at: 1), in: input),
              let loadRange = Range(match.range(at: 2), in: input) else {
            outputLog += "\n输入格式错误，请使用: 崩溃地址 加载地址"
            return
        }
        
        let crashAddrStr = "0x" + input[crashRange]
        let loadAddrStr = "0x" + input[loadRange]
        
        guard let crashAddr = UInt64(crashAddrStr.dropFirst(2), radix: 16),
              let loadAddr = UInt64(loadAddrStr.dropFirst(2), radix: 16) else {
            outputLog += "\n地址转换失败"
            return
        }
        
        let atos = Process()
        atos.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        atos.arguments = ["-arch", "arm64", "-o", lastDsymPath, "-l", loadAddrStr, crashAddrStr]
        
        let pipe = Pipe()
        atos.standardOutput = pipe
        atos.standardError = pipe
        
        do {
            try atos.run()
            atos.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(decoding: data, as: UTF8.self)
            outputLog += "\n[atos 符号化结果]: \(result)"
        } catch {
            outputLog += "\natos 符号化失败: \(error.localizedDescription)"
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

struct FileDropArea: View {
    let title: String
    @Binding var fileURL: URL?
    let allowedTypes: [String]

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
            .foregroundColor(.gray)
            .frame(height: 60)
            .overlay(
                Text(fileURL?.lastPathComponent ?? title)
                    .foregroundColor(.primary)
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                    DispatchQueue.main.async {
                        if let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil),
                           allowedTypes.contains(url.pathExtension) || allowedTypes.contains(url.lastPathComponent) {
                            fileURL = url
                        }
                    }
                }
                return true
            }
    }
}

struct LogTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: NSTextView?
    }
}




#Preview {
    ContentView()
}
