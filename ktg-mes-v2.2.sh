#!/usr/bin/env bash
#====================================================================================
#  KTG-MES 一键部署管理工具 v2.2（骏通-MES 品牌最终版：登录页 + 10 张系统页面设计稿全部实现，基于 v7.0）
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
#
#  【全容器（Docker）模式 · 与本地模式并存】
#  22. 新增 install-docker：前后端全部容器化运行（后端 eclipse-temurin:8-jre、
#      前端 nginx）。两种模式【二选一、互斥】：默认共用端口(1024/8080)，启动其中一种
#      会自动停止另一种并记录当前模式；MySQL/Redis 两模式共用
#      配套命令：docker-up(容器快捷开启) / docker-down(停止容器) / stop-all
#  23. 一键卸载并还原：删除本项目容器(含数据卷)/镜像/网络/部署目录/全局命令与快捷
#      命令，并还原安装时备份的 Docker 加速配置(daemon.json)；--purge 额外清基础
#      镜像与脚本安装的 JDK8；--dry-run 只预览不执行
#  24. verify/status 纳入容器模式检查
#  25. 代理绕行：http_proxy 指向本机代理(如 127.0.0.1:10808)且 no_proxy 写成 127.* 时，
#      curl 不识别会导致本机访问被劫持成 5xx。脚本所有本机探测强制 --noproxy '*'，
#      并在 main 启动时为本机地址统一设置 no_proxy；新增 proxy 命令诊断代理环境
#------------------------------------------------------------------------------------
#  用法：sudo ./ktg-mes.sh [install|install-docker|up|docker-up|docker-down|stop-all|repair|verify|status|images|mirrors|db|sql|patch-db|build|build-fe|apply-brand|start|start-fe|stop|restart|log|log-fe|firewall|clean|uninstall|menu]
#        两种模式二选一、互斥，默认共用端口 1024/8080；启动一种会自动停掉另一种
#  终端快捷命令（安装后生效）：ktgup=快捷开启  ktgoff=停止  ktgst=状态  ktgck=体检
#  全部配置项均可用环境变量覆盖，例如：sudo KTG_MYSQL_PWD=xxx ./ktg-mes.sh install
#====================================================================================
set -Eeuo pipefail

# ======================= 全局配置（可用环境变量覆盖） =======================
WORK_DIR="${KTG_WORK_DIR:-/root/ktg-mes-deploy}"
BACKEND_DIR="$WORK_DIR/ktg-mes"
FRONTEND_DIR="$WORK_DIR/ktg-mes-ui"

# ======================= 品牌定制配置（最终版新增，可用环境变量覆盖） =======================
# 品牌：骏通-MES（严格按交付效果图定制）
ENABLE_BRAND="${KTG_ENABLE_BRAND:-1}"
SYSTEM_NAME="${KTG_SYSTEM_NAME:-骏通-MES}"
SYSTEM_TITLE="${KTG_SYSTEM_TITLE:-骏通-MES 生产执行系统}"
COMPANY_NAME="${KTG_COMPANY_NAME:-骏通齿轮加工有限公司}"
PRIMARY_COLOR="${KTG_PRIMARY_COLOR:-#0F3460}"
SUCCESS_COLOR="${KTG_SUCCESS_COLOR:-#10b981}"
WARNING_COLOR="${KTG_WARNING_COLOR:-#f59e0b}"
DANGER_COLOR="${KTG_DANGER_COLOR:-#ef4444}"
MENU_BACKGROUND="${KTG_MENU_BACKGROUND:-#1a2a3a}"
SUB_MENU_BACKGROUND="${KTG_SUB_MENU_BACKGROUND:-#0f1e2e}"
SUB_MENU_HOVER="${KTG_SUB_MENU_HOVER:-#0F3460}"


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

# ======================= 全容器（Docker）模式：与本地模式并存 =======================
# 容器模式使用独立端口与独立容器名，可与本地模式同时运行、互不冲突；MySQL/Redis 共用
# 两种模式【二选一、互斥】：默认共用同一组端口（前端 1024 / 后端 8080），访问地址不随模式变。
# 启动其中一种会自动停止另一种；如需并存可把 KTG_DOCKER_*_PORT 指到不同端口。
DOCKER_BE_PORT="${KTG_DOCKER_BACKEND_PORT:-$BACKEND_PORT}"
DOCKER_FE_PORT="${KTG_DOCKER_FRONTEND_PORT:-$FRONTEND_PORT}"
MODE_FILE="$WORK_DIR/.mode"   # 记录当前激活模式：local / docker
BACKEND_CONTAINER="${KTG_BACKEND_CONTAINER:-ktg-backend}"
FRONTEND_CONTAINER="${KTG_FRONTEND_CONTAINER:-ktg-frontend}"
BACKEND_IMAGE="${KTG_BACKEND_IMAGE:-ktg-mes-backend:v7}"
FRONTEND_IMAGE="${KTG_FRONTEND_IMAGE:-ktg-mes-frontend:v7}"
DOCKER_NET="${KTG_DOCKER_NET:-ktg-net}"
JAVA_RUNTIME_IMAGE="${KTG_JAVA_RUNTIME_IMAGE:-eclipse-temurin:8-jre}"
NGINX_IMAGE="${KTG_NGINX_IMAGE:-nginx:1.25-alpine}"
DOCKER_DIR="$WORK_DIR/docker"

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

# 本机 HTTP 探测：--noproxy '*' 强制直连，避免被 http_proxy 劫持成 503 造成误判
http_code() {
    curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time "${2:-3}" "$1" 2>/dev/null || true
}

# “活着”判定：2xx/3xx/4xx 都算在线（404/401 说明服务已启动），5xx/无响应算异常
http_alive() {
    local code
    code="$(http_code "$1" "${2:-3}")"
    case "$code" in
        2??|3??|4??) return 0 ;;
        *) return 1 ;;
    esac
}

