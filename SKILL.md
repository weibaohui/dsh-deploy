# dsh-deploy — 交互式一键部署 dsh web harness

把 dsh web harness（dsh 0.1.1-rc.2 + 11 插件 + 可配置 LLM provider/key + user-management HTTPS gateway）部署到本机 Linux 或 scp 到远程服务器。LLM provider 默认 MiniMax 示例（开箱即跑），可换 deepseek/openai/zhipu 等任意 provider。**先一次性问全参数，再统一执行**——不问一句跑一句。

## When to Use
- 用户说「部署 dsh」「装一套 dsh」「在服务器上跑 dsh web」「dsh-deploy」。
- 用户给了一台新 Linux 服务器（或本机是 Linux），想一键起 dsh + gateway + 插件 + 一个 LLM provider。

## Prerequisites
- **部署文件夹** `dsh-deploy/`（含 `install.sh` + `settings.yaml` + `credentials.yaml.example` + 本 SKILL.md）。用户本机路径：`/Users/weibh/projects/ts/dsh-deploy/`；接收者拿到文件夹后用文件夹所在路径。
- **远程部署需 sshpass**（密码 ssh）：`brew install hudochenkov/sshpass/sshpass`（没装先装；ssh key auth 不需要）。
- 目标：Linux 服务器（Ubuntu/Debian），root 权限，能访问 npmmirror，19843 端口对访问者可达。
- user-management **0.6.1+**（install.sh 装 `@weibaohui/user-management@latest`；0.5.4+ 有 sites merge，**0.6.1+ 修了 `/plugins/*` 公开**——< 0.6.1 的 gated gateway 会 "Failed to load plugins"）。

## Procedure

### 1. 收集参数（一次 `ask_user_question` 问全）
问用户以下（free-text 的不设 `options`；provider/target 设 options）：

| id | question | options |
|---|---|---|
| `provider` | 用哪个 LLM provider？默认 MiniMax（开箱即跑，settings.yaml 已预置）；换其他见下方速查表 | `MiniMax (minimax-cn) [默认]` / `其他（free-text 填 provider id）` |
| `key` | 该 provider 的 API key（走该 provider 的 env 名，见速查表） | —（free-text） |
| `model` | 默认用哪个模型？minimax 默认 `MiniMax-M2.7`；其他 provider 填该 provider 的 model id | —（free-text；minimax 可不填走默认） |
| `public_ip` | 公网访问 IP？（可选；NAT 进来、**不在服务器网卡上**的公网 IP，如 `111.228.30.150`。没有填 `none`） | — |
| `domain` | 域名？（可选；有域名想免自签警告就填，如 `dsh.example.com`。没有填 `none`） | — |
| `target` | 装到哪？ | `本机 Linux (local)` / `scp 到远程服务器 (remote)` |

- 若 `target=remote`：再问 `server`（"服务器地址 root@ip 或 ip"）+ `password`（"ssh 密码"），free-text。
- 若 `domain≠none`：再问 `cert`（"证书文件路径，服务器上 fullchain.pem"）+ `keypath`（"私钥文件路径，服务器上 privkey.pem"），free-text。无 cert/key → 自签证书经 merge 覆盖该域名（仍有自签警告）。

> 如果 `ask_user_question` 不便收 free-text，就直接在对话里逐项问用户、让用户一次性贴出。

**常见 provider → env 名速查表**（env 名按各 provider 文档为准；dsh 的 provider id / apiKeyEnv 是在 `settings.yaml` 的 `llm-pi-ai.providers` 里自定义的，下表为常见约定示例）：

| provider id | apiKeyEnv（credentials.yaml 里的 key 名） | 获取 key |
|---|---|---|
| `minimax-cn` | `MINIMAX_CN_API_KEY` | minimaxi.com → API keys |
| `deepseek` | `DEEPSEEK_API_KEY` | platform.deepseek.com → API keys |
| `openai` | `OPENAI_API_KEY` | platform.openai.com → API keys |
| `zhipu` | `ZHIPUAI_API_KEY` | open.bigmodel.cn → API keys |
| `qwen` | `DASHSCOPE_API_KEY` | dashscope.aliyun.com → API-KEY |

### 2. 填 credentials.yaml（key）
```
DEPLOY=/Users/weibh/projects/ts/dsh-deploy   # 接收者改成自己的文件夹路径
cd "$DEPLOY"
cp credentials.yaml.example credentials.yaml
# macOS 用 sed -i ''，Linux 用 sed -i
sed -i '' "s|<your-api-key>|<用户给的 key>|" credentials.yaml
grep -q '<your-api-key>' credentials.yaml && echo "BAD: still placeholder" || echo "key filled"
```
- 若 `provider≠minimax`：先改 credentials.yaml 的 **env 名**成对应 provider 的（见速查表），例如换 deepseek：把 `MINIMAX_CN_API_KEY:` 改成 `DEEPSEEK_API_KEY:`，再 sed 填 key。
- **不要手填 settings.yaml 的 sites**——install.sh 用 `PUBLIC_IP`/`DOMAIN`/`CERT`/`KEY` env var append sites，gateway 0.5.4 merge。

