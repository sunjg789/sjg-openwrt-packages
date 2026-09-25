# SJG OpenWrt 插件库（sjg-openwrt-packages）

你的个人 OpenWrt / ImmortalWrt 插件软件源：**一套源码清单 + GitHub Actions 自动编译 + GitHub Pages 托管**，同时产出 **opkg（24.10 系）** 与 **apk（25.12 系）** 两种格式的二进制包，编译固件（Image Builder）或运行中的固件都能直接安装。

## 工作原理

```text
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  plugins.conf（收录清单）     │        │  GitHub Actions（每周一自动） │
│  OpenClash / PassWall /     │───────▶│  ① 下载 ImmortalWrt SDK       │
│  Lucky / Argon / AdGuardHome│        │  ② clone 上游源码到 package/  │
│  OAF / DiskMan / DockerMan  │        │  ③ make .../compile 逐个编译  │
│  UnblockNeteaseMusic / etc  │        │  ④ 生成索引 + usign 签名      │
└─────────────────────────────┘        └──────────────┬───────────────┘
                                                      ▼
                              ┌────────────────────────────────────────┐
                              │ gh-pages 分支（GitHub Pages 静态托管）   │
                              │  repo/apk/x86_64/   *.apk + APKINDEX    │
                              │  repo/opkg/x86_64/  *.ipk + Packages    │
                              │  repo/keys/         public.key          │
                              └──────────────┬─────────────────────────┘
                                             ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │ 使用方：                                                          │
        │  · Image Builder 编译固件：repositories.conf 加一行源 → PACKAGES   │
        │  · 运行中固件：opkg update && opkg install / apk add 直接装        │
        └─────────────────────────────────────────────────────────────────┘
```

## 目录结构

```text
sjg-openwrt-packages/
├── plugins.conf                       # 收录清单（增删插件只改这一个文件）
├── scripts/
│   ├── fetch-and-build.sh             # 下载 SDK → 克隆源码 → 编译 → 收集包
│   └── gen-index.sh                   # 生成 Packages/Packages.gz 或 APKINDEX.tar.gz + 签名
├── .github/workflows/build-packages.yml  # 自动编译 + 发布 gh-pages
└── repo/                              # 构建产物（CI 生成，推送到 gh-pages 分支）
    ├── apk/x86_64/                    # ImmortalWrt 25.12.2（apk 包管理器）
    └── opkg/x86_64/                   # ImmortalWrt 24.10.6（opkg 包管理器）
```

## 已收录插件（plugins.conf）

| 插件 | 上游源 | 说明 |
|---|---|---|
| luci-app-openclash | vernesong/OpenClash | Clash 内核客户端 |
| luci-app-passwall | xiaorouji/openwrt-passwall | 科学上网（依赖 openwrt-passwall-packages 自动解析） |
| lucky + luci-app-lucky | gdy666/lucky | 网络工具集（端口转发/DDNS/Web服务） |
| luci-theme-argon + argon-config | jerrykuku/luci-theme-argon | Argon 主题 |
| luci-app-adguardhome | rufengsuixing/luci-app-adguardhome | AdGuardHome 插件（主程序运行后手动下载） |
| luci-app-oaf | destan19/OpenAppFilter | 上网行为管理（kmod 内核模块需官方源/源码编译） |
| luci-app-diskman | lisaac/luci-app-diskman | 磁盘管理 |
| luci-app-dockerman | lisaac/luci-app-dockerman | Docker 管理 |
| luci-app-unblockneteasemusic | UnblockNeteaseMusic/… | 解锁网易云音乐 |
| luci-app-partexp | gitee open-wrt/openwrt-packages | 分区扩展 |

> 说明：官方源已内置的（vlmcsd、ramfree、arpbind、ttyd、docker、wireguard、luci-ssl、taskbot、commands、adguardhome 等）不走自建库，直接用官方源即可。想新增插件：在 `plugins.conf` 加一行，推送到 main 分支即自动触发重建。

## 快速开始（约 5 分钟）

