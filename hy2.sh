#!/bin/bash

VERSION="1.1.0"
BASE_DIR="/etc/hysteria"
NODE_DIR="/etc/hysteria/nodes"
CERT_DIR="/etc/hysteria"
SSL_DIR="/etc/hysteria/ssl"
SSL_INFO="/etc/hysteria/ssl/domain.info"
SERVER_IP_FILE="/etc/hysteria/server.ip"
HY2_VERSION="v2.9.2"
HY2_FILE="hysteria-linux-amd64"
MANAGER_URLS=(
  "https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
  "https://gh.llkk.cc/https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
  "https://ghproxy.net/https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
  "https://gh-proxy.com/https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
)

mkdir -p "$BASE_DIR" "$NODE_DIR" "$SSL_DIR"

random_pass() {
  openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16
}

get_ip() {
  curl -4 -s ipv4.ip.sb || curl -4 -s ifconfig.me || hostname -I | awk '{print $1}'
}

port_used() {
  local PORT="$1"

  if ! echo "$PORT" | grep -Eq '^[0-9]+$'; then
    return 0
  fi

  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    return 0
  fi

  if ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\])${PORT}$"; then
    return 0
  fi

  if ls "$NODE_DIR"/*.yaml >/dev/null 2>&1; then
    if grep -R "^listen: :${PORT}$" "$NODE_DIR"/*.yaml >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

random_port() {
  local PORT
  while true; do
    PORT=$(shuf -i 10000-60000 -n 1)
    if ! port_used "$PORT"; then
      echo "$PORT"
      return
    fi
  done
}

choose_port() {
  local INPUT_PORT="$1"
  local PORT

  if [ -z "$INPUT_PORT" ]; then
    random_port
    return
  fi

  if port_used "$INPUT_PORT"; then
    echo "端口 $INPUT_PORT 已被占用或无效，自动随机生成新端口..." >&2
    PORT=$(random_port)
    echo "已自动选择端口：$PORT" >&2
    echo "$PORT"
  else
    echo "$INPUT_PORT"
  fi
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

is_elf_file() {
  local FILE="$1"
  [ -s "$FILE" ] || return 1
  [ "$(stat -c%s "$FILE" 2>/dev/null || echo 0)" -gt 5000000 ] || return 1
  head -c 4 "$FILE" | od -An -t x1 | grep -qi "7f 45 4c 46"
}

install_hysteria() {
  if command -v hysteria >/dev/null 2>&1; then
    echo "检测到 Hysteria2 已安装，跳过下载"
    hysteria version || true
    return
  fi

  echo "正在安装 Hysteria2..."

  URLS=(
    "https://gh.llkk.cc/https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/${HY2_FILE}"
    "https://ghproxy.net/https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/${HY2_FILE}"
    "https://gh-proxy.com/https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/${HY2_FILE}"
    "https://hub.gitmirror.com/https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/${HY2_FILE}"
    "https://github.com/apernet/hysteria/releases/download/app/${HY2_VERSION}/${HY2_FILE}"
  )

  SUCCESS=0

  for url in "${URLS[@]}"; do
    echo "尝试下载: $url"
    rm -f /tmp/hysteria-download

    timeout 45 curl -L \
      --connect-timeout 8 \
      --retry 1 \
      --speed-time 10 \
      --speed-limit 10240 \
      "$url" \
      -o /tmp/hysteria-download

    if is_elf_file /tmp/hysteria-download; then
      chmod +x /tmp/hysteria-download
      mv /tmp/hysteria-download /usr/local/bin/hysteria
      chmod +x /usr/local/bin/hysteria
      SUCCESS=1
      break
    fi

    echo "当前地址失败，尝试下一个..."
  done

  if [ "$SUCCESS" != "1" ]; then
    echo "Hysteria2 下载失败，请检查网络或稍后重试"
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

  if [ ! -f "$CERT_DIR/server.key" ] || [ ! -f "$CERT_DIR/server.crt" ]; then
    echo "正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.crt" \
      -subj "/CN=bing.com" \
      -days 36500
  fi

  chmod 755 "$CERT_DIR"
  chmod 644 "$CERT_DIR/server.crt"
  chmod 644 "$CERT_DIR/server.key"

  if id hysteria >/dev/null 2>&1; then
    chown -R hysteria:hysteria "$CERT_DIR" 2>/dev/null || true
  fi
}

ssl_enabled() {
  [ -f "$SSL_INFO" ] && [ -f "$SSL_DIR/server.crt" ] && [ -f "$SSL_DIR/server.key" ]
}

ssl_domain() {
  if [ -f "$SSL_INFO" ]; then
    grep '^DOMAIN=' "$SSL_INFO" | cut -d= -f2-
  fi
}

cert_path() {
  if ssl_enabled; then
    echo "$SSL_DIR/server.crt"
  else
    echo "$CERT_DIR/server.crt"
  fi
}

key_path() {
  if ssl_enabled; then
    echo "$SSL_DIR/server.key"
  else
    echo "$CERT_DIR/server.key"
  fi
}

node_server_addr() {
  if ssl_enabled; then
    ssl_domain
  else
    get_ip
  fi
}

node_sni() {
  if ssl_enabled; then
    ssl_domain
  else
    echo "bing.com"
  fi
}

make_link() {
  local PASSWORD="$1"
  local PORT="$2"
  local ID="$3"
  local SERVER_ADDR
  local SNI

  SERVER_ADDR=$(node_server_addr)
  echo "$SERVER_ADDR" > "$SERVER_IP_FILE"
  SNI=$(node_sni)

  if ssl_enabled; then
    echo "hysteria2://${PASSWORD}@${SERVER_ADDR}:${PORT}?sni=${SNI}#HY2-${ID}-${SERVER_ADDR}"
  else
    echo "hysteria2://${PASSWORD}@${SERVER_ADDR}:${PORT}?sni=${SNI}&insecure=1#HY2-${ID}-${SERVER_ADDR}"
  fi
}

write_node_config() {
  local ID="$1"
  local PORT="$2"
  local PASSWORD="$3"
  local CERT_FILE
  local KEY_FILE

  CERT_FILE=$(cert_path)
  KEY_FILE=$(key_path)

  cat > "$(config_file "$ID")" <<EOL
listen: :$PORT

tls:
  cert: $CERT_FILE
  key: $KEY_FILE

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

refresh_node_info() {
  local ID="$1"
  local PORT="$2"
  local PASSWORD="$3"
  local LINK
  local SERVER_ADDR
  local SNI
  local INSECURE
  local TLS_MODE

  LINK=$(make_link "$PASSWORD" "$PORT" "$ID")
  SERVER_ADDR=$(node_server_addr)
  SNI=$(node_sni)

  if ssl_enabled; then
    INSECURE="false"
    TLS_MODE="正式证书"
  else
    INSECURE="true"
    TLS_MODE="自签证书"
  fi

  if [ ! -f "$(info_file "$ID")" ]; then
    cat > "$(info_file "$ID")" <<EOL
ID: $ID
服务器: $SERVER_ADDR
端口: $PORT
密码: $PASSWORD
SNI: $SNI
TLS模式: $TLS_MODE
跳过证书验证: $INSECURE
HY2链接: $LINK
到期时间: 未设置
创建时间: $(date "+%Y-%m-%d %H:%M:%S")
EOL
  else
    sed -i "s/^服务器:.*/服务器: $SERVER_ADDR/" "$(info_file "$ID")"
    sed -i "s/^端口:.*/端口: $PORT/" "$(info_file "$ID")"
    sed -i "s/^密码:.*/密码: $PASSWORD/" "$(info_file "$ID")"
    sed -i "s/^SNI:.*/SNI: $SNI/" "$(info_file "$ID")"
    if grep -q '^TLS模式:' "$(info_file "$ID")"; then
      sed -i "s/^TLS模式:.*/TLS模式: $TLS_MODE/" "$(info_file "$ID")"
    else
      sed -i "/^SNI:/a TLS模式: $TLS_MODE" "$(info_file "$ID")"
    fi
    sed -i "s/^跳过证书验证:.*/跳过证书验证: $INSECURE/" "$(info_file "$ID")"
    sed -i "s|^HY2链接:.*|HY2链接: $LINK|" "$(info_file "$ID")"
  fi
}

