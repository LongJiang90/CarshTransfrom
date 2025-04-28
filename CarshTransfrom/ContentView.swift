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
    
    @State private var crashItems: [CrashItem] = []
    @State private var outputLogItem: String = ""

    var body: some View {
        VStack(spacing: 20) {
            // 顶部基础数据区
            VStack(spacing: 20) {
                Text("基础数据")
                    .font(.title2)
                    .padding(.top)
                
                HStack(spacing: 20) {
                    FileDropArea(title: "拖入 .ips / .log / .xccrashpoint 文件", fileURL: $crashLogFile, allowedTypes: ["ips", "log", "xccrashpoint"])
                        .applyOnChange(for: $crashLogFile) { newValue in
                            CarshTransfromTools.shared.crashLogFile = newValue
                        }
                    FileDropArea(title: "拖入 .xcarchive / .app.DSYM 文件", fileURL: $xcarchiveFile, allowedTypes: ["xcarchive", "dSYM"])
                        .applyOnChange(for: $xcarchiveFile) { newValue in
                            CarshTransfromTools.shared.xcarchiveFile = newValue
                            if let xcarchive = newValue {
                                let isFind = CarshTransfromTools.shared.parseXCArchive(xcarchive)
                                if isFind == true {
                                    dSYMFile = CarshTransfromTools.shared.dSYMFile
                                }
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
                            //                            ActionButton(title: "导出日志",
                            //                                         isEnabled: !outputLog.isEmpty,
                            //                                         action: exportLog)
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
                        
                        
                        if !crashItems.isEmpty {
                            NavigationView {
                                List(crashItems) { item in
                                    NavigationLink {
                                        LogTextView(text: $outputLogItem, searchText: $searchText, searchTrigger: $searchTrigger)
                                            .padding(.horizontal, 10)
                                            .padding(.bottom, 10)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    } label: {
                                        Text(item.fileName)
                                            .lineLimit(1)
                                    }
                                    .onAppear {
                                        outputLogItem = item.symbolicatedContent ?? item.crashContent
                                    }
                                }
                            }
                            .navigationTitle(crashItems.isEmpty ? "解析输出" : "崩溃日志列表")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            LogTextView(text: $outputLog, searchText: $searchText, searchTrigger: $searchTrigger)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }


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
        crashItems.removeAll()
        let ext = crashLog.pathExtension.lowercased()
        
        if ext == "ips" || ext == "log" {
            CarshTransfromTools.shared.ipsySymbolicate { sucess, resString in
                DispatchQueue.main.async {
                    isLoading = false
                    outputLog = resString ?? ""
                }
            }
            return
        }
        
        if ext == "xccrashpoint" {
            isLoading = false
            CarshTransfromTools.shared.xccrashpointSymbolicate { carshs in
                crashItems = carshs ?? []
            }
        }
    }
    
    func symbolicateWithAtos() {
        isLoading = true
        let (_, result) = CarshTransfromTools.shared.symbolicateWithAtos(loadAddress: loadAddress)
        signalOutputLog += "\n[atos 符号化结果]: \(result ?? "")"
        isLoading = false
    }
}

#Preview {
    ContentView()
}
