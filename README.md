# 介绍

最好用的 sing-box 一键安装脚本 & 管理脚本

# 特点

- 快速安装
- 无敌好用
- 零学习成本
- 自动化 TLS
- 简化所有流程
- 兼容 sing-box 命令
- 强大的快捷参数
- 支持所有常用协议
- 一键添加 VLESS-REALITY (默认)
- 一键添加 TUIC
- 一键添加 Trojan
- 一键添加 Hysteria2
- 一键添加 AnyTLS
- 一键添加 Shadowsocks 2022
- 一键添加 VMess-(TCP/HTTP/QUIC)
- 一键添加 VMess-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 VLESS-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 Trojan-(WS/H2/HTTPUpgrade)-TLS
- 一键启用 BBR
- 一键更改伪装网站
- 一键更改 (端口/UUID/密码/域名/路径/加密方式/SNI/等...)
- 还有更多...

# 设计理念

设计理念为：**高效率，超快速，极易用**

脚本基于作者的自身使用需求，以 **多配置同时运行** 为核心设计

并且专门优化了，添加、更改、查看、删除、这四项常用功能

你只需要一条命令即可完成 添加、更改、查看、删除、等操作

例如，添加一个配置仅需不到 1 秒！瞬间完成添加！其他操作亦是如此！

脚本的参数非常高效率并且超级易用，请掌握参数的使用

# 文档

安装及使用：https://233boy.com/sing-box/sing-box-script/

# 帮助

使用：`sing-box help`

```
sing-box script v1.0 by 233boy
Usage: sing-box [options]... [args]...

基本:
   v, version                                      显示当前版本
   ip                                              返回当前主机的 IP
   pbk                                             同等于 sing-box generate reality-keypair
   get-port                                        返回一个可用的端口
   ss2022                                          返回一个可用于 Shadowsocks 2022 的密码

一般:
   a, add [protocol] [args... | auto]              添加配置
   c, change [name] [option] [args... | auto]      更改配置
   d, del [name]                                   删除配置**
   i, info [name]                                  查看配置
   qr [name]                                       二维码信息
   url [name]                                      URL 信息
   log                                             查看日志
更改:
   full [name] [...]                               更改多个参数
   id [name] [uuid | auto]                         更改 UUID
   host [name] [domain]                            更改域名
   port [name] [port | auto]                       更改端口
   path [name] [path | auto]                       更改路径
   passwd [name] [password | auto]                 更改密码
   key [name] [Private key | auto] [Public key]    更改密钥
   method [name] [method | auto]                   更改加密方式
   sni [name] [ ip | domain]                       更改 serverName
   new [name] [...]                                更改协议
   web [name] [domain]                             更改伪装网站

进阶:
   dns [...]                                       设置 DNS
   dd, ddel [name...]                              删除多个配置**
   fix [name]                                      修复一个配置
   fix-all                                         修复全部配置
   fix-caddyfile                                   修复 Caddyfile
   fix-config.json                                 修复 config.json
   import                                          导入 sing-box/v2ray 脚本配置

管理:
   un, uninstall                                   卸载
   u, update [core | sh | caddy] [ver]             更新
   U, update.sh                                    更新脚本
   s, status                                       运行状态
   start, stop, restart [caddy]                    启动, 停止, 重启
   t, test                                         测试运行
   reinstall                                       重装脚本

测试:
   debug [name]                                    显示一些 debug 信息, 仅供参考
   gen [...]                                       同等于 add, 但只显示 JSON 内容, 不创建文件, 测试使用
   no-auto-tls [...]                               同等于 add, 但禁止自动配置 TLS, 可用于 *TLS 相关协议
其他:
   bbr                                             启用 BBR, 如果支持
   bin [...]                                       运行 sing-box 命令, 例如: sing-box bin help
   [...] [...]                                     兼容绝大多数的 sing-box 命令, 例如: sing-box generate uuid
   h, help                                         显示此帮助界面

谨慎使用 del, ddel, 此选项会直接删除配置; 无需确认
反馈问题) https://github.com/233boy/sing-box/issues
文档(doc) https://233boy.com/sing-box/sing-box-script/
```
---

# Fork 说明（proxyaio）

本仓库是 `233boy/sing-box` 的 fork，供 [proxyAIO](https://github.com/semsdawn/proxyAIO) 面板调用。**人类交互（菜单、prompt、颜色、快捷参数）与上游一致，未做破坏性改动。**

## 机器通道：`sb api …`

给面板/自动化用的通道，**stdout 只输出一个 JSON 对象**，人类提示走 stderr；退出码即契约。

```bash
sb api version                 # 版本与能力（sh_ver / fork_ver / core_ver / features）
sb api list                    # 全部配置文件摘要
sb api show <file|tag>         # 整份配置（--raw 只输出原文）
sb api get <file> <jq路径>      # 任意路径取值
sb api check <file>            # sing-box check 结构化结果
sb api port free               # 分配空闲端口
sb api restart                 # 重启并返回 is-active
sb api outbound set|unset ...  # 写入/移除出口配置（凭据只走 stdin）
```

输出格式：

```json
{"ok":true,"cmd":"outbound.set","data":{...},"warnings":[]}
{"ok":false,"cmd":"add","code":"NEED_INPUT","message":"缺少端口","hint":"sb add r 39049"}
```

退出码：`0` 成功 / `2` 需要交互或参数不足 / `3` 校验或执行失败 / `4` 未找到 / `1` 其它。

## 约定

- **凭据永不进 argv、永不回显、永不写日志**；需要认证的操作从 stdin 读 JSON。
- 备份与临时文件落 `/etc/sing-box/backup/`，**不写入 conf 目录**（`sb` 会枚举 conf 目录，混入 `.bak` 会导致交互式选择失败）。
- 定制提交保持小而可读，便于 `git rebase upstream/main`。