1. **在 GitHub 新建仓库**，名称建议 `sjg-openwrt-packages`，**必须 Public**（免费账号 Private 仓库无法开启 Pages）。
2. 把本目录全部文件推送上去：
   ```bash
   git init
   git add -A
   git commit -m "init"
   git branch -M main
   git remote add origin https://github.com/sunjg789/sjg-openwrt-packages.git
   git push -u origin main
   ```
3. **启用 Pages**：仓库 Settings → Pages → Source 选 **Deploy from a branch** → 分支 `gh-pages` / root → Save。
4. 到 **Actions** 页手动运行一次 `Build SJG Plugin Repo`（点 Run workflow）。opkg 与 apk 两个任务并行编译，首次约 30–60 分钟。
5. 构建完成后，你的软件源地址为：
   ```text
   apk 源 : https://sunjg789.github.io/sjg-openwrt-packages/apk/x86_64
   opkg 源: https://sunjg789.github.io/sjg-openwrt-packages/opkg/x86_64
   ```
   之后每周一自动重建，也可随时手动触发。

## 编译固件时直接使用（核心用法）

### ① Image Builder（推荐，配合你的 SJG 定制固件）

在你之前的构建脚本流程中，进入 Image Builder 目录后加一行源，然后 `PACKAGES` 里直接写插件名：

```bash
# 25.12 系（apk）Image Builder —— 编辑 repositories.conf 追加：
echo "src/gz sjg_custom https://sunjg789.github.io/sjg-openwrt-packages/apk/x86_64" >> repositories.conf

# 24.10 系（opkg）Image Builder —— 同样追加：
echo "src/gz sjg_custom https://sunjg789.github.io/sjg-openwrt-packages/opkg/x86_64" >> repositories.conf

# 然后正常 make image，PACKAGES 里加：
#   PACKAGES="... luci-app-openclash luci-app-passwall luci-app-lucky luci-theme-argon ..."
```

### ② 运行中的固件（旁路安装）

```bash
# 25.12 系（apk）
apk add --repository https://sunjg789.github.io/sjg-openwrt-packages/apk/x86_64 \
  luci-app-openclash luci-app-passwall

# 24.10 系（opkg）
echo "src/gz sjg_custom https://sunjg789.github.io/sjg-openwrt-packages/opkg/x86_64" \
  >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-openclash luci-app-passwall
```

### ③ 签名公钥（可选，未签名源多数固件也放行）

仓库会自动生成 usign 密钥（`repo/keys/`）。需要严格验签时，把 `public.key` 放进固件：

```bash
# apk 系
mkdir -p /etc/apk/keys && wget -O /etc/apk/keys/sjg.pub \
  https://sunjg789.github.io/sjg-openwrt-packages/keys/public.key

# opkg 系
mkdir -p /etc/opkg/keys && wget -O /etc/opkg/keys/sjg.pub \
  https://sunjg789.github.io/sjg-openwrt-packages/keys/public.key
```

> 若 `apk add` 报 untrusted，说明未配置公钥，加 `--allow-untrusted` 或安装公钥后重试。

## 与「SJG OpenWrt 在线定制站」联动

定制站已内置「自定义源地址」输入框（第 3 步「预装插件」底部）：把上面的源地址填入，生成的构建脚本会自动把 `src/gz sjg_custom <地址>` 追加到 `repositories.conf` 并优先安装，openclash / passwall / lucky 等插件即可从你的源装配。留空则回退到发行版官方源。

## 常见问题

| 问题 | 解答 |
|---|---|
| 私有仓库能用吗？ | Pages 需要 Public（免费版）。不想公开就用 GitHub Releases 托管，但目录不稳定，不推荐。 |
| kmod 内核模块能编译吗？ | SDK 不能编译内核模块（kmod-oaf 等），请用官方源或源码全编译。 |
| Actions 额度够吗？ | 一次全量约 30–60 分钟；私有仓库 2000 分钟/月，每周一次远用不完。 |
| 插件上游更新了怎么办？ | 每周一自动重建；也可以手动 Run workflow，或在 plugins.conf 改版本。 |
| 编译失败某个插件？ | 工作流日志会显示失败项，其余插件照常发布；把失败日志贴给我即可排查。 |
| 密钥安全吗？ | 签名密钥随源公开（个人源常见做法），防的是第三方篡改源；介意可自行改为私钥存 GitHub Secrets。 |
