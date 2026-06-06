# DeepSeek × Claude Code サンドボックス環境

Claude Code を DeepSeek API バックエンドで動かすための、ネットワーク隔離済みコンテナ環境です。

## 構成概要

```
ホスト
 └─ [external-net] ─ proxy (mitmproxy) ─ インターネット（DeepSeek API 等）
                          │
                    [ai-sandbox-net]
                          │
                       code (Claude Code)
                          │
                    /workspace（ホストからマウント）
```

### サービス一覧

| サービス | イメージ | 役割 |
|---|---|---|
| `proxy` | `mitmproxy/mitmproxy` | 全通信の中継・ログ記録 |
| `code` | `./docker` (ubuntu:24.04) | Claude Code の実行環境 |

### 設計意図

- **`code` コンテナはインターネット直接不可** — `ai-sandbox-net`（internal）にのみ接続しており、外部への通信はすべて `proxy` 経由に強制されます。
- **通信の可視化** — mitmproxy が全トラフィックを `volumes/proxy/logs/traffic.bin` に記録するため、AI エージェントが何を送受信しているかを事後検査できます。
- **DeepSeek を Anthropic 互換 API として利用** — `ANTHROPIC_BASE_URL` を DeepSeek のエンドポイントに向けることで、Claude Code をそのまま DeepSeek モデルで動作させます。
- **coder ホームディレクトリの永続化** — `volumes/code/home/` を `/home/coder` にマウントすることで、シェル設定（`.bashrc` など）・SSH 鍵・Claude Code の設定をコンテナ再作成後も保持します。初回起動時にホームディレクトリが空の場合は `entrypoint.sh` が `/etc/skel` から基本ファイルを自動補完します。

## 前提条件

- `podman` および `podman-compose` がインストール済みであること
- DeepSeek の API キーを取得済みであること

## Podman のインストール（Ubuntu 24.04を例として）

以下の手順は Ubuntu 24.04 向けです。WSL2 上の Ubuntu 24.04 でも基本的に同じ手順で動作します。WSL2 固有の追加設定が必要な箇所については後述します。

### インストール

Ubuntu 24.04 の公式リポジトリに Podman が含まれているので、apt で入ります。

```bash
sudo apt update
sudo apt install -y podman
```

#### podman-compose は pipx でインストールする（推奨）

apt の podman-compose はパッケージ更新の遅延により古いバージョン（1.0.6 など）が入る場合があります。古いバージョンでは `podman-compose exec` 等の実行時に**環境変数（API キーを含む）がターミナルに平文で出力される**既知の問題があります。pipx で最新版を入れることでこの問題を回避できます。

```bash
# pipx のインストール
sudo apt install -y pipx
pipx ensurepath

# 新しいシェルセッションを開くかパスを反映してから
source ~/.bashrc  # または ~/.zshrc

# podman-compose のインストール
pipx install podman-compose
```

バージョン確認：

```bash
podman --version
podman-compose --version
```

### rootless 使用のための設定

#### 1. subuid / subgid の確認・設定

rootless Podman はユーザー名前空間のために `/etc/subuid` と `/etc/subgid` が必要です。

```bash
grep $USER /etc/subuid /etc/subgid
```

エントリがなければ追加：

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

#### 2. newuidmap / newgidmap の確認

```bash
which newuidmap newgidmap
# → /usr/bin/newuidmap 等が返ればOK
```

なければインストール：

```bash
sudo apt install -y uidmap
```

#### 3. ストレージ設定の初期化

```bash
podman system migrate
```

#### 4. 動作確認

```bash
podman run --rm hello-world
podman info | grep -E 'rootless|storage'
```

### WSL2 固有の注意事項

#### cgroupv2 の問題

WSL2 のデフォルト設定では cgroup v2 が有効になっていない場合があります。

```bash
cat /sys/fs/cgroup/cgroup.controllers
```

何も出ない・ファイルがない場合は `%USERPROFILE%\.wslconfig` に以下を追記して WSL を再起動：

```ini
[wsl2]
kernelCommandLine=cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1
```

```powershell
# PowerShell から再起動
wsl --shutdown
```

#### systemd の有効化（推奨）

`/etc/wsl.conf` で有効化：

```ini
[boot]
systemd=true
```

これも `wsl --shutdown` 後に反映されます。

#### ネットワーク（slirp4netns）

