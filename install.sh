#!/bin/bash
set -e  # 脚本中任何命令失败都立即退出

# 确保是 root 用户
[ "$EUID" -eq 0 ] || {
    echo "请使用 root 权限运行此脚本"
    exit 1
}

# 确保是 Debian/Ubuntu 系统
[ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ] || {
    echo "此脚本仅支持 Debian/Ubuntu 系统"
    exit 1
}

# 首先更新系统并安装基本工具
echo "更新系统并安装基本工具..."
apt update || {
    echo "apt update 失败"
    exit 1
}

# 安装 net-tools
echo "安装 net-tools..."
apt install -y net-tools || {
    echo "net-tools 安装失败"
    exit 1
}

# 安装 cron
echo "安装 cron..."
apt install -y cron || {
    echo "cron 安装失败"
    exit 1
}

# 安装 rsyslog
echo "安装 rsyslog..."
apt install -y rsyslog || {
    echo "rsyslog 安装失败"
    exit 1
}

# 安装 logrotate
echo "安装 logrotate..."
apt install -y logrotate || {
    echo "logrotate 安装失败"
    exit 1
}

# 安装 ufw
echo "安装 ufw..."
apt install -y ufw || {
    echo "ufw 安装失败"
    exit 1
}

# 函数定义
check_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "错误：未找到命 $1"
        exit 1
    }
}

backup_config() {
    local config_file="$1"
    [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
}

write_config() {
    local file="$1"
    cat > "$file"
}

setup_ssh_key() {
    local key_type="$1"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    case $key_type in
        "generate")
            local ssh_key_file="/root/.ssh/id_ed25519"
            ssh-keygen -t ed25519 -f "$ssh_key_file" -N ""
            cat "${ssh_key_file}.pub" >> /root/.ssh/authorized_keys
            local temp_key_file="/tmp/ssh_key_$(date +%s).txt"
            cat "$ssh_key_file" > "$temp_key_file"
            chmod 600 "$temp_key_file"
            echo "SSH 密钥已生成，私钥保存在: ${temp_key_file}"
            ;;
        "import")
            read -r -p "请输入 SSH 公钥: " pubkey
            [[ $pubkey == ssh-ed25519* ]] || {
                echo "错误：无效的公钥格式"
                return 1
            }
            echo "$pubkey" >> /root/.ssh/authorized_keys
            echo "公钥已添加"
            ;;
    esac
    chmod 600 /root/.ssh/authorized_keys
}

check_installed() {
    local component="$1"
    local check_command="$2"
    echo "检查 $component 是否已安装..."
    if eval "$check_command"; then
        echo "$component 已安装，跳过配置"
        return 0
    fi
    return 1
}

# 添加 Python 版本检测函数（在函数定义部分）
get_python_version() {
    local py_version
    py_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    echo "$py_version"
}

# 修改防火墙规则检查函数
check_ufw_rule() {
    local port="$1"
    local comment="$2"
    
    # 检查所有可能的规则格式（包括带注释和不带注释的）
    if ufw status | grep -qE "^($port(/tcp)?|$port(/tcp)? \(v6\))\s+ALLOW"; then
        # 如果指定了注释，检查是否有带注释的规则
        if [ -n "$comment" ]; then
            if ufw status | grep -E "^$port(/tcp)?\s+.*#.*$comment" >/dev/null; then
                echo "端口 $port 已配置 ($comment)"
                return 0
            fi
            # 存在端口但没有指定注释
            echo "端口 $port 已存在其他规则"
            return 2
        else
            echo "端口 $port 已配置"
            return 0
        fi
    fi
    return 1
}

#确保特权分离目录存在
mkdir -p /run/sshd
chown root:sys /run/sshd
chmod 755 /run/sshd

