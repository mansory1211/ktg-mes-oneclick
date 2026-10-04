#!/bin/bash
#====================================================================================
#  KTG-MES 一键部署管理工具 v4.8 稳定优化版
#  修复：Redis配置错误、Docker服务预检、编译优化、启动检测、全局命令注册
#====================================================================================
set -eo pipefail

# ======================= 全局配置 =======================
WORK_DIR="/root/ktg-mes-deploy"
BACKEND_DIR="$WORK_DIR/ktg-mes"
FRONTEND_DIR="$WORK_DIR/ktg-mes-ui"

MYSQL_CONTAINER="ktg-mysql"
MYSQL_IMAGE="mysql:5.7"
MYSQL_PORT=3306
MYSQL_ROOT_PWD="123456"
MYSQL_DB="j2eedb"

REDIS_CONTAINER="ktg-redis"
REDIS_IMAGE="redis:7"
REDIS_PORT=6379
REDIS_PWD="123456"

BACKEND_PORT=8080
GLOBAL_CMD="ktg"

APT_MIRROR="mirrors.aliyun.com"
MAVEN_SETTINGS="/etc/maven/settings.xml"
NPM_MIRROR="https://registry.npmmirror.com"

DOCKER_MIRRORS=(
  "https://hub-mirror.c.163.com"
  "https://docker.mirrors.ustc.edu.cn"
  "https://registry.cn-hangzhou.aliyuncs.com"
)

DOCKER_COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
DOCKER_NETWORK="ktg-network"

# ======================= 工具函数 =======================
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; }
ok()    { echo -e "\033[32m✔\033[0m  $*"; }

# 检查并启动Docker服务
ensure_docker_running() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi
    warn "Docker服务未运行，尝试启动..."
    systemctl start docker 2>/dev/null || true
    sleep 3
    if docker info >/dev/null 2>&1; then
        ok "Docker服务已启动"
        return 0
    fi
    err "Docker服务启动失败，请手动检查：systemctl status docker"
    exit 1
}

# 检查命令是否存在
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# 注册全局命令
register_global_cmd() {
    local script_path
    script_path="$(readlink -f "$0")"
    if [ ! -f "/usr/local/bin/$GLOBAL_CMD" ] || [ "$(readlink -f "/usr/local/bin/$GLOBAL_CMD")" != "$script_path" ]; then
        cp "$script_path" "/usr/local/bin/$GLOBAL_CMD"
        chmod +x "/usr/local/bin/$GLOBAL_CMD"
        ok "全局命令 $GLOBAL_CMD 已注册"
    fi
}

# ======================= 1. 系统环境初始化 =======================
env_init() {
    echo ""
    info "===== 初始化系统环境 ====="
    
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 权限运行：sudo $0"
        exit 1
    fi

    mkdir -p "$WORK_DIR"
    register_global_cmd

    # 基础依赖安装
    if ! cmd_exists mvn || ! cmd_exists java || ! cmd_exists node; then
        info "安装基础依赖..."
        apt update -qq >/dev/null 2>&1
        apt install -y -qq curl wget git openjdk-8-jdk maven nodejs npm >/dev/null 2>&1
    fi

    # Maven 阿里云源配置
    if [ ! -f "$MAVEN_SETTINGS" ]; then
        mkdir -p /etc/maven
        cat > "$MAVEN_SETTINGS" << 'EOF'
<settings>
  <mirrors>
    <mirror>
      <id>aliyun</id>
      <mirrorOf>central</mirrorOf>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
EOF
    fi

    ok "系统环境初始化完成"
}