rootless では `slirp4netns` がネットワークに使われます：

```bash
sudo apt install -y slirp4netns
```

`passt` ベースの新しいネットワーク実装（`netavark` + `aardvark-dns`）も Ubuntu 24.04 の Podman 4.x では利用可能ですが、WSL2 との相性で問題が出ることがあるため、まず動作確認してから切り替えを検討するのが無難です。

#### `/proc/sys/kernel/unprivileged_userns_clone`

Ubuntu では通常デフォルトで有効ですが念のため確認：

```bash
cat /proc/sys/kernel/unprivileged_userns_clone
# → 1 であればOK（0 なら sudo sysctl kernel.unprivileged_userns_clone=1）
```

#### ambient capability 昇格の警告（`can't raise ambient capability`）

`podman-compose up` 等でコンテナ起動時に以下のような警告が出ることがあります：

```
time="..." level=warning msg="can't raise ambient capability CAP_CHOWN: operation not permitted"
time="..." level=warning msg="can't raise ambient capability CAP_DAC_OVERRIDE: operation not permitted"
time="..." level=warning msg="can't raise ambient capability CAP_FOWNER: operation not permitted"
time="..." level=warning msg="can't raise ambient capability CAP_SETUID: operation not permitted"
time="..." level=warning msg="can't raise ambient capability CAP_SETGID: operation not permitted"
（他 CAP_KILL, CAP_NET_BIND_SERVICE, CAP_SETFCAP, CAP_SETPCAP, CAP_SYS_CHROOT 等）
```

**原因：** OCI ランタイム（crun/runc）がコンテナプロセスのケイパビリティを ambient セットに昇格しようとしますが、WSL2 カーネル（Microsoft カスタムビルド）がユーザー名前空間内での `prctl(PR_CAP_AMBIENT_RAISE, ...)` syscall を追加制限しているため発生します。ネイティブ Linux カーネルでは同操作が許可されているため、同じ設定でもこの警告は出ません。

**実害なし。** ambient への昇格に失敗しても、コンテナ内プロセスは `inheritable` ケイパビリティセット経由で必要な権限を保持するため、コンテナの動作に影響しません。`userns_mode: keep-id` も正常に機能します。

#### マウント伝播の警告（`"/" is not a shared mount`）

`podman system migrate` 等で以下の警告が出ることがあります：

```
WARN[0000] "/" is not a shared mount, this could cause issues or missing mounts with rootless containers
```

WSL2 ではデフォルトで `/` が `private` マウントになっているために発生する既知の問題です。確認：

```bash
cat /proc/self/mountinfo | grep ' / ' | head -5
# peer グループの記載がなく "private" になっているはず
```

**方法1：一時的に修正（再起動で消える）**

```bash
sudo mount --make-rshared /
```

**方法2：WSL 起動時に自動適用（推奨）**

systemd unit として設定する：

```bash
sudo tee /etc/systemd/system/wsl-mount-fix.service << 'EOF'
[Unit]
Description=Fix mount propagation for rootless Podman on WSL2
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/mount --make-rshared /
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable wsl-mount-fix.service
sudo systemctl start wsl-mount-fix.service
```

> この警告は通常のコンテナ実行（`podman run`）では問題になりません。bind mount の伝播など特殊なケースでのみ顕在化します。

### インストール後の確認チェックリスト

```bash
# rootless で動くか
podman run --rm alpine echo "rootless OK"

# UID マッピング確認
podman unshare cat /proc/self/uid_map

# ストレージドライバー確認（overlay が望ましい）
podman info | grep graphDriverName
```

### よくある問題

| 症状 | 原因 | 対処 |
|------|------|------|
| `ERRO: cannot re-exec process` | newuidmap が SUID でない | `sudo chmod u+s /usr/bin/newuidmap` |
| `overlay` が使えず `vfs` になる | カーネルの overlay 対応不足 | WSL2 カーネル更新 or `fuse-overlayfs` 導入 |
| コンテナが起動直後に落ちる | cgroupv2 無効 | 上記 `.wslconfig` 対応 |
| DNS が引けない | `aardvark-dns` の WSL2 非互換 | `netavark` → `slirp4netns` に戻す |
| `can't raise ambient capability ...` の警告（WSL2 のみ） | WSL2 カーネルが `PR_CAP_AMBIENT_RAISE` を制限 | 実害なし。無視して可 |
| `exec` 時に環境変数・API キーが端末に出力される | podman-compose が古い（apt 版 1.0.6 等） | pipx で最新版に置き換える |