# 在函数定义部分添加备份管理函数
backup_with_timestamp() {
    local file="$1"
    local max_backups="${2:-5}"  # 默认最多保留5个备份
    local backup_dir="/root/config_backups"
    
    # 创建备份目录
    mkdir -p "$backup_dir"
    
    # 生成带时间戳的备份文件名
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${backup_dir}/$(basename ${file}).${timestamp}.bak"
    
    # 创建备份
    if [ -f "$file" ]; then
        cp "$file" "$backup_file"
        echo "已创建配置备份: $backup_file"
        
        # 清理旧备份，只保留最新的N个
        local old_backups=($(ls -t "${backup_dir}/$(basename ${file})".*.bak 2>/dev/null))
        if [ ${#old_backups[@]} -gt "$max_backups" ]; then
            echo "清理旧备份文件..."
            for ((i="$max_backups"; i<${#old_backups[@]}; i++)); do
                rm -f "${old_backups[i]}"
                echo "已删除旧备份: ${old_backups[i]}"
            done
        fi
        
        return 0
    fi
    return 1
}

# 变量定义
COWRIE_INSTALL_DIR="/opt/cowrie"
LOG_RETENTION_DAYS=30
CLEANUP_LOG_SCRIPT="/usr/local/bin/cleanup_logs.sh"
CRON_SCHEDULE="0 2 * * *"  # 修正 cron 表达式

# 在开始时先检查并安装 net-tools
echo "检查 netstat 命令..."
if ! command -v netstat &> /dev/null; then
    echo "netstat 命令未找到，正在安装 net-tools..."
    apt update
    apt install -y net-tools || {
        echo "net-tools 安装失败"
        exit 1
    }
    echo "net-tools 安装完成"
fi

# 环境检查
for cmd in apt systemctl grep awk; do
    check_command "$cmd"
done

# 添加系统源更新函数
update_sources() {
    local os_version
    if [ -f /etc/debian_version ]; then
        os_version=$(cat /etc/debian_version)
        case $os_version in
            10*)
                echo "检测到 Debian 10 (Buster)，更新软件源..."
                # 备份当前源
                cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d)
                # 更新为 Debian 11 源
                cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
                echo "已更新软件源为 Debian 11 (Bullseye)"
                ;;
        esac
    fi
}

# 在环境检查后，系统更新前添加
echo "检查系统软件源..."
update_sources

# 添加在环境检查部分之前
echo "设置系统时区为上海..."
if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
    echo "时区已设置为上海"
else
    echo "警告：无法找到上海时区文件"
fi

# 修改 Python 版本检测函数
check_python_version() {
    local current_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    # 将版本号分解为主版本和次版本
    local required_major=3
    local required_minor=9
    local current_major=$(echo $current_version | cut -d. -f1)
    local current_minor=$(echo $current_version | cut -d. -f2)
    
    # 先比较主版本，如果主版本相同则比较次版本
    if [ "$current_major" -gt "$required_major" ] || 
       ([ "$current_major" -eq "$required_major" ] && [ "$current_minor" -ge "$required_minor" ]); then
        echo "当前 Python 版本 ($current_version) 满足要求"
        return 0
    else
        echo "当前 Python 版本 ($current_version) 低于要求的 3.9"
        return 1
    fi
}

# 添加 Python 升级函数
upgrade_python() {
    local os_id=$(. /etc/os-release && echo "$ID")
    local os_version=$(. /etc/os-release && echo "$VERSION_ID")
    local python_version="3.9" # Default to 3.11, can be changed
    local python_pkg="python${python_version}"
    local python_dev_pkg="python${python_version}-dev"
    local python_venv_pkg="python${python_version}-venv"

    echo "开始升级 Python 到 ${python_version}..."
    
    case "$os_id" in
        "debian")
            case "$os_version" in
                "10")
                    echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list
                    apt update
                    apt -t buster-backports install -y python3.9 python3.9-dev python3.9-venv
                    ;;
                "11"|"12")
                    sudo apt update
                    if sudo apt install -y "$python_pkg" "$python_dev_pkg" "$python_venv_pkg"; then
                        sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/"$python_pkg" 1
                        echo "成功将 Python 升级到 ${python_version}。"
                    else
                        echo "升级 Python 到 ${python_version} 失败。"
                        return 1
                    fi
                    ;;
                *)
                    echo "不支持的 Debian 版本: ${os_version}"
                    return 1
                    ;;
            esac
            ;;
        "ubuntu")
            case "$os_version" in
                "20.04"|"22.04"|"24.04")
                    sudo apt install -y software-properties-common
                    sudo add-apt-repository ppa:deadsnakes/ppa -y
                    sudo apt update
                    if sudo apt install -y "$python_pkg" "$python_dev_pkg" "$python_venv_pkg"; then
                        sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/"$python_pkg" 1
                        echo "成功将 Python 升级到 ${python_version}。"
                    else
                        echo "升级 Python 到 ${python_version} 失败。"
                        return 1
                    fi
                    ;;
                *)
                    echo "不支持的 Ubuntu 版本: ${os_version}"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "不支持的操作系统: ${os_id}"
            return 1
            ;;
    esac
}

# 添加 Python 依赖修复函数
fix_python_deps() {
    echo "修复 Python 依赖..."
    # 修复 apt_pkg 模块
    if ! python3 -c "import apt_pkg" 2>/dev/null; then
        echo "重新安装 python3-apt 以修复 apt_pkg 模块..."
        apt-get remove --purge -y python3-apt
        apt-get install -y python3-apt
    fi
}

# 在环境检查后添加 Python 版本检查
echo "检查 Python 版本要求..."
if ! check_python_version; then
    echo "正在升级 Python..."
    upgrade_python
    if ! check_python_version; then
        echo "Python 版本升级失败"
        exit 1
    fi
    echo "Python 已成功升级到 3.9+"
    fix_python_deps
fi

