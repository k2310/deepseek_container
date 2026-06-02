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
- **通信の可視化** — mitmproxy が全トラフィックを `volumes/logs/traffic.bin` に記録するため、AI エージェントが何を送受信しているかを事後検査できます。
- **DeepSeek を Anthropic 互換 API として利用** — `ANTHROPIC_BASE_URL` を DeepSeek のエンドポイントに向けることで、Claude Code をそのまま DeepSeek モデルで動作させます。

## 前提条件

- `podman` および `podman-compose` がインストール済みであること
- DeepSeek の API キーを取得済みであること

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

`volumes/logs/traffic.bin` は mitmproxy のバイナリフロー形式で保存されています。
`mitmweb` を使うとブラウザ上で各リクエスト／レスポンスの内容（ヘッダ・ボディ・gzip展開済み）を確認できます。

**Podman の場合**

```bash
podman run --rm \
  -v ./volumes/logs:/logs:ro \
  -p 8081:8081 \
  docker.io/mitmproxy/mitmproxy \
  mitmweb --rfile /logs/traffic.bin --web-host 0.0.0.0
```

**Docker の場合**

```bash
docker run --rm \
  -v ./volumes/logs:/logs:ro \
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
> podman run --rm -v ./volumes/logs:/logs:ro \
>   docker.io/mitmproxy/mitmproxy mitmdump --rfile /logs/traffic.bin
>
> # Docker
> docker run --rm -v ./volumes/logs:/logs:ro \
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
    ├── logs/             # mitmproxy のトラフィックログ（traffic.bin）
    └── mitmproxy-ca/     # mitmproxy CA 証明書（proxy・code 両方がマウント）
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