# 代理绕行：很多环境（尤其 WSL 的 autoProxy）把 http_proxy 指向本机代理端口
# （如 127.0.0.1:10808），而 no_proxy 里的 "127.*" 通配 curl 并不识别，于是访问本机
# 服务被代理拦成 5xx。这里为本机地址统一设置 no_proxy（外部源下载仍走代理），
# 所有本机探测另外再显式加 --noproxy '*' 双保险。
setup_no_proxy() {
    local ip noproxy
    ip="$(detect_lan_ip)"
    noproxy="localhost,127.0.0.1,::1,0.0.0.0,${ip}"
    export no_proxy="$noproxy"
    export NO_PROXY="$noproxy"
    if [ -n "${http_proxy:-}${HTTP_PROXY:-}${https_proxy:-}${HTTPS_PROXY:-}" ]; then
        info "检测到代理（${http_proxy:-${HTTP_PROXY:-}}）；本机地址已加入 no_proxy，本机访问不会被劫持"
    fi
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

# 真正的“就绪”：能鉴权并执行查询。注意 mysqladmin ping 在初始化中的临时实例上也会
# 返回成功、在密码错误时也可能返回成功，不能作为可用性判据。
mysql_auth_ok() {
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -N -B -e "SELECT 1" >/dev/null 2>&1
}

# 同 mysql_exec，但把数据库报错透出来（DDL 失败时需要看到原因，否则只有一句“补列失败”）
mysql_exec_err() {
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$@" 2>&1 >/dev/null
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

    info "等待 MySQL 完全就绪（首次初始化可能需要 30~120 秒）..."
    local i
    for i in $(seq 1 150); do
        mysql_auth_ok && break
        sleep 2
    done
    if ! mysql_auth_ok; then
        err "MySQL 启动/鉴权超时，查看日志：docker logs $MYSQL_CONTAINER"
        err "若为 root 密码不符：用 KTG_MYSQL_PWD=实际密码 重跑，或 docker rm -f $MYSQL_CONTAINER 后重建"
        return 1
    fi
    if ! mysql_exec -N -B -e "USE \`$MYSQL_DB\`;" >/dev/null 2>&1; then
        warn "数据库 $MYSQL_DB 不存在，尝试创建"
        # 建库失败不中断脚本（例如权限/初始化未完成），init_database 导入前会再确保
        mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
            || warn "创建数据库失败（不中断，稍后重试）"
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
    local t c ddl applied=0 sql err
    while read -r t c ddl; do
        [ -n "$t" ] || continue
        db_table_exists "$t" || continue
        db_column_exists "$t" "$c" && continue
        info "补列：${t}.${c}"
        # 关键：必须带库名！mysql -e 未选库时 ALTER TABLE 会报 "No database selected"
        sql="ALTER TABLE \`$MYSQL_DB\`.\`$t\` ADD COLUMN \`$c\` $ddl;"
        if mysql_exec -e "$sql"; then
            applied=$((applied + 1))
        else
            err="$(mysql_exec_err -e "$sql")"
            warn "补列失败：${t}.${c} → ${err:-未知错误}"
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
    if ! mysql_auth_ok; then
        err "无法以 root/$MYSQL_ROOT_PWD 连接容器 $MYSQL_CONTAINER"
        err "密码不符时：KTG_MYSQL_PWD=实际密码 重跑；或 docker rm -f $MYSQL_CONTAINER 后用默认密码重建"
        return 1
    fi
    # 确保业务库存在（容器首次初始化可能尚未建好）
    if ! mysql_exec -N -B -e "USE \`$MYSQL_DB\`;" >/dev/null 2>&1; then
        mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" || true
    fi
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

# ======================= 品牌 Logo 资源（base64 内嵌） =======================
LOGO_PRIMARY_B64="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"
LOGO_INVERSE_B64="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"
FAVICON_B64="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"


# ======================= 品牌定制：apply_brand_custom（最终版新增） =======================
# 严格按交付效果图：骏通-MES 系统名 / JT 环形传动标 / 工业深蓝主题 / 骏通版登录页（左右分栏）
apply_brand_custom() {
    local ui="${1:-$FRONTEND_DIR}"
    if [ "${ENABLE_BRAND:-1}" != "1" ]; then
        warn "品牌定制已关闭（KTG_ENABLE_BRAND=0），跳过"
        return 0
    fi
    if [ ! -d "$ui" ]; then
        warn "前端目录不存在，跳过品牌定制：$ui"
        return 1
    fi

    step "应用骏通-MES 品牌定制（严格按交付效果图）"

    # 0) 备份
    local bak="$WORK_DIR/brand-backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bak"
    local bf
    for bf in .env.development .env.production package.json \
        public/index.html public/favicon.png \
        src/assets/logo/logo.png src/assets/logo/logo-inverse.png \
        src/assets/styles/element-variables.scss src/assets/styles/variables.scss \
        src/assets/styles/design.scss src/main.js \
        src/layout/components/Sidebar/Logo.vue src/views/login.vue \
        src/views/index.vue src/views/mes/qc/batchtrace/index.vue \
        src/views/mes/wm/wmstock/index.vue src/views/mes/pro/workorder/index.vue \
        src/views/mes/qc/qcresult/index.vue src/views/mes/dv/machinery/index.vue \
        src/views/mes/cal/plan/index.vue src/views/monitor/server/index.vue \
        src/views/system/user/index.vue src/views/mes/md/mditem/index.vue; do
        if [ -f "$ui/$bf" ]; then
            mkdir -p "$bak/$(dirname "$bf")"
            cp "$ui/$bf" "$bak/$bf"
        fi
    done
    ok "原文件已备份：$bak"

    # 1) Logo：JT 环形传动标
    if [ -n "$LOGO_PRIMARY_B64" ]; then
        mkdir -p "$ui/src/assets/logo"
        printf '%s' "$LOGO_PRIMARY_B64" | base64 -d > "$ui/src/assets/logo/logo.png" 2>/dev/null || true
    fi
    if [ -n "$LOGO_INVERSE_B64" ]; then
        mkdir -p "$ui/src/assets/logo"
        printf '%s' "$LOGO_INVERSE_B64" | base64 -d > "$ui/src/assets/logo/logo-inverse.png" 2>/dev/null || true
    fi
    if [ -n "$FAVICON_B64" ]; then
        mkdir -p "$ui/public"
        printf '%s' "$FAVICON_B64" | base64 -d > "$ui/public/favicon.png" 2>/dev/null || true
    fi
    ok "Logo 已替换（JT 环形传动标）"

    # 2) 主题色：工业深蓝
    local ev="$ui/src/assets/styles/element-variables.scss"
    if [ -f "$ev" ]; then
        sed -i "s/\\\$--color-primary: .*/\\\$--color-primary: $PRIMARY_COLOR;/" "$ev" 2>/dev/null || true
        sed -i "s/\\\$--color-success: .*/\\\$--color-success: $SUCCESS_COLOR;/" "$ev" 2>/dev/null || true
        sed -i "s/\\\$--color-warning: .*/\\\$--color-warning: $WARNING_COLOR;/" "$ev" 2>/dev/null || true
        sed -i "s/\\\$--color-danger: .*/\\\$--color-danger: $DANGER_COLOR;/" "$ev" 2>/dev/null || true
        ok "Element 主题色已更新（主色 $PRIMARY_COLOR）"
    fi
    local vs="$ui/src/assets/styles/variables.scss"
    if [ -f "$vs" ]; then
        sed -i "s/\\\$base-menu-background:.*/\\\$base-menu-background:$MENU_BACKGROUND;/" "$vs" 2>/dev/null || true
        sed -i "s/\\\$base-sub-menu-background:.*/\\\$base-sub-menu-background:$SUB_MENU_BACKGROUND;/" "$vs" 2>/dev/null || true
        sed -i "s/\\\$base-sub-menu-hover:.*/\\\$base-sub-menu-hover:$SUB_MENU_HOVER;/" "$vs" 2>/dev/null || true
        sed -i "s/\\\$base-menu-color-active:.*/\\\$base-menu-color-active:#ffffff;/" "$vs" 2>/dev/null || true
        ok "侧边栏深色工业蓝菜单已应用"
    fi

    # 3) 系统名：骏通-MES
    local lv="$ui/src/layout/components/Sidebar/Logo.vue"
    if [ -f "$lv" ]; then
        sed -i "s/title: '.*'/title: '$SYSTEM_NAME'/" "$lv" 2>/dev/null || true
    fi
    sed -i "s/VUE_APP_TITLE = .*/VUE_APP_TITLE = $SYSTEM_TITLE/" "$ui/.env.development" 2>/dev/null || true
    sed -i "s/VUE_APP_TITLE = .*/VUE_APP_TITLE = $SYSTEM_TITLE/" "$ui/.env.production" 2>/dev/null || true
    sed -i "s/\"description\": \".*\"/\"description\": \"$SYSTEM_TITLE（$COMPANY_NAME 定制版）\"/" "$ui/package.json" 2>/dev/null || true
    ok "系统名已更新：$SYSTEM_TITLE"

    # 4) 登录页：严格按骏通版效果图（左右分栏 + 品牌区 + 表单区）
    cat > "$ui/src/views/login.vue" <<'LOGIN_EOF'
<template>
  <div class="login">
    <!-- 左侧品牌区 -->
    <div class="brand-panel">
      <div class="brand-top">
        <img class="brand-logo" src="@/assets/logo/logo-inverse.png" alt="logo" />
        <span class="brand-name">骏通齿轮</span>
      </div>
      <div class="brand-main">
        <h1 class="brand-title">骏通智能制造执行系统</h1>
        <p class="brand-slogan">精密齿轮·数字化车间·全流程追溯</p>
      </div>
      <div class="brand-bottom"></div>
    </div>

    <!-- 右侧登录区 -->
    <div class="login-panel">
      <div class="login-box">
        <h2 class="welcome-title">欢迎登录</h2>
        <p class="welcome-sub">骏通 MES 生产管理系统</p>
        <el-form ref="loginForm" :model="loginForm" :rules="loginRules" class="login-form">
          <el-form-item prop="username">
            <el-input
              v-model="loginForm.username"
              type="text"
              auto-complete="off"
              placeholder="工号/账号"
            >
              <svg-icon slot="prefix" icon-class="user" class="el-input__icon input-icon" />
            </el-input>
          </el-form-item>
          <el-form-item prop="password">
            <el-input
              v-model="loginForm.password"
              type="password"
              auto-complete="off"
              placeholder="密码"
              @keyup.enter.native="handleLogin"
            >
              <svg-icon slot="prefix" icon-class="password" class="el-input__icon input-icon" />
            </el-input>
          </el-form-item>
          <el-form-item>
            <el-select v-model="client" @change="changeClient" placeholder="请选择打印机客户端" style="width: 100%;">
              <el-option
                v-for="item in clientList"
                :key="item.clientId"
                :label="item.clientName"
                :value="item.clientName">
              </el-option>
            </el-select>
          </el-form-item>
          <el-form-item prop="code" v-if="captchaOnOff">
            <el-input
              v-model="loginForm.code"
              auto-complete="off"
              placeholder="验证码"
              style="width: 63%"
              @keyup.enter.native="handleLogin"
            >
              <svg-icon slot="prefix" icon-class="validCode" class="el-input__icon input-icon" />
            </el-input>
            <div class="login-code">
              <img :src="codeUrl" @click="getCode" class="login-code-img"/>
            </div>
          </el-form-item>
          <div class="login-options">
            <el-checkbox v-model="loginForm.rememberMe" style="margin:0px 0px 0px 0px;">记住账号</el-checkbox>
            <span class="forgot-link" @click="handleForgot">忘记密码?</span>
          </div>
          <el-form-item style="width:100%;">
            <el-button
              :loading="loading"
              size="medium"
              type="primary"
              style="width:100%;"
              @click.native.prevent="handleLogin"
            >
              <span v-if="!loading">登 录</span>
              <span v-else>登 录 中...</span>
            </el-button>
            <div style="float: right;" v-if="register">
              <router-link class="link-type" :to="'/register'">立即注册</router-link>
            </div>
          </el-form-item>
        </el-form>
        <div class="other-login">
          <span class="other-divider"></span>
          <span class="other-label">其他登录方式</span>
          <span class="other-divider"></span>
        </div>
        <div class="other-btns">
          <span class="other-btn" @click="handleQrLogin">扫码登录</span>
          <span class="other-btn" @click="handleWeComLogin">企业微信</span>
        </div>
      </div>
      <div class="copyright">©2026 骏通齿轮加工有限公司 版权所有</div>
    </div>
  </div>
</template>

<script>
import { getCodeImg } from "@/api/login";
import Cookies from "js-cookie";
import { encrypt, decrypt } from '@/utils/jsencrypt'
import {getAll} from "../api/print/client";

export default {
  name: "Login",
  data() {
    return {
      codeUrl: "",
      loginForm: {
        username: "testuser",
        password: "123456",
        rememberMe: false,
        code: "",
        uuid: ""
      },
      clientList: [],
      client: null,
      loginRules: {
        username: [
          { required: true, trigger: "blur", message: "请输入您的账号" }
        ],
        password: [
          { required: true, trigger: "blur", message: "请输入您的密码" }
        ],
        code: [{ required: true, trigger: "change", message: "请输入验证码" }]
      },
      loading: false,
      // 验证码开关
      captchaOnOff: true,
      // 注册开关
      register: false,
      redirect: undefined
    };
  },
  watch: {
    $route: {
      handler: function(route) {
        this.redirect = route.query && route.query.redirect;
      },
      immediate: true
    }
  },
  created() {
    this.getCode();
    this.getCookie();
    getAll().then(res => {
      this.clientList = res.data
    })
  },
  methods: {
    changeClient(val) {
      this.client = this.clientList.filter(item => item.clientName == val)[0]
    },
    toIPC(){
      window.open("https://beian.miit.gov.cn/","_blank");
    },
    handleForgot() {
      this.$message.warning('请联系系统管理员重置密码');
    },
    handleQrLogin() {
      this.$message.warning('扫码登录功能暂未开放，请使用账号登录');
    },
    handleWeComLogin() {
      this.$message.warning('企业微信登录功能暂未开放，请使用账号登录');
    },
    getCode() {
      getCodeImg().then(res => {
        this.captchaOnOff = res.captchaOnOff === undefined ? true : res.captchaOnOff;
        if (this.captchaOnOff) {
          this.codeUrl = "data:image/gif;base64," + res.img;
          this.loginForm.uuid = res.uuid;
        }
      });
    },
    getCookie() {
      const username = Cookies.get("username");
      const password = Cookies.get("password");
      const rememberMe = Cookies.get('rememberMe')
      this.loginForm = {
        username: username === undefined ? this.loginForm.username : username,
        password: password === undefined ? this.loginForm.password : decrypt(password),
        rememberMe: rememberMe === undefined ? false : Boolean(rememberMe)
      };
    },
    handleLogin() {
      if (this.client) {
        // 将打印机客户端配置保存到 localStorage
        const key = 'defaultClient'
        const value = JSON.stringify(this.client)
        localStorage.setItem(key, value)
        // if(!hiprint.hiwebSocket.opened){
        //   hiprint.setConfig()
        //   if (this.client.clientToken) {
        //     hiprint.hiwebSocket.setHost(this.client.clientIp + ":" + this.client.clientPort, this.client.clientToken)
        //   } else {
        //     hiprint.hiwebSocket.setHost(this.client.clientIp + ":" + this.client.clientPort)
        //   }
        // }
      }
      this.$refs.loginForm.validate(valid => {
        if (valid) {
          this.loading = true;
          if (this.loginForm.rememberMe) {
            Cookies.set("username", this.loginForm.username, { expires: 30 });
            Cookies.set("password", encrypt(this.loginForm.password), { expires: 30 });
            Cookies.set('rememberMe', this.loginForm.rememberMe, { expires: 30 });
          } else {
            Cookies.remove("username");
            Cookies.remove("password");
            Cookies.remove('rememberMe');
          }
          this.$store.dispatch("Login", this.loginForm).then(() => {
            this.$router.push({ path: this.redirect || "/" }).catch(()=>{});
          }).catch(() => {
            this.loading = false;
            if (this.captchaOnOff) {
              this.getCode();
            }
          });
        }
      });
    }
  }
};
</script>

<style rel="stylesheet/scss" lang="scss">
.login {
  display: flex;
  width: 100%;
  height: 100%;
  overflow: hidden;
}

/* ===== 左侧品牌区 ===== */
.brand-panel {
  flex: 0 0 55%;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  padding: 60px 70px;
  background: linear-gradient(135deg, #0F3460 0%, #16467A 100%);
  color: #ffffff;
  box-sizing: border-box;
}
.brand-top {
  display: flex;
  align-items: center;
}
.brand-logo {
  width: 56px;
  height: 56px;
  margin-right: 14px;
}
.brand-name {
  font-size: 30px;
  font-weight: 600;
  letter-spacing: 2px;
}
.brand-main {
  flex: 1;
  display: flex;
  flex-direction: column;
  justify-content: center;
}
.brand-title {
  margin: 0 0 18px 0;
  font-size: 44px;
  font-weight: 700;
  letter-spacing: 3px;
}
.brand-slogan {
  margin: 0;
  font-size: 20px;
  letter-spacing: 2px;
  opacity: 0.85;
}
.brand-bottom {
  height: 20px;
}

/* ===== 右侧登录区 ===== */
.login-panel {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  background: #ffffff;
  position: relative;
  box-sizing: border-box;
}
.login-box {
  width: 400px;
  max-width: 88%;
}
.welcome-title {
  margin: 0 0 6px 0;
  text-align: center;
  font-size: 30px;
  font-weight: 700;
  color: #0F3460;
}
.welcome-sub {
  margin: 0 0 30px 0;
  text-align: center;
  font-size: 15px;
  color: #606266;
}
.login-form .el-input {
  height: 40px;
  input {
    height: 40px;
  }
}
.login-form .input-icon {
  height: 41px;
  width: 14px;
  margin-left: 2px;
}
.login-options {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin: 0 0 18px 0;
}
.forgot-link {
  color: #409eff;
  font-size: 13px;
  cursor: pointer;
}
.login-code {
  width: 33%;
  height: 40px;
  float: right;
  img {
    cursor: pointer;
    vertical-align: middle;
  }
}
.login-code-img {
  height: 40px;
}
.other-login {
  display: flex;
  align-items: center;
  margin: 20px 0 14px 0;
}
.other-divider {
  flex: 1;
  height: 1px;
  background: #e4e7ed;
}
.other-label {
  padding: 0 12px;
  font-size: 13px;
  color: #909399;
}
.other-btns {
  display: flex;
  justify-content: center;
}
.other-btn {
  margin: 0 10px;
  padding: 7px 22px;
  border: 1px solid #d9d9d9;
  border-radius: 4px;
  font-size: 13px;
  color: #303133;
  cursor: pointer;
  transition: all 0.2s;
}
.other-btn:hover {
  border-color: #0F3460;
  color: #0F3460;
}
.copyright {
  position: absolute;
  bottom: 22px;
  left: 0;
  width: 100%;
  text-align: center;
  color: #909399;
  font-size: 12px;
  letter-spacing: 1px;
}

/* ===== 移动端适配 ===== */
@media (max-width: 900px) {
  .login {
    flex-direction: column;
  }
  .brand-panel {
    flex: 0 0 auto;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    padding: 46px 20px 40px 20px;
  }
  .brand-top {
    margin-bottom: 22px;
  }
  .brand-main {
    align-items: center;
  }
  .brand-title {
    font-size: 30px;
    margin-bottom: 12px;
  }
  .brand-slogan {
    font-size: 15px;
    text-align: center;
  }
  .login-panel {
    padding: 36px 20px 64px 20px;
  }
  .login-box {
    width: 100%;
  }
  .welcome-title {
    font-size: 24px;
  }
}
</style>

LOGIN_EOF
    ok "登录页已按骏通版效果图重构（左侧品牌区 + 右侧登录表单，支持移动端）"

    # 5) 加载页深蓝背景
    sed -i "s|background: #.*;|background: $PRIMARY_COLOR;|" "$ui/public/index.html" 2>/dev/null || true
    ok "加载页背景已更新"

    # 6) 系统页面设计稿定制（严格按 10 张系统页面设计稿：全部页面实现）
    apply_ui_custom "$ui"

    # 7) 补充"检验结果"菜单（设计稿 05 质量管理=检验单页；qcresult 页面源码存在但原库未挂菜单）
    add_qcresult_menu

    ok "骏通-MES 品牌定制应用完成"
}

# ======================= 系统页面设计稿定制：apply_ui_custom =======================
# 按交付包 03_系统页面设计稿 10 张图：全局统一风格 + 工作台 + 条码追溯 + 8 个模块页面全部实现
apply_ui_custom() {
    local ui="${1:-$FRONTEND_DIR}"
    if [ ! -d "$ui" ]; then
        warn "前端目录不存在，跳过系统页面定制：$ui"
        return 1
    fi
    step "应用系统页面设计稿定制（10 张设计稿全部实现）"

    # 6.1 全局统一风格（design.scss，所有模块页面自动美化）
    cat > "$ui/src/assets/styles/design.scss" <<'UI_DESIGN_EOF'
/* ============================================================
   骏通-MES 系统页面统一风格（严格按照设计稿：蓝白工业风）
   全局美化层：所有功能模块页面自动继承该风格
   ============================================================ */

/* ---- 品牌变量 ---- */
$jt-primary: #0F3460;      /* 主色：工业深蓝 */
$jt-primary-light: #1d4e89;
$jt-success: #10b981;      /* 成功 */
$jt-warning: #f59e0b;      /* 警告 */
$jt-danger: #ef4444;       /* 危险 */
$jt-info: #64748b;
$jt-bg: #eef1f6;           /* 页面背景：浅灰蓝 */
$jt-card-bg: #ffffff;      /* 卡片背景 */
$jt-border: #e8ecf3;       /* 卡片边框 */
$jt-text: #1f2d3d;         /* 主文字 */
$jt-text-sub: #8a94a6;     /* 次要文字 */
$jt-radius: 10px;
$jt-shadow: 0 1px 4px rgba(15, 52, 96, 0.08);

/* ---- 页面整体背景 ---- */
#app .app-main {
  background: $jt-bg;
}
.app-container {
  background: transparent;
  padding: 16px;
}

/* ---- 页面标题栏（设计稿顶部标题） ---- */
.jt-page-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 16px;
  padding: 14px 18px;
  background: $jt-card-bg;
  border: 1px solid $jt-border;
  border-radius: $jt-radius;
  box-shadow: $jt-shadow;
}
.jt-page-title {
  font-size: 18px;
  font-weight: 600;
  color: $jt-text;
  display: flex;
  align-items: center;
  gap: 8px;
}
.jt-page-title::before {
  content: '';
  width: 4px;
  height: 18px;
  background: $jt-primary;
  border-radius: 2px;
}
.jt-page-sub {
  font-size: 13px;
  color: $jt-text-sub;
  margin-top: 2px;
}

/* ---- 统计卡片（设计稿 4 指标卡） ---- */
.jt-stat-cards {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
  margin-bottom: 16px;
}
.jt-stat-card {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 20px;
  background: $jt-card-bg;
  border: 1px solid $jt-border;
  border-radius: $jt-radius;
  box-shadow: $jt-shadow;
  transition: all .2s;
}
.jt-stat-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 6px 16px rgba(15, 52, 96, 0.12);
}
.jt-stat-icon {
  width: 52px;
  height: 52px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 24px;
  color: #fff;
  flex-shrink: 0;
}
.jt-stat-icon.is-primary { background: linear-gradient(135deg, #0F3460, #1d4e89); }
.jt-stat-icon.is-success { background: linear-gradient(135deg, #10b981, #34d399); }
.jt-stat-icon.is-warning { background: linear-gradient(135deg, #f59e0b, #fbbf24); }
.jt-stat-icon.is-danger  { background: linear-gradient(135deg, #ef4444, #f87171); }
.jt-stat-icon.is-info    { background: linear-gradient(135deg, #64748b, #94a3b8); }
.jt-stat-body .jt-stat-value {
  font-size: 26px;
  font-weight: 700;
  color: $jt-text;
  line-height: 1.1;
}
.jt-stat-body .jt-stat-label {
  font-size: 13px;
  color: $jt-text-sub;
  margin-top: 6px;
}
.jt-stat-body .jt-stat-trend {
  font-size: 12px;
  margin-top: 4px;
}
.jt-stat-trend.up { color: $jt-success; }
.jt-stat-trend.down { color: $jt-danger; }

/* ---- 功能按钮区（设计稿顶部标签式按钮） ---- */
.jt-func-buttons {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-bottom: 16px;
  padding: 14px 18px;
  background: $jt-card-bg;
  border: 1px solid $jt-border;
  border-radius: $jt-radius;
  box-shadow: $jt-shadow;
}
.jt-func-btn {
  padding: 8px 18px;
  border-radius: 6px;
  border: 1px solid $jt-border;
  background: #f5f8fc;
  color: $jt-text;
  font-size: 14px;
  cursor: pointer;
  transition: all .2s;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.jt-func-btn i { font-size: 15px; }
.jt-func-btn:hover {
  border-color: $jt-primary;
  color: $jt-primary;
  background: #f0f5fb;
}
.jt-func-btn.is-active {
  background: $jt-primary;
  border-color: $jt-primary;
  color: #fff;
  box-shadow: 0 2px 8px rgba(15, 52, 96, 0.3);
}

/* ---- 卡片容器（设计稿图表/面板/表格容器） ---- */
.jt-card {
  background: $jt-card-bg;
  border: 1px solid $jt-border;
  border-radius: $jt-radius;
  box-shadow: $jt-shadow;
  padding: 16px;
  margin-bottom: 16px;
}
.jt-card-title {
  font-size: 15px;
  font-weight: 600;
  color: $jt-text;
  margin-bottom: 14px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.jt-card-title::before {
  content: '';
  width: 4px;
  height: 16px;
  background: $jt-primary;
  border-radius: 2px;
}
.jt-grid-2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
}
.jt-grid-3 {
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  gap: 16px;
}

/* ---- Element 表格统一美化 ---- */
.el-table {
  border-radius: 8px;
  overflow: hidden;
  color: $jt-text;
}
.el-table th {
  background: #f0f5fb !important;
  color: #1f2d3d !important;
  font-weight: 600 !important;
  border-bottom: 1px solid #dfe6f0 !important;
}
.el-table--enable-row-hover .el-table__body tr:hover > td {
  background: #f7faff !important;
}
.el-table__body tr td {
  border-bottom: 1px solid #f0f3f8;
}
.el-table::before {
  background: transparent;
}

/* ---- Element 按钮统一（主色深蓝） ---- */
.el-button--primary {
  background-color: $jt-primary;
  border-color: $jt-primary;
}
.el-button--primary:hover,
.el-button--primary:focus {
  background-color: $jt-primary-light;
  border-color: $jt-primary-light;
}
.el-button--primary.is-plain {
  color: $jt-primary;
  border-color: #9db4d0;
  background: #f0f5fb;
}
.el-button--primary.is-plain:hover,
.el-button--primary.is-plain:focus {
  background: $jt-primary;
  border-color: $jt-primary;
  color: #fff;
}

/* ---- Element 标签/徽标统一 ---- */
.el-tag--success { background: #ecfdf5; border-color: #a7f3d0; color: #059669; }
.el-tag--warning { background: #fffbeb; border-color: #fde68a; color: #d97706; }
.el-tag--danger  { background: #fef2f2; border-color: #fecaca; color: #dc2626; }
.el-tag--info    { background: #f1f5f9; border-color: #e2e8f0; color: #475569; }

/* ---- Element 输入框/选择器统一 ---- */
.el-input__inner,
.el-textarea__inner {
  border-radius: 6px;
}
.el-input__inner:focus,
.el-textarea__inner:focus {
  border-color: $jt-primary;
}

/* ---- Element 分页 ---- */
.el-pagination.is-background .el-pager li:not(.disabled).active {
  background-color: $jt-primary;
}

/* ---- Element 卡片/弹窗 ---- */
.el-card {
  border-radius: $jt-radius;
  border-color: $jt-border;
}
.el-dialog {
  border-radius: $jt-radius;
}
.el-tabs__item.is-active {
  color: $jt-primary;
}
.el-tabs__active-bar {
  background-color: $jt-primary;
}

/* ---- Element 进度条（设计稿环形进度用主色） ---- */
.el-progress-circle .el-progress__text {
  color: $jt-text !important;
}

/* ---- 设备状态面板（设计稿 06/01） ---- */
.jt-device-panel {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}
.jt-device-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 14px;
  background: #f7faff;
  border: 1px solid $jt-border;
  border-radius: 8px;
}
.jt-device-name {
  font-size: 14px;
  font-weight: 600;
  color: $jt-text;
  display: flex;
  align-items: center;
  gap: 8px;
}
.jt-device-name .dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  display: inline-block;
}
.dot.is-run { background: $jt-success; }
.dot.is-idle { background: $jt-warning; }
.dot.is-maint { background: $jt-danger; }
.jt-device-status {
  font-size: 13px;
  color: $jt-text-sub;
}
.jt-device-status .up { color: $jt-success; }
.jt-device-status .mid { color: $jt-warning; }
.jt-device-status .down { color: $jt-danger; }

/* ---- 待处理事项/流程步骤（设计稿 07 追溯流程） ---- */
.jt-flow-steps {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 4px;
}
.jt-flow-step {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
}
.jt-flow-step .step-node {
  width: 46px;
  height: 46px;
  border-radius: 50%;
  background: #f0f5fb;
  border: 2px solid #d5deeb;
  color: $jt-text-sub;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 18px;
  transition: all .3s;
}
.jt-flow-step .step-text {
  font-size: 13px;
  color: $jt-text-sub;
  white-space: nowrap;
}
.jt-flow-step.is-active .step-node {
  background: $jt-primary;
  border-color: $jt-primary;
  color: #fff;
  box-shadow: 0 4px 12px rgba(15, 52, 96, 0.35);
}
.jt-flow-step.is-active .step-text {
  color: $jt-primary;
  font-weight: 600;
}
.jt-flow-line {
  flex: 1;
  height: 2px;
  background: #d5deeb;
  margin: 0 6px;
  position: relative;
  top: -14px;
}
.jt-flow-line.is-done {
  background: $jt-primary;
}

/* ---- 响应式 ---- */
@media (max-width: 1280px) {
  .jt-stat-cards { grid-template-columns: repeat(2, 1fr); }
  .jt-grid-2, .jt-grid-3 { grid-template-columns: 1fr; }
}
@media (max-width: 768px) {
  .jt-stat-cards { grid-template-columns: 1fr; }
  .jt-device-panel { grid-template-columns: 1fr; }
  .jt-flow-steps { overflow-x: auto; }
}

UI_DESIGN_EOF
    if ! grep -q "design.scss" "$ui/src/main.js"; then
        sed -i "s|import '@/assets/styles/ruoyi.scss'.*|&\nimport '@/assets/styles/design.scss' // juntong design|" "$ui/src/main.js" 2>/dev/null || true
    fi
    ok "全局统一风格已应用（蓝白工业风，所有功能模块自动美化）"

    # 6.2 工作台首页（设计稿 01：指标卡 + 生产进度 + 设备状态 + 待处理事项）
    cat > "$ui/src/views/index.vue" <<'UI_INDEX_EOF'
<template>
  <div class="jt-dashboard app-container">
    <!-- 顶部统计指标卡（设计稿：今日工单 / 已完成 / 良品率 / 设备综合效率） -->
    <div class="jt-stat-cards">
      <div class="jt-stat-card">
        <div class="jt-stat-icon is-primary"><i class="el-icon-document"></i></div>
        <div class="jt-stat-body">
          <div class="jt-stat-value">{{ todayCount }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">单</span></div>
          <div class="jt-stat-label">今日工单</div>
        </div>
      </div>
      <div class="jt-stat-card">
        <div class="jt-stat-icon is-success"><i class="el-icon-circle-check"></i></div>
        <div class="jt-stat-body">
          <div class="jt-stat-value">{{ completedCount }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">单</span></div>
          <div class="jt-stat-label">已完成</div>
        </div>
      </div>
      <div class="jt-stat-card">
        <div class="jt-stat-icon is-warning"><i class="el-icon-medal"></i></div>
        <div class="jt-stat-body">
          <div class="jt-stat-value">{{ qualityRate }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div>
          <div class="jt-stat-label">良品率</div>
        </div>
      </div>
      <div class="jt-stat-card">
        <div class="jt-stat-icon is-info"><i class="el-icon-odometer"></i></div>
        <div class="jt-stat-body">
          <div class="jt-stat-value">{{ oee }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div>
          <div class="jt-stat-label">设备综合效率</div>
        </div>
      </div>
    </div>

    <!-- 中部：生产进度 + 设备状态（设计稿：柱状折线组合图 + 设备状态面板） -->
    <div class="jt-grid-2">
      <div class="jt-card">
        <div class="jt-card-title">生产进度</div>
        <div ref="progressChart" style="height:300px;width:100%;"></div>
      </div>
      <div class="jt-card">
        <div class="jt-card-title">设备状态</div>
        <div class="jt-device-panel">
          <div v-for="(d, i) in deviceList" :key="i" class="jt-device-item">
            <span class="jt-device-name">
              <span class="dot" :class="d.dotClass"></span>{{ d.name }}
            </span>
            <span class="jt-device-status">
              <span :class="d.statusClass">{{ d.statusText }}</span>
            </span>
          </div>
        </div>
        <el-empty v-if="deviceList.length === 0" description="暂无设备数据" :image-size="60" />
      </div>
    </div>

    <!-- 底部：待处理事项表（设计稿：任务 / 类型 / 负责人 / 截止时间 / 状态） -->
    <div class="jt-card">
      <div class="jt-card-title">待处理事项</div>
      <el-table v-loading="loading" :data="todoList" style="width:100%">
        <el-table-column label="任务" prop="task" min-width="160" />
        <el-table-column label="类型" prop="type" width="120" align="center" />
        <el-table-column label="负责人" prop="owner" width="100" align="center" />
        <el-table-column label="截止时间" prop="deadline" width="120" align="center" />
        <el-table-column label="状态" prop="status" width="120" align="center">
          <template slot-scope="scope">
            <el-tag :type="scope.row.tagType" size="mini">{{ scope.row.status }}</el-tag>
          </template>
        </el-table-column>
      </el-table>
    </div>
  </div>
</template>

<script>
import echarts from 'echarts'
import { getHomeList } from "@/api/mes/pro/workorder";
import { listMachinery } from "@/api/mes/dv/machinery";

export default {
  name: 'JtDashboard',
  data() {
    return {
      loading: true,
      queryParams: { status: 'CONFIRMED' },
      workorderList: [],
      deviceList: [],
      // 统计指标
      todayCount: 0,
      completedCount: 0,
      qualityRate: 98.6,
      oee: 84.2,
      // 待处理事项（设计稿示例，业务真实数据由各模块处理）
      todoList: [
        { task: '工序报工', type: '生产', owner: '张工', deadline: '2026-10-06', status: '待处理', tagType: 'warning' },
        { task: '设备点检', type: '设备', owner: '王强', deadline: '2026-10-06', status: '进行中', tagType: 'success' },
        { task: '质量异常处理', type: '质量', owner: '赵敏', deadline: '2026-10-06', status: '紧急', tagType: 'danger' }
      ]
    }
  },
  created() {
    this.getList();
    this.getDevices();
  },
  mounted() {
    this.$nextTick(() => {
      this.initChart();
    });
  },
  methods: {
    /** 工单数据（真实） */
    getList() {
      getHomeList(this.queryParams).then(response => {
        this.workorderList = response.data || [];
        this.loading = false;
        this.todayCount = this.workorderList.length;
        this.completedCount = this.workorderList.filter(w =>
          (w.status && String(w.status).toUpperCase().indexOf('COMP') > -1) ||
          (w.quantity && w.quantityProduced && Number(w.quantityProduced) >= Number(w.quantity))
        ).length;
        this.$nextTick(() => this.initChart());
      }).catch(() => { this.loading = false; });
    },
    /** 设备数据（真实） */
    getDevices() {
      listMachinery({ pageNum: 1, pageSize: 4 }).then(response => {
        const rows = response.rows || [];
        if (rows.length) {
          this.deviceList = rows.map(m => this.mapDevice(m));
        } else {
          this.deviceList = this.sampleDevices();
        }
      }).catch(() => {
        this.deviceList = this.sampleDevices();
      });
    },
    /** 设备状态映射 */
    mapDevice(m) {
      const name = m.machineryName || m.machineryCode || m.machineryNo || '设备';
      let statusText = '待机', dotClass = 'is-idle', statusClass = 'mid';
      if (m.status === 1) { statusText = '运行中'; dotClass = 'is-run'; statusClass = 'up'; }
      else if (m.status === 2 || m.status === 3) { statusText = '维护中'; dotClass = 'is-maint'; statusClass = 'down'; }
      return { name, statusText, dotClass, statusClass };
    },
    /** 无设备数据时的设计稿示例 */
    sampleDevices() {
      return [
        { name: '设备A', statusText: '运行中', dotClass: 'is-run', statusClass: 'up' },
        { name: '设备B', statusText: '待机', dotClass: 'is-idle', statusClass: 'mid' },
        { name: '设备C', statusText: '维护中', dotClass: 'is-maint', statusClass: 'down' },
        { name: '设备D', statusText: '运行中', dotClass: 'is-run', statusClass: 'up' }
      ];
    },
    /** 生产进度组合图（柱状=已完成数量，折线=完成率%） */
    initChart() {
      const el = this.$refs.progressChart;
      if (!el) return;
      let chart = echarts.getInstanceByDom(el);
      if (chart) { chart.dispose(); }
      chart = echarts.init(el);

      let names = [], planned = [], done = [], rate = [];
      const list = this.workorderList.slice(0, 8);
      if (list.length) {
        list.forEach(w => {
          names.push(w.workorderCode || w.workorderName || '工单');
          const q = Number(w.quantity) || 0;
          const p = Number(w.quantityProduced) || 0;
          planned.push(q);
          done.push(p);
          rate.push(q ? Number(((p / q) * 100).toFixed(1)) : 0);
        });
      } else {
        // 设计稿示例数据
        names = ['WO-01', 'WO-02', 'WO-03', 'WO-04', 'WO-05', 'WO-06'];
        planned = [500, 300, 480, 260, 400, 350];
        done = [380, 210, 374, 180, 320, 96];
        rate = done.map((d, i) => Number(((d / planned[i]) * 100).toFixed(1)));
      }

      chart.setOption({
        tooltip: { trigger: 'axis' },
        legend: { data: ['计划数量', '已完成', '完成率'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 40, bottom: 10, top: 40, containLabel: true },
        xAxis: {
          type: 'category',
          data: names,
          axisLine: { lineStyle: { color: '#d5deeb' } },
          axisLabel: { color: '#64748b', interval: 0, rotate: 20, fontSize: 11 }
        },
        yAxis: [
          { type: 'value', name: '数量', nameTextStyle: { color: '#8a94a6' }, axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
          { type: 'value', name: '完成率%', min: 0, max: 100, axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { show: false } }
        ],
        series: [
          {
            name: '计划数量', type: 'bar', barWidth: 18, data: planned,
            itemStyle: { color: '#dbe4f2', borderRadius: [4, 4, 0, 0] }
          },
          {
            name: '已完成', type: 'bar', barWidth: 18, data: done,
            itemStyle: { color: '#0F3460', borderRadius: [4, 4, 0, 0] }
          },
          {
            name: '完成率', type: 'line', yAxisIndex: 1, smooth: true, data: rate,
            symbol: 'circle', symbolSize: 6,
            lineStyle: { color: '#10b981', width: 3 },
            itemStyle: { color: '#10b981' }
          }
        ]
      });
    }
  }
}
</script>

<style lang="scss" scoped>
.jt-dashboard {
  background: #eef1f6;
  min-height: 100%;
}
</style>

UI_INDEX_EOF
    ok "工作台首页已按设计稿重构（4 指标卡 + 生产进度组合图 + 设备状态 + 待处理事项）"

    # 6.3 条码追溯（设计稿 07：搜索 + 生产全流程步骤图 + 批次信息 + 追溯明细）
    cat > "$ui/src/views/mes/qc/batchtrace/index.vue" <<'UI_BATCH_EOF'
<template>
  <div class="app-container">
    <!-- 搜索区（设计稿：批次号/条码号/工单号 查询） -->
    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">条码追溯</div>
        <div class="jt-page-sub">按批次号 / 条码号 / 工单号查询物料流转全流程</div>
      </div>
    </div>
    <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="90px" class="jt-card" style="padding:14px 18px;">
      <el-form-item label="批次号" prop="batchCode">
        <el-input
          v-model="queryParams.batchCode"
          placeholder="请输入批次号"
          clearable
          style="width:180px"
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="产品物料编码" prop="itemCode">
        <el-input
          v-model="queryParams.itemCode"
          placeholder="请输入产品物料编码"
          clearable
          style="width:180px"
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="产品物料名称" prop="itemName">
        <el-input
          v-model="queryParams.itemName"
          placeholder="请输入产品物料名称"
          clearable
          style="width:180px"
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="销售订单编号" prop="coCode">
        <el-input
          v-model="queryParams.coCode"
          placeholder="请输入销售订单编号"
          clearable
          style="width:180px"
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="采购订单编号" prop="poCode">
        <el-input
          v-model="queryParams.poCode"
          placeholder="请输入采购订单编号"
          clearable
          style="width:180px"
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item>
        <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">查询</el-button>
        <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
      </el-form-item>
    </el-form>

    <!-- 批次列表 -->
    <div class="jt-card" style="padding:0 16px 16px;">
      <div class="jt-card-title" style="padding-top:16px;">批次列表</div>
      <el-table v-loading="loading" :data="batchList" @selection-change="handleSelectionChange">
        <el-table-column label="批次编号" align="center" prop="batchCode" />
        <el-table-column label="产品物料编码" align="center" prop="itemCode" />
        <el-table-column label="产品物料名称" align="center" prop="itemName" :show-overflow-tooltip="true" />
        <el-table-column label="规格型号" align="center" prop="specification" :show-overflow-tooltip="true" />
        <el-table-column label="单位" align="center" prop="unitName" />
        <el-table-column label="供应商" align="center" prop="vendorName" :show-overflow-tooltip="true" />
        <el-table-column label="客户" align="center" prop="clientName" :show-overflow-tooltip="true" />
        <el-table-column label="操作" align="center" class-name="small-padding fixed-width">
          <template slot-scope="scope">
            <el-button
              size="mini"
              type="primary"
              plain
              icon="el-icon-aim"
              @click="handleTrace(scope.row)"
              v-hasPermi="['mes:wm:batch:query']"
            >批次追溯</el-button>
          </template>
        </el-table-column>
      </el-table>

      <pagination
        v-show="total>0"
        :total="total"
        :page.sync="queryParams.pageNum"
        :limit.sync="queryParams.pageSize"
        @pagination="getList"
      />
    </div>

    <!-- 批次追溯弹窗（设计稿：批次信息面板 + 生产全流程步骤图 + 向前/向后追溯） -->
    <el-dialog :title="title" :visible.sync="open" width="1100px" append-to-body>
      <!-- 批次信息面板 -->
      <div class="jt-card">
        <div class="jt-card-title">批次信息</div>
        <div class="jt-trace-info">
          <div class="jt-info-item">
            <span class="jt-info-label">批次号</span>
            <span class="jt-info-value">{{ form.batchCode }}</span>
          </div>
          <div class="jt-info-item">
            <span class="jt-info-label">物料名称</span>
            <span class="jt-info-value">{{ form.itemName }}</span>
          </div>
          <div class="jt-info-item">
            <span class="jt-info-label">规格</span>
            <span class="jt-info-value">{{ form.specification }}</span>
          </div>
          <div class="jt-info-item">
            <span class="jt-info-label">数量</span>
            <span class="jt-info-value">{{ form.quantity || form.produceQuantity || '-' }}</span>
          </div>
          <div class="jt-info-item">
            <span class="jt-info-label">供应商</span>
            <span class="jt-info-value">{{ form.vendorName || '-' }}</span>
          </div>
          <div class="jt-info-item">
            <span class="jt-info-label">客户</span>
            <span class="jt-info-value">{{ form.clientName || '-' }}</span>
          </div>
        </div>
      </div>

      <!-- 生产全流程步骤图（设计稿：原材料入库→车间领用→工序加工→质量检验→成品入库） -->
      <div class="jt-card">
        <div class="jt-card-title">生产全流程追溯</div>
        <div class="jt-flow-steps">
          <template v-for="(s, i) in flowSteps">
            <div class="jt-flow-step" :key="'s' + i" :class="{ 'is-active': i === activeStep }">
              <div class="step-node"><i :class="s.icon"></i></div>
              <div class="step-text">{{ s.name }}</div>
            </div>
            <div
              v-if="i < flowSteps.length - 1"
              :key="'l' + i"
              class="jt-flow-line"
              :class="{ 'is-done': i < activeStep }"
            ></div>
          </template>
        </div>
      </div>

      <!-- 追溯明细 -->
      <el-tabs type="border-card">
        <el-tab-pane label="向前追溯">
          <forward :batchId="form.batchId" :batchCode="form.batchCode"></forward>
        </el-tab-pane>
        <el-tab-pane label="向后追溯">
          <backward :batchId="form.batchId" :batchCode="form.batchCode"></backward>
        </el-tab-pane>
      </el-tabs>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="cancel">关 闭</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listBatch, getBatch } from "@/api/mes/wm/batch";
import forward from "./forward.vue";
import backward from "./backward.vue";
export default {
  name: "Batch",
  components: { forward, backward },
  data() {
    return {
      // 遮罩层
      loading: true,
      // 显示搜索条件
      showSearch: true,
      // 总条数
      total: 0,
      // 批次记录表格数据
      batchList: [],
      // 弹出层标题
      title: "",
      // 是否显示弹出层
      open: false,
      // 生产全流程步骤（设计稿）
      flowSteps: [
        { name: '原材料入库', icon: 'el-icon-box' },
        { name: '车间领用', icon: 'el-icon-shopping-cart' },
        { name: '工序加工', icon: 'el-icon-setting' },
        { name: '质量检验', icon: 'el-icon-search' },
        { name: '成品入库', icon: 'el-icon-finished' }
      ],
      activeStep: 2,
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        batchCode: null,
        itemCode: null,
        itemName: null,
        specification: null,
        unitOfMeasure: null,
        vendorCode: null,
        vendorName: null,
        clientCode: null,
        clientName: null,
        coCode: null,
        poCode: null,
        workorderCode: null,
        productCode: null,
        qualityStatus: null
      },
      // 表单参数
      form: {},
      // 表单校验
      rules: {
        batchCode: [
          { required: true, message: "批次编号不能为空", trigger: "blur" }
        ],
        itemId: [
          { required: true, message: "产品物料ID不能为空", trigger: "blur" }
        ]
      }
    };
  },
  created() {
    this.getList();
  },
  methods: {
    /** 查询批次记录列表 */
    getList() {
      this.loading = true;
      listBatch(this.queryParams).then(response => {
        this.batchList = response.rows;
        this.total = response.total;
        this.loading = false;
      });
    },
    // 取消按钮
    cancel() {
      this.open = false;
      this.reset();
    },
    // 表单重置
    reset() {
      this.form = {
        batchId: null, batchCode: null, itemId: null, itemCode: null,
        itemName: null, specification: null, unitOfMeasure: null,
        vendorCode: null, vendorName: null, clientCode: null, clientName: null,
        coCode: null, poCode: null, workorderId: null, workorderCode: null,
        productCode: null, qualityStatus: "0", remark: null
      };
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.batchId);
    },
    /** 追溯按钮操作 */
    handleTrace(row) {
      this.reset();
      const batchId = row.batchId || this.ids;
      getBatch(batchId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "批次追溯";
        // 根据批次是否有质量记录高亮对应环节（无记录默认高亮工序加工）
        if (response.data.qualityStatus && String(response.data.qualityStatus) !== '0') {
          this.activeStep = 3;
        } else {
          this.activeStep = 2;
        }
      });
    }
  }
};
</script>

<style lang="scss" scoped>
.jt-trace-info {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px 20px;
}
.jt-info-item {
  display: flex;
  align-items: baseline;
  font-size: 14px;
}
.jt-info-label {
  color: #8a94a6;
  width: 64px;
  flex-shrink: 0;
}
.jt-info-value {
  color: #1f2d3d;
  font-weight: 500;
  word-break: break-all;
}
@media (max-width: 768px) {
  .jt-trace-info { grid-template-columns: 1fr; }
}
</style>

UI_BATCH_EOF
    ok "条码追溯已按设计稿重构（流程步骤图 + 批次信息面板）"

    # 6.4 八个模块页面按设计稿实现（02 主数据 / 03 仓储 / 04 生产 / 05 质量 / 06 设备 / 08 排班 / 09 监控 / 10 系统管理）
    apply_module_pages "$ui"

    ok "系统页面设计稿定制应用完成（10 张设计稿全部实现）"
}

# ======================= 8 个模块页面按设计稿注入 =======================
apply_module_pages() {
    local ui="${1:-$FRONTEND_DIR}"

    cat > "$ui/src/views/mes/wm/wmstock/index.vue" <<'UI_MOD_WMSTOCK_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">仓储管理</div>
        <div class="jt-page-sub">实时掌握库存动态与仓库分布</div>
      </div>
    </div>
    <div class="jt-func-buttons">
      <span class="jt-func-btn" @click="go('/mes/wm/itemrecpt')"><i class="el-icon-download"></i>入库单</span>
      <span class="jt-func-btn" @click="go('/mes/wm/issue')"><i class="el-icon-upload2"></i>出库单</span>
      <span class="jt-func-btn is-active"><i class="el-icon-search"></i>库存查询</span>
      <span class="jt-func-btn" @click="warnOnly"><i class="el-icon-warning-outline"></i>库存预警</span>
    </div>
    <div class="jt-stat-cards">
      <div class="jt-stat-card"><div class="jt-stat-icon is-primary"><i class="el-icon-box"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.stockTotal.toLocaleString() }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">件</span></div><div class="jt-stat-label">当前库存</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-success"><i class="el-icon-download"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.inToday.toLocaleString() }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">件</span></div><div class="jt-stat-label">今日入库</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-warning"><i class="el-icon-upload2"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.outToday.toLocaleString() }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">件</span></div><div class="jt-stat-label">今日出库</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-danger"><i class="el-icon-warning"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.warnCount }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">项</span></div><div class="jt-stat-label">库存预警</div></div></div>
    </div>
    <div class="jt-grid-2">
      <div class="jt-card"><div class="jt-card-title">库存趋势</div><div ref="jtChart1" style="height:280px;width:100%;"></div></div>
      <div class="jt-card"><div class="jt-card-title">仓库分布</div><div ref="jtChart2" style="height:280px;width:100%;"></div></div>
    </div>

    <el-row :gutter="20">
      <el-col :span="4" :xs="24">
        <div class="head-container">
          <el-input
            v-model="itemTypeName"
            placeholder="请输入分类名称"
            clearable
            size="small"
            prefix-icon="el-icon-search"
            style="margin-bottom: 20px"
          />
        </div>
        <div class="head-container">
          <el-tree
            :data="itemTypeOptions"
            :props="defaultProps"
            :expand-on-click-node="false"
            :filter-node-method="filterNode"
            ref="tree"
            default-expand-all
            @node-click="handleNodeClick"
          />
        </div>
      </el-col>
      <el-col :span="20" :xs="24">

      <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="100px">
        <el-form-item label="产品物料编码" prop="itemCode">
          <el-input
            v-model="queryParams.itemCode"
            placeholder="请输入产品物料编码"
            clearable
            @keyup.enter.native="handleQuery"
          />
        </el-form-item>
        <el-form-item label="产品物料名称" prop="itemName">
          <el-input
            v-model="queryParams.itemName"
            placeholder="请输入产品物料名称"
            clearable
            @keyup.enter.native="handleQuery"
          />
        </el-form-item>
        <el-form-item label="批次号" prop="batchCode">
          <el-input
            v-model="queryParams.batchCode"
            placeholder="请输入批次号"
            clearable
            @keyup.enter.native="handleQuery"
          />
        </el-form-item>
        <el-form-item label="仓库名称" prop="warehouseName">
          <el-input
            v-model="queryParams.warehouseName"
            placeholder="请输入仓库名称"
            clearable
            @keyup.enter.native="handleQuery"
          />
        </el-form-item>
        <el-form-item label="库区名称" prop="locationName">
          <el-input
            v-model="queryParams.locationName"
            placeholder="请输入库区名称"
            clearable
            @keyup.enter.native="handleQuery"
          />
        </el-form-item>
        <el-form-item label="库位编码" prop="areaCode">
          <el-input
            v-model="queryParams.areaCode"
            placeholder="请输入库位编码"
            clearable
            @keyup.enter.native="handleQuery"
          />
        </el-form-item>
        <el-form-item label="是否冻结" prop="frozenFlag">
          <el-select v-model="queryParams.frozenFlag" placeholder="请选择">
            <el-option
              v-for="dict in dict.type.sys_yes_no"
              :key="dict.value"
              :label="dict.label"
              :value="dict.value"
            ></el-option>
          </el-select>
        </el-form-item>
        <el-form-item>
          <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">搜索</el-button>
          <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
        </el-form-item>
      </el-form>

      <el-row :gutter="10" class="mb8">    
        <el-col :span="1.5">
          <el-button
            type="warning"
            plain
            icon="el-icon-download"
            size="mini"
            @click="handleExport"
            v-hasPermi="['mes:wm:wmstock:export']"
          >导出</el-button>
        </el-col>
        <right-toolbar :showSearch.sync="showSearch" @queryTable="getList"></right-toolbar>
      </el-row>

      <el-table v-loading="loading" :data="wmstockList" @selection-change="handleSelectionChange">
        <el-table-column type="selection" width="55" align="center" />
        <el-table-column label="产品物料编码" width="120px" align="center" prop="itemCode" />
        <el-table-column label="产品物料名称" width="150px" align="center" prop="itemName" :show-overflow-tooltip="true"/>
        <el-table-column label="规格型号" align="center" prop="specification" :show-overflow-tooltip="true"/>
        <el-table-column label="在库数量" align="center" prop="quantityOnhand" />
        <el-table-column label="单位" align="center" prop="unitName" />
        <el-table-column label="批次号" width="150px" align="center" prop="batchCode" :show-overflow-tooltip="true">
          <template slot-scope="scope">
            <el-button
              type="text"
              @click="handleBatchClick(scope.row)"
            >{{scope.row.batchCode}}</el-button>
          </template>
        </el-table-column>
        <el-table-column label="仓库" align="center" prop="warehouseName" />
        <el-table-column label="库区" align="center" prop="locationName" />
        <el-table-column label="库位" align="center" prop="areaName" >
          <template slot-scope="scope">
          <el-button
            type="text"
            @click="handleAreaClick(scope.row)"
          >{{scope.row.areaName}}</el-button>
        </template>
        </el-table-column>
        <el-table-column label="入库日期" align="center" prop="recptDate" width="120">
          <template slot-scope="scope">
            <span>{{ parseTime(scope.row.recptDate, '{y}-{m}-{d}') }}</span>
          </template>
        </el-table-column>
        <el-table-column label="是否冻结" align="center" width="100">
          <template slot-scope="scope">
            <el-switch
              v-model="scope.row.frozenFlag"
              active-text="是"
              inactive-text="否"
              active-value="Y"
              inactive-value="N"
              @change="handleFrozenChange(scope.row)"
            ></el-switch>
          </template>
        </el-table-column>
      </el-table>
    
      <pagination
        v-show="total>0"
        :total="total"
        :page.sync="queryParams.pageNum"
        :limit.sync="queryParams.pageSize"
        @pagination="getList"
      />
      </el-col>
    </el-row>

 <!-- 添加或修改库位设置对话框 -->
 <el-dialog title="储位详情" :visible.sync="open" width="960px" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="120px">
        <el-row>
          <el-col :span="14">
            <el-row>
              <el-col :span="16">
                <el-form-item label="库位编码" prop="areaCode">
                  <el-input v-model="form.areaCode" readonly="readonly" maxlength="64"/>
                </el-form-item>
              </el-col>
              <el-col :span="8">

              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="库位名称" prop="areaName">
                  <el-input v-model="form.areaName" readonly="readonly" maxlength="255"/>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="12">
                <el-form-item label="面积" prop="area">
                  <el-input-number :min="0" :max="99999999" :step="1" :percision="2" v-model="form.area" readonly="readonly" />
                </el-form-item>
              </el-col>
              <el-col :span="12">
                <el-form-item label="最大载重量" prop="maxLoa">
                  <el-input-number v-model="form.maxLoa" :max="99999999" :step="1" :percision="2" readonly="readonly" />
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="12">
                <el-form-item label="允许产品混放" prop="productMixing">
                  <el-radio-group v-model="form.productMixing">
                    <el-radio
                      v-for="dict in dict.type.sys_yes_no"
                      :key="dict.value"
                      :label="dict.value"
                    >{{dict.label}}</el-radio>
                  </el-radio-group>
                </el-form-item>
              </el-col>
              <el-col :span="12">
                <el-form-item label="允许批次混放" prop="batchMixing">
                  <el-radio-group v-model="form.batchMixing">
                    <el-radio
                      v-for="dict in dict.type.sys_yes_no"
                      :key="dict.value"
                      :label="dict.value"
                    >{{dict.label}}</el-radio>
                  </el-radio-group>
                </el-form-item>
              </el-col>
            </el-row>
          </el-col>
          <el-col :span="10">
            <BarcodeImg ref="barcodeImg" :bussinessId="form.areaId" :bussinessCode="form.areaCode" barcodeType="AREA"></BarcodeImg>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="8">
            <el-form-item label="库位位置X" prop="positionX">
              <el-input-number :min="0" :max="99999999" :step="1" v-model="form.positionX" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="库位位置y" prop="positionY">
              <el-input-number :min="0" :max="99999999" :step="1" v-model="form.positionY" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="库位位置z" prop="positionZ">
              <el-input-number :min="0" :max="99999999" :step="1" v-model="form.positionZ" readonly="readonly" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" maxlength="500" readonly="readonly"/>
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <div slot="footer" class="dialog-footer">
        <el-button @click="closeArea">关 闭</el-button>
      </div>
    </el-dialog>

    <el-dialog title="批次详情" :visible.sync="batchOpen" width="960px" append-to-body>
      <el-form ref="batchform" :model="batchform" label-width="100px">
        <el-row>
          <el-col :span="14">
            <el-row>
              <el-col :span="24">
                <el-form-item label="批次编号" prop="batchCode">
                  <el-input v-model="batchform.batchCode" readonly="readonly"/>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="产品物料编码" prop="itemCode">
                  <el-input v-model="batchform.itemCode" readonly="readonly" />
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="产品物料名称" prop="itemName">
                  <el-input v-model="batchform.itemName" readonly="readonly" />
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="规格型号" prop="specification">
                  <el-input v-model="batchform.specification" type="textarea" readonly="readonly" />
                </el-form-item>
              </el-col>
            </el-row>
          </el-col>
          <el-col :span="10">
            <BarcodeImg ref="batchBarcodeImg" :bussinessId="batchform.batchId" :bussinessCode="batchform.batchCode" barcodeType="BATCH"></BarcodeImg>
          </el-col>
        </el-row>      
        <el-row>
          <el-col :span="8">
            <el-form-item label="单位" prop="unitName">
              <el-input v-model="batchform.unitName" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="生产日期" prop="produceDate">
              <el-date-picker clearable
                v-model="batchform.produceDate"
                type="date"
                value-format="yyyy-MM-dd">
              </el-date-picker>
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="有效期" prop="expireDate">
              <el-date-picker clearable
                v-model="batchform.expireDate"
                type="date"
                value-format="yyyy-MM-dd">
              </el-date-picker>
            </el-form-item>
          </el-col>
        </el-row>  
        <el-row>
              <el-col :span="12">
                <el-form-item label="供应商名称" prop="vendorName">
                  <el-input v-model="batchform.vendorName" readonly="readonly" />
                </el-form-item>
              </el-col>
              <el-col :span="12">
                <el-form-item label="客户名称" prop="clientName">
                  <el-input v-model="batchform.clientName" readonly="readonly" />
                </el-form-item>
              </el-col>
            </el-row>
        <el-row>
          <el-col :span="8">
            <el-form-item label="销售订单编号" prop="coCode">
              <el-input v-model="batchform.coCode" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="采购订单编号" prop="poCode">
              <el-input v-model="batchform.poCode" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="生产工单" prop="workorderCode">
              <el-input v-model="batchform.workorderCode" readonly="readonly" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="8">
            <el-form-item label="生产任务" prop="taskCode">
              <el-input v-model="batchform.taskCode" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="工作站编码" prop="workstationCode">
              <el-input v-model="batchform.workstationCode" readonly="readonly" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="生产批号" prop="productCode">
              <el-input v-model="batchform.productCode" readonly="readonly" />
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <div slot="footer" class="dialog-footer">
        <el-button @click="closeBatch">关 闭</el-button>
      </div>
    </el-dialog>


  </div>
</template>

<script>
import { listWmstock, changeFrozenState } from "@/api/mes/wm/wmstock";
import echarts from 'echarts'
import { getArea } from "@/api/mes/wm/area";
import { getBatch } from "@/api/mes/wm/batch";
import { treeselect } from "@/api/mes/md/itemtype";
import BarcodeImg from "@/components/barcodeImg/index.vue"
import Treeselect from "@riophae/vue-treeselect";
import "@riophae/vue-treeselect/dist/vue-treeselect.css";
export default {
  name: "Wmstock",
  dicts: ['sys_yes_no'],
  components: { Treeselect, BarcodeImg },
  data() {
    return {
      // 遮罩层
      loading: true,
      // 选中数组
      ids: [],
      // 非单个禁用
      single: true,
      // 非多个禁用
      multiple: true,
      // 显示搜索条件
      showSearch: true,
      itemTypeName: null,
      defaultProps: {
        children: "children",
        label: "label"
      },
      // 总条数
      total: 0,
      jtStats: { stockTotal: 12680, inToday: 1240, outToday: 980, warnCount: 6 },
      jtChart1Option: null,
      jtChart2Option: null,

      //物料产品分类树
      itemTypeOptions: undefined,
      // 库存记录表格数据
      wmstockList: [],
      // 弹出层标题
      title: "",
      // 是否显示弹出层
      open: false,
      batchOpen: false,
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        itemTypeId: null,
        itemId: null,
        itemCode: null,
        itemName: null,
        specification: null,
        unitOfMeasure: null,
        batchCode: null,
        warehouseId: null,
        warehouseCode: null,
        warehouseName: null,
        locationId: null,
        locationCode: null,
        locationName: null,
        areaId: null,
        areaCode: null,
        areaName: null,
        vendorId: null,
        vendorCode: null,
        vendorName: null,
        vendorNick: null,
        quantityOnhand: null,
        workorderCode: null,
        expireDate: null,
      },
      // 表单参数
      form: {},
      batchform: {},
    };
  },
  watch: {
    // 根据名称筛选分类树
    itemTypeName(val) {
      this.$refs.tree.filter(val);
    }
  },
    mounted() {
    this.$nextTick(() => { this.initJtCharts(); });
  },
  created() {
    this.getList();
      this.calcJtStats();
    this.getTreeselect();
  },
  methods: {

    /** 设计稿统计：库存指标 */
    calcJtStats() {
      const list = this.wmstockList || [];
      if (list.length) {
        const total = list.reduce((s, it) => s + (Number(it.quantity) || 0), 0);
        this.jtStats.stockTotal = total;
        this.jtStats.warnCount = list.filter(it => (Number(it.minQuantity) > 0 && (Number(it.quantity) || 0) < Number(it.minQuantity))).length;
      }
      this.buildJtCharts(list);
    },
    buildJtCharts(list) {
      const days = ['10-01','10-02','10-03','10-04','10-05','10-06','10-07'];
      const inData = [860, 1020, 940, 1180, 1090, 1240, 980];
      const outData = [720, 830, 760, 910, 880, 980, 860];
      const warehouses = list.slice(0, 5).map(it => ({ name: it.warehouseName || '仓库' + it.warehouseId, value: Number(it.quantity) || 0 }));
      const whData = warehouses.length >= 2 ? warehouses : [
        { name: '原料仓', value: 4200 }, { name: '半成品仓', value: 3650 },
        { name: '成品仓', value: 3180 }, { name: '待检区', value: 1650 }
      ];
      this.jtChart1Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['入库', '出库'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: days, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [
          { name: '入库', type: 'bar', barWidth: 14, data: inData, itemStyle: { color: '#0F3460', borderRadius: [4, 4, 0, 0] } },
          { name: '出库', type: 'bar', barWidth: 14, data: outData, itemStyle: { color: '#10b981', borderRadius: [4, 4, 0, 0] } }
        ]
      };
      this.jtChart2Option = {
        tooltip: { trigger: 'item', formatter: '{b}: {c} 件 ({d}%)' },
        legend: { bottom: 0, textStyle: { color: '#8a94a6' } },
        color: ['#0F3460', '#1d4e89', '#10b981', '#f59e0b', '#ef4444', '#94a3b8'],
        series: [{
          type: 'pie', radius: ['45%', '70%'], center: ['50%', '44%'],
          data: whData,
          label: { formatter: '{b}\n{c}件', color: '#1f2d3d' }
        }]
      };
    },
    /** 库存预警 */
    warnOnly() {
      this.$router.push({ path: '/mes/wm/wmstock', query: { warn: '1' } });
    },

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    /** 查询库存记录列表 */
    getList() {
      this.loading = true;
      listWmstock(this.queryParams).then(response => {
        this.wmstockList = response.rows;
        this.total = response.total;
        this.loading = false;
        this.calcJtStats();
        this.$nextTick(() => this.initJtCharts());
      });
    },
    /** 查询分类下拉树结构 */
    getTreeselect() {
      treeselect().then(response => {
        this.itemTypeOptions = response.data;
      });
    },
    /**
     * 冻结状态变更
     * @param row 
     */
    handleFrozenChange(row){
      let text = row.frozenFlag === "Y" ? "冻结" : "解冻";
      this.$modal.confirm('确认要"' + text + '""' + row.materialStockId + '"此库存吗？').then(function() {
        return changeFrozenState(row.materialStockId,row.frozenFlag);
      }).then(() => {
        this.$modal.msgSuccess(text + "成功");
      }).catch(function() {
        row.frozenFlag = row.frozenFlag === "N" ? "Y" : "N";
      });

    },
    // 筛选节点
    filterNode(value, data) {
      if (!value) return true;
      return data.label.indexOf(value) !== -1;
    },
    // 节点单击事件
    handleNodeClick(data) {
      this.queryParams.itemTypeId = data.id;
      this.handleQuery();
    },
    // 表单重置
    reset() {
      this.form = {
        areaId: null,
        areaCode: null,
        areaName: null,
        locationId: null,
        area: null,
        maxLoa: null,
        productMixing: 'N',
        batchMixing: 'N',
        positionX: null,
        positionY: null,
        positionZ: null,
        enableFlag: 'Y',
        remark: null,
        attr1: null,
        attr2: null,
        attr3: null,
        attr4: null,
        createBy: null,
        createTime: null,
        updateBy: null,
        updateTime: null
      };
      this.resetForm("form");
    },
    resetBatch(){
      this.batchform = {
        batchId: null,
        batchCode: null,
        itemCode: null,
        itemName: null,
        specification: null,
        produceDate: null,
        expireDate: null,
        vendorName: null,
        clientName: null,
        coCode: null,
        poCode: null,
        workorderCode: null,
        taskCode: null,
        workstationCode: null,
        productCode: null,
      };
      this.resetForm("batchform");
    },
    //库位点击事件
    handleAreaClick(row){
      this.reset();
      const areaId = row.areaId || this.ids
      getArea(areaId).then(response => {
        this.form = response.data;
        this.open = true;
        this.$nextTick(()=>{
          this.$refs.barcodeImg.getBarcode();
        })
      });
    },
    closeArea(){
      this.open = false;
    },
    //批次点击
    handleBatchClick(row){
      this.resetBatch();
      const batchId = row.batchId
      getBatch(batchId).then(response => {
        this.batchform = response.data;
        this.batchOpen = true;
        this.$nextTick(()=>{
          this.$refs.batchBarcodeImg.getBarcode();
        });
      });
    },
    closeBatch(){
      this.batchOpen = false;
    },

    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.materialStockId)
      this.single = selection.length!==1
      this.multiple = !selection.length
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('mes/wm/wmstock/export', {
        ...this.queryParams
      }, `wmstock_${new Date().getTime()}.xlsx`)
    }
  }
};
</script>

UI_MOD_WMSTOCK_EOF
    ok "仓储管理已按设计稿实现（设计稿 03：指标卡 + 库存趋势 + 仓库分布 + 4 功能按钮）"

    cat > "$ui/src/views/mes/pro/workorder/index.vue" <<'UI_MOD_WORKORDER_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">生产管理</div>
        <div class="jt-page-sub">工单、排产、报工全流程管控</div>
      </div>
    </div>
    <div class="jt-func-buttons">
      <span class="jt-func-btn is-active" @click="handleAdd"><i class="el-icon-plus"></i>新增工单</span>
      <span class="jt-func-btn" @click="go('/mes/pro/schedule')"><i class="el-icon-s-order"></i>工序派工</span>
      <span class="jt-func-btn" @click="go('/mes/pro/feedback')"><i class="el-icon-finished"></i>生产报工</span>
      <span class="jt-func-btn" @click="go('/mes/pro/andon')"><i class="el-icon-bell"></i>异常处理</span>
    </div>
    <div class="jt-stat-cards">
      <div class="jt-stat-card"><div class="jt-stat-icon is-primary"><i class="el-icon-date"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.planTotal.toLocaleString() }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">件</span></div><div class="jt-stat-label">今日计划</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-success"><i class="el-icon-circle-check"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.doneTotal.toLocaleString() }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">件</span></div><div class="jt-stat-label">已完成</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-warning"><i class="el-icon-odometer"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.rate }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div><div class="jt-stat-label">完成率</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-danger"><i class="el-icon-warning-outline"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.abnormal }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">单</span></div><div class="jt-stat-label">异常工单</div></div></div>
    </div>
    <div class="jt-grid-2">
      <div class="jt-card"><div class="jt-card-title">工单执行状态</div><div ref="jtChart1" style="height:280px;width:100%;"></div></div>
      <div class="jt-card"><div class="jt-card-title">生产进度</div><div ref="jtChart2" style="height:280px;width:100%;"></div></div>
    </div>

    <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="68px">
      <el-form-item label="工单编码" prop="workorderCode">
        <el-input
          v-model="queryParams.workorderCode"
          placeholder="请输入工单编码"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="工单名称" prop="workorderName">
        <el-input
          v-model="queryParams.workorderName"
          placeholder="请输入工单名称"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="来源单据" prop="sourceCode">
        <el-input
          v-model="queryParams.sourceCode"
          placeholder="请输入来源单据"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>

      <el-form-item label="产品编号" prop="productCode">
        <el-input
          v-model="queryParams.productCode"
          placeholder="请输入产品编号"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="产品名称" prop="productName">
        <el-input
          v-model="queryParams.productName"
          placeholder="请输入产品名称"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>

      <el-form-item label="客户编码" prop="clientCode">
        <el-input
          v-model="queryParams.clientCode"
          placeholder="请输入客户编码"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="客户名称" prop="clientName">
        <el-input
          v-model="queryParams.clientName"
          placeholder="请输入客户名称"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="工单类型" prop="workorderType">
        <el-input
          v-model="queryParams.workorderType"
          placeholder="请选择工单类型"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="需求日期" prop="requestDate">
        <el-date-picker clearable
                        v-model="queryParams.requestDate"
                        type="date"
                        value-format="yyyy-MM-dd"
                        placeholder="请选择需求日期">
        </el-date-picker>
      </el-form-item>
      <el-form-item>
        <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">搜索</el-button>
        <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
      </el-form-item>
    </el-form>

    <el-row :gutter="10" class="mb8">
      <el-col :span="1.5">
        <el-button
          type="primary"
          plain
          icon="el-icon-plus"
          size="mini"
          @click="handleAdd"
          v-hasPermi="['mes:pro:workorder:add']"
        >新增</el-button>
      </el-col>
      <el-col :span="1.5">
        <el-button
          type="warning"
          plain
          icon="el-icon-download"
          size="mini"
          @click="handleExport"
          v-hasPermi="['mes:pro:workorder:export']"
        >导出</el-button>
      </el-col>
      <right-toolbar :showSearch.sync="showSearch" @queryTable="getList"></right-toolbar>
    </el-row>

    <el-table
      v-loading="loading"
      :data="workorderList"
      row-key="workorderId"
      default-expand-all
      :tree-props="{children: 'children', hasChildren: 'hasChildren'}"
    >
      <el-table-column label="工单编码" width="180" prop="workorderCode" >
        <template slot-scope="scope">
          <el-button
            size="mini"
            type="text"
            @click="handleView(scope.row)"
            v-hasPermi="['mes:pro:workorder:query']"
          >{{scope.row.workorderCode}}</el-button>
        </template>
      </el-table-column>
      <el-table-column label="工单名称" width="200" align="center" prop="workorderName" :show-overflow-tooltip="true"/>
      <el-table-column label="工单类型" align="center" prop="workorderType" >
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_workorder_type" :value="scope.row.workorderType"/>
        </template>
      </el-table-column>
      <el-table-column label="工单来源" align="center" prop="orderSource" >
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_workorder_sourcetype" :value="scope.row.orderSource"/>
        </template>
      </el-table-column>
      <el-table-column label="订单编号" width="140" align="center" prop="sourceCode" />
      <el-table-column label="产品编号" width="120" align="center" prop="productCode" />
      <el-table-column label="产品名称" width="200" align="center" prop="productName" :show-overflow-tooltip="true"/>
      <el-table-column label="规格型号" align="center" prop="productSpc" :show-overflow-tooltip="true"/>
      <el-table-column label="单位" align="center" prop="unitName" />
      <el-table-column label="工单数量" align="center" prop="quantity" />
      <el-table-column label="已生产数量" align="center" width="100px" prop="quantityProduced" />
      <el-table-column label="客户编码" align="center" prop="clientCode" />
      <el-table-column label="客户名称" align="center" prop="clientName" :show-overflow-tooltip="true"/>
      <el-table-column label="需求日期" align="center" prop="requestDate" width="180">
        <template slot-scope="scope">
          <span>{{ parseTime(scope.row.requestDate, '{y}-{m}-{d}') }}</span>
        </template>
      </el-table-column>
      <el-table-column label="单据状态" align="center" prop="status">
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_order_status" :value="scope.row.status"/>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="250px" align="center" class-name="small-padding fixed-width">
        <template slot-scope="scope">
          <el-button
            size="mini"
            type="text"
            icon="el-icon-edit"
            v-if="scope.row.status =='PREPARE'"
            @click="handleUpdate(scope.row)"
            v-hasPermi="['mes:pro:workorder:edit']"
          >修改</el-button>
          <el-button
            size="mini"
            type="text"
            icon="el-icon-plus"
            v-if="scope.row.status =='CONFIRMED' && scope.row.workorderType =='SELF'"
            @click="handleAdd(scope.row)"
            v-hasPermi="['mes:pro:workorder:update']"
          >新增</el-button>
          <el-button
            size="mini"
            type="text"
            icon="el-icon-circle-check"
            v-if="scope.row.status =='CONFIRMED'"
            @click="handleFinish(scope.row)"
            v-hasPermi="['mes:pro:workorder:update']"
          >完成</el-button>
          <el-button
            size="mini"
            type="text"
            icon="el-icon-circle-close"
            v-if="scope.row.status =='CONFIRMED'"
            @click="handleCancel(scope.row)"
            v-hasPermi="['mes:pro:workorder:update']"
          >取消</el-button>
          <el-button
            size="mini"
            type="text"
            icon="el-icon-delete"
            v-if="scope.row.status =='PREPARE'"
            @click="handleDelete(scope.row)"
            v-hasPermi="['mes:pro:workorder:remove']"
          >删除</el-button>
          <el-button
              size="mini"
              type="text"
              icon="el-icon-printer"
              @click="handlePreview(scope.row)"
          >预览</el-button>
        </template>
      </el-table-column>
    </el-table>
    <pagination
      v-show="total>0"
      :total="total"
      :page.sync="queryParams.pageNum"
      :limit.sync="queryParams.pageSize"
      @pagination="getList"
    />

    <!-- 添加或修改生产工单对话框 -->
    <el-dialog :title="title" :visible.sync="open" width="960px" @close="cancel" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="100px">
        <el-row>
          <el-col :span="16">
            <el-row>
              <el-col :span="16">
                <el-form-item label="工单编号" prop="workorderCode">
                  <el-input v-model="form.workorderCode" placeholder="请输入工单编号" />
                </el-form-item>
              </el-col>
              <el-col :span="8">
                <el-form-item  label-width="80">
                  <el-switch v-model="autoGenFlag"
                             active-color="#13ce66"
                             active-text="自动生成"
                             @change="handleAutoGenChange(autoGenFlag)" v-if="optType != 'view' && form.status =='PREPARE'">
                  </el-switch>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="工单名称" prop="workorderName">
                  <el-input v-model="form.workorderName" placeholder="请输入工单名称" />
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="12">
                <el-form-item label="来源类型" prop="orderSource">
                  <el-radio-group v-model="form.orderSource" disabled v-if="optType=='view'">
                    <el-radio
                      v-for="dict in dict.type.mes_workorder_sourcetype"
                      :key="dict.value"
                      :label="dict.value"
                    >{{dict.label}}</el-radio>
                  </el-radio-group>
                  <el-radio-group v-model="form.orderSource" v-else>
                    <el-radio
                      v-for="dict in dict.type.mes_workorder_sourcetype"
                      :key="dict.value"
                      :label="dict.value"
                    >{{dict.label}}</el-radio>
                  </el-radio-group>
                </el-form-item>
              </el-col>
              <el-col :span="12" v-if="form.orderSource == 'ORDER'">
                <el-form-item label="订单编号" prop="sourceCode">
                  <el-input v-model="form.sourceCode" placeholder="请输入订单编号" />
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="工单类型" prop="workorderType">
                  <el-select v-model="form.workorderType" placeholder="请选择类型">
                    <el-option
                      v-for="dict in dict.type.mes_workorder_type"
                      :key="dict.value"
                      :label="dict.label"
                      :value="dict.value"
                    ></el-option>
                  </el-select>
                </el-form-item>
              </el-col>
            </el-row>
          </el-col>
          <el-col :span="8">
            <BarcodeImg ref="barcodeImg" :bussinessId="form.workorderId" :bussinessCode="form.workorderCode" barcodeType="WORKORDER"></BarcodeImg>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item label="产品编号" prop="productCode">
              <el-input v-model="form.productCode" placeholder="请选择产品" >
                <el-button slot="append" @click="handleSelectProduct" icon="el-icon-search"></el-button>
              </el-input>
              <ItemSelect ref="itemSelect" @onSelected="onItemSelected" > </ItemSelect>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="产品名称" prop="productName">
              <el-input v-model="form.productName" placeholder="请选择产品" disabled/>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item label="规格型号" prop="productSpc">
              <el-input v-model="form.productSpc" placeholder="请选择产品" disabled/>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="单位" prop="unitName">
              <el-input v-model="form.unitName" placeholder="请选择产品" disabled/>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="8">
            <el-form-item label="工单数量" prop="quantity">
              <el-input-number :min="1" :max="99999999" v-model="form.quantity" placeholder="请输入生产数量" />
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="需求日期" prop="requestDate">
              <el-date-picker clearable
                              v-model="form.requestDate"
                              type="date"
                              value-format="yyyy-MM-dd"
                              placeholder="请选择需求日期">
              </el-date-picker>
            </el-form-item>
          </el-col>
          <el-col :span="8">
          </el-col>
        </el-row>
        <el-row v-if="form.orderSource == 'ORDER'">
          <el-col :span="12">
            <el-form-item label="客户编码" prop="clientCode">
              <el-input v-model="form.clientCode" placeholder="请选择客户" >
                <el-button slot="append" @click="handleSelectClient" icon="el-icon-search"></el-button>
              </el-input>
              <ClientSelect ref="clientSelect" @onSelected="onClientSelected" > </ClientSelect>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="客户名称" prop="clientName">
              <el-input v-model="form.clientName" readonly="readonly" placeholder="请输入客户名称" />
            </el-form-item>
          </el-col>
          <el-col></el-col>
        </el-row>
        <el-row v-if="form.workorderType == 'OUTSOURCE' || form.workorderType == 'PURCHASE'">
          <el-col :span="12">
            <el-form-item label="供应商编码" prop="vendorCode">
              <el-input v-model="form.vendorCode" placeholder="请选择供应商" >
                <el-button slot="append" @click="handleSelectVendor" icon="el-icon-search"></el-button>
              </el-input>
              <VendorSelect ref="vendorSelect" @onSelected="onVendorSelected" />
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="供应商名称" prop="vendorName">
              <el-input v-model="form.vendorName" readonly="readonly" placeholder="请选择供应商" />
            </el-form-item>
          </el-col>
          <el-col></el-col>
        </el-row>
        <el-row>
          <el-col></el-col>
          <el-col></el-col>
          <el-col></el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" placeholder="请输入内容" />
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <el-tabs type="border-card" v-if="form.workorderId != null" v-model="activeName" @tab-click="handleClickTab">
        <el-tab-pane label="BOM组成" name="bom">
          <Workorderbom ref="bomlist" :optType="optType" :workorder="form" @handleAddSub="handleSubAdd" ></Workorderbom>
        </el-tab-pane>
        <el-tab-pane label="物料需求" name="item">
          <WorkorderItemList ref="itemlist"  :workorder="form" :itemStatus="itemStatus"></WorkorderItemList>
        </el-tab-pane>
      </el-tabs>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitForm" v-if="form.status =='PREPARE' && optType !='view' ">保 存</el-button>
        <el-button type="success" @click="handleConfirm" v-if="form.status =='PREPARE' && optType !='view'  && form.workorderId !=null">确 认</el-button>
        <el-button @click="cancel">关 闭</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listWorkorder, getWorkorder, delWorkorder, addWorkorder, updateWorkorder ,dofinish ,doCancel} from "@/api/mes/pro/workorder";
import echarts from 'echarts'
import Workorderbom from "./bom/bom.vue";
import WorkorderItemList from "./items/item.vue";
import ItemSelect  from "@/components/itemSelect/single.vue";
import ClientSelect from "@/components/clientSelect/single.vue";
import VendorSelect from "@/components/vendorSelect/single.vue";
import {genCode} from "@/api/system/autocode/rule"
import Treeselect from "@riophae/vue-treeselect";
import BarcodeImg from "@/components/barcodeImg/index.vue"
import "@riophae/vue-treeselect/dist/vue-treeselect.css";

export default {
  name: "Workorder",
  dicts: ['mes_order_status','mes_workorder_sourcetype','mes_workorder_type'],
  components: {
    Treeselect,
    ItemSelect ,
    ClientSelect,
    VendorSelect,
    Workorderbom,
    WorkorderItemList,
    BarcodeImg
  },
  data() {
    return {
      itemStatus: false,
      activeName: 'bom',
      //自动生成编码
      autoGenFlag:false,
      optType: undefined,
      // 遮罩层
      loading: true,
      // 显示搜索条件
      showSearch: true,
      // 非单个禁用
      single: true,
      // 总条数
      total: 0,
      jtStats: { planTotal: 1280, doneTotal: 964, rate: 75.3, abnormal: 3 },
      jtChart1Option: null,
      jtChart2Option: null,

      // 非多个禁用
      multiple: true,
      // 生产工单表格数据
      workorderList: [],
      // 生产工单树选项
      workorderOptions: [],
      // 弹出层标题
      title: "",
      // 是否显示弹出层
      open: false,
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        workorderCode: null,
        workorderName: null,
        orderSource: null,
        sourceCode: null,
        productId: null,
        productCode: null,
        productName: null,
        productSpc: null,
        unitOfMeasure: null,
        quantity: null,
        quantityProduced: null,
        quantityChanged: null,
        quantityScheduled: null,
        clientId: null,
        clientCode: null,
        clientName: null,
        requestDate: null,
        parentId: null,
        ancestors: null,
        status: null,
      },
      // 表单参数
      form: {},
      formStatus: "parent",
      // 生成工单后的表单
      secondaryForm: {},
      primaryForm: {},
      // 表单校验
      rules: {
        workorderCode: [
          { required: true, message: "工单编码不能为空", trigger: "blur" },
          { max: 64, message: "字段过长", trigger: "blur" }
        ],
        workorderName: [
          { required: true, message: "工单名称不能为空", trigger: "blur" },
          { max: 100, message: "字段过长", trigger: "blur" }
        ],
        workorderType: [
          { required: true, message: "请选择生产工单类型", trigger: "blur" }
        ],
        orderSource: [
          { required: true, message: "来源类型不能为空", trigger: "blur" }
        ],
        productId: [
          { required: true, message: "产品不能为空", trigger: "blur" }
        ],
        productCode: [
          { required: true, message: "产品编号不能为空", trigger: "blur" }
        ],
        productName: [
          { required: true, message: "产品名称不能为空", trigger: "blur" }
        ],
        quantity: [
          { required: true, message: "生产数量不能为空", trigger: "blur" }
        ],
        requestDate: [
          { required: true, message: "需求日期不能为空", trigger: "blur" }
        ],
        remark: [
          { max: 250, message: '长度必须小于250个字符', trigger: 'blur' }
        ]
      }
    };
  },
    mounted() {
    this.$nextTick(() => { this.initJtCharts(); });
  },
  created() {
    this.getList();
      this.calcJtStats();
  },
  methods: {

    /** 设计稿统计：生产指标 */
    calcJtStats() {
      const list = this.workorderList || [];
      if (list.length) {
        const plan = list.reduce((s, it) => s + (Number(it.quantity) || 0), 0);
        const done = list.reduce((s, it) => s + (Number(it.quantityProduced) || 0), 0);
        this.jtStats.planTotal = plan;
        this.jtStats.doneTotal = done;
        this.jtStats.rate = plan ? Number(((done / plan) * 100).toFixed(1)) : 0;
        this.jtStats.abnormal = list.filter(it => it.status === '4' || it.status === '5').length;
      }
      this.buildJtCharts(list);
    },
    buildJtCharts(list) {
      const names = list.slice(0, 7).map(it => (it.workorderCode || 'WO').slice(-8));
      const planData = list.slice(0, 7).map(it => Number(it.quantity) || 0);
      const doneData = list.slice(0, 7).map(it => Number(it.quantityProduced) || 0);
      const rateData = doneData.map((d, i) => planData[i] ? Number(((d / planData[i]) * 100).toFixed(1)) : 0);
      const cNames = names.length >= 2 ? names : ['WO-01','WO-02','WO-03','WO-04','WO-05','WO-06'];
      const cPlan = planData.length >= 2 ? planData : [500, 300, 480, 260, 400, 350];
      const cDone = doneData.length >= 2 ? doneData : [380, 210, 374, 180, 320, 96];
      const cRate = rateData.length >= 2 ? rateData : cDone.map((d, i) => Number(((d / cPlan[i]) * 100).toFixed(1)));
      this.jtChart1Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['计划数量', '已完成'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: cNames, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b', interval: 0, rotate: 20, fontSize: 11 } },
        yAxis: { type: 'value', axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [
          { name: '计划数量', type: 'bar', barWidth: 18, data: cPlan, itemStyle: { color: '#dbe4f2', borderRadius: [4, 4, 0, 0] } },
          { name: '已完成', type: 'bar', barWidth: 18, data: cDone, itemStyle: { color: '#0F3460', borderRadius: [4, 4, 0, 0] } }
        ]
      };
      this.jtChart2Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['完成率'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: cNames, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b', interval: 0, rotate: 20, fontSize: 11 } },
        yAxis: { type: 'value', max: 100, axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [{
          name: '完成率', type: 'line', smooth: true, data: cRate,
          symbol: 'circle', symbolSize: 6, lineStyle: { color: '#10b981', width: 3 }, itemStyle: { color: '#10b981' },
          areaStyle: { color: 'rgba(16,185,129,0.12)' }
        }]
      };
    },

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    handleClickTab(tab) {
      if (tab.name == 'item') {
        this.itemStatus = true
      } else {
        this.itemStatus = false
      }
    },
    /** 查询生产工单列表 */
    getList() {
      this.loading = true;
      listWorkorder(this.queryParams).then(response => {
        this.workorderList = this.handleTree(response.rows, "workorderId", "parentId");
        this.total = response.total;
        this.loading = false;
        this.calcJtStats();
        this.$nextTick(() => this.initJtCharts());
      });
    },
    /** 转换生产工单数据结构 */
    normalizer(node) {
      if (node.children && !node.children.length) {
        delete node.children;
      }
      return {
        id: node.workorderId,
        label: node.workorderName,
        children: node.children
      };
    },
    /** 查询生产工单下拉树结构 */
    getTreeselect() {
      listWorkorder().then(response => {
        this.workorderOptions = [];
        const data = { workorderId: 0, workorderName: '顶级节点', children: [] };
        data.children = this.handleTree(response.rows, "workorderId", "parentId");
        this.workorderOptions.push(data);
      });
    },
    // 取消按钮
    cancel() {
      if (this.formStatus == 'parent') {
        this.open = false;
        this.reset();
      } else {
        this.reset()
        this.formStatus = 'parent'
        this.getTreeselect();
        const workorderId = this.primaryForm.workorderId;
        getWorkorder(workorderId).then(response => {
          this.form = response.data
          this.open = true;
          this.$nextTick(() => {
            this.$refs.barcodeImg.getBarcode();

          })
          this.title = "查看工单信息";
          this.optType = "view";
        });
      }

    },
    // 表单重置
    reset() {
      this.form = {
        workorderId: null,
        workorderCode: null,
        workorderName: null,
        workorderType: 'SELF',
        orderSource: null,
        sourceCode: null,
        productId: null,
        productCode: null,
        productName: null,
        productSpc: null,
        unitOfMeasure: null,
        quantity: null,
        quantityProduced: null,
        quantityChanged: null,
        quantityScheduled: null,
        clientId: null,
        clientCode: null,
        clientName: null,
        vendorId: null,
        vendorCode: null,
        vendorName: null,
        requestDate: null,
        parentId: null,
        status: "PREPARE",
        remark: null,
        createBy: null,
        createTime: null,
        updateBy: null,
        updateTime: null
      };
      this.autoGenFlag = false;
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    //从BOM行中直接新增
    handleSubAdd(row){
      this.primaryForm = this.form
      this.formStatus = "child"
      this.open = false;
      this.reset();
      this.getTreeselect();
      if (row != null && row.workorderId) {
        this.form = row;
        this.form.parentId = row.workorderId;
        this.form.workorderId = null;
        this.form.workorderCode = null;
      } else {
        this.form.parentId = 0;
      }
      this.open = true;
      this.title = "添加生产工单";
      this.optType="add";
    },
    /** 新增按钮操作 */
    handleAdd(row) {
      this.reset();
      this.getTreeselect();
      if (row != null && row.workorderId) {
        this.form.parentId = row.workorderId;
        this.form.orderSource = row.orderSource;
        this.form.sourceCode = row.sourceCode;
        this.form.clientId = row.clientId;
        this.form.clientCode = row.clientCode;
        this.form.clientName = row.clientName;
      } else {
        this.form.parentId = 0;
      }
      this.open = true;
      this.title = "添加生产工单";
      this.optType="add";
    },
    // 查询明细按钮操作
    handleView(row){
      this.reset();
      this.getTreeselect();
      const workorderId = row.workorderId || this.ids;
      getWorkorder(workorderId).then(response => {
        this.form = response.data
        this.open = true;
        this.$nextTick(() => {
          this.$refs.barcodeImg.getBarcode();

        })
        this.title = "查看工单信息";
        this.optType = "view";
      });
    },
    /** 修改按钮操作 */
    handleUpdate(row) {
      this.reset();
      this.getTreeselect();
      if (row != null) {
        this.form.parentId = row.workorderId;
      }
      getWorkorder(row.workorderId).then(response => {
        this.form = response.data;

        this.form.workorderCode = response.data.workorderCode
        this.form.workorderId = response.data.workorderId
        this.open = true;
        this.title = "修改生产工单";
        this.optType="edit";
      });
    },
    /** 提交按钮 */
    submitForm() {
      this.$refs["form"].validate(valid => {
        if (valid) {
          if (this.form.workorderId != null) {
            updateWorkorder(this.form).then(response => {
              this.$modal.msgSuccess("修改成功");
              //this.open = false;
              this.$refs["bomlist"].getList();
              this.getList();
            });
          } else {
            addWorkorder(this.form).then(response => {
              this.$modal.msgSuccess("新增成功");
              //this.open = false;
              this.form.workorderId = response.data;
              this.getList();
            });
          }
        }
      });
    },
    handlePreview(row){
      //todo:本地环境报表地址
      window.open(process.env.VUE_APP_REPORT+"/ureport/preview?_u=mysql:生产工单打印模版.ureport.xml&id="+row.workorderId+"&code="+row.workorderCode)
    },
    /** 删除按钮操作 */
    handleDelete(row) {
      this.$modal.confirm('是否确认删除生产工单编号为"' + row.workorderId + '"的数据项？').then(function() {
        return delWorkorder(row.workorderId);
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("删除成功");
      }).catch(() => {});
    },
    handleSelectProduct(){
      this.$refs.itemSelect.handleOpen(this.form.productId)
    },
    handleSelectClient(){
      this.$refs.clientSelect.showFlag = true;
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('mes/pro/workorder/export', {
        ...this.queryParams
      }, `workorder_${new Date().getTime()}.xlsx`)
    },
    handleConfirm(){
      let that = this;
      this.$modal.confirm('是确认完成工单编制？【确认后将不能更改】').then(function(){
        that.form.status = 'CONFIRMED';
        that.submitForm();
      });
    },
    handleFinish(row){
      const workorderIds = row.workorderId || this.ids;
      this.$modal.confirm('确认完成工单？一旦完成，此工单将无法继续报工').then(function() {
        return dofinish(workorderIds) //完成工单
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("更改成功");
      }).catch(() => {});
    },
    handleCancel(row){
      const workorderIds = row.workorderId || this.ids;
      this.$modal.confirm('确认取消工单？一旦完成，此工单将无法继续报工').then(function() {
        return doCancel(workorderIds) //取消工单
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("更改成功");
      }).catch(() => {});
    },
    //物料选择弹出框
    onItemSelected(obj){
      console.log(obj, '----------------')
      if(obj != undefined && obj != null){
        this.form.productId = obj.itemId;
        this.form.productCode = obj.itemCode;
        this.form.productName = obj.itemName;
        this.form.productSpc = obj.specification;
        this.form.unitOfMeasure = obj.unitOfMeasure;
        this.form.unitName = obj.unitName;
      }
    },
    //客户选择弹出框
    onClientSelected(obj){
      if(obj != undefined && obj != null){
        this.form.clientId = obj.clientId;
        this.form.clientCode = obj.clientCode;
        this.form.clientName = obj.clientName;
      }
    },
    //供应商选择
    handleSelectVendor(){
      this.$refs.vendorSelect.showFlag = true;
    },
    //供应商选择弹出框
    onVendorSelected(obj){
      debugger;
      if(obj != undefined && obj != null){
        this.form.vendorId = obj.vendorId;
        this.form.vendorCode = obj.vendorCode;
        this.form.vendorName = obj.vendorName;
      }
    },
    //自动生成编码
    handleAutoGenChange(autoGenFlag){
      if(autoGenFlag){
        genCode('WORKORDER_CODE').then(response =>{
          this.form.workorderCode = response;
        });
      }else{
        this.form.workorderCode = null;
      }
    }
  }
};
</script>

UI_MOD_WORKORDER_EOF
    ok "生产管理已按设计稿实现（设计稿 04：4 功能按钮 + 指标卡 + 工单执行状态 + 生产进度）"

    cat > "$ui/src/views/mes/qc/qcresult/index.vue" <<'UI_MOD_QCRESULT_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">质量管理</div>
        <div class="jt-page-sub">检验、不合格品、质量异常全流程管控</div>
      </div>
    </div>
    <div class="jt-func-buttons">
      <span class="jt-func-btn is-active"><i class="el-icon-document-checked"></i>检验单</span>
      <span class="jt-func-btn" @click="go('/mes/qc/defectrecord')"><i class="el-icon-circle-close"></i>不合格品处理</span>
      <span class="jt-func-btn" @click="go('/mes/qc/ipqc')"><i class="el-icon-warning-outline"></i>质量异常</span>
      <span class="jt-func-btn" @click="go('/mes/report/chart')"><i class="el-icon-data-analysis"></i>检验统计</span>
    </div>
    <div class="jt-stat-cards">
      <div class="jt-stat-card"><div class="jt-stat-icon is-primary"><i class="el-icon-document"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.checkTotal }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">单</span></div><div class="jt-stat-label">今日检验</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-success"><i class="el-icon-circle-check"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.passTotal }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">单</span></div><div class="jt-stat-label">合格</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-warning"><i class="el-icon-medal"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.passRate }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div><div class="jt-stat-label">合格率</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-danger"><i class="el-icon-circle-close"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.failTotal }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">单</span></div><div class="jt-stat-label">不合格</div></div></div>
    </div>
    <div class="jt-grid-2">
      <div class="jt-card"><div class="jt-card-title">合格率趋势</div><div ref="jtChart1" style="height:280px;width:100%;"></div></div>
      <div class="jt-card"><div class="jt-card-title">不合格原因分布</div><div ref="jtChart2" style="height:280px;width:100%;"></div></div>
    </div>

    <el-row v-if="optType!= 'view'" :gutter="10" class="mb8">
      <el-col :span="1.5">
        <el-button
          type="primary"
          plain
          icon="el-icon-plus"
          size="mini"
          @click="handleAdd"
          v-hasPermi="['qc:qcresult:add']"
        >新增</el-button>
      </el-col>
      <el-col :span="1.5">
        <el-button
          type="success"
          plain
          icon="el-icon-edit"
          size="mini"
          :disabled="single"
          @click="handleUpdate"
          v-hasPermi="['qc:qcresult:edit']"
        >修改</el-button>
      </el-col>
      <el-col :span="1.5">
        <el-button
          type="danger"
          plain
          icon="el-icon-delete"
          size="mini"
          :disabled="multiple"
          @click="handleDelete"
          v-hasPermi="['qc:qcresult:remove']"
        >删除</el-button>
      </el-col>
      <right-toolbar :showSearch.sync="showSearch" @queryTable="getList"></right-toolbar>
    </el-row>

    <el-table v-loading="loading" :data="qcresultList" @selection-change="handleSelectionChange">
      <el-table-column type="selection" width="55" align="center" />
      <el-table-column label="样品编号" align="center" prop="resultCode" />
      <el-table-column label="对应的物资SN" align="center" prop="snCode" />
      <el-table-column label="操作" v-if="optType != 'view'" align="center" class-name="small-padding fixed-width">
        <template slot-scope="scope">
          <el-button
            size="mini"
            type="text"
            icon="el-icon-edit"
            @click="handleUpdate(scope.row)"
            v-hasPermi="['qc:qcresult:edit']"
          >修改</el-button>
          <el-button
            size="mini"
            type="text"
            icon="el-icon-delete"
            @click="handleDelete(scope.row)"
            v-hasPermi="['qc:qcresult:remove']"
          >删除</el-button>
        </template>
      </el-table-column>
    </el-table>
    
    <pagination
      v-show="total>0"
      :total="total"
      :page.sync="queryParams.pageNum"
      :limit.sync="queryParams.pageSize"
      @pagination="getList"
    />

    <!-- 添加或修改检测结果记录对话框 -->
    <el-dialog :title="title" :visible.sync="open" width="960px" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="100px">
        <el-row>
          <el-col :span="8">
            <el-form-item label="样品编号" prop="resultCode">
              <el-input v-model="form.resultCode" placeholder="请输入记录编号" />
            </el-form-item>
          </el-col>
          <el-col :span="4">
            <el-form-item  label-width="80">
              <el-switch v-model="autoGenFlag"
                  active-color="#13ce66"
                  active-text="自动生成"
                  @change="handleAutoGenChange(autoGenFlag)" v-if="optType != 'view'" >               
              </el-switch>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="SN" prop="snCode">
              <el-input v-model="form.snCode" placeholder="请输入对应的物资SN" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" placeholder="请输入内容" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-divider>检测值</el-divider>
        <div v-for="(item, index) in form.items" :key="index">
          <el-row>
            <el-col :span="12">
              <el-form-item :label="'检测项' + (index + 1)" :prop="'items.' + index + '.indexName'">
                <el-input v-model="item.indexName" readonly="readonly"  />
              </el-form-item>
            </el-col>
            <el-col :span="12">
              <el-form-item v-if="item.qcResultType =='TEXT'" label="检测值" :prop="'items.' + index + '.qcValText'">
                <el-input type="textarea" v-model="item.qcValText" placeholder="请输入检测值" />
              </el-form-item>
              <el-form-item v-else-if="item.qcResultType =='FLOAT'" label="检测值" :prop="'items.' + index + '.qcValFloat'">
                <el-input v-model="item.qcValFloat" placeholder="请输入检测值" />
              </el-form-item>
              <el-form-item v-else-if="item.qcResultType =='INTEGER'" label="检测值" :prop="'items.' + index + '.qcValInteger'">
                <el-input v-model="item.qcValInteger" placeholder="请输入检测值" />
              </el-form-item>
              <el-form-item v-else-if="item.qcResultType =='DICT'" label="检测值" :prop="'items.' + index + '.qcValDict'">
                <DictDataSelect  :dictName="item.qcResultSpc" v-model="item.qcValDict" :initialValue="item.qcValDict"></DictDataSelect>
              </el-form-item>
              <el-form-item v-else :label="'文件 ' + (index + 1)" :prop="'items.' + index + '.qcValFile'">
                <ImageUpload v-if="item.qcResultType =='FILE' && item.qcResultSpc == 'IMG'" v-model="item.qcValFile" :limit="1" :fileSize="10" :fileType="['jpg','png','jpeg']" @onUploaded="(file) => handleUploaded(file,index)" @onRemoved="(file) => handleRemoved(file,index)" ></ImageUpload>
                <FileUpload v-else="item.qcResultType == 'FILE' && item.qcResultSpc == 'FILE'"  v-model="item.qcValFile" :limit="1" :fileSize="10" :fileType="['text','doc','docx','excel','mp4']" @onUploaded="(file) => handleUploaded(file,index)" @onRemoved="(file) => handleRemoved(file,index)"></FileUpload>
              </el-form-item>
            </el-col>
          </el-row>
          <el-divider></el-divider>
        </div>
      </el-form>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitForm">确 定</el-button>
        <el-button @click="cancel">取 消</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listQcresult, getQcresult, delQcresult, addQcresult, updateQcresult } from "@/api/mes/qc/qcresult";
import echarts from 'echarts'
import { listQcresultdetail, listDetails ,getQcresultdetail, delQcresultdetail, addQcresultdetail, updateQcresultdetail } from "@/api/mes/qc/qcresultdetail";
import DictDataSelect from "@/components/DictSelect/dictOptionSelect.vue"
import {genCode} from "@/api/system/autocode/rule"
export default {
  autoGenFlag : false,
  name: "Qcresult",
  props:{
    qcId: null,
    qcType: null,
    qcDetailType: null,
    optType: null,
  },
  components: { DictDataSelect },
  data() {
    return {
      optType2: this.optType,
      autoGenFlag : false,
      // 遮罩层
      loading: true,
      // 选中数组
      ids: [],
      // 非单个禁用
      single: true,
      // 非多个禁用
      multiple: true,
      // 显示搜索条件
      showSearch: true,
      // 总条数
      total: 0,
      jtStats: { checkTotal: 124, passTotal: 118, passRate: 95.2, failTotal: 6 },
      jtChart1Option: null,
      jtChart2Option: null,

      // 检测结果记录表格数据
      qcresultList: [],
      // 弹出层标题
      title: "",
      // 是否显示弹出层
      open: false,
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        resultCode: null,        sourceDocId: this.qcId,        sourceDocCode: null,        sourceDocName: null,        sourceDocType: this.qcType,        itemId: null,        itemCode: null,        itemName: null,        specification: null,        unitOfMeasure: null,        snCode: null,      },
      
       queryParams2: {
          qcId:this.qcId,
          qcType:this.qcType,
          resultId: null
       },
        // 表单参数
      form: {

      },
      // 表单校验
      rules: {
        resultCode: [
          { required: true, message: "记录编号不能为空", trigger: "blur" }
        ],        itemId: [
          { required: true, message: "产品物料ID不能为空", trigger: "blur" }
        ],      }
    };
  },
    mounted() {
    this.$nextTick(() => { this.initJtCharts(); });
  },
  created() {
    this.getList();
      this.calcJtStats();
  },
  methods: {

    /** 设计稿统计：质量指标 */
    calcJtStats() {
      const list = this.qcresultList || [];
      if (list.length) {
        let pass = 0, fail = 0;
        list.forEach(it => {
          const r = String(it.result || it.qcResult || '');
          if (r.indexOf('合格') > -1 || r === '1' || r === 'P') { pass++; }
          else if (r.indexOf('不合格') > -1 || r === '2' || r === 'F') { fail++; }
        });
        const total = pass + fail;
        if (total) {
          this.jtStats.checkTotal = list.length;
          this.jtStats.passTotal = pass;
          this.jtStats.failTotal = fail;
          this.jtStats.passRate = Number(((pass / total) * 100).toFixed(1));
        }
      }
      this.buildJtCharts();
    },
    buildJtCharts() {
      const days = ['10-01','10-02','10-03','10-04','10-05','10-06','10-07'];
      const rateData = [93.2, 94.1, 93.8, 95.0, 94.6, 95.2, 95.8];
      this.jtChart1Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['合格率'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: days, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', min: 80, max: 100, axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [{
          name: '合格率', type: 'line', smooth: true, data: rateData,
          symbol: 'circle', symbolSize: 6, lineStyle: { color: '#0F3460', width: 3 }, itemStyle: { color: '#0F3460' },
          areaStyle: { color: 'rgba(15,52,96,0.10)' }
        }]
      };
      this.jtChart2Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['不合格数'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: ['尺寸超差','表面缺陷','装配不良','材料异常'], axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [{
          name: '不合格数', type: 'bar', barWidth: 24, data: [8, 6, 4, 3],
          itemStyle: { color: '#ef4444', borderRadius: [4, 4, 0, 0] }
        }]
      };
    },

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    /** 查询检测结果记录列表 */
    getList() {
      this.loading = true;
      listQcresult(this.queryParams).then(response => {
        this.qcresultList = response.rows;
        this.total = response.total;
        this.loading = false;
        this.calcJtStats();
        this.$nextTick(() => this.initJtCharts());
      });
    },

    /** 查询检测结果明细记录列表 
     * 此处无论是否有传递resultId参数，都会返回所有检查项的结果记录明细列表
    */
    getDetailList() {
      this.loading = true;
      listDetails(this.queryParams2).then(response => {
        debugger;
        this.form.items = response.data;
        this.loading = false;
      });
    },

    // 取消按钮
    cancel() {
      this.open = false;
      this.reset();
    },
    // 表单重置
    reset() {
      this.form = {
        resultId: null,        resultCode: null,        sourceDocId: this.qcId,        sourceDocCode: null,        sourceDocName: null,        sourceDocType: this.qcType,        itemId: null,        itemCode: null,        itemName: null,        specification: null,        unitOfMeasure: null,        snCode: null,        remark: null,        attr1: null,        attr2: null,        attr3: null,        attr4: null,        createBy: null,        createTime: null,        updateBy: null,        updateTime: null,      
        items: [],
      };
      this.autoGenFlag = false;
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.resultId)
      this.single = selection.length!==1
      this.multiple = !selection.length
    },
    /** 新增按钮操作 */
    handleAdd() {
      this.reset();
      this.open = true;
      this.title = "添加检测结果记录";
      this.optType2 = "add";
      this.getDetailList();
    },
    /** 修改按钮操作 */
    handleUpdate(row) {
      this.reset();
      const resultId = row.resultId || this.ids
      getQcresult(resultId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "修改检测结果记录";
        this.optType2 = "edit";
        this.queryParams2.resultId = this.form.resultId
        this.getDetailList();
      });
    },
    /** 提交按钮 */
    submitForm() {
      this.$refs["form"].validate(valid => {
        if (valid) {
          debugger;
          if (this.form.resultId != null) {
            updateQcresult(this.form).then(response => {
              this.$modal.msgSuccess("修改成功");
              this.open = false;
              this.getList();
            });
          } else {
            addQcresult(this.form).then(response => {
              this.$modal.msgSuccess("新增成功");
              this.open = false;
              this.getList();
            });
          }
        }
      });
    },
    /** 删除按钮操作 */
    handleDelete(row) {
      const resultIds = row.resultId || this.ids;
      this.$modal.confirm('是否确认删除检测结果记录编号为"' + resultIds + '"的数据项？').then(function() {
        return delQcresult(resultIds);
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("删除成功");
      }).catch(() => {});
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('qc/qcresult/export', {
        ...this.queryParams
      }, `qcresult_${new Date().getTime()}.xlsx`)
    },
    /** 上传完成 */
    handleUploaded(url,index){
      this.form.items[index].qcValFile = url;
    },
    /** 移除上传文件 */
    handleRemoved(url,index){
      this.form.items[index].qcValFile = null;
    },
    //自动生成编码
    handleAutoGenChange(autoGenFlag){
      if(autoGenFlag){
        genCode('QC_RESULT_CODE').then(response =>{
          this.form.resultCode = response;
        });
      }else{
        this.form.resultCode = null;
      }
    },
  }
};
</script>

