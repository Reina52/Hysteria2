#!/bin/bash

# Hysteria 2 完整一键部署脚本
# 适用于 Debian/Ubuntu/CentOS
# 使用方法: bash 一键部署Hysteria2.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════╗
║                                           ║
║      Hysteria 2 一键部署脚本              ║
║      速度最快的代理方案                   ║
║                                           ║
╚═══════════════════════════════════════════╝
EOF
echo -e "${NC}"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 请使用 root 用户运行此脚本${NC}"
   echo "使用方法: sudo bash $0"
   exit 1
fi

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo -e "${RED}无法检测系统类型${NC}"
    exit 1
fi

echo -e "${BLUE}检测到系统: $OS $VERSION${NC}"
echo ""

# 生成端口
PORT=443

echo -e "${YELLOW}=========================================="
echo "开始安装 Hysteria 2"
echo "==========================================${NC}"
echo ""

# 步骤 1: 安装依赖
echo -e "${CYAN}[1/9] 安装系统依赖...${NC}"
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    apt update -qq
    apt install -y curl wget openssl qrencode iproute2 > /dev/null 2>&1
elif [ "$OS" = "centos" ]; then
    yum install -y curl wget openssl qrencode iproute > /dev/null 2>&1
fi
echo -e "${GREEN}✓ 依赖安装完成${NC}"
echo ""

# 步骤 2: 检测可用的 IPv4/IPv6 地址
echo -e "${CYAN}[2/9] 检测 IPv4/IPv6 网络...${NC}"
LOCAL_IPV4=""
LOCAL_IPV6=""
SERVER_IPV4=""
SERVER_IPV6=""

if command -v ip &> /dev/null; then
    LOCAL_IPV4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, address, "/"); print address[1]; exit}')
    LOCAL_IPV6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    [[ -z "$LOCAL_IPV6" ]] && LOCAL_IPV6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{split($4, address, "/"); print address[1]; exit}')
fi

SERVER_IPV4=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
SERVER_IPV6=$(curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null || true)

[[ -z "$SERVER_IPV4" ]] && SERVER_IPV4="$LOCAL_IPV4"
[[ -z "$SERVER_IPV6" ]] && SERVER_IPV6="$LOCAL_IPV6"
[[ -n "$SERVER_IPV6" && -z "$LOCAL_IPV6" ]] && SERVER_IPV6=""

if [[ -z "$SERVER_IPV4" && -z "$SERVER_IPV6" ]]; then
    echo -e "${RED}错误: 未检测到可用的 IPv4 或 IPv6 地址${NC}"
    exit 1
fi

echo -e "${CYAN}检测到网络地址:${NC}"
[[ -n "$SERVER_IPV4" ]] && echo -e "${GREEN}✓ IPv4: $SERVER_IPV4${NC}"
[[ -n "$SERVER_IPV6" ]] && echo -e "${GREEN}✓ IPv6: $SERVER_IPV6${NC}"
echo ""

# 步骤 3: 安装 Hysteria 2
echo -e "${CYAN}[3/9] 安装 Hysteria 2...${NC}"
bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Hysteria 2 安装成功${NC}"
else
    echo -e "${RED}✗ Hysteria 2 安装失败${NC}"
    exit 1
fi
echo ""

# 步骤 4: 生成证书
echo -e "${CYAN}[4/9] 生成 TLS 证书...${NC}"
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=www.bing.com" \
  -days 36500 > /dev/null 2>&1
echo -e "${GREEN}✓ 证书生成完成${NC}"
echo ""

# 步骤 5: 创建 IPv4/IPv6 配置和服务
echo -e "${CYAN}[5/9] 创建 IPv4/IPv6 配置和服务...${NC}"

create_instance() {
    local instance="$1"
    local listen="$2"
    local password="$3"

    cat > "/etc/hysteria/config-${instance}.yaml" <<EOF
listen: ${listen}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: true
speedTest: false
disableUDP: false
udpIdleTimeout: 60s
EOF

    cat > "/etc/systemd/system/hysteria-server-${instance}.service" <<EOF
[Unit]
Description=Hysteria Server (${instance})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config-${instance}.yaml
WorkingDirectory=/var/lib/hysteria
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    chown hysteria:hysteria "/etc/hysteria/config-${instance}.yaml"
    chmod 600 "/etc/hysteria/config-${instance}.yaml"
}