# 检查 netstat 命令
if ! command -v netstat &> /dev/null; then
    echo "netstat 命令未找到，正在安装 net-tools..."
    apt install -y net-tools || {
        echo "net-tools 安装失败"
        exit 1
    }
    echo "net-tools 安装完成"
fi

# 系统依赖安装和 Python 环境检查
echo "安装依赖..."
apt install -y fail2ban python3-virtualenv git curl netstat-nat || {
    echo "依赖安装失败，请检查系统配置"
    exit 1
}

# 检查 Python 环境
if ! python3 -c "import distutils" 2>/dev/null; then
    echo "正在安装 Python 兼容环境..."
    apt install -y python3.7 python3.7-distutils
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.7 1
fi

apt upgrade -y
apt install -y fail2ban python3-virtualenv git curl netstat-nat

# 添加 fail2ban 配置函数
configure_fail2ban() {
    echo "====开始配置 fail2ban===="
    
    # 如果存在现有配置,显示配置摘要
    if [ -f /etc/fail2ban/jail.local ]; then
        echo "当前 fail2ban 配置摘要:"
        echo "------------------------"
        grep -E "^(bantime|findtime|maxretry|action)" /etc/fail2ban/jail.local
        echo "------------------------"
    fi

    # 备份现有配置
    if [ -f /etc/fail2ban/jail.local ]; then
        echo "1. 备份 fail2ban 配置..."
        backup_with_timestamp "/etc/fail2ban/jail.local" 3
    fi

    # 检测系统并写入相应配置
    echo "2. 写入新配置..."
    echo "新配置将包含:"
    echo "- 禁止时长: 86400秒(24小时)"
    echo "- 检测时间窗口: 1800秒(30分钟)"
    echo "- 最大重试次数: 3次"
    echo "- 启用 SSH 防护"

    # 检测最佳后端
    if [ -d /run/systemd/system ]; then
        BACKEND="systemd"
    else
        BACKEND="auto"
    fi
    
    if ! cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 86400
findtime = 1800
backend = $BACKEND  
action = %(action_)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
    then
        echo "错误：无法写入 fail2ban 配置文件"
        return 1
    fi
    echo "配置文件写入成功"

    # 测试配置
    echo "3. 测试配置文件..."
    if ! fail2ban-client -t; then
        echo "错误：fail2ban 配置测试失败"
        return 1
    fi
    echo "配置文件测试通过"

    # 重启服务
    echo "4. 重启 fail2ban 服务..."
    if ! systemctl restart fail2ban; then
        echo "错误：fail2ban 服务重启失败"
        journalctl -u fail2ban --no-pager -n 50
        return 1
    fi

    # 检查服务状态
    echo "5. 检查服务状态..."
    if ! systemctl is-active --quiet fail2ban; then
        echo "错误：fail2ban 服务未能正常启动"
        systemctl status fail2ban
        return 1
    fi

    echo "====fail2ban 配置完成===="
    return 0
}

install_fail2ban_deps() {
    echo "安装fail2ban依赖..."
    apt update
    # 安装python3-systemd包以解决systemd后端问题
    apt install -y python3-systemd || {
        echo "python3-systemd安装失败"
        return 1
    }
    # 确保fail2ban完全卸载后重新安装
    apt remove --purge -y fail2ban
    apt autoremove -y
    apt install -y fail2ban || {
        echo "fail2ban安装失败"
        return 1
    }
    return 0
}

# Fail2ban 安装和配置部分
echo "检查 fail2ban 状态..."

# 先检查是否已安装
if ! command -v fail2ban-client &>/dev/null || \
   ! python3 -c "import systemd" 2>/dev/null; then
    echo "fail2ban 未安装或缺少必要依赖，开始安装..."
    install_fail2ban_deps || {
        echo "fail2ban及其依赖安装失败"
        exit 1
    }
fi

# 检查服务状态并提供配置选项
if systemctl is-active --quiet fail2ban; then
    echo "fail2ban 服务正在运行"
    if [ -f /etc/fail2ban/jail.local ]; then
        echo "当前 fail2ban 配置摘要:"
        echo "------------------------"
        grep -E "^(bantime|findtime|maxretry|action)" /etc/fail2ban/jail.local || echo "未找到关键配置"
        echo "------------------------"
    else
        echo "未检测到自定义配置文件"
    fi
    
    read -r -p "是否重新配置 fail2ban？(y/N): " reconfigure
    if [[ "$reconfigure" =~ ^([yY])+$ ]]; then
        configure_fail2ban || exit 1
    else
        echo "保持当前配置"
    fi
else
    echo "fail2ban 服务未运行，开始配置..."
    configure_fail2ban || exit 1
fi

# 日志清理脚本配置
echo "检查日志清理配置..."
if [ ! -f "$CLEANUP_LOG_SCRIPT" ]; then
    echo "配置日志清理..."
    cat > "$CLEANUP_LOG_SCRIPT" <<'EOFF'