UI_MOD_QCRESULT_EOF
    ok "质量管理已按设计稿实现（设计稿 05：检验单 + 指标卡 + 合格率趋势 + 不合格原因分布）"

    cat > "$ui/src/views/mes/dv/machinery/index.vue" <<'UI_MOD_MACHINERY_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">设备管理</div>
        <div class="jt-page-sub">设备台账、点检保养、故障维修统一管理</div>
      </div>
    </div>
    <div class="jt-func-buttons">
      <span class="jt-func-btn is-active"><i class="el-icon-cpu"></i>设备档案</span>
      <span class="jt-func-btn" @click="go('/mes/dv/checkplan')"><i class="el-icon-time"></i>点检计划</span>
      <span class="jt-func-btn" @click="go('/mes/dv/repair')"><i class="el-icon-tools"></i>故障记录</span>
    </div>
    <div class="jt-stat-cards">
      <div class="jt-stat-card"><div class="jt-stat-icon is-primary"><i class="el-icon-set-up"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.total }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">台</span></div><div class="jt-stat-label">设备总数</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-success"><i class="el-icon-video-play"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.running }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">台</span></div><div class="jt-stat-label">运行中</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-warning"><i class="el-icon-video-pause"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.idle }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">台</span></div><div class="jt-stat-label">待机</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-danger"><i class="el-icon-video-pause"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.maintain }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">台</span></div><div class="jt-stat-label">维护中</div></div></div>
    </div>
    <div class="jt-grid-2">
      <div class="jt-card"><div class="jt-card-title">设备状态分布</div><div ref="jtChart1" style="height:280px;width:100%;"></div></div>
      <div class="jt-card"><div class="jt-card-title">设备运行趋势</div><div ref="jtChart2" style="height:280px;width:100%;"></div></div>
    </div>

    <el-row :gutter="20">
      <!--分类数据-->
      <el-col :span="4" :xs="24">
        <div class="head-container">
          <el-input
            v-model="machineryTypeName"
            placeholder="请输入分类名称"
            clearable
            size="small"
            prefix-icon="el-icon-search"
            style="margin-bottom: 20px"
          />
        </div>
        <div class="head-container">
          <el-tree
            :data="machineryTypeOptions"
            :props="defaultProps"
            :expand-on-click-node="false"
            :filter-node-method="filterNode"
            ref="tree"
            default-expand-all
            @node-click="handleNodeClick"
          />
        </div>
      </el-col>
      <!--设备数据-->
      <el-col :span="20" :xs="24">
        <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="68px">
          <el-form-item label="设备编码" prop="machineryCode">
            <el-input
              v-model="queryParams.machineryCode"
              placeholder="请输入设备编码"
              clearable
              style="width: 240px"
              @keyup.enter.native="handleQuery"
            />
          </el-form-item>
          <el-form-item label="设备名称" prop="machineryName">
            <el-input
              v-model="queryParams.machineryName"
              placeholder="请输入设备名称"
              clearable
              style="width: 240px"
              @keyup.enter.native="handleQuery"
            />
          </el-form-item>
          <el-form-item>
            <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">搜索</el-button>
            <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
          </el-form-item>
        </el-form>

        <el-row :gutter="10" class="mb8">
          <el-col :span="1.5">
            <el-button
              type="primary"
              plain
              icon="el-icon-plus"
              size="mini"
              @click="handleAdd"
              v-hasPermi="['mes:dv:machinery:add']"
            >新增</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="success"
              plain
              icon="el-icon-edit"
              size="mini"
              :disabled="single"
              @click="handleUpdate"
              v-hasPermi="['mes:dv:machinery:edit']"
            >修改</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="danger"
              plain
              icon="el-icon-delete"
              size="mini"
              :disabled="multiple"
              @click="handleDelete"
              v-hasPermi="['mes:dv:machinery:remove']"
            >删除</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="info"
              plain
              icon="el-icon-upload2"
              size="mini"
              @click="handleImport"
              v-hasPermi="['mes:dv:machinery:import']"
            >导入</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="warning"
              plain
              icon="el-icon-download"
              size="mini"
              @click="handleExport"
              v-hasPermi="['mes:dv:machinery:export']"
            >导出</el-button>
          </el-col>
          <right-toolbar :showSearch.sync="showSearch" @queryTable="getList"></right-toolbar>
        </el-row>

        <el-table v-loading="loading" :data="machineryList" @selection-change="handleSelectionChange">
          <el-table-column type="selection" width="50" align="center" />
          <el-table-column label="设备编码" width = "120" align="center" key="machineryCode" prop="machineryCode">
              <template slot-scope="scope">
                <el-button
                  size="mini"
                  type="text"
                  @click="handleView(scope.row)"
                  v-hasPermi="['mes:dv:machinery:query']"
                >{{scope.row.machineryCode}}</el-button>
              </template>
          </el-table-column>
          <el-table-column label="设备名称" min-width="120" align="left" key="machineryName" prop="machineryName" :show-overflow-tooltip="true" />
          <el-table-column label="品牌" align="left" key="machineryBrand" prop="machineryBrand" :show-overflow-tooltip="true" />
          <el-table-column label="规格型号" align="left" key="machinerySpec" prop="machinerySpec" :show-overflow-tooltip="true" />
          <el-table-column label="所属车间" align="center" key="workshopName" prop="workshopName"  :show-overflow-tooltip="true" />
          <el-table-column label="设备状态" align="center" key="status" prop="status" >
            <template slot-scope="scope">
              <dict-tag :options="dict.type.mes_machinery_status" :value="scope.row.status"/>
            </template>
          </el-table-column>
          <el-table-column label="创建时间" align="center" prop="createTime" width="160">
            <template slot-scope="scope">
              <span>{{ parseTime(scope.row.createTime) }}</span>
            </template>
          </el-table-column>
          <el-table-column
            label="操作"
            align="center"
            width="160"
            class-name="small-padding fixed-width"
          >
            <template slot-scope="scope">
              <el-button
                size="mini"
                type="text"
                icon="el-icon-edit"
                @click="handleUpdate(scope.row)"
                v-hasPermi="['mes:dv:machinery:edit']"
              >修改</el-button>
              <el-button
                size="mini"
                type="text"
                icon="el-icon-delete"
                @click="handleDelete(scope.row)"
                v-hasPermi="['mes:dv:machinery:remove']"
              >删除</el-button>
              <el-button
                size="mini"
                type="text"
                icon="el-icon-printer"
                @click="handleHiPrint(scope.row)"
                v-hasPermi="['mes:dv:machinery:print']"
              >标签打印</el-button>
            </template>
          </el-table-column>
        </el-table>

        <pagination
          v-show="total>0"
          :total="total"
          :page.sync="queryParams.pageNum"
          :limit.sync="queryParams.pageSize"
          @pagination="getList"
        />
      </el-col>
    </el-row>

    <!-- 添加或修改设备对话框 -->
    <el-dialog :title="title" :visible.sync="open" width="960px" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="120px">
        <el-row>
          <el-col :span="14">
            <el-row>
              <el-col :span="16">
                <el-form-item label="设备编码" prop="machineryCode">
                  <el-input v-model="form.machineryCode" :disabled="optType != 'add'" readonly="readonly" maxlength="64" v-if="['view','edit'].indexOf(optType)> -1"/>
                  <el-input v-model="form.machineryCode" :disabled="optType != 'add'" placeholder="请输入设备编码" maxlength="64" v-else/>
                </el-form-item>
              </el-col>
              <el-col :span="8">
                <el-form-item  label-width="80">
                  <el-switch v-model="autoGenFlag"
                             active-color="#13ce66"
                             active-text="自动生成"
                             @change="handleAutoGenChange(autoGenFlag)" v-if="['view','edit'].indexOf(optType)< 0">
                  </el-switch>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="设备名称" prop="machineryName">
                  <el-input v-model="form.machineryName"  maxlength="255" readonly="readonly" v-if="optType=='view'" />
                  <el-input v-model="form.machineryName" placeholder="请输入设备名称" maxlength="255" v-else/>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="品牌" prop="machineryBrand">
                  <el-input v-model="form.machineryBrand"  maxlength="255" readonly="readonly" v-if="optType=='view'" />
                  <el-input v-model="form.machineryBrand"  placeholder="请输入品牌" maxlength="255" v-else/>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item  label="设备分类" prop="machineryTypeId">
                  <treeselect v-model="form.machineryTypeId" :options="machineryTypeOptions" :normalizer="normalizer" disabled v-if="optType=='view'"  />
                  <treeselect v-model="form.machineryTypeId" :options="machineryTypeOptions" :normalizer="normalizer" placeholder="请选择所属分类" v-else :disable-branch-nodes='true' />
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="12">
                <el-form-item label="所属车间" prop="workshopId">
                  <el-select v-model="form.workshopId" @change="changeWorkshop" placeholder="请选择车间">
                    <el-option
                        v-for="item in workshopOptions"
                        :key="item.workshopId"
                        :label="item.workshopName"
                        :value="item.workshopId"
                    ></el-option>
                  </el-select>
                </el-form-item>
              </el-col>
              <el-col :span="12">
                <el-form-item label="设备状态" prop="status">
                  <el-select v-model="form.status" placeholder="请选择设备状态">
                    <el-option
                      v-for="item in dict.type.mes_machinery_status"
                      :key="item.value"
                      :label="item.label"
                      :value="item.value"
                    ></el-option>
                  </el-select>
                </el-form-item>
              </el-col>
            </el-row>
          </el-col>
          <el-col :span="10">
            <BarcodeImg ref="barcodeImg" :bussinessId="form.machineryId" :bussinessCode="form.machineryCode" barcodeType="MACHINERY"></BarcodeImg>
          </el-col>
        </el-row>
        <el-row v-if="form.machineryId !=null">
          <el-col :span="12">
            <el-form-item label="最近点检时间" prop="lastCheckTime">
              <el-date-picker clearable
                v-model="form.lastCheckTime"
                readonly
                type="datetime"
                value-format="yyyy-MM-dd HH:mm:ss">
              </el-date-picker>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="最近保养时间" prop="lastMaintenTime">
              <el-date-picker clearable
                v-model="form.lastMaintenTime"
                readonly
                type="datetime"
                value-format="yyyy-MM-dd HH:mm:ss">
              </el-date-picker>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="规格型号" prop="machinerySpec">
              <el-input v-model="form.machinerySpec" type="textarea" maxlength="255" readonly="readonly" v-if="optType=='view'" />
              <el-input v-model="form.machinerySpec" type="textarea" placeholder="请输入规格型号" maxlength="255" v-else/>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" readonly v-if="optType=='view'"></el-input>
              <el-input v-model="form.remark" type="textarea" placeholder="请输入内容" v-else></el-input>
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <el-tabs type="border-card" v-model="activeName" v-if="optType != 'add'" @tab-click="handleActive">
        <el-tab-pane label="点检记录" name="check">
          <CheckPlan ref="checkList" />
        </el-tab-pane>
        <el-tab-pane label="保养记录" name="maintenance">
          <CheckPlan ref="maintenanceList" />
        </el-tab-pane>
        <el-tab-pane label="维修记录" name="repair">
          <Repair ref="repairList" />
        </el-tab-pane>
      </el-tabs>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitForm" v-if="optType !='view'">确 定</el-button>
        <el-button @click="cancel">取 消</el-button>
      </div>
    </el-dialog>

    <!-- 物料导入对话框 -->
    <el-dialog :title="upload.title" :visible.sync="upload.open" width="400px" append-to-body>
      <el-upload
        ref="upload"
        :limit="1"
        accept=".xlsx, .xls"
        :headers="upload.headers"
        :action="upload.url + '?updateSupport=' + upload.updateSupport"
        :disabled="upload.isUploading"
        :on-progress="handleFileUploadProgress"
        :on-success="handleFileSuccess"
        :auto-upload="false"
        drag
      >
        <i class="el-icon-upload"></i>
        <div class="el-upload__text">将文件拖到此处，或<em>点击上传</em></div>
        <div class="el-upload__tip text-center" slot="tip">
          <div class="el-upload__tip" slot="tip">
            <el-checkbox v-model="upload.updateSupport" /> 是否更新已经存在的设备数据
          </div>
          <span>仅允许导入xls、xlsx格式文件。</span>
          <el-link type="primary" :underline="false" style="font-size:12px;vertical-align: baseline;" @click="importTemplate">下载模板</el-link>
        </div>
      </el-upload>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitFileForm">确 定</el-button>
        <el-button @click="upload.open = false">取 消</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listMachinery, getMachinery, delMachinery, addMachinery, updateMachinery } from "@/api/mes/dv/machinery";
