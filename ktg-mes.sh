#!/bin/bash
#====================================================================================
#  KTG-MES 苦糖果 MES 一键部署 & 管理工具 v3.2 最终稳定版
#  用法: sudo bash ktg-mes.sh
#  默认账号: admin / admin123
#  修复: Docker源失败/apt锁/Maven OOM/前端地址不显示/信息查询 等全部已知问题
#====================================================================================
set -eo pipefail

# ======================= 可配置项 =======================
WORK_DIR="/root/ktg-mes-deploy"
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

BACKEND_PORT="8080"
GLOBAL_CMD="ktg-mes"

# 国内镜像源配置
APT_MIRROR="mirrors.aliyun.com"
DOCKER_MIRROR="https://mirrors.aliyun.com/docker-ce"
MAVEN_MIRROR="https://maven.aliyun.com/repository/public"
NPM_MIRROR="https://registry.npmmirror.com"
GITEE_OWNER="kutangguo"
# ========================================================

# 颜色输出
R='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
info() { echo -e "${GREEN}[INFO]${R}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${R}  $*"; }
err()  { echo -e "${RED}[ERROR]${R}  $*" >&2; }
step() { echo -e "\n${CYAN}========== $* ==========${R}"; }
ok()   { echo -e "${GREEN}✔ $*${R}"; }

#====================================================================================
# 工具函数
#====================================================================================
# 释放apt锁
free_apt_lock() {
    if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        warn "检测到apt包锁被占用，正在释放..."
        killall apt apt-get dpkg 2>/dev/null || true
        sleep 1
        rm -f /var/lib/dpkg/lock-frontend
        rm -f /var/lib/dpkg/lock
        rm -f /var/cache/apt/archives/lock
        dpkg --configure -a 2>/dev/null || true
        ok "包锁已释放"
    fi
}

# 检查命令是否存在
cmd_exists() {
    command -v "$1" &>/dev/null
}

# 自动检测前端端口
get_frontend_port() {
    sleep 2
    local port
    port=$(ss -tlnp | grep "node" | grep -oP ':\K[0-9]+' | head -1)
    echo "$port"
}

#====================================================================================
# 1. 系统环境初始化（全国内源 + 容错）
#====================================================================================
env_init() {
    step "1/9 初始化系统运行环境"

    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 sudo 运行此脚本"
        exit 1
    fi

    # 释放apt锁
    free_apt_lock

    # 替换apt国内源
    info "替换软件源为阿里云镜像"
    sed -i "s/ports.ubuntu.com/$APT_MIRROR/g" /etc/apt/sources.list 2>/dev/null || true
    sed -i "s/security.ubuntu.com/$APT_MIRROR/g" /etc/apt/sources.list 2>/dev/null || true
    apt update -y 2>/dev/null || apt update -y

    # 安装基础依赖
    info "安装基础依赖包"
    apt install -y curl wget git unzip ca-certificates gnupg lsb-release net-tools iproute2
    apt install -y openjdk-8-jdk-headless maven
    java -version 2>&1 | head -1

    # 配置Maven阿里云镜像
    info "配置Maven国内镜像"
    mkdir -p /etc/maven
    cat > /etc/maven/settings.xml << 'EOF'
<settings>
  <mirrors>
    <mirror>
      <id>aliyun</id>
      <mirrorOf>central</mirrorOf>
      <name>阿里云公共仓库</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
EOF

    # 安装Docker（阿里云源，避免官方源连接重置）
    if ! cmd_exists docker; then
        info "安装Docker（阿里云镜像源）"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "$DOCKER_MIRROR/linux/ubuntu/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_MIRROR/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
    fi

    # 检查Docker运行状态
    if ! docker info >/dev/null 2>&1; then
        warn "Docker未运行，尝试启动..."
        systemctl start docker 2>/dev/null || true
        sleep 2
        docker info >/dev/null 2>&1 || { err "Docker启动失败，请手动检查"; exit 1; }
    fi

    # 配置Docker镜像加速
    info "配置Docker镜像加速"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn"]
}
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true

    # 安装Node.js 16
    if ! cmd_exists node || ! node -v 2>/dev/null | grep -q '^v16'; then
        info "安装Node.js 16"
        curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
        apt install -y nodejs
    fi
    node -v

    # 系统参数调优
    info "优化系统参数"
    grep -q "nofile 65536" /etc/security/limits.conf || cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