PASSWORD_IPV4=""
PASSWORD_IPV6=""

if [[ -n "$SERVER_IPV4" ]]; then
    PASSWORD_IPV4=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-20)
    create_instance "ipv4" "0.0.0.0:${PORT}" "$PASSWORD_IPV4"
fi

if [[ -n "$SERVER_IPV6" ]]; then
    PASSWORD_IPV6=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-20)
    create_instance "ipv6" "[${LOCAL_IPV6}]:${PORT}" "$PASSWORD_IPV6"
fi

systemctl disable --now hysteria-server.service hysteria-server-ipv4.service hysteria-server-ipv6.service > /dev/null 2>&1 || true
systemctl daemon-reload
chown hysteria:hysteria /etc/hysteria/server.key
chown hysteria:hysteria /etc/hysteria/server.crt
chmod 600 /etc/hysteria/server.key
echo -e "${GREEN}✓ IPv4/IPv6 配置文件和服务创建完成${NC}"
echo ""

# 步骤 6: 系统优化
echo -e "${CYAN}[6/9] 优化系统参数...${NC}"

# 开启 BBR
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi

# UDP 和网络优化
cat >> /etc/sysctl.conf <<EOF

# Hysteria 2 优化
net.core.rmem_max=2500000
net.core.wmem_max=2500000
net.core.rmem_default=2500000
net.core.wmem_default=2500000
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.ip_local_port_range=10000 65000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
fs.file-max=51200
EOF

sysctl -p > /dev/null 2>&1

# 文件描述符限制
cat >> /etc/security/limits.conf <<EOF

# Hysteria 2 优化
* soft nofile 51200
* hard nofile 51200
* soft nproc 51200
* hard nproc 51200
EOF

echo -e "${GREEN}✓ 系统优化完成${NC}"
echo ""

# 步骤 7: 配置防火墙
echo -e "${CYAN}[7/9] 配置防火墙...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow $PORT/udp > /dev/null 2>&1
    echo -e "${GREEN}✓ UFW 防火墙已配置${NC}"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=$PORT/udp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    echo -e "${GREEN}✓ Firewalld 防火墙已配置${NC}"
elif command -v iptables &> /dev/null; then
    iptables -A INPUT -p udp --dport $PORT -j ACCEPT
    echo -e "${GREEN}✓ iptables 防火墙已配置${NC}"
else
    echo -e "${YELLOW}⚠ 未检测到防火墙，请手动开放 UDP $PORT 端口${NC}"
fi
echo ""

# 步骤 8: 启动服务
echo -e "${CYAN}[8/9] 启动 Hysteria 服务...${NC}"
systemctl daemon-reload
SERVICES_STARTED=0
SERVICES_FAILED=0

start_instance() {
    local instance="$1"
    local service="hysteria-server-${instance}"

    systemctl enable "$service" > /dev/null 2>&1
    systemctl restart "$service"
    sleep 1

    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}✓ $instance 服务启动成功${NC}"
        SERVICES_STARTED=$((SERVICES_STARTED + 1))
    else
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
        echo -e "${RED}✗ $instance 服务启动失败，查看日志: journalctl -u $service -n 20 --no-pager${NC}"
        journalctl -u "$service" -n 20 --no-pager
    fi
}

[[ -n "$SERVER_IPV4" ]] && start_instance "ipv4"
[[ -n "$SERVER_IPV6" ]] && start_instance "ipv6"

if [ "$SERVICES_STARTED" -eq 0 ] || [ "$SERVICES_FAILED" -gt 0 ]; then
    echo -e "${RED}✗ 至少一个 Hysteria 服务启动失败，请检查上面的日志${NC}"
    exit 1
fi
echo ""

# 步骤 9: 生成客户端配置
echo -e "${CYAN}[9/9] 生成客户端配置...${NC}"

write_client_config() {
    local instance="$1"
    local address="$2"
    local password="$3"

    cat > "/root/hysteria-client-${instance}.yaml" <<EOF
server: ${address}:${PORT}

auth: ${password}

tls:
  sni: www.bing.com
  insecure: true

bandwidth:
  up: 100 mbps
  down: 500 mbps

fastOpen: true
lazy: false

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
EOF
}

