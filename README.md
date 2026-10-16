# Cloudflare DDNS 中文一键配置

首次运行按中文提示填写 API 令牌、主域名和解析记录，按回车使用默认值。脚本自动保存配置并立即更新 DNS，不需要编辑脚本或手动拼接参数。以后运行会读取配置，IP 没有变化时跳过 Cloudflare API 请求。

适用于已安装 Bash 4+ 的 Linux 系统，支持 IPv4（A）和 IPv6（AAAA）。需要 `curl`（7.55+）、`jq`，首次配置时会检测依赖，并询问是否通过系统包管理器安装。安装依赖可能需要 root 或 sudo 权限，日常运行不需要 root。

## 一键运行

将以下命令整行复制到服务器终端，按回车：

```bash
mkdir -p "$HOME/.local/bin" && curl -fSL https://raw.githubusercontent.com/GeorgeXie2333/cloudflare-api-v4-ddns/dev/cf-v4-ddns.sh -o "$HOME/.local/bin/cf-ddns.sh" && bash "$HOME/.local/bin/cf-ddns.sh"
```

如果已下载或克隆仓库，可直接运行：

```bash
bash cf-v4-ddns.sh
```

引导中需要填写：

1. **API 令牌**：在 [Cloudflare API 令牌页面](https://dash.cloudflare.com/profile/api-tokens)创建，授予「区域 → 区域 → 读取」和「区域 → DNS → 编辑」，区域资源选择需要更新的域名。不要填写 Global API Key。终端输入令牌时不会显示字符。
2. **主域名**：例如 `example.com`，填写 Cloudflare 中的区域名称。
3. **解析记录**：填 `@` 更新主域名，填 `home` 更新 `home.example.com`，也可填写完整域名。
4. **IP 类型**：直接回车选 `A`（IPv4），输入 `AAAA` 或 `6` 选 IPv6。IPv6 需要服务器有可用的公网 IPv6 网络。
5. **TTL**：直接回车选 `1`（自动），也可填写 `60`～`86400` 秒。

填写完成后会立即保存并执行一次。若对应记录不存在，会自动创建；已有记录保留小黄云代理和备注等设置，新记录默认关闭代理。主域名和已有记录的类型必须与所填内容对应，例如已有 CNAME 记录时，需先在 Cloudflare 中处理冲突。

## 自动更新和修改配置

首次更新成功后，如果系统有 `crontab`，脚本会询问是否启用每 5 分钟自动更新，直接回车即可启用。它只管理自己的任务，保留其他 crontab 条目，重复配置不会重复添加。请确保系统的 `cron` / `crond` 服务已启动。没有 `crontab` 时仍会完成本次更新；安装并启动 cron 后，重新配置即可添加定时任务。

再次手动更新（无交互）：

```bash
bash "$HOME/.local/bin/cf-ddns.sh" --run
```

修改已保存的参数（回车保留原值，令牌不会显示）：

```bash
bash "$HOME/.local/bin/cf-ddns.sh" --configure
```

使用克隆的仓库时，将上述路径改成 `cf-v4-ddns.sh` 即可。

默认文件位置：

| 文件 | 位置 |
| --- | --- |
| 配置（含 API 令牌，权限 `600`） | `~/.config/cloudflare-ddns/config.json` |
| 定时任务使用的脚本副本 | `~/.local/share/cloudflare-ddns/cf-v4-ddns.sh` |
| IP 缓存 | `~/.local/share/cloudflare-ddns/cache/` |
| 定时任务日志 | `~/.local/share/cloudflare-ddns/ddns.log` |

支持 `XDG_CONFIG_HOME` 和 `XDG_DATA_HOME`。请使用同一个系统用户运行和配置；换用 `sudo` 会使用 root 的配置目录。使用 `crontab -e` 删除带有 `# cloudflare-ddns:` 标记的对应条目，即可停止自动更新。修改配置时回答 `n` 表示本次不添加任务，不会删除已有任务。

API 令牌会作为 JSON 数据保存在本机，不会作为 Shell 脚本执行。请勿分享配置文件或提交到 Git 仓库。网络、鉴权或更新失败时不会写入成功的 IP 缓存；配置已经保存，可修正后重试 `--configure` 或直接用 `--run` 重试。

## 多个域名与原命令行用法

为其他域名指定独立配置文件，也可以同时配置 A 和 AAAA：

```bash
bash cf-v4-ddns.sh --configure --config "$HOME/.config/cloudflare-ddns/ipv6.json"
bash cf-v4-ddns.sh --run --config "$HOME/.config/cloudflare-ddns/ipv6.json"
```

兼容原有 `-k`、`-z`、`-h`、`-t`、`-f` 参数。命令行参数优先于配置文件，只在本次执行生效；需要保存时加 `--configure`。令牌直接写在命令里可能留在历史记录中，推荐使用向导输入。

```bash
bash cf-v4-ddns.sh -k '你的 API 令牌' -z example.com -h home.example.com -t A -f true
bash cf-v4-ddns.sh --run -f true
bash cf-v4-ddns.sh --help
```

`-h` 仍用于记录名称，查看帮助请使用 `--help`。IPv4、IPv6 和不同配置分别缓存，不会互相跳过更新。IP 通过 HTTPS 从 `ipv4.icanhazip.com` / `ipv6.icanhazip.com` 获取，Cloudflare API 使用 HTTPS 和证书校验。

## 本地检查

```bash
bash -n cf-v4-ddns.sh
python3 -m unittest discover -s tests -v
```

测试使用模拟的网络和 crontab，不会修改真实 DNS 或定时任务。