EOF

    ok "系统环境初始化完成"
}

#====================================================================================
# 2. 启动数据库容器
#====================================================================================
start_db() {
    step "2/9 启动 MySQL + Redis 容器"

    # MySQL
    if [ -z "$(docker ps -q -f name=^${MYSQL_CONTAINER}$)" ]; then
        docker rm -f "$MYSQL_CONTAINER" 2>/dev/null || true
        docker run -d --name "$MYSQL_CONTAINER" \
            -p ${MYSQL_PORT}:3306 \
            -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" \
            -e MYSQL_DATABASE="$MYSQL_DB" \
            --restart=always "$MYSQL_IMAGE" \
            --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci \
            --default-time-zone='+8:00'
        info "MySQL容器已创建，等待启动..."
    fi

    # 等待MySQL就绪
    for i in $(seq 1 60); do
        docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PWD" --silent &>/dev/null && break
        sleep 2
    done
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" &>/dev/null \
        || { err "MySQL启动失败"; exit 1; }

    # Redis
    if [ -z "$(docker ps -q -f name=^${REDIS_CONTAINER}$)" ]; then
        docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
        docker run -d --name "$REDIS_CONTAINER" \
            -p ${REDIS_PORT}:6379 --restart=always "$REDIS_IMAGE" \
            redis-server --requirepass "$REDIS_PWD"
        info "Redis容器已创建"
        sleep 3
    fi

    docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" ping 2>/dev/null | grep -q PONG \
        || { err "Redis启动失败"; exit 1; }

    ok "MySQL + Redis 运行正常"
}

#====================================================================================
# 3. 下载源码（Gitee国内源）
#====================================================================================
pull_source() {
    step "3/9 下载项目源码"
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

    # 后端源码
    if [ ! -d "$BACKEND_DIR" ]; then
        info "下载后端源码..."
        wget -q --show-progress --tries=3 "https://gitee.com/${GITEE_OWNER}/ktg-mes/repository/archive/master.zip" -O /tmp/be.zip
        unzip -q /tmp/be.zip -d /tmp/
        mv /tmp/ktg-mes-master "$BACKEND_DIR"
    fi

    # 前端源码
    if [ ! -d "$FRONTEND_DIR" ]; then
        info "下载前端源码..."
        wget -q --show-progress --tries=3 "https://gitee.com/${GITEE_OWNER}/ktg-mes-ui/repository/archive/master.zip" -O /tmp/fe.zip
        unzip -q /tmp/fe.zip -d /tmp/
        mv /tmp/ktg-mes-ui-master "$FRONTEND_DIR"
    fi

    ok "源码下载完成"
}