if [[ -n "$SERVER_IPV4" ]]; then
    SHARE_LINK_IPV4="hysteria2://$PASSWORD_IPV4@$SERVER_IPV4:$PORT/?insecure=1&sni=www.bing.com#Hysteria2-IPv4"
    write_client_config "ipv4" "$SERVER_IPV4" "$PASSWORD_IPV4"
fi

if [[ -n "$SERVER_IPV6" ]]; then
    SHARE_LINK_IPV6="hysteria2://$PASSWORD_IPV6@[$SERVER_IPV6]:$PORT/?insecure=1&sni=www.bing.com#Hysteria2-IPv6"
    write_client_config "ipv6" "[$SERVER_IPV6]" "$PASSWORD_IPV6"
fi

echo -e "${GREEN}✓ 客户端配置已生成${NC}"
echo ""

# 显示安装结果
clear
echo -e "${GREEN}"
cat << "EOF"
╔═══════════════════════════════════════════╗
║                                           ║
║         🎉 安装成功！                     ║
║                                           ║
╚═══════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${CYAN}=========================================="
echo "  服务器信息"
echo "==========================================${NC}"
print_instance_result() {
    local label="$1"
    local instance="${label,,}"
    local address="$2"
    local password="$3"
    local link="$4"

    echo -e "${CYAN}=========================================="
    echo "  $label"
    echo "==========================================${NC}"
    echo -e "${YELLOW}服务器地址:${NC} $address"
    echo -e "${YELLOW}端口:${NC} $PORT"
    echo -e "${YELLOW}密码:${NC} $password"
    echo -e "${YELLOW}协议:${NC} UDP"
    echo -e "${YELLOW}服务:${NC} hysteria-server-$instance"
    echo -e "${YELLOW}客户端配置:${NC} /root/hysteria-client-$instance.yaml"
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    echo -e "${GREEN}$link${NC}"
    echo ""
    echo -e "${YELLOW}二维码（手机扫描）:${NC}"
    qrencode -t ANSIUTF8 "$link"
    echo ""
}

if [[ -n "$SERVER_IPV4" ]]; then
    print_instance_result "IPv4" "$SERVER_IPV4" "$PASSWORD_IPV4" "$SHARE_LINK_IPV4"
fi

if [[ -n "$SERVER_IPV6" ]]; then
    print_instance_result "IPv6" "[$SERVER_IPV6]" "$PASSWORD_IPV6" "$SHARE_LINK_IPV6"
fi

echo -e "${CYAN}=========================================="
echo "  客户端下载"
echo "==========================================${NC}"
echo -e "${YELLOW}Windows/Mac/Linux:${NC}"
echo "  https://github.com/apernet/hysteria/releases"
echo ""
echo -e "${YELLOW}Android:${NC}"
echo "  SagerNet - https://github.com/SagerNet/SagerNet/releases"
echo ""
echo -e "${YELLOW}iOS:${NC}"
echo "  Shadowrocket (App Store 美区)"
echo ""

echo -e "${CYAN}=========================================="
echo "  配置文件位置"
echo "==========================================${NC}"
echo -e "${YELLOW}IPv4 服务器配置:${NC} /etc/hysteria/config-ipv4.yaml"
echo -e "${YELLOW}IPv6 服务器配置:${NC} /etc/hysteria/config-ipv6.yaml"
echo -e "${YELLOW}IPv4 客户端配置:${NC} /root/hysteria-client-ipv4.yaml"
echo -e "${YELLOW}IPv6 客户端配置:${NC} /root/hysteria-client-ipv6.yaml"
echo ""

echo -e "${CYAN}=========================================="
echo "  管理命令"
echo "==========================================${NC}"
echo -e "${YELLOW}启动 IPv4:${NC} systemctl start hysteria-server-ipv4"
echo -e "${YELLOW}启动 IPv6:${NC} systemctl start hysteria-server-ipv6"
echo -e "${YELLOW}停止服务:${NC} systemctl stop hysteria-server-ipv4 hysteria-server-ipv6"
echo -e "${YELLOW}重启服务:${NC} systemctl restart hysteria-server-ipv4 hysteria-server-ipv6"
echo -e "${YELLOW}查看状态:${NC} systemctl status hysteria-server-ipv4 hysteria-server-ipv6"
echo -e "${YELLOW}查看日志:${NC} journalctl -u hysteria-server-ipv4 -u hysteria-server-ipv6 -f"
echo ""

