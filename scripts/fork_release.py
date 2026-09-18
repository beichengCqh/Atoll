#!/usr/bin/env python3
"""fork 发布流水线的辅助命令，由 .github/workflows/fork-release.yml 调用。

判断是否发布、生成 appcast、写构建信息这三件事放在这里而不是内联在 workflow，
是为了能用 tests/test_fork_release.py 在本地覆盖。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

# 上游 CI 每天自动刷新的数据文件。上游只改了它们时跳过发布，
# 等下一次有实质改动时随包一起带上，避免每天推一次几乎无变化的自动更新。
UPSTREAM_DATA_ONLY_PATHS = frozenset({
    "DynamicIsland/managers/LLMUsage/pricing.json",
})

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def changed_upstream_paths(repo: str, old_sha: str, new_sha: str) -> list[str] | None:
    """返回上游两个提交之间改动的文件列表；旧提交不在本地历史里（上游改写过历史）时返回 None。"""
    result = subprocess.run(
        ["git", "-C", repo, "diff", "--name-only", old_sha, new_sha],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return [line for line in result.stdout.splitlines() if line]


def decide(
    previous: dict | None,
    fork_sha: str,
    upstream_sha: str,
    force: bool,
    changed_paths: list[str] | None,
) -> tuple[bool, str]:
    """决定本次是否发布，返回 (是否发布, 原因)。

    previous 是上一次发布附带的 build-info.json；没有历史发布时为 None。
    changed_paths 是上一次发布的上游提交到本次上游提交之间的改动文件，None 表示无法计算。
    """
    if force:
        return True, "manually forced"
    if previous is None:
        return True, "no previous release"
    if previous.get("fork_sha") != fork_sha:
        return True, "fork branch changed"
    if previous.get("upstream_sha") == upstream_sha:
        return False, "fork and upstream unchanged"
    if changed_paths is None:
        return True, "previous upstream commit not found, treating as changed"
    meaningful = [path for path in changed_paths if path not in UPSTREAM_DATA_ONLY_PATHS]
    if not meaningful:
        return False, "upstream only refreshed data files"
    return True, f"upstream changed {len(meaningful)} file(s)"


def render_appcast(
    *,
    version: str,
    build: str,
    url: str,
    length: int,
    signature: str,
    minimum_system: str,
    notes: str,
    pub_date: str,
) -> str:
    """生成只含本次版本一个条目的 appcast。

    appcast 作为 Release 附件发布，客户端经 releases/latest/download/appcast.xml 永远读到最新一份，
    所以条目里只需要本次版本。
    """
    description = escape(notes.strip())
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NAMESPACE}">
    <channel>
        <title>Atoll (beichengCqh fork)</title>
        <item>
            <title>{escape(version)}</title>
            <pubDate>{escape(pub_date)}</pubDate>
            <sparkle:version>{escape(build)}</sparkle:version>
            <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{escape(minimum_system)}</sparkle:minimumSystemVersion>
            <description><![CDATA[<pre>{description}</pre>]]></description>
            <enclosure url={quoteattr(url)} length="{int(length)}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
        </item>
    </channel>
</rss>
"""


def _load_previous(path: str) -> dict | None:
    file = Path(path)
    if not file.is_file():
        return None
    return json.loads(file.read_text(encoding="utf-8"))


def _command_decide(args: argparse.Namespace) -> int:
    previous = _load_previous(args.previous)
    changed = None
    if previous and previous.get("upstream_sha"):
        changed = changed_upstream_paths(args.repo, previous["upstream_sha"], args.upstream_sha)
    should_release, reason = decide(
        previous, args.fork_sha, args.upstream_sha, args.force == "true", changed
    )
    print(f"release={str(should_release).lower()} ({reason})")
    if args.github_output:
        # previous_upstream_sha 供 workflow 生成「上次发布以来的上游变更」发布说明
        previous_upstream = (previous or {}).get("upstream_sha", "")
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write(f"release={str(should_release).lower()}\n")
            output.write(f"reason={reason}\n")
            output.write(f"previous_upstream_sha={previous_upstream}\n")
    return 0


def _command_appcast(args: argparse.Namespace) -> int:
    notes = Path(args.notes_file).read_text(encoding="utf-8") if args.notes_file else ""
    xml = render_appcast(
        version=args.version,
        build=args.build,
        url=args.url,
        length=args.length,
        signature=args.signature,
        minimum_system=args.minimum_system,
        notes=notes,
        pub_date=formatdate(usegmt=True),
    )
    Path(args.output).write_text(xml, encoding="utf-8")
    return 0


def _command_build_info(args: argparse.Namespace) -> int:
    info = {
        "fork_sha": args.fork_sha,
        "upstream_sha": args.upstream_sha,
        "build": args.build,
        "version": args.version,
        "tag": args.tag,
    }
    Path(args.output).write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    decide_parser = commands.add_parser("decide")
    decide_parser.add_argument("--repo", default=".")
    decide_parser.add_argument("--previous", required=True)
    decide_parser.add_argument("--fork-sha", required=True)
    decide_parser.add_argument("--upstream-sha", required=True)
    decide_parser.add_argument("--force", choices=("true", "false"), default="false")
    decide_parser.add_argument("--github-output")
    decide_parser.set_defaults(handler=_command_decide)

    appcast_parser = commands.add_parser("appcast")
    appcast_parser.add_argument("--version", required=True)
    appcast_parser.add_argument("--build", required=True)
    appcast_parser.add_argument("--url", required=True)
    appcast_parser.add_argument("--length", required=True, type=int)
    appcast_parser.add_argument("--signature", required=True)
    appcast_parser.add_argument("--minimum-system", required=True)
    appcast_parser.add_argument("--notes-file")
    appcast_parser.add_argument("--output", required=True)
    appcast_parser.set_defaults(handler=_command_appcast)

    info_parser = commands.add_parser("build-info")
    for name in ("--fork-sha", "--upstream-sha", "--build", "--version", "--tag", "--output"):
        info_parser.add_argument(name, required=True)
    info_parser.set_defaults(handler=_command_build_info)

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