#!/bin/bash
find /var/log -type f -name "*.log" -mtime +30 -exec rm -f {} \;
echo "$(date): Logs older than 30 days have been deleted." >> /var/log/cleanup.log
EOFF

    chmod +x "$CLEANUP_LOG_SCRIPT"
    
    # 配置定时任务
    if ! crontab -l | grep -q "$CLEANUP_LOG_SCRIPT"; then
        (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CLEANUP_LOG_SCRIPT") | crontab -
        echo "定时任务已配置"
    fi
    echo "日志清理配置完成"
else
    echo "日志清理已配置，跳过"
fi

echo "开始安装 Cowrie..."

# Cowrie 配置部分
echo "检查 Cowrie 安装状态..."
COWRIE_INSTALLED=false
if [ -d "$COWRIE_INSTALL_DIR" ] && [ -f "$COWRIE_INSTALL_DIR/bin/cowrie" ]; then
    echo "检测到现有 Cowrie 安装，检查完整性..."
    if [ -f "/etc/systemd/system/cowrie.service" ] && [ -d "$COWRIE_INSTALL_DIR/var/log/cowrie" ]; then
        COWRIE_INSTALLED=true
        echo "Cowrie 已完整安装"
    fi
fi

if [ "$COWRIE_INSTALLED" = "false" ]; then
    echo "开始安装 Cowrie..."
    
    # 创建 Cowrie 用户和主目录
    echo "创建 Cowrie 用户..."
    if ! id cowrie &>/dev/null; then
        useradd -m -s /bin/bash cowrie || {
            echo "创建 cowrie 用户失败"
            exit 1
        }
    fi

    # 准备目录
    echo "准备安装目录..."
    rm -rf "$COWRIE_INSTALL_DIR"
    mkdir -p "$COWRIE_INSTALL_DIR"
    
    # 克隆仓库
    echo "克隆 Cowrie 仓库..."
    git clone https://github.com/cowrie/cowrie.git "$COWRIE_INSTALL_DIR" || {
        echo "克隆 Cowrie 仓库失败"
        exit 1
    }

    # 先用 root 执行初始化操作
    echo "初始化 Python 环境..."
    cd "$COWRIE_INSTALL_DIR"
    python3 -m virtualenv cowrie-env || {
        echo "创建虚拟环境失败"
        exit 1
    }

    # 激活虚拟环境并安装依赖
    echo "安装依赖..."
    source cowrie-env/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt || {
        echo "安装依赖失败"
        exit 1
    }
    deactivate

    # 配置 Cowrie
    echo "配置 Cowrie..."
    cp etc/cowrie.cfg.dist etc/cowrie.cfg
    sed -i 's/hostname = svr04/hostname = macmini/' etc/cowrie.cfg
    sed -i 's/^#listen_port=2222/listen_port=2222/' etc/cowrie.cfg
    sed -i 's/^#download_limit_size=10485760/download_limit_size=1048576/' etc/cowrie.cfg
    
    # 创建日志目录
    mkdir -p var/log/cowrie

    # 最后设置权限
    echo "设置权限..."
    chown -R cowrie:cowrie "$COWRIE_INSTALL_DIR"
    chmod -R 755 "$COWRIE_INSTALL_DIR"
    chmod 700 "$COWRIE_INSTALL_DIR/var/log/cowrie"

    echo "Cowrie 基础安装完成"
fi

# 配置 Cowrie 服务
echo "配置 Cowrie 服务..."
PYTHON_VERSION=$(get_python_version)
cat <<EOF > /etc/systemd/system/cowrie.service
[Unit]
Description=Cowrie SSH Honeypot
After=network.target

[Service]
Type=simple
User=cowrie
Group=cowrie
WorkingDirectory=$COWRIE_INSTALL_DIR
Environment="PYTHONPATH=$COWRIE_INSTALL_DIR/cowrie-env/lib/python${PYTHON_VERSION}/site-packages"
Environment="PATH=$COWRIE_INSTALL_DIR/cowrie-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/bin/bash -c 'cd $COWRIE_INSTALL_DIR && source cowrie-env/bin/activate && bin/cowrie start -n'
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# 重载并启动服务
systemctl daemon-reload
systemctl enable cowrie
systemctl start cowrie

# SSH 安全配置
echo "检查 SSH 配置..."
if [ -f "/root/.ssh/id_rsa" ] && grep -q "^Port" /etc/ssh/sshd_config; then
    read -p "SSH 已配置，是否重新配置？[y/N]: " RECONFIGURE_SSH
    if [[ ! $RECONFIGURE_SSH =~ ^[Yy]$ ]]; then
        echo "保持当前 SSH 配置"
        SSH_CONFIGURED=true
    fi
fi