import echarts from 'echarts'
import { listMachinerytype } from "@/api/mes/dv/machinerytype";
import { listAllWorkshop } from "@/api/mes/md/workshop";
import {genCode} from "@/api/system/autocode/rule"
import { getToken } from "@/utils/auth";
import Treeselect from "@riophae/vue-treeselect";
import "@riophae/vue-treeselect/dist/vue-treeselect.css";
import BarcodeImg from "@/components/barcodeImg/index.vue";
import CheckPlan from "@/views/mes/dv/machinery/components/Checkplan.vue"
import Repair from "@/views/mes/dv/machinery/components/Repair.vue"
import {getBarcodeUrl} from "@/api/mes/wm/barcode";
import { option } from "runjs";
import { hiprintMixin } from "../../../../mixins/hiprintMixin";
import {print} from "../../../../utils/print"
import {getByTemplateType} from "@/api/print/template";

export default {
  name: "Machinery",
  dicts: ['sys_yes_no','mes_machinery_status'],
  components: { Treeselect,BarcodeImg, CheckPlan, Repair },
  mixins: [hiprintMixin],
  data() {
    return {
      activeName: "check",
      //自动生成编码
      autoGenFlag:false,
      optType: undefined,
      // 遮罩层
      loading: true,
      // 选中数组
      ids: [],
      // 非单个禁用
      single: true,
      // 非多个禁用
      multiple: true,
      // 显示搜索条件
      showSearch: true,
      // 总条数
      total: 0,
      jtStats: { total: 48, running: 32, idle: 10, maintain: 6 },
      jtChart1Option: null,
      jtChart2Option: null,

      // 物料产品表格数据
      machineryList: [],
      // 弹出层标题
      title: "",
      // 设备类型树选项
      machineryTypeOptions: [],
      //车间选项
      workshopOptions:[],
      // 是否显示弹出层
      open: false,
      // 设备类型名称
      machineryTypeName: undefined,
      // 表单参数
      form: {},
      defaultProps: {
        children: "children",
        label: "machineryTypeName"
      },
      // 用户导入参数
      upload: {
        // 是否显示弹出层（用户导入）
        open: false,
        // 弹出层标题（用户导入）
        title: "",
        // 是否禁用上传
        isUploading: false,
        // 是否更新已经存在的用户数据
        updateSupport: 0,
        // 设置上传的请求头部
        headers: { Authorization: "Bearer " + getToken() },
        // 上传的地址
        url: process.env.VUE_APP_BASE_API + "/mes/dv/machinery/importData"
      },
      //二维码查询参数
      barcodeParams: {
        bussinessId: null,
        bussinessCode: null,
        barcodeFormart: 'QR_CODE', //模式二维码
        barcodeType: 'MACHINERY' //类型
      },
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        machineryCode: null,
        machineryName: null,
        machineryBrand: null,
        machinerySpec: null,
        machineryTypeId: null,
        machineryTypeCode: null,
        machineryTypeName: null,
        workshopId: null,
        workshopCode: null,
        workshopName: null,
        status: null
      },

      // 表单校验
      rules: {
        machineryCode: [
          { required: true, message: "设备编码不能为空", trigger: "blur" },
          { max: 64, message: '设备编码长度必须小于64个字符', trigger: 'blur' }
        ],
        machineryName: [
          { required: true, message: "设备名称不能为空", trigger: "blur" }
        ],
        workshopId: [
          { required: true, message: "车间不能为空",trigger: "blur"}
        ],
        machineryTypeId: [
          { required: true, message: "设备分类不能为空", trigger: "blur" },
        ],
        remark: [
          { max: 250, message: '长度必须小于250个字符', trigger: 'blur' }
        ]
      }
    };
  },
  watch: {
    // 根据设备分类名称筛选分类树
    machineryTypeName(val) {
      this.$refs.tree.filter(val);
    }
  },
    mounted() {
    this.$nextTick(() => { this.initJtCharts(); });
  },
  created() {
    this.getList();
      this.calcJtStats();
    this.getTreeselect();
  },
  methods: {

    /** 设计稿统计：设备指标 */
    calcJtStats() {
      const list = this.machineryList || [];
      if (list.length) {
        let run = 0, idle = 0, maint = 0;
        list.forEach(m => {
          if (m.status === 1) { run++; }
          else if (m.status === 2 || m.status === 3) { maint++; }
          else { idle++; }
        });
        this.jtStats.total = list.length;
        this.jtStats.running = run;
        this.jtStats.idle = idle;
        this.jtStats.maintain = maint;
      }
      this.buildJtCharts(list);
    },
    buildJtCharts(list) {
      const hasData = list.length > 0;
      const total = hasData ? list.length : 48;
      const run = hasData ? list.filter(m => m.status === 1).length : 32;
      const idle = hasData ? list.filter(m => !(m.status === 1 || m.status === 2 || m.status === 3)).length : 10;
      const maint = hasData ? list.filter(m => m.status === 2 || m.status === 3).length : 6;
      this.jtChart1Option = {
        tooltip: { trigger: 'item', formatter: '{b}: {c} 台 ({d}%)' },
        legend: { bottom: 0, textStyle: { color: '#8a94a6' } },
        color: ['#10b981', '#f59e0b', '#ef4444'],
        series: [{
          type: 'pie', radius: ['45%', '70%'], center: ['50%', '44%'],
          data: [
            { name: '运行中', value: run },
            { name: '待机', value: idle },
            { name: '维护中', value: maint }
          ],
          label: { formatter: '{b}\n{c}台', color: '#1f2d3d' }
        }]
      };
      this.jtChart2Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['运行时长(h)'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: ['周一','周二','周三','周四','周五','周六','周日'], axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [{
          name: '运行时长(h)', type: 'line', smooth: true, data: [180, 195, 172, 210, 188, 120, 0],
          symbol: 'circle', symbolSize: 6, lineStyle: { color: '#0F3460', width: 3 }, itemStyle: { color: '#0F3460' },
          areaStyle: { color: 'rgba(15,52,96,0.10)' }
        }]
      };
    },

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    // 使用HiPrint打印
    async handleHiPrint(row) {
      let printData = row
      let printTemplate
      // 处理数据 - 获取条形码图片地址
      let barcodeParams = {
        bussinessId: row.machineryId,
        bussinessCode: row.machineryCode,
        barcodeFormart: "QR_CODE",
        barcodeType: "MACHINERY"
      };
      await getBarcodeUrl(barcodeParams).then(res => {
        if (res.data) {
          printData.barcodeContent = res.data.barcodeContent
        } else {
          printData.barcodeContent = ''
        }
      })
      // 获取打印模板
      let templateStatus = true
      await getByTemplateType("MACHINERY").then(res => {
        printTemplate = res.data.templateJson
      }).catch(err => {
        templateStatus = false
      })
      if (templateStatus) {
        print(printTemplate, printData, this.hiprintTemplate, this.hiprintThis)
      }

    },
    handleActive (tab) {
      const query = {}
      query.machineryCode = this.form.machineryCode
      if (tab.name == "check") {
        query.planType = "CHECK"
        this.$refs.checkList.getOpen(query)
      }
      if (tab.name == "maintenance") {
        query.planType = "MAINTEN"
        this.$refs.maintenanceList.getOpen(query)
      }
      if (tab.name == "repair") {
        this.$refs.repairList.getOpen(query)
      }
    },
    changeWorkshop(val) {
      const workshop = this.workshopOptions.filter(item => item.workshopId == val)
      this.form.workshopId = workshop[0].workshopId
      this.form.workshopName = workshop[0].workshopName
      this.form.workshopCode = workshop[0].workshopCode
    },
    /** 查询物料编码列表 */
    getList() {
      this.loading = true;
      listMachinery(this.queryParams).then(response => {
          this.machineryList = response.rows;
          this.total = response.total;
          this.loading = false;
        this.calcJtStats();
        this.$nextTick(() => this.initJtCharts());
        }
      );
    },
    getWorkshops(){
      listAllWorkshop().then( response => {
        this.workshopOptions =response.data;
      });
    },
    /** 转换设备类型数据结构 */
    normalizer(node) {
      if (node.children && !node.children.length) {
        delete node.children;
      }
      return {
        id: node.machineryTypeId,
        label: node.machineryTypeName,
        children: node.children
      };
    },
	/** 查询设备类型下拉树结构 */
    getTreeselect() {
      listMachinerytype().then(response => {
        debugger;
        this.machineryTypeOptions = [];
        const data = this.handleTree(response.data, "machineryTypeId", "parentTypeId")[0];
        this.machineryTypeOptions.push(data);
      });
    },
    // 筛选节点
    filterNode(value, data) {
      if (!value) return true;
      return data.machineryTypeName.indexOf(value) !== -1;
    },
    // 节点单击事件
    handleNodeClick(data) {
      this.queryParams.machineryTypeId = data.machineryTypeId;
      this.handleQuery();
    },
    // 取消按钮
    cancel() {
      this.open = false;
      this.reset();
    },
    // 表单重置
    reset() {
      this.form = {
        machineryId: null,
        machineryCode: null,
        machineryName: null,
        machineryBrand: null,
        machinerySpec: null,
        machineryTypeId: null,
        machineryTypeCode: null,
        machineryTypeName: null,
        workshopId: null,
        workshopCode: null,
        workshopName: null,
        lastMaintenTime: null,
        lastCheckTime: null,
        status: "STOP",
        remark: null,
        createBy: null,
        createTime: null,
        updateBy: null,
        updateTime: null
      };
      this.autoGenFlag = false;
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.machineryId);
      this.single = selection.length != 1;
      this.multiple = !selection.length;
    },
    // 查询明细按钮操作
    handleView(row){
      this.reset();
      this.getTreeselect();
      this.getWorkshops();
      const machineryId = row.machineryId || this.ids;
      getMachinery(machineryId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "查看设备信息";
        this.optType = "view";
        this.activeName = "check"
        const query = {
          machineryCode: this.form.machineryCode,
          planType: "CHECK"
        }
        this.$nextTick(()=>{
          this.$refs.barcodeImg.getBarcode();
          this.$refs.checkList.getOpen(query)
        })
      });
    },
    /** 新增按钮操作 */
    handleAdd() {
      debugger;
      this.reset();
      this.getTreeselect();
      this.getWorkshops();
      if(this.queryParams.machineryTypeId != 0){
        this.form.machineryTypeId = this.queryParams.machineryTypeId;
      }
      this.optType = "add";
      this.open = true;
      this.title = "新增设备";
    },
    /** 修改按钮操作 */
    handleUpdate(row) {
      this.reset();
      this.getTreeselect();
      this.getWorkshops();
      const machineryId = row.machineryId || this.ids
      getMachinery(machineryId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "修改设备";
        this.optType = "edit";
        this.activeName = "check"
        const query = {
          machineryCode: this.form.machineryCode,
          planType: "CHECK"
        }
        this.$nextTick(()=>{
          this.$refs.barcodeImg.getBarcode();
          this.$refs.checkList.getOpen(query)
        })
      });
    },

    /** 提交按钮 */
    submitForm: function() {
      this.$refs["form"].validate(valid => {
        if (valid) {
          if (this.form.machineryId != undefined) {
            updateMachinery(this.form).then(response => {
              this.$modal.msgSuccess("修改成功");
              this.open = false;
              this.getList();
            });
          } else {
            debugger;
            addMachinery(this.form).then(response => {
              this.$modal.msgSuccess("新增成功");
              this.open = false;
              this.getList();
            });
          }
        }
      });
    },
    /** 删除按钮操作 */
    handleDelete(row) {
      const machineryIds = row.machineryId || this.ids;
      this.$modal.confirm('确认删除数据项？').then(function() {
        return delMachinery(machineryIds);
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("删除成功");
      }).catch(() => {});
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('mes/dv/machinery/export', {
        ...this.queryParams
      }, `user_${new Date().getTime()}.xlsx`)
    },
    /** 导入按钮操作 */
    handleImport() {
      this.upload.title = "设备导入";
      this.upload.open = true;
    },
    /** 下载模板操作 */
    importTemplate() {
      this.download('mes/dv/machinery/importTemplate', {
      }, `md_item_${new Date().getTime()}.xlsx`)
    },
    // 文件上传中处理
    handleFileUploadProgress(event, file, fileList) {
      this.upload.isUploading = true;
    },
    // 文件上传成功处理
    handleFileSuccess(response, file, fileList) {
      this.upload.open = false;
      this.upload.isUploading = false;
      this.$refs.upload.clearFiles();
      this.$alert("<div style='overflow: auto;overflow-x: hidden;max-height: 70vh;padding: 10px 20px 0;'>" + response.msg + "</div>", "导入结果", { dangerouslyUseHTMLString: true });
      this.getList();
    },
    // 提交上传文件
    submitFileForm() {
      this.$refs.upload.submit();
    },
    //自动生成编码
    handleAutoGenChange(autoGenFlag){
      if(autoGenFlag){
        genCode('MACHINERY_CODE').then(response =>{
          this.form.machineryCode = response;
        });
      }else{
        this.form.machineryCode = null;
      }
    }
  }
};
</script>
<style scoped>
.flex-container{
  display: flex;
  justify-content: center; /* 水平居中 */
  align-items: center; /* 垂直居中 */
}
.barcodeClass {
  width: 200px;
  height: 200px;
  border: 1px dashed;
  position: relative;
  display: inline-block;
}
</style>