#====================================================================================
# 4. 导入数据库
#====================================================================================
import_db() {
    step "4/9 导入数据库脚本"
    local SQL_FILE
    SQL_FILE=$(find "$BACKEND_DIR/doc" "$BACKEND_DIR/sql" -type f \( -name "*.sql.gz" -o -name "*.sql" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -z "$SQL_FILE" ] && { warn "未找到SQL文件，跳过导入"; return 0; }

    info "使用数据库文件: $SQL_FILE"
    if [[ "$SQL_FILE" == *.gz ]]; then
        gunzip -c "$SQL_FILE" | docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB"
    else
        docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB" < "$SQL_FILE"
    fi

    ok "数据库导入完成"
}

#====================================================================================
# 5. 修改配置（复用原始yml，只替换占位符）
#====================================================================================
patch_config() {
    step "5/9 更新项目配置文件"
    local RES_DIR="$BACKEND_DIR/ktg-admin/src/main/resources"
    local DRUID_CONF="$RES_DIR/application-druid.yml"
    local APP_CONF="$RES_DIR/application.yml"
    local VUE_CONF="$FRONTEND_DIR/vue.config.js"

    # 数据库配置
    if [ -f "$DRUID_CONF" ]; then
        cp "$DRUID_CONF" "${DRUID_CONF}.bak"
        sed -i "s|your_username|root|g" "$DRUID_CONF"
        sed -i "s|your_password|$MYSQL_ROOT_PWD|g" "$DRUID_CONF"
        sed -i "s|jdbc:mysql://[^?]*/[a-zA-Z0-9_-]*|jdbc:mysql://127.0.0.1:${MYSQL_PORT}/${MYSQL_DB}|g" "$DRUID_CONF"
        ok "数据库连接配置已更新"
    else
        warn "未找到druid配置文件，请检查源码结构"
    fi

    # 主配置
    if [ -f "$APP_CONF" ]; then
        cp "$APP_CONF" "${APP_CONF}.bak"
        # 修改服务端口
        sed -i "/^server:/,/^[a-z]/ s/^\([[:space:]]*port:[[:space:]]*\)[0-9]\+/\1$BACKEND_PORT/" "$APP_CONF"
        # 修改Redis密码
        sed -i "/^[[:space:]]*redis:/,/^[a-z]/ s/^\([[:space:]]*password:[[:space:]]*\).*/\1$REDIS_PWD/" "$APP_CONF"
        # 修改Redis端口
        sed -i "/^[[:space:]]*redis:/,/^[a-z]/ s/^\([[:space:]]*port:[[:space:]]*\)[0-9]\+/\1$REDIS_PORT/" "$APP_CONF"
        ok "主配置已更新（端口:$BACKEND_PORT，Redis密码已设置）"
    else
        warn "未找到主配置文件，请检查源码结构"
    fi

    # 前端代理
    if [ -f "$VUE_CONF" ]; then
        sed -i "s|localhost:[0-9]\+|localhost:$BACKEND_PORT|g" "$VUE_CONF"
        ok "前端代理配置已指向 localhost:$BACKEND_PORT"
    fi
}

#====================================================================================
# 6. 编译后端（内存优化，防OOM）
#====================================================================================
build_backend() {
    step "6/9 Maven编译后端项目"

    # 预检数据库
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" "$MYSQL_DB" &>/dev/null \
        || { err "MySQL连接失败"; exit 1; }
    docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" ping 2>/dev/null | grep -q PONG \
        || { err "Redis连接失败"; exit 1; }
    ok "数据库预检通过"

    cd "$BACKEND_DIR"
    # 设置Maven内存，防止WSL下OOM被杀死
    export MAVEN_OPTS="-Xms512m -Xmx4g"

    info "开始编译（首次编译耗时较长，请耐心等待）..."
    mvn clean install -DskipTests -q

    # 查找jar包
    local JAR_FILE
    JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    [ -z "$JAR_FILE" ] && { err "编译失败，未找到jar包"; exit 1; }

    # 停止旧进程
    pkill -f ktg-admin.jar 2>/dev/null || true
    sleep 1

    # 启动后端
    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    info "后端进程已启动，等待端口就绪..."

    # 等待端口
    local ready=0
    for i in $(seq 1 60); do
        curl -s "http://127.0.0.1:$BACKEND_PORT" >/dev/null 2>&1 && { ready=1; break; }
        sleep 2
    done

    if [ "$ready" -ne 1 ]; then
        err "后端启动失败，最后30行日志："
        tail -30 "$WORK_DIR/backend.log"
        exit 1
    fi

    ok "后端启动成功，端口 $BACKEND_PORT 就绪"
}

#====================================================================================
# 7. 启动前端（自动检测端口+等待就绪）
#====================================================================================
start_frontend() {
    step "7/9 启动前端服务"
    cd "$FRONTEND_DIR"

    npm config set registry "$NPM_MIRROR"
    info "安装前端依赖..."
    npm install --legacy-peer-deps 2>&1 | tail -5

    # 停止旧进程
    pkill -f "npm run dev" 2>/dev/null || true
    sleep 1

    nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    info "前端服务启动中，等待端口就绪..."

    # 等待前端端口启动，最多等待60秒
    local fe_port=""
    for i in $(seq 1 30); do
        fe_port=$(get_frontend_port)
        if [ -n "$fe_port" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "$fe_port" ]; then
        warn "未检测到前端端口，可手动查看日志确认"
    else
        ok "前端启动成功，端口 $fe_port 就绪"
    fi

    # 保存前端端口到文件，后续查询调用
    echo "$fe_port" > "$WORK_DIR/frontend.port"
}

#====================================================================================
# 8. 注册全局命令
#====================================================================================
register_cmd() {
    step "8/9 注册全局管理命令"
    local SELF; SELF="$(readlink -f "$0")"
    cp "$SELF" /usr/local/bin/$GLOBAL_CMD
    chmod +x /usr/local/bin/$GLOBAL_CMD
    ok "全局命令注册完成，任意目录输入 $GLOBAL_CMD 即可打开管理菜单"
}

#====================================================================================
# 9. 运行信息总览（新增功能）
#====================================================================================
show_info() {
    clear
    echo -e "${CYAN}############################################################${R}"
    echo -e "${CYAN}#${R}${GREEN}          KTG-MES 运行信息总览            ${R}${CYAN}#${R}"
    echo -e "${CYAN}############################################################${R}"
    echo ""

    echo -e "  ${YELLOW}【系统登录账号】${R}"
    echo -e "  管理员账号: admin"
    echo -e "  管理员密码: admin123"
    echo ""

    echo -e "  ${YELLOW}【数据库信息】${R}"
    echo -e "  MySQL 地址: 127.0.0.1:${MYSQL_PORT}"
    echo -e "  MySQL 账号: root"
    echo -e "  MySQL 密码: ${MYSQL_ROOT_PWD}"
    echo -e "  数据库名: ${MYSQL_DB}"
    echo ""

    echo -e "  ${YELLOW}【Redis信息】${R}"
    echo -e "  Redis 地址: 127.0.0.1:${REDIS_PORT}"
    echo -e "  Redis 密码: ${REDIS_PWD}"
    echo ""

    echo -e "  ${YELLOW}【访问地址】${R}"
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')
    echo -e "  后端服务: http://localhost:${BACKEND_PORT}"
    local fe_port
    fe_port=$(cat "$WORK_DIR/frontend.port" 2>/dev/null || echo "未启动/未检测")
    echo -e "  前端服务: http://localhost:${fe_port}"
    echo -e "  内网访问: http://${local_ip}:${fe_port}"
    echo ""

    echo -e "  ${YELLOW}【服务运行状态】${R}"
    if docker ps -q -f name=^${MYSQL_CONTAINER}$ >/dev/null 2>&1; then
        echo -e "  MySQL 容器: ${GREEN}运行中${R}"
    else
        echo -e "  MySQL 容器: ${RED}已停止${R}"
    fi

    if docker ps -q -f name=^${REDIS_CONTAINER}$ >/dev/null 2>&1; then
        echo -e "  Redis 容器: ${GREEN}运行中${R}"
    else
        echo -e "  Redis 容器: ${RED}已停止${R}"
    fi

    if pgrep -f ktg-admin.jar >/dev/null 2>&1; then
        echo -e "  后端服务: ${GREEN}运行中${R}"
    else
        echo -e "  后端服务: ${RED}已停止${R}"
    fi

    if pgrep -f "npm run dev" >/dev/null 2>&1; then
        echo -e "  前端服务: ${GREEN}运行中${R}"
    else
        echo -e "  前端服务: ${RED}已停止${R}"
    fi
    echo ""

    read -p "按回车返回菜单..."
}

#====================================================================================
# 管理功能
#====================================================================================
start_all() {
    docker start "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
    cd "$BACKEND_DIR"
    local JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    cd "$FRONTEND_DIR" && nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    ok "全部服务已启动"
}

stop_all() {
    [ -f "$WORK_DIR/backend.pid" ]  && kill "$(cat $WORK_DIR/backend.pid)" 2>/dev/null && info "后端已停止"
    [ -f "$WORK_DIR/frontend.pid" ] && kill "$(cat $WORK_DIR/frontend.pid)" 2>/dev/null && info "前端已停止"
    read -p "是否同时停止 MySQL/Redis 容器? (y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        docker stop "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null
        info "数据库容器已停止"
    fi
}

view_log() {
    echo "=== 后端日志（按Ctrl+C退出） ==="
    tail -f "$WORK_DIR/backend.log"
}

uninstall_all() {
    read -p "确认卸载所有KTG-MES相关内容? (y/N): " yn
    { [ "$yn" != "y" ] && [ "$yn" != "Y" ]; } && { info "已取消"; return; }
    pkill -f ktg-admin.jar 2>/dev/null || true
    pkill -f "npm run dev" 2>/dev/null || true
    docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    rm -f /usr/local/bin/$GLOBAL_CMD
    ok "卸载完成"
}

#====================================================================================
# 完整安装流程
#====================================================================================
install_all() {
    echo -e "${PURPLE}############ 开始安装 KTG-MES v3.2 最终稳定版 ############${R}"
    env_init
    start_db
    pull_source
    import_db
    patch_config
    build_backend
    start_frontend
    register_cmd

    local fe_port
    fe_port=$(cat "$WORK_DIR/frontend.port" 2>/dev/null || echo "未检测到")
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}############ 安装完成 ############${R}"
    echo -e "  默认账号: ${YELLOW}admin / admin123${R}"
    echo -e "  后端地址: http://localhost:$BACKEND_PORT"
    echo -e "  前端地址: http://localhost:$fe_port"
    echo -e "  内网访问: http://$local_ip:$fe_port"
    echo -e "  管理命令: $GLOBAL_CMD"
}

