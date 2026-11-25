#!/usr/bin/env bash
# iptables-forward.sh v2 — CloudIPLC 官方 iptables 转发教程的脚本化实现
# v2 改进 (相对 v1, 2026-11-25 Kevin 要求: 把更新脚本也加上, 以后要迭代):
#   新增 update: 菜单第 9 项"更新脚本 (从 GitHub 拉最新版)", 卸载移到第 10 项,
#   0 退出不变, 输入提示改成 [0-10]; 命令行 `iptables-forward update` 也能用。
#   先下载到临时文件、校验 (bash -n + 版本号格式 v+数字 + 版本号比本地新)
#   再替换, 任何一步失败都不动现在用的版本。比对版本号: 一样就说已经是
#   最新版; GitHub 上的更旧就提醒先去 GitHub 覆盖上传。更新只替换脚本文件、
#   跑一次 install (规则文件不动), 然后终端里 exec 新版重开菜单, 非终端
#   只打印新版本号退出。下载地址和一键安装器一样, 默认 GitHub raw,
#   可用 IPTABLES_FORWARD_URL 环境变量改。更新用独立的更新锁, 不和正常
#   规则锁抢同一把; 失败用 return 1 不用 die, 菜单里调用时菜单不能被杀掉。
#
# 依据: https://www.cloudiplc.com/index.php?rp=/knowledgebase/9/iptablesIP.html
# 教程原文逻辑 (逐条对应, 见下面 "教程对照表"):
#   1. 开转发: sysctl net.ipv4.ip_forward = 1, 写入 /etc/sysctl.conf
#      (CentOS 7 写入 /usr/lib/sysctl.d/cloudiplc.conf)
#   2. 加规则 (每条转发 = 4 条 iptables 规则, tcp+udp 各一对):
#        iptables -t nat -A PREROUTING -p tcp --dport [本机端口] -j DNAT --to-destination [目标IP]
#        iptables -t nat -A PREROUTING -p udp --dport [本机端口] -j DNAT --to-destination [目标IP]
#        iptables -t nat -A POSTROUTING -p tcp -d [目标IP] --dport [端口] -j SNAT --to-source [本机IP]
#        iptables -t nat -A POSTROUTING -p udp -d [目标IP] --dport [端口] -j SNAT --to-source [本机IP]
#      NAT-VPS 的 [本机IP] 是走公网流量的网卡内网 IP, 不是公网 IP。
#   3. 持久化: CentOS 用 service iptables save / systemctl restart iptables;
#      Debian/Ubuntu 用 iptables-save > /etc/iptables.up.rules,
#      重启后 iptables-restore < /etc/iptables.up.rules
#   4. 三种端口写法 (教程最后三节):
#      同端口: 本机 10000 -> 1.1.1.1:10000
#      异端口: 本机 60000 -> 1.1.1.1:50000 (PREROUTING dport=60000, POSTROUTING dport=50000)
#      端口段: 本机 10000:65535 -> 1.1.1.1:10000:65535
#   5. 查看: iptables -t nat -nL / iptables -nL --line-number
#
# 本脚本在教程之外只加了管理层, 不改转发语义:
#   - 规则记在 /etc/iptables-forward/rules.conf, 一行一条, 重启后从文件重建;
#   - 每条 iptables 规则带 -m comment --comment "ipfwd:<本机端口>:<协议>",
#     删规则 / 清理过期规则只动带这个标记的, 不碰 Docker / 面板 / 其他工具的规则;
#   - add/del/edit 先备份 rules.conf 再写文件, 写失败从备份恢复;
#   - apply 先逐条 iptables -C 检查, 已在的不重复加, 不在配置里的旧标记规则才删;
#   - 端口冲突预查 (ss 监听 / 已有 DNAT / Docker 已发布端口), 占了就硬拒绝;
#   - 22 端口单独确认 (SSH 端口, 转发它会把自己锁在外面);
#   - 目标支持填域名, 添加时解析一次存 IP (和 nft-forward v27 同款做法,
#     域名 IP 变了要删了重加, 不会自动跟);
#   - Debian 11 上 iptables 默认是 iptables-nft 后端, 和 nftables 共用内核,
#     本脚本只动 iptables 的 nat 表, 不动 nft-forward 的 nft 表, 两套可以共存,
#     但同一本机端口不要两边同时转发, 会互相抢。
#
# 用法 (快捷命令, 装好后直接用):
#   iptables-forward                    # 交互菜单
#   iptables-forward add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]
#   iptables-forward del <本机端口> [tcp|udp|both]
#   iptables-forward edit <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both] [新本机端口]
#   iptables-forward list               # 看配置 + 实时规则
#   iptables-forward check              # 检查转发开关 / 本机IP / 每条规则是否在内核里
#   iptables-forward apply              # 从配置文件重建实时规则 (手动改过配置文件才用)
#   iptables-forward set-ip [本机IP]    # 改 SNAT 源地址 (默认自动探测)
#   iptables-forward clear              # 清空全部转发规则
#   iptables-forward version
#   iptables-forward install            # 一键安装 (装二进制 + 开转发 + 持久化)
#   iptables-forward uninstall          # 卸载 (删规则 + 删文件)
#
# 例子 (和你 IPLC 机上现在跑的那几条对应):
#   iptables-forward add 42168 209.33.144.170 28256 both
#   iptables-forward add 12399 69.63.210.77 22168 both
#   iptables-forward add 60000 1.1.1.1 50000 both      # 异端口, 教程第 2 个例子
#   iptables-forward add 10000:65535 1.1.1.1 both     # 端口段, 教程第 3 个例子
#
# 注意: 这是 v1, 只在本地做过 bash -n / ShellCheck / mock 模拟,
# 没有在真机上跑过 iptables 加载, 上生产前先在一台测试机跑:
#   bash iptables-forward-v1.sh install && iptables-forward check
#   iptables-forward add 12369 209.33.144.170 38396 both
#   手机测 12369 通了, 重启机器再测一次还在, 才算过关。

SCRIPT_VERSION="v2"
PROG="iptables-forward"
UPDATE_URL="${IPTABLES_FORWARD_URL:-https://raw.githubusercontent.com/kearycool/iptables-forward/refs/heads/main/iptables-forward.sh}"
UPDATE_LOCK_FILE="/run/iptables-forward-update.lock"

CONFIG_DIR="/etc/iptables-forward"
RULES_FILE="$CONFIG_DIR/rules.conf"
LOCAL_IP_FILE="$CONFIG_DIR/local_ip"
BACKUP_DIR="$CONFIG_DIR/backup"
LOCK_FILE="/run/iptables-forward.lock"
SAVE_FILE="/etc/iptables/rules.v4"
LEGACY_SAVE_FILE="/etc/iptables.up.rules"
SYSTEMD_UNIT="/etc/systemd/system/iptables-forward.service"
SYSCTL_DROPIN="/etc/sysctl.d/99-iptables-forward.conf"

# 教程里 CentOS 7 的转发配置文件名, 只在 CentOS 7 上用
CENTOS7_SYSCTL_FILE="/usr/lib/sysctl.d/cloudiplc.conf"

LOCK_HELD=0
LOCK_FD=""

set -o pipefail

# ---------- 小工具 ----------

die() { echo "错误: $*" >&2; return 1; }
info() { echo "$*"; }
warn() { echo "注意: $*" >&2; }
ok() { echo "OK: $*"; }

# 是否 root (version/help 不需要, 其余都需要)
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 需要 root 权限, 请用 sudo 或 root 运行: sudo $PROG $*" >&2
        exit 1
    fi
}

# 读 /etc/os-release, 输出 ID (debian/ubuntu/centos/almalinux/alpine/arch 等)
os_id() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf 'unknown'
    fi
}

is_centos_family() {
    case "$(os_id)" in centos|rhel|almalinux|rocky|fedora|oracle) return 0 ;; *) return 1 ;; esac
}

# ---------- 校验 ----------

