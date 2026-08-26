/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// inbox 的磁盘布局。
///
/// 投递目录是**外部进程要手写的路径**，所以用硬编码字面量 `Atoll`，
/// 而不是从 bundle id 推导——这个 fork 重签名时 bundle id 会变，
/// 路径跟着漂移会让所有已配好的 hook 脚本静默失效。
///
/// 已摄取的条目落在 `DynamicIsland/Inbox/store.json`（与其它 app 数据同处），
/// 与投递目录分开，因此 `rm -rf` 投递目录永远是安全操作。
enum InboxLocation {
    /// 允许用环境变量改投递目录，便于测试与多实例调试。
    static let directoryOverrideEnvKey = "ATOLL_INBOX_DIR"

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// 投递目录：外部进程往这里写 JSON 文件即等于推送一条消息。
    static var spool: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideEnvKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupport
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    /// 解析失败的文件挪到这里保留现场，方便投递方自查。数量有上限，超出后 FIFO 淘汰。
    static var rejected: URL { spool.appendingPathComponent("rejected", isDirectory: true) }

    /// 预留给打扰规则的文件名。当前没有实现方读它，
    /// 这里保留只为让 watcher 把同名文件排除在消息之外，避免有人放了它却被当成一条消息解析。
    static var rulesFile: URL { spool.appendingPathComponent("rules.json") }

    /// 自解释契约文档，首次创建目录时写入，让人打开目录就知道怎么用。
    static var readmeFile: URL { spool.appendingPathComponent("README.txt") }

    /// 已摄取条目的持久化位置。
    static var storeFile: URL {
        applicationSupport
            .appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent("store.json")
    }

    /// `rejected/` 目录保留的坏文件数量上限。
    static let maxRejectedFiles = 20

    /// 单次扫描处理的文件数上限。超出部分按文件名排序保留最新的，其余直接删除不解析——
    /// 长期没开 Atoll 时投递目录可能堆积到几千个文件，全量解析会卡住 UI。
    static let maxFilesPerScan = 2000

    /// 单个投递文件的体积上限。超过则视为畸形，直接拒收。
    static let maxFileSize = 256 * 1024

    /// 确保投递目录及其子目录存在。返回是否可用。
    ///
    /// 失败不抛错也不禁用功能——调用方会退避重试，因为目录可能只是被临时删掉了。
    @discardableResult
    static func ensureSpoolExists() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: spool, withIntermediateDirectories: true)
            try fm.createDirectory(at: rejected, withIntermediateDirectories: true)
            writeReadmeIfNeeded()
            return true
        } catch {
            return false
        }
    }

    /// 确保 store 所在目录存在。
    @discardableResult
    static func ensureStoreDirectoryExists() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: storeFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return true
        } catch {
            return false
        }
    }

    /// README 只在缺失时写，不覆盖——北城可能在里面加了自己的备注。
    private static func writeReadmeIfNeeded() {
        guard !FileManager.default.fileExists(atPath: readmeFile.path) else { return }
        try? readmeContent.write(to: readmeFile, atomically: true, encoding: .utf8)
    }

    /// 投递契约的完整说明。这份文本就是 inbox 对外的 API 文档。
    static let readmeContent = """
    Atoll Inbox — 通用本地消息投递目录
    ==================================

    往本目录写一个 JSON 文件，就等于给灵动岛推送一条消息。
    任何进程都可以投递：Claude Code hook、CI 脚本、cron、长跑任务。

    写入必须是原子的
    ----------------
    先写同目录下的临时文件，再 rename 过来。同目录 rename 由内核保证原子性，
    这样 Atoll 永远读不到写了一半的内容。

        tmp="$DIR/.tmp.$$"
        printf '%s' "$json" > "$tmp"
        mv "$tmp" "$DIR/$(date +%s%3N)-$$-$RANDOM.json"

    文件名随意，用 .json 结尾即可。建议带时间戳与 pid 避免重名。
    Atoll 读取后会删除该文件，稳态下本目录应该是空的。

    消息格式
    --------
    {
      "v": 1,
      "status": "needs_input",     // needs_input | running | idle | done | failed | info | cleared
      "title": "需要确认是否删除 3 个文件",
      "detail": "更长的说明，可选",
      "source": "claude-code",     // 折叠命名空间，缺省 unknown
      "key": "session-abc123",     // 折叠键：同 source+key 的新消息覆盖旧的
      "ts": 1787713844,            // 秒或毫秒时间戳，缺省用文件 mtime
      "cwd": "/path/to/project",
      "icon": "tray.full",         // SF Symbol 名，缺省按 status 取
      "present": "sneak",          // silent(只进列表) | badge(计入角标) | sneak(弹横幅)
      "priority": "normal",        // low | normal | high
      "tags": ["deploy"],
      "ttl": 1800                  // 存活秒数，缺省不过期
    }

    只有 status 和 title 值得认真填，其余全部可省。
    字段缺失或写错不会导致消息被丢弃——Atoll 一律降级处理后仍然显示。
    解析不了的文件会被挪进 rejected/ 保留现场。

    状态语义
    --------
    needs_input  需要人来回答或授权，默认弹一次横幅
    running      正在跑
    idle         停下了，但没声明是完成还是在等人
    done         完成
    failed       失败
    info         普通通知
    cleared      撤回该 key 的条目（例如 session 结束）

    打扰规则
    --------
    每条消息的 present 字段就是它的打扰上限，由投递方决定。
    Atoll 只会在此基础上降级（勿扰模式、静音期、限流），不会把 silent 提升成横幅。
    要改推送策略，改投递方的脚本。

    静音
    ----
    在 Atoll 的 Inbox 设置里静音。静音只压横幅，消息照常进列表与角标。
    不要用 Claude 的 disableAllHooks 来静音——那会把所有 hook 一起关掉。
    """
}