#====================================================================================
# 主菜单
#====================================================================================
menu() {
    clear
    echo -e "${CYAN}############################################################${R}"
    echo -e "${CYAN}#${R}${GREEN}          KTG-MES 苦糖果MES 管理工具 v3.2 最终版            ${R}${CYAN}#${R}"
    echo -e "${CYAN}############################################################${R}"
    echo ""
    echo -e "  ${YELLOW}[1]${R}  完整安装"
    echo -e "  ${YELLOW}[2]${R}  启动服务"
    echo -e "  ${YELLOW}[3]${R}  停止服务"
    echo -e "  ${YELLOW}[4]${R}  查看后端日志"
    echo -e "  ${YELLOW}[5]${R}  卸载"
    echo -e "  ${YELLOW}[6]${R}  查看运行信息"
    echo -e "  ${YELLOW}[0]${R}  退出"
    echo ""
    read -p "请输入选项 [0-6]: " opt
    case "$opt" in
        1) install_all; read -p "按回车返回菜单...";;
        2) start_all; read -p "按回车返回菜单...";;
        3) stop_all; read -p "按回车返回菜单...";;
        4) view_log;;
        5) uninstall_all; read -p "按回车返回菜单...";;
        6) show_info;;
        0) echo "再见!"; exit 0;;
        *) warn "无效选项"; sleep 1;;
    esac
}

# 入口
[ "${1:-}" == "install" ] && install_all || while true; do menu; done