is_ipv4() {
    local ip="$1" a b c d
    case "$ip" in
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    IFS='.' read -r a b c d <<EOF
$ip
EOF
    for o in "$a" "$b" "$c" "$d"; do
        case "$o" in
            ''|*[!0-9]*) return 1 ;;
        esac
        # 去掉前导零再比, 防止 08 被当八进制
        o=$((10#$o))
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
}

# 单个端口 1-65535, 允许前导零输入, 输出归一化后的数字
is_port() {
    local p="$1"
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    p=$((10#$p))
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# 端口写法: 单个 (42168) 或一段 (10000:65535), 输出归一化写法
# 用法: norm=$(normalize_port_spec "080" ) || die ...
normalize_port_spec() {
    local spec="$1" lo hi
    case "$spec" in
        *:*)
            lo="${spec%%:*}"; hi="${spec##*:}"
            is_port "$lo" || return 1
            is_port "$hi" || return 1
            lo=$((10#$lo)); hi=$((10#$hi))
            [ "$lo" -lt "$hi" ] || return 1
            printf '%s:%s' "$lo" "$hi"
            ;;
        *)
            is_port "$spec" || return 1
            printf '%s' "$((10#$spec))"
            ;;
    esac
}

is_range_spec() {
    case "$1" in *:* ) return 0 ;; *) return 1 ;; esac
}

# 两个端口写法是否重叠 (单端口 vs 段、段 vs 段都算)
# 返回 0 = 重叠, 1 = 不重叠
ports_overlap() {
    local a="$1" b="$2" alo ahi blo bhi
    if is_range_spec "$a"; then alo="${a%%:*}"; ahi="${a##*:}"; else alo="$a"; ahi="$a"; fi
    if is_range_spec "$b"; then blo="${b%%:*}"; bhi="${b##*:}"; else blo="$b"; bhi="$b"; fi
    alo=$((10#$alo)); ahi=$((10#$ahi)); blo=$((10#$blo)); bhi=$((10#$bhi))
    [ "$alo" -le "$bhi" ] && [ "$blo" -le "$ahi" ]
}

# 协议归一化: tcp/udp/both, 默认 both
normalize_proto() {
    local p="${1:-both}"
    case "$p" in
        tcp|udp|both) printf '%s' "$p" ;;
        TCP) printf 'tcp' ;;
        UDP) printf 'udp' ;;
        BOTH) printf 'both' ;;
        *) return 1 ;;
    esac
}

# ---------- 目标解析 / 本机 IP ----------

# 目标支持 IP 或域名。域名解析一次存 IP, 返回 IP; 域名原值写在规则行尾注释里。
# 用法: ip=$(resolve_target "jpeastern.lindays.xyz") || die "解析失败"
resolve_target() {
    local target="$1" ip=""
    if is_ipv4 "$target"; then
        printf '%s' "$target"
        return 0
    fi
    # 域名: 只认合法域名样子, 防止注入进 iptables 参数
    case "$target" in
        *[!A-Za-z0-9.-]*|.*|*..*|*-*|*-) return 1 ;;
    esac
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$target" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    fi
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup "$target" 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -n 1)
    fi
    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        ip=$(dig +short "$target" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    fi
    if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
        ip=$(host "$target" 2>/dev/null | awk '/has address/{print $4}' | head -n 1)
    fi
    if [ -z "$ip" ] && command -v python3 >/dev/null 2>&1; then
        ip=$(python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$target" 2>/dev/null)
    fi
    [ -n "$ip" ] && is_ipv4 "$ip" || return 1
    printf '%s' "$ip"
}

# 探测走公网流量的网卡内网 IP (教程: NAT-VPS 用 ifconfig/ip addr 确认的内网 IP)。
# 优先 ip route get 的 src, 再取全局 IPv4 地址, 最后 hostname -I 第一个。
detect_local_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
        if [ -z "$ip" ]; then
            ip=$(ip -4 addr show scope global 2>/dev/null | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | grep -v '^127\.' | head -n 1)
        fi
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -n "$ip" ] && is_ipv4 "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    return 1
}

# 本机 IP: 有存档用存档, 没有就现探测 (不写文件, 让 install 时固化)
get_local_ip() {
    local ip=""
    if [ -s "$LOCAL_IP_FILE" ]; then
        ip=$(head -n 1 "$LOCAL_IP_FILE" | tr -d ' \t\r\n')
        if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
    fi
    detect_local_ip
}

# ---------- 锁 / 备份 ----------

acquire_lock() {
    local lock_dir
    lock_dir=$(dirname "$LOCK_FILE")
    [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || LOCK_FILE="/tmp/iptables-forward.lock"
    exec 9>"$LOCK_FILE" 2>/dev/null || return 1
    if flock -n 9 2>/dev/null; then
        LOCK_HELD=1
        LOCK_FD=9
        return 0
    fi
    exec 9>&-
    echo "错误: 另一个 iptables-forward 正在运行, 稍后再试" >&2
    return 1
}

release_lock() {
    if [ "$LOCK_HELD" = "1" ]; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
        LOCK_HELD=0
    fi
}

# 原子备份 rules.conf: 临时文件 + mv, 中途被杀不留残缺备份
backup_rules() {
    local tmp=""
    [ -f "$RULES_FILE" ] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    tmp="$BACKUP_DIR/rules.conf.tmp.$$"
    cp "$RULES_FILE" "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$BACKUP_DIR/rules.conf.bak" || { rm -f "$tmp"; return 1; }
    return 0
}

restore_rules_from_backup() {
    if [ -f "$BACKUP_DIR/rules.conf.bak" ]; then
        cp "$BACKUP_DIR/rules.conf.bak" "$RULES_FILE" || return 1
    fi
    return 0
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" || return 1
    [ -f "$RULES_FILE" ] || : > "$RULES_FILE" || return 1
    return 0
}


# ---------- iptables 底层 ----------

# comment 模块是否可用 (有的精简系统没装 xt_comment, 没它就不用标记,
# 但 prune 就认不出来, apply 时会提示只能按配置文件逐条删)
comment_supported() {
    iptables -t nat -C PREROUTING -p tcp --dport 1 -m comment --comment "ipfwd-probe" -j RETURN 2>/dev/null
    local rc=$?
    # -C 返回 1 只说明规则不在, 不是模块缺失; 返回 2 才是参数/模块问题
    [ "$rc" -ne 2 ]
}

# DNAT 目标串: 同端口/同段只写 IP, 异端口/异段写 IP:端口 (段用短横线)
# 用法: dnat_to "42168" "209.33.144.170" "28256" -> 209.33.144.170:28256
#       dnat_to "10000:65535" "1.1.1.1" "10000:65535" -> 1.1.1.1
dnat_to() {
    local local_spec="$1" target_ip="$2" target_spec="$3"
    if [ "$local_spec" = "$target_spec" ]; then
        printf '%s' "$target_ip"
    elif is_range_spec "$target_spec"; then
        printf '%s:%s-%s' "$target_ip" "${target_spec%%:*}" "${target_spec##*:}"
    else
        printf '%s:%s' "$target_ip" "$target_spec"
    fi
}

# 每条转发 = tcp/udp 各一对 DNAT + SNAT, 共 4 条 (both 时)。
# 协议展开: both -> tcp + udp 两轮, 单协议只一轮。
protos_for() {
    case "$1" in
        both) printf 'tcp\nudp\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# 规则标记, 用于识别本脚本建的规则
rule_comment() {
    printf 'ipfwd:%s:%s' "$1" "$2"
}

# 检查一条 iptables 规则是否已在内核里 (iptables -C)
# 参数: 表 链 其余参数... ; 返回 0=在, 1=不在, 2=命令本身失败
iptables_rule_exists() {
    iptables "$@" -C 2>/dev/null
    return $?
}

# 确保一条规则在: 在就不动, 不在就 -A 加上
# 参数: 表 链 协议 本机端口 目标IP 目标端口 本机IP 方向(dnat/snat)
# 方向 dnat: -t nat PREROUTING -p proto --dport local -j DNAT --to-destination X
# 方向 snat: -t nat POSTROUTING -p proto -d target --dport target -j SNAT --to-source local_ip
ensure_one_rule() {
    local table="$1" chain="$2" proto="$3" local_spec="$4" target_ip="$5" target_spec="$6" local_ip="$7" kind="$8"
    local -a check_args add_args comment_args=()
    local to=""
    if comment_supported; then
        comment_args=(-m comment --comment "$(rule_comment "$local_spec" "$proto")")
    fi
    if [ "$kind" = "dnat" ]; then
        to=$(dnat_to "$local_spec" "$target_ip" "$target_spec")
        check_args=(-t "$table" -A "$chain" -p "$proto" --dport "$local_spec" -j DNAT --to-destination "$to" "${comment_args[@]}")
        # iptables -C 的参数顺序和 -A 一致, 把 -A 换成 -C 即可
        if iptables -t "$table" -C "$chain" -p "$proto" --dport "$local_spec" -j DNAT --to-destination "$to" "${comment_args[@]}" 2>/dev/null; then
            return 0
        fi
        iptables -t "$table" -A "$chain" -p "$proto" --dport "$local_spec" -j DNAT --to-destination "$to" "${comment_args[@]}" || return 1
    else
        # SNAT 的 --dport 是目标端口 (教程异端口例子: POSTROUTING dport=50000, 不是 60000)
        if iptables -t "$table" -C "$chain" -p "$proto" -d "$target_ip" --dport "$target_spec" -j SNAT --to-source "$local_ip" "${comment_args[@]}" 2>/dev/null; then
            return 0
        fi
        iptables -t "$table" -A "$chain" -p "$proto" -d "$target_ip" --dport "$target_spec" -j SNAT --to-source "$local_ip" "${comment_args[@]}" || return 1
    fi
    return 0
}

# 删一条规则 (在才删, 不在不报错)
delete_one_rule() {
    local table="$1" chain="$2" proto="$3" local_spec="$4" target_ip="$5" target_spec="$6" local_ip="$7" kind="$8"
    local -a comment_args=()
    local to=""
    if comment_supported; then
        comment_args=(-m comment --comment "$(rule_comment "$local_spec" "$proto")")
    fi
    if [ "$kind" = "dnat" ]; then
        to=$(dnat_to "$local_spec" "$target_ip" "$target_spec")
        iptables -t "$table" -D "$chain" -p "$proto" --dport "$local_spec" -j DNAT --to-destination "$to" "${comment_args[@]}" 2>/dev/null || true
    else
        iptables -t "$table" -D "$chain" -p "$proto" -d "$target_ip" --dport "$target_spec" -j SNAT --to-source "$local_ip" "${comment_args[@]}" 2>/dev/null || true
    fi
    return 0
}

# FORWARD 放行: 只有 FORWARD 默认策略是 DROP 时才需要,
# 教程没写这一条, 但默认 DROP 的机器上不放行包过不去。
# 只放本脚本转发的目标, 不放全网。
ensure_forward_accept() {
    local proto="$1" target_ip="$2" target_spec="$3"
    local policy=""
    policy=$(iptables -S FORWARD 2>/dev/null | head -n 1)
    case "$policy" in
        "-P FORWARD DROP") ;;
        *) return 0 ;;
    esac
    if ! iptables -C FORWARD -p "$proto" -d "$target_ip" --dport "$target_spec" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -p "$proto" -d "$target_ip" --dport "$target_spec" -j ACCEPT 2>/dev/null || warn "FORWARD 放行规则添加失败, 转发可能不通"
    fi
    if ! iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi
    return 0
}