if [ "$SSH_CONFIGURED" != "true" ]; then
    echo "配置 SSH..."
    # 检测当前 SSH 配置
    current_ssh_config() {
        local port=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
        echo "${port:-22}"
    }

    CURRENT_SSH_PORT=$(current_ssh_config)
    CURRENT_PASSWORD_AUTH=$(grep -E "^PasswordAuthentication\s+" /etc/ssh/sshd_config | awk '{print $2}')
    CURRENT_PASSWORD_AUTH=${CURRENT_PASSWORD_AUTH:-yes}
    CURRENT_PUBKEY_AUTH=$(grep -E "^PubkeyAuthentication\s+" /etc/ssh/sshd_config | awk '{print $2}')
    CURRENT_PUBKEY_AUTH=${CURRENT_PUBKEY_AUTH:-yes}

    echo "当前 SSH 配置："
    echo "- 端口: $CURRENT_SSH_PORT"
    echo "- 密码认证: $CURRENT_PASSWORD_AUTH"
    echo "- 密钥认证: $CURRENT_PUBKEY_AUTH"
    echo ""

    # SSH 端口配置
    echo "0) 保持当前配置 (端口: $CURRENT_SSH_PORT)"
    echo "1) 随机生成新端口"
    echo "2) 手动输入新端口"
    read -p "请选择 [0/1/2] (默认: 0): " PORT_CHOICE
    PORT_CHOICE=${PORT_CHOICE:-0}

    case $PORT_CHOICE in
        0)
            NEW_SSH_PORT=$CURRENT_SSH_PORT
            echo "保持当前 SSH 端口: $NEW_SSH_PORT"
            ;;
        1)
            NEW_SSH_PORT=$((RANDOM % 55535 + 10000))
            while netstat -tuln | grep ":$NEW_SSH_PORT " > /dev/null; do
                NEW_SSH_PORT=$((RANDOM % 55535 + 10000))
            done
            ;;
        2)
            while true; do
                read -p "请输入要使用的 SSH 端口 (1024-65535): " NEW_SSH_PORT
                if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1024 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
                    # 检查端口是否被占用
                    if ! netstat -tuln | grep ":$NEW_SSH_PORT " > /dev/null; then
                        break
                    else
                        echo "错误：端口 $NEW_SSH_PORT 已被占用，请选择其他端口"
                    fi
                else
                    echo "错误：请输入 1024-65535 之间的有效端口号"
                fi
            done
            ;;
        *)
            NEW_SSH_PORT=$CURRENT_SSH_PORT
            echo "无效的选择！保持当前端口: $NEW_SSH_PORT"
            ;;
    esac

    # 更新 SSH 配置文件
    sed -i "s/^#\?Port.*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config

    # 重新启动 SSH 服务
    echo "重新启动 SSH 服务..."
    systemctl restart ssh

    # 更新防火墙规则
    echo "更新防火墙规则..."
    ufw allow "$NEW_SSH_PORT"/tcp comment 'SSH'
    ufw delete allow "$CURRENT_SSH_PORT"/tcp

    echo "SSH 服务已重新启动，使用新的端口: ${NEW_SSH_PORT}"

    # SSH 认证配置
    echo "SSH 认证配置："
    echo "0) 保持当前配置"
    echo "1) 仅使用密钥认证（禁用密码）"
    echo "2) 同时启用密码和密钥认证"
    read -p "请选择 [0/1/2] (默认: 0): " AUTH_CHOICE
    AUTH_CHOICE=${AUTH_CHOICE:-0}

    case $AUTH_CHOICE in
        0)
            echo "保持当前认证配置"
            ;;
        1)
            echo "配置仅使用密钥认证..."
            # 创建配置备份
            backup_with_timestamp "/etc/ssh/sshd_config" 3
            
            # 移除所有相关的认证配置行
            sed -i '/^#\?PasswordAuthentication/d' /etc/ssh/sshd_config
            sed -i '/^#\?PubkeyAuthentication/d' /etc/ssh/sshd_config
            sed -i '/^#\?ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
            sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
            sed -i '/^#\?AuthenticationMethods/d' /etc/ssh/sshd_config
            sed -i '/^#\?UsePAM/d' /etc/ssh/sshd_config
            
            # 添加新的配置（在文件末尾）
            cat >> /etc/ssh/sshd_config <<EOF

