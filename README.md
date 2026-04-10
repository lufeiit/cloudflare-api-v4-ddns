# CloudFlare Dynamic DNS Updater (DDNS)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)

一个功能完整的 **CloudFlare DDNS** 客户端，用 Bash 编写。自动将你的公网 IP（IPv4 / IPv6）更新到 CloudFlare DNS 记录中，支持**自动创建缺失记录**、**中文域名（Punycode）**、**日志记录**和**本地缓存**，适合部署在路由器、树莓派、NAS 或任何 Linux 主机上。

## 功能特性

- ✅ 支持 **IPv4 (A)** 和 **IPv6 (AAAA)** 记录
- ✅ 自动创建 DNS 记录（如果子域名不存在）
- ✅ 中文域名自动转换为 Punycode（需 `idn` 或 Python）
- ✅ 本地 IP 缓存，避免频繁调用 API
- ✅ 缓存 Zone ID 和 Record ID，提升速度
- ✅ 强制更新开关 (`-f true`)
- ✅ 完整的日志记录（stderr + syslog）
- ✅ IP 合法性校验（防止错误 IP 传播）
- ✅ 错误处理完善（API 失败、网络超时等）
- ✅ 单一脚本，无外部依赖（除 curl 和基础工具）

## 依赖

- `bash` 4.0+
- `curl`
- `grep`, `sed`, `logger`（通常系统自带）
- 可选：`idn`（GNU libidn）或 `python3`，用于中文域名转换。如果缺失，中文域名可能无法正常工作。

安装依赖（以 Debian/Ubuntu 为例）：
```bash
sudo apt update
sudo apt install curl idn  # idn 用于中文域名转换