# ---------- 配置文件 ----------

# 配置行格式: <本机端口> <目标IP> <目标端口> <协议> [# 域名]
# 例: 42168 209.33.144.170 28256 both
#     10000:65535 1.1.1.1 10000:65535 both
# 行首 # 是注释, 空行跳过。
config_line_for() {
    local local_spec="$1" target_ip="$2" target_spec="$3" proto="$4" domain="${5:-}"
    if [ -n "$domain" ]; then
        printf '%s %s %s %s # %s' "$local_spec" "$target_ip" "$target_spec" "$proto" "$domain"
    else
        printf '%s %s %s %s' "$local_spec" "$target_ip" "$target_spec" "$proto"
    fi
}

# 查配置里有没有某本机端口+协议 (返回整行, 找不到返回 1)
config_find() {
    local local_spec="$1" proto="${2:-}"
    local line l p _t _tp pr
    [ -f "$RULES_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        l="$1"; _t="$2"; _tp="$3"; pr="$4"
        [ "$l" = "$local_spec" ] || continue
        if [ -z "$proto" ]; then printf '%s\n' "$line"; return 0; fi
        if [ "$pr" = "$proto" ] || [ "$pr" = "both" ] || [ "$proto" = "both" ]; then
            printf '%s\n' "$line"; return 0
        fi
    done < "$RULES_FILE"
    return 1
}

# 端口冲突预查: ss 监听 / 配置里已有 / Docker 已发布, 任一命中就拒绝。
# 22 端口走单独确认, 不在这里硬拦。
# 返回 0=没冲突, 1=有冲突 (原因已打印)
check_port_conflict() {
    local local_spec="$1" proto="$2" skip_config="${3:-0}"
    local p line l _t _tp pr
    # 1) 配置里已有 (重叠就算, 段覆盖单端口也算)
    if [ "$skip_config" = "0" ] && [ -f "$RULES_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            # shellcheck disable=SC2086
            set -- $line
            l="$1"; _t="$2"; _tp="$3"; pr="$4"
            if ports_overlap "$local_spec" "$l"; then
                if [ "$proto" = "both" ] || [ "$pr" = "both" ] || [ "$proto" = "$pr" ]; then
                    echo "错误: 本机端口 $local_spec 已有转发规则 ($line), 先删了再加" >&2
                    return 1
                fi
            fi
        done < "$RULES_FILE"
    fi
    # 2) 本机已有进程在监听 (只查单端口, 段不逐个查, 段由第 3 步的 DNAT 查兜底)
    if ! is_range_spec "$local_spec" && command -v ss >/dev/null 2>&1; then
        if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
            if ss -tlnH "sport = :$local_spec" 2>/dev/null | grep -q .; then
                echo "错误: 本机端口 $local_spec/tcp 已被其他程序监听, 换个端口" >&2
                return 1
            fi
        fi
        if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
            if ss -ulnH "sport = :$local_spec" 2>/dev/null | grep -q .; then
                echo "错误: 本机端口 $local_spec/udp 已被其他程序监听, 换个端口" >&2
                return 1
            fi
        fi
    fi
    # 3) Docker 已发布端口
    if command -v docker >/dev/null 2>&1; then
        local docker_ports=""
        docker_ports=$(docker ps --format '{{.Ports}}' 2>/dev/null || true)
        if [ -n "$docker_ports" ]; then
            if is_range_spec "$local_spec"; then
                # 段: 只要 Docker 发布了段内的任一端口就提示, 粗查
                echo "$docker_ports" | grep -qE "0\.0\.0\.0:[0-9]+->" && warn "Docker 正在发布端口, 端口段 $local_spec 可能与它重叠, 请自行核对 docker ps"
            else
                if echo "$docker_ports" | grep -q "0.0.0.0:$local_spec->"; then
                    echo "错误: 本机端口 $local_spec 已被 Docker 发布, 换个端口" >&2
                    return 1
                fi
            fi
        fi
    fi
    return 0
}

# 22 端口确认: 交互终端问一次, 非终端直接拒绝 (防止脚本里误转 SSH)
confirm_port_22() {
    local local_spec="$1"
    if is_range_spec "$local_spec"; then
        local lo="${local_spec%%:*}"; local hi="${local_spec##*:}"
        if [ "$((10#$lo))" -le 22 ] && [ 22 -le "$((10#$hi))" ]; then
            :
        else
            return 0
        fi
    elif [ "$((10#$local_spec))" -ne 22 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "错误: 22 是 SSH 端口, 转发它会把自己锁在外面, 非交互模式下直接拒绝" >&2
        return 1
    fi
    printf '警告: 22 是 SSH 端口, 转发后 SSH 可能连不上本机。确定要继续吗? [y/N] '
    local ans=""
    read -r ans || return 1
    case "$ans" in y|Y|yes|YES) return 0 ;; *) echo "已取消"; return 1 ;; esac
}


# ---------- 开转发 / 装 iptables / 持久化 (教程第 1、3 步) ----------

# 开转发: 立即 sysctl -w, 再写持久化文件。
# Debian/Ubuntu 写 /etc/sysctl.conf (教程) + /etc/sysctl.d/99-iptables-forward.conf;
# CentOS 7 写 /usr/lib/sysctl.d/cloudiplc.conf (教程原文路径)。
ensure_forwarding() {
    local cur=""
    cur=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [ "$cur" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || { echo "错误: 开转发失败 (sysctl -w net.ipv4.ip_forward=1)"; return 1; }
    fi
    # 持久化: 先写 drop-in (现代系统都认), 再按教程补写传统位置
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    if ! grep -qs '^net.ipv4.ip_forward *= *1' "$SYSCTL_DROPIN" 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" > "$SYSCTL_DROPIN" 2>/dev/null || warn "写 $SYSCTL_DROPIN 失败, 重启后转发可能关闭"
    fi
    if is_centos_family; then
        local ver=""
        ver=$(grep -oE '^[0-9]+' /etc/centos-release /etc/redhat-release 2>/dev/null | head -n 1 || true)
        if [ "$ver" = "7" ]; then
            mkdir -p "$(dirname "$CENTOS7_SYSCTL_FILE")" 2>/dev/null || true
            if ! grep -qs '^net.ipv4.ip_forward *= *1' "$CENTOS7_SYSCTL_FILE" 2>/dev/null; then
                echo "net.ipv4.ip_forward = 1" >> "$CENTOS7_SYSCTL_FILE" 2>/dev/null || true
            fi
            sysctl -p "$CENTOS7_SYSCTL_FILE" >/dev/null 2>&1 || true
        fi
    else
        if [ -f /etc/sysctl.conf ] && ! grep -qs '^net.ipv4.ip_forward *= *1' /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf 2>/dev/null || true
        fi
        sysctl -p "$SYSCTL_DROPIN" >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
    fi
    cur=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    [ "$cur" = "1" ] || { echo "错误: 转发开关仍是 $cur, 没打开"; return 1; }
    return 0
}

# 装 iptables (没装时才装)。CentOS 7 先按教程删 firewalld、装 iptables-services。
ensure_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    echo "本机没装 iptables, 正在安装..."
    if is_centos_family; then
        local ver=""
        ver=$(grep -oE '^[0-9]+' /etc/centos-release /etc/redhat-release 2>/dev/null | head -n 1 || true)
        if [ "$ver" = "7" ]; then
            systemctl stop firewalld.service 2>/dev/null || true
            systemctl disable firewalld.service 2>/dev/null || true
        fi
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y iptables-services iptables 2>&1 | tail -n 3
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iptables-services iptables 2>&1 | tail -n 3
        else
            echo "错误: 没找到 dnf/yum, 装不了 iptables" >&2; return 1
        fi
        systemctl enable iptables.service 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update 2>&1 | tail -n 2 || warn "apt-get update 失败 (Debian 11 老源可能已失效, 见下面提示)"
        apt-get install -y iptables iproute2 2>&1 | tail -n 3 || { echo "错误: apt-get 装 iptables 失败"; return 1; }
    elif command -v apt >/dev/null 2>&1; then
        apt update 2>&1 | tail -n 2 || true
        apt install -y iptables iproute2 2>&1 | tail -n 3 || { echo "错误: apt 装 iptables 失败"; return 1; }
    elif command -v apk >/dev/null 2>&1; then
        apk add iptables ip6tables iproute2 2>&1 | tail -n 3 || return 1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm iptables iproute2 2>&1 | tail -n 3 || return 1
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y iptables iproute2 2>&1 | tail -n 3 || return 1
    else
        echo "错误: 没找到 apt-get/apt/dnf/yum/apk/pacman/zypper, 装不了 iptables" >&2
        return 1
    fi
    command -v iptables >/dev/null 2>&1 || { echo "错误: 装完还是找不到 iptables"; return 1; }
    return 0
}

# 保存实时规则到文件 (教程第 3 步)。
# Debian/Ubuntu: iptables-save > /etc/iptables/rules.v4, 同时写一份
# /etc/iptables.up.rules (教程原文路径, 兼容老教程)。
# CentOS: service iptables save (写 /etc/sysconfig/iptables)。
save_rules() {
    if is_centos_family; then
        if command -v service >/dev/null 2>&1 && [ -f /etc/init.d/iptables ]; then
            service iptables save 2>&1 | tail -n 2 || warn "service iptables save 失败"
        else
            mkdir -p /etc/sysconfig
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || warn "写 /etc/sysconfig/iptables 失败"
        fi
        return 0
    fi
    mkdir -p "$(dirname "$SAVE_FILE")" 2>/dev/null || true
    if ! iptables-save > "$SAVE_FILE" 2>/dev/null; then
        warn "写 $SAVE_FILE 失败"
        return 1
    fi
    # 教程原文路径也写一份
    cp "$SAVE_FILE" "$LEGACY_SAVE_FILE" 2>/dev/null || true
    return 0
}

# 持久化: 开机自动恢复。
# 优先 iptables-persistent / netfilter-persistent (装了就用它),
# 没有就建一个 oneshot systemd 服务, 重启后 iptables-restore 恢复。
ensure_persistence() {
    if is_centos_family; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable iptables.service 2>/dev/null || true
        fi
        return 0
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
        systemctl enable netfilter-persistent 2>/dev/null || true
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Restore iptables-forward rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore $SAVE_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable iptables-forward.service 2>/dev/null || warn "开机自启设置失败, 重启后需手动 iptables-restore < $SAVE_FILE"
        return 0
    fi
    # 没 systemd 的机器: 教程的老办法, 写进 rc.local 或提示手动恢复
    warn "没找到 systemctl, 重启后需手动执行: iptables-restore < $SAVE_FILE"
    return 0
}

# ---------- 从配置文件重建实时规则 ----------

# apply: 按 rules.conf 逐条确保在内核里, 再删掉不在配置里的旧标记规则。
# 失败时不删配置, 只报错, 由调用方决定是否恢复。
apply_rules() {
    local local_ip=""
    local_ip=$(get_local_ip) || { echo "错误: 探测不到本机 IP (SNAT 源地址), 先跑: $PROG set-ip <内网IP>"; return 1; }
    local cur=""
    cur=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [ "$cur" != "1" ]; then
        echo "错误: 转发没开 (net.ipv4.ip_forward=$cur), 先跑: $PROG install 或 sysctl -w net.ipv4.ip_forward=1" >&2
        return 1
    fi
    local line l t tp pr proto
    local failed=0
    [ -f "$RULES_FILE" ] || { echo "错误: 配置文件不存在: $RULES_FILE"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        l="$1"; t="$2"; tp="$3"; pr="$4"
        [ -n "$l" ] && [ -n "$t" ] && [ -n "$tp" ] && [ -n "$pr" ] || { warn "跳过非法配置行: $line"; continue; }
        for proto in $(protos_for "$pr"); do
            ensure_one_rule nat PREROUTING "$proto" "$l" "$t" "$tp" "$local_ip" dnat || failed=1
            ensure_one_rule nat POSTROUTING "$proto" "$l" "$t" "$tp" "$local_ip" snat || failed=1
            ensure_forward_accept "$proto" "$t" "$tp"
        done
    done < "$RULES_FILE"
    # 清理过期标记规则: 内核里带 ipfwd: 标记、但不在配置里的, 删掉
    prune_stale_rules || true
    if [ "$failed" -ne 0 ]; then
        echo "错误: 部分规则应用失败, 见上面输出" >&2
        return 1
    fi
    save_rules || warn "规则已生效, 但保存到文件失败, 重启后可能丢失"
    return 0
}

# 删掉内核里带 ipfwd: 标记、但不在 rules.conf 里的规则
prune_stale_rules() {
    comment_supported || return 0
    local spec proto line l _t _tp pr found
    # 列出当前 nat 表里所有带 ipfwd: 的 DNAT/SNAT 规则的 (本机端口, 协议)
    iptables -t nat -S PREROUTING 2>/dev/null | grep -oE 'ipfwd:[^ ]+' | sort -u | while read -r tag; do
        spec="${tag#ipfwd:}"; spec="${spec%:*}"; proto="${tag##*:}"
        found=0
        if [ -f "$RULES_FILE" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in ''|'#'*) continue ;; esac
                # shellcheck disable=SC2086
                set -- $line
                l="$1"; _t="$2"; _tp="$3"; pr="$4"
                if [ "$l" = "$spec" ] && { [ "$pr" = "$proto" ] || [ "$pr" = "both" ]; }; then found=1; break; fi
            done < "$RULES_FILE"
        fi
        if [ "$found" -eq 0 ]; then
            # 找到这条规则的完整参数再删: 从 iptables -S 里取原行, 把 -A 换成 -D
            iptables -t nat -S PREROUTING 2>/dev/null | grep -F "$tag" | while IFS= read -r rule; do
                rule="${rule#-A }"
                # shellcheck disable=SC2086
                iptables -t nat -D $rule 2>/dev/null || true
            done
            iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "$tag" | while IFS= read -r rule; do
                rule="${rule#-A }"
                # shellcheck disable=SC2086
                iptables -t nat -D $rule 2>/dev/null || true
            done
        fi
    done
    return 0
}


# ---------- 子命令 ----------

print_help() {
    cat <<EOF
$PROG $SCRIPT_VERSION — CloudIPLC 官方 iptables 转发教程的脚本版

用法:
  $PROG                              交互菜单
  $PROG add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]
  $PROG del <本机端口> [tcp|udp|both]
  $PROG edit <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both] [新本机端口]
  $PROG list                         查看配置 + 实时规则
  $PROG check                        检查转发开关 / 本机IP / 每条规则是否在内核里
  $PROG apply                        从配置文件重建实时规则
  $PROG set-ip [本机IP]              查看或设置 SNAT 源地址 (默认自动探测)
  $PROG clear                        清空全部转发规则
  $PROG update                       更新脚本 (从 GitHub 拉最新版)
  $PROG install                      一键安装
  $PROG uninstall                    卸载
  $PROG version

例子:
  $PROG add 42168 209.33.144.170 28256 both
  $PROG add 60000 1.1.1.1 50000 both       # 异端口 (教程例子 2)
  $PROG add 10000:65535 1.1.1.1 both      # 端口段 (教程例子 3)
  $PROG del 42168
  $PROG edit 42168 209.33.144.170 28257 both

配置文件: $RULES_FILE
保存文件: $SAVE_FILE (另存一份 $LEGACY_SAVE_FILE, 教程原文路径)
EOF
}