基本的には **systemd 有効 + cgroupv2 有効** の状態にしておくと、後々 Quadlet（systemd サービスとしてコンテナ管理）も使えて運用が楽になります。

## セットアップ

### 1. `.env` ファイルを作成する

```env
UID=1000                          # ホストの UID（id -u で確認）
GID=1000                          # ホストの GID（id -g で確認）
DEEPSEEK_API_KEY=sk-...           # DeepSeek API キー
WORKSPACE_HOST_PATH=/path/to/dir  # 作業ディレクトリのホスト側パス
```

> UID/GID をホストと合わせることで `/workspace` への書き込み権限の問題を防げます。

### 2. mitmproxy CA 証明書を生成する

初回起動時に `proxy` が自動生成します。`code` コンテナは `SSL_CERT_FILE` でこの証明書を信頼するよう設定済みです。

## 使用方法

### 起動

```bash
# ビルド＆起動（初回またはDockerfile変更後）
podman-compose up --build -d

# 2回目以降
podman-compose up -d
```

### Claude Code を対話的に使う

```bash
# code コンテナのシェルに入る
podman-compose exec code bash

# コンテナ内で Claude Code を起動
claude
```

### ログの確認

```bash
# proxy のコンテナログ
podman-compose logs proxy
```

#### mitmweb でトラフィックをブラウザ確認

`volumes/proxy/logs/traffic.bin` は mitmproxy のバイナリフロー形式で保存されています。
`mitmweb` を使うとブラウザ上で各リクエスト／レスポンスの内容（ヘッダ・ボディ・gzip展開済み）を確認できます。

**Podman の場合**

```bash
podman run --rm \
  -v ./volumes/proxy/logs:/logs:ro \
  -p 8081:8081 \
  docker.io/mitmproxy/mitmproxy \
  mitmweb --rfile /logs/traffic.bin --web-host 0.0.0.0
```

**Docker の場合**

```bash
docker run --rm \
  -v ./volumes/proxy/logs:/logs:ro \
  -p 8081:8081 \
  mitmproxy/mitmproxy \
  mitmweb --rfile /logs/traffic.bin --web-host 0.0.0.0
```

起動後、ブラウザで `http://localhost:8081` を開くと GUI でトラフィックを閲覧できます。
ポート `8081` がすでに使用中の場合は `-p 8082:8081` のように変更してください。

> **テキストで確認したい場合（コンテナ不要）**
>
> ```bash
> # Podman
> podman run --rm -v ./volumes/proxy/logs:/logs:ro \
>   docker.io/mitmproxy/mitmproxy mitmdump --rfile /logs/traffic.bin
>
> # Docker
> docker run --rm -v ./volumes/proxy/logs:/logs:ro \
>   mitmproxy/mitmproxy mitmdump --rfile /logs/traffic.bin
> ```

### 終了

```bash
podman-compose down
```

## ディレクトリ構成

```
.
├── .env                  # 環境変数（UID/GID/APIキー/ワークスペースパス）※ git 管理外
├── compose.yml
├── docker/
│   ├── Dockerfile        # code コンテナの定義（Claude Code インストール済み）
│   └── entrypoint.sh
└── volumes/
    ├── proxy/
    │   ├── logs/         # mitmproxy のトラフィックログ（traffic.bin）
    │   └── mitmproxy-ca/ # mitmproxy CA 証明書（proxy・code 両方がマウント）
    └── code/
        └── home/         # coder ユーザのホームディレクトリ（シェル設定・SSH鍵など永続化）
```

## 環境変数（`code` コンテナ）

| 変数 | 値 | 説明 |
|---|---|---|
| `HTTPS_PROXY` | `http://proxy:8080` | 全通信を proxy 経由にする |
| `SSL_CERT_FILE` | `/ca/mitmproxy-ca-cert.pem` | mitmproxy CA を信頼させる |
| `ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` | DeepSeek の Anthropic 互換エンドポイント |
| `ANTHROPIC_AUTH_TOKEN` | `${DEEPSEEK_API_KEY}` | DeepSeek API キー |
| `ANTHROPIC_MODEL` | `deepseek-v4-pro[1m]` | デフォルトモデル |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `deepseek-v4-flash` | サブエージェント用の軽量モデル |
