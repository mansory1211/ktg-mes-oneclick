#!/usr/bin/env bash
#====================================================================================
#  KTG-MES 一键部署管理工具 v7.0
#------------------------------------------------------------------------------------
#  从零实测中踩到的坑已全部内置自动处理，一条命令跑通：
#      源码 → 容器 → 建库 → 改配置 → 编译 → 启动 → 体检
#
#  【源码 / 环境】
#   1. 真实 Gitee 仓库 https://gitee.com/kutangguo/ktg-mes（旧脚本地址 404）；Gitee
#      失败可走 GitHub 加速前缀；源码支持 git 浅克隆与 zip 归档两种兜底
#   2. 国内源一键切换并探测可用性：APT / YUM / Maven / npm / pip / Node / Docker
#   3. 缺 docker / java8 / node 自动安装；JDK8（Ubuntu 22.04+ 已移除）走清华 Adoptium
#      镜像兜底；编译工具链（make/g++/python3）自动补
#
#  【数据库（本项目最大坑位）】
#   4. 执行顺序修正：先改数据库配置再打包，避免 jar 内仍是 your_password
#   5. 【致命】仓库 sql/ 只有 ry_20210908.sql + quartz.sql（若依框架表），MES 业务表
#      （md_*/pro_*/print_* 等共 181 张，含打印模块）全缺 → 改为优先导入仓库自带的
#      完整导出 doc/实施文档/ktgmes_*.sql.gz|zip（含表结构与数据）
#   6. 用“业务表哨兵”判断是否已初始化，避免“库里有表就跳过”导致业务表永远缺失
#   7. 【致命】代码 master 比导出新：导出(2025-05-18)之后给 pro_feedback / qc_ipqc
#      各加了 3 个废品数量列 → apply_schema_patches 幂等补列；patch-db 可单独执行
#   8. 数据源改为按 YAML 层级精确修改，不再 sed 全量替换（会误伤 druid 控制台密码）
#
#  【前端】
#   9. 构建脚本用 build:prod（package.json 没有 build）；端口显式 1024（避开 80 冲突）
#  10. 显式 --host 0.0.0.0 并校验监听网卡，避免只绑 127.0.0.1 导致外部打不开
#  11. Node 17+ 上 webpack4 需 --openssl-legacy-provider（build 与 dev 都加）
#  12. less/less-loader 锁定 webpack4 兼容版本（less@3.13.1 + less-loader@6.2.0）
#  13. 启动等待 180s，失败区分“仍在编译 / 已退出”并打印日志，不再假报成功
#
#  【访问层】
#  14. 自动探测局域网 IP，摘要/状态/体检均给出真实可访问地址（不再只给 127.0.0.1）
#  15. Linux 自动放行 ufw / firewalld / iptables 的前端 1024 + 后端 8080
#  16. 识别 WSL：浏览器用 localhost；局域网设备需在 Windows 放行（输出对应命令）
#
#  【运维】
#  17. 进程按端口管理，不用 pkill -f（避免 curl|bash 时误杀父进程）
#  18. verify 体检：容器 / Redis / 业务表 / 关键字段 / 后端与前端 HTTP / 监听网卡 / 防火墙
#  19. repair 一键修复：建库 + 补列 + 启动 + 体检
#  20. 所有组件日志落盘到 logs/；清理只删本项目资源
#  21. Docker 镜像版本集中管理：默认锁定 mysql:5.7.44 / redis:7.2.5（可用
#      KTG_MYSQL_IMAGE / KTG_REDIS_IMAGE 覆盖）；新增 images 命令查看脚本配置版本、
#      本地拉取状态、容器实际镜像与 RepoDigest 摘要
#------------------------------------------------------------------------------------
#  用法：sudo ./ktg-mes.sh [install|up|repair|verify|status|images|mirrors|db|sql|patch-db|build|build-fe|start|start-fe|stop|restart|log|log-fe|firewall|clean|uninstall|menu]
#  终端快捷命令（安装后生效）：ktgup=快捷开启  ktgoff=停止  ktgst=状态  ktgck=体检
#  全部配置项均可用环境变量覆盖，例如：sudo KTG_MYSQL_PWD=xxx ./ktg-mes.sh install
#====================================================================================
set -Eeuo pipefail

# ======================= 全局配置（可用环境变量覆盖） =======================
WORK_DIR="${KTG_WORK_DIR:-/root/ktg-mes-deploy}"
BACKEND_DIR="$WORK_DIR/ktg-mes"
FRONTEND_DIR="$WORK_DIR/ktg-mes-ui"
LOG_DIR="$WORK_DIR/logs"

# ---- Docker 镜像与版本：集中在下方管理，默认锁定到具体小版本，避免浮动 tag 漂移 ----
# 升级镜像：改这里或设环境变量，然后 docker rm -f 旧容器再重跑 db（已存在的容器不会重建）
# 查看当前配置/本地/容器实际版本：sudo ./ktg-mes.sh images
MYSQL_CONTAINER="${KTG_MYSQL_CONTAINER:-ktg-mysql}"
MYSQL_IMAGE="${KTG_MYSQL_IMAGE:-mysql:5.7.44}"       # MySQL 5.7 系列最终版
MYSQL_PORT="${KTG_MYSQL_PORT:-3306}"
MYSQL_ROOT_PWD="${KTG_MYSQL_PWD:-123456}"
MYSQL_DB="${KTG_MYSQL_DB:-j2eedb}"

REDIS_CONTAINER="${KTG_REDIS_CONTAINER:-ktg-redis}"
REDIS_IMAGE="${KTG_REDIS_IMAGE:-redis:7.2.5}"        # Redis 7.2 稳定版
REDIS_PORT="${KTG_REDIS_PORT:-6379}"
REDIS_PWD="${KTG_REDIS_PWD:-123456}"

BACKEND_PORT="${KTG_BACKEND_PORT:-8080}"
FRONTEND_PORT="${KTG_FRONTEND_PORT:-1024}"
# 前端监听地址：必须 0.0.0.0 才能被局域网/公网访问（显式传入，覆盖 vue.config.js 的 host）
FRONTEND_HOST="${KTG_FRONTEND_HOST:-0.0.0.0}"
GLOBAL_CMD="ktg"

# 真实仓库（v4.8 的 ktg-dev/... 已 404）
BACKEND_REPO="${KTG_BACKEND_REPO:-https://gitee.com/kutangguo/ktg-mes.git}"
FRONTEND_REPO="${KTG_FRONTEND_REPO:-https://gitee.com/kutangguo/ktg-mes-ui.git}"

# ======================= 国内网络加速源（重点优化） =======================
# 统一开关：KTG_USE_CN_MIRROR=0 可整体关闭，改用官方源
USE_CN_MIRROR="${KTG_USE_CN_MIRROR:-1}"

# -- APT：阿里云为主，清华/中科大为备（按顺序探测可用性） --
APT_MIRRORS=(
  "${KTG_APT_MIRROR:-https://mirrors.aliyun.com}"
  "https://mirrors.tuna.tsinghua.edu.cn"
  "https://mirrors.ustc.edu.cn"
)

# -- Maven：阿里云公共仓库（同时覆盖 central 与 spring 等常用仓库） --
MAVEN_SETTINGS="${KTG_MAVEN_SETTINGS:-/etc/maven/settings.xml}"
MAVEN_MIRROR="${KTG_MAVEN_MIRROR:-https://maven.aliyun.com/repository/public}"
MAVEN_REPO_LOCAL="${KTG_MAVEN_REPO_LOCAL:-/root/.m2/repository}"

# -- npm：npmmirror（原淘宝源） --
NPM_MIRROR="${KTG_NPM_MIRROR:-https://registry.npmmirror.com}"

# -- Node.js 二进制：npmmirror 镜像（官方 nodejs.org 在国内常超时） --
NODE_MIRRORS=(
  "${KTG_NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
  "https://mirrors.tuna.tsinghua.edu.cn/nodejs-release"
  "https://nodejs.org/dist"
)
NODE_MIN_MAJOR=14
NODE_TARGET_VERSION="${KTG_NODE_VERSION:-16.20.2}"

# -- JDK 8 兜底下载：清华 Adoptium 镜像（api.adoptium.net 国内基本不可用） --
TEMURIN_MIRROR="${KTG_TEMURIN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/Adoptium}"

# -- pip（脚本自带 python3 只用标准库，配置仅为环境整洁/兼容） --
PIP_MIRROR="${KTG_PIP_MIRROR:-https://mirrors.aliyun.com/pypi/simple}"

# -- Docker：优先使用你的专属加速地址；否则用公益镜像站 --
#    申请专属地址：https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors
DOCKER_MIRROR="${KTG_DOCKER_MIRROR:-}"
DOCKER_MIRRORS=(
  "https://docker.m.daocloud.io"
  "https://docker.1ms.run"
  "https://dockerproxy.cn"
)
# 拉取镜像的回退注册表前缀（官方仓库在国内常被墙）
DOCKER_REGISTRY_FALLBACKS=(
  "docker.m.daocloud.io"
  "docker.1ms.run"
  "dockerproxy.cn"
)

# -- 无 Gitee 账号/仓库不可用时的 GitHub 加速前缀（git clone 用） --
GH_PROXY="${KTG_GH_PROXY:-https://ghfast.top}"

# -- 网络超时与重试（国内首次拉包经常需要更长时间） --
CURL_OPTS=(-fsSL --connect-timeout 15 --retry 3 --retry-delay 2 --max-time "${KTG_DL_TIMEOUT:-900}")

BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
BACKEND_PID_FILE="$WORK_DIR/backend.pid"
FRONTEND_PID_FILE="$WORK_DIR/frontend.pid"

# ======================= 输出函数 =======================
_c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { _c '32' "[INFO]  $*"; }
warn() { _c '33' "[WARN]  $*"; }
err()  { _c '31' "[ERROR] $*" >&2; }
ok()   { _c '32' "✔  $*"; }
step() { printf '\n\033[36m===== %s =====\033[0m\n' "$*"; }

on_error() {
    local rc=$?
    err "脚本在第 $1 行中断（退出码 $rc）"
    err "排查日志目录：$LOG_DIR"
    exit "$rc"
}
trap 'on_error $LINENO' ERR

# ======================= 基础工具函数 =======================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 权限运行：sudo $0 $*"
        exit 1
    fi
}

has_systemd() { cmd_exists systemctl && [ -d /run/systemd/system ]; }

# ======================= 国内源探测与下载 =======================
# 探测某个源是否可达（HEAD 请求即可，避免下载整包浪费时间）
# 注意：Docker 注册表等端点对未认证请求返回 401/403，属“可达”，不能判失败
url_ok() {
    local url="$1" t="${2:-8}" code
    code="$(curl -sSI -o /dev/null -w '%{http_code}' \
        --connect-timeout "$t" --max-time "$((t * 2))" "$url" 2>/dev/null || true)"
    case "$code" in
        2??|401|403) return 0 ;;
        *) return 1 ;;
    esac
}

# 按顺序挑选第一个可达的源，结果写入 stdout
pick_mirror() {
    local u
    for u in "$@"; do
        if url_ok "$u"; then
            printf '%s\n' "$u"
            return 0
        fi
    done
    return 1
}

# 多源下载：逐个尝试，全部失败才返回非 0
download_first() {
    local out="$1"; shift
    local u
    for u in "$@"; do
        info "下载：$u"
        if curl "${CURL_OPTS[@]}" -o "$out" "$u"; then
            return 0
        fi
        warn "该源不可用，尝试下一个"
    done
    return 1
}