echo -e "${CYAN}=========================================="
echo "  优化信息"
echo "==========================================${NC}"
echo -e "${GREEN}✓${NC} BBR 拥塞控制已启用"
echo -e "${GREEN}✓${NC} UDP 缓冲区已优化"
echo -e "${GREEN}✓${NC} QUIC 参数已优化"
echo -e "${GREEN}✓${NC} 系统参数已优化"
echo -e "${GREEN}✓${NC} 防火墙已配置"
echo ""

echo -e "${CYAN}=========================================="
echo "  性能验证"
echo "==========================================${NC}"
BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$BBR_STATUS" = "bbr" ]; then
    echo -e "${GREEN}✓${NC} BBR: 已启用"
else
    echo -e "${YELLOW}⚠${NC} BBR: 未启用"
fi

if [[ -n "$SERVER_IPV4" ]]; then
    systemctl is-active --quiet hysteria-server-ipv4 && echo -e "${GREEN}✓${NC} IPv4 服务状态: 运行中" || echo -e "${RED}✗${NC} IPv4 服务状态: 未运行"
fi
if [[ -n "$SERVER_IPV6" ]]; then
    systemctl is-active --quiet hysteria-server-ipv6 && echo -e "${GREEN}✓${NC} IPv6 服务状态: 运行中" || echo -e "${RED}✗${NC} IPv6 服务状态: 未运行"
fi
echo ""

echo -e "${CYAN}=========================================="
echo "  下一步"
echo "==========================================${NC}"
echo "1. 复制分享链接到客户端"
echo "2. 或扫描二维码导入配置"
echo "3. 开始使用高速代理"
echo ""

echo -e "${PURPLE}=========================================="
echo "  建议"
echo "==========================================${NC}"
echo "• 定期更新: bash <(curl -fsSL https://get.hy2.sh/)"
echo "• 修改 IPv4 密码: 编辑 /etc/hysteria/config-ipv4.yaml"
echo "• 修改 IPv6 密码: 编辑 /etc/hysteria/config-ipv6.yaml"
echo "• 备份配置: cp /etc/hysteria/config-ipv4.yaml ~/config-ipv4.yaml.bak"
echo "• 监控日志: journalctl -u hysteria-server-ipv4 -u hysteria-server-ipv6 -f"
echo ""

echo -e "${GREEN}=========================================="
echo "  安装完成！享受极速体验！ 🚀"
echo "==========================================${NC}"
echo ""

# 保存信息到文件
cat > /root/hysteria-info.txt <<EOF
========================================
Hysteria 2 配置信息
========================================

ignoreClientBandwidth: true

IPv4 服务器: ${SERVER_IPV4:-未检测到}:$PORT
IPv4 密码: ${PASSWORD_IPV4:-未部署}
IPv4 分享链接:
${SHARE_LINK_IPV4:-未部署}

IPv6 服务器: ${SERVER_IPV6:-未检测到}:$PORT
IPv6 密码: ${PASSWORD_IPV6:-未部署}
IPv6 分享链接:
${SHARE_LINK_IPV6:-未部署}

IPv4 客户端配置文件: /root/hysteria-client-ipv4.yaml
IPv6 客户端配置文件: /root/hysteria-client-ipv6.yaml
IPv4 服务器配置文件: /etc/hysteria/config-ipv4.yaml
IPv6 服务器配置文件: /etc/hysteria/config-ipv6.yaml

管理命令:
systemctl start hysteria-server-ipv4    # 启动 IPv4
systemctl start hysteria-server-ipv6    # 启动 IPv6
systemctl status hysteria-server-ipv4 hysteria-server-ipv6
journalctl -u hysteria-server-ipv4 -u hysteria-server-ipv6 -f

安装时间: $(date)
========================================
EOF

echo -e "${YELLOW}配置信息已保存到: /root/hysteria-info.txt${NC}"
echo ""
