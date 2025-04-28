//
//  CarshTransfromTools.swift
//  CarshTransfrom
//
//  Created by LongJiang on 2025/4/28.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

struct CarshTransfromTools {
    
    static var shared = CarshTransfromTools()
    
    var crashLogFile: URL?
    var xcarchiveFile: URL?
    var dSYMFile: URL?
    private var outputLog: String = ""
    
    //MARK: 解析.ips 友盟的.log
    func ipsySymbolicate(completHandler: @escaping (Bool, String?)->Void) {
        guard let crashLog = crashLogFile, let dSYM = dSYMFile, (crashLog.pathExtension.lowercased() == "ips" || crashLog.pathExtension.lowercased() == "log") else {
            completHandler(false, "请拖入崩溃日志和 .xcarchive 文件")
            return
        }
        ipsySymbolicate(crashLog: crashLog, dSYM: dSYM, completHandler: completHandler)
    }
    
    func ipsySymbolicate(crashLog: URL, dSYM: URL, completHandler: @escaping (Bool, String?)->Void) {
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
                "DEVELOPER_SYMBOL_PATH": dSYM.path
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
                completHandler(true, log)
            } catch {
                completHandler(false, "符号化失败: \(error.localizedDescription)")
            }
        }
    }
    
    //MARK: 解析.xccrashpoint
    func xccrashpointSymbolicate(completHandler: @escaping (([CrashItem]?)->Void)) {
        guard let crashLog = crashLogFile, let dSYM = dSYMFile, crashLog.pathExtension.lowercased() == "xccrashpoint" else {
            completHandler(nil)
            return
        }
        let loader = XccrashpointCrashLoader()
        loader.load(from: crashLog, dSYMURL: dSYM, completion: completHandler)
    }
    
    //MARK: 单行解析
    func symbolicateWithAtos(loadAddress: String) -> (Bool, String?) {
        guard let dsym = dSYMFile else {
            return (false, "未找到dSYM文件")
        }
        
        let input = loadAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 匹配格式：0x0000000103385dfc 0x102ed4000
        let pattern = #"0x([a-fA-F0-9]+)\s+0x([a-fA-F0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges == 3,  // 整个匹配 + 两个组
              let crashRange = Range(match.range(at: 1), in: input),
              let loadRange = Range(match.range(at: 2), in: input) else {
            return (false, "\n输入格式错误，请使用: 崩溃地址 加载地址")
            
        }
        
        let crashAddrStr = "0x" + input[crashRange]
        let loadAddrStr = "0x" + input[loadRange]
        
        guard let _ = UInt64(crashAddrStr.dropFirst(2), radix: 16),
              let _ = UInt64(loadAddrStr.dropFirst(2), radix: 16) else {
            return (false, "\n地址转换失败")
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
            return (true, result)
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    //MARK: 其他方法
    /// 在.xcarchive文件中查找 .DSYM 和 .app
    /// - Parameter xcarchive: 文件路径
    mutating func parseXCArchive(_ xcarchive: URL) -> Bool {
        if xcarchive.lastPathComponent.hasSuffix(".app.dSYM") {
            let fileUrl = findMatchingDsymExecutable(in: xcarchive)
            dSYMFile = fileUrl
            return true
        } else {
            let dSYMsPath = xcarchive.appendingPathComponent("dSYMs")
            if let dsyms = try? FileManager.default.contentsOfDirectory(at: dSYMsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
               let dsym = dsyms.first(where: { $0.lastPathComponent.contains(".app.dSYM") }) {
                dSYMFile = dsym
                return true
            } else {
                return false
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


struct CrashItem: Identifiable {
    let id = UUID()
    let fileName: String
    let crashContent: String
    let symbolicatedContent: String?
}
//MARK: 解析Xccrashpoint文件工具类
class XccrashpointCrashLoader: ObservableObject {
    @Published var crashItems: [CrashItem] = []
    
    func load(from xccrashpointURL: URL, dSYMURL: URL, completion: @escaping ([CrashItem]) -> Void) {
        crashItems.removeAll()
        
        let filtersURL = xccrashpointURL.appendingPathComponent("Filters")
        guard let filterFolder = try? FileManager.default.contentsOfDirectory(at: filtersURL, includingPropertiesForKeys: nil).first else {
            print("找不到 Filters 子目录")
            completion([])
            return
        }
        
        let logsURL = filterFolder.appendingPathComponent("logs")
        guard let logFiles = try? FileManager.default.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil) else {
            print("找不到 logs 文件夹")
            completion([])
            return
        }
        
        let group = DispatchGroup()
        
        for logFile in logFiles where logFile.pathExtension == "crash" {
            if let crashContent = try? String(contentsOf: logFile) {
                group.enter()
                CarshTransfromTools.shared.ipsySymbolicate(crashLog: logFile, dSYM: dSYMURL) { success, symbolicated in
                    let item = CrashItem(
                        fileName: logFile.lastPathComponent,
                        crashContent: crashContent,
                        symbolicatedContent: symbolicated
                    )
                    self.crashItems.append(item)
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            completion(self.crashItems)
        }
    }

    
    /// 符号化函数 (简单版)
    private func symbolicate(crashContent: String, dSYMURL: URL) -> String? {
        guard let (_, loadAddress) = extractModuleNameAndLoadAddress(from: crashContent) else {
            print("❌ 未能提取moduleName或loadAddress")
            return nil
        }
        // 保存临时文件
        let tempCrashURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".crash")
        try? crashContent.write(to: tempCrashURL, atomically: true, encoding: .utf8)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "atos",
            "-o", dSYMURL.path,
            "-arch", "arm64",
            "-l", loadAddress, // 根据你的APP加载基地址调整
            "-f", tempCrashURL.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return output
        } catch {
            print("符号化失败：\(error)")
            return nil
        }
    }
    
    /// 从 crash 内容中提取 moduleName 和加载基地址
    private func extractModuleNameAndLoadAddress(from crashContent: String) -> (moduleName: String, loadAddress: String)? {
        let lines = crashContent.components(separatedBy: .newlines)
        var foundBinaryImagesSection = false
        
        for line in lines {
            if foundBinaryImagesSection {
                if line.contains("/") {
                    // 例如：0x104720000 - 0x1048bffff MyApp arm64  <UUID> /path/to/MyApp
                    let components = line.split(separator: " ", omittingEmptySubsequences: true)
                    if components.count >= 6 {
                        let loadAddress = String(components[0])
                        let moduleName = String(components[2])
                        return (moduleName, loadAddress)
                    }
                }
            }
            
            if line.contains("Binary Images:") {
                foundBinaryImagesSection = true
            }
        }
        
        return nil
    }


}
