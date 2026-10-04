#!/bin/bash
#====================================================================================
#  KTG-MES 苦糖果 MES 一键部署 & 管理工具 v4.2 智能换源版
#  新增: Docker镜像源自动切换 | WSL DNS自动修复 | 拉取失败自动重试
#  修复: MySQL启动误判 | 旧版命令自动清理 | Less编译兼容 | apt锁自动释放
#====================================================================================
set -eo pipefail

# ======================= 全局配置 =======================
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
FRONTEND_PORT="80"
GLOBAL_CMD="ktg"

# 国内镜像源
APT_MIRROR="mirrors.aliyun.com"
MAVEN_MIRROR="https://maven.aliyun.com/repository/public"
NPM_MIRROR="https://registry.npmmirror.com"
GITEE_OWNER="kutangguo"

# Docker备用镜像源列表（按优先级排序，自动轮询）
DOCKER_MIRRORS=(
  "https://docker.mirrors.ustc.edu.cn"
  "https://registry.cn-hangzhou.aliyuncs.com"
  "https://hub-mirror.c.163.com"
  "https://docker.mirrors.ustc.edu.cn"
)

# Docker配置
DOCKER_COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
DOCKER_NETWORK="ktg-network"
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
free_apt_lock() {
    if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        warn "检测到apt包锁被占用，正在释放..."
        killall apt apt-get dpkg 2>/dev/null || true
        sleep 1
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
        dpkg --configure -a 2>/dev/null || true
        ok "包锁已释放"
    fi
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_frontend_port() {
    sleep 2
    ss -tlnp | grep "node" | grep -oP ':\K[0-9]+' | head -1
}

# 检测Docker Compose命令
docker_compose_cmd() {
    if cmd_exists "docker-compose"; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo ""
    fi
}

# 检测是否为WSL环境
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# 修复WSL DNS解析异常（解决lame referral核心问题）
fix_wsl_dns() {
    if ! is_wsl; then
        return 0
    fi

    step "修复WSL DNS解析异常"
    # 备份原配置
    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true

    # 写入公共DNS
    tee /etc/resolv.conf > /dev/null << 'EOF'
nameserver 223.5.5.5
nameserver 114.114.114.114
nameserver 8.8.8.8
EOF

    # 禁止WSL自动覆盖DNS
    if [ ! -f /etc/wsl.conf ] || ! grep -q "generateResolvConf" /etc/wsl.conf; then
        tee -a /etc/wsl.conf > /dev/null << 'EOF'
[network]
generateResolvConf = false
EOF
    fi

    ok "WSL DNS已修复"
}

# 测试Docker镜像源是否可用
test_mirror() {
    local mirror="$1"
    # 配置临时镜像源
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["$mirror"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "3"}
}
EOF
    systemctl daemon-reload
    systemctl restart docker 2>/dev/null || true
    sleep 2

    # 测试拉取轻量镜像
    if docker pull hello-world:latest >/dev/null 2>&1; then
        docker rmi hello-world:latest >/dev/null 2>&1 || true
        return 0
    else
        return 1
    fi
}

# 自动切换可用Docker镜像源
auto_switch_docker_mirror() {
    step "自动检测最优Docker镜像源"
    local success_mirror=""

    for mirror in "${DOCKER_MIRRORS[@]}"; do
        info "测试镜像源: $mirror"
        if test_mirror "$mirror"; then
            success_mirror="$mirror"
            break
        else
            warn "镜像源不可用，切换下一个..."
        fi
    done

    if [ -n "$success_mirror" ]; then
        ok "当前使用镜像源: $success_mirror"
        return 0
    else
        warn "所有备用镜像源均不可用，使用官方源"
        # 清空镜像源配置
        cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "3"}
}
EOF
        systemctl daemon-reload
        systemctl restart docker 2>/dev/null || true
        return 1
    fi
}