UI_MOD_MACHINERY_EOF
    ok "设备管理已按设计稿实现（设计稿 06：3 功能按钮 + 指标卡 + 状态分布 + 运行趋势）"

    cat > "$ui/src/views/mes/cal/plan/index.vue" <<'UI_MOD_PLAN_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">排班管理</div>
        <div class="jt-page-sub">班组、班次、节假日、排班日历统一管理</div>
      </div>
    </div>
    <div class="jt-stat-cards">
      <div class="jt-stat-card"><div class="jt-stat-icon is-primary"><i class="el-icon-user"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.schedTotal }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">人</span></div><div class="jt-stat-label">今日排班</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-success"><i class="el-icon-user-solid"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.onDuty }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">人</span></div><div class="jt-stat-label">在岗</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-warning"><i class="el-icon-moon"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.rest }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">人</span></div><div class="jt-stat-label">休息</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-danger"><i class="el-icon-circle-close"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.absent }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">人</span></div><div class="jt-stat-label">缺勤</div></div></div>
    </div>
    <div class="jt-grid-2">
      <div class="jt-card"><div class="jt-card-title">本周排班概览</div>
        <div class="jt-week-grid">
          <div class="jt-week-head" v-for="d in jtWeekDays" :key="'h'+d">{{ d }}</div>
          <div class="jt-week-cell" :class="jtWeekData[i-1].cls" v-for="i in 6" :key="'c'+i">{{ jtWeekData[i-1].name }}</div>
        </div>
      </div>
      <div class="jt-card"><div class="jt-card-title">各班组人员分布</div><div ref="jtChart2" style="height:220px;width:100%;"></div></div>
    </div>

    <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="68px">
      <el-form-item label="班组类型" prop="calendarType">
        <el-select v-model="queryParams.calendarType" placeholder="请选择班组类型">
          <el-option
            v-for="dict in dict.type.mes_calendar_type"
            :key="dict.value"
            :label="dict.label"
            :value="dict.value"
          />
        </el-select>
      </el-form-item>
      <el-form-item label="计划编号" prop="planCode">
        <el-input
          v-model="queryParams.planCode"
          placeholder="请输入计划编号"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="计划名称" prop="planName">
        <el-input
          v-model="queryParams.planName"
          placeholder="请输入计划名称"
          clearable
          @keyup.enter.native="handleQuery"
        />
      </el-form-item>
      <el-form-item label="开始日期" prop="startDate">
        <el-date-picker clearable
          v-model="queryParams.startDate"
          type="date"
          value-format="yyyy-MM-dd"
          placeholder="请选择开始日期">
        </el-date-picker>
      </el-form-item>
      <el-form-item label="结束日期" prop="endDate">
        <el-date-picker clearable
          v-model="queryParams.endDate"
          type="date"
          value-format="yyyy-MM-dd"
          placeholder="请选择结束日期">
        </el-date-picker>
      </el-form-item>
      <el-form-item>
        <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">搜索</el-button>
        <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
      </el-form-item>
    </el-form>

    <el-row :gutter="10" class="mb8">
      <el-col :span="1.5">
        <el-button
          type="primary"
          plain
          icon="el-icon-plus"
          size="mini"
          @click="handleAdd"
          v-hasPermi="['mes:cal:calplan:add']"
        >新增</el-button>
      </el-col>
      <el-col :span="1.5">
        <el-button
          type="danger"
          plain
          icon="el-icon-delete"
          size="mini"
          :disabled="multiple"
          @click="handleDelete"
          v-hasPermi="['mes:cal:calplan:remove']"
        >删除</el-button>
      </el-col>
      <el-col :span="1.5">
        <el-button
          type="warning"
          plain
          icon="el-icon-download"
          size="mini"
          @click="handleExport"
          v-hasPermi="['mes:cal:calplan:export']"
        >导出</el-button>
      </el-col>
      <right-toolbar :showSearch.sync="showSearch" @queryTable="getList"></right-toolbar>
    </el-row>

    <el-table v-loading="loading" :data="calplanList" @selection-change="handleSelectionChange">
      <el-table-column type="selection" width="55" align="center" />
      <el-table-column label="计划编号" align="center" prop="planCode" >
          <template slot-scope="scope">
                <el-button
                  type="text"
                  @click="handleView(scope.row)"
                  v-hasPermi="['mes:cal:calplan:query']"
                >{{scope.row.planCode}}</el-button>
          </template>
      </el-table-column>
      <el-table-column label="计划名称" width="200px" align="center" prop="planName" :show-overflow-tooltip="true"/>
      <el-table-column label="班组类型" align="center" prop="calendarType">
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_calendar_type" :value="scope.row.calendarType"/>
        </template>
      </el-table-column>
      <el-table-column label="开始日期" align="center" prop="startDate" width="120">
        <template slot-scope="scope">
          <span>{{ parseTime(scope.row.startDate, '{y}-{m}-{d}') }}</span>
        </template>
      </el-table-column>
      <el-table-column label="结束日期" align="center" prop="endDate" width="120">
        <template slot-scope="scope">
          <span>{{ parseTime(scope.row.endDate, '{y}-{m}-{d}') }}</span>
        </template>
      </el-table-column>
      <el-table-column label="轮班方式" align="center" prop="shiftType" >
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_shift_type" :value="scope.row.shiftType"/>
        </template>
      </el-table-column>
      <el-table-column label="倒班方式" align="center" prop="shiftMethod" >
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_shift_method" :value="scope.row.shiftMethod"/>
        </template>
      </el-table-column>
      <el-table-column label="单据状态" align="center" prop="status">
        <template slot-scope="scope">
          <dict-tag :options="dict.type.mes_order_status" :value="scope.row.status"/>
        </template>
      </el-table-column>
      <el-table-column label="操作" align="center" class-name="small-padding fixed-width" >
        <template slot-scope="scope">
          <el-button
            size="mini"
            type="text"
            icon="el-icon-edit"
            v-if="scope.row.status =='PREPARE'"
            @click="handleUpdate(scope.row)"
            v-hasPermi="['mes:cal:calplan:edit']"
          >修改</el-button>
          <el-button
            size="mini"
            type="text"
            icon="el-icon-delete"
            v-if="scope.row.status =='PREPARE'"
            @click="handleDelete(scope.row)"
            v-hasPermi="['mes:cal:calplan:remove']"
          >删除</el-button>
        </template>
      </el-table-column>
    </el-table>

    <pagination
      v-show="total>0"
      :total="total"
      :page.sync="queryParams.pageNum"
      :limit.sync="queryParams.pageSize"
      @pagination="getList"
    />

    <!-- 添加或修改排班计划对话框 -->
    <el-dialog :title="title" v-loading="formLoading" :visible.sync="open" width="960px" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="100px">
        <el-row>
          <el-col :span="8">
            <el-form-item label="计划编号" prop="planCode">
              <el-input v-model="form.planCode" placeholder="请输入计划编号" />
            </el-form-item>
          </el-col>
          <el-col :span="4">
            <el-form-item  label-width="80">
              <el-switch v-model="autoGenFlag"
                  active-color="#13ce66"
                  active-text="自动生成"
                  @change="handleAutoGenChange(autoGenFlag)" v-if="optType != 'view'" >
              </el-switch>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="计划名称" prop="planName">
              <el-input v-model="form.planName" placeholder="请输入计划名称" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="8">
            <el-form-item label="开始日期" prop="startDate">
              <el-date-picker clearable
                v-model="form.startDate"
                type="date"
                value-format="yyyy-MM-dd"
                placeholder="请选择开始日期">
              </el-date-picker>
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="结束日期" prop="endDate">
              <el-date-picker clearable
                v-model="form.endDate"
                type="date"
                value-format="yyyy-MM-dd"
                placeholder="请选择结束日期">
              </el-date-picker>
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="班组类型" prop="calendarType">
              <el-select v-model="form.calendarType" placeholder="请选择班组类型">
                <el-option
                  v-for="dict in dict.type.mes_calendar_type"
                  :key="dict.value"
                  :label="dict.label"
                  :value="dict.value"
                />
              </el-select>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item label="轮班方式">
              <el-radio-group v-model="form.shiftType">
                <el-radio
                  v-for="dict in dict.type.mes_shift_type"
                  :key="dict.value"
                  :label="dict.value"
                >{{dict.label}}</el-radio>
              </el-radio-group>
            </el-form-item>
          </el-col>
          <el-col v-if="form.shiftType !='SINGLE'" :span="6">
            <el-form-item label="倒班方式" prop="shiftMethod">
              <el-select style="width:100px" v-model="form.shiftMethod" placeholder="请选择倒班方式">
                <el-option
                  v-for="dict in dict.type.mes_shift_method"
                  :key="dict.value"
                  :label="dict.label"
                  :value="dict.value"
                ></el-option>
              </el-select>
            </el-form-item>
          </el-col>
          <el-col v-if="form.shiftMethod =='DAY' && form.shiftType !='SINGLE'" :span="6">
            <el-form-item label-width="20" prop="shiftCount">
              <el-input-number :min="1"  controls-position="right" v-model="form.shiftCount" >
              </el-input-number>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" placeholder="请输入内容" />
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <el-tabs type="border-card" v-if="form.planId != null">
        <el-tab-pane label="班次">
          <Shift ref="shiftTab" :planId="form.planId" :optType="optType"></Shift>
        </el-tab-pane>
        <el-tab-pane label="班组">
          <Team  ref="teamTab" :planId="form.planId" :calendarType="form.calendarType" :optType="optType"></Team>
        </el-tab-pane>
      </el-tabs>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitForm" v-if="form.status =='PREPARE' && optType !='view' ">确 定</el-button>
        <el-button type="success" @click="handleFinish" v-if="form.status =='PREPARE' && optType !='view'  && form.planId !=null">完成</el-button>
        <el-button @click="cancel">取 消</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listCalplan, getCalplan, delCalplan, addCalplan, updateCalplan } from "@/api/mes/cal/calplan";
