#!/usr/bin/env python3
"""用 GitHub REST API 把当前目录推成一个提交。

有些公司网络/代理只放通 api.github.com，不放通 github.com:443 的 git 协议，
这时 `git push` 会报 `CONNECT tunnel failed`。这个脚本走 Git Data API 完成同样的事：

    blobs -> tree -> commit -> refs/heads/<branch>（全量覆盖，不带 parent）

用法:
    GITHUB_TOKEN=github_pat_xxx python scripts/push_via_api.py \
        --repo owner/name --message "commit message" [--branch main] [--dir .]

注意: token 只从环境变量读，不要写进命令行历史或仓库文件。
"""
import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"

SKIP_DIRS = {".git", ".build", ".swiftpm", "dist", "DerivedData", "node_modules", "__pycache__", ".idea", ".vscode", ".workbuddy"}
SKIP_FILES = {".DS_Store", "Package.resolved"}
MAX_BLOB = 40 * 1024 * 1024


def request(method, path, token, payload=None):
    url = API + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8")


def collect_files(root):
    result = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name in SKIP_FILES:
                continue
            full = os.path.join(current, name)
            if os.path.getsize(full) > MAX_BLOB:
                print("跳过超大文件:", full, file=sys.stderr)
                continue
            relative = os.path.relpath(full, root).replace(os.sep, "/")
            result.append((relative, full))
    result.sort()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--message", required=True)
    parser.add_argument("--branch", default="main")
    parser.add_argument("--dir", default=".")
    parser.add_argument("--parent", default=None, help="可选：父提交 sha，不传则创建无父提交（覆盖历史）")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("缺少环境变量 GITHUB_TOKEN")

    files = collect_files(args.dir)
    if not files:
        sys.exit("目录里没有可推送的文件")
    print("待推送文件数:", len(files))

    entries = []
    for index, (relative, full) in enumerate(files, 1):
        with open(full, "rb") as handle:
            content = base64.b64encode(handle.read()).decode("ascii")
        status, body = request("POST", "/repos/%s/git/blobs" % args.repo, token,
                               {"content": content, "encoding": "base64"})
        if status != 201:
            sys.exit("创建 blob 失败 (%s): %s -> %s" % (relative, status, body))
        entries.append({"path": relative, "mode": "100644", "type": "blob", "sha": body["sha"]})
        print("  [%d/%d] %s" % (index, len(files), relative))

    status, tree = request("POST", "/repos/%s/git/trees" % args.repo, token, {"tree": entries})
    if status != 201:
        sys.exit("创建 tree 失败: %s %s" % (status, tree))
    print("tree:", tree["sha"])

    commit_payload = {"message": args.message, "tree": tree["sha"]}
    if args.parent:
        commit_payload["parents"] = [args.parent]
    status, commit = request("POST", "/repos/%s/git/commits" % args.repo, token, commit_payload)
    if status != 201:
        sys.exit("创建 commit 失败: %s %s" % (status, commit))
    print("commit:", commit["sha"])

    ref = "refs/heads/" + args.branch
    status, body = request("GET", "/repos/%s/git/ref/heads/%s" % (args.repo, args.branch), token)
    if status == 200:
        status, body = request("PATCH", "/repos/%s/git/refs/heads/%s" % (args.repo, args.branch), token, {"sha": commit["sha"], "force": True})
    else:
        status, body = request("POST", "/repos/%s/git/refs" % args.repo, token, {"ref": ref, "sha": commit["sha"]})
    if status not in (200, 201):
        sys.exit("更新分支失败: %s %s" % (status, body))
    print("已更新", ref)


if __name__ == "__main__":
    main()
