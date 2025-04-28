//
//  LogTextView.swift
//  CarshTransfrom
//
//  Created by LongJiang on 2025/4/27.
//

import SwiftUI
import UniformTypeIdentifiers

//MARK: 日志输出视图
struct LogTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var searchText: String?
    @Binding var searchTrigger: Bool?  // 新增：外部触发一次跳转（点按钮）

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

        // 文本内容变化时，更新内容 + 重置搜索
        if textView.string != text {
            textView.string = text
            textView.setNeedsDisplay(textView.bounds)
            context.coordinator.resetSearch()
            
            if let searchText = searchText, !searchText.isEmpty {
                context.coordinator.updateSearch(searchText: searchText)
                context.coordinator.lastSearchText = searchText // 记住上次搜索词
            }
        } else {
            // 如果 searchText 变化了，也重新搜索高亮
            if let searchText = searchText, searchText != context.coordinator.lastSearchText {
                context.coordinator.resetSearch()
                context.coordinator.updateSearch(searchText: searchText)
                context.coordinator.lastSearchText = searchText
            }
        }

        // 搜索下一条
        if searchTrigger == true {
            context.coordinator.searchNext()
            DispatchQueue.main.async {
                searchTrigger = false
            }
        }
    }


    

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: NSTextView?
        var lastSearchText: String? = nil
        private var matches: [NSRange] = []
        private var currentMatchIndex: Int = -1

        func resetSearch() {
            matches = []
            currentMatchIndex = -1
        }

        func updateSearch(searchText: String) {
            guard let textView = textView else { return }
            let textNSString = textView.string as NSString
            let fullRange = NSRange(location: 0, length: textNSString.length)

            textView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
            matches = []

            guard !searchText.isEmpty else { return }

            let regexOptions: NSRegularExpression.Options = [.caseInsensitive]
            if let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: searchText), options: regexOptions) {
                matches = regex.matches(in: textView.string, options: [], range: fullRange).map { $0.range }
            }

            // 高亮所有匹配
            for match in matches {
                textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.gray, range: match)
            }

            // --- 这里加上第一次自动跳转 ---
            if !matches.isEmpty {
                currentMatchIndex = 0
                highlightCurrentMatch()
            } else {
                currentMatchIndex = -1
            }
        }


        func searchNext() {
            guard !matches.isEmpty, let _ = textView else { return }

            currentMatchIndex += 1
            if currentMatchIndex >= matches.count {
                currentMatchIndex = 0
            }
            highlightCurrentMatch()
        }
        
        func highlightCurrentMatch() {
            guard !matches.isEmpty, let textView = textView else { return }
            
            let textNSString = textView.string as NSString
            let fullRange = NSRange(location: 0, length: textNSString.length)
            
            // 先把所有高亮成灰色
            textView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
            for match in matches {
                textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.gray, range: match)
            }
            
            // 当前匹配高亮成橙色
            let currentRange = matches[currentMatchIndex]
            textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemOrange, range: currentRange)
            
            textView.scrollRangeToVisible(currentRange)
            textView.showFindIndicator(for: currentRange)
        }
    }
}

//MARK: 拖动添加文件视图
struct FileDropArea: View {
    let title: String
    @Binding var fileURL: URL?
    let allowedTypes: [String]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                .foregroundColor(.gray)
                .frame(height: 60)
                .overlay(
                    Text(fileURL?.lastPathComponent ?? title)
                        .foregroundColor(.primary)
                )
            
            // 右上角的清除按钮
            if fileURL != nil {
                Button(action: {
                    fileURL = nil
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .padding(6)
                }
            }
        }
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

//MARK: 自定义切换控制视图
enum TabType: String, CaseIterable, Identifiable {
    case whole = "整体解析"
    case single = "单项解析"
    
    var id: String { self.rawValue }
}

struct CustomSegmentedControl: View {
    @Binding var selection: TabType

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TabType.allCases) { tab in
                Text(tab.rawValue)
                    .foregroundColor(selection == tab ? .white : .blue)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == tab ? Color.blue : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = tab
                    }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue, lineWidth: 2)
        )
//        .padding(.horizontal)
    }
}

//MARK: 带背景,圆角的按钮
struct ActionButton: View {
    var title: String
    var isEnabled: Bool
    var width: CGFloat = 100
    var height: CGFloat = 30
    var action: () -> Void

    var body: some View {
        Text(title)
            .foregroundColor(.white)
            .frame(width: width, height: height)
            .background(isEnabled ? Color.blue : Color.gray)
            .cornerRadius(10)
            .contentShape(Rectangle()) // 保证整个区域都能点
            .onTapGesture {
                if isEnabled {
                    action()
                }
            }
    }
}


extension View {
    @ViewBuilder
    func applyOnChange<T: Equatable>(for binding: Binding<T>, perform action: @escaping (T) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: binding.wrappedValue) { oldValue, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: binding.wrappedValue) { newValue in
                action(newValue)
            }
        }
    }
}