import echarts from 'echarts'
import Shift from "./shift";
import Team  from "./team";
import {genCode} from "@/api/system/autocode/rule"
export default {
  name: "Calplan",
  dicts: ['mes_shift_method','mes_shift_type','mes_calendar_type','mes_order_status'],
  components: {Shift,Team},
  data() {
    return {
      //自动生成编码
      autoGenFlag:false,
      optType: undefined,
      // 遮罩层
      loading: true,
      formLoading: false,
      // 选中数组
      ids: [],
      // 非单个禁用
      single: true,
      // 非多个禁用
      multiple: true,
      // 显示搜索条件
      showSearch: true,
      // 总条数
      total: 0,
      jtStats: { schedTotal: 126, onDuty: 98, rest: 20, absent: 8 },
      jtChart1Option: null,
      jtChart2Option: null,
      jtWeekDays: ['周一','周二','周三','周四','周五','周六'],
      jtWeekData: [
        { name: '早班', cls: 'early' }, { name: '中班', cls: 'mid' },
        { name: '夜班', cls: 'night' }, { name: '早班', cls: 'early' },
        { name: '中班', cls: 'mid' }, { name: '早班', cls: 'early' }
      ],

      // 排班计划表格数据
      calplanList: [],
      // 弹出层标题
      title: "",
      // 是否显示弹出层
      open: false,
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        planCode: null,
        planName: null,
        calendarType:null,
        startDate: null,
        endDate: null,
        shiftType: null,
        shiftMethod: null,
      },
      // 表单参数
      form: {},
      // 表单校验
      rules: {
        planCode: [
          { required: true, message: "计划编号不能为空", trigger: "blur" },
          { max: 64, message: "字段过长", trigger: "blur" }
        ],
        planName: [
          { required: true, message: "计划名称不能为空", trigger: "blur" },
          { max: 100, message: "字段过长", trigger: "blur" }
        ],
        calendarType:[
          { required: true, message: "请选择班组类型", trigger: "blur" }
        ],
        startDate: [
          { required: true, message: "开始日期不能为空", trigger: "blur" }
        ],
        endDate: [
          { required: true, message: "结束日期不能为空", trigger: "blur" }
        ],
        remark: [
          { max: 250, message: '长度必须小于250个字符', trigger: 'blur' }
        ]
      }
    };
  },
    mounted() {
    this.$nextTick(() => { this.initJtCharts(); });
  },
  created() {
    this.getList();
      this.calcJtStats();
  },
  methods: {

    /** 设计稿统计：排班指标 */
    calcJtStats() {
      const list = this.calplanList || [];
      if (list.length) {
        this.jtStats.schedTotal = list.length * 3 || 126;
      }
      this.buildJtCharts(list);
    },
    buildJtCharts(list) {
      const teamNames = ['装配一组','装配二组','机加一组','机加二组','质检组'];
      const teamData = [22, 20, 26, 24, 18];
      this.jtChart2Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['人数'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: teamNames, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [{
          name: '人数', type: 'bar', barWidth: 22, data: teamData,
          itemStyle: { color: '#0F3460', borderRadius: [4, 4, 0, 0] }
        }]
      };
    },

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    /** 查询排班计划列表 */
    getList() {
      this.loading = true;
      listCalplan(this.queryParams).then(response => {
        this.calplanList = response.rows;
        this.total = response.total;
        this.loading = false;
        this.calcJtStats();
        this.$nextTick(() => this.initJtCharts());
      });
    },
    // 取消按钮
    cancel() {
      this.open = false;
      this.reset();
    },
    // 表单重置
    reset() {
      this.form = {
        planId: null,
        planCode: null,
        planName: null,
        calendarType:null,
        startDate: null,
        endDate: null,
        shiftType: 'SHIFT_TWO',
        shiftMethod: 'MONTH',
        shiftCount: 1,
        status: "PREPARE",
        remark: null,
        attr1: null,
        attr2: null,
        attr3: null,
        attr4: null,
        createBy: null,
        createTime: null,
        updateBy: null,
        updateTime: null
      };
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.planId)
      this.single = selection.length!==1
      this.multiple = !selection.length
    },
    /** 新增按钮操作 */
    handleAdd() {
      this.reset();
      this.open = true;
      this.title = "添加排班计划";
      this.optType = "add";
    },
    // 查询明细按钮操作
    handleView(row){
      this.reset();
      const planId = row.planId || this.ids
      getCalplan(planId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "查看排班计划";
        this.optType = "view";
      });
    },
    /** 修改按钮操作 */
    handleUpdate(row) {
      this.reset();
      const planId = row.planId || this.ids
      getCalplan(planId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "修改排班计划";
        this.optType = "edit";
      });
    },
    /** 提交按钮 */
    submitForm() {
      this.$refs["form"].validate(valid => {
        if (valid) {
          if (this.form.planId != null) {
            updateCalplan(this.form).then(response => {
              this.$modal.msgSuccess("修改成功");
              this.open = false;
              this.getList();
            });
          } else {
            addCalplan(this.form).then(response => {
              this.$modal.msgSuccess("新增成功");
              this.open = false;
              this.getList();
            });
          }
        }
      });
    },
    /** 删除按钮操作 */
    handleDelete(row) {
      const planIds = row.planId || this.ids;
      this.$modal.confirm('是否确认删除排班计划编号为"' + planIds + '"的数据项？').then(function() {
        return delCalplan(planIds);
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("删除成功");
      }).catch(() => {});
    },
    handleFinish(){
      let that = this;
      this.$modal.confirm('是否完成计划编制？【完成后将不能更改】').then(function(){
        that.form.status = 'CONFIRMED';
        that.$refs["form"].validate(valid => {
        if (valid) {
          if (that.form.planId != null) {
            updateCalplan(that.form).then(response => {
              that.$modal.msgSuccess("已完成");
              that.open = false;
              that.getList();
              that.formLoading = false;
            },err =>{
              that.form.status = 'PREPARE';
              that.formLoading = false;
            });
          }
        }
      });
      });
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('cal/calplan/export', {
        ...this.queryParams
      }, `calplan_${new Date().getTime()}.xlsx`)
    },
    //自动生成编码
    handleAutoGenChange(autoGenFlag){
      if(autoGenFlag){
        genCode('CAL_PLAN_CODE').then(response =>{
          this.form.planCode = response;
        });
      }else{
        this.form.planCode = null;
      }
    },
  }
};
</script>
<style lang="scss" scoped>
.jt-week-grid {
  display: grid;
  grid-template-columns: repeat(6, 1fr);
  gap: 8px;
}
.jt-week-head {
  text-align: center;
  font-size: 13px;
  color: #8a94a6;
  padding: 4px 0;
}
.jt-week-cell {
  text-align: center;
  font-size: 13px;
  font-weight: 600;
  color: #1f2d3d;
  padding: 14px 0;
  border-radius: 6px;
}
.jt-week-cell.early { background: #dbeafe; }
.jt-week-cell.mid { background: #fef3c7; }
.jt-week-cell.night { background: #c7d2fe; }
</style>

UI_MOD_PLAN_EOF
    ok "排班管理已按设计稿实现（设计稿 08：指标卡 + 本周排班概览 + 班组分布）"

    cat > "$ui/src/views/monitor/server/index.vue" <<'UI_MOD_SERVER_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">系统监控</div>
        <div class="jt-page-sub">服务器资源、接口调用、服务运行状态实时监控</div>
      </div>
    </div>
    <div class="jt-stat-cards">
      <div class="jt-stat-card"><div class="jt-stat-icon is-primary"><i class="el-icon-cpu"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.cpu }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div><div class="jt-stat-label">CPU使用率</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-success"><i class="el-icon-coin"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.mem }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div><div class="jt-stat-label">内存使用率</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-warning"><i class="el-icon-folder-opened"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.disk }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">%</span></div><div class="jt-stat-label">磁盘使用率</div></div></div>
      <div class="jt-stat-card"><div class="jt-stat-icon is-info"><i class="el-icon-user"></i></div><div class="jt-stat-body"><div class="jt-stat-value">{{ jtStats.online }}<span style="font-size:14px;color:#8a94a6;margin-left:2px;">人</span></div><div class="jt-stat-label">在线用户</div></div></div>
    </div>
    <div class="jt-grid-2">
      <div class="jt-card"><div class="jt-card-title">服务器资源趋势</div><div ref="jtChart1" style="height:280px;width:100%;"></div></div>
      <div class="jt-card"><div class="jt-card-title">接口调用量</div><div ref="jtChart2" style="height:280px;width:100%;"></div></div>
    </div>
    <div class="jt-card">
      <div class="jt-card-title">服务状态</div>
      <div class="jt-service-grid">
        <div class="jt-service-item"><span class="dot is-run"></span>数据库 <span class="up">运行中</span></div>
        <div class="jt-service-item"><span class="dot is-run"></span>Redis <span class="up">运行中</span></div>
        <div class="jt-service-item"><span class="dot is-run"></span>MQ <span class="up">运行中</span></div>
        <div class="jt-service-item"><span class="dot is-run"></span>文件服务 <span class="up">运行中</span></div>
      </div>
    </div>

    <el-row>
      <el-col :span="12" class="card-box">
        <el-card>
          <div slot="header"><span>CPU</span></div>
          <div class="el-table el-table--enable-row-hover el-table--medium">
            <table cellspacing="0" style="width: 100%;">
              <thead>
                <tr>
                  <th class="el-table__cell is-leaf"><div class="cell">属性</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">值</div></th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">核心数</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.cpu">{{ server.cpu.cpuNum }}</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">用户使用率</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.cpu">{{ server.cpu.used }}%</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">系统使用率</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.cpu">{{ server.cpu.sys }}%</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">当前空闲率</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.cpu">{{ server.cpu.free }}%</div></td>
                </tr>
              </tbody>
            </table>
          </div>
        </el-card>
      </el-col>

      <el-col :span="12" class="card-box">
        <el-card>
          <div slot="header"><span>内存</span></div>
          <div class="el-table el-table--enable-row-hover el-table--medium">
            <table cellspacing="0" style="width: 100%;">
              <thead>
                <tr>
                  <th class="el-table__cell is-leaf"><div class="cell">属性</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">内存</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">JVM</div></th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">总内存</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.mem">{{ server.mem.total }}G</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.total }}M</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">已用内存</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.mem">{{ server.mem.used}}G</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.used}}M</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">剩余内存</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.mem">{{ server.mem.free }}G</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.free }}M</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">使用率</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.mem" :class="{'text-danger': server.mem.usage > 80}">{{ server.mem.usage }}%</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm" :class="{'text-danger': server.jvm.usage > 80}">{{ server.jvm.usage }}%</div></td>
                </tr>
              </tbody>
            </table>
          </div>
        </el-card>
      </el-col>

      <el-col :span="24" class="card-box">
        <el-card>
          <div slot="header">
            <span>服务器信息</span>
          </div>
          <div class="el-table el-table--enable-row-hover el-table--medium">
            <table cellspacing="0" style="width: 100%;">
              <tbody>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">服务器名称</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.sys">{{ server.sys.computerName }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">操作系统</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.sys">{{ server.sys.osName }}</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">服务器IP</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.sys">{{ server.sys.computerIp }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">系统架构</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.sys">{{ server.sys.osArch }}</div></td>
                </tr>
              </tbody>
            </table>
          </div>
        </el-card>
      </el-col>

      <el-col :span="24" class="card-box">
        <el-card>
          <div slot="header">
            <span>Java虚拟机信息</span>
          </div>
          <div class="el-table el-table--enable-row-hover el-table--medium">
            <table cellspacing="0" style="width: 100%;">
              <tbody>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">Java名称</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.name }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">Java版本</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.version }}</div></td>
                </tr>
                <tr>
                  <td class="el-table__cell is-leaf"><div class="cell">启动时间</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.startTime }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">运行时长</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.runTime }}</div></td>
                </tr>
                <tr>
                  <td colspan="1" class="el-table__cell is-leaf"><div class="cell">安装路径</div></td>
                  <td colspan="3" class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.home }}</div></td>
                </tr>
                <tr>
                  <td colspan="1" class="el-table__cell is-leaf"><div class="cell">项目路径</div></td>
                  <td colspan="3" class="el-table__cell is-leaf"><div class="cell" v-if="server.sys">{{ server.sys.userDir }}</div></td>
                </tr>
                <tr>
                  <td colspan="1" class="el-table__cell is-leaf"><div class="cell">运行参数</div></td>
                  <td colspan="3" class="el-table__cell is-leaf"><div class="cell" v-if="server.jvm">{{ server.jvm.inputArgs }}</div></td>
                </tr>
              </tbody>
            </table>
          </div>
        </el-card>
      </el-col>

      <el-col :span="24" class="card-box">
        <el-card>
          <div slot="header">
            <span>磁盘状态</span>
          </div>
          <div class="el-table el-table--enable-row-hover el-table--medium">
            <table cellspacing="0" style="width: 100%;">
              <thead>
                <tr>
                  <th class="el-table__cell el-table__cell is-leaf"><div class="cell">盘符路径</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">文件系统</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">盘符类型</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">总大小</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">可用大小</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">已用大小</div></th>
                  <th class="el-table__cell is-leaf"><div class="cell">已用百分比</div></th>
                </tr>
              </thead>
              <tbody v-if="server.sysFiles">
                <tr v-for="(sysFile, index) in server.sysFiles" :key="index">
                  <td class="el-table__cell is-leaf"><div class="cell">{{ sysFile.dirName }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">{{ sysFile.sysTypeName }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">{{ sysFile.typeName }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">{{ sysFile.total }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">{{ sysFile.free }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell">{{ sysFile.used }}</div></td>
                  <td class="el-table__cell is-leaf"><div class="cell" :class="{'text-danger': sysFile.usage > 80}">{{ sysFile.usage }}%</div></td>
                </tr>
              </tbody>
            </table>
          </div>
        </el-card>
      </el-col>
    </el-row>
  </div>
</template>

<script>
import { getServer } from "@/api/monitor/server";
import echarts from 'echarts'

export default {
  name: "Server",
  data() {
    return {
      // 服务器信息
      server: [],
      jtStats: { cpu: 45, mem: 62, disk: 38, online: 28 },
      jtChart1Option: null,
      jtChart2Option: null,

    };
  },
    mounted() {
    this.$nextTick(() => { this.initJtCharts(); });
  },
  created() {
    this.getList();
      this.calcJtStats();
    this.openLoading();
  },
  methods: {

    /** 设计稿统计：服务器指标（真实数据来自 getServer） */
    calcJtStats() {
      const s = this.server || {};
      const cpu = s.cpu || {};
      const mem = s.mem || {};
      const sys = s.sys || {};
      if (cpu.cpuNum) {
        this.jtStats.cpu = Number(cpu.used || 45);
        this.jtStats.mem = Number(mem.used || 62);
        this.jtStats.disk = Number((sys.used || 38));
      }
      this.buildJtCharts();
    },
    buildJtCharts() {
      const hours = ['08','10','12','14','16','18','20'];
      const cpuData = [38, 45, 52, 48, 55, 45, 50];
      const memData = [55, 58, 60, 62, 64, 62, 61];
      this.jtChart1Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['CPU', '内存'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: hours, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', max: 100, axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [
          { name: 'CPU', type: 'line', smooth: true, data: cpuData, symbol: 'circle', symbolSize: 5, lineStyle: { color: '#0F3460', width: 3 }, itemStyle: { color: '#0F3460' } },
          { name: '内存', type: 'line', smooth: true, data: memData, symbol: 'circle', symbolSize: 5, lineStyle: { color: '#10b981', width: 3 }, itemStyle: { color: '#10b981' } }
        ]
      };
      this.jtChart2Option = {
        tooltip: { trigger: 'axis' },
        legend: { data: ['调用量'], top: 0, textStyle: { color: '#8a94a6' } },
        grid: { left: 10, right: 10, bottom: 10, top: 40, containLabel: true },
        xAxis: { type: 'category', data: hours, axisLine: { lineStyle: { color: '#d5deeb' } }, axisLabel: { color: '#64748b' } },
        yAxis: { type: 'value', axisLine: { show: false }, axisLabel: { color: '#8a94a6' }, splitLine: { lineStyle: { color: '#eef1f6' } } },
        series: [{
          name: '调用量', type: 'bar', barWidth: 16, data: [320, 480, 560, 420, 610, 380, 280],
          itemStyle: { color: '#1d4e89', borderRadius: [4, 4, 0, 0] }
        }]
      };
    },

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    /** 查询服务器信息 */
    getList() {
      getServer().then(response => {
        this.server = response.data
        this.calcJtStats();
        this.$nextTick(() => this.initJtCharts());;
        this.$modal.closeLoading();
      });
    },
    // 打开加载层
    openLoading() {
      this.$modal.loading("正在加载服务监控数据，请稍候！");
    }
  }
};
</script>
<style lang="scss" scoped>
.jt-service-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
}
.jt-service-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 14px;
  background: #f7faff;
  border: 1px solid #e8ecf3;
  border-radius: 8px;
  font-size: 14px;
  color: #1f2d3d;
}
.jt-service-item .up { color: #10b981; margin-left: auto; font-weight: 600; }
.jt-service-item .dot { width: 8px; height: 8px; border-radius: 50%; background: #10b981; display: inline-block; }
</style>
UI_MOD_SERVER_EOF
    ok "系统监控已按设计稿实现（设计稿 09：资源指标 + 趋势图 + 服务状态）"

    cat > "$ui/src/views/system/user/index.vue" <<'UI_MOD_USER_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">系统管理</div>
        <div class="jt-page-sub">用户、角色、菜单、部门、日志统一管理</div>
      </div>
    </div>
    <div class="jt-func-buttons">
      <span class="jt-func-btn is-active"><i class="el-icon-user"></i>用户管理</span>
      <span class="jt-func-btn" @click="go('/user/role')"><i class="el-icon-key"></i>角色权限</span>
      <span class="jt-func-btn" @click="go('/system/menu')"><i class="el-icon-menu"></i>菜单管理</span>
      <span class="jt-func-btn" @click="go('/user/dept')"><i class="el-icon-office-building"></i>部门管理</span>
      <span class="jt-func-btn" @click="go('/monitor/operlog')"><i class="el-icon-document"></i>操作日志</span>
    </div>

    <el-row :gutter="20">
      <!--部门数据-->
      <el-col :span="4" :xs="24">
        <div class="head-container">
          <el-input
            v-model="deptName"
            placeholder="请输入部门名称"
            clearable
            size="small"
            prefix-icon="el-icon-search"
            style="margin-bottom: 20px"
          />
        </div>
        <div class="head-container">
          <el-tree
            :data="deptOptions"
            :props="defaultProps"
            :expand-on-click-node="false"
            :filter-node-method="filterNode"
            ref="tree"
            default-expand-all
            @node-click="handleNodeClick"
          />
        </div>
      </el-col>
      <!--用户数据-->
      <el-col :span="20" :xs="24">
        <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="68px">
          <el-form-item label="用户名称" prop="userName">
            <el-input
              v-model="queryParams.userName"
              placeholder="请输入用户名称"
              clearable
              style="width: 240px"
              @keyup.enter.native="handleQuery"
            />
          </el-form-item>
          <el-form-item label="手机号码" prop="phonenumber">
            <el-input
              v-model="queryParams.phonenumber"
              placeholder="请输入手机号码"
              clearable
              style="width: 240px"
              @keyup.enter.native="handleQuery"
            />
          </el-form-item>
          <el-form-item label="状态" prop="status">
            <el-select
              v-model="queryParams.status"
              placeholder="用户状态"
              clearable
              style="width: 240px"
            >
              <el-option
                v-for="dict in dict.type.sys_normal_disable"
                :key="dict.value"
                :label="dict.label"
                :value="dict.value"
              />
            </el-select>
          </el-form-item>
          <el-form-item label="创建时间">
            <el-date-picker
              v-model="dateRange"
              style="width: 240px"
              value-format="yyyy-MM-dd"
              type="daterange"
              range-separator="-"
              start-placeholder="开始日期"
              end-placeholder="结束日期"
            ></el-date-picker>
          </el-form-item>
          <el-form-item>
            <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">搜索</el-button>
            <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
          </el-form-item>
        </el-form>

        <el-row :gutter="10" class="mb8">
          <el-col :span="1.5">
            <el-button
              type="primary"
              plain
              icon="el-icon-plus"
              size="mini"
              @click="handleAdd"
              v-hasPermi="['system:user:add']"
            >新增</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="success"
              plain
              icon="el-icon-edit"
              size="mini"
              :disabled="single"
              @click="handleUpdate"
              v-hasPermi="['system:user:edit']"
            >修改</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="danger"
              plain
              icon="el-icon-delete"
              size="mini"
              :disabled="multiple"
              @click="handleDelete"
              v-hasPermi="['system:user:remove']"
            >删除</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="info"
              plain
              icon="el-icon-upload2"
              size="mini"
              @click="handleImport"
              v-hasPermi="['system:user:import']"
            >导入</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="warning"
              plain
              icon="el-icon-download"
              size="mini"
              @click="handleExport"
              v-hasPermi="['system:user:export']"
            >导出</el-button>
          </el-col>
          <right-toolbar :showSearch.sync="showSearch" @queryTable="getList" :columns="columns"></right-toolbar>
        </el-row>

        <el-table v-loading="loading" :data="userList" @selection-change="handleSelectionChange">
          <el-table-column type="selection" width="50" align="center" />
          <el-table-column label="用户编号" align="center" key="userId" prop="userId" v-if="columns[0].visible" />
          <el-table-column label="用户名称" align="center" key="userName" prop="userName" v-if="columns[1].visible" :show-overflow-tooltip="true" />
          <el-table-column label="用户昵称" align="center" key="nickName" prop="nickName" v-if="columns[2].visible" :show-overflow-tooltip="true" />
          <el-table-column label="部门" align="center" key="deptName" prop="dept.deptName" v-if="columns[3].visible" :show-overflow-tooltip="true" />
          <el-table-column label="手机号码" align="center" key="phonenumber" prop="phonenumber" v-if="columns[4].visible" width="120" />
          <el-table-column label="状态" align="center" key="status" v-if="columns[5].visible">
            <template slot-scope="scope">
              <el-switch
                v-model="scope.row.status"
                active-value="0"
                inactive-value="1"
                @change="handleStatusChange(scope.row)"
              ></el-switch>
            </template>
          </el-table-column>
          <el-table-column label="创建时间" align="center" prop="createTime" v-if="columns[6].visible" width="160">
            <template slot-scope="scope">
              <span>{{ parseTime(scope.row.createTime) }}</span>
            </template>
          </el-table-column>
          <el-table-column
            label="操作"
            align="center"
            width="160"
            class-name="small-padding fixed-width"
          >
            <template slot-scope="scope" v-if="scope.row.userId !== 1">
              <el-button
                size="mini"
                type="text"
                icon="el-icon-edit"
                @click="handleUpdate(scope.row)"
                v-hasPermi="['system:user:edit']"
              >修改</el-button>
              <el-button
                size="mini"
                type="text"
                icon="el-icon-delete"
                @click="handleDelete(scope.row)"
                v-hasPermi="['system:user:remove']"
              >删除</el-button>
              <el-dropdown size="mini" @command="(command) => handleCommand(command, scope.row)" v-hasPermi="['system:user:resetPwd', 'system:user:edit']">
                <span class="el-dropdown-link">
                  <i class="el-icon-d-arrow-right el-icon--right"></i>更多
                </span>
                <el-dropdown-menu slot="dropdown">
                  <el-dropdown-item command="handleResetPwd" icon="el-icon-key"
                    v-hasPermi="['system:user:resetPwd']">重置密码</el-dropdown-item>
                  <el-dropdown-item command="handleAuthRole" icon="el-icon-circle-check"
                    v-hasPermi="['system:user:edit']">分配角色</el-dropdown-item>
                </el-dropdown-menu>
              </el-dropdown>
            </template>
          </el-table-column>
        </el-table>

        <pagination
          v-show="total>0"
          :total="total"
          :page.sync="queryParams.pageNum"
          :limit.sync="queryParams.pageSize"
          @pagination="getList"
        />
      </el-col>
    </el-row>

    <!-- 添加或修改用户配置对话框 -->
    <el-dialog :title="title" :visible.sync="open" width="600px" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="80px">
        <el-row>
          <el-col :span="12">
            <el-form-item label="用户昵称" prop="nickName">
              <el-input v-model="form.nickName" placeholder="请输入用户昵称" maxlength="30" />
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="归属部门" prop="deptId">
              <treeselect v-model="form.deptId" :options="deptOptions" :show-count="true" placeholder="请选择归属部门" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item label="手机号码" prop="phonenumber">
              <el-input v-model="form.phonenumber" placeholder="请输入手机号码" maxlength="11" />
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="邮箱" prop="email">
              <el-input v-model="form.email" placeholder="请输入邮箱" maxlength="50" />
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item v-if="form.userId == undefined" label="用户名称" prop="userName">
              <el-input v-model="form.userName" placeholder="请输入用户名称" maxlength="30" />
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item v-if="form.userId == undefined" label="用户密码" prop="password">
              <el-input v-model="form.password" placeholder="请输入用户密码" type="password" maxlength="20" show-password/>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item label="用户性别">
              <el-select v-model="form.sex" placeholder="请选择性别">
                <el-option
                  v-for="dict in dict.type.sys_user_sex"
                  :key="dict.value"
                  :label="dict.label"
                  :value="dict.value"
                ></el-option>
              </el-select>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="状态">
              <el-radio-group v-model="form.status">
                <el-radio
                  v-for="dict in dict.type.sys_normal_disable"
                  :key="dict.value"
                  :label="dict.value"
                >{{dict.label}}</el-radio>
              </el-radio-group>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="12">
            <el-form-item label="岗位">
              <el-select v-model="form.postIds" multiple placeholder="请选择岗位">
                <el-option
                  v-for="item in postOptions"
                  :key="item.postId"
                  :label="item.postName"
                  :value="item.postId"
                  :disabled="item.status == 1"
                ></el-option>
              </el-select>
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="角色">
              <el-select v-model="form.roleIds" multiple placeholder="请选择角色">
                <el-option
                  v-for="item in roleOptions"
                  :key="item.roleId"
                  :label="item.roleName"
                  :value="item.roleId"
                  :disabled="item.status == 1"
                ></el-option>
              </el-select>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" placeholder="请输入内容"></el-input>
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitForm">确 定</el-button>
        <el-button @click="cancel">取 消</el-button>
      </div>
    </el-dialog>

    <!-- 用户导入对话框 -->
    <el-dialog :title="upload.title" :visible.sync="upload.open" width="400px" append-to-body>
      <el-upload
        ref="upload"
        :limit="1"
        accept=".xlsx, .xls"
        :headers="upload.headers"
        :action="upload.url + '?updateSupport=' + upload.updateSupport"
        :disabled="upload.isUploading"
        :on-progress="handleFileUploadProgress"
        :on-success="handleFileSuccess"
        :auto-upload="false"
        drag
      >
        <i class="el-icon-upload"></i>
        <div class="el-upload__text">将文件拖到此处，或<em>点击上传</em></div>
        <div class="el-upload__tip text-center" slot="tip">
          <div class="el-upload__tip" slot="tip">
            <el-checkbox v-model="upload.updateSupport" /> 是否更新已经存在的用户数据
          </div>
          <span>仅允许导入xls、xlsx格式文件。</span>
          <el-link type="primary" :underline="false" style="font-size:12px;vertical-align: baseline;" @click="importTemplate">下载模板</el-link>
        </div>
      </el-upload>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitFileForm">确 定</el-button>
        <el-button @click="upload.open = false">取 消</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listUser, getUser, delUser, addUser, updateUser, resetUserPwd, changeUserStatus } from "@/api/system/user";
import echarts from 'echarts'
import { getToken } from "@/utils/auth";
import { treeselect } from "@/api/system/dept";
import Treeselect from "@riophae/vue-treeselect";
import "@riophae/vue-treeselect/dist/vue-treeselect.css";

export default {
  name: "User",
  dicts: ['sys_normal_disable', 'sys_user_sex'],
  components: { Treeselect },
  data() {
    return {
      // 遮罩层
      loading: true,
      // 选中数组
      ids: [],
      // 非单个禁用
      single: true,
      // 非多个禁用
      multiple: true,
      // 显示搜索条件
      showSearch: true,
      // 总条数
      total: 0,
      // 用户表格数据
      userList: null,
      // 弹出层标题
      title: "",
      // 部门树选项
      deptOptions: undefined,
      // 是否显示弹出层
      open: false,
      // 部门名称
      deptName: undefined,
      // 默认密码
      initPassword: undefined,
      // 日期范围
      dateRange: [],
      // 岗位选项
      postOptions: [],
      // 角色选项
      roleOptions: [],
      // 表单参数
      form: {},
      defaultProps: {
        children: "children",
        label: "label"
      },
      // 用户导入参数
      upload: {
        // 是否显示弹出层（用户导入）
        open: false,
        // 弹出层标题（用户导入）
        title: "",
        // 是否禁用上传
        isUploading: false,
        // 是否更新已经存在的用户数据
        updateSupport: 0,
        // 设置上传的请求头部
        headers: { Authorization: "Bearer " + getToken() },
        // 上传的地址
        url: process.env.VUE_APP_BASE_API + "/system/user/importData"
      },
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        userName: undefined,
        phonenumber: undefined,
        status: undefined,
        deptId: undefined
      },
      // 列信息
      columns: [
        { key: 0, label: `用户编号`, visible: true },
        { key: 1, label: `用户名称`, visible: true },
        { key: 2, label: `用户昵称`, visible: true },
        { key: 3, label: `部门`, visible: true },
        { key: 4, label: `手机号码`, visible: true },
        { key: 5, label: `状态`, visible: true },
        { key: 6, label: `创建时间`, visible: true }
      ],
      // 表单校验
      rules: {
        userName: [
          { required: true, message: "用户名称不能为空", trigger: "blur" },
          { min: 2, max: 20, message: '用户名称长度必须介于 2 和 20 之间', trigger: 'blur' }
        ],
        deptId: [
          { required: true, message: "所属部门不能为空", trigger: "blur" }
        ],
        nickName: [
          { required: true, message: "用户昵称不能为空", trigger: "blur" }
        ],
        password: [
          { required: true, message: "用户密码不能为空", trigger: "blur" },
          { min: 5, max: 20, message: '用户密码长度必须介于 5 和 20 之间', trigger: 'blur' }
        ],
        email: [
          {
            type: "email",
            message: "请输入正确的邮箱地址",
            trigger: ["blur", "change"]
          }
        ],
        phonenumber: [
          {
            pattern: /^1[3|4|5|6|7|8|9][0-9]\d{8}$/,
            message: "请输入正确的手机号码",
            trigger: "blur"
          }
        ],
        remark: [
          { max: 250, message: '长度必须小于250个字符', trigger: 'blur' }
        ]
      }
    };
  },
  watch: {
    // 根据名称筛选部门树
    deptName(val) {
      this.$refs.tree.filter(val);
    }
  },
  created() {
    this.getList();
    this.getTreeselect();
    this.getConfigKey("sys.user.initPassword").then(response => {
      this.initPassword = response.msg;
    });
  },
  methods: {

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    /** 查询用户列表 */
    getList() {
      this.loading = true;
      listUser(this.addDateRange(this.queryParams, this.dateRange)).then(response => {
          this.userList = response.rows;
          this.total = response.total;
          this.loading = false;
        }
      );
    },
    /** 查询部门下拉树结构 */
    getTreeselect() {
      treeselect().then(response => {
        debugger;
        this.deptOptions = response.data;
      });
    },
    // 筛选节点
    filterNode(value, data) {
      if (!value) return true;
      return data.label.indexOf(value) !== -1;
    },
    // 节点单击事件
    handleNodeClick(data) {
      this.queryParams.deptId = data.id;
      this.handleQuery();
    },
    // 用户状态修改
    handleStatusChange(row) {
      let text = row.status === "0" ? "启用" : "停用";
      this.$modal.confirm('确认要"' + text + '""' + row.userName + '"用户吗？').then(function() {
        return changeUserStatus(row.userId, row.status);
      }).then(() => {
        this.$modal.msgSuccess(text + "成功");
      }).catch(function() {
        row.status = row.status === "0" ? "1" : "0";
      });
    },
    // 取消按钮
    cancel() {
      this.open = false;
      this.reset();
    },
    // 表单重置
    reset() {
      this.form = {
        userId: undefined,
        deptId: undefined,
        userName: undefined,
        nickName: undefined,
        password: undefined,
        phonenumber: undefined,
        email: undefined,
        sex: undefined,
        status: "0",
        remark: undefined,
        postIds: [],
        roleIds: []
      };
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.dateRange = [];
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.userId);
      this.single = selection.length != 1;
      this.multiple = !selection.length;
    },
    // 更多操作触发
    handleCommand(command, row) {
      switch (command) {
        case "handleResetPwd":
          this.handleResetPwd(row);
          break;
        case "handleAuthRole":
          this.handleAuthRole(row);
          break;
        default:
          break;
      }
    },
    /** 新增按钮操作 */
    handleAdd() {
      this.reset();
      this.getTreeselect();
      getUser().then(response => {
        this.postOptions = response.posts;
        this.roleOptions = response.roles;
        this.open = true;
        this.title = "添加用户";
        this.form.password = this.initPassword;
      });
    },
    /** 修改按钮操作 */
    handleUpdate(row) {
      this.reset();
      this.getTreeselect();
      const userId = row.userId || this.ids;
      getUser(userId).then(response => {
        this.form = response.data;
        this.postOptions = response.posts;
        this.roleOptions = response.roles;
        this.form.postIds = response.postIds;
        this.form.roleIds = response.roleIds;
        this.open = true;
        this.title = "修改用户";
        this.form.password = "";
      });
    },
    /** 重置密码按钮操作 */
    handleResetPwd(row) {
      this.$prompt('请输入"' + row.userName + '"的新密码', "提示", {
        confirmButtonText: "确定",
        cancelButtonText: "取消",
        closeOnClickModal: false,
        inputPattern: /^.{5,20}$/,
        inputErrorMessage: "用户密码长度必须介于 5 和 20 之间"
      }).then(({ value }) => {
          resetUserPwd(row.userId, value).then(response => {
            this.$modal.msgSuccess("修改成功，新密码是：" + value);
          });
        }).catch(() => {});
    },
    /** 分配角色操作 */
    handleAuthRole: function(row) {
      const userId = row.userId;
      this.$router.push("/system/user-auth/role/" + userId);
    },
    /** 提交按钮 */
    submitForm: function() {
      this.$refs["form"].validate(valid => {
        if (valid) {
          if (this.form.userId != undefined) {
            updateUser(this.form).then(response => {
              this.$modal.msgSuccess("修改成功");
              this.open = false;
              this.getList();
            });
          } else {
            addUser(this.form).then(response => {
              this.$modal.msgSuccess("新增成功");
              this.open = false;
              this.getList();
            });
          }
        }
      });
    },
    /** 删除按钮操作 */
    handleDelete(row) {
      const userIds = row.userId || this.ids;
      this.$modal.confirm('是否确认删除用户编号为"' + userIds + '"的数据项？').then(function() {
        return delUser(userIds);
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("删除成功");
      }).catch(() => {});
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('system/user/export', {
        ...this.queryParams
      }, `user_${new Date().getTime()}.xlsx`)
    },
    /** 导入按钮操作 */
    handleImport() {
      this.upload.title = "用户导入";
      this.upload.open = true;
    },
    /** 下载模板操作 */
    importTemplate() {
      this.download('system/user/importTemplate', {
      }, `user_template_${new Date().getTime()}.xlsx`)
    },
    // 文件上传中处理
    handleFileUploadProgress(event, file, fileList) {
      this.upload.isUploading = true;
    },
    // 文件上传成功处理
    handleFileSuccess(response, file, fileList) {
      this.upload.open = false;
      this.upload.isUploading = false;
      this.$refs.upload.clearFiles();
      this.$alert("<div style='overflow: auto;overflow-x: hidden;max-height: 70vh;padding: 10px 20px 0;'>" + response.msg + "</div>", "导入结果", { dangerouslyUseHTMLString: true });
      this.getList();
    },
    // 提交上传文件
    submitFileForm() {
      this.$refs.upload.submit();
    }
  }
};
</script>

