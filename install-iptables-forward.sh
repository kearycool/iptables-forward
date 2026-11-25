#!/usr/bin/env bash
# install-iptables-forward.sh — iptables-forward 一键安装脚本 (v1, 2026-11-25)
#
# 用法 (在 VPS 上, 一般在 /root 里运行):
#   bash install-iptables-forward.sh
#
# 做的事 (四步, 哪步失败后面就不跑):
#   1. 从 GitHub 拉最新 iptables-forward.sh (先下到文件, 校验通过才继续, 不直接管道执行)
#   2. 显示版本号 (语法检查 + 读 SCRIPT_VERSION)
#   3. 安装 (bash iptables-forward.sh install; 已有规则在 /etc/iptables-forward/rules.conf 里, 不会丢)
#   4. 上线前检查 (iptables-forward check)
#
# 全程不用你输东西。新机器和升级都用同一行。
# 换仓库地址时改下面的 URL, 或用环境变量:
#   IPTABLES_FORWARD_URL="https://..." bash install-iptables-forward.sh
#
# 注意: 仓库地址是占位, 先把 iptables-forward-v1.sh 传到你自己的 GitHub 仓库
# (建议新建仓库 kearycool/iptables-forward, 文件名 iptables-forward.sh),
# 再跑下面这条命令。没传之前跑会 404, 什么都不会装。
set -euo pipefail

URL="${IPTABLES_FORWARD_URL:-https://raw.githubusercontent.com/kearycool/iptables-forward/refs/heads/main/iptables-forward.sh}"
FILE="iptables-forward.sh"

command -v curl >/dev/null 2>&1 || { echo "错误: 本机没有 curl, 先装: apt-get install -y curl (yum/dnf/apk 用对应命令)"; exit 1; }

echo "== 1/4 下载最新版 =="
curl -fsSL -o "$FILE" "$URL" || { echo "错误: 下载失败, 检查网络或 GitHub 链接 (地址: $URL)"; exit 1; }
[ -s "$FILE" ] || { echo "错误: 下载到的文件是空的, 没装任何东西"; exit 1; }
echo "已下载到: $(pwd)/$FILE"

echo "== 2/4 确认版本 =="
bash -n "$FILE" || { echo "错误: 下载到的脚本语法有问题, 没装任何东西"; exit 1; }
VER=$(grep -m1 '^SCRIPT_VERSION="' "$FILE" | cut -d'"' -f2)
[ -n "$VER" ] || { echo "错误: 下载到的文件里没找到版本号, 没装任何东西"; exit 1; }
echo "下载到的是 iptables-forward $VER"

echo "== 3/4 安装 =="
bash "$FILE" install

echo "== 4/4 上线前检查 =="
if iptables-forward check; then
    echo
    echo "完成: iptables-forward $VER 已装好, 检查通过, 可以加规则了。"
    echo "菜单: iptables-forward (或 ipfwd)"
    echo "加规则: iptables-forward add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]"
else
    echo
    echo "安装已完成, 但检查发现了问题 (上面标 !! 的), 先处理再加规则。"
    exit 1
fi
