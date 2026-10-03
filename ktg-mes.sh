#!/bin/bash
#====================================================================================
#  KTG-MES 苦糖果 MES 一键部署 & 管理工具 v2.0.0
#  修复: Maven多模块打包 / yml直接写入 / Redis端口不误伤 / unzip预装
#  用法: sudo bash ktg-mes.sh
#  账号: admin / admin123
#====================================================================================
set -euo pipefail

# ======================= 可配置项 =======================
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
BACKEND_PORT="8080"
GLOBAL_CMD="ktg-mes"
# ========================================================

if [ -t 1 ]; then
    R='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[1;33m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
else R=''; RED=''; GREEN=''; YELLOW=''; PURPLE=''; CYAN=''; fi
info() { echo -e "${GREEN}[INFO]${R}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${R}  $*"; }
err()  { echo -e "${RED}[ERROR]${R} $*" >&2; }
step() { echo -e "\n${CYAN}========== $* ==========${R}"; }
ok()   { echo -e "${GREEN}✔ $*${R}"; }
SUDO=""; [ "$EUID" -ne 0 ] && SUDO="sudo"

#====================================================================================
env_init() {
    step "1/9 安装基础环境 (JDK8 / Maven / Node16 / unzip / Docker)"
    $SUDO apt update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt install -y \
        curl wget git unzip ca-certificates gnupg lsb-release \
        openjdk-8-jdk-headless maven
    java -version 2>&1 | head -1

    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        $SUDO systemctl enable docker 2>/dev/null || true
        $SUDO systemctl start docker 2>/dev/null || true
    fi
    docker info >/dev/null 2>&1 || { err "Docker 未运行"; exit 1; }

    if ! command -v node &>/dev/null || ! node -v 2>/dev/null | grep -q '^v16'; then
        curl -fsSL https://deb.nodesource.com/setup_16.x | $SUDO -E bash -
        $SUDO DEBIAN_FRONTEND=noninteractive apt install -y nodejs
    fi
    ok "JDK / Maven / Node16 / Docker 就绪"
}

#====================================================================================
start_db() {
    step "2/9 启动 MySQL + Redis"
    if [ -z "$(docker ps -q -f name=^${MYSQL_CONTAINER}$)" ]; then
        docker rm -f "$MYSQL_CONTAINER" 2>/dev/null || true
        docker run -d --name "$MYSQL_CONTAINER" \
            -p ${MYSQL_PORT}:3306 \
            -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" \
            -e MYSQL_DATABASE="$MYSQL_DB" \
            --restart=always $MYSQL_IMAGE \
            --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci \
            --default-time-zone='+8:00'
    fi
    for i in $(seq 1 60); do
        docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PWD" --silent &>/dev/null && break
        sleep 3
    done
    if [ -z "$(docker ps -q -f name=^${REDIS_CONTAINER}$)" ]; then
        docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
        docker run -d --name "$REDIS_CONTAINER" \
            -p ${REDIS_PORT}:6379 --restart=always $REDIS_IMAGE \
            redis-server --requirepass "$REDIS_PWD"
        sleep 3
    fi
    ok "MySQL + Redis 就绪"
}

#====================================================================================
pull_source() {
    step "3/9 下载源码"
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
    if [ ! -d "$BACKEND_DIR" ]; then
        wget -q --show-progress "https://gitee.com/${GITEE_OWNER}/ktg-mes/repository/archive/master.zip" -O /tmp/be.zip
        unzip -q /tmp/be.zip -d /tmp/ && mv /tmp/ktg-mes-master "$BACKEND_DIR"
    fi
    if [ ! -d "$FRONTEND_DIR" ]; then
        wget -q --show-progress "https://gitee.com/${GITEE_OWNER}/ktg-mes-ui/repository/archive/master.zip" -O /tmp/fe.zip
        unzip -q /tmp/fe.zip -d /tmp/ && mv /tmp/ktg-mes-ui-master "$FRONTEND_DIR"
    fi
    ok "源码就绪"
}