# ---------- APT 源 ----------
setup_apt_mirror() {
    [ "$USE_CN_MIRROR" = "1" ] || { info "已关闭国内源优化，保留系统默认 APT 源"; return 0; }
    cmd_exists apt-get || return 0

    # 已经指向国内源就不再折腾
    if grep -rqsE 'mirrors\.(aliyun|tuna|ustc|163|huaweicloud)' \
        /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        ok "APT 已在使用国内源"
        return 0
    fi

    local distro codename base
    distro="$( (. /etc/os-release 2>/dev/null && echo "${ID:-}") || true)"
    codename="$( (. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}") || true)"
    if [ "$distro" != "ubuntu" ] && [ "$distro" != "debian" ]; then
        warn "未识别的 APT 发行版（ID=$distro），跳过 APT 源替换（避免破坏系统）"
        return 0
    fi
    [ -n "$codename" ] || { warn "未识别版本代号，跳过 APT 源替换"; return 0; }

    info "探测国内 APT 源可用性（$distro/$codename）..."
    if ! base="$(pick_mirror "${APT_MIRRORS[@]}")"; then
        warn "所有国内 APT 源均不可达，保留系统默认源"
        return 0
    fi
    ok "选用 APT 源：$base"

    local stamp; stamp="$(date +%Y%m%d%H%M%S)"
    mkdir -p "$WORK_DIR/backup"
    cp -a /etc/apt/sources.list "$WORK_DIR/backup/sources.list.$stamp" 2>/dev/null || true
    # 把 sources.list.d 下已有的源全部置为 .disabled，统一由 sources.list 提供源
    # 这样 Ubuntu 22.04/24.04 的 deb822(.sources) 与旧 .list 都不会残留旧源
    local f
    for f in /etc/apt/sources.list.d/*; do
        [ -e "$f" ] || continue
        case "$f" in
            *.disabled) continue ;;
            *) mv "$f" "$f.disabled" 2>/dev/null || true ;;
        esac
    done

    if [ "$distro" = "ubuntu" ]; then
        cat > /etc/apt/sources.list <<EOF
deb $base/ubuntu/ $codename main restricted universe multiverse
deb $base/ubuntu/ $codename-updates main restricted universe multiverse
deb $base/ubuntu/ $codename-backports main restricted universe multiverse
deb $base/ubuntu/ $codename-security main restricted universe multiverse
EOF
    else
        cat > /etc/apt/sources.list <<EOF
deb $base/debian/ $codename main contrib non-free
deb $base/debian/ $codename-updates main contrib non-free
deb $base/debian-security/ ${codename}-security main contrib non-free
EOF
    fi

    rm -f "$WORK_DIR/.apt-updated"
    if DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        ok "APT 源已切换为 $base（原配置备份于 $WORK_DIR/backup/）"
    else
        err "切换后的 APT 源不可用，回滚为系统默认源"
        cp -a "$WORK_DIR/backup/sources.list.$stamp" /etc/apt/sources.list 2>/dev/null || true
        for f in /etc/apt/sources.list.d/*.disabled; do
            [ -e "$f" ] || continue
            mv "$f" "${f%.disabled}" 2>/dev/null || true
        done
        rm -f "$WORK_DIR/.apt-updated"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    fi
}

# ---------- YUM / DNF 源（CentOS / Rocky / AlmaLinux） ----------
setup_yum_mirror() {
    [ "$USE_CN_MIRROR" = "1" ] || return 0
    cmd_exists yum || cmd_exists dnf || return 0

    # 已指向国内源就不再折腾
    if grep -rqsE 'mirrors\.(aliyun|tuna|ustc|163|huaweicloud)' \
        /etc/yum.repos.d/*.repo 2>/dev/null; then
        ok "YUM/DNF 已在使用国内源"
        return 0
    fi

    local releasever
    releasever="$( (. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}") || true)"
    releasever="${releasever%%.*}"

    # 优先阿里云 base/updates/epel；epel 按 EL 版本号区分
    local base_url="https://mirrors.aliyun.com"
    local mirror_dir="centos"
    if grep -qsE '^(rocky|almalinux)$' /etc/os-release 2>/dev/null; then
        mirror_dir="$(grep -oE '^(rocky|almalinux)' /etc/os-release | head -1)"
    fi

    mkdir -p "$WORK_DIR/backup"
    cp -a /etc/yum.repos.d "$WORK_DIR/backup/yum.repos.d.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    if cmd_exists dnf; then
        # 幂等：已存在则只刷新，避免重复重建
        local cfg=/etc/yum.repos.d/ktg-mirror.repo
        cat > "$cfg" <<EOF
[ktg-base]
name=ktg base
baseurl=$base_url/$mirror_dir-stream/\$releasever-stream/BaseOS/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[ktg-appstream]
name=ktg appstream
baseurl=$base_url/$mirror_dir-stream/\$releasever-stream/AppStream/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOF
    else
        cat > /etc/yum.repos.d/ktg-mirror.repo <<EOF
[ktg-base]
name=ktg base
baseurl=$base_url/$mirror_dir/\$releasever/os/\$basearch/
enabled=1
gpgcheck=0

[ktg-updates]
name=ktg updates
baseurl=$base_url/$mirror_dir/\$releasever/updates/\$basearch/
enabled=1
gpgcheck=0
EOF
    fi
    # 让新源生效，旧的第三方 repo 保留不动（避免误删用户自建源）
    (yum makecache 2>/dev/null || dnf makecache 2>/dev/null) || true
    ok "YUM/DNF 源已切换为 $base_url/$mirror_dir"
}

# ---------- npm 源 ----------
setup_npm_mirror() {
    [ "$USE_CN_MIRROR" = "1" ] || return 0
    cmd_exists npm || return 0
    export npm_config_registry="$NPM_MIRROR"
    local cfg=/root/.npmrc
    if ! grep -qs 'registry=' "$cfg" 2>/dev/null; then
        printf 'registry=%s\n' "$NPM_MIRROR" >> "$cfg"
    fi
    ok "npm 源：$NPM_MIRROR"
}

# ---------- pip 源 ----------
setup_pip_mirror() {
    [ "$USE_CN_MIRROR" = "1" ] || return 0
    mkdir -p /root/.pip
    cat > /root/.pip/pip.conf <<EOF
[global]
index-url = $PIP_MIRROR
trusted-host = $(printf '%s' "$PIP_MIRROR" | awk -F/ '{print $3}')
timeout = 60
EOF
    ok "pip 源：$PIP_MIRROR"
}

# ---------- Docker 源 ----------
setup_docker_mirror() {
    [ "$USE_CN_MIRROR" = "1" ] || { info "已关闭国内源优化，保留 Docker 默认配置"; return 0; }
    ensure_docker_running

    local mirrors=()
    if [ -n "$DOCKER_MIRROR" ]; then
        mirrors=("$DOCKER_MIRROR")
        ok "使用你指定的 Docker 加速地址：$DOCKER_MIRROR"
    else
        local u
        for u in "${DOCKER_MIRRORS[@]}"; do
            if url_ok "$u/v2/" 6; then
                mirrors+=("$u")
                info "Docker 加速源可用：$u"
                [ "${#mirrors[@]}" -ge 2 ] && break
            fi
        done
        if [ "${#mirrors[@]}" -eq 0 ]; then
            warn "未探测到可用的 Docker 公益加速源"
            warn "建议申请阿里云专属加速地址后重跑："
            warn "  sudo KTG_DOCKER_MIRROR=https://xxxx.mirror.aliyuncs.com $0 mirrors"
            warn "拉取镜像时将直接走官方仓库，并按注册表前缀自动回退"
            return 0
        fi
    fi

    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        cp -f /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    fi
    {
        printf '{\n  "registry-mirrors": ['
        local first=1 m
        for m in "${mirrors[@]}"; do
            [ "$first" -eq 1 ] || printf ', '
            printf '"%s"' "$m"
            first=0
        done
        printf '],\n'
        printf '  "log-driver": "json-file",\n'
        printf '  "log-opts": {"max-size": "100m", "max-file": "3"}\n}\n'
    } > /etc/docker/daemon.json

    if has_systemd; then
        systemctl daemon-reload || true
        systemctl restart docker || true
        local i
        for i in $(seq 1 15); do
            docker info >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    ok "Docker 加速源已写入 /etc/docker/daemon.json（原文件已备份）"
}

# 拉取镜像：先按配置的加速源拉，失败再按注册表前缀回退
pull_image() {
    local image="$1"
    info "拉取镜像：$image"
    if docker image inspect "$image" >/dev/null 2>&1; then
        ok "本地已有镜像 $image"
        return 0
    fi
    if docker pull "$image" >> "$LOG_DIR/docker-pull.log" 2>&1; then
        return 0
    fi
    warn "直连拉取失败，尝试国内注册表前缀回退..."
    local reg
    for reg in "${DOCKER_REGISTRY_FALLBACKS[@]}"; do
        info "尝试 $reg/$image"
        if docker pull "$reg/$image" >> "$LOG_DIR/docker-pull.log" 2>&1; then
            docker tag "$reg/$image" "$image"
            docker rmi "$reg/$image" >/dev/null 2>&1 || true
            ok "已通过 $reg 拉取并重命名为 $image"
            return 0
        fi
    done
    err "镜像 $image 拉取失败，日志：$LOG_DIR/docker-pull.log"
    err "可手动重试：docker pull $image  或设置 KTG_DOCKER_MIRROR 后重跑"
    return 1
}

port_free() {
    local p="$1"
    if cmd_exists ss; then
        ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif cmd_exists netstat; then
        ! netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        return 0
    fi
}

wait_port_free() {
    local p="$1" i
    for i in $(seq 1 30); do
        port_free "$p" && return 0
        sleep 1
    done
    return 1
}

wait_for_port() {
    local p="$1" timeout="${2:-90}" i
    for i in $(seq 1 "$timeout"); do
        port_free "$p" || return 0
        sleep 1
    done
    return 1
}

# ======================= 访问层辅助（局域网 IP / 监听范围 / 防火墙） =======================
# 探测本机对外可用的 IP。不发起外网请求，只查本地路由表/网卡，离线也能用。
detect_lan_ip() {
    local ip=""
    if cmd_exists ip; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
        if [ -z "$ip" ]; then
            ip="$(ip -4 -o addr show scope global 2>/dev/null \
                | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
        fi
    fi
    if [ -z "$ip" ] && cmd_exists hostname; then
        ip="$(hostname -I 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./ && $i !~ /:/){print $i; exit}}' || true)"
    fi
    printf '%s\n' "${ip:-127.0.0.1}"
}

# 端口监听范围：all=所有网卡（外部可访问）/ local=仅 127.0.0.1 / none=未监听 / unknown=无检测工具
port_scope() {
    local p="$1" out="" line tool=""
    if cmd_exists ss; then
        tool=ss
    elif cmd_exists netstat; then
        tool=netstat
    else
        printf 'unknown\n'
        return 0
    fi
    if [ "$tool" = "ss" ]; then
        out="$(ss -H -ltn 2>/dev/null | awk -v port="$p" '$4 ~ (":" port "$") {print $4}' || true)"
    else
        out="$(netstat -ltn 2>/dev/null | awk -v port="$p" '$4 ~ (":" port "$") {print $4}' || true)"
    fi
    if [ -z "$out" ]; then
        printf 'none\n'
        return 0
    fi
    while IFS= read -r line; do
        # 去掉 ":端口" 后比较地址部分：0.0.0.0 / * / [::] / :: 都表示所有网卡
        case "${line%:*}" in
            0.0.0.0|'*'|'[::]'|'::') printf 'all\n'; return 0 ;;
        esac
    done <<EOF
$out
EOF
    printf 'local\n'
}

# 是否运行在 WSL（WSL1/WSL2）
is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

# WSL 下的访问说明：WSL 内不需要 ufw/iptables，入站由 Windows 防火墙 / Hyper-V 防火墙决定
wsl_access_note() {
    local ip
    ip="$(detect_lan_ip)"
    echo "  ── WSL 访问说明 ──"
    echo "  ▸ Windows 浏览器访问（推荐）：http://localhost:${FRONTEND_PORT}"
    echo "  ▸ 局域网其它设备访问       ：http://${ip}:${FRONTEND_PORT}"
    echo "  ▸ 注意：镜像模式下 http://${ip} 连本机常打不开（WSL Hyper-V 防火墙默认"
    echo "    DefaultInboundAction=Block，且本机访问自己 LAN IP 不回路）；本机请用 localhost。"
    echo "  ▸ 要让局域网设备访问，在 Windows 用【管理员 PowerShell】执行："
    echo "      # 1) 放行 WSL 虚拟机入站（镜像模式必需，否则普通端口规则不生效）"
    echo "      New-NetFirewallHyperVRule -Name 'KTG-fe-${FRONTEND_PORT}' -DisplayName 'KTG frontend ${FRONTEND_PORT}' -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts ${FRONTEND_PORT} -Action Allow"
    echo "      New-NetFirewallHyperVRule -Name 'KTG-be-${BACKEND_PORT}' -DisplayName 'KTG backend ${BACKEND_PORT}' -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts ${BACKEND_PORT} -Action Allow"
    echo "      # 2) 同时放行 Windows 防火墙对应端口"
    echo "      New-NetFirewallRule -DisplayName 'KTG-frontend-${FRONTEND_PORT}' -Direction Inbound -Protocol TCP -LocalPort ${FRONTEND_PORT} -Action Allow"
    echo "      New-NetFirewallRule -DisplayName 'KTG-backend-${BACKEND_PORT}' -Direction Inbound -Protocol TCP -LocalPort ${BACKEND_PORT} -Action Allow"
    echo "  ▸ 若 Hyper-V 规则命令不可用，可退而放开 WSL 入站默认动作（较宽松）："
    echo "      Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow"
    echo "  ▸ WSL 内无需 ufw/firewalld（改了也不生效，入站由 Windows/Hyper-V 防火墙决定）"
}

# 放行单个 TCP 端口（ufw / firewalld / iptables），幂等，可重复执行
open_firewall_port() {
    local port="$1"
    if cmd_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        if ufw allow "${port}/tcp" >/dev/null 2>&1; then
            ok "ufw 已放行 ${port}/tcp"
        else
            warn "ufw 放行 ${port}/tcp 失败，请手动执行：ufw allow ${port}/tcp"
        fi
        return 0
    fi
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1; then
            firewall-cmd --reload >/dev/null 2>&1 || true
            ok "firewalld 已放行 ${port}/tcp（永久规则）"
        else
            warn "firewalld 放行 ${port}/tcp 失败，请手动执行："
            warn "  firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
        fi
        return 0
    fi
    if cmd_exists iptables; then
        if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            return 0
        fi
        if iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            ok "iptables 已放行 ${port}/tcp"
            # 有 netfilter-persistent 时顺手保存，重启后规则不丢
            cmd_exists netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
        else
            warn "iptables 放行 ${port}/tcp 失败，请手动放行"
        fi
        return 0
    fi
    info "未检测到 ufw/firewalld/iptables，跳过本机防火墙放行"
}

# 为整个应用放行端口：前端（1024，必须）+ 后端（8080，直连 API 时用）
open_firewall_for_app() {
    if is_wsl; then
        info "检测到 WSL 环境：WSL 内无需配置 ufw/firewalld（入站由 Windows 防火墙决定）"
        wsl_access_note
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        warn "当前非 root，跳过防火墙放行；如需自动放行请执行：sudo $GLOBAL_CMD firewall"
        return 0
    fi
    info "检查本机防火墙（放行前端 ${FRONTEND_PORT}/tcp 与后端 ${BACKEND_PORT}/tcp）..."
    open_firewall_port "$FRONTEND_PORT"
    open_firewall_port "$BACKEND_PORT"
}

# ======================= 全局命令注册 =======================
register_global_cmd() {
    local src dst="/usr/local/bin/$GLOBAL_CMD"
    # 关键：BASH_SOURCE[0] 比 $0 可靠。
    # 当以 `bash -s < 文件`、`curl | bash` 或 stdin 方式运行时，$0 会变成 "bash"，
    # 此时 readlink -f "bash" 会解析成 /root/bash 这种不存在的路径导致 cp 失败。
    src="${BASH_SOURCE[0]:-$0}"
    src="$(readlink -f "$src" 2>/dev/null || true)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        warn "无法定位脚本文件（当前 \$0=$0），跳过全局命令注册"
        return 0
    fi
    mkdir -p /usr/local/bin
    if [ "$(readlink -f "$dst" 2>/dev/null || true)" = "$src" ]; then
        return 0
    fi
    cp -f "$src" "$dst"
    chmod +x "$dst"
    ok "全局命令已注册：$GLOBAL_CMD"
}

# ======================= 1. 系统环境初始化 =======================
detect_pkg_mgr() {
    if cmd_exists apt-get; then echo apt
    elif cmd_exists dnf; then echo dnf
    elif cmd_exists yum; then echo yum
    else echo none
    fi
}

pkg_install() {
    local pm; pm="$(detect_pkg_mgr)"
    case "$pm" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        *)   err "未识别的包管理器，请手动安装：$*"; return 1 ;;
    esac
}

apt_update_once() {
    local marker="$WORK_DIR/.apt-updated"
    [ -f "$marker" ] && return 0
    mkdir -p "$WORK_DIR"
    info "更新软件源索引..."
    if DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        touch "$marker"
        return 0
    fi
    warn "apt-get update 失败（国内源未生效？），尝试切换国内源后重试"
    if [ "$USE_CN_MIRROR" = "1" ]; then
        setup_apt_mirror
        if DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
            touch "$marker"
            return 0
        fi
    fi
    warn "apt-get update 持续失败，仍继续尝试安装（可能使用本地缓存）"
    return 0
}

install_java8() {
    if cmd_exists java && java -version 2>&1 | grep -q '"1\.8\.'; then
        ok "已检测到 JDK 8：$(java -version 2>&1 | head -1)"
        return 0
    fi
    info "安装 JDK 8（项目 pom.xml 中 java.version=1.8）..."
    # 1) 优先系统源
    if [ "$(detect_pkg_mgr)" = "apt" ]; then
        apt_update_once
        pkg_install ca-certificates curl || true
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-8-jdk; then
            ok "已通过 apt 安装 openjdk-8-jdk"
            return 0
        fi
        warn "apt 源中没有 openjdk-8-jdk（Ubuntu 22.04+/24.04 已移除），改用清华 Adoptium 镜像"
    elif pkg_install java-1.8.0-openjdk-devel; then
        return 0
    fi
    # 2) 国内镜像下载 Tar 包
    if install_temurin8; then return 0; fi
    err "JDK 8 安装失败，请手动安装后重试"
    return 1
}

install_temurin8() {
    local arch url tgz tmp extract jdk
    case "$(uname -m)" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) err "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac
    tmp="$(mktemp -d)"
    tgz="$tmp/temurin8.tar.gz"

    # 清华镜像目录形如 .../Adoptium/8/jdk/x64/linux/OpenJDK8U-jdk_x64_linux_hotspot_8u<build>.tar.gz
    # 先列出目录选择合适的包；镜像不可用时再退回官方 api
    local urls=()
    if [ "$USE_CN_MIRROR" = "1" ]; then
        local pkg
        pkg="$(curl -fsSL --connect-timeout 10 --max-time 20 \
            "${TEMURIN_MIRROR}/8/jdk/${arch}/linux/" 2>/dev/null \
            | grep -oE 'OpenJDK8U-jdk_[^"<>]+\.tar\.gz' | sort -u | tail -1 || true)"
        if [ -n "$pkg" ]; then
            urls+=("${TEMURIN_MIRROR}/8/jdk/${arch}/linux/${pkg}")
        fi
        urls+=("https://mirrors.tuna.tsinghua.edu.cn/Adoptium/8/jdk/${arch}/linux/")
    fi
    urls+=("https://api.adoptium.net/v3/binary/latest/8/ga/linux/${arch}/jdk/hotspot/normal/eclipse")

    if ! download_first "$tgz" "${urls[@]}"; then
        rm -rf "$tmp"
        warn "JDK 8 下载失败（国内镜像与官方源均不可用）"
        return 1
    fi
    # 最后那个官方 URL 不带文件名，下载到的仍是 tar.gz，可直接解压
    mkdir -p /opt/java
    if ! tar -xzf "$tgz" -C /opt/java 2>/dev/null; then
        rm -rf "$tmp"
        warn "JDK 压缩包解析失败"
        return 1
    fi
    rm -rf "$tmp"
    jdk="$(find /opt/java -maxdepth 1 -type d \( -name 'jdk8*' -o -name 'jdk-8*' \) | head -1)"
    if [ -z "$jdk" ]; then
        jdk="$(find /opt/java -maxdepth 1 -mindepth 1 -type d | head -1)"
    fi
    [ -n "$jdk" ] || return 1
    ln -sfn "$jdk" /opt/java/openjdk8
    cat > /etc/profile.d/ktg-java.sh <<'EOF'
export JAVA_HOME=/opt/java/openjdk8
export PATH="$JAVA_HOME/bin:$PATH"
EOF
    chmod +x /etc/profile.d/ktg-java.sh
    export JAVA_HOME=/opt/java/openjdk8
    export PATH="$JAVA_HOME/bin:$PATH"
    hash -r
    if cmd_exists java; then
        ok "JDK 8 就绪：$(java -version 2>&1 | head -1)"
        return 0
    fi
    return 1
}

install_maven() {
    cmd_exists mvn && { ok "已检测到 Maven：$(mvn -v 2>/dev/null | head -1)"; return 0; }
    info "安装 Maven..."
    apt_update_once
    if pkg_install maven; then return 0; fi
    return 1
}

install_node() {
    if cmd_exists node; then
        local major
        major="$(node -v | sed 's/^v//' | cut -d. -f1)"
        if [ "${major:-0}" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null; then
            ok "Node.js $(node -v) 满足要求（>= v${NODE_MIN_MAJOR}）"
            return 0
        fi
        warn "当前 Node.js $(node -v) 过低（vue-cli 4 需要 >= v${NODE_MIN_MAJOR}），将安装 node v${NODE_TARGET_VERSION}"
    fi
    info "下载 Node.js v${NODE_TARGET_VERSION}（优先国内镜像）..."
    local arch tgz tmp
    case "$(uname -m)" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) err "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac
    tmp="$(mktemp -d)"
    tgz="$tmp/node.tar.xz"

    local file="v${NODE_TARGET_VERSION}/node-v${NODE_TARGET_VERSION}-linux-${arch}.tar.xz"
    local urls=()
    local base
    for base in "${NODE_MIRRORS[@]}"; do
        urls+=("${base}/${file}")
    done
    if download_first "$tgz" "${urls[@]}"; then
        if tar -xJf "$tgz" -C /usr/local --strip-components=1; then
            rm -rf "$tmp"
            hash -r
            ok "Node.js $(node -v) / npm $(npm -v) 安装完成"
            return 0
        fi
        warn "Node.js 解压失败，回退系统包管理器"
    fi
    rm -rf "$tmp"
    warn "Node.js 二进制安装失败，回退到系统包管理器（版本可能偏低，前端可能编译失败）"
    apt_update_once
    pkg_install nodejs npm || true
    cmd_exists node && ok "Node.js $(node -v)" || { err "Node.js 安装失败"; return 1; }
}

write_maven_settings() {
    if [ "$USE_CN_MIRROR" != "1" ]; then
        info "已关闭国内源优化，保留 Maven 默认配置"
        return 0
    fi
    if [ -f "$MAVEN_SETTINGS" ]; then
        ok "已存在 Maven 配置，未覆盖：$MAVEN_SETTINGS"
        return 0
    fi
    mkdir -p "$(dirname "$MAVEN_SETTINGS")" "$MAVEN_REPO_LOCAL"
    cat > "$MAVEN_SETTINGS" <<EOF
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <localRepository>${MAVEN_REPO_LOCAL}</localRepository>
  <mirrors>
    <!-- mirrorOf 用 * 覆盖 central 及 pom 中声明的其他仓库，
         避免部分依赖绕回 repo.maven.apache.org 造成长时间卡住 -->
    <mirror>
      <id>aliyun-public</id>
      <name>aliyun public</name>
      <mirrorOf>*</mirrorOf>
      <url>${MAVEN_MIRROR}</url>
    </mirror>
  </mirrors>
</settings>
EOF
    ok "Maven 源：$MAVEN_MIRROR（本地仓库 $MAVEN_REPO_LOCAL）"
}

env_init() {
    step "初始化系统环境"
    require_root "$@"
    mkdir -p "$WORK_DIR" "$LOG_DIR"
    register_global_cmd
    install_shortcuts

    # 先切国内源，再装包，避免“装不动”的第一步就卡死
    case "$(detect_pkg_mgr)" in
        apt) setup_apt_mirror; apt_update_once ;;
        yum|dnf) setup_yum_mirror ;;
    esac

    # 基础工具（v4.8 在 docker 缺失时不会安装任何东西，直接崩）
    if ! cmd_exists curl || ! cmd_exists git || ! cmd_exists unzip || ! cmd_exists wget; then
        info "安装基础工具（curl wget git unzip psmisc）..."
        # psmisc 提供 fuser，用于按端口结束进程（stop 逻辑依赖它）
        pkg_install curl wget git unzip ca-certificates psmisc || warn "部分基础工具安装失败，请检查网络"
    fi

    install_docker
    install_java8
    install_maven
    install_node
    write_maven_settings
    setup_npm_mirror
    setup_pip_mirror

    # 前端源码编译需要本机编译工具链（某些依赖会尝试本地构建）
    if ! cmd_exists make || ! cmd_exists g++; then
        info "安装编译工具链（make g++ python3）..."
        pkg_install make g++ python3 || warn "编译工具链安装失败，前端依赖可能安装失败"
    fi

    ok "系统环境初始化完成"
}

install_docker() {
    if cmd_exists docker; then
        return 0
    fi
    info "未检测到 Docker，尝试自动安装..."
    if [ "$(detect_pkg_mgr)" = "apt" ]; then
        apt_update_once
        if ! pkg_install docker.io; then
            err "Docker 安装失败。请手动安装后重试："
            err "  curl -fsSL https://get.docker.com | sh   或   apt-get install -y docker.io"
            return 1
        fi
    elif ! pkg_install docker; then
        err "Docker 安装失败，请手动安装"
        return 1
    fi
    if has_systemd; then
        systemctl enable --now docker >/dev/null 2>&1 || warn "systemctl 启动 docker 失败"
    fi
    ok "Docker 安装完成：$(docker --version 2>/dev/null || echo 未就绪)"
}

# ======================= 2. Docker 环境配置 =======================
ensure_docker_running() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi
    if ! cmd_exists docker; then
        install_docker || {
            err "Docker 不可用，无法继续。请先手动安装 Docker 后重试。"
            return 1
        }
    fi
    warn "Docker 守护进程未运行，尝试启动..."
    if has_systemd; then
        systemctl start docker >/dev/null 2>&1 || true
    elif cmd_exists service; then
        service docker start >/dev/null 2>&1 || true
    fi
    local i
    for i in $(seq 1 15); do
        docker info >/dev/null 2>&1 && { ok "Docker 守护进程已启动"; return 0; }
        sleep 1
    done
    err "Docker 守护进程启动失败，请手动检查：systemctl status docker"
    return 1
}

docker_env_init() {
    ensure_docker_running
    # 国内加速源探测与写入（含公益源回退开关）
    setup_docker_mirror
}

# ======================= 3. 源码下载 =======================
# Gitee 克隆失败时的备选：GitHub 加速前缀
gh_proxied() {
    printf '%s/%s\n' "${GH_PROXY%/}" "$1"
}

clone_repo() {
    local url="$1" dest="$2" name="$3" tmp cand
    if [ -d "$dest/.git" ] || [ -f "$dest/pom.xml" ] || [ -f "$dest/package.json" ]; then
        ok "$name 源码已存在，跳过下载"
        return 0
    fi
    rm -rf "$dest"
    tmp="$(mktemp -d)"

    # 依次尝试：原地址 → Gitee 加速前缀（如配置）→ GitHub 加速前缀
    local candidates=("$url")
    if [ -n "$GH_PROXY" ] && printf '%s' "$url" | grep -q 'github.com'; then
        candidates+=("$(gh_proxied "$url")")
    fi

    if cmd_exists git; then
        for cand in "${candidates[@]}"; do
            info "git clone（浅克隆）$cand"
            if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
                clone --depth 1 "$cand" "$tmp/src" >>"$LOG_DIR/git.log" 2>&1; then
                mv "$tmp/src" "$dest"
                rm -rf "$tmp"
                ok "$name 源码下载完成（git）"
                return 0
            fi
            rm -rf "$tmp/src"
            warn "该地址克隆失败，尝试下一个"
        done
    fi

    # 回退：Gitee 归档 zip（走 curl，可重试）
    local zip="$tmp/src.zip"
    for cand in "${candidates[@]}"; do
        local zurl="${cand%.git}/repository/archive/master.zip"
        if curl "${CURL_OPTS[@]}" -o "$zip" "$zurl"; then
            if unzip -q "$zip" -d "$tmp/x" >>"$LOG_DIR/git.log" 2>&1; then
                local first
                first="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
                if [ -n "$first" ]; then
                    mv "$first" "$dest"
                    rm -rf "$tmp"
                    ok "$name 源码下载完成（zip）"
                    return 0
                fi
            fi
            warn "zip 包解析失败，尝试下一个地址"
        fi
        rm -rf "$tmp/x" "$zip"
    done

    rm -rf "$tmp"
    err "$name 源码下载失败：$url"
    err "国内网络建议："
    err "  1) 确认能访问 gitee.com；企业内网可用 KTG_BACKEND_REPO / KTG_FRONTEND_REPO 指向内网 Git"
    err "  2) 若用 GitHub，可设置加速前缀：sudo KTG_GH_PROXY=https://ghfast.top $0 install"
    err "  3) 也可先手动放置源码到 $dest 再重跑本脚本"
    return 1
}

pull_source() {
    step "检查项目源码"
    clone_repo "$BACKEND_REPO" "$BACKEND_DIR" "后端 ktg-mes"
    clone_repo "$FRONTEND_REPO" "$FRONTEND_DIR" "前端 ktg-mes-ui"
}

# ======================= 4. 数据库容器 =======================
container_running() {
    [ -n "$(docker ps -q -f "name=^/${1}$" 2>/dev/null || true)" ]
}

container_exists() {
    [ -n "$(docker ps -aq -f "name=^/${1}$" 2>/dev/null || true)" ]
}

ensure_running() {
    local name="$1"
    if container_running "$name"; then return 0; fi
    if container_exists "$name"; then
        info "容器 $name 已存在但未运行，启动中..."
        docker start "$name" >/dev/null
    fi
}

mysql_exec() {
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$@" 2>/dev/null
}

mysql_ready() {
    docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PWD" --silent >/dev/null 2>&1
}

redis_ready() {
    [ "$(docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" --no-auth-warning ping 2>/dev/null | tr -d '\r')" = "PONG" ]
}

start_db_containers() {
    step "启动数据库容器"
    ensure_docker_running

    # ---------- MySQL ----------
    if ! container_exists "$MYSQL_CONTAINER"; then
        # 显式拉取：失败会给出国内加速源的可行修复建议，而不是让 docker run 报晦涩错误
        pull_image "$MYSQL_IMAGE"
        info "创建 MySQL 容器（$MYSQL_IMAGE，端口 $MYSQL_PORT）..."
        docker run -d --name "$MYSQL_CONTAINER" \
            --restart always \
            -p "$MYSQL_PORT:3306" \
            -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" \
            -e MYSQL_DATABASE="$MYSQL_DB" \
            "$MYSQL_IMAGE" \
            --character-set-server=utf8mb4 \
            --collation-server=utf8mb4_general_ci \
            --explicit_defaults_for_timestamp=true \
            --lower_case_table_names=1 >/dev/null
    else
        ensure_running "$MYSQL_CONTAINER"
    fi

    info "等待 MySQL 就绪（首次初始化可能需要 30~120 秒）..."
    local i
    for i in $(seq 1 120); do
        mysql_ready && break
        sleep 2
    done
    if ! mysql_ready; then
        err "MySQL 启动超时，查看日志：docker logs $MYSQL_CONTAINER"
        return 1
    fi
    if ! mysql_exec -e "USE \`$MYSQL_DB\`;" >/dev/null; then
        warn "数据库 $MYSQL_DB 不存在，手动创建"
        mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    fi
    ok "MySQL 就绪：127.0.0.1:$MYSQL_PORT / 库 $MYSQL_DB"

    # ---------- Redis ----------
    if ! container_exists "$REDIS_CONTAINER"; then
        pull_image "$REDIS_IMAGE"
        info "创建 Redis 容器（$REDIS_IMAGE，端口 $REDIS_PORT）..."
        docker run -d --name "$REDIS_CONTAINER" \
            --restart always \
            -p "$REDIS_PORT:6379" \
            "$REDIS_IMAGE" \
            redis-server --requirepass "$REDIS_PWD" \
            --appendonly yes >/dev/null
    else
        ensure_running "$REDIS_CONTAINER"
    fi

    info "等待 Redis 就绪..."
    for i in $(seq 1 30); do
        redis_ready && break
        sleep 1
    done
    if ! redis_ready; then
        err "Redis 连通性校验失败（密码 $REDIS_PWD 可能不一致）"
        err "修复建议：docker rm -f $REDIS_CONTAINER 后重跑本步骤，或核对 KTG_REDIS_PWD"
        return 1
    fi
    ok "Redis 就绪：127.0.0.1:$REDIS_PORT（密码已校验）"
}

# ======================= 5. 数据库初始化（v4.8 完全缺失） =======================
# MES 业务表是否存在（哨兵）。仅看“表数量>0”会误判：只导了若依基础表（sys_*）时
# 表数也为正，于是业务表/打印表永远缺失，运行时报 Table 'j2eedb.print_client' doesn't exist。
db_has_app_tables() {
    local n
    n="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DB' AND table_name IN ('print_client','md_item','pro_card');" 2>/dev/null | tr -dc '0-9' || true)"
    [ "${n:-0}" -gt 0 ]
}

db_table_exists() {
    local t="$1" n
    n="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DB' AND table_name='$t';" 2>/dev/null | tr -dc '0-9' || true)"
    [ "${n:-0}" -gt 0 ]
}

db_column_exists() {
    local t="$1" c="$2" n
    n="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$MYSQL_DB' AND table_name='$t' AND column_name='$c';" 2>/dev/null | tr -dc '0-9' || true)"
    [ "${n:-0}" -gt 0 ]
}

# 代码(master)比仓库最新数据库导出(2025-05-18)新，导出缺少其后新增的字段。
# 这里做幂等补列：缺哪个补哪个；以后遇到新的表结构漂移，在下面追加一行即可。
# 格式：表名 列名 列定义
schema_patch_columns() {
    cat <<'PATCH'
pro_feedback quantity_labor_scrap    double(14,2) DEFAULT NULL COMMENT '工废数量'
pro_feedback quantity_material_scrap double(14,2) DEFAULT NULL COMMENT '料废数量'
pro_feedback quantity_other_scrap    double(14,2) DEFAULT NULL COMMENT '其他废品数量'
qc_ipqc      quantity_labor_scrap    double(12,4) DEFAULT NULL COMMENT '工废数量'
qc_ipqc      quantity_material_scrap double(12,4) DEFAULT NULL COMMENT '料废数量'
qc_ipqc      quantity_other_scrap    double(12,4) DEFAULT NULL COMMENT '其他废品数量'
PATCH
}

apply_schema_patches() {
    local t c ddl applied=0
    while read -r t c ddl; do
        [ -n "$t" ] || continue
        db_table_exists "$t" || continue
        db_column_exists "$t" "$c" && continue
        info "补列：${t}.${c}"
        if mysql_exec -e "ALTER TABLE \`$t\` ADD COLUMN \`$c\` $ddl;"; then
            applied=$((applied + 1))
        else
            warn "补列失败：${t}.${c}（请手动 ALTER TABLE）"
        fi
    done <<EOF
$(schema_patch_columns)
EOF
    if [ "$applied" -gt 0 ]; then
        ok "已补齐 ${applied} 个缺失字段（代码新于数据库导出的部分）"
    fi
}

# 在源码里查找作者随仓库提供的完整数据库导出（doc/实施文档/ktgmes_*.sql.gz|zip）
find_full_dump() {
    local dir="$BACKEND_DIR/doc/实施文档" f
    [ -d "$dir" ] || dir="$BACKEND_DIR/doc"
    [ -d "$dir" ] || return 1
    # 文件名带时间戳，字典序即时间序，取最新一份
    f="$(ls -1 "$dir"/ktgmes_*.sql.gz "$dir"/ktgmes_*.zip 2>/dev/null | sort | tail -1 || true)"
    [ -n "$f" ] && [ -f "$f" ] || return 1
    printf '%s\n' "$f"
}

# 把完整导出流式导入业务库（.gz 直接管道；.zip 取出内部 .sql）
import_full_dump() {
    local f="$1"
    case "$f" in
        *.gz)
            zcat "$f" | docker exec -i "$MYSQL_CONTAINER" \
                mysql -uroot -p"$MYSQL_ROOT_PWD" --default-character-set=utf8mb4 "$MYSQL_DB" ;;
        *.zip)
            if ! cmd_exists unzip; then
                err "导入 .zip 导出需要 unzip，请先安装：apt-get install -y unzip"
                return 1
            fi
            unzip -p "$f" '*.sql' | docker exec -i "$MYSQL_CONTAINER" \
                mysql -uroot -p"$MYSQL_ROOT_PWD" --default-character-set=utf8mb4 "$MYSQL_DB" ;;
        *)
            docker exec -i "$MYSQL_CONTAINER" \
                mysql -uroot -p"$MYSQL_ROOT_PWD" --default-character-set=utf8mb4 "$MYSQL_DB" < "$f" ;;
    esac
}

init_database() {
    step "初始化数据库结构"
    ensure_docker_running
    local sql_dir="$BACKEND_DIR/sql"

    if db_has_app_tables; then
        ok "数据库 $MYSQL_DB 已包含 KTG-MES 业务表，跳过导入（如需重建请先执行 clean）"
        apply_schema_patches
        return 0
    fi

    local dump=""
    if dump="$(find_full_dump)"; then
        local existing
        existing="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DB';" 2>/dev/null | tr -dc '0-9' || echo 0)"
        if [ "${existing:-0}" -gt 0 ]; then
            warn "数据库已有 ${existing} 张表但缺少 MES 业务表，导入完整导出会 DROP 重建这些表（新部署无妨）"
        fi
        info "导入完整数据库导出：$(basename "$dump")（$(du -h "$dump" | cut -f1)），需要一点时间..."
        if ! import_full_dump "$dump"; then
            err "完整导出导入失败：$dump"
            err "可手动重试：unzip -p '$dump' '*.sql' | docker exec -i $MYSQL_CONTAINER mysql -uroot -p<密码> $MYSQL_DB"
            return 1
        fi
        if ! db_has_app_tables; then
            err "导入结束但未检测到业务表，请检查导出文件：$dump"
            return 1
        fi
        ok "数据库初始化完成（含 print_* 等 MES 业务表）"
    else
        # 兜底：仓库 sql/ 仅若依基础表，业务表会缺失（仅当找不到完整导出时走到这里）
        warn "未找到完整导出（doc/实施文档/ktgmes_*.sql.gz|zip），回退到若依基础表"
        warn "注意：此时没有 MES 业务表/打印表，运行时会报 Table 'xxx.print_client' doesn't exist"
        if [ ! -d "$sql_dir" ]; then
            warn "未找到 $sql_dir，跳过（请确认源码完整）"
            return 0
        fi
        local f count=0
        # ry_20210908.sql 为若依基础表结构，必须在业务表之前导入
        for f in "$sql_dir/ry_20210908.sql" "$sql_dir/quartz.sql"; do
            if [ ! -f "$f" ]; then
                warn "缺少初始化脚本：$f"
                continue
            fi
            info "导入 $(basename "$f")（$(du -h "$f" | cut -f1)）..."
            docker exec -i "$MYSQL_CONTAINER" \
                mysql -uroot -p"$MYSQL_ROOT_PWD" --default-character-set=utf8mb4 "$MYSQL_DB" < "$f"
            count=$((count + 1))
        done
        if [ "$count" -eq 0 ]; then
            err "没有任何 SQL 被导入，数据库为空，登录必然失败"
            return 1
        fi
        ok "若依基础表导入完成（业务表仍缺失，请提供完整导出）"
    fi

    # 代码比导出新，补上导出之后新增的字段（幂等）
    apply_schema_patches

    local users
    users="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM $MYSQL_DB.sys_user;" 2>/dev/null | tr -dc '0-9' || echo 0)"
    if [ "${users:-0}" -gt 0 ]; then
        ok "sys_user 共 ${users} 条（默认账号 admin / admin123）"
    else
        warn "sys_user 表为空或不存在，登录可能失败"
    fi
}

# ======================= 6. 配置文件精确修正 =======================
patch_config() {
    step "修正项目配置"
    local f="$BACKEND_DIR/ktg-admin/src/main/resources/application-druid.yml"
    if [ ! -f "$f" ]; then
        err "未找到数据源配置：$f（源码不完整？）"
        return 1
    fi

    if ! cmd_exists python3; then
        err "缺少 python3，无法安全地精确修改 YAML（v4.8 的 sed 全量替换会改坏 druid 控制台密码）"
        err "请先安装：apt-get install -y python3"
        return 1
    fi

    # 注意：这里必须精确到 master 数据源层级。
    # v4.8 的  sed "s#password:.*#...#"  会连带把 statViewServlet 的 login-password 一起改掉。
    python3 - "$f" "$MYSQL_DB" "$MYSQL_PORT" "$MYSQL_ROOT_PWD" <<'PY'
import re, sys

path, db, port, mysql_pwd = sys.argv[1:5]
with open(path, encoding='utf-8') as fh:
    text = fh.read()

changed = []

# 第一步：整篇重写 JDBC URL。
# 必须一次性替换，不能放在下面的逐行遍历里——遍历 master 段的内部循环会把
# url/username/password 三行“吞掉”，导致 URL 分支永远看不到 url 那一行。
URL_RE = re.compile(r'jdbc:mysql://[^/\s]+/([A-Za-z0-9_\-]+)')
text, n_url = URL_RE.subn('jdbc:mysql://127.0.0.1:%s/%s' % (port, db), text)
if n_url:
    changed.append('url')

lines = text.splitlines()
out = []
i, n = 0, len(lines)

def indent(s):
    return len(s) - len(s.lstrip(' '))

while i < n:
    line = lines[i]
    # 第二步：只改 druid.master 段内部的 username / password。
    # slave 段的 username/password 是空值，login-password 不在该段内，都不会被误伤。
    if re.match(r'^\s*master:\s*$', line):
        base = indent(line)
        out.append(line)
        i += 1
        while i < n:
            cur = lines[i]
            if cur.strip() and indent(cur) <= base:
                break
            if re.match(r'^\s*username:\s', cur):
                cur = '%susername: root' % (' ' * indent(cur))
                changed.append('username')
            elif re.match(r'^\s*password:\s', cur):
                cur = '%spassword: %s' % (' ' * indent(cur), mysql_pwd)
                changed.append('password')
            out.append(cur)
            i += 1
        continue
    # 兜底：万一 master 段结构变了，直接替换占位符
    if re.match(r'^\s*username:\s*your_username\s*$', line):
        line = ' ' * indent(line) + 'username: root'
        changed.append('username(fallback)')
    if re.match(r'^\s*password:\s*your_password\s*$', line):
        line = ' ' * indent(line) + 'password: %s' % mysql_pwd
        changed.append('password(fallback)')
    out.append(line)
    i += 1

with open(path, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(out) + '\n')

print('已修改项：%s' % (', '.join(sorted(set(changed))) or '无'))
PY

    if ! grep -q "password: ${MYSQL_ROOT_PWD}" "$f"; then
        err "数据源密码写入校验失败，请检查 $f"
        return 1
    fi
    if ! grep -q "jdbc:mysql://127.0.0.1:${MYSQL_PORT}/${MYSQL_DB}" "$f"; then
        err "数据源 URL 写入校验失败，请检查 $f"
        return 1
    fi
    if grep -q 'your_username\|your_password' "$f"; then
        err "仍有占位符未替换，请检查 $f"
        return 1
    fi
    ok "master 数据源已指向 127.0.0.1:$MYSQL_PORT/$MYSQL_DB（账号 root）"

    # ---------- Redis 配置 ----------
    # application.yml 中 spring.redis.host=localhost / port=6379 / password=123456
    # 这里显式修正 host 与 port，密码由启动参数兜底传入（cmdline 优先级最高）
    local yml="$BACKEND_DIR/ktg-admin/src/main/resources/application.yml"
    if [ -f "$yml" ]; then
        sed -i -E "s#^([[:space:]]*)host:[[:space:]]*localhost[[:space:]]*\$#\1host: 127.0.0.1#" "$yml"
        sed -i -E "s#^([[:space:]]*)port:[[:space:]]*6379[[:space:]]*\$#\1port: ${REDIS_PORT}#" "$yml"
        sed -i -E "s#^([[:space:]]*)password:[[:space:]]*123456[[:space:]]*\$#\1password: ${REDIS_PWD}#" "$yml"
        ok "Redis 配置已修正为 127.0.0.1:${REDIS_PORT}"
    else
        warn "未找到 application.yml，Redis 配置将在启动参数中兜底"
    fi
}

# ======================= 7. 本地编译 =======================
build_backend() {
    step "编译后端"
    cd "$BACKEND_DIR"
    [ -f pom.xml ] || { err "$BACKEND_DIR 下没有 pom.xml"; return 1; }

    local settings_opt=()
    [ -f "$MAVEN_SETTINGS" ] && settings_opt=(-s "$MAVEN_SETTINGS")

    export MAVEN_OPTS="${MAVEN_OPTS:--Xms512m -Xmx2g -Dfile.encoding=UTF-8}"
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:--Dfile.encoding=UTF-8}"

    # 注意：不要用 -q，否则编译失败时用户看不到任何原因
    set +e
    mvn clean package -DskipTests -B "${settings_opt[@]}" 2>&1 | tee "$LOG_DIR/maven-build.log"
    local rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        err "后端编译失败（退出码 $rc），完整日志：$LOG_DIR/maven-build.log"
        tail -30 "$LOG_DIR/maven-build.log" >&2
        return 1
    fi

    local jar_file
    jar_file="$(find ktg-admin/target -maxdepth 1 -name '*.jar' \
        ! -name '*sources*' ! -name '*javadoc*' ! -name '*.original' | head -1)"
    if [ -z "$jar_file" ] || [ ! -f "$jar_file" ]; then
        err "编译成功但未找到可执行 jar（ktg-admin/target）"
        return 1
    fi
    printf '%s\n' "$(readlink -f "$jar_file")" > "$WORK_DIR/backend-jar.path"
    ok "后端编译完成：$jar_file"
}

backend_jar() {
    if [ -f "$WORK_DIR/backend-jar.path" ]; then
        local p
        p="$(cat "$WORK_DIR/backend-jar.path")"
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    fi
    local jar
    jar="$(find "$BACKEND_DIR/ktg-admin/target" -maxdepth 1 -name '*.jar' \
        ! -name '*sources*' ! -name '*javadoc*' ! -name '*.original' 2>/dev/null | head -1)"
    [ -n "$jar" ] || return 1
    printf '%s\n' "$(readlink -f "$jar")"
}

build_frontend() {
    step "编译前端"
    cd "$FRONTEND_DIR"
    [ -f package.json ] || { err "$FRONTEND_DIR 下没有 package.json"; return 1; }

    export PATH="/usr/local/bin:$PATH"
    hash -r

    # v4.8 用的是 npm run build，但 package.json 里只有 build:prod / build:stage
    local build_script="build:prod"
    if ! grep -q '"build:prod"' package.json; then
        if grep -q '"build:stage"' package.json; then
            build_script="build:stage"
        elif grep -q '"build"' package.json; then
            build_script="build"
        else
            err "package.json 中找不到可用的 build 脚本"
            return 1
        fi
    fi

    export npm_config_registry="$NPM_MIRROR"
    # 关掉可能被墙的二进制下载（node-sass/cypress/puppeteer 等）
    export PUPPETEER_SKIP_DOWNLOAD=1
    export CYPRESS_INSTALL_BINARY=0
    export SASS_BINARY_SITE="https://npmmirror.com/mirrors/node-sass"
    export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
    export PHANTOMJS_CDNURL="https://npmmirror.com/mirrors/phantomjs"
    export npm_config_disturl="https://npmmirror.com/mirrors/node"

    if [ ! -d node_modules ] || [ ! -f node_modules/.ktg-installed ] \
        || [ package.json -nt node_modules/.ktg-installed ] \
        || { [ -f package-lock.json ] && [ package-lock.json -nt node_modules/.ktg-installed ]; }; then
        info "安装前端依赖（npm install --registry=$NPM_MIRROR）..."
        rm -rf node_modules
        if ! npm install --legacy-peer-deps --no-audit --no-fund \
                --registry="$NPM_MIRROR" > "$LOG_DIR/npm-install.log" 2>&1; then
            warn "首次安装失败，清理缓存后重试一次（国内源偶发超时）"
            npm cache clean --force >/dev/null 2>&1 || true
            if ! npm install --legacy-peer-deps --no-audit --no-fund \
                    --registry="$NPM_MIRROR" >> "$LOG_DIR/npm-install.log" 2>&1; then
                err "前端依赖安装失败，日志末尾："
                tail -40 "$LOG_DIR/npm-install.log" >&2
                err "可尝试：npm config set registry $NPM_MIRROR && npm install --legacy-peer-deps"
                return 1
            fi
        fi
        touch node_modules/.ktg-installed
        ok "前端依赖安装完成"
    else
        ok "前端依赖已存在且是最新的，跳过安装"
    fi

    # 关键兼容性修复（原 v4.8 有，v5 曾误删导致编译失败）：
    # vue-cli 4.4 内置 webpack4，而 package.json 声明的 less@^4 / less-loader@^11 要求 webpack5；
    # less@4 的 dist/less.js 里用了 `??` 等现代语法，webpack4 的解析器直接报
    # "Module parse failed: Unexpected token"。必须锁定 webpack4 兼容版本。
    if [ -d node_modules ]; then
        if ! npm install --legacy-peer-deps --no-audit --no-fund --registry="$NPM_MIRROR" \
                less@3.13.1 less-loader@6.2.0 >> "$LOG_DIR/npm-install.log" 2>&1; then
            err "less/less-loader 回退到 webpack4 兼容版本失败，日志末尾："
            tail -40 "$LOG_DIR/npm-install.log" >&2
            return 1
        fi
        ok "less/less-loader 已锁定为 webpack4 兼容版本（less@3.13.1 + less-loader@6.2.0）"
    fi

    rm -rf dist
    info "执行 npm run $build_script ..."
    # vue-cli 4 内置 webpack 4，在 Node 17+ 上需要 legacy OpenSSL
    local node_major node_opts
    node_major="$(node -v | sed 's/^v//' | cut -d. -f1)"
    node_opts="${NODE_OPTIONS:---max-old-space-size=4096}"
    if [ "${node_major:-0}" -ge 17 ] 2>/dev/null; then
        node_opts="$node_opts --openssl-legacy-provider"
    fi
    # 用 if ! 而不是 set +e/set -e：避免与 ERR 陷阱(set -E)交互导致误报中断
    if ! NODE_OPTIONS="$node_opts" npm run "$build_script" > "$LOG_DIR/npm-build.log" 2>&1; then
        err "前端编译失败，日志末尾："
        tail -40 "$LOG_DIR/npm-build.log" >&2
        err "请将上面的日志发给我进一步排查"
        return 1
    fi
    if [ ! -d dist ]; then
        err "编译结束但未生成 dist 目录，请查看：$LOG_DIR/npm-build.log"
        return 1
    fi
    ok "前端编译完成：$FRONTEND_DIR/dist（可交给 nginx 静态托管）"
}

build_local() {
    build_backend
    build_frontend
}

# ======================= 8. 启动/停止服务 =======================
# 按端口结束进程（fuser 优先，lsof 兜底）。
# 关键：绝不使用 pkill -f 按进程名匹配——curl|bash 执行时脚本全文会进入父 bash 的
# 命令行参数，pkill -f 'ktg-admin.*\.jar' 会匹配到父 bash/sudo 进程，导致
# 进程被 SIGTERM 杀死、终端显示 "Terminated" 的自杀事故。
kill_port() {
    local port="$1" pid
    if cmd_exists fuser; then
        fuser -k "${port}/tcp" 2>/dev/null || true
        return 0
    fi
    if cmd_exists lsof; then
        pid="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            kill $pid 2>/dev/null || true
        fi
    fi
}

stop_backend() {
    local pid
    if [ -f "$BACKEND_PID_FILE" ]; then
        pid="$(cat "$BACKEND_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
    kill_port "$BACKEND_PORT"
    rm -f "$BACKEND_PID_FILE"
}

stop_frontend() {
    local pid
    if [ -f "$FRONTEND_PID_FILE" ]; then
        pid="$(cat "$FRONTEND_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
    # npm run dev 的真正服务进程是子进程 node(vue-cli-service)，按端口兜底结束
    kill_port "$FRONTEND_PORT"
    rm -f "$FRONTEND_PID_FILE"
}

stop_local_services() {
    stop_backend
    stop_frontend
    info "已停止后端/前端进程"
    return 0
}

start_backend() {
    local jar
    if ! jar="$(backend_jar)"; then
        err "未找到后端 jar，请先执行：$0 build"
        return 1
    fi

    info "停止旧的后端进程..."
    stop_backend
    # wait_port_free 失败时返回非 0；用 `if !` 正好利用了“条件上下文豁免 errexit”，
    # 不会因“端口仍被占用”而中断脚本。
    if ! wait_port_free "$BACKEND_PORT"; then
        warn "端口 $BACKEND_PORT 仍被占用，强制结束占用进程"
        kill_port "$BACKEND_PORT"
        sleep 2
    fi

    mkdir -p "$LOG_DIR"
    info "启动后端：$jar"
    nohup java -Dfile.encoding=UTF-8 -Duser.timezone=Asia/Shanghai \
        -Xms512m -Xmx2g \
        -jar "$jar" \
        --server.port="$BACKEND_PORT" \
        --server.address=0.0.0.0 \
        --spring.redis.host=127.0.0.1 \
        --spring.redis.port="$REDIS_PORT" \
        --spring.redis.password="$REDIS_PWD" \
        > "$BACKEND_LOG" 2>&1 &
    echo $! > "$BACKEND_PID_FILE"

    info "等待后端就绪（最多 120 秒）..."
    local i
    for i in $(seq 1 120); do
        if ! kill -0 "$(cat "$BACKEND_PID_FILE")" 2>/dev/null; then
            err "后端进程已退出，日志末尾："
            tail -40 "$BACKEND_LOG" >&2
            return 1
        fi
        if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${BACKEND_PORT}/" 2>/dev/null; then
            ok "后端服务已就绪：http://127.0.0.1:${BACKEND_PORT}"
            return 0
        fi
        if ! port_free "$BACKEND_PORT" && grep -qE 'Started .*Application|Tomcat started on port' "$BACKEND_LOG" 2>/dev/null; then
            ok "后端已监听 ${BACKEND_PORT}（HTTP 探测未通过但端口正常）"
            return 0
        fi
        sleep 1
    done
    err "后端启动超时，日志末尾："
    tail -40 "$BACKEND_LOG" >&2
    return 1
}

start_frontend() {
    cd "$FRONTEND_DIR"
    [ -d node_modules ] || { err "前端依赖未安装，请先执行：$0 build"; return 1; }

    info "停止旧的前端进程..."
    stop_frontend
    if ! wait_port_free "$FRONTEND_PORT"; then
        warn "端口 $FRONTEND_PORT 被占用（后端默认 8080，前端 vue.config.js 默认 80，注意区分）"
        kill_port "$FRONTEND_PORT"
        sleep 2
    fi

    # vue-cli 4 内置 webpack4，在 Node 17+ 上 serve 同样需要 legacy OpenSSL，
    # 否则 dev server 直接崩溃、端口永远不监听（这是“前端起不来”的第二大原因）
    local node_major node_opts
    node_major="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || true)"
    node_opts="${NODE_OPTIONS:---max-old-space-size=4096}"
    if [ "${node_major:-0}" -ge 17 ] 2>/dev/null; then
        node_opts="$node_opts --openssl-legacy-provider"
        info "检测到 Node $(node -v)，已附加 --openssl-legacy-provider（webpack4 兼容）"
    fi

    # vue.config.js: port = process.env.port || process.env.npm_config_port || 80
    # v4.8 不传端口，dev server 会抢 80 端口。
    # --host 必须显式传 0.0.0.0：否则可能只绑 127.0.0.1，局域网/公网一律打不开。
    local pid
    info "启动前端开发服务（端口 $FRONTEND_PORT，监听 $FRONTEND_HOST）..."
    nohup env NODE_OPTIONS="$node_opts" \
        npm run dev -- --port "$FRONTEND_PORT" --host "$FRONTEND_HOST" \
        > "$FRONTEND_LOG" 2>&1 &
    pid=$!
    echo "$pid" > "$FRONTEND_PID_FILE"

    info "等待前端编译完成并监听端口（最多 180 秒，首次编译较慢）..."
    if wait_for_port "$FRONTEND_PORT" 180; then
        case "$(port_scope "$FRONTEND_PORT")" in
            local)
                warn "前端只监听 127.0.0.1，局域网/公网无法访问！请检查 vue.config.js 的 host 配置"
                warn "临时规避：sudo KTG_FRONTEND_HOST=0.0.0.0 $GLOBAL_CMD restart"
                ;;
            all) ok "前端已监听所有网卡（$FRONTEND_HOST）" ;;
            *)   : ;;
        esac
        ok "前端服务已启动：http://$(detect_lan_ip):${FRONTEND_PORT}（本机 http://127.0.0.1:${FRONTEND_PORT}）"
        return 0
    fi

    # 超时：区分“进程还在（多半仍在编译）”与“进程已退出（真失败）”
    if kill -0 "$pid" 2>/dev/null; then
        warn "前端进程仍在运行但 $FRONTEND_PORT 尚未监听：多半还在编译，稍等 1~2 分钟后访问"
        warn "  访问地址：http://$(detect_lan_ip):${FRONTEND_PORT}"
        warn "  实时日志：tail -n 100 -f $FRONTEND_LOG"
    else
        err "前端进程已退出，启动失败，日志末尾："
        tail -40 "$FRONTEND_LOG" >&2
    fi
    return 1
}

start_local_services() {
    step "启动本地服务"
    ensure_docker_running
    # 访问层：本机防火墙放行（云服务器安全组仍需在控制台手动放行）
    open_firewall_for_app
    start_backend
    if ! start_frontend; then
        warn "前端未在预期时间内就绪（后端与数据库不受影响）"
        warn "排查后重试：sudo $GLOBAL_CMD restart   查看日志：sudo $GLOBAL_CMD log-fe"
    fi
}

print_summary() {
    local ip
    ip="$(detect_lan_ip)"
    echo ""
    ok "===== 部署完成 ====="
    if is_wsl; then
        echo "  前端访问（Windows 浏览器）：http://localhost:${FRONTEND_PORT}   ← 推荐"
        echo "  前端访问（局域网其它设备）：http://${ip}:${FRONTEND_PORT}"
    else
        echo "  前端访问（局域网/公网）：http://${ip}:${FRONTEND_PORT}"
        echo "  前端访问（服务器本机）  ：http://127.0.0.1:${FRONTEND_PORT}"
    fi
    echo "  后端接口                ：http://${ip}:${BACKEND_PORT}"
    echo "  静态产物：$FRONTEND_DIR/dist（生产环境建议用 nginx 托管并反代到 ${BACKEND_PORT}）"
    echo "  数据库  ：127.0.0.1:${MYSQL_PORT}  库 ${MYSQL_DB}  账号 root/${MYSQL_ROOT_PWD}"
    echo "  Redis   ：127.0.0.1:${REDIS_PORT}  密码 ${REDIS_PWD}"
    echo "  镜像    ：MySQL ${MYSQL_IMAGE} / Redis ${REDIS_IMAGE}（sudo $GLOBAL_CMD images 查看详情）"
    echo "  登录账号：admin / admin123"
    echo "  后端日志：$BACKEND_LOG"
    echo "  前端日志：$FRONTEND_LOG"
    echo ""
    if is_wsl; then
        wsl_access_note
        echo "  ▸ 前端首次启动要编译 1~2 分钟，未就绪时看日志：sudo $GLOBAL_CMD log-fe"
    else
        warn "打不开前端时先看这三条："
        echo "  1) 在你自己的电脑上访问 http://${ip}:${FRONTEND_PORT}，不要用 127.0.0.1（那指向你自己的电脑）"
        echo "  2) 云服务器需在控制台安全组放行 TCP ${FRONTEND_PORT}（前端）与 ${BACKEND_PORT}（后端）；本机防火墙已自动放行"
        echo "     （如需重跑：sudo $GLOBAL_CMD firewall）"
        echo "  3) 前端首次启动要编译 1~2 分钟，稍等重试；实时日志：sudo $GLOBAL_CMD log-fe"
    fi
    echo "  管理命令：sudo $GLOBAL_CMD status"
}

# ======================= 9. 一键完整部署 =======================
install_local_full() {
    env_init "$@"
    docker_env_init
    pull_source
    start_db_containers
    # ↓↓↓ v4.8 的顺序错误正是“后端连不上数据库”的根因
    patch_config
    init_database
    build_local
    start_local_services
    print_summary
    verify_all
}

# ======================= 9.4 Docker 镜像与版本一览 =======================
show_images() {
    step "Docker 镜像与版本"
    if ! cmd_exists docker || ! docker info >/dev/null 2>&1; then
        warn "Docker 未运行，无法读取镜像信息"
        return 0
    fi
    local p label img cname state running_img vers digest
    for p in "MySQL|$MYSQL_IMAGE|$MYSQL_CONTAINER" "Redis|$REDIS_IMAGE|$REDIS_CONTAINER"; do
        IFS='|' read -r label img cname <<<"$p"
        if docker image inspect "$img" >/dev/null 2>&1; then state="已拉取"; else state="未拉取"; fi
        echo ""
        echo "  [$label] 脚本配置版本：$img（本地：$state）"
        digest="$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$img" 2>/dev/null || true)"
        [ -n "$digest" ] && echo "    镜像摘要：$digest"
        if container_exists "$cname"; then
            running_img="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || true)"
            echo "    容器 $cname 使用镜像：${running_img:-未知}"
            if container_running "$cname"; then
                case "$label" in
                    MySQL) vers="$(docker exec "$cname" mysql --version 2>/dev/null || true)" ;;
                    Redis) vers="$(docker exec "$cname" redis-server --version 2>/dev/null || true)" ;;
                esac
                [ -n "$vers" ] && echo "    容器内版本：$vers"
            else
                echo "    容器未运行"
            fi
        else
            echo "    容器 $cname 尚未创建"
        fi
    done
    echo ""
    echo "  提示：改版本用 KTG_MYSQL_IMAGE / KTG_REDIS_IMAGE 覆盖；换版本需先 docker rm -f 旧容器"
}

# ======================= 9.5 环境体检（verify） =======================
# 比 status 更全：一次性核对“装完能不能用、外部能不能访问”，供 install/repair 收尾调用。
# 只读，不修改任何东西；有问题时给出对应的修复命令。
verify_all() {
    step "环境体检"
    local fail=0 ip code scope fe_pid ntbl t c miss=""
    ip="$(detect_lan_ip)"
    if [ "$(id -u)" -ne 0 ]; then
        warn "当前非 root：容器/数据库检测可能因权限不足而不准，建议：sudo $GLOBAL_CMD verify"
    fi

    # ---------- 1) 容器与中间件 ----------
    if container_running "$MYSQL_CONTAINER"; then ok "MySQL 容器运行中"; else warn "MySQL 容器未运行 → sudo $GLOBAL_CMD db"; fail=1; fi
    if container_running "$REDIS_CONTAINER"; then
        ok "Redis 容器运行中"
        if redis_ready; then ok "Redis 连接（含密码）正常"; else warn "Redis 连接失败（密码不符？）"; fail=1; fi
    else
        warn "Redis 容器未运行 → sudo $GLOBAL_CMD db"; fail=1
    fi

    # ---------- 2) 数据库结构 ----------
    ntbl="$(mysql_exec -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DB';" 2>/dev/null | tr -dc '0-9' || echo 0)"
    if db_has_app_tables; then
        ok "MES 业务表已就绪（库 $MYSQL_DB 共 ${ntbl:-0} 张表）"
    else
        warn "缺少 MES 业务表（库内仅 ${ntbl:-0} 张）→ sudo $GLOBAL_CMD sql"; fail=1
    fi
    for t in pro_feedback qc_ipqc; do
        for c in quantity_labor_scrap quantity_material_scrap quantity_other_scrap; do
            db_column_exists "$t" "$c" || miss="${miss} ${t}.${c}"
        done
    done
    if [ -z "$miss" ]; then ok "关键字段齐全（报工/质检废品数量列）"; else warn "缺失字段：${miss} → sudo $GLOBAL_CMD patch-db"; fail=1; fi

    # ---------- 3) 后端 ----------
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${BACKEND_PORT}/" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then ok "后端响应正常（HTTP $code，端口 $BACKEND_PORT）"; else warn "后端无响应（$BACKEND_PORT）→ sudo $GLOBAL_CMD log"; fail=1; fi

    # ---------- 4) 前端监听与响应 ----------
    scope="$(port_scope "$FRONTEND_PORT")"
    case "$scope" in
        all)   ok "前端已监听所有网卡（$FRONTEND_HOST）" ;;
        local) warn "前端仅监听 127.0.0.1，外部访问不了（需 --host 0.0.0.0）"; fail=1 ;;
        none)
            fe_pid=""
            [ -f "$FRONTEND_PID_FILE" ] && fe_pid="$(cat "$FRONTEND_PID_FILE" 2>/dev/null || true)"
            if [ -n "$fe_pid" ] && kill -0 "$fe_pid" 2>/dev/null; then
                warn "前端进程在跑但端口未监听（多半仍在编译），稍后再体检"; fail=1
            else
                warn "前端未运行 → sudo $GLOBAL_CMD start-fe"; fail=1
            fi
            ;;
        *) warn "无法检测前端端口（缺 ss/netstat）" ;;
    esac
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${FRONTEND_PORT}/" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then ok "前端 HTTP 响应正常（HTTP $code）"; fi

    # ---------- 5) 访问层 ----------
    if is_wsl; then
        wsl_access_note
    elif cmd_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        ufw status 2>/dev/null | grep -qE "(^|[^0-9])${FRONTEND_PORT}/tcp" \
            && ok "ufw 已放行 ${FRONTEND_PORT}/tcp" \
            || { warn "ufw 未放行 ${FRONTEND_PORT}/tcp → sudo $GLOBAL_CMD firewall"; fail=1; }
    elif cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --query-port="${FRONTEND_PORT}/tcp" >/dev/null 2>&1 \
            && ok "firewalld 已放行 ${FRONTEND_PORT}/tcp" \
            || { warn "firewalld 未放行 ${FRONTEND_PORT}/tcp → sudo $GLOBAL_CMD firewall"; fail=1; }
    fi

    # ---------- 6) 结论 ----------
    echo ""
    if [ "$fail" -eq 0 ]; then
        if is_wsl; then
            ok "体检通过：Windows 浏览器访问 http://localhost:${FRONTEND_PORT}"
        else
            ok "体检通过：访问 http://${ip}:${FRONTEND_PORT}"
        fi
    else
        warn "体检发现问题（见上）。可尝试一键修复：sudo $GLOBAL_CMD repair"
    fi
    return 0
}

# 一键修复：把实测中最高频的三类问题（缺业务表 / 缺字段 / 服务没起）一次处理掉
repair_all() {
    require_root "$@"
    step "一键修复（数据库 → 服务 → 体检）"
    ensure_docker_running
    start_db_containers
    init_database
    start_local_services
    verify_all
}

# ======================= 9.6 快捷开启 / 快捷命令 =======================
# 快捷开启：不重装、不编译，直接把数据库与服务拉起来并打印访问地址
quick_up() {
    require_root "$@"
    step "快捷开启"
    ensure_docker_running
    start_db_containers
    start_backend
    start_frontend || warn "前端未就绪（可能仍在编译），稍后查看：sudo $GLOBAL_CMD log-fe"
    local ip
    ip="$(detect_lan_ip)"
    echo ""
    if is_wsl; then
        ok "已开启：Windows 浏览器访问 http://localhost:${FRONTEND_PORT}"
    else
        ok "已开启：http://${ip}:${FRONTEND_PORT}（本机 http://127.0.0.1:${FRONTEND_PORT}）"
    fi
    ok "状态：sudo $GLOBAL_CMD status   停止：sudo $GLOBAL_CMD stop   体检：sudo $GLOBAL_CMD verify"
}

# 安装快捷命令：在 /usr/local/bin 写真正的可执行包装脚本（任意 shell 直接可用，无需 source）
# 由 env_init（即一键 install）自动调用，也可单独执行：sudo ktg shortcuts
install_shortcuts() {
    local bin ktg
    bin="${KTG_BIN_DIR:-/usr/local/bin}"
    ktg="$bin/$GLOBAL_CMD"
    mkdir -p "$bin"
    if [ ! -x "$ktg" ]; then
        cp -f "${BASH_SOURCE[0]:-$0}" "$ktg" 2>/dev/null || true
        chmod +x "$ktg" 2>/dev/null || true
    fi

    local pair name sub
    for pair in "ktgup:up" "ktgoff:stop" "ktgst:status" "ktgck:verify"; do
        name="${pair%%:*}"; sub="${pair##*:}"
        cat > "$bin/$name" <<EOF
#!/usr/bin/env bash
# KTG-MES 快捷命令：等价于 sudo $GLOBAL_CMD $sub（由一键脚本生成）
exec sudo $ktg $sub "\$@"
EOF
        chmod +x "$bin/$name"
        ok "已安装快捷命令：$name  →  sudo $GLOBAL_CMD $sub"
    done
    # 清理早期版本写入的 alias 文件，避免与可执行快捷命令混淆
    rm -f /etc/profile.d/ktg-shortcuts.sh 2>/dev/null || true
}

show_status() {
    step "运行状态"
    local ip scope fe_pid code
    ip="$(detect_lan_ip)"

    if container_running "$MYSQL_CONTAINER"; then ok "MySQL 容器运行中"; else warn "MySQL 容器未运行"; fi
    if container_running "$REDIS_CONTAINER"; then ok "Redis 容器运行中"; else warn "Redis 容器未运行"; fi

    scope="$(port_scope "$BACKEND_PORT")"
    case "$scope" in
        all)   ok "后端端口 $BACKEND_PORT 已监听（所有网卡）：http://${ip}:${BACKEND_PORT}" ;;
        local) warn "后端端口 $BACKEND_PORT 仅监听 127.0.0.1，外部访问不了" ;;
        none)  warn "后端端口 $BACKEND_PORT 未监听" ;;
        *)     warn "无法检测后端端口状态（缺少 ss/netstat）" ;;
    esac

    scope="$(port_scope "$FRONTEND_PORT")"
    case "$scope" in
        all)   ok "前端端口 $FRONTEND_PORT 已监听（所有网卡）：http://${ip}:${FRONTEND_PORT}" ;;
        local) warn "前端端口 $FRONTEND_PORT 仅监听 127.0.0.1，外部访问不了（需 --host 0.0.0.0 重启）" ;;
        none)
            fe_pid=""
            if [ -f "$FRONTEND_PID_FILE" ]; then
                fe_pid="$(cat "$FRONTEND_PID_FILE" 2>/dev/null || true)"
            fi
            if [ -n "$fe_pid" ] && kill -0 "$fe_pid" 2>/dev/null; then
                warn "前端进程在运行但端口 $FRONTEND_PORT 尚未监听：多半还在编译（首次 1~2 分钟），稍后再查"
            else
                warn "前端端口 $FRONTEND_PORT 未监听（进程也未在运行）"
            fi
            ;;
        *) warn "无法检测前端端口状态（缺少 ss/netstat）" ;;
    esac

    # 端口在听 ≠ 应用能响应：对前端做一次真实 HTTP 探测
    if [ "$scope" = "all" ] || [ "$scope" = "local" ]; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${FRONTEND_PORT}/" 2>/dev/null || true)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            ok "前端 HTTP 探测通过（HTTP $code）"
        fi
    fi

    # 防火墙状态：WSL 下由 Windows 侧决定；Linux 上检查 ufw/firewalld
    if is_wsl; then
        info "WSL 环境：Windows 浏览器用 http://localhost:${FRONTEND_PORT}；局域网设备访问需在 Windows 放行端口"
    elif cmd_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        if ufw status 2>/dev/null | grep -qE "(^|[^0-9])${FRONTEND_PORT}/tcp"; then
            ok "ufw 已放行 ${FRONTEND_PORT}/tcp"
        else
            warn "ufw 未放行 ${FRONTEND_PORT}/tcp，执行：sudo $GLOBAL_CMD firewall"
        fi
    elif cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --query-port="${FRONTEND_PORT}/tcp" >/dev/null 2>&1; then
            ok "firewalld 已放行 ${FRONTEND_PORT}/tcp"
        else
            warn "firewalld 未放行 ${FRONTEND_PORT}/tcp，执行：sudo $GLOBAL_CMD firewall"
        fi
    fi

    if [ -f "$BACKEND_LOG" ]; then echo "  后端日志：$BACKEND_LOG（$(du -h "$BACKEND_LOG" | cut -f1)）"; fi
    if [ -f "$FRONTEND_LOG" ]; then echo "  前端日志：$FRONTEND_LOG（$(du -h "$FRONTEND_LOG" | cut -f1)）"; fi
    if is_wsl; then
        echo "  访问地址：http://localhost:${FRONTEND_PORT}（Windows 浏览器）；http://${ip}:${FRONTEND_PORT}（其它设备）"
    else
        echo "  访问地址：http://${ip}:${FRONTEND_PORT}（从别的电脑访问请用这个，不要用 127.0.0.1）"
    fi
}

clean_db() {
    warn "即将删除 MySQL / Redis 容器（数据一并丢失）"
    read -rp "确认执行？(y/N): " c || c=""
    if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
        docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
        ok "已删除数据库容器"
    else
        info "已取消"
    fi
}

uninstall_all() {
    warn "即将停止所有服务、删除容器，并删除 $WORK_DIR"
    read -rp "确认执行？(y/N): " c || c=""
    if [ "$c" != "y" ] && [ "$c" != "Y" ]; then
        info "已取消"
        return 0
    fi
    stop_local_services
    docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    rm -f "/usr/local/bin/$GLOBAL_CMD"
    ok "清理完成"
}

# ======================= 10. 主菜单 =======================
show_menu() {
    while true; do
        clear 2>/dev/null || true
        cat <<EOF
==============================================
       KTG-MES 一键部署管理工具 v7.0
==============================================
  [1] 本地模式完整安装（推荐）
  [2] 仅启动数据库容器
  [3] 仅初始化数据库（导入 sql）
  [4] 重新编译（后端 + 前端）
  [a] 仅启动前端（不重启后端）
  [b] 仅重新编译前端
  [u] 快捷开启（不重装不编译，直接拉起服务）
  [k] 安装/刷新全局命令与快捷命令（ktgup 等）
  [p] 补齐数据库缺失字段（patch-db）
  [r] 一键修复（建库 + 补列 + 启动 + 体检）
  [v] 环境体检
  [i] 查看 Docker 镜像与版本
  [5] 重启本地服务
  [6] 查看运行状态
  [7] 查看后端日志
  [8] 查看前端日志
  [9] 停止本地服务
  [m] 配置国内加速源（APT/Maven/npm/pip/Docker）
  [f] 放行防火墙端口（前端/后端，ufw/firewalld/iptables）
  [c] 清理数据库容器（保留源码）
  [0] 退出
==============================================
EOF
        local opt=""
        read -rp "请输入选项：" opt || opt="0"
        case "$opt" in
            1) install_local_full ;;
            2) env_init; docker_env_init; start_db_containers ;;
            3) env_init; init_database ;;
            4) env_init; patch_config; build_local ;;
            a|A) require_root "$@"; start_frontend ;;
            b|B) require_root "$@"; build_frontend ;;
            u|U) quick_up ;;
            i|I) show_images ;;
            k|K) require_root "$@"; register_global_cmd; install_shortcuts ;;
            p|P) require_root "$@"; ensure_docker_running; apply_schema_patches ;;
            r|R) repair_all ;;
            v|V) verify_all ;;
            5) start_local_services ;;
            6) show_status ;;
            7) tail -n 200 -f "$BACKEND_LOG" ;;
            8) tail -n 200 -f "$FRONTEND_LOG" ;;
            9) stop_local_services ;;
            m|M) setup_mirrors ;;
            f|F) require_root "$@"; open_firewall_for_app ;;
            c|C) clean_db ;;
            0|q|Q) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
        echo ""
        read -rp "按回车返回主菜单..." _ || exit 0
    done
}

# 仅配置国内源（不下载源码、不建库），便于先解决“装不上包”的问题
setup_mirrors() {
    step "配置国内加速源"
    require_root "$@"
    mkdir -p "$WORK_DIR" "$LOG_DIR"
    if [ "$USE_CN_MIRROR" != "1" ]; then
        warn "KTG_USE_CN_MIRROR=0，本次不做任何替换（保留官方源）"
        return 0
    fi
    setup_apt_mirror
    setup_yum_mirror
    write_maven_settings
    install_node >/dev/null 2>&1 || warn "Node.js 未就绪，npm 源稍后在前端编译阶段自动生效"
    setup_npm_mirror
    setup_pip_mirror
    if cmd_exists docker; then
        setup_docker_mirror
    else
        warn "未安装 Docker，跳过 Docker 加速源配置（install 时会自动安装并配置）"
    fi
    echo ""
    ok "国内源配置完成："
    echo "  APT   : $(grep -m1 -oE 'https?://[^ ]+' /etc/apt/sources.list 2>/dev/null | head -1 || echo 未修改)"
    echo "  YUM   : $(grep -m1 -oE 'https?://[^ ]+' /etc/yum.repos.d/ktg-mirror.repo 2>/dev/null | head -1 || echo 未修改)"
    echo "  Maven : $MAVEN_MIRROR -> $MAVEN_SETTINGS"
    echo "  npm   : $NPM_MIRROR"
    echo "  pip   : $PIP_MIRROR"
    echo "  Node  : ${NODE_MIRRORS[0]}"
    echo "  Docker: $( [ -n "$DOCKER_MIRROR" ] && echo "$DOCKER_MIRROR" || echo '公益源自动探测' )"
}

usage() {
    cat <<EOF
KTG-MES 部署管理工具 v7.0

用法：sudo $0 [命令]

命令：
  install        一键完整部署（环境 → 容器 → 源码 → 配置 → 建库 → 编译 → 启动 → 体检）
  up / on        快捷开启（拉起数据库与服务并打印访问地址，不重装不编译）
  shortcuts      安装/刷新全局命令 ktg 与快捷命令（ktgup/ktgoff/ktgst/ktgck）
  repair         一键修复（建库 + 补列 + 启动 + 体检）
  verify         环境体检（容器/数据库/字段/前后端 HTTP/监听网卡/防火墙）
  images         查看 Docker 镜像与版本（脚本配置 / 本地拉取 / 容器实际 / 摘要）
  mirrors        仅配置国内加速源（APT/YUM/Maven/npm/pip/Docker），不下载源码
  start          启动数据库容器与本地服务
  stop           停止本地服务
  restart        重启本地服务
  status         查看运行状态
  build          重新编译后端与前端
  build-fe       仅重新编译前端
  start-fe       仅启动前端（不重启后端）
  sql            初始化数据库（优先导入仓库自带的完整导出，并补齐缺失字段）
  patch-db       仅补齐数据库缺失字段（代码新于导出时用）
  firewall       放行前端/后端端口（ufw/firewalld/iptables），排查“打不开”第一步
  db             仅启动数据库容器（MySQL + Redis）
  log            跟踪后端日志
  log-fe         跟踪前端日志
  clean          删除数据库容器（数据丢失）
  uninstall      停止服务、删除容器与部署目录
  menu / 无参数  交互式菜单

国内网络相关的可覆盖变量：
  KTG_USE_CN_MIRROR=0/1   总开关，默认 1（启用国内源）
  KTG_APT_MIRROR          默认 https://mirrors.aliyun.com（备选清华/中科大自动探测；YUM 同理）
  KTG_MAVEN_MIRROR        默认 https://maven.aliyun.com/repository/public
  KTG_NPM_MIRROR          默认 https://registry.npmmirror.com
  KTG_NODE_MIRROR         默认 https://npmmirror.com/mirrors/node（备选清华/官方）
  KTG_TEMURIN_MIRROR      默认 https://mirrors.tuna.tsinghua.edu.cn/Adoptium
  KTG_DOCKER_MIRROR       阿里云专属加速地址（强烈建议填写）
  KTG_GH_PROXY            默认 https://ghfast.top（GitHub 加速前缀）
  KTG_DL_TIMEOUT          下载超时秒数，默认 900

其他常用变量：
  KTG_MYSQL_PWD=xxx KTG_REDIS_PWD=xxx KTG_BACKEND_PORT=8080 KTG_FRONTEND_PORT=1024
  KTG_FRONTEND_HOST=0.0.0.0（前端监听地址，默认所有网卡；只在本机用可设 127.0.0.1）
  KTG_BACKEND_REPO=... KTG_FRONTEND_REPO=...（内网 Git 地址）

Docker 镜像拉取建议：
  1) 申请免费专属加速地址：https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors
  2) sudo KTG_DOCKER_MIRROR=https://xxxx.mirror.aliyuncs.com $0 mirrors
  3) 未配置时会自动探测 docker.m.daocloud.io 等公益源，并在拉取失败时按注册表前缀回退

前端打不开排查顺序（v5.1 已自动化大部分）：
  1) 地址：从你自己电脑访问 http://<服务器局域网IP>:1024，不要用 127.0.0.1（那指向你自己电脑）
  2) 命令：sudo ktg status —— 应显示“已监听（所有网卡）”与“HTTP 探测通过”
  3) 防火墙：脚本已自动放行本机 ufw/firewalld/iptables；云服务器还需在控制台安全组放行 TCP 1024 / 8080
  4) 首次启动前端需编译 1~2 分钟，未就绪时看日志：sudo ktg log-fe

默认账号：admin / admin123
EOF
}

# ======================= 入口 =======================
main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        install)   install_local_full "$@" ;;
        mirrors)   setup_mirrors "$@" ;;
        start)     env_init; start_db_containers; start_local_services ;;
        stop)      stop_local_services ;;
        restart)   stop_local_services; sleep 2; start_local_services ;;
        status)    show_status ;;
        images|image) show_images ;;
        verify|doctor|check) verify_all ;;
        repair)    repair_all ;;
        up|on|open|go|quick) quick_up ;;
        shortcuts|alias) require_root "$@"; register_global_cmd; install_shortcuts ;;
        build)     env_init; patch_config; build_local ;;
        build-fe)  require_root "$@"; build_frontend ;;
        start-fe)  require_root "$@"; start_frontend ;;
        sql)       env_init; start_db_containers; init_database ;;
        patch-db)  require_root "$@"; ensure_docker_running; apply_schema_patches ;;
        db)        env_init; docker_env_init; start_db_containers ;;
        log)       tail -n 200 -f "$BACKEND_LOG" ;;
        log-fe)    tail -n 200 -f "$FRONTEND_LOG" ;;
        firewall)  require_root "$@"; open_firewall_for_app ;;
        clean)     clean_db ;;
        uninstall) uninstall_all ;;
        menu|"")   show_menu ;;
        -h|--help|help) usage ;;
        *)         err "未知命令：$cmd"; usage; exit 1 ;;
    esac
}

main "$@"
