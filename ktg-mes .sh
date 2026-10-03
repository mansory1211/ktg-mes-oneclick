#!/bin/bash
#====================================================================================
#  KTG-MES 苦糖果 MES 一键部署 & 管理工具
#  ------------------------------------------------------------------
#  项目: 苦糖果 MES (基于 RuoYi-Vue 二次开发的开源生产执行管理系统)
#  源码: https://gitee.com/kutangguo/ktg-mes
#  用法:
#        首次安装:  sudo bash ktg-mes.sh
#        安装后:    任意目录执行  ktg-mes   即可调出管理菜单
#  环境:     Ubuntu 20.04+ / Debian 11+ / WSL2
#  默认账号: admin / admin123
#====================================================================================
set -euo pipefail

# ======================= 可配置项（上传到你的 GitHub 后可按需改） =======================
WORK_DIR="$HOME/ktg-mes-deploy"
BACKEND_DIR="$WORK_DIR/ktg-mes"
FRONTEND_DIR="$WORK_DIR/ktg-mes-ui"

MYSQL_CONTAINER="ktg-mysql"
MYSQL_IMAGE="mysql:5.7"
MYSQL_PORT="3306"
MYSQL_ROOT_PWD="123456"
MYSQL_DB="j2eedb"

REDIS_CONTAINER="ktg-redis"
REDIS_IMAGE="redis:7"
REDIS_PORT="6379"
REDIS_PWD="123456"

GITEE_OWNER="kutangguo"
NPM_REGISTRY="https://registry.npmmirror.com"

# 后端监听端口（浏览器访问 http://服务器IP:8080）
BACKEND_PORT="8080"

# 全局命令名（装完后敲这个命令进菜单）
GLOBAL_CMD="ktg-mes"
# =====================================================================================

# 颜色
if [ -t 1 ]; then
    R='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
else
    R=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''
fi
info()  { echo -e "${GREEN}[INFO]${R}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${R}  $*"; }
err()   { echo -e "${RED}[ERROR]${R} $*" >&2; }
step()  { echo -e "\n${CYAN}========== $* ==========${R}"; }
ok()    { echo -e "${GREEN}✔ $*${R}"; }

SUDO=""
[ "$EUID" -ne 0 ] && SUDO="sudo"

#====================================================================================
#  1. 环境初始化
#====================================================================================
env_init() {
    step "1/9 系统更新 & 安装基础工具 (JDK8 / Maven / Git)"
    $SUDO apt update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt install -y \
        curl wget git unzip ca-certificates gnupg lsb-release \
        openjdk-8-jdk-headless maven
    java -version 2>&1 | head -1
    mvn -v | head -1

    step "2/9 安装 Docker"
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        $SUDO systemctl enable docker 2>/dev/null || true
        $SUDO systemctl start docker 2>/dev/null || true
    fi
    docker info >/dev/null 2>&1 || { err "Docker 守护进程未运行，请先启动 Docker"; exit 1; }
    ok "Docker: $(docker --version)"

    step "3/9 安装 Node.js 16"
    if ! command -v node &>/dev/null || ! node -v 2>/dev/null | grep -q '^v16'; then
        curl -fsSL https://deb.nodesource.com/setup_16.x | $SUDO -E bash -
        $SUDO DEBIAN_FRONTEND=noninteractive apt install -y nodejs
    fi
    ok "Node $(node -v) / npm $(npm -v)"
}

#====================================================================================
#  2. 数据库容器
#====================================================================================
start_db() {
    step "4/9 启动 MySQL 5.7 + Redis 容器"
    if [ -z "$(docker ps -q -f name=^${MYSQL_CONTAINER}$)" ]; then
        docker rm -f "$MYSQL_CONTAINER" 2>/dev/null || true
        docker run -d --name "$MYSQL_CONTAINER" \
            -p ${MYSQL_PORT}:3306 \
            -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" \
            -e MYSQL_DATABASE="$MYSQL_DB" \
            --restart=always \
            $MYSQL_IMAGE \
            --character-set-server=utf8mb4 \
            --collation-server=utf8mb4_unicode_ci \
            --default-time-zone='+8:00'
        info "等待 MySQL 初始化..."
    fi
    for i in $(seq 1 60); do
        docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PWD" --silent &>/dev/null && break
        sleep 3
    done

    if [ -z "$(docker ps -q -f name=^${REDIS_CONTAINER}$)" ]; then
        docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
        docker run -d --name "$REDIS_CONTAINER" \
            -p ${REDIS_PORT}:6379 --restart=always \
            $REDIS_IMAGE redis-server --requirepass "$REDIS_PWD"
        sleep 3
    fi
    docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" ping 2>/dev/null | grep -q PONG
    ok "MySQL + Redis 就绪"
}

