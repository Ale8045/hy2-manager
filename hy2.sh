#!/bin/bash

VERSION="1.3.1"
PROJECT_NAME="HK HY2 Manager"

BASE_DIR="/etc/hysteria"
NODE_DIR="/etc/hysteria/nodes"
CERT_DIR="/etc/hysteria"
SELF_CERT="$CERT_DIR/server.crt"
SELF_KEY="$CERT_DIR/server.key"
SSL_DIR="/etc/hysteria/ssl"
SSL_CERT="$SSL_DIR/server.crt"
SSL_KEY="$SSL_DIR/server.key"
SSL_INFO="$SSL_DIR/ssl.info"
SERVER_IP_FILE="/etc/hysteria/server.ip"

HY2_VERSION="v2.9.2"
HY2_FILE="hysteria-linux-amd64"

mkdir -p "$BASE_DIR" "$NODE_DIR" "$SSL_DIR"

random_pass() {
  openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16
}

get_ip() {
  curl -4 -s ipv4.ip.sb || curl -4 -s ifconfig.me || hostname -I | awk '{print $1}'
}

next_id() {
  if ls "$NODE_DIR"/*.info >/dev/null 2>&1; then
    ls "$NODE_DIR"/*.info | sed 's/.*node-\([0-9]*\).info/\1/' | sort -n | tail -1 | awk '{print $1+1}'
  else
    echo 1
  fi
}

service_name() {
  echo "hysteria-$1.service"
}

config_file() {
  echo "$NODE_DIR/node-$1.yaml"
}

info_file() {
  echo "$NODE_DIR/node-$1.info"
}

expire_file() {
  echo "$NODE_DIR/node-$1.expire"
}

pause() {
  read -p "按回车返回菜单..."
  menu
}

check_port_used() {
  local PORT="$1"
  local EXCLUDE_ID="$2"

  if ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\.)${PORT}$"; then
    return 0
  fi

  if ls "$NODE_DIR"/node-*.yaml >/dev/null 2>&1; then
    for f in "$NODE_DIR"/node-*.yaml; do
      if [ -n "$EXCLUDE_ID" ] && [ "$f" = "$(config_file "$EXCLUDE_ID")" ]; then
        continue
      fi
      if grep -q "^listen: :$PORT$" "$f" 2>/dev/null; then
        return 0
      fi
    done
  fi

  return 1
}

random_port() {
  local PORT
  while true; do
    PORT=$(shuf -i 10000-60000 -n 1)
    if ! check_port_used "$PORT"; then
      echo "$PORT"
      return
    fi
  done
}

choose_port() {
  local INPUT_PORT="$1"
  local EXCLUDE_ID="$2"
  local FINAL_PORT

  if [ -z "$INPUT_PORT" ]; then
    FINAL_PORT=$(random_port)
    echo "$FINAL_PORT"
    return
  fi

  if ! echo "$INPUT_PORT" | grep -Eq '^[0-9]+$'; then
    echo "端口格式错误，自动生成随机端口" >&2
    FINAL_PORT=$(random_port)
    echo "$FINAL_PORT"
    return
  fi

  if [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
    echo "端口范围错误，自动生成随机端口" >&2
    FINAL_PORT=$(random_port)
    echo "$FINAL_PORT"
    return
  fi

  if check_port_used "$INPUT_PORT" "$EXCLUDE_ID"; then
    echo "端口 $INPUT_PORT 已被占用，自动生成随机端口" >&2
    FINAL_PORT=$(random_port)
    echo "$FINAL_PORT"
  else
    echo "$INPUT_PORT"
  fi
}

get_ssl_domain() {
  local DOMAIN=""

  if [ -f "$SSL_INFO" ]; then
    DOMAIN=$(grep "^DOMAIN=" "$SSL_INFO" | cut -d= -f2- | head -1)
  fi

  if [ -z "$DOMAIN" ] && [ -f "$SSL_CERT" ]; then
    DOMAIN=$(openssl x509 -in "$SSL_CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | sed 's/,.*//' | head -1)
  fi

  echo "$DOMAIN"
}

has_ssl_cert() {
  [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ] && [ -s "$SSL_CERT" ] && [ -s "$SSL_KEY" ]
}

node_mode() {
  local ID="$1"
  grep "^模式:" "$(info_file "$ID")" 2>/dev/null | sed 's/^模式: //'
}

node_server() {
  local ID="$1"
  grep "^服务器:" "$(info_file "$ID")" 2>/dev/null | awk '{print $2}'
}