### 2b. 若 provider≠minimax，改 settings.yaml 的 provider 块（minimax 可跳过本步——已是开箱即跑示例）
minimax 是 settings.yaml 里已预置好的可运行示例；换其他 provider 时，同步改这 4 处（缺一会导致 agent 调不到模型）：
1. `llm-pi-ai.providers.<id>`：把 `minimax-cn` 块换成目标 provider 块——provider id、`models[]`（该 provider 的 model id + contextWindow + maxTokens）、`apiKeyEnv`（与 credentials.yaml 里的 env 名一致）。
2. `agent-default-model.provider` / `agent-default-model.model`：chat agent 用的 provider/model。
3. `hermes-loop.provider` / `hermes-loop.model`：autonomous loop 用的 provider/model（建议与 default 一致）。
4. `credentials.yaml` 的 env 名（已在第 2 步改）。

### 3. 执行
设 env vars（按用户给的，没填的不设）：
```
export PUBLIC_IP=<public_ip>   # none 则不设
export DOMAIN=<domain>          # none 则不设
export CERT=<cert>              # domain 且有 cert 才设
export KEY=<keypath>            # 同上
```

**local**（先 `uname -s` 确认是 Linux；不是 Linux 就停手，告诉用户 local 只支持 Linux、改用 remote）：
```
cd "$DEPLOY" && bash install.sh
```

**remote**（`sshpass -p '<password>'`；scp/ssh 都加 `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` 首连不卡）：
```
sshpass -p '<password>' scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$DEPLOY" root@<server>:/root/dsh-deploy
sshpass -p '<password>' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<server> \
  "cd /root/dsh-deploy && PUBLIC_IP='<public_ip>' DOMAIN='<domain>' CERT='<cert>' KEY='<keypath>' bash install.sh"
```
（env vars 经 ssh 单引号传到远端 install.sh。）

### 4. 验证 + 报告
- install.sh 自带验证（dsh web loopback `:3080` + gateway `:19843` `/login`）+ 打印访问 URL。
- **remote**：从本机 `curl -sk https://<server-ip 或 public_ip>:19843/login` → `200`（确认可达）。优先用用户填的 `public_ip`（公网）或 Tailscale IP。
- 取 gateway hosts 确认 merge 生效（remote）：
  ```
  sshpass -p '<password>' ssh root@<server> 'journalctl -u dsh-web -n 30 | grep "user-management:"'
  ```
  日志应见 `0.0.0.0:19843 -> 127.0.0.1:3080 (hosts: localhost, <本机IP>, ..., <public_ip>, ...)`——`<public_ip>` 在 hosts 里 = merge 成功。
- **报告**：
  - 访问 URL：`https://<public_ip 或 server-ip 或 domain>:19843` → 浏览器开 → 信任自签证书（domain+cert 无警告）→ **注册首访问者为管理员**。
  - cert 下载：`https://<url>:19843/user-management/api/cert`（PEM，公开 pre-auth）。
  - 日志：`sshpass ... ssh root@<server> 'journalctl -u dsh-web -f'`。

## Pitfalls
- install.sh 用 `systemctl enable` + `restart`（**不是** `enable --now`）——重跑/fresh 都重启重载配置（旧版 `--now` 在已运行时 no-op，新配置不加载）。
- `PUBLIC_IP`/`DOMAIN` 依赖 user-management **0.5.4+**（merge）；`/plugins/*` 公开依赖 **0.6.1+**。install.sh 装 `@latest`（0.6.1+）。< 0.5.4 会 REPLACE（本地 IP 丢，421）；< 0.6.1 的 gated gateway 报 "Failed to load plugins"。
- remote ssh 密码用 sshpass（`brew install hudochenkov/sshpass/sshpass`）；ssh key auth 更安全但用户要密码就 sshpass。**不要**把密码写进文件/日志。
- local 安装只支持 Linux（install.sh 用 npmmirror `linux-x64` node 二进制 + systemd）；Mac 上 local 不行，用 remote。
- 域名 + cert/key：cert/key 路径是**服务器上的路径**（用户先在服务器 `certbot certonly -d <域名>` 申请，或自己上传）。本机 Mac 上 certbot 申请的证书要传到服务器再用。
- settings.yaml 是 provider 默认 MiniMax 示例 + 同步全关；`dsh-sync` token=null（启用同步前自己填）。
- 接收者填的 key 不回显；install.sh 检测到 credentials.yaml 还是占位 `<your-api-key>` 会报错指路。
- **换 provider 必须同步改 4 处**（providers 块 + agent-default-model + hermes-loop + credentials env 名），漏改任一处都会让 agent 调不到模型或加载失败。