# ======================= 2. Docker 环境配置 =======================
docker_env_init() {
    ensure_docker_running
    
    # 配置默认镜像源（第一个）
    if [ ${#DOCKER_MIRRORS[@]} -gt 0 ]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["${DOCKER_MIRRORS[0]}"],
  "dns": ["223.5.5.5", "114.114.114.114"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "3"}
}
EOF
        systemctl daemon-reload
        systemctl restart docker
        sleep 2
    fi
}

# ======================= 3. 源码下载 =======================
pull_source() {
    echo ""
    info "===== 检查项目源码 ====="
    
    if [ -d "$BACKEND_DIR" ] && [ -d "$FRONTEND_DIR" ]; then
        ok "项目源码已存在"
        return 0
    fi

    info "下载项目源码..."
    cd "$WORK_DIR"

    # 后端
    if [ ! -d "$BACKEND_DIR" ]; then
        wget -q --show-progress "https://gitee.com/ktg-dev/ktg-mes/repository/archive/master.zip" -O backend.zip
        unzip -q backend.zip
        mv ktg-mes-master ktg-mes
        rm -f backend.zip
    fi

    # 前端
    if [ ! -d "$FRONTEND_DIR" ]; then
        wget -q --show-progress "https://gitee.com/ktg-dev/ktg-mes-ui/repository/archive/master.zip" -O frontend.zip
        unzip -q frontend.zip
        mv ktg-mes-ui-master ktg-mes-ui
        rm -f frontend.zip
    fi

    ok "源码下载完成"
}

# ======================= 4. 数据库容器启动 =======================
start_db_containers() {
    echo ""
    info "===== 启动数据库容器 ====="
    ensure_docker_running

    # 启动 MySQL
    if ! docker ps --format '{{.Names}}' | grep -q "$MYSQL_CONTAINER"; then
        info "启动 MySQL 容器..."
        docker run -d --name "$MYSQL_CONTAINER" \
            -p "$MYSQL_PORT:3306" \
            -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" \
            -e MYSQL_DATABASE="$MYSQL_DB" \
            --restart always \
            "$MYSQL_IMAGE" \
            --character-set-server=utf8mb4 \
            --collation-server=utf8mb4_unicode_ci >/dev/null
        
        # 等待 MySQL 就绪
        info "等待 MySQL 初始化..."
        for i in {1..30}; do
            if docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
    fi
    ok "MySQL 容器运行正常"

    # 启动 Redis
    if ! docker ps --format '{{.Names}}' | grep -q "$REDIS_CONTAINER"; then
        info "启动 Redis 容器..."
        docker run -d --name "$REDIS_CONTAINER" \
            -p "$REDIS_PORT:6379" \
            --restart always \
            "$REDIS_IMAGE" \
            redis-server --requirepass "$REDIS_PWD" >/dev/null
        sleep 2
    fi
    ok "Redis 容器运行正常"
}

# ======================= 5. 配置文件自动修正（核心修复） =======================
patch_config() {
    echo ""
    info "===== 自动修正项目配置 ====="
    
    local res_dir="$BACKEND_DIR/ktg-admin/src/main/resources"
    if [ ! -d "$res_dir" ]; then
        warn "未找到配置目录，跳过修正"
        return 0
    fi

    # 修正数据库配置
    info "修正数据库连接配置..."
    for cfg in application.yml application-druid.yml application.properties; do
        [ -f "$res_dir/$cfg" ] || continue
        sed -i "s#jdbc:mysql://.*:#jdbc:mysql://127.0.0.1:$MYSQL_PORT:#g" "$res_dir/$cfg" 2>/dev/null || true
        sed -i "s#username:.*root#username: root#g" "$res_dir/$cfg" 2>/dev/null || true
        sed -i "s#password:.*#password: $MYSQL_ROOT_PWD#g" "$res_dir/$cfg" 2>/dev/null || true
    done
    ok "数据库连接配置已更新"

    # 修正 Redis 配置（核心修复：解决连8080端口的问题）
    info "修正 Redis 连接配置..."
    for cfg in application.yml application-druid.yml application.properties; do
        [ -f "$res_dir/$cfg" ] || continue
        
        # YAML 格式
        sed -i "s#redis.host:.*#redis.host: 127.0.0.1#g" "$res_dir/$cfg" 2>/dev/null || true
        sed -i "s#redis.port:.*#redis.port: $REDIS_PORT#g" "$res_dir/$cfg" 2>/dev/null || true
        sed -i "s#redis.password:.*#redis.password: $REDIS_PWD#g" "$res_dir/$cfg" 2>/dev/null || true
        
        # Properties 格式
        sed -i "s#spring.redis.host=.*#spring.redis.host=127.0.0.1#g" "$res_dir/$cfg" 2>/dev/null || true
        sed -i "s#spring.redis.port=.*#spring.redis.port=$REDIS_PORT#g" "$res_dir/$cfg" 2>/dev/null || true
        sed -i "s#spring.redis.password=.*#spring.redis.password=$REDIS_PWD#g" "$res_dir/$cfg" 2>/dev/null || true
    done
    ok "Redis 连接配置已更新（host=127.0.0.1，port=$REDIS_PORT）"
}

# ======================= 6. 本地编译 =======================
build_local() {
    echo ""
    info "===== 本地编译项目 ====="

    # 后端编译
    info "编译后端..."
    cd "$BACKEND_DIR"
    export MAVEN_OPTS="-Xms512m -Xmx2g"
    mvn clean install -DskipTests -s "$MAVEN_SETTINGS" -q
    
    local jar_file
    jar_file=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    if [ -z "$jar_file" ] || [ ! -f "$jar_file" ]; then
        err "后端编译失败，未生成 jar 文件"
        exit 1
    fi
    ok "后端编译完成：$jar_file"

    # 前端编译
    info "编译前端..."
    cd "$FRONTEND_DIR"
    npm config set registry "$NPM_MIRROR" >/dev/null 2>&1
    
    if [ ! -d node_modules ]; then
        npm install --legacy-peer-deps --silent >/dev/null 2>&1
        npm install less@3.13.1 less-loader@6.2.0 --legacy-peer-deps --silent >/dev/null 2>&1
    fi
    
    npm run build >/dev/null 2>&1
    if [ ! -d dist ]; then
        warn "前端开发模式运行，跳过 build"
    else
        ok "前端编译完成"
    fi
}

# ======================= 7. 启动本地服务 =======================
start_local_services() {
    echo ""
    info "===== 启动本地服务 ====="

    # 杀掉旧进程
    pkill -f ktg-admin 2>/dev/null || true
    pkill -f "npm run dev" 2>/dev/null || true
    sleep 1

    # 启动后端（带Redis参数兜底）
    info "启动后端服务..."
    cd "$BACKEND_DIR"
    local jar_file
    jar_file=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    
    nohup java -jar "$jar_file" \
        --spring.redis.host=127.0.0.1 \
        --spring.redis.port="$REDIS_PORT" \
        --spring.redis.password="$REDIS_PWD" \
        > "$WORK_DIR/backend.log" 2>&1 &
    
    # 等待后端启动
    info "等待后端服务就绪..."
    local success=0
    for i in {1..30}; do
        if ss -tlnp | grep -q ":$BACKEND_PORT "; then
            success=1
            break
        fi
        sleep 1
    done

    if [ $success -eq 0 ]; then
        err "后端启动失败，请查看日志：tail -50 $WORK_DIR/backend.log"
        exit 1
    fi
    ok "后端服务启动成功，端口：$BACKEND_PORT"

    # 启动前端
    info "启动前端服务..."
    cd "$FRONTEND_DIR"
    nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    sleep 3
    
    ok "前端服务已启动"
    echo ""
    info "===== 部署完成 ====="
    echo "  后端地址：http://127.0.0.1:$BACKEND_PORT"
    echo "  后端日志：$WORK_DIR/backend.log"
    echo "  前端日志：$WORK_DIR/frontend.log"
    echo "  管理命令：sudo $GLOBAL_CMD"
}

# ======================= 8. 一键完整本地部署 =======================
install_local_full() {
    env_init
    docker_env_init
    pull_source
    start_db_containers
    patch_config
    build_local
    start_local_services
}

# ======================= 9. 主菜单 =======================
show_menu() {
    clear
    echo "=============================================="
    echo "       KTG-MES 一键部署管理工具 v4.8"
    echo "=============================================="
    echo "  [1] 本地模式完整安装（推荐）"
    echo "  [2] 仅启动数据库容器"
    echo "  [3] 重新编译后端"
    echo "  [4] 重启后端服务"
    echo "  [5] 查看后端日志"
    echo "  [6] 一键清理所有"
    echo "  [0] 退出"
    echo "=============================================="
    read -p "请输入选项：" opt

    case $opt in
        1) install_local_full ;;
        2) env_init; docker_env_init; start_db_containers ;;
        3) env_init; patch_config; build_local ;;
        4) env_init; start_local_services ;;
        5) tail -f "$WORK_DIR/backend.log" ;;
        6) 
            warn "即将停止所有服务并清理文件..."
            read -p "确认执行？(y/n):" confirm
            if [ "$confirm" = "y" ]; then
                pkill -f ktg-admin 2>/dev/null || true
                pkill -f "npm run dev" 2>/dev/null || true
                docker rm -f "$MYSQL_CONTAINER" "$REDIS_CONTAINER" 2>/dev/null || true
                rm -rf "$WORK_DIR"
                rm -f "/usr/local/bin/$GLOBAL_CMD"
                ok "清理完成"
            fi
            ;;
        0) exit 0 ;;
        *) warn "无效选项" ; sleep 1 ; show_menu ;;
    esac
}

# ======================= 入口 =======================
if [ $# -eq 0 ]; then
    show_menu
else
    case "$1" in
        install) install_local_full ;;
        start)   env_init; start_db_containers; start_local_services ;;
        log)     tail -f "$WORK_DIR/backend.log" ;;
        *)       show_menu ;;
    esac
fi
