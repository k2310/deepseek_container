FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    python3 python3-pip nodejs npm git curl \
    tzdata nodejs npm \
    locales language-pack-ja-base language-pack-ja

# localeを日本語設定に変更
RUN locale-gen ja_JP.UTF-8
# 言語を日本語に設定
ENV LANG ja_JP.UTF-8

# Claude Code のインストール（root で実施）
RUN npm install -g @anthropic-ai/claude-code

# ビルド時に UID/GID を受け取り非 root ユーザーを作成
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} coder \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash coder

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# userns_mode: keep-id により coder(UID) = ホストユーザーのため直接 coder で起動
USER coder
WORKDIR /home/coder
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
