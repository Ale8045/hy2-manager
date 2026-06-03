#!/bin/bash

curl -fsSL \
https://raw.githubusercontent.com/Ale8045/hy2-manager/main/hy2.sh \
-o /usr/local/bin/hy2

chmod +x /usr/local/bin/hy2

echo "HY2 安装完成"

hy2
