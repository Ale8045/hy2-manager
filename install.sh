#!/bin/bash

URLS=(
"https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
"https://gh.llkk.cc/https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
"https://gh-proxy.com/https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh"
)

for url in "${URLS[@]}"; do
  echo "正在尝试下载: $url"
  if curl -L --connect-timeout 10 --retry 2 "$url" -o /usr/local/bin/hy2; then
    break
  fi
done

sed -i 's/\r$//' /usr/local/bin/hy2
chmod +x /usr/local/bin/hy2

echo "HY2 管理脚本安装完成"

hy2
