# Cloudflare Xray Node



# 脚本安装支持的协议

- VLESS + WebSocket + TLS
- VMess + WebSocket + TLS
- VLESS + XHTTP + TLS
- VLESS + TCP + Reality + Vision

WS/XHTTP TLS 节点用于配合 Cloudflare CDN 回源；Reality 节点是直连 TCP，不适合套 Cloudflare CDN。

## 支持范围

- Debian 10+
- Ubuntu 20.04+

脚本会安装或更新 Xray 最新稳定版，并写入 `/usr/local/etc/xray/config.json`。
安装时会优先调用官方 `XTLS/Xray-install`；如果 GitHub API 或官方安装链路不可用，会自动回退到 GitHub release 直链安装。
节点状态保存在 `/etc/cloudflare-xray-node/state.json`，分享链接保存在 `/root/xray-node-links.txt`。

无论你是填写现有证书路径还是直接粘贴 PEM，脚本都会把 CDN TLS 节点证书统一收拢到 `/usr/local/etc/xray/certs/`，并在重建配置时按 Xray 实际运行用户校正证书与日志目录权限。

## 使用

把脚本放到 VPS 后执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/tuneu/cf_xray/main/cfxray.sh)
```

或者 `curl`
```
bash <(curl -fsSL https://raw.githubusercontent.com/tuneu/cf_xray/main/cfxray.sh)
```



也可以直接执行子命令：

```bash
sudo bash cloudflare-xray-node/cfxray.sh install
sudo bash cloudflare-xray-node/cfxray.sh update-xray
sudo bash cloudflare-xray-node/cfxray.sh list
sudo bash cloudflare-xray-node/cfxray.sh add
sudo bash cloudflare-xray-node/cfxray.sh modify
sudo bash cloudflare-xray-node/cfxray.sh delete-all
sudo bash cloudflare-xray-node/cfxray.sh links
sudo bash cloudflare-xray-node/cfxray.sh restart
sudo bash cloudflare-xray-node/cfxray.sh uninstall
```

命令说明：

- `menu`：打开交互菜单，默认命令。
- `install`：安装或更新 Xray，并重新初始化本脚本管理的节点。
- `update-xray`：独立检查并更新 Xray Core 和 geodata；不会重新初始化节点。
- `list`：查看当前状态文件里的节点。
- `add`：新增 VLESS WS TLS、VMess WS TLS、VLESS XHTTP TLS 或 Reality 节点。
- `modify`：按编号或 tag 修改已有节点。
- `delete-all`：清空所有已管理节点并重建空配置；不会删除证书文件。
- `links`：重新生成并显示分享链接。
- `restart`：重启 Xray 服务。
- `uninstall`：调用官方脚本移除 Xray，并删除本脚本状态和链接文件；卸载时会询问是否一并删除证书目录，回车默认删除。

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

## 证书

WS/XHTTP TLS 节点支持两种证书输入：

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
- Cloudflare SSL/TLS 模式建议设为 `Full` 

## Reality

Reality 节点按 `xray-vless-reality` 的思路生成账号、Reality key 和链接：

- `network: tcp`
- `security: reality`
- `flow: xtls-rprx-vision`
- `realitySettings.dest`
- 默认目标 SNI：`apple.com`（未填写端口时默认 `443`）
- 默认 shortId 和 x25519 key 从 UUID 派生，重装时使用相同 UUID 会得到相同 Reality 参数

Reality 不走 Cloudflare CDN。客户端需要使用脚本输出链接里的公钥 `pbk`，服务端配置里保存的是私钥。



# 使用教程

# 准备

* 一个托管在CloudFlare的全功能的域名，千万不要使用双向解析的域名
* 一台VPS (IPv6和IPv4都可以)

 

# CF设置域名

打开 `https://dash.cloudflare.com/` 进入你所想使用的域名管理界面

1. 点击 `DNS` -- `记录` 添加你的 VPS IP 记得打开小黄云（ `代理状态` 显示为 `已代理` ）

2. 点击 `SSL/TLS` -- `概述`  把它调整为 `完整` （英文状态下的名字叫做 `Full` ）

3. 点击 `SSL/TLS` -- `边缘证书` 下翻，找到 `始终使用 HTTPS` 和 ` 自动 HTTPS 重写` 保持这两项打开，因为我们使用 TLS

4. 点击 `SSL/TLS` -- `源服务器` --`创建证书` 有效期选择 15 年，默认值不用动，直接创建。把我们的证书和密钥复制保存好。

   这默认值申请的证书，我们的一个域名下面的所有服务都可以使用这一套证书。

# 部署节点

## 安装脚本

```bash
bash <(wget -qO- https://raw.githubusercontent.com/tuneu/cf_xray/main/cfxray.sh)
```

或者 `curl`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tuneu/cf_xray/main/cfxray.sh)
```

![1](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/1.png)

输入 `1` 回车

![2](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/2.png)

下面我使用 VLESS + WebSocket + TLS 这一个来做例子

其实不套TLS也能用，但是有CF的证书白嫖，套了TLS怎么说都安全些，本脚本就只做了套TLS的



UUID 可以直接回车，使用默认值是自动生成的



![3](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/3.png)

填写托管到 CF, 并且解析到此服务器 IP 的域名



![4](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/4.png)

填写你的优选域名/IP了。（可以理解为，这个就是中转的域名/ IP）

这里只是便于脚本输出的节点链接是已经套上 CDN直接可以使用的，后面我们搭建出来的节点也可以使用这里任意优选域名/IP，不用再次在脚本里面修改配置。



![5](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/5.png)

填写我们客户端连接中转服务器的端口，可以填写这里列出来的所有值，默认为443。

这里只是便于便于脚本输出的节点链接是已经套上 CDN直接可以使用的，后面我们搭建出来的节点也可以使用这里列出来的任意端口。不用再次在脚本里面修改配置。



![6](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/6.png)

这一个填写的端口，就是你服务器的 Xray 实际监听的端口。也就是说，如果你用直连的话，是直接使用这一个端口。如果我们服务器有`443`、`8443`、`2053`、`2083`、`2087`、`2096`这一些端口可以使用的话，上面那一个端口和这一个端口可以写同一个，就不用进行回源操作了。



接下来的两个，`Path`和`Host/SNI`，直接默认回车就可以了。我也懒得截图了。



## 证书配置

无论你是填写现有证书路径还是直接粘贴 PEM，脚本都会把 CDN TLS 节点证书统一收拢到 `/usr/local/etc/xray/certs/`，并在重建配置时按 Xray 实际运行用户校正证书与日志目录权限。

![7](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/7.png)

我更推荐使用第一个方式，粘贴证书内容。也就是我们之前生存的保存好的15年证书

脚本接受三种输入形态：

- 标准多行 PEM。
- 带字面 `\n` 的单行 PEM。
- 把 BEGIN、正文、END 放在一行的 PEM

![8](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/8.png)

```text
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