#====================================================================================
# 1. 系统环境初始化
#====================================================================================
env_init() {
    step "初始化系统运行环境"
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 sudo 运行此脚本"
        exit 1
    fi

    free_apt_lock
    fix_wsl_dns

    info "替换软件源为阿里云镜像"
    sed -i "s/ports.ubuntu.com/$APT_MIRROR/g" /etc/apt/sources.list 2>/dev/null || true
    sed -i "s/security.ubuntu.com/$APT_MIRROR/g" /etc/apt/sources.list 2>/dev/null || true
    apt update -y 2>/dev/null || apt update -y

    info "安装基础依赖包"
    apt install -y curl wget git unzip ca-certificates gnupg lsb-release net-tools iproute2
    apt install -y openjdk-8-jdk-headless maven
    java -version 2>&1 | head -1

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

    # 安装Node.js 16
    if ! cmd_exists node || ! node -v 2>/dev/null | grep -q '^v16'; then
        info "安装Node.js 16"
        curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
        apt install -y nodejs
    fi
    node -v

    grep -q "nofile 65536" /etc/security/limits.conf || cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
EOF
    ok "系统环境初始化完成"
}

#====================================================================================
# 2. Docker环境安装
#====================================================================================
install_docker() {
    if cmd_exists docker && [ -n "$(docker_compose_cmd)" ]; then
        info "Docker环境已存在"
        # 已有环境也执行DNS修复和镜像源检测
        fix_wsl_dns
        auto_switch_docker_mirror
        return 0
    fi

    step "安装Docker环境"
    free_apt_lock
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    if [ -z "$(docker_compose_cmd)" ]; then
        apt install -y docker-compose
    fi

    systemctl enable docker
    systemctl start docker

    # 安装完成后自动修复DNS+切换最优镜像源
    fix_wsl_dns
    auto_switch_docker_mirror

    ok "Docker环境安装完成"
}

#====================================================================================
# 3. 源码下载
#====================================================================================
pull_source() {
    step "下载项目源码"
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

    if [ ! -d "$BACKEND_DIR" ]; then
        info "下载后端源码..."
        wget -q --show-progress --tries=3 "https://gitee.com/${GITEE_OWNER}/ktg-mes/repository/archive/master.zip" -O /tmp/be.zip
        unzip -q /tmp/be.zip -d /tmp/
        mv /tmp/ktg-mes-master "$BACKEND_DIR"
    fi

    if [ ! -d "$FRONTEND_DIR" ]; then
        info "下载前端源码..."
        wget -q --show-progress --tries=3 "https://gitee.com/${GITEE_OWNER}/ktg-mes-ui/repository/archive/master.zip" -O /tmp/fe.zip
        unzip -q /tmp/fe.zip -d /tmp/
        mv /tmp/ktg-mes-ui-master "$FRONTEND_DIR"
    fi
    ok "源码下载完成"
}

#====================================================================================
# 4. 本地部署模式
#====================================================================================
start_db_local() {
    step "启动数据库容器"

    if ! docker ps -q --filter "name=^${MYSQL_CONTAINER}$" | grep -q .; then
        docker rm -f "$MYSQL_CONTAINER" 2>/dev/null || true
        docker run -d --name "$MYSQL_CONTAINER" \
            -p ${MYSQL_PORT}:3306 \
            -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" \
            -e MYSQL_DATABASE="$MYSQL_DB" \
            --restart=always "$MYSQL_IMAGE" \
            --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --default-time-zone='+8:00'
        info "MySQL容器已创建，等待启动..."
    else
        info "MySQL容器已在运行"
    fi

    # 健康检查（修复误判）
    for i in $(seq 1 60); do
        docker exec "$MYSQL_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_ROOT_PWD" --silent >/dev/null 2>&1 && break
        sleep 2
    done
    sleep 3

    if docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" >/dev/null 2>&1; then
        ok "MySQL启动成功，端口 $MYSQL_PORT"
    else
        err "MySQL启动失败"
        exit 1
    fi

    if ! docker ps -q --filter "name=^${REDIS_CONTAINER}$" | grep -q .; then
        docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
        docker run -d --name "$REDIS_CONTAINER" \
            -p ${REDIS_PORT}:6379 --restart=always "$REDIS_IMAGE" \
            redis-server --requirepass "$REDIS_PWD"
        info "Redis容器已创建"
        sleep 3
    fi

    if docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" ping >/dev/null 2>&1; then
        ok "Redis启动成功，端口 $REDIS_PORT"
    else
        err "Redis启动失败"
        exit 1
    fi
    ok "数据库服务运行正常"
}