cmd_version() {
    if [ -n "${1:-}" ]; then echo "错误: version 不带参数" >&2; return 1; fi
    echo "$PROG $SCRIPT_VERSION"
    return 0
}

cmd_set_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        local cur=""
        cur=$(get_local_ip 2>/dev/null || echo "")
        if [ -n "$cur" ]; then echo "当前本机 IP (SNAT 源): $cur"; else echo "当前探测不到本机 IP"; fi
        echo "用法: $PROG set-ip <内网IP>  (NAT-VPS 填走公网流量的网卡内网 IP)"
        return 0
    fi
    is_ipv4 "$ip" || { echo "错误: IP 不合法: $ip" >&2; return 1; }
    ensure_config_dir || return 1
    printf '%s\n' "$ip" > "$LOCAL_IP_FILE" || { echo "错误: 写 $LOCAL_IP_FILE 失败"; return 1; }
    ok "本机 IP 已设为 $ip, 下次 apply 起用新地址 (旧规则的 SNAT 不会自动改, 需跑 apply 重建)"
    return 0
}

cmd_add() {
    local local_raw="${1:-}" target_raw="${2:-}" target_port_raw="${3:-}" proto_raw="${4:-both}"
    [ -n "$local_raw" ] && [ -n "$target_raw" ] || { echo "用法: $PROG add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]" >&2; return 1; }
    [ -z "${5:-}" ] || { echo "错误: add 参数多了 (最多 4 个)" >&2; return 1; }
    # 省略目标端口时协议会落在第 3 位: add 10000:65535 1.1.1.1 both
    # 此时第 3 位是协议词, 不是端口, 把它挪到协议位, 目标端口留空 (= 本机端口)
    case "$target_port_raw" in
        tcp|udp|both|TCP|UDP|BOTH)
            if [ -z "${4:-}" ]; then proto_raw="$target_port_raw"; target_port_raw=""; fi
            ;;
    esac
    local local_spec="" target_spec="" proto="" target_ip="" domain=""
    local_spec=$(normalize_port_spec "$local_raw") || { echo "错误: 本机端口不合法: $local_raw (单个 1-65535, 或一段如 10000:65535)" >&2; return 1; }
    proto=$(normalize_proto "$proto_raw") || { echo "错误: 协议只能是 tcp/udp/both: $proto_raw" >&2; return 1; }
    if [ -n "$target_port_raw" ]; then
        target_spec=$(normalize_port_spec "$target_port_raw") || { echo "错误: 目标端口不合法: $target_port_raw" >&2; return 1; }
    else
        target_spec="$local_spec"
    fi
    # 单端口对段、段对单端口不允许 (DNAT 段必须两边都是段且长度一致)
    if is_range_spec "$local_spec" && ! is_range_spec "$target_spec"; then
        echo "错误: 本机是端口段, 目标端口也得是段 (如 10000:65535 -> 20000:75535)" >&2; return 1
    fi
    if ! is_range_spec "$local_spec" && is_range_spec "$target_spec"; then
        echo "错误: 本机是单个端口, 目标端口也得是单个" >&2; return 1
    fi
    if is_range_spec "$local_spec" && is_range_spec "$target_spec"; then
        local llo="${local_spec%%:*}" lhi="${local_spec##*:}" tlo="${target_spec%%:*}" thi="${target_spec##*:}"
        if [ $((10#$lhi - 10#$llo)) -ne $((10#$thi - 10#$tlo)) ]; then
            echo "错误: 端口段两边长度不一致: $local_spec vs $target_spec" >&2; return 1
        fi
    fi
    target_ip=$(resolve_target "$target_raw") || { echo "错误: 目标解析失败: $target_raw (填 IP, 或填能解析的域名)" >&2; return 1; }
    if ! is_ipv4 "$target_raw"; then domain="$target_raw"; fi
    confirm_port_22 "$local_spec" || return 1
    check_port_conflict "$local_spec" "$proto" 0 || return 1
    ensure_config_dir || return 1
    acquire_lock || return 1
    backup_rules || { release_lock; echo "错误: 备份配置文件失败, 没改任何东西"; return 1; }
    local line=""
    line=$(config_line_for "$local_spec" "$target_ip" "$target_spec" "$proto" "$domain")
    if ! printf '%s\n' "$line" >> "$RULES_FILE"; then
        restore_rules_from_backup; release_lock
        echo "错误: 写配置文件失败, 已从备份恢复" >&2; return 1
    fi
    if ! apply_rules; then
        restore_rules_from_backup
        # 配置恢复后, 再重建一次实时规则, 把刚加的那条清掉
        apply_rules >/dev/null 2>&1 || true
        release_lock
        echo "错误: 规则应用失败, 配置已从备份恢复" >&2; return 1
    fi
    release_lock
    ok "已添加: 本机 $local_spec -> $target_ip:$target_spec ($proto)"
    return 0
}

cmd_del() {
    local local_raw="${1:-}" proto_raw="${2:-both}"
    [ -n "$local_raw" ] || { echo "用法: $PROG del <本机端口> [tcp|udp|both]" >&2; return 1; }
    [ -z "${3:-}" ] || { echo "错误: del 参数多了" >&2; return 1; }
    local local_spec="" proto=""
    local_spec=$(normalize_port_spec "$local_raw") || { echo "错误: 本机端口不合法: $local_raw" >&2; return 1; }
    proto=$(normalize_proto "$proto_raw") || { echo "错误: 协议只能是 tcp/udp/both" >&2; return 1; }
    local found=""
    found=$(config_find "$local_spec" "$proto") || { echo "错误: 没找到本机端口 $local_spec 的规则" >&2; return 1; }
    ensure_config_dir || return 1
    acquire_lock || return 1
    backup_rules || { release_lock; echo "错误: 备份失败, 没改任何东西"; return 1; }
    local tmp="$RULES_FILE.tmp.$$"
    # 删配置行: 本机端口 + 协议匹配 (both 的行删整行, 单协议只删对应方向时把 both 改成另一方向)
    local line l t tp pr kept=0
    : > "$tmp" || { release_lock; echo "错误: 建临时文件失败"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        l="$1"; t="$2"; tp="$3"; pr="$4"
        if [ "$l" = "$local_spec" ] && { [ "$proto" = "both" ] || [ "$pr" = "$proto" ] || [ "$pr" = "both" ]; }; then
            if [ "$pr" = "both" ] && [ "$proto" != "both" ]; then
                # both 改成另一方向, 保留一半
                local other="udp"; [ "$proto" = "udp" ] && other="tcp"
                printf '%s\n' "$(config_line_for "$l" "$t" "$tp" "$other")" >> "$tmp"
            fi
            kept=1
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$RULES_FILE"
    if [ "$kept" -eq 0 ]; then rm -f "$tmp"; release_lock; echo "错误: 没找到要删的规则" >&2; return 1; fi
    if ! mv "$tmp" "$RULES_FILE"; then
        rm -f "$tmp"; restore_rules_from_backup; release_lock
        echo "错误: 写配置文件失败, 已恢复" >&2; return 1
    fi
    # 删实时规则: 用删之前的配置行参数删, 再跑一次 apply 清残留
    local d_t d_tp
    # shellcheck disable=SC2086
    set -- $found
    d_t="$2"; d_tp="$3"
    local local_ip=""
    local_ip=$(get_local_ip 2>/dev/null || echo "")
    if [ -n "$local_ip" ]; then
        for p in $(protos_for "$proto"); do
            delete_one_rule nat PREROUTING "$p" "$local_spec" "$d_t" "$d_tp" "$local_ip" dnat
            delete_one_rule nat POSTROUTING "$p" "$local_spec" "$d_t" "$d_tp" "$local_ip" snat
        done
    fi
    apply_rules >/dev/null 2>&1 || warn "实时规则重建有警告, 见上面输出"
    save_rules >/dev/null 2>&1 || true
    release_lock
    ok "已删除: 本机 $local_spec ($proto)"
    return 0
}

cmd_edit() {
    local local_raw="${1:-}" target_raw="${2:-}" target_port_raw="${3:-}" proto_raw="${4:-}" new_local_raw="${5:-}"
    [ -n "$local_raw" ] && [ -n "$target_raw" ] || { echo "用法: $PROG edit <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both] [新本机端口]" >&2; return 1; }
    [ -z "${6:-}" ] || { echo "错误: edit 参数多了" >&2; return 1; }
    # 和 add 一样: 省略目标端口时协议落在第 3 位, 新本机端口落在第 4 位
    case "$target_port_raw" in
        tcp|udp|both|TCP|UDP|BOTH)
            if [ -z "${5:-}" ]; then proto_raw="$target_port_raw"; target_port_raw=""; new_local_raw="${4:-}"; fi
            ;;
    esac
    local local_spec="" old_line=""
    local_spec=$(normalize_port_spec "$local_raw") || { echo "错误: 本机端口不合法: $local_raw" >&2; return 1; }
    old_line=$(config_find "$local_spec" "") || { echo "错误: 没找到本机端口 $local_spec 的规则" >&2; return 1; }
    local old_t old_tp old_pr
    # shellcheck disable=SC2086
    set -- $old_line
    old_t="$2"; old_tp="$3"; old_pr="$4"
    local target_spec="${target_port_raw:-$old_tp}" proto="${proto_raw:-$old_pr}" new_local_spec="$local_spec"
    target_spec=$(normalize_port_spec "$target_spec") || { echo "错误: 目标端口不合法: $target_port_raw" >&2; return 1; }
    proto=$(normalize_proto "$proto") || { echo "错误: 协议只能是 tcp/udp/both" >&2; return 1; }
    if [ -n "$new_local_raw" ]; then
        new_local_spec=$(normalize_port_spec "$new_local_raw") || { echo "错误: 新本机端口不合法: $new_local_raw" >&2; return 1; }
    fi
    local target_ip="" domain=""
    target_ip=$(resolve_target "$target_raw") || { echo "错误: 目标解析失败: $target_raw" >&2; return 1; }
    if ! is_ipv4 "$target_raw"; then domain="$target_raw"; fi
    if [ "$new_local_spec" != "$local_spec" ]; then
        confirm_port_22 "$new_local_spec" || return 1
        check_port_conflict "$new_local_spec" "$proto" 0 || return 1
    fi
    ensure_config_dir || return 1
    acquire_lock || return 1
    backup_rules || { release_lock; echo "错误: 备份失败, 没改任何东西"; return 1; }
    # 一次改完文件、一次 apply, 不是先 del 再 add (del 完 add 失败会丢规则)
    local tmp="$RULES_FILE.tmp.$$" line l t tp pr
    : > "$tmp" || { release_lock; echo "错误: 建临时文件失败"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        l="$1"; t="$2"; tp="$3"; pr="$4"
        if [ "$l" = "$local_spec" ]; then
            printf '%s\n' "$(config_line_for "$new_local_spec" "$target_ip" "$target_spec" "$proto" "$domain")" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$RULES_FILE"
    if ! mv "$tmp" "$RULES_FILE"; then
        rm -f "$tmp"; restore_rules_from_backup; release_lock
        echo "错误: 写配置文件失败, 已恢复" >&2; return 1
    fi
    if ! apply_rules; then
        restore_rules_from_backup
        apply_rules >/dev/null 2>&1 || true
        release_lock
        echo "错误: 规则应用失败, 配置已从备份恢复" >&2; return 1
    fi
    release_lock
    ok "已修改: 本机 $local_spec -> $new_local_spec, 目标 $target_ip:$target_spec ($proto)"
    return 0
}

cmd_list() {
    echo "== 配置文件 ($RULES_FILE) =="
    if [ ! -s "$RULES_FILE" ]; then
        echo "(空, 还没加规则)"
    else
        local n=0 line
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            n=$((n + 1))
            echo "  $n. 本机 $line"
        done < "$RULES_FILE"
    fi
    echo
    echo "== 实时 nat 规则 (iptables -t nat -nL, 只列本脚本的标记规则) =="
    if ! command -v iptables >/dev/null 2>&1; then
        echo "(没装 iptables)"
        return 0
    fi
    iptables -t nat -nL PREROUTING 2>/dev/null | grep -E 'ipfwd:|DNAT' || echo "(PREROUTING 里没有 DNAT 规则)"
    iptables -t nat -nL POSTROUTING 2>/dev/null | grep -E 'ipfwd:|SNAT' || echo "(POSTROUTING 里没有 SNAT 规则)"
    local lip=""
    lip=$(get_local_ip 2>/dev/null || echo "")
    echo
    echo "本机 IP (SNAT 源): ${lip:-探测不到, 跑 $PROG set-ip <内网IP>}"
    return 0
}

cmd_check() {
    local failed=0
    echo "== 转发开关 =="
    local cur=""
    cur=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [ "$cur" = "1" ]; then ok "net.ipv4.ip_forward = 1"; else echo "!! net.ipv4.ip_forward = $cur (没开, 转发不通)"; failed=1; fi
    echo
    echo "== iptables =="
    if command -v iptables >/dev/null 2>&1; then ok "iptables 已装: $(iptables --version 2>/dev/null | head -n 1)"; else echo "!! 没装 iptables"; failed=1; fi
    echo
    echo "== 本机 IP (SNAT 源) =="
    local lip=""
    lip=$(get_local_ip 2>/dev/null || echo "")
    if [ -n "$lip" ]; then ok "$lip"; else echo "!! 探测不到本机 IP, 跑 $PROG set-ip <内网IP>"; failed=1; fi
    echo
    echo "== 每条规则是否在内核里 =="
    if [ ! -s "$RULES_FILE" ]; then echo "(配置为空)"; return "$failed"; fi
    local line l t tp pr proto to=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2086
        set -- $line
        l="$1"; t="$2"; tp="$3"; pr="$4"
        for proto in $(protos_for "$pr"); do
            to=$(dnat_to "$l" "$t" "$tp")
            if iptables -t nat -C PREROUTING -p "$proto" --dport "$l" -j DNAT --to-destination "$to" 2>/dev/null; then
                ok "DNAT $l/$proto -> $to 在"
            else
                # 带 comment 的规则用不带 comment 的 -C 查不到, 再按 comment 查一次
                if iptables -t nat -S PREROUTING 2>/dev/null | grep -qF "ipfwd:$l:$proto"; then
                    ok "DNAT $l/$proto -> $to 在 (带标记)"
                else
                    echo "!! DNAT $l/$proto -> $to 不在内核里, 跑 $PROG apply 重建"; failed=1
                fi
            fi
            if [ -n "$lip" ]; then
                if iptables -t nat -C POSTROUTING -p "$proto" -d "$t" --dport "$tp" -j SNAT --to-source "$lip" 2>/dev/null; then
                    ok "SNAT $t:$tp/$proto -> $lip 在"
                elif iptables -t nat -S POSTROUTING 2>/dev/null | grep -qF "ipfwd:$l:$proto"; then
                    ok "SNAT $t:$tp/$proto -> $lip 在 (带标记)"
                else
                    echo "!! SNAT $t:$tp/$proto 不在内核里, 跑 $PROG apply 重建"; failed=1
                fi
            fi
        done
    done < "$RULES_FILE"
    [ "$failed" -eq 0 ] && echo && ok "检查通过" || echo
    return "$failed"
}

cmd_clear() {
    if [ ! -s "$RULES_FILE" ]; then echo "配置已经是空的"; return 0; fi
    if [ -t 0 ]; then
        printf '确定要清空全部转发规则吗? [y/N] '
        local ans=""; read -r ans || return 1
        case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; return 1 ;; esac
    fi
    ensure_config_dir || return 1
    acquire_lock || return 1
    backup_rules || { release_lock; echo "错误: 备份失败"; return 1; }
    : > "$RULES_FILE" || { restore_rules_from_backup; release_lock; echo "错误: 清空失败, 已恢复"; return 1; }
    prune_stale_rules || true
    # 没标记的老规则 (comment 模块缺失时建的) 按旧配置逐条删: 用备份文件里的行
    if [ -f "$BACKUP_DIR/rules.conf.bak" ]; then
        local lip=""
        lip=$(get_local_ip 2>/dev/null || echo "")
        if [ -n "$lip" ]; then
            local line l t tp pr proto
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in ''|'#'*) continue ;; esac
                # shellcheck disable=SC2086
                set -- $line
                l="$1"; t="$2"; tp="$3"; pr="$4"
                for proto in $(protos_for "$pr"); do
                    delete_one_rule nat PREROUTING "$proto" "$l" "$t" "$tp" "$lip" dnat
                    delete_one_rule nat POSTROUTING "$proto" "$l" "$t" "$tp" "$lip" snat
                done
            done < "$BACKUP_DIR/rules.conf.bak"
        fi
    fi
    save_rules >/dev/null 2>&1 || true
    release_lock
    ok "已清空全部转发规则"
    return 0
}

# 版本号转数字: v2 -> 2, v10 -> 10, 非法格式返回 1
ver_num() {
    local v="$1"
    case "$v" in
        v[0-9]*) printf '%s' "${v#v}" ;;
        *) return 1 ;;
    esac
}

