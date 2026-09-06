# dsh-deploy

一键部署 dsh web harness（dsh 0.1.1-rc.2 + 11 插件 + 可配置 LLM provider/key + user-management HTTPS gateway）到 Linux 服务器。LLM provider 默认 MiniMax 示例（开箱即跑），可换 deepseek/openai/zhipu 等任意 provider。

## 两种用法

**交互式（推荐，让 AI 引导）**：把整个文件夹交给一个 dsh / AI agent，它按 [`SKILL.md`](./SKILL.md) 一次性问全你（LLM provider + key、公网访问 IP、域名、本机装还是 scp 到远程、服务器+密码），然后统一执行——你不用逐条敲命令。

**手动**：
```bash
cp credentials.yaml.example credentials.yaml     # 复制 key 模板
# 编辑 credentials.yaml，把 <your-api-key> 换成你的 LLM provider key（minimax 走 MINIMAX_CN_API_KEY；其余 provider 见 SKILL 速查表）
# 换非 minimax provider 时，同步改 settings.yaml 的 provider 块（4 处，见 SKILL.md「换 provider」）
scp -r dsh-deploy root@<server>:/root/           # 上传到服务器
ssh root@<server> 'cd /root/dsh-deploy && bash install.sh'   # 跑完打印访问 URL
# 可选（公网 IP / 域名，加进 gateway sites）：
#   PUBLIC_IP=111.228.30.150 bash install.sh                       # NAT 公网 IP（不在网卡上）
#   DOMAIN=dsh.example.com CERT=/path/fullchain.pem KEY=/path/privkey.pem bash install.sh   # 域名 + 真证书
```
浏览器开 `https://<服务器IP>:19843` → 信任自签证书 → **注册首个访问者为管理员**。

## 文件

| 文件 | 说明 |
|---|---|
| `install.sh` | 一键脚本（服务器 root 跑；支持 `PUBLIC_IP`/`DOMAIN`/`CERT`/`KEY` env var 把公网 IP/域名加进 gateway sites） |
| `settings.yaml` | LLM provider 配置（默认 MiniMax 示例，provider 可换；同步全关；`dsh-sync` token=null） |
| `credentials.yaml.example` | key 模板（minimax 示例 env `MINIMAX_CN_API_KEY`；换 provider 改 env 名，见 SKILL 速查表） |
| `credentials.yaml` | 你填好 key 的真实文件（**`.gitignore` 排除，不分发**） |
| `SKILL.md` | 交互式安装 skill（AI 引导收参数 + 统一执行；含换 provider 的 4 处指引） |
| `README.md` | 本文件 |

## 前提

- Linux 服务器（Ubuntu/Debian，root），能访问 npmmirror，19843 端口对访问者可达。
- user-management **0.5.4+**（install.sh 装 `@latest`；gateway 把配置的 `sites.hosts` 与自动枚举的本地 IP **合并**，公网 IP/域名不会顶掉本地访问）。
- 远程交互式部署需 sshpass（`brew install hudochenkov/sshpass/sshpass`）。

## 装好的拓扑

```
浏览器 ─https─> [user-management gateway :19843]  ─登录闸(首访问者即admin)─
                └─(登录后)反代─> http://127.0.0.1:3080  (dsh web loopback, 无闸上游)
```
dsh web 留 loopback 不对外，gateway 是唯一入口（认证不可绕过）。详见 [`SKILL.md`](./SKILL.md)。
