#!/usr/bin/env python3
"""Create a separate, publishable blog repository without generated files."""
from pathlib import Path
import argparse
import shutil

parser = argparse.ArgumentParser(description="GitHub Pages用ブログを別の空ディレクトリへ作成します。")
parser.add_argument("destination", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
destination = args.destination.expanduser().resolve()
if destination == root or root in destination.parents or destination in root.parents:
    parser.error("cocoWriterプロジェクトの外にある新規ディレクトリを指定してください。")
if destination.exists():
    parser.error("既存のディレクトリには上書きしません。新しいパスを指定してください。")
shutil.copytree(root / "site-template", destination,
                ignore=shutil.ignore_patterns("node_modules", "dist", ".DS_Store"))
print("ブログを作成しました:", destination)
print("README.mdの手順に従ってGitHubへ登録し、Pagesを設定してください。")