#====================================================================================
#  3. 拉源码（wget zip 优先，避开 git TLS 问题）
#====================================================================================
pull_source() {
    step "5/9 下载 ktg-mes 源码"
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

    if [ ! -d "$BACKEND_DIR" ]; then
        info "下载后端源码 (zip)..."
        wget -q --show-progress "https://gitee.com/${GITEE_OWNER}/ktg-mes/repository/archive/master.zip" -O /tmp/ktg-mes.zip
        unzip -q /tmp/ktg-mes.zip -d /tmp/
        mv /tmp/ktg-mes-master "$BACKEND_DIR"
    fi
    if [ ! -d "$FRONTEND_DIR" ]; then
        info "下载前端源码 (zip)..."
        wget -q --show-progress "https://gitee.com/${GITEE_OWNER}/ktg-mes-ui/repository/archive/master.zip" -O /tmp/ktg-mes-ui.zip
        unzip -q /tmp/ktg-mes-ui.zip -d /tmp/
        mv /tmp/ktg-mes-ui-master "$FRONTEND_DIR"
    fi
    ok "源码就绪"
}

#====================================================================================
#  4. 导数据库
#====================================================================================
import_db() {
    step "6/9 导入数据库脚本"
    local SQL_FILE
    SQL_FILE=$(find "$BACKEND_DIR/doc" "$BACKEND_DIR/sql" -type f \( -name "*.sql.gz" -o -name "*.sql" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -z "$SQL_FILE" ]; then
        warn "未找到 .sql/.sql.gz，请手动导入:"
        echo "  docker exec -i $MYSQL_CONTAINER mysql -uroot -p$MYSQL_ROOT_PWD $MYSQL_DB < <(gunzip -c 你的文件.sql.gz)"
        return 0
    fi
    info "使用: $SQL_FILE"
    if [[ "$SQL_FILE" == *.gz ]]; then
        gunzip -c "$SQL_FILE" | docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB"
    else
        docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB" < "$SQL_FILE"
    fi
    ok "数据库导入完成"
}

#====================================================================================
#  5. 改配置
#====================================================================================
patch_config() {
    step "7/9 修改数据库 / Redis / 端口配置"
    local DRUID_CONF="$BACKEND_DIR/ktg-admin/src/main/resources/application-druid.yml"
    local APP_CONF="$BACKEND_DIR/ktg-admin/src/main/resources/application.yml"
    local VUE_CONF="$FRONTEND_DIR/vue.config.js"

    [ -f "$DRUID_CONF" ] && {
        cp "$DRUID_CONF" "${DRUID_CONF}.bak"
        # 替换若依模板占位符: your_username / your_password
        sed -i "s|your_username|root|g; s|your_password|$MYSQL_ROOT_PWD|g" "$DRUID_CONF"
        # 兜底: 确保 username 是 root
        sed -i "s|username: *[a-zA-Z0-9_]*|username: root|g" "$DRUID_CONF"
        # 兜底: 把其他 password 占位形式统一替换
        sed -i "s|password: *password|password: $MYSQL_ROOT_PWD|g; s|password: *$|password: $MYSQL_ROOT_PWD|g" "$DRUID_CONF"
        ok "application-druid.yml 数据库账号/密码已更新"
    }
    [ -f "$APP_CONF" ] && {
        cp "$APP_CONF" "${APP_CONF}.bak"
        sed -i "s|^\(\s*password:\)\s*$|\1 $REDIS_PWD|" "$APP_CONF"
        # 端口改为 BACKEND_PORT
        sed -i "s|^\(\s*port:\s*\)[0-9]\+|\1$BACKEND_PORT|" "$APP_CONF"
        ok "application.yml Redis密码 + 端口改为 $BACKEND_PORT"
    }
    [ -f "$VUE_CONF" ] && {
        cp "$VUE_CONF" "${VUE_CONF}.bak"
        # 前端代理目标 -> 后端端口
        sed -i "s|localhost:[0-9]\+|localhost:$BACKEND_PORT|g" "$VUE_CONF"
        ok "vue.config.js 前端代理已指向 localhost:$BACKEND_PORT"
    }
}

#====================================================================================
#  6. 编译启动后端
#====================================================================================
build_backend() {
    step "8/9 Maven 编译并启动后端 (首次 3-10 分钟)"

    # 启动前预检数据库连通性
    info "预检 MySQL 连接..."
    if ! docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" "$MYSQL_DB" &>/dev/null; then
        err "MySQL 连接失败！请检查:"
        echo "  docker ps | grep $MYSQL_CONTAINER"
        echo "  docker logs $MYSQL_CONTAINER"
        return 1
    fi
    info "预检 Redis 连接..."
    docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" ping 2>/dev/null | grep -q PONG \
        || { err "Redis 连接失败"; return 1; }
    ok "数据库预检通过"

    cd "$BACKEND_DIR"
    mvn clean package -DskipTests -q -Dmaven.compiler.source=8 -Dmaven.compiler.target=8
    local JAR_FILE
    JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    [ -z "$JAR_FILE" ] && { err "未找到打包后的 jar"; exit 1; }
    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    ok "后端已启动 PID=$(cat $WORK_DIR/backend.pid)"
    info "等待 $BACKEND_PORT 端口..."
    local ready=0
    for i in $(seq 1 40); do
        curl -s "http://127.0.0.1:$BACKEND_PORT" >/dev/null 2>&1 && { ready=1; break; }
        sleep 3
    done
    if [ "$ready" -ne 1 ]; then
        err "后端 ${BACKEND_PORT} 秒内未启动，最近日志:"
        tail -30 "$WORK_DIR/backend.log"
        warn "如果看到 Access denied / Communications link failure，说明数据库配置没改对"
        return 1
    fi
    ok "后端 ${BACKEND_PORT} 端口就绪"
}

#====================================================================================
#  7. 启动前端
#====================================================================================
start_frontend() {
    step "9/9 安装并启动前端"
    cd "$FRONTEND_DIR"
    npm config set registry "$NPM_REGISTRY"
    npm install --legacy-peer-deps
    nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    sleep 10
    ok "前端已启动 PID=$(cat $WORK_DIR/frontend.pid)"
}

#====================================================================================
#  8. 注册全局命令
#====================================================================================
register_cmd() {
    step "注册全局命令"
    local SELF
    SELF="$(readlink -f "$0")"
    $SUDO cp "$SELF" /usr/local/bin/$GLOBAL_CMD
    $SUDO chmod +x /usr/local/bin/$GLOBAL_CMD
    ok "全局命令已注册: 以后任意目录执行  $GLOBAL_CMD  即可进入管理菜单"
}

#====================================================================================
#  管理功能
#====================================================================================
start_all() {
    docker start "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null
    cd "$BACKEND_DIR"
    local JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    cd "$FRONTEND_DIR"
    nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    ok "所有服务已启动"
}

stop_all() {
    [ -f "$WORK_DIR/backend.pid" ]  && kill "$(cat $WORK_DIR/backend.pid)" 2>/dev/null && info "后端已停止"
    [ -f "$WORK_DIR/frontend.pid" ] && kill "$(cat $WORK_DIR/frontend.pid)" 2>/dev/null && info "前端已停止"
    read -p "是否同时停止 MySQL/Redis 容器? (y/N): " yn
    { [ "$yn" = "y" ] || [ "$yn" = "Y" ]; } && docker stop "$MYSQL_CONTAINER" "$REDIS_CONTAINER" && info "数据库容器已停止"
}

view_log() {
    echo -e "${CYAN}后端日志 (Ctrl+C 退出):${R}"
    tail -f "$WORK_DIR/backend.log"
}

uninstall_all() {
    read -p "确认卸载? 将删除容器、源码、配置、全局命令! (y/N): " yn
    { [ "$yn" != "y" ] && [ "$yn" != "Y" ]; } && { info "已取消"; return; }
    [ -f "$WORK_DIR/backend.pid" ]  && kill "$(cat $WORK_DIR/backend.pid)"  2>/dev/null || true
    [ -f "$WORK_DIR/frontend.pid" ] && kill "$(cat $WORK_DIR/frontend.pid)" 2>/dev/null || true
    docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    $SUDO rm -f /usr/local/bin/$GLOBAL_CMD
    ok "卸载完成"
}

#====================================================================================
#  完整安装入口
#====================================================================================
install_all() {
    echo -e "${PURPLE}############ 开始安装 KTG-MES ############${R}"
    env_init       || exit 1
    start_db       || exit 1
    pull_source    || exit 1
    import_db
    patch_config
    build_backend  || exit 1
    start_frontend
    register_cmd
    echo ""
    echo -e "${GREEN}############ 安装完成 ############${R}"
    echo -e "  默认账号: ${YELLOW}admin / admin123${R}"
    echo -e "  前端地址:"
    grep -iE "local|network|http://" "$WORK_DIR/frontend.log" | head -5
    echo ""
    echo -e "  以后管理: 任意目录执行  ${YELLOW}$GLOBAL_CMD${R}"
}

#====================================================================================
#  主菜单
#====================================================================================
menu() {
    clear
    echo -e "${CYAN}############################################################${R}"
    echo -e "${CYAN}#${R}${GREEN}          KTG-MES 苦糖果MES 管理工具 v1.0.0             ${R}${CYAN}#${R}"
    echo -e "${CYAN}############################################################${R}"
    echo ""
    echo -e "  ${YELLOW}[1]${R}  完整安装 / 重新安装"
    echo -e "  ${YELLOW}[2]${R}  启动所有服务"
    echo -e "  ${YELLOW}[3]${R}  停止所有服务"
    echo -e "  ${YELLOW}[4]${R}  查看后端日志"
    echo -e "  ${YELLOW}[5]${R}  卸载 KTG-MES"
    echo -e "  ${YELLOW}[0]${R}  退出"
    echo ""
    read -p "请输入选项 [0-5]: " opt
    case "$opt" in
        1) install_all;  read -p "按回车返回菜单...";;
        2) start_all;     read -p "按回车返回菜单...";;
        3) stop_all;     read -p "按回车返回菜单...";;
        4) view_log;;
        5) uninstall_all; read -p "按回车返回菜单...";;
        0) echo "再见!"; exit 0;;
        *) warn "无效选项"; sleep 1;;
    esac
}

#====================================================================================
#  入口：如果脚本带参数（比如直接调用安装），执行；否则进菜单
#====================================================================================
if [ "${1:-}" == "install" ]; then
    install_all
else
    while true; do menu; done
fi
#（注：内容由AI生成）