#====================================================================================
import_db() {
    step "4/9 导入数据库"
    local SQL_FILE
    SQL_FILE=$(find "$BACKEND_DIR/doc" "$BACKEND_DIR/sql" -type f \( -name "*.sql.gz" -o -name "*.sql" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -z "$SQL_FILE" ] && { warn "未找到 sql 文件"; return 0; }
    info "使用: $SQL_FILE"
    if [[ "$SQL_FILE" == *.gz ]]; then
        gunzip -c "$SQL_FILE" | docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB"
    else
        docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB" < "$SQL_FILE"
    fi
    ok "数据库导入完成"
}

#====================================================================================
#  核心修复: 直接写入完整 yml 模板，不用 sed 改（避免破坏缩进）
#====================================================================================
patch_config() {
    step "5/9 写入配置文件"
    local DRUID_DIR="$BACKEND_DIR/ktg-admin/src/main/resources"
    mkdir -p "$DRUID_DIR"

    # ---- 主配置 application.yml（直接覆盖写） ----
    cat > "$DRUID_DIR/application.yml" << YAMLEOF
server:
  port: $BACKEND_PORT

spring:
  datasource:
    type: com.alibaba.druid.pool.DruidDataSource
    druid:
      master:
        url: jdbc:mysql://127.0.0.1:${MYSQL_PORT}/${MYSQL_DB}?useUnicode=true&characterEncoding=utf8&zeroDateTimeBehavior=convertToNull&useSSL=false&serverTimezone=Asia/Shanghai
        username: root
        password: ${MYSQL_ROOT_PWD}
        driver-class-name: com.mysql.cj.jdbc.Driver
  redis:
    host: 127.0.0.1
    port: ${REDIS_PORT}
    password: ${REDIS_PWD}
    database: 0
YAMLEOF
    ok "application.yml 已写入"

    # ---- 数据库连接配置 application-druid.yml（直接覆盖写） ----
    cat > "$DRUID_DIR/application-druid.yml" << DRUIDEOF
spring:
  datasource:
    type: com.alibaba.druid.pool.DruidDataSource
    driverClassName: com.mysql.cj.jdbc.Driver
    druid:
      master:
        url: jdbc:mysql://127.0.0.1:${MYSQL_PORT}/${MYSQL_DB}?useUnicode=true&characterEncoding=utf8&zeroDateTimeBehavior=convertToNull&useSSL=false&serverTimezone=Asia/Shanghai
        username: root
        password: ${MYSQL_ROOT_PWD}
      slave:
        enabled: false
      initialSize: 5
      minIdle: 10
      maxActive: 20
      maxWait: 60000
DRUIDEOF
    ok "application-druid.yml 已写入"

    # ---- 前端代理 vue.config.js ----
    local VUE_CONF="$FRONTEND_DIR/vue.config.js"
    [ -f "$VUE_CONF" ] && {
        sed -i "s|localhost:[0-9]\+|localhost:$BACKEND_PORT|g" "$VUE_CONF"
        ok "前端代理 -> localhost:$BACKEND_PORT"
    }
}

#====================================================================================
#  核心修复: 在根目录 mvn clean install（编译全部子模块）
#====================================================================================
build_backend() {
    step "6/9 Maven 编译（根目录 install 全部子模块）"

    # 预检
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" "$MYSQL_DB" &>/dev/null \
        || { err "MySQL 连接失败"; return 1; }
    docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG \
        || { err "Redis 连接失败"; return 1; }
    ok "预检通过"

    cd "$BACKEND_DIR"
    # 关键: 根目录 install，把所有子模块装到本地仓库
    mvn clean install -DskipTests -q
    ok "全部子模块编译完成"

    local JAR_FILE
    JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    [ -z "$JAR_FILE" ] && { err "未找到 jar"; return 1; }

    pkill -f ktg-admin.jar 2>/dev/null || true
    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    info "等待 $BACKEND_PORT 端口..."
    local ready=0
    for i in $(seq 1 40); do
        curl -s "http://127.0.0.1:$BACKEND_PORT" >/dev/null 2>&1 && { ready=1; break; }
        sleep 3
    done
    [ "$ready" -ne 1 ] && { err "后端未就绪，日志:"; tail -30 "$WORK_DIR/backend.log"; return 1; }
    ok "后端 $BACKEND_PORT 就绪"
}

#====================================================================================
start_frontend() {
    step "7/9 启动前端"
    cd "$FRONTEND_DIR"
    npm config set registry "$NPM_REGISTRY"
    npm install --legacy-peer-deps
    pkill -f "npm run dev" 2>/dev/null || true
    nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    sleep 10
    ok "前端已启动"
}

#====================================================================================
register_cmd() {
    step "8/9 注册全局命令"
    local SELF; SELF="$(readlink -f "$0")"
    $SUDO cp "$SELF" /usr/local/bin/$GLOBAL_CMD
    $SUDO chmod +x /usr/local/bin/$GLOBAL_CMD
    ok "任意目录敲 $GLOBAL_CMD 进菜单"
}

#====================================================================================
start_all() {
    docker start "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null
    cd "$BACKEND_DIR"
    local JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    cd "$FRONTEND_DIR" && nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    ok "全部启动"
}
stop_all() {
    [ -f "$WORK_DIR/backend.pid" ]  && kill "$(cat $WORK_DIR/backend.pid)" 2>/dev/null && info "后端已停"
    [ -f "$WORK_DIR/frontend.pid" ] && kill "$(cat $WORK_DIR/frontend.pid)" 2>/dev/null && info "前端已停"
    read -p "停 MySQL/Redis? (y/N): " yn
    { [ "$yn" = "y" ] || [ "$yn" = "Y" ]; } && docker stop "$MYSQL_CONTAINER" "$REDIS_CONTAINER"
}
view_log() { tail -f "$WORK_DIR/backend.log"; }
uninstall_all() {
    read -p "确认卸载? (y/N): " yn
    { [ "$yn" != "y" ] && [ "$yn" != "Y" ]; } && { info "取消"; return; }
    pkill -f ktg-admin.jar 2>/dev/null || true
    pkill -f "npm run dev" 2>/dev/null || true
    docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    $SUDO rm -f /usr/local/bin/$GLOBAL_CMD
    ok "已卸载"
}

install_all() {
    echo -e "${PURPLE}############ 开始安装 KTG-MES v2.0 ############${R}"
    env_init; start_db; pull_source; import_db
    patch_config; build_backend; start_frontend; register_cmd
    echo ""
    echo -e "${GREEN}############ 完成 ############${R}"
    echo -e "  账号: ${YELLOW}admin / admin123${R}"
    echo -e "  访问: http://localhost:$BACKEND_PORT"
    echo -e "  管理: $GLOBAL_CMD"
}

#====================================================================================
menu() {
    clear
    echo -e "${CYAN}############################################################${R}"
    echo -e "${CYAN}#${R}${GREEN}          KTG-MES 苦糖果MES 管理工具 v2.0.0            ${R}${CYAN}#${R}"
    echo -e "${CYAN}############################################################${R}"
    echo ""
    echo -e "  ${YELLOW}[1]${R}  完整安装"
    echo -e "  ${YELLOW}[2]${R}  启动服务"
    echo -e "  ${YELLOW}[3]${R}  停止服务"
    echo -e "  ${YELLOW}[4]${R}  后端日志"
    echo -e "  ${YELLOW}[5]${R}  卸载"
    echo -e "  ${YELLOW}[0]${R}  退出"
    echo ""
    read -p "请输入 [0-5]: " opt
    case "$opt" in
        1) install_all; read -p "回车...";;
        2) start_all; read -p "回车...";;
        3) stop_all; read -p "回车...";;
        4) view_log;;
        5) uninstall_all; read -p "回车...";;
        0) echo "再见!"; exit 0;;
        *) warn "无效"; sleep 1;;
    esac
}

[ "${1:-}" == "install" ] && install_all || while true; do menu; done
#（注：内容由AI生成）