install_hysteria() {
  if command -v hysteria >/dev/null 2>&1; then
    if file "$(command -v hysteria)" 2>/dev/null | grep -q "ELF"; then
      echo "检测到 Hysteria2 已安装，跳过下载"
      hysteria version || true
      return
    else
      echo "检测到旧 hysteria 文件无效，删除后重新安装"
      rm -f "$(command -v hysteria)"
    fi
  fi

  echo "正在安装 Hysteria2..."

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)
      HY2_FILE="hysteria-linux-amd64"
      ;;
    aarch64|arm64)
      HY2_FILE="hysteria-linux-arm64"
      ;;
    armv7l|armv7)
      HY2_FILE="hysteria-linux-armv7"
      ;;
    *)
      echo "不支持的架构: $ARCH"
      exit 1
      ;;
  esac

  # Hysteria 官方 tag 是 app/v2.x.x
  # GitHub 下载链接里这个斜杠必须写成 app%2Fv2.x.x
  HY2_TAG="app%2F${HY2_VERSION}"

  URLS=(
    "https://github.com/apernet/hysteria/releases/download/${HY2_TAG}/${HY2_FILE}"
    "https://gh.llkk.cc/https://github.com/apernet/hysteria/releases/download/${HY2_TAG}/${HY2_FILE}"
    "https://ghproxy.net/https://github.com/apernet/hysteria/releases/download/${HY2_TAG}/${HY2_FILE}"
    "https://gh-proxy.com/https://github.com/apernet/hysteria/releases/download/${HY2_TAG}/${HY2_FILE}"
  )

  SUCCESS=0

  for url in "${URLS[@]}"; do
    echo "尝试下载: $url"
    rm -f /tmp/hysteria-download

    curl -4 -L --fail \
      --connect-timeout 10 \
      --retry 2 \
      --retry-delay 2 \
      --max-time 90 \
      -A "Mozilla/5.0" \
      "$url" \
      -o /tmp/hysteria-download

    if [ -s /tmp/hysteria-download ] && file /tmp/hysteria-download | grep -q "ELF"; then
      chmod +x /tmp/hysteria-download

      if /tmp/hysteria-download version >/dev/null 2>&1 || /tmp/hysteria-download --version >/dev/null 2>&1; then
        mv /tmp/hysteria-download /usr/local/bin/hysteria
        chmod +x /usr/local/bin/hysteria
        SUCCESS=1
        break
      fi
    fi

    echo "文件无效，切换源..."
    echo "文件类型: $(file /tmp/hysteria-download 2>/dev/null || echo 无文件)"
    echo "文件大小: $(ls -lh /tmp/hysteria-download 2>/dev/null | awk '{print $5}' || echo 0)"
  done

  if [ "$SUCCESS" != "1" ]; then
    echo "Hysteria2 下载失败"
    echo "请检查服务器是否能访问 GitHub Release，或手动上传 hysteria 到 /usr/local/bin/hysteria"
    exit 1
  fi

  echo "Hysteria2 安装成功"
  /usr/local/bin/hysteria version || true
}

install_base() {
  apt update -y
  apt install -y curl wget openssl ca-certificates iptables coreutils qrencode iproute2

  install_hysteria

  mkdir -p "$CERT_DIR" "$NODE_DIR" "$SSL_DIR"

  if [ ! -f "$SELF_KEY" ] || [ ! -f "$SELF_CERT" ]; then
    echo "正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "$SELF_KEY" \
      -out "$SELF_CERT" \
      -subj "/CN=bing.com" \
      -days 36500
  fi

  chmod 755 "$CERT_DIR" "$SSL_DIR"
  chmod 644 "$SELF_CERT" "$SELF_KEY" 2>/dev/null || true
  chmod 644 "$SSL_CERT" "$SSL_KEY" 2>/dev/null || true

  if id hysteria >/dev/null 2>&1; then
    chown -R hysteria:hysteria "$CERT_DIR" 2>/dev/null || true
  fi
}

write_node_config() {
  local ID="$1"
  local PORT="$2"
  local PASSWORD="$3"
  local MODE="$4"

  local CERT_PATH="$SELF_CERT"
  local KEY_PATH="$SELF_KEY"

  if [ "$MODE" = "SSL" ]; then
    CERT_PATH="$SSL_CERT"
    KEY_PATH="$SSL_KEY"
  fi

  cat > "$(config_file "$ID")" <<EOL
listen: :$PORT

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOL

  chmod 644 "$(config_file "$ID")"
}

