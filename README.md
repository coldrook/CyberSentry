# CyberSentry

[English](./README_EN.md) | 简体中文

一个综合性的网络安全防御系统，集成了蜜罐、入侵检测、安全加固等多重防护机制。
移植自https://github.com/CurtisLu1/CyberSentry
修改仅生成密钥对（256位 ed25519）并增加fail2ban存在逻辑判断，
发现不同vps因系统不同出现不同的bug，尝试使用AI进行测试修复
由于vps及个人精力有限，未能全面测试，有其他bug也不会修！！！


## 核心功能

1. 蜜罐系统
   - SSH 蜜罐
   - 攻击者行为记录
   - 攻击模式分析

2. 安全防护
   - Fail2ban 集成
   - 系统加固
   - 自动封禁

3. 日志管理
   - 自动日志轮转
   - 智能清理
   - 分析报告

4. 系统监控
   - 实时监控
   - 异常检测
   - 告警通知

## 特点
- 一键部署
- 全自动化运维
- 完整审计追踪
- 智能防御响应

## 快速开始

### 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/coldrook/CyberSentry/refs/heads/main/install.sh)
```

### 系统要求

- Debian/Ubuntu 系统
- Root 权限
- Python 3.9+ (如果系统 Python 版本低于 3.9，将自动升级)
  - Debian 10: 通过 backports 源安装
  - Debian 11/12: 通过官方源安装
  - Ubuntu: 通过 deadsnakes PPA 安装

## 功能特点

- 自动部署 Cowrie SSH 蜜罐
- 集成 Fail2ban 防护
- 自动日志清理（默认保留30天）
- 系统日志自动轮转
- 服务自动启动
- SSH 安全配置（可选）：
  - 端口配置：
    - 默认保持现有配置
    - 随机生成（10000-65535）
    - 手动指定（1024-65535）
  - 认证方式：
    - 保持现有配置
    - 仅密钥认证
    - 密码+密钥认证
  - 密钥管理：
    - 保持现有密钥
    - 导入新公钥
    - 自动生成新密钥对
- UFW 防火墙配置（可选）：
  - 自动配置必需端口（SSH和蜜罐）
  - 智能规则管理（自动处理端口变更）
  - 详细规则处理：
    - 自动添加和删除规则
    - 规则冲突检测
    - 规则优先级管理

## 安装过程

1. 环境检查：
   - 系统兼容性验证
   - Python 环境检测
   - 必需命令检查
2. 依赖安装：
   - fail2ban
   - Python virtualenv
   - 其他必需包
3. 组件配置：
   - Cowrie 蜜罐（端口 2222）
   - Fail2ban 防护
   - 日志清理（每日凌晨2点）
4. 安全配置：
   - SSH 端口配置
   - 认证方式设置
   - 密钥管理
   - 防火墙规则

## 配置说明

### Fail2ban 配置
- 封禁时间：24小时（86400秒）
- 检测窗口：5分钟（300秒）
- 最大重试：3次
- 监控日志：auth.log 和 cowrie.log

### SSH 配置选项
- 端口选择：
  - 保持现有端口
  - 随机端口（10000-65535）
  - 手动指定（1024-65535）
- 认证方式：
  - 保持现有配置
  - 仅密钥认证
  - 密码+密钥认证
- 密钥选项：
  - 保持现有密钥
  - 导入新公钥
  - 生成新密钥对（256位 ed25519）

### 防火墙设置
- 自动配置 SSH 端口
- 自动配置蜜罐端口（2222）
- 智能规则管理
- 可选启用 UFW
- 详细规则处理：
  - 自动添加和删除规则
  - 规则冲突检测
  - 规则优先级管理

## 日志管理

### 日志位置
- Cowrie 日志：`/opt/cowrie/var/log/cowrie/`
- Fail2ban 日志：`/var/log/fail2ban.log`
- 系统日志：`/var/log/`
- 清理日志：`/var/log/cleanup.log`

### 日志轮转
- 每周轮转
- 保留4个版本
- 自动压缩
- 自动清理30天前的日志

## 配置备份

### 备份策略
- 备份位置：`/root/config_backups/`
- 命名格式：`配置文件名.YYYYMMDD_HHMMSS.bak`
- 保留策略：每个配置保留最近3-5个版本
- 自动清理：删除过期备份

### 备份内容
- SSH配置：`sshd_config` 备份
- Fail2ban配置：`jail.local` 备份
- 每次修改配置前自动创建备份
- 支持配置回滚

### 备份管理

## 服务管理

```bash
# 状态查看
systemctl status cowrie
systemctl status fail2ban
ufw status

# 日志查看
tail -f /opt/cowrie/var/log/cowrie/cowrie.log
journalctl -u cowrie -f
tail -f /var/log/fail2ban.log

# 服务控制
systemctl start|stop|restart cowrie
systemctl start|stop|restart fail2ban
```

## 安全建议

1. 安装完成后：
   - 保存显示的 SSH 端口号
   - 备份生成的 SSH 密钥（如果有）
   - 测试新配置前保留当前会话
2. 防火墙配置：
   - 确保必要端口已开放
   - 建议启用 UFW
   - 定期检查防火墙规则
3. 日常维护：
   - 定期检查系统日志
   - 监控蜜罐日志
   - 及时更新系统

## 卸载方法

```bash
# 停止服务
systemctl stop cowrie
systemctl disable cowrie

# 删除文件
rm -rf /opt/cowrie
rm /etc/systemd/system/cowrie.service

# 重载服务
systemctl daemon-reload
```

## 许可证

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## 贡献指南

欢迎通过以下方式贡献：
- 提交 Issue
- 提交 Pull Request
- 完善文档
- 分享使用经验

## 问题反馈

如遇问题，请提供以下信息：
1. 系统版本
2. Python 版本
3. 错误信息
4. 相关日志
