# Cloudflare Xray Node

独立 Bash 脚本，用于在 Debian/Ubuntu VPS 上部署：

- VLESS + WebSocket + TLS
- VMess + WebSocket + TLS
- VLESS + TCP + Reality + Vision

WS+TLS 节点用于配合 Cloudflare CDN 回源；Reality 节点是直连 TCP，不适合套 Cloudflare CDN。

## 支持范围

- Debian 10+
- Ubuntu 20.04+
- systemd
- root 用户运行

脚本会安装或更新 Xray 最新稳定版，并写入 `/usr/local/etc/xray/config.json`。

## 使用

把脚本放到 VPS 后执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

如果当前目录就是本项目目录：

```bash
sudo bash cloudflare-xray-node/install.sh
```

脚本会交互询问：

- 启用哪些协议
- UUID，默认自动生成
- Cloudflare 域名、客户端连接地址、WS path、Host/SNI
- 证书输入方式
- 各节点源站监听端口和客户端连接端口
- Reality 的客户端地址、端口和目标 SNI

安装完成后，节点链接保存在：

```text
/root/xray-node-links.txt
```

## 证书

WS+TLS 节点支持两种证书输入：

- 填写已有证书和私钥路径
- 粘贴 PEM 内容，由脚本保存到 `/usr/local/etc/xray/certs/`

如果使用 Cloudflare Origin Certificate：

- 证书和私钥都粘贴到脚本提示位置
- Cloudflare SSL/TLS 模式建议设为 `Full` 或 `Full (strict)`
- 不要把私钥发给他人，脚本最终摘要不会回显证书内容

## Cloudflare Origin Rule

如果客户端端口和源站监听端口一致，通常只需要 Cloudflare 正常代理到源站端口。

如果使用视频里的“全端口回源”做法，常见配置是：

- 客户端连接 Cloudflare 支持的 HTTPS 端口，例如 `443`、`8443`、`2053`、`2083`、`2087`、`2096`
- 源站监听脚本里填写的端口
- 在 Cloudflare Origin Rule 中按 `Host` 和 `Path` 将流量回源到对应源站端口

脚本输出的分享链接使用“客户端连接地址”和“客户端连接端口”，Xray 服务端配置使用“源站监听端口”。

## Reality

Reality 节点按 `xray-vless-reality` 的思路生成账号、Reality key 和链接；服务端配置使用当前 Xray 文档里的字段：

- `network: raw`
- `security: reality`
- `flow: xtls-rprx-vision`
- `realitySettings.target`
- 默认目标 SNI：`learn.microsoft.com:443`
- 默认 shortId 和 x25519 key 从 UUID 派生，重装时使用相同 UUID 会得到相同 Reality 参数

Reality 不走 Cloudflare CDN。客户端链接仍按通用分享格式输出 `type=tcp`；客户端需要使用脚本输出链接里的公钥 `pbk`，服务端配置里保存的是私钥。

## 验证

脚本内部会在写入正式配置前执行：

```bash
xray run -test -c <临时配置文件>
```

通过后才会备份旧配置、写入新配置并重启：

```bash
systemctl restart xray
```

手动排查可用：

```bash
systemctl status xray --no-pager
ss -lntp
journalctl -u xray -n 100 --no-pager
```