write_node_service() {
  local ID="$1"

  cat > "/etc/systemd/system/$(service_name "$ID")" <<EOL
[Unit]
Description=HY2 Node $ID
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config $(config_file "$ID")
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL
}

open_firewall() {
  local PORT="$1"

  iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/udp >/dev/null 2>&1 || true
    ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  fi
}

make_link() {
  local PASSWORD="$1"
  local PORT="$2"
  local ID="$3"
  local MODE="$4"
  local SERVER_NAME="$5"

  if [ "$MODE" = "SSL" ]; then
    echo "hysteria2://${PASSWORD}@${SERVER_NAME}:${PORT}?sni=${SERVER_NAME}#HY2-${ID}-${SERVER_NAME}"
  else
    local SERVER_IP
    SERVER_IP=$(get_ip)
    echo "$SERVER_IP" > "$SERVER_IP_FILE"
    echo "hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}?sni=bing.com&insecure=1#HY2-${ID}-${SERVER_IP}"
  fi
}

install_acme() {
  if [ -x "$HOME/.acme.sh/acme.sh" ]; then
    return
  fi

  echo "正在安装 acme.sh..."
  apt update -y
  apt install -y curl socat openssl ca-certificates cron

  curl https://get.acme.sh | sh
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
}

apply_ssl_cert() {
  clear
  read -p "请输入证书域名，例如 sx.example.com: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "域名不能为空"
    pause
  fi

  read -p "请输入邮箱，留空使用 admin@$DOMAIN: " EMAIL
  if [ -z "$EMAIL" ]; then
    EMAIL="admin@$DOMAIN"
  fi

  echo ""
  echo "申请前请确认："
  echo "1. $DOMAIN 已经解析到当前服务器 IP"
  echo "2. 服务器安全组已放行 TCP 80"
  echo "3. 如果使用 Cloudflare，建议该记录使用灰云 DNS only"
  echo ""

  read -p "确认继续申请证书？输入 y: " confirm
  if [ "$confirm" != "y" ]; then
    pause
  fi

  install_acme
  mkdir -p "$SSL_DIR"

  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
  systemctl stop httpd 2>/dev/null || true

  "$HOME/.acme.sh/acme.sh" --register-account -m "$EMAIL" || true

  if ! "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force; then
    echo "证书申请失败"
    echo "请检查域名解析、80端口、安全组、Cloudflare灰云设置"
    pause
  fi

  "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$SSL_CERT" \
    --key-file "$SSL_KEY" \
    --reloadcmd "systemctl restart 'hysteria-*.service' 2>/dev/null || true"

  chmod 755 "$SSL_DIR"
  chmod 644 "$SSL_CERT" "$SSL_KEY"

  cat > "$SSL_INFO" <<EOL
DOMAIN=$DOMAIN
EMAIL=$EMAIL
CERT=$SSL_CERT
KEY=$SSL_KEY
CREATED_AT=$(date "+%Y-%m-%d %H:%M:%S")
EOL

  echo "==============================="
  echo "SSL证书申请成功"
  echo "==============================="
  echo "域名：$DOMAIN"
  echo "证书：$SSL_CERT"
  echo "私钥：$SSL_KEY"
  END_RAW=$(openssl x509 -in "$SSL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2-)
  END_TIME=$(date -d "$END_RAW" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$END_RAW")
  echo "到期时间：$END_TIME"
  echo "==============================="
}

select_node_mode() {
  echo "==============================="
  echo "是否使用 SSL 证书？"
  echo "1. 使用 SSL"
  echo "2. 不使用 SSL"
  echo "==============================="
  read -p "请选择 [1/2]: " SSL_CHOICE

  if [ "$SSL_CHOICE" = "1" ]; then
    if ! has_ssl_cert; then
      echo "未检测到 SSL 证书，需要先申请。"
      apply_ssl_cert
    fi

    if has_ssl_cert; then
      MODE="SSL"
      SERVER_NAME=$(get_ssl_domain)
      if [ -z "$SERVER_NAME" ]; then
        read -p "未找到域名记录，请输入当前证书域名: " SERVER_NAME
      fi
      SNI="$SERVER_NAME"
      TLS_MODE="正式证书"
      INSECURE="false"
    else
      echo "SSL证书不可用，自动回退到 IP 模式"
      MODE="IP"
      SERVER_NAME=$(get_ip)
      SNI="bing.com"
      TLS_MODE="自签证书"
      INSECURE="true"
    fi
  else
    MODE="IP"
    SERVER_NAME=$(get_ip)
    SNI="bing.com"
    TLS_MODE="自签证书"
    INSECURE="true"
  fi
}

add_node() {
  clear
  install_base

  ID=$(next_id)

  echo "==============================="
  echo "新增 HY2 节点"
  echo "==============================="
  select_node_mode

  read -p "请输入节点端口，留空随机: " INPUT_PORT
  PORT=$(choose_port "$INPUT_PORT")

  PASSWORD=$(random_pass)
  LINK=$(make_link "$PASSWORD" "$PORT" "$ID" "$MODE" "$SERVER_NAME")

  write_node_config "$ID" "$PORT" "$PASSWORD" "$MODE"
  write_node_service "$ID"
  open_firewall "$PORT"

  cat > "$(info_file "$ID")" <<EOL
ID: $ID
模式: $MODE
服务器: $SERVER_NAME
端口: $PORT
密码: $PASSWORD
SNI: $SNI
TLS模式: $TLS_MODE
跳过证书验证: $INSECURE
HY2链接: $LINK
到期时间: 未设置
创建时间: $(date "+%Y-%m-%d %H:%M:%S")
EOL

  systemctl daemon-reload
  systemctl enable --now "$(service_name "$ID")"

  sleep 2

  clear
  echo "==============================="
  echo "节点创建完成"
  echo "==============================="
  cat "$(info_file "$ID")"
  echo "==============================="
  echo "注意：云服务器安全组必须放行 UDP $PORT"
  echo "==============================="
  pause
}

list_nodes() {
  clear
  echo "==============================="
  echo "所有 HY2 节点"
  echo "==============================="

  if ! ls "$NODE_DIR"/*.info >/dev/null 2>&1; then
    echo "暂无节点"
    pause
  fi

  printf "%-6s %-8s %-10s %-12s %-20s\n" "ID" "模式" "端口" "状态" "到期时间"

  for f in "$NODE_DIR"/*.info; do
    ID=$(grep "^ID:" "$f" | awk '{print $2}')
    MODE_SHOW=$(grep "^模式:" "$f" | awk '{print $2}')
    [ -z "$MODE_SHOW" ] && MODE_SHOW="IP"
    PORT=$(grep "^端口:" "$f" | awk '{print $2}')
    EXPIRE=$(grep "^到期时间:" "$f" | sed 's/^到期时间: //')
    STATUS=$(systemctl is-active "$(service_name "$ID")" 2>/dev/null)
    printf "%-6s %-8s %-10s %-12s %-20s\n" "$ID" "$MODE_SHOW" "$PORT" "$STATUS" "$EXPIRE"
  done

  echo "==============================="
  pause
}

show_node() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  echo "==============================="
  echo "节点详情"
  echo "==============================="
  cat "$(info_file "$ID")"
  echo "==============================="
  systemctl status "$(service_name "$ID")" --no-pager
  echo "==============================="
  pause
}

delete_node() {
  clear
  read -p "请输入要删除的节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  read -p "确定删除节点 $ID 吗？输入 y 确认: " confirm
  if [ "$confirm" != "y" ]; then
    menu
  fi

  systemctl stop "$(service_name "$ID")" 2>/dev/null
  systemctl disable "$(service_name "$ID")" 2>/dev/null

  rm -f "/etc/systemd/system/$(service_name "$ID")"
  rm -f "$(config_file "$ID")"
  rm -f "$(info_file "$ID")"
  rm -f "$(expire_file "$ID")"

  systemctl daemon-reload

  echo "节点 $ID 已删除"
  pause
}

set_expire() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  echo "时间格式示例：2026-06-30 23:59"
  read -p "请输入到期时间: " EXPIRE_TIME

  EXPIRE_TIMESTAMP=$(date -d "$EXPIRE_TIME" +%s 2>/dev/null)

  if [ -z "$EXPIRE_TIMESTAMP" ]; then
    echo "时间格式错误"
    pause
  fi

  echo "$EXPIRE_TIMESTAMP" > "$(expire_file "$ID")"
  sed -i "s/^到期时间:.*/到期时间: $EXPIRE_TIME/" "$(info_file "$ID")"

  setup_expire_timer

  echo "节点 $ID 到期时间已设置为：$EXPIRE_TIME"
  pause
}

setup_expire_timer() {
  cat > /usr/local/bin/hy2-expire-check <<'EOL'
#!/bin/bash

NODE_DIR="/etc/hysteria/nodes"

for file in "$NODE_DIR"/node-*.expire; do
  [ -e "$file" ] || continue

  ID=$(basename "$file" | sed 's/node-\([0-9]*\).expire/\1/')
  EXPIRE=$(cat "$file")
  NOW=$(date +%s)

  if [ "$NOW" -ge "$EXPIRE" ]; then
    systemctl stop "hysteria-$ID.service" 2>/dev/null
    systemctl disable "hysteria-$ID.service" 2>/dev/null

    INFO="$NODE_DIR/node-$ID.info"
    if [ -f "$INFO" ]; then
      sed -i 's/^到期时间:.*/到期时间: 已到期，节点已停用/' "$INFO"
    fi
  fi
done
EOL

  chmod +x /usr/local/bin/hy2-expire-check

  cat > /etc/systemd/system/hy2-expire-check.service <<EOL
[Unit]
Description=HY2 Multi Node Expire Check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hy2-expire-check
EOL

  cat > /etc/systemd/system/hy2-expire-check.timer <<EOL
[Unit]
Description=HY2 Multi Node Expire Check Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=hy2-expire-check.service

[Install]
WantedBy=timers.target
EOL

  systemctl daemon-reload
  systemctl enable --now hy2-expire-check.timer >/dev/null 2>&1
}

change_port() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  read -p "请输入新端口，留空随机: " INPUT_PORT
  NEW_PORT=$(choose_port "$INPUT_PORT" "$ID")

  PASSWORD=$(grep "^密码:" "$(info_file "$ID")" | awk '{print $2}')
  MODE=$(node_mode "$ID")
  [ -z "$MODE" ] && MODE="IP"
  SERVER_NAME=$(node_server "$ID")
  [ -z "$SERVER_NAME" ] && SERVER_NAME=$(get_ip)

  LINK=$(make_link "$PASSWORD" "$NEW_PORT" "$ID" "$MODE" "$SERVER_NAME")

  write_node_config "$ID" "$NEW_PORT" "$PASSWORD" "$MODE"
  open_firewall "$NEW_PORT"

  sed -i "s/^服务器:.*/服务器: $SERVER_NAME/" "$(info_file "$ID")"
  sed -i "s/^端口:.*/端口: $NEW_PORT/" "$(info_file "$ID")"
  sed -i "s|^HY2链接:.*|HY2链接: $LINK|" "$(info_file "$ID")"

  systemctl restart "$(service_name "$ID")"

  echo "节点 $ID 已更换端口：$NEW_PORT"
  echo "$LINK"
  echo "注意：云服务器安全组必须放行 UDP $NEW_PORT"
  pause
}

reset_password() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  PORT=$(grep "^端口:" "$(info_file "$ID")" | awk '{print $2}')
  NEW_PASSWORD=$(random_pass)
  MODE=$(node_mode "$ID")
  [ -z "$MODE" ] && MODE="IP"
  SERVER_NAME=$(node_server "$ID")
  [ -z "$SERVER_NAME" ] && SERVER_NAME=$(get_ip)

  LINK=$(make_link "$NEW_PASSWORD" "$PORT" "$ID" "$MODE" "$SERVER_NAME")

  write_node_config "$ID" "$PORT" "$NEW_PASSWORD" "$MODE"

  sed -i "s/^服务器:.*/服务器: $SERVER_NAME/" "$(info_file "$ID")"
  sed -i "s/^密码:.*/密码: $NEW_PASSWORD/" "$(info_file "$ID")"
  sed -i "s|^HY2链接:.*|HY2链接: $LINK|" "$(info_file "$ID")"

  systemctl restart "$(service_name "$ID")"

  echo "节点 $ID 已重置密码：$NEW_PASSWORD"
  echo "$LINK"
  pause
}

