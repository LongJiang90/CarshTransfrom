//
//  BookmarkManager.swift
//  CarshTransfrom
//
//  Created by LongJiang on 2025/4/29.
//

import Foundation
import Cocoa

class BookmarkManager {

    static let shared = BookmarkManager()
    private let bookmarkKey = "SavedDirectoryBookmark"

    private init() {}

    func saveSecurityScopedBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            print("✅ 保存目录 Bookmark 成功")
        } catch {
            print("❌ 保存 Bookmark 失败: \(error)")
        }
    }

    func restoreSecurityScopedBookmark() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            print("⚠️ 没有保存的目录 Bookmark")
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("⚠️ Bookmark 已失效，需要重新选择目录")
            }

            if url.startAccessingSecurityScopedResource() {
                print("✅ 恢复访问权限成功: \(url.path)")
                return url
            } else {
                print("❌ 无法访问恢复的目录")
                return nil
            }
        } catch {
            print("❌ 恢复 Bookmark 失败: \(error)")
            return nil
        }
    }

    func requestAccessToParentDirectory(of fileURL: URL, completion: @escaping (URL?) -> Void) {
        let parentDirectory = fileURL.deletingLastPathComponent()

        // 尝试直接请求访问，不弹窗
        if parentDirectory.startAccessingSecurityScopedResource() {
            BookmarkManager.shared.saveSecurityScopedBookmark(for: parentDirectory)
            completion(parentDirectory)
        } else {
            // 失败了，弹出选父目录
            let panel = NSOpenPanel()
            panel.title = "需要访问文件所在的目录"
            panel.message = "App 需要访问 '\(parentDirectory.lastPathComponent)' 目录。"
            panel.directoryURL = parentDirectory
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "授权访问"

            panel.begin { result in
                if result == .OK, let url = panel.url {
                    if url == parentDirectory {
                        if url.startAccessingSecurityScopedResource() {
                            BookmarkManager.shared.saveSecurityScopedBookmark(for: url)
                            completion(url)
                        } else {
                            print("❌ 无法访问选择的目录")
                            completion(nil)
                        }
                    } else {
                        print("❌ 请选择正确的目录")
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            }
        }
    }

    func checkIfAccessGranted(for url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }
}
