# Cloudflare Xray Node

独立 Bash 管理脚本，用于在 Debian/Ubuntu VPS 上部署和维护：

- VLESS + WebSocket + TLS
- VMess + WebSocket + TLS
- VLESS + TCP + Reality + Vision

WS+TLS 节点用于配合 Cloudflare CDN 回源；Reality 节点是直连 TCP，不适合套 Cloudflare CDN。

## 支持范围

- Debian 10+
- Ubuntu 20.04+
- systemd
- root 用户运行安装、修改、删除、重启等动作

脚本会安装或更新 Xray 最新稳定版，并写入 `/usr/local/etc/xray/config.json`。
节点状态保存在 `/etc/cloudflare-xray-node/state.json`，分享链接保存在 `/root/xray-node-links.txt`。

为避免 `WS + TLS` 使用文件证书时和官方 `XTLS/Xray-install` 默认的 `nobody` systemd 用户发生读权限冲突，这个脚本会显式用 `root` 作为 Xray 安装用户。
如需覆盖，可自行设置环境变量 `CXN_XRAY_INSTALL_USER`。
无论你是填写现有证书路径还是直接粘贴 PEM，脚本都会把 `WS + TLS` 证书统一收拢到 `/usr/local/etc/xray/certs/`，并在重建配置时按 Xray 实际运行用户校正证书与日志目录权限。

## 使用

把脚本放到 VPS 后执行：

```bash
chmod +x install.sh
sudo ./install.sh menu
```

如果当前目录就是本项目目录：

```bash
sudo bash cloudflare-xray-node/install.sh menu
```

不带命令时默认进入菜单：

```bash
sudo bash cloudflare-xray-node/install.sh
```

也可以直接执行子命令：

```bash
sudo bash cloudflare-xray-node/install.sh install
sudo bash cloudflare-xray-node/install.sh list
sudo bash cloudflare-xray-node/install.sh add
sudo bash cloudflare-xray-node/install.sh modify
sudo bash cloudflare-xray-node/install.sh delete-all
sudo bash cloudflare-xray-node/install.sh links
sudo bash cloudflare-xray-node/install.sh restart
sudo bash cloudflare-xray-node/install.sh uninstall
```

命令说明：

- `menu`：打开交互菜单，默认命令。
- `install`：安装或更新 Xray，并重新初始化本脚本管理的节点。
- `list`：查看当前状态文件里的节点。
- `add`：新增 VLESS WS TLS、VMess WS TLS 或 Reality 节点。
- `modify`：按编号或 tag 修改已有节点。
- `delete-all`：清空所有已管理节点并重建空配置；不会删除证书文件。
- `links`：重新生成并显示分享链接。
- `restart`：重启 Xray 服务。
- `uninstall`：调用官方脚本移除 Xray，并删除本脚本状态和链接文件；卸载时会询问是否一并删除证书目录，回车默认删除。

安装和新增节点时，脚本会交互询问：

- 启用哪些协议
- UUID，默认自动生成
- Cloudflare 域名、客户端连接地址、WS path、Host/SNI
- 证书输入方式
- 各节点实际监听端口
- 当实际监听端口不是 Cloudflare 标准 HTTPS 代理端口时，额外询问客户端公开端口
- Reality 的客户端地址、端口和目标 SNI

安装完成后，节点链接保存在：

```text
/root/xray-node-links.txt
```

## 状态与管理

本脚本不是一次性安装器。所有已管理节点写入：

```text
/etc/cloudflare-xray-node/state.json
```

`install` 会重新初始化状态；`add`、`modify`、`delete-all` 会修改状态后重建 Xray 配置和分享链接。
重建配置前，脚本会先校验状态文件、证书/私钥是否存在且匹配，必要时把旧状态里的外部证书路径迁移到受控证书目录，然后执行 Xray 配置测试。
如果 `systemctl restart xray` 失败，脚本会直接输出最近的 `systemctl status` 和 `journalctl -u xray` 诊断信息，方便定位 TLS/权限/配置加载问题。

## 证书

WS+TLS 节点支持两种证书输入：

- 填写已有证书和私钥路径
- 粘贴 PEM 内容，由脚本保存到 `/usr/local/etc/xray/certs/`

不管用哪一种方式，实际运行时都会引用 `/usr/local/etc/xray/certs/` 下的受控副本，而不是长期直接依赖你最初填写的原始路径。

PEM 不是“不能带换行”。标准 PEM 文本编码本来就是：