UI_MOD_USER_EOF
    ok "系统管理已按设计稿实现（设计稿 10：用户管理 Tab 导航 + 部门树 + 用户列表）"

    cat > "$ui/src/views/mes/md/mditem/index.vue" <<'UI_MOD_MDITEM_EOF'
<template>
  <div class="app-container">

    <div class="jt-page-header">
      <div>
        <div class="jt-page-title">主数据管理</div>
        <div class="jt-page-sub">物料、产品、工艺路线、工位、设备档案统一维护</div>
      </div>
    </div>
    <div class="jt-func-buttons">
      <span class="jt-func-btn is-active"><i class="el-icon-box"></i>物料管理</span>
      <span class="jt-func-btn" @click="go('/mes/md/itemtype')"><i class="el-icon-goods"></i>产品管理</span>
      <span class="jt-func-btn" @click="go('/mes/pro/proroute')"><i class="el-icon-s-operation"></i>工艺路线</span>
      <span class="jt-func-btn" @click="go('/mes/md/workstation')"><i class="el-icon-office-building"></i>工位管理</span>
      <span class="jt-func-btn" @click="go('/mes/dv/machinery')"><i class="el-icon-cpu"></i>设备档案</span>
    </div>

    <el-row :gutter="20">
      <!--分类数据-->
      <el-col :span="4" :xs="24">
        <div class="head-container">
          <el-input
            v-model="itemTypeName"
            placeholder="请输入分类名称"
            clearable
            size="small"
            prefix-icon="el-icon-search"
            style="margin-bottom: 20px"
          />
        </div>
        <div class="head-container">
          <el-tree
            :data="itemTypeOptions"
            :props="defaultProps"
            :expand-on-click-node="false"
            :filter-node-method="filterNode"
            ref="tree"
            default-expand-all
            @node-click="handleNodeClick"
          />
        </div>
      </el-col>
      <!--物料数据-->
      <el-col :span="20" :xs="24">
        <el-form :model="queryParams" ref="queryForm" size="small" :inline="true" v-show="showSearch" label-width="68px">
          <el-form-item label="物料编码" prop="itemCode">
            <el-input
              v-model="queryParams.itemCode"
              placeholder="请输入物料编码"
              clearable
              style="width: 240px"
              @keyup.enter.native="handleQuery"
            />
          </el-form-item>
          <el-form-item label="物料名称" prop="itemName">
            <el-input
              v-model="queryParams.itemName"
              placeholder="请输入物料名称"
              clearable
              style="width: 240px"
              @keyup.enter.native="handleQuery"
            />
          </el-form-item>
          <el-form-item>
            <el-button type="primary" icon="el-icon-search" size="mini" @click="handleQuery">搜索</el-button>
            <el-button icon="el-icon-refresh" size="mini" @click="resetQuery">重置</el-button>
          </el-form-item>
        </el-form>

        <el-row :gutter="10" class="mb8">
          <el-col :span="1.5">
            <el-button
              type="primary"
              plain
              icon="el-icon-plus"
              size="mini"
              @click="handleAdd"
              v-hasPermi="['mes:md:mditem:add']"
            >新增</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="success"
              plain
              icon="el-icon-edit"
              size="mini"
              :disabled="single"
              @click="handleUpdate"
              v-hasPermi="['mes:md:mditem:edit']"
            >修改</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="danger"
              plain
              icon="el-icon-delete"
              size="mini"
              :disabled="multiple"
              @click="handleDelete"
              v-hasPermi="['mes:md:mditem:remove']"
            >删除</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="info"
              plain
              icon="el-icon-upload2"
              size="mini"
              @click="handleImport"
              v-hasPermi="['mes:md:mditem:import']"
            >导入</el-button>
          </el-col>
          <el-col :span="1.5">
            <el-button
              type="warning"
              plain
              icon="el-icon-download"
              size="mini"
              @click="handleExport"
              v-hasPermi="['mes:md:mditem:export']"
            >导出</el-button>
          </el-col>
          <right-toolbar :showSearch.sync="showSearch" @queryTable="getList" :columns="columns"></right-toolbar>
        </el-row>

        <el-table v-loading="loading" :data="itemList" @selection-change="handleSelectionChange">
          <el-table-column type="selection" width="50" align="center" />
          <el-table-column label="物料编码" width = "120" align="center" key="itemCode" prop="itemCode" v-if="columns[0].visible" >
            <template slot-scope="scope">
              <el-button
                size="mini"
                type="text"
                @click="handleView(scope.row)"
                v-hasPermi="['mes:md:mditem:query']"
              >{{scope.row.itemCode}}</el-button>
            </template>
          </el-table-column>
          <el-table-column label="物料名称" min-width="120" align="left" key="itemName" prop="itemName" v-if="columns[1].visible" :show-overflow-tooltip="true" />
          <el-table-column label="规格型号" align="left" key="specification" prop="specification" v-if="columns[2].visible" :show-overflow-tooltip="true" />
          <el-table-column label="单位" align="center" key="unitName" prop="unitName" v-if="columns[3].visible" :show-overflow-tooltip="true" >
          </el-table-column>
          <el-table-column label="物料/产品" align="center" key="itemOrProduct" prop="itemOrProduct" v-if="columns[4].visible" :show-overflow-tooltip="true" >
            <template slot-scope="scope">
              <dict-tag :options="dict.type.mes_item_product" :value="scope.row.itemOrProduct"/>
            </template>
          </el-table-column>

          <el-table-column label="所属分类" align="center" key="itemTypeName" prop="itemTypeName" v-if="columns[5].visible" width="120" />
          <el-table-column label="是否启用" align="center" width="100">
            <template slot-scope="scope">
              <el-switch
                v-model="scope.row.enableFlag"
                active-text="是"
                inactive-text="否"
                active-value="Y"
                inactive-value="N"
                @change="handleEnableFlagChange(scope.row)"
              ></el-switch>
            </template>
          </el-table-column>
          <el-table-column label="设置安全库存" align="center" key="safeStockFlag" v-if="columns[7].visible">
            <template slot-scope="scope">
              <dict-tag :options="dict.type.sys_yes_no" :value="scope.row.safeStockFlag"/>
            </template>
          </el-table-column>
          <el-table-column label="创建时间" align="center" prop="createTime" v-if="columns[8].visible" width="160">
            <template slot-scope="scope">
              <span>{{ parseTime(scope.row.createTime) }}</span>
            </template>
          </el-table-column>
          <el-table-column
            label="操作"
            align="center"
            width="160"
            class-name="small-padding fixed-width"
          >
            <template slot-scope="scope">
              <el-button
                size="mini"
                type="text"
                icon="el-icon-edit"
                @click="handleUpdate(scope.row)"
                v-if="scope.row.enableFlag == 'N'"
                v-hasPermi="['mes:md:mditem:edit']"
              >修改</el-button>
              <el-button
                size="mini"
                type="text"
                icon="el-icon-delete"
                @click="handleDelete(scope.row)"
                v-if="scope.row.enableFlag == 'N'"
                v-hasPermi="['mes:md:mditem:remove']"
              >删除</el-button>
              <el-button
                size="mini"
                type="text"
                icon="el-icon-printer"
                @click="handleHiPrint(scope.row)"
                v-hasPermi="['mes:md:mditem:print']"
              >标签打印</el-button>
            </template>
          </el-table-column>
        </el-table>

        <pagination
          v-show="total>0"
          :total="total"
          :page.sync="queryParams.pageNum"
          :limit.sync="queryParams.pageSize"
          @pagination="getList"
        />
      </el-col>
    </el-row>

    <!-- 添加或修改物料产品编码对话框 -->
    <el-dialog :title="title" :visible.sync="open" width="960px" append-to-body>
      <el-form ref="form" :model="form" :rules="rules" label-width="120px">
        <el-row>
          <el-col :span="14">
            <el-row>
              <el-col :span="16">
                <el-form-item label="物料编码" prop="itemCode">
                  <el-input v-model="form.itemCode" readonly="readonly" maxlength="64" v-if="optType == 'view'"/>
                  <el-input v-model="form.itemCode" placeholder="请输入物料编码" maxlength="64" v-else/>
                </el-form-item>
              </el-col>
              <el-col :span="8">
                <el-form-item  label-width="80">
                  <el-switch v-model="autoGenFlag"
                             active-color="#13ce66"
                             active-text="自动生成"
                             @change="handleAutoGenChange(autoGenFlag)" v-if="optType != 'view'">
                  </el-switch>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="物料名称" prop="itemName">
                  <el-input v-model="form.itemName"  maxlength="255" readonly="readonly" v-if="optType=='view'" />
                  <el-input v-model="form.itemName" placeholder="请输入物料名称" maxlength="255" v-else/>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="规格型号" prop="specification">
                  <el-input v-model="form.specification" type="textarea" maxlength="500" readonly="readonly" v-if="optType=='view'" />
                  <el-input v-model="form.specification" type="textarea" placeholder="请输入规格型号" maxlength="500" v-else/>
                </el-form-item>
              </el-col>
            </el-row>
            <el-row>
              <el-col :span="24">
                <el-form-item label="单位" prop="unitOfMeasure">
                  <el-select v-model="form.unitOfMeasure" disabled v-if="optType=='view'">
                    <el-option
                      v-for="item in measureOptions"
                      :key="item.measureCode"
                      :label="item.measureName"
                      :value="item.measureCode"
                      :disabled="item.enableFlag == 'N'"
                    ></el-option>
                  </el-select>

                  <el-select v-model="form.unitOfMeasure" placeholder="请选择单位" v-else>
                    <el-option
                      v-for="item in measureOptions"
                      :key="item.measureCode"
                      :label="item.measureName"
                      :value="item.measureCode"
                      :disabled="item.enableFlag == 'N'"
                    ></el-option>
                  </el-select>
                </el-form-item>
              </el-col>
            </el-row>
          </el-col>
          <el-col :span="10">
            <BarcodeImg ref="barcodeImg" :bussinessId="form.itemId" :bussinessCode="form.itemCode" barcodeType="ITEM"></BarcodeImg>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="14">
            <el-form-item  label="物料/产品分类" prop="itemTypeId">
              <treeselect v-model="form.itemTypeId" :options="itemTypeOptions" :show-count="true" disabled v-if="optType=='view'"  />
              <treeselect v-model="form.itemTypeId" :options="itemTypeOptions" :show-count="true" placeholder="请选择所属分类" v-else :disable-branch-nodes="true"/>
            </el-form-item>
          </el-col>
          <el-col :span="10">
            <el-form-item  label="高价值/易被盗物品" label-width="150px" prop="highValue">
              <el-checkbox v-model="form.highValue" :true-label="'Y'" :false-label="'N'"></el-checkbox>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="8">
            <el-form-item label="是否启用">
              <el-radio-group v-model="form.enableFlag" disabled>
                <el-radio
                  v-for="dict in dict.type.sys_yes_no"
                  :key="dict.value"
                  :label="dict.value"
                >{{dict.label}}</el-radio>
              </el-radio-group>
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="批次管理">
              <el-switch
                v-model="form.batchFlag"
                active-text="是"
                inactive-text="否"
                active-value="Y"
                inactive-value="N"
              ></el-switch>
            </el-form-item>
          </el-col>
          <el-col :span="8">
            <el-form-item label="安全库存">
              <el-radio-group v-model="form.safeStockFlag" disabled v-if="optType=='view'">
                <el-radio
                  v-for="dict in dict.type.sys_yes_no"
                  :key="dict.value"
                  :label="dict.value"
                >{{dict.label}}</el-radio>
              </el-radio-group>

              <el-radio-group v-model="form.safeStockFlag" v-else>
                <el-radio
                  v-for="dict in dict.type.sys_yes_no"
                  :key="dict.value"
                  :label="dict.value"
                >{{dict.label}}</el-radio>
              </el-radio-group>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row v-if="form.safeStockFlag == 'Y'">
          <el-col :span="12">
            <el-form-item label="最小库存量">
              <el-input-number v-model="form.minStock" :percision="2" :step="1" disabled v-if="optType=='view'" />
              <el-input-number v-model="form.minStock" :percision="2" :step="1" placeholder="请输入最小安全库存量" v-else />
            </el-form-item>
          </el-col>
          <el-col :span="12">
            <el-form-item label="最大库存量">
              <el-input-number v-model="form.maxStock" :percision="2" :step="1" disabled v-if="optType=='view'" />
              <el-input-number v-model="form.maxStock" :percision="2" :step="1" placeholder="请输入最大安全库存量" v-else/>
            </el-form-item>
          </el-col>
        </el-row>
        <el-row>
          <el-col :span="24">
            <el-form-item label="备注" prop="remark">
              <el-input v-model="form.remark" type="textarea" readonly v-if="optType=='view'"></el-input>
              <el-input v-model="form.remark" type="textarea" maxlength="500" placeholder="请输入内容" v-else></el-input>
            </el-form-item>
          </el-col>
        </el-row>
      </el-form>
      <el-tabs type="border-card" v-if="form.itemId != null">
        <el-tab-pane label="BOM组成">
          <ItemBom :optType="optType" :itemId="form.itemId"></ItemBom>
        </el-tab-pane>
        <el-tab-pane v-if="form.batchFlag =='Y'" label="批次属性">
          <BatchConfig :itemId="form.itemId"  :itemProductFlag="form.itemOrProduct" :optType="optType"></BatchConfig>
        </el-tab-pane>
        <el-tab-pane label="替代品"></el-tab-pane>
        <el-tab-pane label="SIP">
          <SIPTab :itemId="form.itemId" :optType="optType"></SIPTab>
        </el-tab-pane>
        <el-tab-pane label="SOP">
          <SOPTab :itemId="form.itemId" :optType="optType"></SOPTab>
        </el-tab-pane>
      </el-tabs>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitForm" v-if="optType !='view'">确 定</el-button>
        <el-button @click="cancel">关 闭</el-button>
      </div>
    </el-dialog>

    <!-- 物料导入对话框 -->
    <el-dialog :title="upload.title" :visible.sync="upload.open" width="400px" append-to-body>
      <el-upload
        ref="upload"
        :limit="1"
        accept=".xlsx, .xls"
        :headers="upload.headers"
        :action="upload.url + '?updateSupport=' + upload.updateSupport"
        :disabled="upload.isUploading"
        :on-progress="handleFileUploadProgress"
        :on-success="handleFileSuccess"
        :auto-upload="false"
        drag
      >
        <i class="el-icon-upload"></i>
        <div class="el-upload__text">将文件拖到此处，或<em>点击上传</em></div>
        <div class="el-upload__tip text-center" slot="tip">
          <div class="el-upload__tip" slot="tip">
            <el-checkbox v-model="upload.updateSupport" /> 是否更新已经存在的用户数据
          </div>
          <span>仅允许导入xls、xlsx格式文件。</span>
          <el-link type="primary" :underline="false" style="font-size:12px;vertical-align: baseline;" @click="importTemplate">下载模板</el-link>
        </div>
      </el-upload>
      <div slot="footer" class="dialog-footer">
        <el-button type="primary" @click="submitFileForm">确 定</el-button>
        <el-button @click="upload.open = false">取 消</el-button>
      </div>
    </el-dialog>
  </div>
</template>

<script>
import { listMdItem, getMdItem, delMdItem, addMdItem, updateMdItem} from "@/api/mes/md/mdItem";
import echarts from 'echarts'
import { hiprintMixin } from "../../../../mixins/hiprintMixin";
import {print} from "../../../../utils/print"
import {getByTemplateType, getTemplate} from "@/api/print/template";
import ItemBom from "./components/itembom.vue";
import SOPTab from  "./components/sop.vue"
import SIPTab from  "./components/sip.vue"
import { listAllUnitmeasure} from "@/api/mes/md/unitmeasure";
import {genCode} from "@/api/system/autocode/rule"
import { getToken } from "@/utils/auth";
import { treeselect } from "@/api/mes/md/itemtype";
import Treeselect from "@riophae/vue-treeselect";
import { getBarcodeUrl } from '@/api/mes/wm/barcode';
import "@riophae/vue-treeselect/dist/vue-treeselect.css";
import BarcodeImg from "@/components/barcodeImg/index.vue"
import printLabel from "@/components/printerLabel/index.vue"
import BatchConfig from "./components/batch.vue";

export default {
  name: "MdItem",
  dicts: ['sys_yes_no','mes_item_product'],
  components: { Treeselect,ItemBom,SOPTab,SIPTab,BarcodeImg,printLabel, BatchConfig },
  mixins: [hiprintMixin],
  data() {
    return {
      // 遮罩层
      loading: true,
      // 选中数组
      ids: [],
      // 非单个禁用
      single: true,
      // 非多个禁用
      multiple: true,
      // 显示搜索条件
      showSearch: true,
      // 总条数
      total: 0,
      // 物料产品表格数据
      itemList: null,
      // 弹出层标题
      title: "",
      // 部门树选项
      itemTypeOptions: undefined,
      // 是否显示弹出层
      open: false,
      //弹框的操作类型 view add edit
      optType: undefined,
      // 部门名称
      itemTypeName: undefined,
      //自动生成物料编码标识
      autoGenFlag: false,
      // 日期范围
      dateRange: [],
      //单位列表
      measureOptions: [],
      // 表单参数
      form: {},
      defaultProps: {
        children: "children",
        label: "label"
      },
      // 用户导入参数
      upload: {
        // 是否显示弹出层（用户导入）
        open: false,
        // 弹出层标题（用户导入）
        title: "",
        // 是否禁用上传
        isUploading: false,
        // 是否更新已经存在的用户数据
        updateSupport: 0,
        // 设置上传的请求头部
        headers: { Authorization: "Bearer " + getToken() },
        // 上传的地址
        url: process.env.VUE_APP_BASE_API + "/mes/md/mditem/importData"
      },
      //二维码查询参数
      barcodeParams: {
        bussinessId: null,
        bussinessCode: null,
        barcodeFormart: 'QR_CODE', //模式二维码
        barcodeType: 'ITEM' //类型
      },
      // 查询参数
      queryParams: {
        pageNum: 1,
        pageSize: 10,
        itemCode: undefined,
        itemName: undefined,
        itemTypeId: 0
      },
      // 列信息
      columns: [
        { key: 0, label: `物料/产品编码`, visible: true },
        { key: 1, label: `物料/产品名称`, visible: true },
        { key: 2, label: `规格型号`, visible: true },
        { key: 3, label: `单位`, visible: true },
        { key: 4, label: `物料/产品`, visible: true },
        { key: 5, label: `物料分类`, visible: true },
        { key: 6, label: `是否启用`, visible: true },
        { key: 7, label: `是否设置安全库存`, visible: true },
        { key: 8, label: `创建时间`, visible: true }
      ],
      // 表单校验
      rules: {
        itemCode: [
          { required: true, message: "物料/产品编码不能为空", trigger: "blur" },
          { max: 64, message: '物料/产品编码长度必须小于64个字符', trigger: 'blur' }
        ],
        itemName: [
          { required: true, message: "物料/产品名称不能为空", trigger: "blur" }
        ],
        unitOfMeasure: [
          { required: true, message: "单位不能为空",trigger: "blur"}
        ],
        itemTypeId: [
          { required: true, message: "物料分类不能为空", trigger: "blur" },
        ],
        remark: [
          { max: 250, message: '长度必须小于250个字符', trigger: 'blur' }
        ]
      }
    };
  },
  watch: {
    // 根据名称筛选分类树
    itemTypeName(val) {
      this.$refs.tree.filter(val);
    }
  },
  created() {
    this.getList();
    this.getTreeselect();
    this.getUnits();
  },
  methods: {

    /** 跳转到对应功能模块 */
    go(path) {
      if (this.$route.path === path) { return; }
      this.$router.push(path);
    },

    /** 设计稿图表渲染 */
    initJtCharts() {
      const charts = [
        { ref: 'jtChart1', option: this.jtChart1Option },
        { ref: 'jtChart2', option: this.jtChart2Option }
      ];
      charts.forEach(item => {
        const el = this.$refs[item.ref];
        if (!el || !item.option) return;
        let chart = echarts.getInstanceByDom(el);
        if (chart) chart.dispose();
        chart = echarts.init(el);
        chart.setOption(item.option);
      });
    },

    // 使用HiPrint打印
    async handleHiPrint(row) {
      let printData = row
      let printTemplate
      // 处理数据 - 获取条形码图片地址
      let barcodeParams = {
        bussinessId: row.itemId,
        bussinessCode: row.itemCode,
        barcodeFormart: "QR_CODE",
        barcodeType: "ITEM"
      };
      await getBarcodeUrl(barcodeParams).then(res => {
        if (res.data) {
          printData.barcodeContent = res.data.barcodeContent
        } else {
          printData.barcodeContent = ''
        }
      })
      // 获取打印模板
      let templateStatus = true
      await getByTemplateType("ITEM").then(res => {
        printTemplate = res.data.templateJson
      }).catch(err => {
        templateStatus = false
      })
      if (templateStatus) {
        print(printTemplate, printData, this.hiprintTemplate, this.hiprintThis)
      }

    },
    /** 查询物料编码列表 */
    getList() {
      this.loading = true;
      listMdItem(this.queryParams).then(response => {
          this.itemList = response.rows;
          this.total = response.total;
          this.loading = false;
        }
      );
    },
    getUnits(){
      listAllUnitmeasure().then(response =>{
        this.measureOptions = response.data;
      });
    },
    /** 查询分类下拉树结构 */
    getTreeselect() {
      treeselect().then(response => {
        this.itemTypeOptions = response.data;
      });
    },
    // 筛选节点
    filterNode(value, data) {
      if (!value) return true;
      return data.label.indexOf(value) !== -1;
    },
    // 节点单击事件
    handleNodeClick(data) {
      this.queryParams.itemTypeId = data.id;
      this.handleQuery();
    },
    // 取消按钮
    cancel() {
      this.open = false;
      this.reset();
    },
    // 表单重置
    reset() {
      this.form = {
        itemId: undefined,
        itemTypeId: undefined,
        itemCode: undefined,
        itemName: undefined,
        specification: undefined,
        unitOfMeasrue: undefined,
        unitName: undefined,
        enableFlag: undefined,
        itemOrProduct: undefined,
        enableFlag: 'N',
        safeStockFlag: 'N',
        highValue: 'N',
        batchFlag: 'Y',
        barcodeUrl: null,
        minStock: 0,
        maxStock: 0,
        optType: undefined,
        remark: undefined
      };
      this.autoGenFlag = false;
      this.resetForm("form");
    },
    /** 搜索按钮操作 */
    handleQuery() {
      this.queryParams.pageNum = 1;
      this.getList();
    },
    /** 重置按钮操作 */
    resetQuery() {
      this.resetForm("queryForm");
      this.handleQuery();
    },
    // 多选框选中数据
    handleSelectionChange(selection) {
      this.ids = selection.map(item => item.itemId);
      this.single = selection.length != 1;
      this.multiple = !selection.length;
    },
    // 查询明细按钮操作
    handleView(row){
      this.reset();
      this.getTreeselect();
      const itemId = row.itemId || this.ids;
      getMdItem(itemId).then(response => {
        this.form = response.data;
        this.open = true;
        this.title = "查看物料/产品";
        this.optType = "view";
        this.$nextTick(()=>{
          this.$refs.barcodeImg.getBarcode();
        })
      });
    },
    /** 新增按钮操作 */
    handleAdd() {
      this.reset();
      this.getTreeselect();
      if(this.queryParams.itemTypeId != 0){
        this.form.itemTypeId = this.queryParams.itemTypeId;
      }
      this.optType = "add";
      this.open = true;
      this.title = "新增物料/产品";
    },
    /** 修改按钮操作 */
    handleUpdate(row) {
      this.reset();
      this.getTreeselect();
      const itemId = row.itemId || this.ids;
      getMdItem(itemId).then(response => {
        this.form = response.data;
        this.open = true;
        this.optType = "edit";
        this.title = "修改物料/产品";
        this.$nextTick(()=>{
          this.$refs.barcodeImg.getBarcode();
        })
      });
    },
    /**
     * 启用状态变更
     * @param row
     */
     handleEnableFlagChange(row){
      let text = row.enableFlag === "N" ? "禁用" : "启用";
      this.$modal.confirm('确认要"' + text + '""' + row.itemName + '"物料吗？').then(function() {
        return updateMdItem(row);
      }).then(() => {
        this.$modal.msgSuccess(text + "成功");
      }).catch(function() {
        row.enableFlag = row.enableFlag === "N" ? "Y" : "N";
      });
    },

    /** 提交按钮 */
    submitForm: function() {
      this.$refs["form"].validate(valid => {
        if (valid) {
          if (this.form.itemId != undefined) {
            updateMdItem(this.form).then(response => {
              this.$modal.msgSuccess("修改成功");
              this.form = response.data;
              this.getList();
            });
          } else {
            addMdItem(this.form).then(response => {
              this.$modal.msgSuccess("新增成功");
              this.form = response.data;
              this.getList();
            });
          }
        }
      });
    },
    /** 删除按钮操作 */
    handleDelete(row) {
      const itemIds = row.itemId || this.ids;
      this.$modal.confirm('确认删除数据项？').then(function() {
        return delMdItem(itemIds);
      }).then(() => {
        this.getList();
        this.$modal.msgSuccess("删除成功");
      }).catch(() => {});
    },
    /** 导出按钮操作 */
    handleExport() {
      this.download('mes/md/mditem/export', {
        ...this.queryParams
      }, `md_item_${new Date().getTime()}.xlsx`)
    },
    /** 导入按钮操作 */
    handleImport() {
      this.upload.title = "物料/产品导入";
      this.upload.open = true;
    },
    /** 下载模板操作 */
    importTemplate() {
      this.download('mes/md/mditem/importTemplate', {
      }, `md_item_template${new Date().getTime()}.xlsx`)
    },
    // 文件上传中处理
    handleFileUploadProgress(event, file, fileList) {
      this.upload.isUploading = true;
    },
    // 文件上传成功处理
    handleFileSuccess(response, file, fileList) {
      this.upload.open = false;
      this.upload.isUploading = false;
      this.$refs.upload.clearFiles();
      this.$alert("<div style='overflow: auto;overflow-x: hidden;max-height: 70vh;padding: 10px 20px 0;'>" + response.msg + "</div>", "导入结果", { dangerouslyUseHTMLString: true });
      this.getList();
    },
    // 提交上传文件
    submitFileForm() {
      this.$refs.upload.submit();
    },
    //获取二维码地址
    getBarcodeUrl(){
      this.barcodeParams.bussinessId = this.form.itemId;
      this.barcodeParams.bussinessCode = this.form.itemCode;
      getBarcodeUrl(this.barcodeParams).then( response =>{
        if(response.data != null){
          this.$set(this.form,'barcodeUrl',response.data.barcodeUrl);//强制刷新DOM
        }
      });
    },
    //自动生成物料编码
    handleAutoGenChange(autoGenFlag){
      debugger;
      if(autoGenFlag){
        genCode('ITEM_CODE').then(response =>{
          this.form.itemCode = response;
        });
      }else{
        this.form.itemCode = null;
      }
    }
  }
};
</script>
<style scoped>
.barcodeClass {
  width: 200px;
  height: 200px;
  border: 1px dashed;
  position: relative;
  display: inline-block;
}

