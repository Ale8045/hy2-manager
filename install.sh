#!/bin/bash

curl -L --connect-timeout 15 --retry 3 \
"https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh" \
-o /usr/local/bin/hy2

# 修复 Windows CRLF
sed -i 's/\r$//' /usr/local/bin/hy2

chmod +x /usr/local/bin/hy2

echo "HY2 安装完成"

exec /usr/local/bin/hy2