# 安全配置 - $(date '+%Y-%m-%d %H:%M:%S')
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
AuthenticationMethods publickey
UsePAM yes
EOF

            # 密钥配置选项
            echo "SSH 密钥配置："
            echo "0) 保持现有密钥"
            echo "1) 使用新的公钥"
            echo "2) 自动生成新密钥对"
            read -p "请选择 [0/1/2] (默认: 0): " KEY_CHOICE
            KEY_CHOICE=${KEY_CHOICE:-0}

            case $KEY_CHOICE in
                0)
                    echo "保持现有密钥配置"
                    ;;
                1)
                    setup_ssh_key "import"
                    ;;
                2)
                    echo "生成新的密钥对..."
                    echo "注意：这将覆盖现有的密钥"
                    read -p "是否继续？[y/N]: " CONFIRM
                    if [[ $CONFIRM =~ ^[Yy]$ ]]; then
                        setup_ssh_key "generate"
                    else
                        echo "取消生成新密钥"
                    fi
                    ;;
                *)
                    echo "无效的选择！保持现有密钥配置"
                    ;;
            esac

            # 测试配置
            echo "测试 SSH 配置..."
            if ! sshd -t; then
                echo "SSH 配置测试失败，恢复默认配置"
                # 找到最新的备份文件
                LATEST_BACKUP=$(find /root/config_backups -name "sshd_config*.bak" -print0 | xargs -0 ls -1t | head -n 1)
                if [ -n "$LATEST_BACKUP" ]; then
                    cp "$LATEST_BACKUP" /etc/ssh/sshd_config
                    systemctl restart sshd
                    exit 1
                else
                    echo "错误：未找到备份文件，无法恢复"
                    exit 1
                fi
            fi

            echo "测试 SSH 配置..."
            if ! sshd -t; then
                echo "SSH 配置测试失败，恢复默认配置"
                mv /etc/ssh/sshd_config.bak.$(date +%s) /etc/ssh/sshd_config
                systemctl restart sshd
                exit 1
            fi

            echo "应用新的 SSH 配置..."
            systemctl restart ssh

            # 验证配置
            echo "验证 SSH 配置..."
            if grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config || \
               ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config || \
               ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || \
               ! grep -q "^AuthenticationMethods publickey" /etc/ssh/sshd_config; then
                echo "警告：SSH 配置可能未正确应用"
                echo "当前 SSH 配置状态："
                grep -E "^(PasswordAuthentication|PubkeyAuthentication|AuthenticationMethods)" /etc/ssh/sshd_config
                echo "是否继续？[y/N]: "
                read -r CONTINUE
                if [[ ! $CONTINUE =~ ^[Yy]$ ]]; then
                    echo "恢复原始配置..."
                    mv /etc/ssh/sshd_config.bak.$(date +%s) /etc/ssh/sshd_config
                    systemctl restart ssh
                    exit 1
                fi
            fi

            echo "SSH 配置更新完成：仅允许密钥认证"
            ;;
        2)
            # 启用密码和密钥认证
            sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
            sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
            sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
            ;;
        *)
            echo "无效的选择！保持当前认证配置"
            ;;
    esac

    # 防火墙配置
    setup_firewall() {
        echo "开始设置防火墙规则..."
        command -v ufw >/dev/null 2>&1 || {
            echo "未检测到 UFW 防火墙"
            return 0
        }
        
        echo "检测到 UFW 防火墙..."
        
        # 检查防火墙状态
        local ufw_status=$(ufw status | grep "Status: " | cut -d' ' -f2)
        echo "当前防火墙状态: $ufw_status"
        
        # 检查并添加 SSH 端口规则
        local ssh_rule_exists=false
        if check_ufw_rule "$NEW_SSH_PORT" "SSH"; then
            echo "SSH 端口 $NEW_SSH_PORT 已配置正确规则"
            ssh_rule_exists=true
        elif check_ufw_rule "$NEW_SSH_PORT" ""; then
            echo "端口 $NEW_SSH_PORT 已存在，但没有 SSH 标记"
            read -p "是否重新添加带 SSH 标记的规则？[y/N]: " -r ADD_SSH_MARK
            if [[ $ADD_SSH_MARK =~ ^[Yy]$ ]]; then
                ufw delete allow $NEW_SSH_PORT
                ufw allow "$NEW_SSH_PORT"/tcp comment 'SSH'
                echo "更新了 SSH 端口规则"
            fi
            ssh_rule_exists=true
        else
            echo "添加新 SSH 端口 $NEW_SSH_PORT 到防火墙规则..."
            ufw allow "$NEW_SSH_PORT"/tcp comment 'SSH'
        fi
        
        # 检查原 SSH 端口规则（如果不同）
        if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
            if check_ufw_rule "$CURRENT_SSH_PORT" "SSH"; then
                read -p "是否保留原 SSH 端口($CURRENT_SSH_PORT)规则？[Y/n]: " -r KEEP_OLD_PORT
                KEEP_OLD_PORT=${KEEP_OLD_PORT:-y}
                if [[ $KEEP_OLD_PORT =~ ^[Nn]$ ]]; then
                    echo "删除原 SSH 端口规则..."
                    ufw delete allow "$CURRENT_SSH_PORT"/tcp
                else
                    echo "保留原 SSH 端口规则作为备用"
                fi
            fi
        fi
        
        # 检查蜜罐端口规则
        check_ufw_rule "2222" "Cowrie"
        local honeypot_status=$?
        if [ "$honeypot_status" -eq 1 ]; then
            echo "添加蜜罐端口到防火墙规则..."
            ufw allow 2222/tcp comment 'Cowrie Honeypot'
        elif [ "$honeypot_status" -eq 2 ]; then
            echo "警告: 端口 2222 已有其他规则，可能会影响蜜罐功能"
            read -p "是否添加新规则？[Y/n]: " -r ADD_HONEYPOT_RULE
            ADD_HONEYPOT_RULE=${ADD_HONEYPOT_RULE:-y}
            if [[ $ADD_HONEYPOT_RULE =~ ^[Yy]$ ]]; then
                ufw allow 2222/tcp comment 'Cowrie Honeypot'
            fi
        else
            echo "蜜罐端口规则已配置"
        fi
        
        # 检查防火墙状态并询问是否启用
        if [ "$ufw_status" != "active" ]; then
            read -p "防火墙当前未启用，是否启用？[Y/n]: " -r ENABLE_UFW
            ENABLE_UFW=${ENABLE_UFW:-y}
            if [[ $ENABLE_UFW =~ ^[Yy]$ ]]; then
                echo "启用防火墙..."
                ufw --force enable
                echo "防火墙已启用"
            else
                print_warning "警告：防火墙未启用，请确保手动配置以下规则："
                echo "- SSH 端口: $NEW_SSH_PORT/tcp"
                echo "- 蜜罐端口: 2222/tcp"
                [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] && [ "$KEEP_OLD_PORT" != "n" ] && echo "- 原 SSH 端口: $CURRENT_SSH_PORT/tcp"
            fi
        fi
        
        # 显示最终配置
        echo -e "\n当前防火墙状态和规则："
        ufw status verbose
        
        echo "防火墙配置完成"
        return 0
    }

    # 调用防火墙配置函数并确保继续执行
    setup_firewall || true
    echo "继续执行后续配置..."

    # 如果端口已更改，则更新 SSH 配置
    if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
        sed -i "s/^#\?Port.*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
    fi

    if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] || [ "$AUTH_CHOICE" != "0" ]; then
        systemctl restart ssh
    fi

    echo "SSH 配置状态："
    [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] && echo "- SSH 端口已更改为: ${NEW_SSH_PORT}"
    [ "$AUTH_CHOICE" != "0" ] && echo "- SSH 认证配置已更新"
    [ "$SETUP_UFW" = "y" ] && echo "- 防火墙规则已更新"
    echo "=========================="