make_qr() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    apt update -y
    apt install -y qrencode
  fi

  LINK=$(grep "^HY2链接:" "$(info_file "$ID")" | sed 's/^HY2链接: //')

  echo "==============================="
  echo "节点 $ID 二维码"
  echo "==============================="
  qrencode -t ANSIUTF8 "$LINK"
  echo "==============================="
  echo "$LINK"
  echo "==============================="
  pause
}

show_all_links() {
  clear
  echo "==============================="
  echo "所有 HY2 链接"
  echo "==============================="

  if ! ls "$NODE_DIR"/*.info >/dev/null 2>&1; then
    echo "暂无节点"
    pause
  fi

  for f in "$NODE_DIR"/*.info; do
    ID=$(grep "^ID:" "$f" | awk '{print $2}')
    LINK=$(grep "^HY2链接:" "$f" | sed 's/^HY2链接: //')
    echo "节点 $ID:"
    echo "$LINK"
    echo ""
  done

  echo "==============================="
  pause
}

speed_test_node() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  PORT=$(grep "^端口:" "$(info_file "$ID")" | awk '{print $2}')
  SERVER_NAME=$(node_server "$ID")
  MODE=$(node_mode "$ID")
  [ -z "$MODE" ] && MODE="IP"

  echo "==============================="
  echo "节点 $ID 一键测速 / 检测"
  echo "==============================="
  echo "模式: $MODE"
  echo "服务器: $SERVER_NAME"
  echo "端口: $PORT"
  echo ""

  if systemctl is-active --quiet "$(service_name "$ID")"; then
    echo "服务状态: 正常"
  else
    echo "服务状态: 异常"
  fi

  if ss -lunpt 2>/dev/null | grep -q ":$PORT"; then
    echo "UDP监听: 正常"
  else
    echo "UDP监听: 未检测到"
  fi

  if [ "$MODE" = "SSL" ]; then
    if has_ssl_cert; then
      echo "SSL证书: 存在"
      openssl x509 -in "$SSL_CERT" -noout -enddate 2>/dev/null || true
    else
      echo "SSL证书: 不存在"
    fi
  else
    echo "SSL证书: IP自签模式"
  fi

  echo ""
  echo "服务器外网延迟测试:"
  if command -v ping >/dev/null 2>&1; then
    ping -c 3 -W 2 1.1.1.1 2>/dev/null | tail -1 || echo "Ping测试失败"
  else
    echo "未安装 ping"
  fi

  echo "==============================="
  pause
}

online_status() {
  clear
  echo "==============================="
  echo "HY2 在线状态"
  echo "==============================="

  if ! ls "$NODE_DIR"/*.info >/dev/null 2>&1; then
    echo "暂无节点"
    pause
  fi

  printf "%-5s %-8s %-10s %-10s %-12s %-10s\n" "ID" "模式" "端口" "状态" "PID" "内存"

  for f in "$NODE_DIR"/*.info; do
    ID=$(grep "^ID:" "$f" | awk '{print $2}')
    MODE_SHOW=$(grep "^模式:" "$f" | awk '{print $2}')
    [ -z "$MODE_SHOW" ] && MODE_SHOW="IP"
    PORT=$(grep "^端口:" "$f" | awk '{print $2}')
    STATUS=$(systemctl is-active "$(service_name "$ID")" 2>/dev/null)
    PID=$(systemctl show "$(service_name "$ID")" -p MainPID --value 2>/dev/null)
    MEM=$(systemctl show "$(service_name "$ID")" -p MemoryCurrent --value 2>/dev/null)

    if [ -z "$PID" ] || [ "$PID" = "0" ]; then
      PID="-"
    fi

    if [ -n "$MEM" ] && echo "$MEM" | grep -Eq '^[0-9]+$' && [ "$MEM" -gt 0 ]; then
      MEM_MB=$((MEM / 1024 / 1024))M
    else
      MEM_MB="-"
    fi

    printf "%-5s %-8s %-10s %-10s %-12s %-10s\n" "$ID" "$MODE_SHOW" "$PORT" "$STATUS" "$PID" "$MEM_MB"
  done

  echo "==============================="
  pause
}

restart_node() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  systemctl restart "$(service_name "$ID")"
  echo "节点 $ID 已重启"
  pause
}

status_node() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  systemctl status "$(service_name "$ID")" --no-pager
  pause
}

log_node() {
  clear
  read -p "请输入节点ID: " ID

  if [ ! -f "$(info_file "$ID")" ]; then
    echo "节点不存在"
    pause
  fi

  journalctl -u "$(service_name "$ID")" -n 50 --no-pager
  pause
}

ssl_menu() {
  clear
  echo "==============================="
  echo "SSL 证书管理"
  echo "==============================="
  echo "1. 申请/更换证书"
  echo "2. 查看证书状态"
  echo "3. 强制续期证书"
  echo "4. 删除证书"
  echo "5. 导出证书路径"
  echo "6. 检测证书健康"
  echo "0. 返回主菜单"
  echo "==============================="
  read -p "请输入选项: " c

  case "$c" in
    1) apply_ssl_cert; pause ;;
    2) show_ssl_status ;;
    3) renew_ssl_cert ;;
    4) delete_ssl_cert ;;
    5) export_ssl_path ;;
    6) check_ssl_health ;;
    0) menu ;;
    *) echo "输入错误"; sleep 1; ssl_menu ;;
  esac
}

show_ssl_status() {
  clear
  echo "==============================="
  echo "SSL 证书状态"
  echo "==============================="

  if ! has_ssl_cert; then
    echo "状态：未安装"
    echo "证书路径：$SSL_CERT"
    echo "私钥路径：$SSL_KEY"
    echo "证书目录：$SSL_DIR"
    echo "==============================="
    pause
  fi

  DOMAIN=$(get_ssl_domain)
  [ -z "$DOMAIN" ] && DOMAIN="未识别"

  SUBJECT=$(openssl x509 -in "$SSL_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')
  ISSUER=$(openssl x509 -in "$SSL_CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  START_RAW=$(openssl x509 -in "$SSL_CERT" -noout -startdate 2>/dev/null | cut -d= -f2-)
  END_RAW=$(openssl x509 -in "$SSL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2-)

  START_TIME=$(date -d "$START_RAW" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$START_RAW")
  END_TIME=$(date -d "$END_RAW" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$END_RAW")

  END_TS=$(date -d "$END_RAW" +%s 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  if [ "$END_TS" -gt 0 ]; then
    LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))
  else
    LEFT_DAYS="未知"
  fi

  echo "状态：已安装"
  echo "绑定域名：$DOMAIN"
  echo "证书路径：$SSL_CERT"
  echo "私钥路径：$SSL_KEY"
  echo "证书目录：$SSL_DIR"
  echo "签发对象：$SUBJECT"
  echo "签发机构：$ISSUER"
  echo "生效时间：$START_TIME"
  echo "到期时间：$END_TIME"
  echo "剩余天数：$LEFT_DAYS 天"

  if systemctl list-timers 2>/dev/null | grep -q acme; then
    echo "自动续期：已开启"
  elif crontab -l 2>/dev/null | grep -q acme.sh; then
    echo "自动续期：已开启"
  else
    echo "自动续期：未检测到"
  fi

  echo "==============================="
  pause
}

export_ssl_path() {
  clear
  echo "==============================="
  echo "SSL 证书路径"
  echo "==============================="

  if ! has_ssl_cert; then
    echo "SSL证书未安装"
    echo "==============================="
    pause
  fi

  echo "证书路径：$SSL_CERT"
  echo "私钥路径：$SSL_KEY"
  echo "证书目录：$SSL_DIR"
  echo "绑定域名：$(get_ssl_domain)"
  echo "==============================="
  echo "可复制路径："
  echo "$SSL_CERT"
  echo "$SSL_KEY"
  echo "==============================="
  pause
}

check_ssl_health() {
  clear
  echo "==============================="
  echo "SSL 证书健康检测"
  echo "==============================="

  if ! has_ssl_cert; then
    echo "证书状态：异常，未安装"
    echo "建议：先申请证书"
    echo "==============================="
    pause
  fi

  DOMAIN=$(get_ssl_domain)
  [ -z "$DOMAIN" ] && DOMAIN="未识别"
  echo "绑定域名：$DOMAIN"

  if openssl x509 -in "$SSL_CERT" -noout >/dev/null 2>&1; then
    echo "证书文件：正常"
  else
    echo "证书文件：异常"
  fi

  if [ -f "$SSL_KEY" ] && [ -s "$SSL_KEY" ]; then
    echo "私钥文件：正常"
  else
    echo "私钥文件：异常"
  fi

  END_RAW=$(openssl x509 -in "$SSL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2-)
  END_TS=$(date -d "$END_RAW" +%s 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  if [ "$END_TS" -gt 0 ]; then
    LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))
    echo "剩余天数：$LEFT_DAYS 天"
    if [ "$LEFT_DAYS" -le 0 ]; then
      echo "到期状态：已过期"
      echo "建议：立即强制续期"
    elif [ "$LEFT_DAYS" -le 15 ]; then
      echo "到期状态：即将过期"
      echo "建议：尽快续期"
    elif [ "$LEFT_DAYS" -le 30 ]; then
      echo "到期状态：需要关注"
      echo "建议：可以提前续期"
    else
      echo "到期状态：正常"
    fi
  else
    echo "剩余天数：未知"
  fi

  if [ "$DOMAIN" != "未识别" ]; then
    RESOLVE_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    SERVER_IP=$(get_ip)
    if [ -n "$RESOLVE_IP" ]; then
      echo "域名解析：$RESOLVE_IP"
      echo "当前服务器IP：$SERVER_IP"
      if [ "$RESOLVE_IP" = "$SERVER_IP" ]; then
        echo "解析状态：正常"
      else
        echo "解析状态：可能不一致"
        echo "建议：检查DNS解析是否指向当前服务器"
      fi
    else
      echo "域名解析：未检测到"
      echo "建议：检查DNS解析"
    fi
  fi

  echo "==============================="
  pause
}

renew_ssl_cert() {
  clear
  DOMAIN=$(get_ssl_domain)

  if [ -z "$DOMAIN" ]; then
    echo "未找到证书域名，请先申请证书"
    pause
  fi

  install_acme

  echo "正在强制续期：$DOMAIN"
  "$HOME/.acme.sh/acme.sh" --renew -d "$DOMAIN" --ecc --force

  "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$SSL_CERT" \
    --key-file "$SSL_KEY" \
    --reloadcmd "systemctl restart 'hysteria-*.service' 2>/dev/null || true"

  echo "续期完成"
  pause
}

delete_ssl_cert() {
  clear
  echo "此操作只删除本地 SSL 证书文件，不删除已有节点。"
  echo "如果已有 SSL 节点正在使用该证书，删除后这些节点可能无法启动。"
  read -p "确认删除 SSL 证书？输入 y: " confirm

  if [ "$confirm" != "y" ]; then
    ssl_menu
  fi

  rm -rf "$SSL_DIR"
  mkdir -p "$SSL_DIR"

  echo "SSL证书已删除"
  pause
}

uninstall_manager() {
  clear
  echo "此操作只删除 hy2 管理面板，不删除已创建的 HY2 节点。"
  read -p "确定删除管理面板吗？输入 y 确认: " confirm

  if [ "$confirm" != "y" ]; then
    menu
  fi

  rm -f /usr/local/bin/hy2

  echo "HY2 管理面板已删除。"
  echo "已创建的节点不会受影响。"
  exit 0
}

uninstall_all() {
  clear
  echo "危险操作：这会删除所有 HY2 节点、配置、证书和管理面板。"
  read -p "确定全部删除吗？输入 y 确认: " confirm

  if [ "$confirm" != "y" ]; then
    menu
  fi

  systemctl stop hysteria.service 2>/dev/null || true
  systemctl disable hysteria.service 2>/dev/null || true

  systemctl stop hysteria-*.service 2>/dev/null || true
  systemctl disable hysteria-*.service 2>/dev/null || true

  systemctl stop hy2-expire-check.timer 2>/dev/null || true
  systemctl disable hy2-expire-check.timer 2>/dev/null || true

  rm -f /etc/systemd/system/hysteria.service
  rm -f /etc/systemd/system/hysteria-*.service
  rm -f /etc/systemd/system/hy2-expire-check.service
  rm -f /etc/systemd/system/hy2-expire-check.timer
  rm -f /usr/local/bin/hy2-expire-check
  rm -f /usr/local/bin/hy2
  rm -rf /etc/hysteria

  systemctl daemon-reload
  systemctl reset-failed

  echo "HY2 已全部删除。"
  exit 0
}

update_panel() {
  clear
  echo "正在更新管理面板..."

  curl -fsSL \
  https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh \
  -o /usr/local/bin/hy2

  sed -i 's/\r$//' /usr/local/bin/hy2
  chmod +x /usr/local/bin/hy2

  echo "更新完成，请重新执行：hy2"
  exit 0
}

menu() {
clear
echo "==============================="
echo "      $PROJECT_NAME"
echo "      Version $VERSION"
echo "==============================="
echo "1. 新增节点"
echo "2. 查看所有节点"
echo "3. 查看节点详情"
echo "4. 删除节点"
echo "5. 设置到期时间"
echo "6. 一键换端口"
echo "7. 一键重置密码"
echo "8. 一键生成二维码"
echo "9. 查看所有链接"
echo "10. 一键测速/检测"
echo "11. 查看在线状态"
echo "12. 查看指定节点日志"
echo "13. SSL证书管理"
echo "14. 删除管理面板（保留节点）"
echo "15. 删除所有节点并卸载HY2"
echo "16. 更新管理面板"
echo "0. 退出"
echo "==============================="
read -p "请输入选项: " choice

case "$choice" in
  1) add_node ;;
  2) list_nodes ;;
  3) show_node ;;
  4) delete_node ;;
  5) set_expire ;;
  6) change_port ;;
  7) reset_password ;;
  8) make_qr ;;
  9) show_all_links ;;
  10) speed_test_node ;;
  11) online_status ;;
  12) log_node ;;
  13) ssl_menu ;;
  14) uninstall_manager ;;
  15) uninstall_all ;;
  16) update_panel ;;
  0) exit 0 ;;
  *) echo "输入错误"; sleep 1; menu ;;
esac
}

menu