```text
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

私钥常见格式包括：

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

也可能是 `RSA PRIVATE KEY` 或 `EC PRIVATE KEY`。脚本会自动识别 `-----END CERTIFICATE-----`、`-----END PRIVATE KEY-----`、`-----END RSA PRIVATE KEY-----`、`-----END EC PRIVATE KEY-----`，检测到 END 边界后结束粘贴读取。

脚本接受三种输入形态：

- 标准多行 PEM。
- 带字面 `\n` 的单行 PEM。
- 把 BEGIN、正文、END 放在一行的 PEM。

落盘前脚本会去掉正文空白，并按 64 字符重新分行；落盘后用 OpenSSL 解析证书和私钥，并比较二者公钥指纹，确认匹配后才写入 Xray 配置。

如果使用 Cloudflare Origin Certificate：

- 证书和私钥都粘贴到脚本提示位置
- Cloudflare SSL/TLS 模式建议设为 `Full` 或 `Full (strict)`
- 不要把私钥发给他人，脚本最终摘要不会回显证书内容

## WS Path

VLESS/VMess 的 WS Path 默认自动随机生成，例如 `/9f2c4e8a1b7d6c33`。
也可以手动填写，但必须满足：

- 以 `/` 开头。
- 不能只填 `/`。
- 不能包含空白字符。

随机路径参考 `v2ray-agent` 的路径生成习惯，避免生成以 `ws` 或 `vws` 结尾的路径，方便以后接入前置分流或迁移到更复杂的多协议布局。

## Cloudflare Origin Rule

如果使用视频里的“全端口回源”做法，常见配置是：

- 客户端连接 Cloudflare 支持代理的 HTTPS 端口，例如 `443`、`8443`、`2053`、`2083`、`2087`、`2096`
- 源站监听脚本里填写的节点端口
- 你自己在 Cloudflare Origin Rule 里按 `Host` 和 `Path` 把请求回源到对应节点端口

这版脚本仍然管理节点本身的实际监听端口，Cloudflare 回源映射由你自行配置。
如果节点实际端口本身就是 Cloudflare 支持代理的 HTTPS 端口，脚本默认直接把这个端口写进分享链接。
如果节点实际端口不是 Cloudflare 支持代理的 HTTPS 端口，脚本默认仍然把实际监听端口写进分享链接，保证“脚本搭完直接可连”。
只有当你显式填写不同的“客户端公开端口”时，脚本才会把分享链接改成该公开端口；这种情况下，你需要自己在 Cloudflare Origin Rule 或其他前置代理里把公开端口回源到实际监听端口。

## Reality

Reality 节点按 `xray-vless-reality` 的思路生成账号、Reality key 和链接：

- `network: tcp`
- `security: reality`
- `flow: xtls-rprx-vision`
- `realitySettings.dest`
- 默认目标 SNI：`learn.microsoft.com:443`
- 默认 shortId 和 x25519 key 从 UUID 派生，重装时使用相同 UUID 会得到相同 Reality 参数

Reality 不走 Cloudflare CDN。客户端需要使用脚本输出链接里的公钥 `pbk`，服务端配置里保存的是私钥。

## 参考项目取舍

这版脚本按以下方式吸收本地成熟项目：

- `xray-vless-reality`：沿用 Reality 的 `tcp + reality` 配置形态、UUID 派生 x25519 key、UUID 派生 shortId、`vless://...security=reality...pbk...sid...` 链接格式。
- `x-ui-yg-main`：沿用 WS 节点分享链接格式、`wsSettings.headers.Host` 和证书内容直贴写入文件的交互思路。
- `v2ray-agent`：吸收随机路径生成、读取已有配置继续管理、TLS 配置里的 `minVersion`、`alpn: ["http/1.1"]`、`ocspStapling`，以及写配置前先验证、旧配置备份的习惯。
- `Xray`：参考其 `add/change/info/del/manage/uninstall` 管理入口，本脚本提供 `menu/install/list/add/modify/delete-all/links/restart/uninstall`；使用官方 Xray-install 安装后执行 `xray run -test`，通过后再重启服务。

没有纳入 v1 的能力：

- 不做 x-ui 面板、数据库、订阅服务和用户管理。
- 不做 v2ray-agent 的 Nginx/Caddy 前置 fallback 聚合模式。
- 不自动申请 ACME 证书，只使用用户提供的证书路径或 PEM 内容。
- 不做 sing-box/Clash 订阅文件生成，只输出标准分享链接和二维码。

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

本地开发验证：

```bash
bash -n cloudflare-xray-node/install.sh
bash cloudflare-xray-node/tests/run_helper_tests.sh
bash cloudflare-xray-node/tests/run_state_tests.sh
```

`run_state_tests.sh` 只写临时目录，不安装 Xray，也不重启 systemd。