fi

# 检查服务状态
echo "检查服务状态..."
SERVICE_CHECK_FAILED=false

check_service() {
    local service_name="$1"
    echo "检查 $service_name 服务状态..."
    
    if ! systemctl is-active --quiet "$service_name"; then
        echo "服务未运行，检查问题..."
        if [ "$service_name" = "cowrie" ]; then
            echo "===== Cowrie 服务状态 ====="
            systemctl status cowrie
            echo "===== Cowrie 日志 ====="
            journalctl -u cowrie --no-pager -n 50
            echo "===== 进程检查 ====="
            ps aux | grep cowrie
            echo "===== 权限检查 ====="
            ls -la "$COWRIE_INSTALL_DIR"
            ls -la "$COWRIE_INSTALL_DIR/bin"
            echo "===== Python 环境 ====="
            runuser -l cowrie -c "cd $COWRIE_INSTALL_DIR && source cowrie-env/bin/activate && python3 -V"
        fi
        return 1
    fi
    echo "$service_name 服务运行正常"
    return 0
}

# 检查各个服务
check_service "cowrie"
check_service "fail2ban"

# 在最终状态报告前添加防火墙检查和提示
echo "检查防火墙状态..."
if ! command -v ufw >/dev/null 2>&1; then
    echo "提示：系统未安装防火墙(UFW)，建议安装并配置以提高安全性"
    echo "安装和配置方法："
    echo "apt install ufw"
    echo "ufw allow ${NEW_SSH_PORT:-22}/tcp  # 开放 SSH 端口"
    echo "ufw allow 2222/tcp                 # 开放蜜罐端口"
    echo "ufw enable                         # 启用防火墙"
else
    echo "防火墙状态："
    if ufw status | grep -q "Status: active"; then
        echo "- UFW 已启用"
        echo "- SSH 端口状态: $(ufw status | grep -E "$NEW_SSH_PORT/tcp" || echo "未开放")"
        echo "- 蜜罐端口状态: $(ufw status | grep "2222/tcp" || echo "未开放")"
    else
        echo "警告：UFW 防火墙已安装但未启用"
        echo "建议执行以下命令配置防火墙："
        echo "ufw allow ${NEW_SSH_PORT:-22}/tcp"
        echo "ufw allow 2222/tcp"
        echo "ufw enable"
    fi
fi

# 在脚本末尾添加美化输出函数和最终配置总结
print_header() {
    echo -e "\n\033[1;34m=== $1 ===\033[0m"
}