import_db_local() {
    step "导入数据库脚本"
    local SQL_FILE
    SQL_FILE=$(find "$BACKEND_DIR/doc" "$BACKEND_DIR/sql" -type f \( -name "*.sql.gz" -o -name "*.sql" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [ -z "$SQL_FILE" ]; then
        warn "未找到SQL文件，跳过导入"
        return 0
    fi

    info "使用数据库文件: $SQL_FILE"
    if [[ "$SQL_FILE" == *.gz ]]; then
        gunzip -c "$SQL_FILE" | docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB"
    else
        docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" "$MYSQL_DB" < "$SQL_FILE"
    fi
    ok "数据库导入完成"
}

patch_config_local() {
    step "更新项目配置文件"
    local RES_DIR="$BACKEND_DIR/ktg-admin/src/main/resources"
    local DRUID_CONF="$RES_DIR/application-druid.yml"
    local APP_CONF="$RES_DIR/application.yml"
    local VUE_CONF="$FRONTEND_DIR/vue.config.js"

    if [ -f "$DRUID_CONF" ]; then
        cp "$DRUID_CONF" "${DRUID_CONF}.bak"
        sed -i "s|your_username|root|g" "$DRUID_CONF"
        sed -i "s|your_password|$MYSQL_ROOT_PWD|g" "$DRUID_CONF"
        sed -i "s|jdbc:mysql://[^:]*:[0-9]*/|jdbc:mysql://127.0.0.1:${MYSQL_PORT}/|g" "$DRUID_CONF"
        ok "数据库连接配置已更新"
    fi

    if [ -f "$APP_CONF" ]; then
        cp "$APP_CONF" "${APP_CONF}.bak"
        sed -i "s|port: [0-9]*|port: $BACKEND_PORT|" "$APP_CONF"
        ok "后端端口配置已更新"
    fi

    if [ -f "$VUE_CONF" ]; then
        sed -i "s|localhost:[0-9]*|localhost:$BACKEND_PORT|g" "$VUE_CONF"
        ok "前端代理配置已更新"
    fi
}

build_backend_local() {
    step "编译后端项目"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" >/dev/null 2>&1 || { err "MySQL连接失败"; exit 1; }
    docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_PWD" ping >/dev/null 2>&1 || { err "Redis连接失败"; exit 1; }
    ok "数据库预检通过"

    cd "$BACKEND_DIR"
    export MAVEN_OPTS="-Xms512m -Xmx4g"
    info "开始编译（首次编译耗时较长，请耐心等待）..."
    mvn clean install -DskipTests -q

    local JAR_FILE
    JAR_FILE=$(find ktg-admin/target -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -1)
    if [ -z "$JAR_FILE" ]; then
        err "编译失败，未找到jar包"
        exit 1
    fi

    pkill -f ktg-admin.jar 2>/dev/null || true
    sleep 1

    nohup java -jar "$JAR_FILE" > "$WORK_DIR/backend.log" 2>&1 &
    echo $! > "$WORK_DIR/backend.pid"
    info "后端进程已启动，等待端口就绪..."

    local ready=0
    for i in $(seq 1 60); do
        curl -s "http://127.0.0.1:$BACKEND_PORT" >/dev/null 2>&1 && { ready=1; break; }
        sleep 2
    done

    if [ "$ready" -eq 1 ]; then
        ok "后端启动成功，端口 $BACKEND_PORT"
    else
        err "后端启动失败，详见日志"
        exit 1
    fi
}

start_frontend_local() {
    step "启动前端服务"
    cd "$FRONTEND_DIR"

    npm config set registry "$NPM_MIRROR"
    info "安装前端依赖..."
    npm install --legacy-peer-deps 2>&1 | tail -5

    info "安装兼容版Less编译器"
    npm install less@3.13.1 less-loader@6.2.0 --legacy-peer-deps --save-dev 2>/dev/null || true

    pkill -f "npm run dev" 2>/dev/null || true
    pkill -f webpack-dev-server 2>/dev/null || true
    sleep 1

    nohup npm run dev > "$WORK_DIR/frontend.log" 2>&1 &
    echo $! > "$WORK_DIR/frontend.pid"
    info "前端服务启动中，等待端口就绪..."

    local fe_port=""
    for i in $(seq 1 40); do
        fe_port=$(get_frontend_port)
        [ -n "$fe_port" ] && break
        sleep 2
    done

    if [ -n "$fe_port" ]; then
        ok "前端启动成功，端口 $fe_port"
    else
        warn "未检测到前端端口，可手动查看日志确认"
    fi
    echo "$fe_port" > "$WORK_DIR/frontend.port"
}

register_global_cmd() {
    step "注册全局管理命令"
    info "清理旧版全局命令残留..."
    rm -f /usr/local/bin/ktg-mes /usr/local/bin/ktg

    local SELF
    SELF="$(readlink -f "$0")"
    cp "$SELF" /usr/local/bin/$GLOBAL_CMD
    chmod +x /usr/local/bin/$GLOBAL_CMD
    ok "全局命令注册完成，任意目录输入 $GLOBAL_CMD 即可打开管理菜单"
}

install_local() {
    echo -e "${PURPLE}############ 开始本地模式安装 KTG-MES v4.2 ############${R}"
    env_init
    install_docker
    start_db_local
    pull_source
    import_db_local
    patch_config_local
    build_backend_local
    start_frontend_local
    register_global_cmd

    local fe_port local_ip
    fe_port=$(cat "$WORK_DIR/frontend.port" 2>/dev/null || echo "未检测到")
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
# 5. Docker全容器化部署模式（智能换源版）
#====================================================================================
generate_docker_files() {
    step "生成Docker配置文件"
    mkdir -p "$WORK_DIR"

    # 1. docker-compose.yml
    cat > "$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

networks:
  $DOCKER_NETWORK:
    driver: bridge

volumes:
  ktg-mysql-data:
  ktg-redis-data:

services:
  ktg-mysql:
    image: $MYSQL_IMAGE
    container_name: $MYSQL_CONTAINER
    restart: always
    ports:
      - "$MYSQL_PORT:3306"
    environment:
      MYSQL_ROOT_PASSWORD: "$MYSQL_ROOT_PWD"
      MYSQL_DATABASE: "$MYSQL_DB"
      TZ: "Asia/Shanghai"
    command:
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --default-time-zone=+8:00
    volumes:
      - ktg-mysql-data:/var/lib/mysql
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-uroot", "-p$MYSQL_ROOT_PWD"]
      interval: 5s
      timeout: 3s
      retries: 12

  ktg-redis:
    image: $REDIS_IMAGE
    container_name: $REDIS_CONTAINER
    restart: always
    ports:
      - "$REDIS_PORT:6379"
    command: redis-server --requirepass $REDIS_PWD --appendonly yes
    volumes:
      - ktg-redis-data:/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_PWD", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

  ktg-backend:
    build:
      context: ./ktg-mes
      dockerfile: Dockerfile
    container_name: ktg-backend
    restart: always
    ports:
      - "$BACKEND_PORT:8080"
    environment:
      TZ: "Asia/Shanghai"
      SPRING_DATASOURCE_URL: "jdbc:mysql://ktg-mysql:3306/$MYSQL_DB?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai"
      SPRING_DATASOURCE_USERNAME: "root"
      SPRING_DATASOURCE_PASSWORD: "$MYSQL_ROOT_PWD"
      SPRING_REDIS_HOST: "ktg-redis"
      SPRING_REDIS_PORT: "6379"
      SPRING_REDIS_PASSWORD: "$REDIS_PWD"
    depends_on:
      ktg-mysql:
        condition: service_healthy
      ktg-redis:
        condition: service_healthy
    networks:
      - $DOCKER_NETWORK

  ktg-frontend:
    build:
      context: ./ktg-mes-ui
      dockerfile: Dockerfile
    container_name: ktg-frontend
    restart: always
    ports:
      - "$FRONTEND_PORT:80"
    depends_on:
      - ktg-backend
    networks:
      - $DOCKER_NETWORK
EOF

    # 2. 后端Dockerfile
    cat > "$BACKEND_DIR/Dockerfile" << 'EOF'
FROM maven:3.8.6-openjdk-8 AS builder
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN sed -i 's/central/aliyun/g' /usr/share/maven/conf/settings.xml && \
    mvn clean install -DskipTests -q

FROM openjdk:8-jre-slim
WORKDIR /app
COPY --from=builder /app/ktg-admin/target/*.jar app.jar
ENV TZ=Asia/Shanghai
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "-Xms512m", "-Xmx2g", "app.jar"]
EOF

    # 3. 前端Dockerfile
    cat > "$FRONTEND_DIR/Dockerfile" << 'EOF'
FROM node:16-alpine AS builder
WORKDIR /app
COPY package.json .
RUN npm config set registry https://registry.npmmirror.com && \
    npm install --legacy-peer-deps
COPY . .
RUN npm install less@3.13.1 less-loader@6.2.0 --legacy-peer-deps --save-dev
RUN npm run build

FROM nginx:alpine
ENV TZ=Asia/Shanghai
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF

    # 4. 前端Nginx配置
    cat > "$FRONTEND_DIR/nginx.conf" << 'EOF'
server {
    listen 80;
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://ktg-backend:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

    ok "所有Docker配置文件生成完成"
}

deploy_docker() {
    echo -e "${PURPLE}############ 开始Docker全容器化部署 KTG-MES v4.2 ############${R}"
    env_init
    install_docker
    pull_source

    # 停止本地服务避免端口冲突
    warn "停止本地服务，避免端口冲突..."
    pkill -f ktg-admin.jar 2>/dev/null || true
    pkill -f "npm run dev" 2>/dev/null || true
    docker rm -f ktg-mysql ktg-redis 2>/dev/null || true

    generate_docker_files

    step "构建并启动所有容器"
    cd "$WORK_DIR"
    local DC
    DC=$(docker_compose_cmd)

    # 第一次构建尝试
    if $DC up -d --build 2>&1; then
        build_success=1
    else
        build_success=0
        warn "首次构建失败，自动切换镜像源重试..."
        # 自动切换下一个镜像源
        auto_switch_docker_mirror
        info "使用新镜像源重新构建..."
        # 清理构建缓存重试
        $DC build --no-cache 2>&1 && build_success=1 || build_success=0
    fi

    if [ "$build_success" -eq 0 ]; then
        err "构建失败，请检查网络或手动执行 docker compose build 查看详情"
        read -p "按回车继续..."
        return 1
    fi

    # 等待服务就绪
    info "等待服务启动就绪..."
    sleep 15

    local ready=0
    for i in $(seq 1 20); do
        if curl -s "http://127.0.0.1:$FRONTEND_PORT" >/dev/null 2>&1 && \
           curl -s "http://127.0.0.1:$BACKEND_PORT" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 3
    done

    register_global_cmd

    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')

    echo ""
    if [ "$ready" -eq 1 ]; then
        echo -e "${GREEN}############ 部署完成 ############${R}"
        echo -e "  默认账号: ${YELLOW}admin / admin123${R}"
        echo -e "  前端地址: http://localhost:$FRONTEND_PORT"
        echo -e "  后端地址: http://localhost:$BACKEND_PORT"
        echo -e "  内网访问: http://$local_ip:$FRONTEND_PORT"
        echo ""
        echo -e "  集群管理命令:"
        echo -e "  查看状态: $DC ps"
        echo -e "  查看日志: $DC logs -f [服务名]"
        echo -e "  停止服务: $DC stop"
        echo -e "  启动服务: $DC start"
    else
        warn "部署已执行，服务启动中，请稍候访问"
        echo -e "  可执行命令查看状态: $DC ps"
    fi
}

#====================================================================================
# 6. 一键彻底清理还原
#====================================================================================
full_cleanup() {
    clear
    echo -e "${RED}############################################################${R}"
    echo -e "${RED}#                    【危险操作】彻底清理还原                    #${R}"
    echo -e "${RED}############################################################${R}"
    echo ""
    echo -e "  即将执行以下操作："
    echo -e "  1. 停止所有本地服务进程（后端/前端）"
    echo -e "  2. 删除所有相关Docker容器"
    echo -e "  3. 删除整个项目目录（源码/编译产物/日志/配置）"
    echo -e "  4. 移除全局命令 ktg / ktg-mes"
    echo ""
    echo -e "${YELLOW}  可选操作（需二次确认）：${R}"
    echo -e "  A. 删除Docker数据卷（MySQL/Redis数据永久丢失）"
    echo -e "  B. 卸载Docker环境"
    echo -e "  C. 卸载Java/Node/Maven等系统依赖"
    echo ""
    echo -e "${RED}  此操作不可逆！请确认已备份重要数据！${R}"
    echo ""

    read -p "输入 YES 确认开始彻底清理: " confirm
    if [ "$confirm" != "YES" ]; then
        info "已取消操作"
        read -p "按回车返回菜单..."
        return 0
    fi

    step "停止所有本地服务"
    pkill -f ktg-admin.jar 2>/dev/null || true
    pkill -f "npm run dev" 2>/dev/null || true
    pkill -f webpack-dev-server 2>/dev/null || true
    ok "本地进程已停止"

    step "删除所有相关Docker容器"
    docker rm -f ktg-mysql ktg-redis ktg-backend ktg-frontend 2>/dev/null || true
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        local DC
        DC=$(docker_compose_cmd)
        $DC down -v 2>/dev/null || true
    fi
    ok "所有容器已删除"

    # 二次确认：删除数据卷
    echo ""
    read -p "是否删除数据库数据卷？（输入 DELETE 确认永久删除数据）: " del_data
    if [ "$del_data" == "DELETE" ]; then
        step "删除Docker数据卷"
        docker volume rm ktg-mysql-data ktg-redis-data 2>/dev/null || true
        docker volume prune -f 2>/dev/null || true
        ok "数据卷已删除，数据库数据已清空"
    else
        info "保留数据库数据卷，数据未删除"
    fi

    step "删除项目目录"
    rm -rf "$WORK_DIR"
    ok "项目文件已全部删除"

    step "移除全局命令"
    rm -f /usr/local/bin/ktg /usr/local/bin/ktg-mes
    ok "全局命令已移除"

    # 三次确认：卸载系统依赖
    echo ""
    read -p "是否卸载Docker环境？（y/N）: " del_docker
    if [ "$del_docker" = "y" ] || [ "$del_docker" = "Y" ]; then
        step "卸载Docker环境"
        apt purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose 2>/dev/null || true
        rm -rf /etc/docker /var/lib/docker
        ok "Docker环境已卸载"
    fi

    echo ""
    read -p "是否卸载Java/Node/Maven等系统依赖？（y/N）: " del_sys
    if [ "$del_sys" = "y" ] || [ "$del_sys" = "Y" ]; then
        step "卸载系统依赖"
        apt purge -y openjdk-8-jdk-headless maven nodejs 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
        ok "系统依赖已卸载"
    fi

    echo ""
    echo -e "${GREEN}############ 清理完成 ############${R}"
    echo -e "  已停止所有服务"
    echo -e "  已删除所有容器"
    echo -e "  已删除项目文件"
    echo -e "  已移除全局命令"
    [ "$del_data" == "DELETE" ] && echo -e "  已清空数据库数据"
    [ "$del_docker" = "y" ] || [ "$del_docker" = "Y" ] && echo -e "  已卸载Docker环境"
    [ "$del_sys" = "y" ] || [ "$del_sys" = "Y" ] && echo -e "  已卸载系统依赖"
    echo ""
    echo -e "  环境已还原至部署前状态"

    read -p "按回车返回菜单..."
}

#====================================================================================
# 7. 运行信息总览
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
    local local_ip fe_port
    local_ip=$(hostname -I | awk '{print $1}')
    fe_port=$(cat "$WORK_DIR/frontend.port" 2>/dev/null || echo "未启动/未检测")
    echo -e "  后端服务: http://localhost:${BACKEND_PORT}"
    echo -e "  前端服务: http://localhost:${fe_port}"
    echo -e "  内网访问: http://${local_ip}:${fe_port}"
    echo ""

    echo -e "  ${YELLOW}【服务运行状态】${R}"
    if docker ps -q --filter "name=^${MYSQL_CONTAINER}$" | grep -q .; then
        echo -e "  MySQL 容器: ${GREEN}运行中${R}"
    else
        echo -e "  MySQL 容器: ${RED}已停止${R}"
    fi

    if docker ps -q --filter "name=^${REDIS_CONTAINER}$" | grep -q .; then
        echo -e "  Redis 容器: ${GREEN}运行中${R}"
    else
        echo -e "  Redis 容器: ${RED}已停止${R}"
    fi

    if pgrep -f ktg-admin.jar >/dev/null 2>&1; then
        echo -e "  后端服务(本地): ${GREEN}运行中${R}"
    else
        echo -e "  后端服务(本地): ${RED}已停止${R}"
    fi

    if pgrep -f "webpack-dev-server" >/dev/null 2>&1 || pgrep -f "npm run dev" >/dev/null 2>&1; then
        echo -e "  前端服务(本地): ${GREEN}运行中${R}"
    else
        echo -e "  前端服务(本地): ${RED}已停止${R}"
    fi

    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        local DC
        DC=$(docker_compose_cmd)
        if $DC ps -q --filter "status=running" 2>/dev/null | grep -q .; then
            echo -e "  Docker集群: ${GREEN}运行中${R}"
        else
            echo -e "  Docker集群: ${RED}已停止${R}"
        fi
    fi
    echo ""
    read -p "按回车返回菜单..."
}

#====================================================================================
# 主菜单
#====================================================================================
menu() {
    while true; do
        clear
        echo -e "${CYAN}############################################################${R}"
        echo -e "${CYAN}#${R}${GREEN}          KTG-MES 苦糖果MES 管理工具 v4.2 智能换源版            ${R}${CYAN}#${R}"
        echo -e "${CYAN}############################################################${R}"
        echo ""
        echo -e "  ${YELLOW}[1]${R}  本地模式完整安装"
        echo -e "  ${YELLOW}[2]${R}  启动本地服务"
        echo -e "  ${YELLOW}[3]${R}  停止本地服务"
        echo -e "  ${YELLOW}[4]${R}  查看后端日志"
        echo -e "  ${YELLOW}[5]${R}  卸载本地服务"
        echo -e "  ${YELLOW}[6]${R}  查看运行信息"
        echo -e "  ${YELLOW}[7]${R}  Docker全容器化部署"
        echo -e "  ${YELLOW}[8]${R}  一键彻底清理还原"
        echo -e "  ${YELLOW}[0]${R}  退出"
        echo ""
        read -p "请输入选项 [0-8]: " opt

        case "$opt" in
            1) install_local; read -p "按回车继续..." ;;
            2) start_db_local && build_backend_local && start_frontend_local; read -p "按回车继续..." ;;
            3)
                pkill -f ktg-admin.jar 2>/dev/null || true
                pkill -f "npm run dev" 2>/dev/null || true
                docker stop ktg-mysql ktg-redis 2>/dev/null || true
                ok "本地服务已停止"
                read -p "按回车继续..."
                ;;
            4)
                echo "=== 后端日志（按Ctrl+C退出） ==="
                tail -f "$WORK_DIR/backend.log"
                ;;
            5)
                read -p "确认卸载本地服务? (y/N): " yn
                [ "$yn" != "y" ] && { info "已取消"; read -p "按回车继续..."; continue; }
                pkill -f ktg-admin.jar 2>/dev/null || true
                pkill -f "npm run dev" 2>/dev/null || true
                docker rm -f ktg-mysql ktg-redis 2>/dev/null || true
                rm -rf "$WORK_DIR"
                rm -f /usr/local/bin/$GLOBAL_CMD /usr/local/bin/ktg-mes
                ok "卸载完成"
                read -p "按回车继续..."
                ;;
            6) show_info ;;
            7) deploy_docker; read -p "按回车继续..." ;;
            8) full_cleanup ;;
            0) echo "再见"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# 入口
[ "${1:-}" == "install" ] && install_local || menu