restart_existing_nodes_with_current_cert() {
  if ! ls "$NODE_DIR"/*.info >/dev/null 2>&1; then
    return
  fi

  for f in "$NODE_DIR"/*.info; do
    ID=$(grep "^ID:" "$f" | awk '{print $2}')
    PORT=$(grep "^端口:" "$f" | awk '{print $2}')
    PASSWORD=$(grep "^密码:" "$f" | awk '{print $2}')

    if [ -n "$ID" ] && [ -n "$PORT" ] && [ -n "$PASSWORD" ]; then
      write_node_config "$ID" "$PORT" "$PASSWORD"
      refresh_node_info "$ID" "$PORT" "$PASSWORD"
      systemctl restart "$(service_name "$ID")" 2>/dev/null || true
    fi
  done
}

add_node() {
  clear
  install_base

  ID=$(next_id)

  read -p "请输入节点端口，留空随机: " INPUT_PORT
  PORT=$(choose_port "$INPUT_PORT")

  PASSWORD=$(random_pass)

  write_node_config "$ID" "$PORT" "$PASSWORD"
  write_node_service "$ID"
  open_firewall "$PORT"
  refresh_node_info "$ID" "$PORT" "$PASSWORD"

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

  printf "%-6s %-10s %-12s %-20s\n" "ID" "端口" "状态" "到期时间"

  for f in "$NODE_DIR"/*.info; do
    ID=$(grep "^ID:" "$f" | awk '{print $2}')
    PORT=$(grep "^端口:" "$f" | awk '{print $2}')
    EXPIRE=$(grep "^到期时间:" "$f" | sed 's/^到期时间: //')
    STATUS=$(systemctl is-active "$(service_name "$ID")" 2>/dev/null)
    printf "%-6s %-10s %-12s %-20s\n" "$ID" "$PORT" "$STATUS" "$EXPIRE"
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
  NEW_PORT=$(choose_port "$INPUT_PORT")

  PASSWORD=$(grep "^密码:" "$(info_file "$ID")" | awk '{print $2}')

  write_node_config "$ID" "$NEW_PORT" "$PASSWORD"
  open_firewall "$NEW_PORT"
  refresh_node_info "$ID" "$NEW_PORT" "$PASSWORD"

  systemctl restart "$(service_name "$ID")"

  echo "节点 $ID 已更换端口：$NEW_PORT"
  grep "^HY2链接:" "$(info_file "$ID")" | sed 's/^HY2链接: //'
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

  write_node_config "$ID" "$PORT" "$NEW_PASSWORD"
  refresh_node_info "$ID" "$PORT" "$NEW_PASSWORD"

  systemctl restart "$(service_name "$ID")"

  echo "节点 $ID 已重置密码：$NEW_PASSWORD"
  grep "^HY2链接:" "$(info_file "$ID")" | sed 's/^HY2链接: //'
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
  echo "        SSL 证书管理"
  echo "==============================="
  echo "1. 申请/更新域名证书"
  echo "2. 查看证书状态"
  echo "3. 强制续期"
  echo "4. 删除域名证书"
  echo "5. 将现有节点切换到当前证书模式"
  echo "0. 返回主菜单"
  echo "==============================="
  read -p "请输入选项: " ssl_choice

  case "$ssl_choice" in
    1) issue_ssl_cert ;;
    2) show_ssl_status ;;
    3) renew_ssl_cert ;;
    4) delete_ssl_cert ;;
    5) switch_nodes_cert_mode ;;
    0) menu ;;
    *) echo "输入错误"; sleep 1; ssl_menu ;;
  esac
}

issue_ssl_cert() {
  clear
  read -p "请输入域名，例如 hy2.example.com: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "域名不能为空"
    pause
  fi

  read -p "请输入邮箱，用于申请证书: " EMAIL
  if [ -z "$EMAIL" ]; then
    echo "邮箱不能为空"
    pause
  fi

  echo "请确认域名 $DOMAIN 已解析到本机 IP：$(get_ip)"
  echo "请确认 80/TCP 已放行。"
  read -p "确认后输入 y 继续: " confirm
  if [ "$confirm" != "y" ]; then
    ssl_menu
  fi

  apt update -y
  apt install -y certbot

  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true

  certbot certonly --standalone \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL" \
    --preferred-challenges http

  if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
    echo "证书申请失败"
    pause
  fi

  mkdir -p "$SSL_DIR"
  ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/server.crt"
  ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/server.key"

  cat > "$SSL_INFO" <<EOL
DOMAIN=$DOMAIN
EMAIL=$EMAIL
CERT=$SSL_DIR/server.crt
KEY=$SSL_DIR/server.key
MODE=domain
EOL

  echo "证书申请成功：$DOMAIN"
  read -p "是否将现有节点切换为域名证书模式？输入 y 确认: " apply_now
  if [ "$apply_now" = "y" ]; then
    restart_existing_nodes_with_current_cert
    echo "现有节点已切换为域名证书模式"
  fi

  pause
}

show_ssl_status() {
  clear
  echo "==============================="
  echo "SSL 证书状态"
  echo "==============================="

  if ! ssl_enabled; then
    echo "当前未启用域名证书，节点将使用自签证书。"
    echo "自签模式链接会带 insecure=1。"
    echo "==============================="
    pause
  fi

  DOMAIN=$(ssl_domain)
  echo "域名: $DOMAIN"
  echo "证书: $SSL_DIR/server.crt"
  echo "私钥: $SSL_DIR/server.key"
  echo ""
  openssl x509 -in "$SSL_DIR/server.crt" -noout -subject -issuer -dates 2>/dev/null || true
  echo "==============================="
  pause
}

renew_ssl_cert() {
  clear
  if [ ! -f "$SSL_INFO" ]; then
    echo "未找到证书信息，请先申请证书。"
    pause
  fi

  DOMAIN=$(ssl_domain)
  if [ -z "$DOMAIN" ]; then
    echo "域名信息不存在"
    pause
  fi

  echo "正在强制续期：$DOMAIN"
  certbot renew --force-renewal --cert-name "$DOMAIN" || certbot renew --force-renewal

  ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/server.crt"
  ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/server.key"

  restart_existing_nodes_with_current_cert

  echo "续期完成，并已重启现有节点"
  pause
}

delete_ssl_cert() {
  clear
  if [ -f "$SSL_INFO" ]; then
    DOMAIN=$(ssl_domain)
  fi

  echo "删除域名证书后，新增节点会回到自签证书模式。"
  read -p "确定删除域名证书配置吗？输入 y 确认: " confirm
  if [ "$confirm" != "y" ]; then
    ssl_menu
  fi

  rm -f "$SSL_INFO"
  rm -f "$SSL_DIR/server.crt" "$SSL_DIR/server.key"

  if [ -n "$DOMAIN" ]; then
    read -p "是否同时让 certbot 删除证书 $DOMAIN？输入 y 确认: " del_certbot
    if [ "$del_certbot" = "y" ]; then
      certbot delete --cert-name "$DOMAIN" || true
    fi
  fi

  restart_existing_nodes_with_current_cert
  echo "已删除域名证书配置，现有节点已切换回自签模式"
  pause
}

switch_nodes_cert_mode() {
  clear
  restart_existing_nodes_with_current_cert
  echo "现有节点已按当前证书模式重新生成配置并重启"
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

  SUCCESS=0
  for url in "${MANAGER_URLS[@]}"; do
    echo "尝试下载: $url"
    if curl -fsSL --connect-timeout 10 --retry 2 "$url" -o /usr/local/bin/hy2; then
      SUCCESS=1
      break
    fi
  done

  if [ "$SUCCESS" != "1" ]; then
    echo "更新失败，请检查网络"
    pause
  fi

  sed -i 's/\r$//' /usr/local/bin/hy2
  chmod +x /usr/local/bin/hy2

  echo "更新完成，请重新执行：hy2"
  exit 0
}

menu() {
clear
echo "==============================="
echo "      HK HY2 Manager v$VERSION"
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
echo "10. 重启指定节点"
echo "11. 查看指定节点状态"
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
  10) restart_node ;;
  11) status_node ;;
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