按回车进行下一步 填写密钥

![9](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/9.png)

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

弄完这里就会输出节点链接了




# CF回源

![6](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/6.png)

过当时填写这一步填写的是其他随机端口的话，还需要去 C F 进行回源操作。

打开 `https://dash.cloudflare.com/` 进入你所使用的域名管理界面

左侧 `规则` -- `概述`-- `Origin Rules`(`源服务器规则`、`更改端口`) 这个东西名字太多了，下面给一些图片

<img src="https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/10.png" alt="10" style="zoom:50%;" />

<img src="https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/11.png" alt="11" style="zoom:50%;" />

点击`创建规则`进去，规则名称自定义，能记住就好

`自定义筛选表达式` --  字段为 `主机名` -- `运算符`为等于 -- 值 就是你之前解析你服务器的IP的域名，也就是前面你在下面填写的这个域名

![3](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/3.png)

再点击 `And` --字段为 `SSL/HTTPS` -- `开启`

`目标端口`-- `重写到` --这里的端口就填写，之前这一步的端口，这也就是回源的操作

![6](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/6.png)

再次点击部署就完成了

附上此页面的完整图片

<img src="https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/12.png" alt="12" style="zoom:50%;" />

这下就完成了，不过既然有免费的中转使用了，为什么不多弄几个呢，来进行负载均衡



# 节点裂变

我这里搭配 `Sub-Store`来使用

在`Sub-Store`里面添加一个 `单条订阅` 

把我们的VPS输出的节点链接给填到`本地订阅` 里面

添加`脚本操作`

![13](https://raw.githubusercontent.com/tuneu/cf_xray/main/assets/13.png)

选择`本地内容` ，清空里面的内容

复制我们下面链接的文本，粘贴进去

https://raw.githubusercontent.com/tuneu/cf_xray/main/substore_cf.js

## 节点裂变脚本说明

脚本顶部是用来填写参数的

```js
const CONFIG = {
  keepOriginal: false,
  targets: [
    'www.wto.org#wto',
    'www.visa.com.sg#visa',
  ],

  // Optional: fetch target list from URLs. Each line: host[:port]#alias
  urls: [
    'https://eg1.com/cu',
    'https://eg2.com/',
  ],
  urlTimeout: 5000,
};
```

下面对这里面的两个进行一些说明。

1.  targets

```js
 targets: [
    'www.wto.org#wto',
    'www.visa.com.sg#visa',
  ],
```

这一个填写的是
`优选域名/IP`   `#`  `别名`

说一下别名
我们的这个脚本输出的节点名称是

- VLESS + WebSocket + TLS   --------> `vl_主机名`
- VMess + WebSocket + TLS.  --------> `vm_主机名`
- VLESS + XHTTP + TLS       --------> `xhttp_主机名`

我们的别名是把井号的内容添加到协议前缀和 `主机名_`之间，并自动加一个 `-`

来举一个例子吧

默认输出的节点名字是 `vl_JP`

设置了`www.wto.org#wto`

最终输出的节点的名字就会变为`vl-wto_JP`

如果别名相同，就会输出为 `别名⁰、别名¹、别名²、别名³`

这种设计是便于我们使用正则表达式 `^vl-.*_主机名$`，来做节点筛选，弄负载均衡

2. urls

```js
  urls: [
    'https://eg1.com/',
    'https://eg2.com/',
  ],
```

这个里面就是填写，从URL获取，优选域名和节点

URL内容是这样的
```txt
1.1.1.1#别名1
2.2.2.2#别名2
3.3.3.3#别名3
```

大家可以自己本地跑好优选域名，然后上传到一个固定的网址，或者找别人弄好的

这个玩法很多，我自己是这么用的。大家有更好的方案也可以分享一下。

脚本是把节点转换为clash的类型然后修改的，所以vmess和vless都能用这个。

每个人的使用场景不同，拿着脚本直接叫AI改就行，欢迎大家分享自己的玩法



# 参考教程

CM 全端口回源设置：https://www.youtube.com/watch?v=Q8psxqYklZQ

CM IPv6全端口回源：https://www.youtube.com/watch?v=S1Ilq69teVI

CM 博客https://cmliussss.com/p/CM19

本教程类似于甬哥影片里的第二个方案，也有其他的方案可以学习：https://www.youtube.com/watch?v=RnUT1CNbCr8 
