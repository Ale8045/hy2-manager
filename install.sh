#!/bin/bash

curl -L --connect-timeout 15 --retry 3 \
https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh \
-o /usr/local/bin/hy2

# 自动修复Windows换行符
sed -i 's/\r$//' /usr/local/bin/hy2

chmod +x /usr/local/bin/hy2

echo "HY2 安装完成"

hy2