print_success() {
    echo -e "\033[1;32m✓ $1\033[0m"
}

print_warning() {
    echo -e "\033[1;33m⚠ $1\033[0m"
}

print_error() {
    echo -e "\033[1;31m✗ $1\033[0m"
}

print_info() {
    echo -e "\033[1;36m➜ $1\033[0m"
}

# 修改获取当前 SSH 端口的函数
get_current_ssh_port() {
    # 优先使用脚本中设置的新端口
    if [ -n "$NEW_SSH_PORT" ]; then
        echo "$NEW_SSH_PORT"
        return
    fi
    # 否则从配置文件读取
    local port=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
    echo "${port:-22}"
}

# 最终配置总结
clear
print_header "Backtrance 安装完成"
echo "安装时间: $(date '+%Y-%m-%d %H:%M:%S')"

print_header "SSH 配置信息"
FINAL_SSH_PORT=$(get_current_ssh_port)
echo "当前 SSH 配置："
print_info "端口: $FINAL_SSH_PORT"
print_info "密码认证: $(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}' || echo "yes")" 
check_pubkey_auth() {
    # 1. 首先检查未注释的配置
    local value=$(grep -E "^[[:space:]]*PubkeyAuthentication[[:space:]]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    
    # 2. 如果没找到,检查注释的配置
    if [ -z "$value" ]; then
        value=$(grep -E "^#[[:space:]]*PubkeyAuthentication[[:space:]]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    fi
    
    # 3. 如果还是没找到,返回默认值
    echo "${value:-yes}"
}

print_info "密钥认证: $(check_pubkey_auth)"
# Check both root and original user's SSH keys
ORIGINAL_USER=$(who am i | awk '{print $1}')
if [ -f "/root/.ssh/authorized_keys" ]; then
    print_info "root用户已配置公钥数量: $(grep -c "^ssh-" /root/.ssh/authorized_keys)"
fi
if [ -n "$ORIGINAL_USER" ] && [ -f "/home/$ORIGINAL_USER/.ssh/authorized_keys" ]; then
    print_info "$ORIGINAL_USER用户已配置公钥数量: $(grep -c "^ssh-" /home/$ORIGINAL_USER/.ssh/authorized_keys)"
fi
[ -n "$TEMP_KEY_FILE" ] && print_info "新生成的私钥位置: $TEMP_KEY_FILE"

print_header "蜜罐信息"
print_info "Cowrie 端口: 2222"
print_info "安装目录: $COWRIE_INSTALL_DIR"
print_info "日志位置: $COWRIE_INSTALL_DIR/var/log/cowrie/"
if systemctl is-active --quiet cowrie; then
    print_success "Cowrie 服务运行状态: 正常运行"
else
    print_error "Cowrie 服务运行状态: 未运行"
fi

print_header "Fail2ban 状态"
if systemctl is-active --quiet fail2ban; then
    print_success "Fail2ban 服务: 正常运行"
    print_info "已激活的监狱: $(fail2ban-client status | grep "Jail list" | cut -d':' -f2)"
else
    print_error "Fail2ban 服务: 未运行"
fi

print_header "防火墙状态"
if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        print_success "UFW 防火墙: 已启用"
        echo "开放的端口:"
        ufw status | grep -E "ALLOW" | while read -r line; do
            if echo "$line" | grep -q "SSH"; then
                print_info "$line (SSH访问端口)"
            elif echo "$line" | grep -q "Cowrie"; then
                print_info "$line (蜜罐端口)"
            else
                print_info "$line"
            fi
        done
    else
        print_warning "UFW 防火墙: 已安装但未启用"
        print_info "建议执行: ufw enable"
    fi
    
    # 检查必要端口
    for port in "$FINAL_SSH_PORT" "2222"; do
        if ! ufw status | grep -q "^$port/tcp"; then
            print_warning "端口 $port 未在防火墙中配置"
        fi
    done
else
    print_warning "UFW 防火墙: 未安装"
    print_info "建议执行: apt install ufw"
fi

print_header "重要提示"
echo "1. 请确保记录以下信息："
print_info "SSH 端口: $FINAL_SSH_PORT"
[ -n "$TEMP_KEY_FILE" ] && print_info "SSH 私钥位置: $TEMP_KEY_FILE"
echo "2. 确保防火墙规则正确配置"
echo "3. 测试新的 SSH 配置前不要关闭当前会话"

print_header "常用命令"
echo "查看服务状态:"
print_info "systemctl status cowrie"
print_info "systemctl status fail2ban"
print_info "ufw status"
echo "查看日志:"
print_info "tail -f $COWRIE_INSTALL_DIR/var/log/cowrie/cowrie.log"
print_info "journalctl -u cowrie -f"
print_info "tail -f /var/log/fail2ban.log"

echo -e "\n\033[1;32m安装完成！如需帮助，请访问项目主页。\033[0m\n"
