DEFAULT_START_PORT=20000                         #默认起始端口
DEFAULT_SOCKS_USERNAME="userb"                   #默认socks账号
DEFAULT_SOCKS_PASSWORD="passwordb"               #默认socks密码
DEFAULT_WS_PATH="/ws"                            #默认ws路径
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid) #默认随机UUID

IP_ADDRESSES=($(hostname -I))

install_xray() {
	echo "安装 Xray..."
	apt-get install unzip -y || yum install unzip -y
	wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
	unzip Xray-linux-64.zip
	mv xray /usr/local/bin/xrayL
	chmod +x /usr/local/bin/xrayL
	cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.json
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable xrayL.service
	systemctl start xrayL.service
	
	# 检查防火墙设置
	if command -v ufw >/dev/null 2>&1; then
		echo "检测到 ufw 防火墙，请手动开放端口范围"
	elif command -v firewall-cmd >/dev/null 2>&1; then
		echo "检测到 firewalld 防火墙，请手动开放端口范围"
	fi
	
	echo "Xray 安装完成."
}
config_xray() {
	config_type=$1
	mkdir -p /etc/xrayL
	if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
		echo "类型错误！仅支持socks和vmess."
		exit 1
	fi

	read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
	START_PORT=${START_PORT:-$DEFAULT_START_PORT}
	if [ "$config_type" == "socks" ]; then
		read -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME
		SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

		read -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD
		SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}
	elif [ "$config_type" == "vmess" ]; then
		read -p "UUID (默认随机): " UUID
		UUID=${UUID:-$DEFAULT_UUID}
		read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
		WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
	fi

	# 创建 JSON 格式配置
	config_content="{\n"
	config_content+="  \"log\": {\n"
	config_content+="    \"loglevel\": \"info\"\n"
	config_content+="  },\n"
	config_content+="  \"inbounds\": [\n"
	
	# 生成入站配置
	for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
		if [ $i -gt 0 ]; then
			config_content+=",\n"
		fi
		config_content+="    {\n"
		config_content+="      \"port\": $((START_PORT + i)),\n"
		config_content+="      \"protocol\": \"$config_type\",\n"
		config_content+="      \"tag\": \"inbound_$((i + 1))\",\n"
		config_content+="      \"listen\": \"0.0.0.0\",\n"
		config_content+="      \"settings\": {\n"
		
		if [ "$config_type" == "socks" ]; then
			config_content+="        \"auth\": \"password\",\n"
			config_content+="        \"udp\": true,\n"
			config_content+="        \"accounts\": [\n"
			config_content+="          {\n"
			config_content+="            \"user\": \"$SOCKS_USERNAME\",\n"
			config_content+="            \"pass\": \"$SOCKS_PASSWORD\"\n"
			config_content+="          }\n"
			config_content+="        ]\n"
		elif [ "$config_type" == "vmess" ]; then
			config_content+="        \"clients\": [\n"
			config_content+="          {\n"
			config_content+="            \"id\": \"$UUID\"\n"
			config_content+="          }\n"
			config_content+="        ]\n"
			config_content+="      },\n"
			config_content+="      \"streamSettings\": {\n"
			config_content+="        \"network\": \"ws\",\n"
			config_content+="        \"wsSettings\": {\n"
			config_content+="          \"path\": \"$WS_PATH\"\n"
			config_content+="        }\n"
		fi
		config_content+="      }\n"
		config_content+="    }"
	done
	
	config_content+="\n  ],\n"
	config_content+="  \"outbounds\": [\n"
	
	# 生成出站配置
	for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
		if [ $i -gt 0 ]; then
			config_content+=",\n"
		fi
		config_content+="    {\n"
		config_content+="      \"sendThrough\": \"${IP_ADDRESSES[i]}\",\n"
		config_content+="      \"protocol\": \"freedom\",\n"
		config_content+="      \"tag\": \"outbound_$((i + 1))\"\n"
		config_content+="    }"
	done
	
	# 添加默认出站
	config_content+=",\n"
	config_content+="    {\n"
	config_content+="      \"protocol\": \"freedom\",\n"
	config_content+="      \"tag\": \"direct\"\n"
	config_content+="    }\n"
	
	config_content+="  ],\n"
	config_content+="  \"routing\": {\n"
	config_content+="    \"domainStrategy\": \"IPIfNonMatch\",\n"
	config_content+="    \"rules\": [\n"
	
	# 生成路由配置
	for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
		if [ $i -gt 0 ]; then
			config_content+=",\n"
		fi
		config_content+="      {\n"
		config_content+="        \"type\": \"field\",\n"
		config_content+="        \"inboundTag\": [\"inbound_$((i + 1))\"],\n"
		config_content+="        \"outboundTag\": \"outbound_$((i + 1))\"\n"
		config_content+="      }"
	done
	
	config_content+="\n    ]\n"
	config_content+="  }\n"
	config_content+="}\n"
	echo -e "$config_content" >/etc/xrayL/config.json
	
	# 验证JSON格式
	if command -v python3 >/dev/null 2>&1; then
		if ! python3 -m json.tool /etc/xrayL/config.json >/dev/null 2>&1; then
			echo "错误：生成的配置文件JSON格式有误！"
			exit 1
		fi
	fi
	
	systemctl restart xrayL.service
	sleep 2
	systemctl --no-pager status xrayL.service
	
	echo ""
	echo "生成 $config_type 配置完成"
	echo "起始端口:$START_PORT"
	echo "结束端口:$(($START_PORT + $i - 1))"
	if [ "$config_type" == "socks" ]; then
		echo "socks账号:$SOCKS_USERNAME"
		echo "socks密码:$SOCKS_PASSWORD"
	elif [ "$config_type" == "vmess" ]; then
		echo "UUID:$UUID"
		echo "ws路径:$WS_PATH"
	fi
	
	echo ""
	echo "端口监听状态："
	for ((j = 0; j < ${#IP_ADDRESSES[@]}; j++)); do
		port=$((START_PORT + j))
		if netstat -tlnp 2>/dev/null | grep ":$port " >/dev/null; then
			echo "✓ 端口 $port 正在监听"
		else
			echo "✗ 端口 $port 未监听"
		fi
	done
	
	echo ""
	echo "如果端口未监听，请检查："
	echo "1. 防火墙设置：ufw allow $START_PORT:$(($START_PORT + $i - 1))/tcp"
	echo "2. 服务日志：journalctl -u xrayL.service -f"
	echo "3. 配置文件：cat /etc/xrayL/config.json"
	echo ""
}
main() {
	[ -x "$(command -v xrayL)" ] || install_xray
	if [ $# -eq 1 ]; then
		config_type="$1"
	else
		read -p "选择生成的节点类型 (socks/vmess): " config_type
	fi
	if [ "$config_type" == "vmess" ]; then
		config_xray "vmess"
	elif [ "$config_type" == "socks" ]; then
		config_xray "socks"
	else
		echo "未正确选择类型，使用默认sokcs配置."
		config_xray "socks"
	fi
}
main "$@"