# 当前脚本文件的实际路径 (装好后是 /usr/local/bin/iptables-forward)
installed_path() {
    local p=""
    p=$(readlink -f "$0" 2>/dev/null || echo "")
    if [ -z "$p" ] || [ ! -f "$p" ]; then
        p=$(command -v "$0" 2>/dev/null || echo "$0")
    fi
    printf '%s' "$p"
}

# 更新脚本: 从 GitHub 拉最新版, 校验通过才替换, 规则文件不动。
# 用独立的更新锁, 不和 add/del/edit 的规则锁抢同一把。
cmd_update() {
    [ -n "${1:-}" ] && { echo "错误: update 不带参数" >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { echo "错误: 本机没有 curl, 先装: apt-get install -y curl" >&2; return 1; }
    local self="" tmp="" bak=""
    self=$(installed_path)
    [ -f "$self" ] || { echo "错误: 找不到当前脚本文件: $self" >&2; return 1; }
    # 更新锁: 另一个 update 正在跑就直接退出, 不排队等
    local lock_dir=""
    lock_dir=$(dirname "$UPDATE_LOCK_FILE")
    [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || UPDATE_LOCK_FILE="/tmp/iptables-forward-update.lock"
    exec 8>"$UPDATE_LOCK_FILE" 2>/dev/null || { echo "错误: 建更新锁失败" >&2; return 1; }
    if ! flock -n 8 2>/dev/null; then
        exec 8>&-
        echo "错误: 另一个更新正在运行, 稍后再试" >&2
        return 1
    fi
    tmp=$(mktemp /tmp/iptables-forward-update.XXXXXX) || { exec 8>&-; echo "错误: 建临时文件失败" >&2; return 1; }
    echo "正在从 GitHub 拉最新版..."
    echo "地址: $UPDATE_URL"
    if ! curl -fsSL -o "$tmp" "$UPDATE_URL"; then
        rm -f "$tmp"; exec 8>&-
        echo "错误: 下载失败, 检查网络或 GitHub 链接" >&2
        return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; exec 8>&-; echo "错误: 下载到的文件是空的, 没换任何东西" >&2; return 1; }
    if ! bash -n "$tmp"; then
        rm -f "$tmp"; exec 8>&-
        echo "错误: 下载到的脚本语法有问题, 没换任何东西" >&2
        return 1
    fi
    local new_ver="" new_num="" cur_num=""
    new_ver=$(grep -m1 '^SCRIPT_VERSION="' "$tmp" | cut -d'"' -f2)
    if [ -z "$new_ver" ]; then
        rm -f "$tmp"; exec 8>&-
        echo "错误: 下载到的文件里没找到版本号, 没换任何东西" >&2
        return 1
    fi
    new_num=$(ver_num "$new_ver") || { rm -f "$tmp"; exec 8>&-; echo "错误: 新版本号格式不对: $new_ver (应为 v+数字)" >&2; return 1; }
    cur_num=$(ver_num "$SCRIPT_VERSION") || { rm -f "$tmp"; exec 8>&-; echo "错误: 本地版本号格式不对: $SCRIPT_VERSION" >&2; return 1; }
    if [ "$new_num" -eq "$cur_num" ]; then
        rm -f "$tmp"; exec 8>&-
        ok "已经是最新版 ($SCRIPT_VERSION), 不用更新"
        return 0
    fi
    if [ "$new_num" -lt "$cur_num" ]; then
        rm -f "$tmp"; exec 8>&-
        echo "提醒: GitHub 上的 $new_ver 比本地的 $SCRIPT_VERSION 还旧, 先去 GitHub 覆盖上传新版再更新" >&2
        return 1
    fi
    echo "发现新版 $new_ver (本地 $SCRIPT_VERSION), 正在更新..."
    bak="$self.bak"
    if ! cp "$self" "$bak"; then
        rm -f "$tmp"; exec 8>&-
        echo "错误: 备份当前版本失败, 没换任何东西" >&2
        return 1
    fi
    if ! cp "$tmp" "$self"; then
        cp "$bak" "$self" 2>/dev/null || true
        rm -f "$tmp"; exec 8>&-
        echo "错误: 替换失败, 已从备份恢复" >&2
        return 1
    fi
    rm -f "$tmp"
    chmod +x "$self" 2>/dev/null || true
    # 替换成功才放更新锁: 后面的 install 和重开菜单不再需要它
    exec 8>&-
    # 跑一次 install 刷新安装 (规则文件不动), 失败就从备份恢复
    if ! bash "$self" install; then
        cp "$bak" "$self" 2>/dev/null || true
        echo "错误: 新版安装失败, 已恢复到 $SCRIPT_VERSION" >&2
        return 1
    fi
    rm -f "$bak"
    ok "已更新到 $new_ver"
    if [ -t 0 ]; then
        echo "正在用新版重开菜单..."
        exec bash "$self" menu
    else
        bash "$self" version
    fi
    return 0
}

cmd_install() {
    echo "== 1/5 装 iptables-forward $SCRIPT_VERSION =="
    ensure_config_dir || { echo "错误: 建配置目录失败"; return 1; }
    local self=""
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$self" != "/usr/local/bin/$PROG" ]; then
        cp "$self" "/usr/local/bin/$PROG" || { echo "错误: 复制到 /usr/local/bin/$PROG 失败"; return 1; }
        chmod +x "/usr/local/bin/$PROG" || true
        ln -sf "/usr/local/bin/$PROG" "/usr/local/bin/ipfwd" 2>/dev/null || true
        echo "已装到 /usr/local/bin/$PROG (快捷别名: ipfwd)"
    fi
    echo "== 2/5 检查 iptables =="
    ensure_iptables || return 1
    ok "iptables 就绪"
    echo "== 3/5 开转发 =="
    ensure_forwarding || return 1
    ok "net.ipv4.ip_forward = 1 (已持久化)"
    echo "== 4/5 本机 IP (SNAT 源) =="
    local lip=""
    lip=$(get_local_ip 2>/dev/null || echo "")
    if [ -n "$lip" ]; then
        printf '%s\n' "$lip" > "$LOCAL_IP_FILE" 2>/dev/null || true
        ok "本机 IP: $lip (已存到 $LOCAL_IP_FILE, 不对就跑 $PROG set-ip <内网IP> 改)"
    else
        warn "探测不到本机 IP, 加规则前先跑: $PROG set-ip <内网IP>"
    fi
    echo "== 5/5 持久化 + 重建规则 =="
    ensure_persistence || true
    apply_rules || warn "重建规则有警告 (配置为空时这是正常的)"
    save_rules >/dev/null 2>&1 || true
    echo
    ok "安装完成: $PROG $SCRIPT_VERSION"
    echo "菜单: $PROG"
    echo "加规则: $PROG add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]"
    return 0
}

cmd_uninstall() {
    if [ -t 0 ]; then
        printf '卸载会删掉本脚本建的全部转发规则和配置文件, 确定吗? [y/N] '
        local ans=""; read -r ans || return 1
        case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; return 1 ;; esac
    fi
    # 先清规则 (cmd_clear 在非终端下不问, 这里已经问过了)
    if [ -s "$RULES_FILE" ]; then
        # 临时把 stdin 关掉, 让 clear 不再问
        cmd_clear < /dev/null || warn "清空规则有警告"
    fi
    systemctl disable iptables-forward.service 2>/dev/null || true
    rm -f "$SYSTEMD_UNIT" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -f "/usr/local/bin/$PROG" "/usr/local/bin/ipfwd" 2>/dev/null || true
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    ok "已卸载 (iptables 本身没动, 其他规则不受影响)"
    return 0
}

# ---------- 交互菜单 ----------

menu() {
    need_root "menu"
    ensure_config_dir || { echo "错误: 建配置目录失败"; return 1; }
    while true; do
        echo
        echo "=== iptables-forward $SCRIPT_VERSION (CloudIPLC iptables 教程版) ==="
        local lip=""
        lip=$(get_local_ip 2>/dev/null || echo "未设置")
        local count=0
        [ -f "$RULES_FILE" ] && count=$(grep -vcE '^\s*(#|$)' "$RULES_FILE" 2>/dev/null || echo 0)
        echo "本机 IP: $lip | 规则数: $count | 配置: $RULES_FILE"
        echo " 1. 添加转发规则"
        echo " 2. 删除转发规则"
        echo " 3. 查看转发规则"
        echo " 4. 检查状态"
        echo " 5. 重新应用规则 (手动改过配置文件 / 实时规则丢了才用)"
        echo " 6. 修改转发规则"
        echo " 7. 清空全部规则"
        echo " 8. 设置本机 IP (SNAT 源)"
        echo " 9. 更新脚本 (从 GitHub 拉最新版)"
        echo " 10. 卸载脚本"
        echo " 0. 退出"
        printf '请选择 [0-10]: '
        local choice=""
        read -r choice || return 0
        case "$choice" in
            1)
                printf '本机端口 (单个如 42168, 或一段如 10000:65535): '; local lp=""; read -r lp
                printf '目标 IP 或域名: '; local tg=""; read -r tg
                printf '目标端口 (回车 = 和本机端口一样): '; local tp=""; read -r tp
                printf '协议 tcp/udp/both (回车 = both): '; local pr=""; read -r pr
                [ -n "$lp" ] && [ -n "$tg" ] || { echo "本机端口和目标不能为空"; continue; }
                cmd_add "$lp" "$tg" "$tp" "${pr:-both}" || echo "添加失败, 见上面原因"
                ;;
            2)
                cmd_list
                printf '要删的本机端口: '; local dp=""; read -r dp
                printf '协议 tcp/udp/both (回车 = both): '; local dpr=""; read -r dpr
                [ -n "$dp" ] || { echo "已取消"; continue; }
                cmd_del "$dp" "${dpr:-both}" || echo "删除失败, 见上面原因"
                ;;
            3) cmd_list ;;
            4) cmd_check || echo "检查发现问题, 见上面 !! 的行" ;;
            5)
                if apply_rules; then ok "已从配置文件重建实时规则"; else echo "重建失败, 见上面原因"; fi
                ;;
            6)
                cmd_list
                printf '要改的本机端口: '; local ep=""; read -r ep
                [ -n "$ep" ] || { echo "已取消"; continue; }
                local cur_line=""
                cur_line=$(config_find "$ep" "") || { echo "没找到 $ep 的规则"; continue; }
                echo "当前: $cur_line"
                printf '新目标 IP 或域名 (回车 = 不变): '; local nt=""; read -r nt
                printf '新目标端口 (回车 = 不变): '; local ntp=""; read -r ntp
                printf '新协议 tcp/udp/both (回车 = 不变): '; local npr=""; read -r npr
                printf '新本机端口 (回车 = 不变): '; local nlp=""; read -r nlp
                local ct ctp cpr
                # shellcheck disable=SC2086
                set -- $cur_line
                ct="$2"; ctp="$3"; cpr="$4"
                cmd_edit "$ep" "${nt:-$ct}" "${ntp:-$ctp}" "${npr:-$cpr}" "${nlp:-$ep}" || echo "修改失败, 见上面原因"
                ;;
            7) cmd_clear || echo "清空失败或已取消" ;;
            8)
                printf '本机 IP (回车 = 自动探测, 现在是 %s): ' "$lip"
                local nip=""; read -r nip
                if [ -n "$nip" ]; then cmd_set_ip "$nip"; else
                    local dip=""
                    dip=$(detect_local_ip) && cmd_set_ip "$dip" || echo "探测不到, 手动填一个内网 IP"
                fi
                ;;
            9)
                cmd_update || echo "更新失败, 见上面原因"
                ;;
            10)
                if cmd_uninstall; then return 0; fi
                ;;
            0) echo "退出"; return 0 ;;
            *) echo "输入 0-10" ;;
        esac
    done
}

# ---------- 入口 ----------

main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        menu) menu ;;
        help|--help|-h) print_help ;;
        version) cmd_version "${2:-}" ;;
        install) need_root "install"; cmd_install ;;
        update) need_root "update"; cmd_update ;;
        uninstall) need_root "uninstall"; cmd_uninstall ;;
        add) need_root "add"; shift; cmd_add "$@" ;;
        del|delete) need_root "del"; shift; cmd_del "$@" ;;
        edit) need_root "edit"; shift; cmd_edit "$@" ;;
        list|ls) cmd_list ;;
        check|status) cmd_check ;;
        apply) need_root "apply"; apply_rules ;;
        set-ip) need_root "set-ip"; shift; cmd_set_ip "$@" ;;
        clear) need_root "clear"; cmd_clear ;;
        *)
            echo "错误: 未知命令: $cmd" >&2
            print_help >&2
            return 1
            ;;
    esac
}

trap release_lock EXIT
main "$@"

