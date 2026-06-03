
cat > /usr/local/bin/hy2 <<'EOF'
#!/bin/bash

BASE_DIR="/etc/hysteria"
NODE_DIR="/etc/hysteria/nodes"
CERT_DIR="/etc/hysteria"
SERVER_IP_FILE="/etc/hysteria/server.ip"

mkdir -p "$BASE_DIR" "$NODE_DIR"

random_port() {
  shuf -i 10000-60000 -n 1
}

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

install_base() {
  apt update -y
  apt install -y curl wget openssl ca-certificates iptables coreutils qrencode iproute2

  if [ ! -f /usr/local/bin/hysteria ]; then
    bash <(curl -fsSL https://get.hy2.sh/)
  fi

  mkdir -p "$CERT_DIR" "$NODE_DIR"

  if [ ! -f "$CERT_DIR/server.key" ] || [ ! -f "$CERT_DIR/server.crt" ]; then
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
    chown -R hysteria:hysteria "$CERT_DIR"
  fi
}

write_node_config() {
  local ID="$1"
  local PORT="$2"
  local PASSWORD="$3"

  cat > "$(config_file "$ID")" <<EOL
listen: :$PORT

tls:
  cert: $CERT_DIR/server.crt
  key: $CERT_DIR/server.key

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
  local SERVER_IP

  SERVER_IP=$(get_ip)
  echo "$SERVER_IP" > "$SERVER_IP_FILE"

  echo "hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}?sni=bing.com&insecure=1#HY2-${ID}-${SERVER_IP}"
}

add_node() {
  clear
  install_base

  ID=$(next_id)

  read -p "请输入节点端口，留空随机: " INPUT_PORT
  if [ -z "$INPUT_PORT" ]; then
    PORT=$(random_port)
  else
    PORT="$INPUT_PORT"
  fi

  PASSWORD=$(random_pass)
  LINK=$(make_link "$PASSWORD" "$PORT" "$ID")

  write_node_config "$ID" "$PORT" "$PASSWORD"
  write_node_service "$ID"
  open_firewall "$PORT"

  cat > "$(info_file "$ID")" <<EOL
ID: $ID
服务器: $(cat "$SERVER_IP_FILE")
端口: $PORT
密码: $PASSWORD
SNI: bing.com
跳过证书验证: true
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
  if [ -z "$INPUT_PORT" ]; then
    NEW_PORT=$(random_port)
  else
    NEW_PORT="$INPUT_PORT"
  fi

  PASSWORD=$(grep "^密码:" "$(info_file "$ID")" | awk '{print $2}')
  LINK=$(make_link "$PASSWORD" "$NEW_PORT" "$ID")

  write_node_config "$ID" "$NEW_PORT" "$PASSWORD"
  open_firewall "$NEW_PORT"

  sed -i "s/^服务器:.*/服务器: $(cat "$SERVER_IP_FILE")/" "$(info_file "$ID")"
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
  LINK=$(make_link "$NEW_PASSWORD" "$PORT" "$ID")

  write_node_config "$ID" "$PORT" "$NEW_PASSWORD"

  sed -i "s/^服务器:.*/服务器: $(cat "$SERVER_IP_FILE")/" "$(info_file "$ID")"
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

menu() {
clear
echo "==============================="
echo "      HY2 多节点管理面板"
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
  0) exit 0 ;;
  *) echo "输入错误"; sleep 1; menu ;;
esac
}

menu
EOF

chmod +x /usr/local/bin/hy2
hy2