.flex-container{
  display: flex;
  justify-content: center; /* 水平居中 */
  align-items: center; /* 垂直居中 */
}
</style>

UI_MOD_MDITEM_EOF
    ok "主数据管理已按设计稿实现（设计稿 02：物料/产品/工艺路线/工位/设备档案 Tab 导航）"
}

# ======================= 补充"检验结果"菜单（设计稿 05 = 检验单页） =======================
add_qcresult_menu() {
    if ! command -v docker >/dev/null 2>&1; then
        warn "docker 不可用，跳过检验结果菜单补充"
        return 0
    fi
    local exists
    exists=$(docker exec ktg-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-123456}" j2eedb -N -e \
        "select count(*) from sys_menu where component like '%qcresult%' or menu_name='检验结果';" 2>/dev/null)
    if [ "${exists:-0}" != "0" ]; then
        ok "检验结果菜单已存在，跳过"
        return 0
    fi
    docker exec ktg-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-123456}" j2eedb -e "
INSERT INTO sys_menu (menu_name, parent_id, order_num, path, component, is_frame, is_cache, menu_type, visible, status, perms, icon, create_by, create_time, remark)
VALUES ('检验结果', 2124, 7, 'qcresult', 'mes/qc/qcresult/index', 1, 0, 'C', 0, 0, 'mes:qc:qcresult:list', 'form', 'admin', NOW(), '骏通-MES 定制：设计稿05检验单页');
" >/dev/null 2>&1 && ok "已补充「检验结果」菜单（设计稿 05 检验单页）" || warn "检验结果菜单补充失败（可手动在系统管理-菜单管理添加）"
}


build_frontend() {
    step "编译前端"
    cd "$FRONTEND_DIR"
    [ -f package.json ] || { err "$FRONTEND_DIR 下没有 package.json"; return 1; }
    # 品牌 + 系统页面定制（最终版新增）：每次编译前自动应用，幂等
    if [ "${ENABLE_BRAND:-1}" = "1" ]; then
        apply_brand_custom "$FRONTEND_DIR"
    fi


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
    local had=0
    if [ -f "$BACKEND_PID_FILE" ] || [ -f "$FRONTEND_PID_FILE" ] \
        || [ "$(port_scope "$BACKEND_PORT")" != "none" ] \
        || [ "$(port_scope "$FRONTEND_PORT")" != "none" ]; then
        had=1
    fi
    stop_backend
    stop_frontend
    [ "$had" -eq 1 ] && info "已停止本地后端/前端进程"
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
        if http_alive "http://127.0.0.1:${BACKEND_PORT}/"; then
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
    step "启动本地服务（二选一：将停止容器模式）"
    ensure_docker_running
    stop_docker_services
    # 访问层：本机防火墙放行（云服务器安全组仍需在控制台手动放行）
    open_firewall_for_app
    start_backend
    if ! start_frontend; then
        warn "前端未在预期时间内就绪（后端与数据库不受影响）"
        warn "排查后重试：sudo $GLOBAL_CMD restart   查看日志：sudo $GLOBAL_CMD log-fe"
    fi
    set_mode local
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
    echo "  容器模式：sudo $GLOBAL_CMD install-docker（前后端容器化，二选一，启动会自动停本地模式）"
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

# ======================= 8.5 全容器（Docker）模式：与本地模式并存 =======================
# 前后端都跑在容器里；用独立端口(1124/18080)与独立容器名，与本地模式(1024/8080)并存。
# 镜像基于本地已编译产物构建（复用已验证的 mvn/npm 流程），运行期完全容器化。

current_mode() { [ -f "$MODE_FILE" ] && cat "$MODE_FILE" 2>/dev/null || true; }
set_mode() { mkdir -p "$WORK_DIR"; printf '%s\n' "$1" > "$MODE_FILE" 2>/dev/null || true; }

ensure_docker_net() {
    if ! docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
        docker network create "$DOCKER_NET" >/dev/null
        ok "已创建 Docker 网络：$DOCKER_NET"
    fi
}

attach_to_net() {
    local c="$1"
    container_exists "$c" || return 0
    if ! docker network inspect "$DOCKER_NET" \
            --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qw "$c"; then
        docker network connect "$DOCKER_NET" "$c" >/dev/null 2>&1 || true
    fi
}

write_docker_assets() {
    mkdir -p "$DOCKER_DIR"
    cat > "$DOCKER_DIR/Dockerfile.backend" <<EOF
FROM ${JAVA_RUNTIME_IMAGE}
WORKDIR /app
ENV TZ=Asia/Shanghai
COPY app.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["java","-Dfile.encoding=UTF-8","-Duser.timezone=Asia/Shanghai","-Xms512m","-Xmx2g","-jar","/app/app.jar"]
EOF

    # nginx 反向代理 /prod-api → 后端容器；下面 $ 开头的都是 nginx 变量，需转义
    cat > "$DOCKER_DIR/nginx.conf" <<EOF
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /prod-api/ {
        proxy_pass http://${BACKEND_CONTAINER}:8080/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
EOF

    cat > "$DOCKER_DIR/Dockerfile.frontend" <<EOF
FROM ${NGINX_IMAGE}
COPY dist/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
EOF
    ok "已生成 Dockerfile 与 nginx 配置：$DOCKER_DIR"
}

build_docker_images() {
    step "构建容器镜像（后端 + 前端）"
    ensure_docker_running
    mkdir -p "$LOG_DIR"
    local jar be fe
    if ! jar="$(backend_jar)"; then
        err "未找到后端 jar，请先 sudo $GLOBAL_CMD build"
        return 1
    fi
    [ -d "$FRONTEND_DIR/dist" ] || { err "未找到前端 dist，请先 sudo $GLOBAL_CMD build"; return 1; }

    # 基础镜像先按国内加速源拉取，build 时直接用本地缓存
    pull_image "$JAVA_RUNTIME_IMAGE"
    pull_image "$NGINX_IMAGE"

    be="$DOCKER_DIR/backend-ctx"; fe="$DOCKER_DIR/frontend-ctx"
    rm -rf "$be" "$fe"; mkdir -p "$be" "$fe/dist"
    cp -f "$jar" "$be/app.jar"
    cp -f "$DOCKER_DIR/Dockerfile.backend" "$be/Dockerfile"
    cp -rf "$FRONTEND_DIR/dist/." "$fe/dist/"
    cp -f "$DOCKER_DIR/nginx.conf" "$fe/nginx.conf"
    cp -f "$DOCKER_DIR/Dockerfile.frontend" "$fe/Dockerfile"

    info "构建后端镜像：$BACKEND_IMAGE"
    if ! docker build -t "$BACKEND_IMAGE" "$be" >> "$LOG_DIR/docker-build.log" 2>&1; then
        err "后端镜像构建失败，日志末尾："; tail -30 "$LOG_DIR/docker-build.log" >&2; return 1
    fi
    info "构建前端镜像：$FRONTEND_IMAGE"
    if ! docker build -t "$FRONTEND_IMAGE" "$fe" >> "$LOG_DIR/docker-build.log" 2>&1; then
        err "前端镜像构建失败，日志末尾："; tail -30 "$LOG_DIR/docker-build.log" >&2; return 1
    fi
    ok "镜像构建完成：$BACKEND_IMAGE / $FRONTEND_IMAGE"
}

start_docker_services() {
    step "启动容器化前后端（二选一：将停止本地模式）"
    ensure_docker_running
    stop_local_services
    ensure_docker_net
    attach_to_net "$MYSQL_CONTAINER"
    attach_to_net "$REDIS_CONTAINER"

    local miss=0
    docker image inspect "$BACKEND_IMAGE" >/dev/null 2>&1 || { err "后端镜像不存在：$BACKEND_IMAGE（先 sudo $GLOBAL_CMD install-docker）"; miss=1; }
    docker image inspect "$FRONTEND_IMAGE" >/dev/null 2>&1 || { err "前端镜像不存在：$FRONTEND_IMAGE"; miss=1; }
    [ "$miss" -eq 0 ] || return 1

    docker rm -f "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" >/dev/null 2>&1 || true
    wait_port_free "$DOCKER_BE_PORT" >/dev/null 2>&1 || true
    wait_port_free "$DOCKER_FE_PORT" >/dev/null 2>&1 || true

    local db_url="jdbc:mysql://${MYSQL_CONTAINER}:3306/${MYSQL_DB}?useUnicode=true&characterEncoding=utf8&zeroDateTimeBehavior=convertToNull&useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true"

    info "启动后端容器：$BACKEND_CONTAINER（宿主 $DOCKER_BE_PORT → 容器 8080）"
    docker run -d --name "$BACKEND_CONTAINER" --restart always --network "$DOCKER_NET" \
        -p "${DOCKER_BE_PORT}:8080" -e TZ=Asia/Shanghai \
        "$BACKEND_IMAGE" \
        --server.address=0.0.0.0 --server.port=8080 \
        --spring.datasource.druid.master.url="$db_url" \
        --spring.datasource.druid.master.username=root \
        --spring.datasource.druid.master.password="$MYSQL_ROOT_PWD" \
        --spring.redis.host="$REDIS_CONTAINER" --spring.redis.port=6379 \
        --spring.redis.password="$REDIS_PWD" >/dev/null

    info "启动前端容器：$FRONTEND_CONTAINER（宿主 $DOCKER_FE_PORT → 容器 80）"
    docker run -d --name "$FRONTEND_CONTAINER" --restart always --network "$DOCKER_NET" \
        -p "${DOCKER_FE_PORT}:80" "$FRONTEND_IMAGE" >/dev/null

    local i code=""
    info "等待容器前端就绪（最多 90 秒）..."
    for i in $(seq 1 90); do
        if http_alive "http://127.0.0.1:${DOCKER_FE_PORT}/"; then
            code="$(http_code "http://127.0.0.1:${DOCKER_FE_PORT}/")"
            break
        fi
        sleep 1
    done
    if [ -n "$code" ]; then
        ok "容器前端已就绪（HTTP $code）"
    else
        warn "容器前端未及时响应；日志：docker logs $FRONTEND_CONTAINER / docker logs $BACKEND_CONTAINER"
    fi
    set_mode docker
}

stop_docker_services() {
    local had=0
    if cmd_exists docker; then
        if container_exists "$BACKEND_CONTAINER" || container_exists "$FRONTEND_CONTAINER"; then had=1; fi
        docker rm -f "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" >/dev/null 2>&1 || true
    fi
    [ "$had" -eq 1 ] && info "已停止容器化前端/后端（MySQL/Redis 容器保留）"
    return 0
}

docker_up() {
    require_root "$@"
    step "容器模式快捷开启"
    ensure_docker_running
    start_db_containers
    start_docker_services || return 1
    echo ""
    docker_summary
}

docker_summary() {
    local ip; ip="$(detect_lan_ip)"
    echo ""
    ok "===== 容器模式就绪（当前模式：docker）====="
    if is_wsl; then
        echo "  前端（Windows 浏览器）：http://localhost:${DOCKER_FE_PORT}"
        echo "  前端（局域网其它设备）：http://${ip}:${DOCKER_FE_PORT}"
    else
        echo "  前端访问：http://${ip}:${DOCKER_FE_PORT}（本机 http://127.0.0.1:${DOCKER_FE_PORT}）"
    fi
    echo "  后端接口：http://${ip}:${DOCKER_BE_PORT}"
    echo "  容器    ：$BACKEND_CONTAINER / $FRONTEND_CONTAINER（本地模式已停止）"
    echo "  登录账号：admin / admin123"
    echo "  切回本地模式：sudo $GLOBAL_CMD up（会自动停容器模式）    停止：sudo $GLOBAL_CMD docker-down"
}

install_docker_full() {
    env_init "$@"
    docker_env_init
    pull_source
    start_db_containers
    ensure_docker_net
    attach_to_net "$MYSQL_CONTAINER"
    attach_to_net "$REDIS_CONTAINER"
    patch_config
    init_database
    build_local
    write_docker_assets
    build_docker_images
    start_docker_services
    docker_summary
    verify_all
}

# 还原安装时被改写的 Docker 加速配置（setup_docker_mirror 会先备份）
restore_docker_daemon() {
    local bak
    bak="$(ls -1t /etc/docker/daemon.json.bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$bak" ] && [ -f "$bak" ]; then
        cp -f "$bak" /etc/docker/daemon.json
        has_systemd && systemctl restart docker >/dev/null 2>&1 || true
        ok "已还原 Docker 配置：/etc/docker/daemon.json（来自 $bak）"
    elif [ -f /etc/docker/daemon.json ]; then
        # 没有备份说明原本就没有该文件，删掉脚本生成的
        rm -f /etc/docker/daemon.json
        has_systemd && systemctl restart docker >/dev/null 2>&1 || true
        ok "已移除脚本生成的 Docker 加速配置"
    fi
}

# ======================= 9.35 代理 / no_proxy 诊断 =======================
show_proxy() {
    step "代理环境与访问诊断"
    echo "  http_proxy  = ${http_proxy:-${HTTP_PROXY:-（未设置）}}"
    echo "  https_proxy = ${https_proxy:-${HTTPS_PROXY:-（未设置）}}"
    echo "  no_proxy    = ${no_proxy:-${NO_PROXY:-（未设置）}}"
    echo ""
    echo "  本机各端口直连探测（脚本已强制 --noproxy '*'）："
    local url code
    for url in "http://127.0.0.1:${FRONTEND_PORT}/" "http://127.0.0.1:${BACKEND_PORT}/" \
               "http://127.0.0.1:${DOCKER_FE_PORT}/" "http://127.0.0.1:${DOCKER_BE_PORT}/"; do
        code="$(http_code "$url")"
        printf '    %-32s -> %s\n' "$url" "${code:-无响应}"
    done
    echo ""
    ok "本脚本不占用 ${KTG_PROXY_PORT_HINT:-10808}；本机模式用 ${FRONTEND_PORT}/${BACKEND_PORT}，容器模式用 ${DOCKER_FE_PORT}/${DOCKER_BE_PORT}"
    echo "  代理端口只会影响“本机 HTTP 探测”，脚本已对全部本机探测强制直连，功能不受影响。"
    echo "  若要从 WSL 全局避开代理对本机的干扰，二选一："
    echo "    1) Windows 的 %UserProfile%\\.wslconfig 里设 autoProxy=false 后 wsl --shutdown"
    echo "    2) 保证 no_proxy 用具体地址（curl 不识别 '127.*' 通配）：no_proxy=localhost,127.0.0.1,::1,${ip:-<服务器IP>}"
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
    local fail=0 ip code scope fe_pid ntbl t c miss="" serving=0 mode="" docker_on=0 local_on=0
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

    # ---------- 3) 当前激活模式（二选一） ----------
    mode="$(current_mode)"
    container_running "$FRONTEND_CONTAINER" && docker_on=1
    container_running "$BACKEND_CONTAINER" && docker_on=1
    if [ -f "$FRONTEND_PID_FILE" ] && kill -0 "$(cat "$FRONTEND_PID_FILE" 2>/dev/null || true)" 2>/dev/null; then local_on=1; fi
    if [ -f "$BACKEND_PID_FILE" ] && kill -0 "$(cat "$BACKEND_PID_FILE" 2>/dev/null || true)" 2>/dev/null; then local_on=1; fi

    if [ "$docker_on" -eq 1 ] && [ "$local_on" -eq 1 ]; then
        warn "本地与容器两套都在运行（设计为二选一）→ sudo $GLOBAL_CMD stop-all 后只启动一种"; fail=1
    elif [ "$docker_on" -eq 1 ]; then
        ok "当前模式：容器模式（端口 ${DOCKER_FE_PORT}/${DOCKER_BE_PORT}）"
        container_running "$BACKEND_CONTAINER" && ok "容器后端运行中" || { warn "容器后端未运行"; fail=1; }
        container_running "$FRONTEND_CONTAINER" && ok "容器前端运行中" || { warn "容器前端未运行"; fail=1; }
    elif [ "$local_on" -eq 1 ]; then
        ok "当前模式：本地模式（端口 ${FRONTEND_PORT}/${BACKEND_PORT}）"
    else
        info "当前没有运行中的模式（记录的模式：${mode:-无}）"
    fi

    # ---------- 4) 端口与 HTTP（两模式共用端口） ----------
    if [ "$(port_scope "$BACKEND_PORT")" != "none" ]; then
        if http_alive "http://127.0.0.1:${BACKEND_PORT}/"; then
            ok "后端响应正常（端口 $BACKEND_PORT）"
        else
            warn "后端端口在听但 HTTP 异常 → sudo $GLOBAL_CMD log"; fail=1
        fi
    else
        warn "后端未监听（$BACKEND_PORT）"
    fi
    scope="$(port_scope "$FRONTEND_PORT")"
    case "$scope" in
        all)   ok "前端已监听所有网卡（端口 $FRONTEND_PORT）" ;;
        local) warn "前端仅监听 127.0.0.1，外部访问不了"; fail=1 ;;
        none)  warn "前端未监听（$FRONTEND_PORT）" ;;
        *)     : ;;
    esac
    if http_alive "http://127.0.0.1:${FRONTEND_PORT}/"; then
        ok "前端 HTTP 响应正常"; serving=1
    fi

    # ---------- 5) 至少有一个可访问的前端 ----------
    if [ "$serving" -eq 0 ]; then
        warn "没有可访问的前端 → 本地模式：sudo $GLOBAL_CMD up；容器模式：sudo $GLOBAL_CMD docker-up"
        fail=1
    fi

    # ---------- 6) 访问层 ----------
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

    # ---------- 7) 结论 ----------
    echo ""
    if [ "$fail" -eq 0 ]; then
        ok "体检通过（${mode:-当前模式}）：访问 http://${ip}:${FRONTEND_PORT}（Windows 本机 http://localhost:${FRONTEND_PORT}）"
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
        code="$(http_code "http://127.0.0.1:${FRONTEND_PORT}/")"
        if http_alive "http://127.0.0.1:${FRONTEND_PORT}/"; then
            ok "前端 HTTP 探测通过（HTTP $code）"
        else
            warn "前端端口在听但 HTTP 异常（HTTP ${code:-无响应}）"
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

# 卸载并尽量还原系统到部署前状态。
#   uninstall            删除本项目容器(含数据卷)/镜像/网络/部署目录/全局命令，并还原 Docker 配置
#   uninstall --purge    额外删除基础镜像(mysql/redis/jre/nginx) 与脚本安装的 JDK8
#   uninstall --dry-run  只列出将删除的内容，不执行
uninstall_all() {
    local opt="${1:-}" dry=0 purge=0
    case "$opt" in
        --dry-run) dry=1 ;;
        --purge)   purge=1 ;;
    esac

    step "卸载 KTG-MES（本地 + 容器模式）"
    local items=(
        "本地后端/前端进程（端口 ${BACKEND_PORT}/${FRONTEND_PORT}）"
        "容器：${BACKEND_CONTAINER} ${FRONTEND_CONTAINER} ${MYSQL_CONTAINER} ${REDIS_CONTAINER}（含数据卷）"
        "镜像：${BACKEND_IMAGE} ${FRONTEND_IMAGE}"
        "Docker 网络：${DOCKER_NET}"
        "部署目录：${WORK_DIR}"
        "全局命令：/usr/local/bin/${GLOBAL_CMD}、ktgup/ktgoff/ktgst/ktgck 及 /etc/profile.d/ktg-shortcuts.sh"
        "还原 Docker 加速配置：/etc/docker/daemon.json（来自安装时备份）"
    )
    if [ "$purge" -eq 1 ]; then
        items+=("基础镜像：${MYSQL_IMAGE} ${REDIS_IMAGE} ${JAVA_RUNTIME_IMAGE} ${NGINX_IMAGE}")
        items+=("脚本安装的 JDK8：/opt/java + /etc/profile.d/ktg-java.sh")
    fi

    echo ""
    info "将删除 / 还原以下内容："
    local it; for it in "${items[@]}"; do echo "  - $it"; done
    echo ""
    if [ "$dry" -eq 1 ]; then
        warn "--dry-run：以上仅为预览，未执行任何删除"; return 0
    fi

    warn "此操作会删除数据库数据，且不可恢复！"
    read -rp "确认执行请输入 yes: " c || c=""
    [ "$c" = "yes" ] || { info "已取消（需输入 yes）"; return 0; }

    # 1) 本地进程
    stop_local_services 2>/dev/null || true
    # 2) 容器（-v 一并删匿名数据卷）
    if cmd_exists docker; then
        docker rm -fv "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" \
            "$MYSQL_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1 || true
        # 3) 项目镜像
        docker rmi -f "$BACKEND_IMAGE" "$FRONTEND_IMAGE" >/dev/null 2>&1 || true
        # 4) 网络
        docker network rm "$DOCKER_NET" >/dev/null 2>&1 || true
    fi
    # 5) 部署目录
    rm -rf "$WORK_DIR"
    # 6) 全局命令与快捷命令
    rm -f "/usr/local/bin/$GLOBAL_CMD" /usr/local/bin/ktgup /usr/local/bin/ktgoff \
          /usr/local/bin/ktgst /usr/local/bin/ktgck
    rm -f /etc/profile.d/ktg-shortcuts.sh 2>/dev/null || true
    # 7) 还原 Docker 加速配置
    restore_docker_daemon
    # 8) --purge：基础镜像 + 脚本装的 JDK8
    if [ "$purge" -eq 1 ]; then
        if cmd_exists docker; then
            docker rmi -f "$MYSQL_IMAGE" "$REDIS_IMAGE" "$JAVA_RUNTIME_IMAGE" "$NGINX_IMAGE" \
                >/dev/null 2>&1 || true
        fi
        if [ -f /etc/profile.d/ktg-java.sh ]; then
            rm -f /etc/profile.d/ktg-java.sh
            rm -rf /opt/java/openjdk8
            ok "已移除脚本安装的 JDK8（/opt/java/openjdk8）"
        fi
    fi

    ok "卸载完成"
    echo ""
    echo "  如需彻底还原系统软件包（仅当这些包是部署时新装的，部署前已存在则勿删）："
    echo "    apt-get remove --purge -y docker.io openjdk-8-jdk maven 2>/dev/null || true"
    echo "  说明：本脚本不自动卸载系统软件包，避免误删你原本已安装的软件。"
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
  [o] 诊断代理环境（http_proxy / no_proxy）
  [d] 全容器（Docker）模式安装
  [g] 容器模式快捷开启
  [h] 停止容器模式
  [x] 完全卸载并还原
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
            d|D) install_docker_full ;;
            g|G) docker_up ;;
            h|H) require_root "$@"; stop_docker_services ;;
            i|I) show_images ;;
            o|O) show_proxy ;;
            x|X) uninstall_all ;;
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
  install-docker 全容器模式（前后端跑在 docker，二选一，启动自动停本地模式）
  up / on        快捷开启（拉起数据库与服务并打印访问地址，不重装不编译）
  docker-up      容器模式快捷开启
  docker-down    停止容器化前端/后端（保留数据库容器）
  stop-all       停止本地模式与容器模式两套服务
  shortcuts      安装/刷新全局命令 ktg 与快捷命令（ktgup/ktgoff/ktgst/ktgck）
  repair         一键修复（建库 + 补列 + 启动 + 体检）
  verify         环境体检（容器/数据库/字段/前后端 HTTP/监听网卡/防火墙）
  images         查看 Docker 镜像与版本（脚本配置 / 本地拉取 / 容器实际 / 摘要）
  proxy          诊断代理环境（http_proxy/no_proxy）与本机端口直连情况
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
  uninstall      完全卸载并还原（默认删本项目容器/镜像/数据卷/目录/命令并还原 Docker 配置）
                 uninstall --purge 额外清基础镜像与脚本装的 JDK8；--dry-run 仅预览
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
    # 统一绕开本机代理干扰（http_proxy 指向 127.0.0.1:10808 之类时，避免本机访问被劫持）
    setup_no_proxy
    case "$cmd" in
        install)   install_local_full "$@" ;;
        install-docker|dinstall) install_docker_full "$@" ;;
        mirrors)   setup_mirrors "$@" ;;
        start)     env_init; start_db_containers; start_local_services ;;
        stop)      stop_local_services ;;
        restart)   stop_local_services; sleep 2; start_local_services ;;
        status)    show_status ;;
        images|image) show_images ;;
        proxy)     show_proxy ;;
        verify|doctor|check) verify_all ;;
        repair)    repair_all ;;
        up|on|open|go|quick) quick_up ;;
        docker-up|dup) require_root "$@"; docker_up ;;
        docker-down|ddown) require_root "$@"; stop_docker_services ;;
        stop-all)  stop_local_services; stop_docker_services ;;
        shortcuts|alias) require_root "$@"; register_global_cmd; install_shortcuts ;;
        build)     env_init; patch_config; build_local ;;
        build-fe)  require_root "$@"; build_frontend ;;
        apply-brand) require_root "$@"; apply_brand_custom "$FRONTEND_DIR" ;;
        start-fe)  require_root "$@"; start_frontend ;;
        sql)       env_init; start_db_containers; init_database ;;
        patch-db)  require_root "$@"; ensure_docker_running; apply_schema_patches ;;
        db)        env_init; docker_env_init; start_db_containers ;;
        log)       tail -n 200 -f "$BACKEND_LOG" ;;
        log-fe)    tail -n 200 -f "$FRONTEND_LOG" ;;
        firewall)  require_root "$@"; open_firewall_for_app ;;
        clean)     clean_db ;;
        uninstall) uninstall_all "${2:-}" ;;
        menu|"")   show_menu ;;
        -h|--help|help) usage ;;
        *)         err "未知命令：$cmd"; usage; exit 1 ;;
    esac
}

main "$@"
