# docker-wechat

在 Docker 里运行 Linux 版微信，并针对容器场景补强搜狗拼音输入法的可用性和稳定性。

这个项目基于原作者 [xiaoheiCat/docker-wechat-sogou-pinyin](https://github.com/xiaoheiCat/docker-wechat-sogou-pinyin) 继续整理和增强。上游项目解决了「Docker 里运行微信 + 搜狗拼音」这个核心问题，这个仓库则更偏向“适合自己长期使用和公开维护”的版本：保留原作者思路和链接，同时补齐本地构建、输入法恢复、Web/VNC 使用建议以及更适合发布到 GitHub 的仓库结构。

## 我这版重点增强

- 搜狗拼音默认激活，不再强依赖手动切换热键。
- 容器启动时补强 `D-Bus`、`fcitx`、`X11` 相关初始化逻辑，减少输入法起不来的情况。
- 增加 `fcitx` 健康检查和自动拉起逻辑，尽量避免输入法进程消失后只能重启容器。
- 针对 `noVNC` / 浏览器访问场景做了额外兼容，优先保证直接输入拼音时能用。
- 支持直接本地构建，不再依赖 CI 预先产出 `temp-packages/`。
- 保留多架构构建工作流，方便后续推送到 `GHCR`。

## 上游来源与说明

- 上游仓库：<https://github.com/xiaoheiCat/docker-wechat-sogou-pinyin>
- 当前仓库保留原作者项目链接和许可证。
- Dockerfile 默认仍会使用上游 release 中提供的搜狗拼音安装包；如果你后续在自己仓库维护安装包，也可以通过构建参数改成自己的下载地址。

## 仓库内容说明

适合公开仓库的核心文件主要是这些：

- `Dockerfile`
- `docker-compose.yml`
- `startapp-enhanced.sh`
- `.github/workflows/docker.yml`
- `LICENSE`
- `.gitignore`
- `temp-packages/.gitkeep`

像 `datas/` 这种运行时数据目录、微信缓存、登录信息、聊天文件和本地日志，不适合提交到公开仓库，应该排除在版本控制之外。

## 快速开始

### 本地构建

```bash
docker build -t wechat-fixed:latest .
```

如果你在中国大陆，默认会使用阿里云 Ubuntu 镜像源加速构建。

如果你不想使用镜像源，可以切回官方源：

```bash
docker build \
  --build-arg APT_MIRROR_MODE=official \
  -t wechat-fixed:latest .
```

### 使用 Docker Compose

```bash
docker compose up -d --build --force-recreate
```

推荐的 `docker-compose.yml`：

```yaml
services:
  wechat:
    build:
      context: .
    image: wechat-fixed:latest
    container_name: wechat-fixed
    privileged: true
    shm_size: "1gb"
    volumes:
      - ./datas/xwechat-config:/root/.xwechat
      - ./datas/xwechat_files:/root/xwechat_files
      - ./datas/downloads:/root/downloads
    ports:
      - "5800:5800"
      - "5900:5900"
    restart: unless-stopped
    environment:
      - LANG=zh_CN.UTF-8
      - KEEP_APP_RUNNING=0
      - USER_ID=0
      - GROUP_ID=0
      - DARK_MODE=1
      - WEB_AUDIO=1
      - TZ=Asia/Shanghai
```

### 使用 Docker Run

```bash
docker run -d \
  --name wechat-fixed \
  --privileged \
  --shm-size=1g \
  -v $(pwd)/datas/xwechat-config:/root/.xwechat \
  -v $(pwd)/datas/xwechat_files:/root/xwechat_files \
  -v $(pwd)/datas/downloads:/root/downloads \
  -p 5800:5800 \
  -p 5900:5900 \
  -e LANG=zh_CN.UTF-8 \
  -e KEEP_APP_RUNNING=0 \
  -e USER_ID=0 \
  -e GROUP_ID=0 \
  -e DARK_MODE=1 \
  -e WEB_AUDIO=1 \
  -e TZ=Asia/Shanghai \
  wechat-fixed:latest
```

## 输入法使用建议

### 浏览器访问 `5800`

如果你通过 `http://localhost:5800` 使用 noVNC，macOS、浏览器和 noVNC 本身都可能拦截 `Option` / `Alt` / `Ctrl+Space` 之类的输入法切换热键。所以这版镜像的策略不是依赖热键，而是尽量在容器内部持续保持搜狗拼音处于可用状态。

建议操作方式：

- 先点进微信输入框。
- 直接输入拼音。
- 尽量不要把输入法切换成功与否建立在浏览器热键透传上。

### 原生 VNC 访问 `5900`

如果你主要想稳定输入中文，优先推荐原生 VNC 客户端连接 `5900`。相比浏览器里的 noVNC，这种方式通常更稳定，尤其是在 macOS 环境下。

## 构建与发布

仓库保留了一个用于发布多架构镜像的工作流：

- `.github/workflows/docker.yml`

这个工作流会：

- 构建 `linux/amd64` 和 `linux/arm64` 镜像。
- 登录 `GHCR`。
- 推送 `latest` 和基于 commit SHA 的 tag。

如果你准备把它作为自己的 GitHub 仓库发布，通常只需要：

1. 在 GitHub 创建新仓库。
2. 把当前目录中的公开文件推送上去。
3. 启用 Actions。
4. 直接使用仓库自带的 `GITHUB_TOKEN` 推送到 `ghcr.io/<你的用户名>/<你的仓库名>`。

## 常用环境变量

| 环境变量 | 说明 | 默认值 |
|---|---|---|
| `LANG` | 容器语言环境。建议中文场景下用 `zh_CN.UTF-8`。 | `en_US.UTF-8` |
| `TZ` | 容器时区。 | `Asia/Shanghai` |
| `KEEP_APP_RUNNING` | 设为 `1` 时应用退出后自动重启。搜狗输入法场景下不建议依赖它做保活。 | `0` |
| `DISPLAY_WIDTH` | 桌面宽度。 | `1920` |
| `DISPLAY_HEIGHT` | 桌面高度。 | `1080` |
| `DARK_MODE` | 启用深色模式。 | `0` |
| `WEB_AUDIO` | 浏览器访问时启用音频。 | `0` |
| `WEB_AUTHENTICATION` | 设为 `1` 时，浏览器访问 `5800` 会先进入登录页。需要同时启用 `SECURE_CONNECTION=1`。 | `0` |
| `WEB_AUTHENTICATION_USERNAME` | Web 登录保护的用户名。适合单用户快速配置。 | 无 |
| `WEB_AUTHENTICATION_PASSWORD` | Web 登录保护的密码。适合单用户快速配置。 | 无 |
| `VNC_PASSWORD` | 原生 VNC 连接密码。 | 无 |
| `SECURE_CONNECTION` | 启用 Web/VNC 加密连接。 | `0` |

## Web 登录保护

`WEB_AUTHENTICATION`、`WEB_AUTHENTICATION_USERNAME` 和 `WEB_AUTHENTICATION_PASSWORD` 仍然有效，但它们不是由本仓库脚本自己处理，而是由基础镜像 `jlesage/baseimage-gui` 提供。

需要注意：

- 只有浏览器访问的 Web 界面会受这组变量保护。
- 要生效，必须同时设置 `SECURE_CONNECTION=1`，即通过 HTTPS 访问。
- 如果只开 `WEB_AUTHENTICATION=1` 而不开 `SECURE_CONNECTION=1`，Web 认证不会按预期工作。

示例：

```yaml
services:
  wechat:
    environment:
      - SECURE_CONNECTION=1
      - WEB_AUTHENTICATION=1
      - WEB_AUTHENTICATION_USERNAME=admin
      - WEB_AUTHENTICATION_PASSWORD=change-this-password
```

## 目录与数据

- `datas/xwechat-config`：微信配置与登录状态。
- `datas/xwechat_files`：微信产生的文件与缓存。
- `datas/downloads`：容器内下载目录。

这些目录都属于运行时数据，不建议提交到 GitHub。首次运行时不存在也没关系，Docker 会自动创建。

## 演示

- <https://b23.tv/ihPZQaa>
- <https://youtu.be/1zqcNArcZBA>

## 致谢

- 原始思路与基础实现来自 [xiaoheiCat/docker-wechat-sogou-pinyin](https://github.com/xiaoheiCat/docker-wechat-sogou-pinyin)
- 基础 GUI 镜像来自 `jlesage/baseimage-gui`

## Star History

[![Star History Chart](https://api.star-history.com/image?repos=whynottogo/docker-wechat&type=date&legend=top-left)](https://www.star-history.com/?repos=whynottogo%2Fdocker-wechat&type=date&legend=top-left)

