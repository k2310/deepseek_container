#!/bin/bash
set -e

# ホームディレクトリが空（初回マウント時など）の場合、/etc/skel からドットファイルを補完する
for src in /etc/skel/.*; do
    name=$(basename "$src")
    # . と .. はスキップ
    [ "$name" = "." ] || [ "$name" = ".." ] && continue
    dest="$HOME/$name"
    if [ ! -e "$dest" ]; then
        cp -r "$src" "$dest"
    fi
done

exec "$@"
