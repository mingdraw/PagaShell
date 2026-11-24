# Agent 使用指南

Agent 位于主窗口右侧，可以巡检已连接的 SSH 服务器、后台执行命令，以及审阅、应用和回滚配置。开始使用前，需要配置自己的模型 API。

[返回使用指南](user-guide.md#agent)

## 配置模型

1. 点击主窗口顶部的 **Agent** 展开右栏，再点击右栏的「AI 设置」。也可从主窗口的「设置 → AI 设置」打开。
2. 选择「API 协议」：OpenAI Chat Completions、OpenAI Responses 或 Anthropic Messages。填写「API 地址」和 API Key；远程地址使用 HTTPS，本机接口可使用 HTTP。
3. 填写「默认模型 ID」，或点击模型字段旁的刷新按钮获取列表、再选择模型。获取列表失败时仍可手动填写。
4. 点击「测试连接」，成功后保存。测试只用当前填写的配置，不保存配置或聊天记录。以后修改其他字段时，可将 API Key 留空以继续使用已保存的 Key。

## 引用会话和发送消息

- 在输入框输入 `@`，或点击「+」，从「会话」列表选择已打开的连接。一次可引用多个会话，引用成功后名称会高亮。
- 按 `Esc` 关闭候选后，可以继续编辑本次 `@` 查询。点击「+」或输入新的 `@` 会再次打开候选。
- 若只想分享一段终端文字，可在终端选中内容后右键选择「引用选区到 Agent」。选区会添加到草稿，你可以编辑后再发送。
- 直接按 `Enter` 发送，按 `Shift+Enter` 换行。前一条消息还在执行时，后续消息会排队。
- 引用 SSH 会话后，Agent 会将该会话的相关信息和近期终端输出发送给你配置的 API。若只想咨询一般问题，可以不加会话引用。引用 RDP 只提供会话上下文和建议。

## 命令权限

| 模式 | 行为 |
|---|---|
| 请求批准（默认） | 固定巡检可自动读取。后台命令、终端输入、提权文件读取和配置修改需要确认。 |
| 只读自动 | 可自动执行白名单中的后台只读检查及非交互提权读取。其他命令、终端输入和配置修改需要确认。 |
| 完全访问 | 在只读自动基础上，也可自动将已识别的只读检查发送到引用终端。启用前会提示确认；配置修改和其他命令仍需确认。 |

高风险和多行命令还会显示确认弹窗。多选会话后，Agent 仍须为每条操作指定一个目标。停止按钮取消当前请求和排队消息；已经发到交互终端的输入需在该终端处理。

### 后台命令与配置修改

1. 使用 `@` 引用目标，例如「全面巡检服务器状态与资源瓶颈」。Agent 可读取系统基线、进程、监听端口、Docker、目录和配置，再给出建议。
2. 非交互命令走独立 SSH 通道，不占用当前终端。卡片提供实时输出、退出码、耗时及单命令中断；结束后可分别查看或复制标准输出、错误输出。后台时限为 1–600 秒。超时或取消会请求远端终止并关闭通道；重试前应检查服务和子进程状态。
3. 配置修改先展示精确 Diff、目标路径、提权及校验信息。应用时检查原文件 SHA-256，保留旧文件备份，再原子替换。需要重载或重启时会单独提出命令。语法校验失败时可直接从卡片回滚。应用或回滚时请避免同时在其他编辑器修改同一文件。
4. 回滚恢复原文件，或删除本次新建且没有再次修改的文件。若目标或备份已变更则停止。回滚文件不会自动恢复已加载的服务或内核配置。
5. 若需要交互输入，可用「改在终端运行」或「填入终端」将命令放进指定会话，由你检查后按回车。sudo 密码只在终端直接输入。

## 阅读回复和管理历史

- 回复先以可选的纯文本逐步显示，接收结束后排版为 Markdown。「思考与工具调用」可展开查看服务商提供的思考内容和工具记录。
- 上翻时保留阅读位置；点击「回到底部」或发送新消息可恢复跟随。重试历史消息时仍保留阅读位置。
- 每轮最多执行 24 批工具调用。到达上限可点「继续执行」，在原模型和会话仍有效时保留已完成步骤并接着处理。先发送新消息则使用已有记录开始下一轮。已执行过工具的中断请求请查看记录后再提交指令，避免重复执行。
- 标题栏可新建对话、搜索并打开历史，或删除不需要的记录。历史在本机加密保存；重新打开历史后，需要重新选择会话引用。

## 本地 MCP 服务（供 Codex 等外部工具调用）

PagaShell 内置纯本地 **MCP Streamable HTTP** 服务，允许本机的 **OpenAI Codex CLI**、**Claude Code**、**Cursor** 等外部工具直接复用 PagaShell 已建立的 SSH 会话和已保存的 SSH 服务进行巡检、命令执行、配置修改与回滚。

### 启用与接入

1. 打开「设置 → AI 设置」，下滑至 **本地 MCP 服务** 区域（无需先配置第三方模型 API Key）。
2. 开启「启用本地 MCP 服务」（默认关闭）。服务仅监听 `http://127.0.0.1:<端口>/mcp`（默认端口 `47321`），并自动生成高熵 Bearer 令牌存入本机凭据保险库/钥匙串。
3. 点击「复制 Codex 配置」，粘贴到 `~/.codex/config.toml`：

```toml
[mcp_servers.pagashell]
url = "http://127.0.0.1:47321/mcp"
http_headers = { "Authorization" = "Bearer <token>" }
```

也可点击「复制 MCP JSON」用于 Claude Code、Cursor 等标准 MCP HTTP 客户端。

### 安全与访问策略

- **回环绑定与防重绑定**：仅绑定 `127.0.0.1`，严格校验 `Host` 与 `Origin` 请求头，强制 `Authorization: Bearer` 常量时间校验；支持随时在设置中重置令牌，旧令牌立即失效。
- **权限模式**：
  - **完全放行（默认）**：暴露巡检、按需连接、后台命令、配置编辑、回滚与交互终端发送工具，由 Codex 等外部工具自身流程审批。
  - **只读模式**：隐藏并拒绝 `edit_remote_file`、`rollback_remote_file`、`send_terminal_command`，`exec_ssh_command` 仅允许白名单只读命令。切换模式后会通过 SSE 推送 `notifications/tools/list_changed`。
- **凭据与主机指纹保护**：所有工具、资源与审计日志均不返回密码、私钥、口令、API Key 或主机备注，并自动脱敏敏感赋值与私钥块；`connect_host` 仅支持已保存凭据且**主机指纹已在 PagaShell 中确认信任**的 SSH 服务，拒绝未信任或已变更指纹的主机；`edit_remote_file` 始终执行 SHA-256 核对、自动创建时间戳备份并拦截凭据类敏感文件。
- **能力清单**：
  - **Tools**：`list_sessions`、`list_hosts`、`connect_host`、`inspect_server_profile`、`get_server_status`、`get_processes`、`get_network_ports`、`get_docker_resources`、`list_remote_dir`、`read_remote_file`、`read_terminal_output`、`read_skill`、`exec_ssh_command`，以及完全放行模式下的 `edit_remote_file`、`rollback_remote_file`、`send_terminal_command`。
  - **Resources**：`pagashell://sessions`、`pagashell://hosts`、`pagashell://skills/<id>`。
  - **Prompts**：内置运维手册对应的 `ops_<skill_id>` 提示词模板。

<details>
<summary>接口、数据范围和开发验证</summary>

## 结构与边界

- `ShellPage` 的外层 `AgentWorkspace` 将左侧服务栏、完整会话工作区与 Agent 分成独立区域，Agent 不再嵌入中间 `TabPane` 的内容或圆角外框。右栏有独立顶部拖窗区、开关和拖宽分隔条，使用与左侧服务栏相同的宽度过渡、时长与曲线；动画只裁剪固定宽度的聊天，避免反复换行。窄窗口不足以容纳三栏时临时收起左栏，保持中间工作区与右栏并排，不覆盖主区域，也不改写左栏显隐偏好；关闭 Agent 或加宽窗口后恢复。此时点击左栏展开入口会收起 Agent 并恢复服务栏。收起后右栏不占宽度，通过顶部 Agent 按钮重新展开。聊天和会话子树均保持挂载，RDP 全屏立即隐藏右栏。Windows/Linux 窗口按钮固定在窗口右上角，不跟随右栏动画移动。
- 设置分为「通用」「代理」「AI 设置」「关于」。AI 设置表单包含 API 协议、地址、Key 和默认模型 ID，底部提供测试连接与保存。
- `AiSettingsController` 串行提交配置快照。`DriftAiSettingsRepository` 复用 `app_settings.ai_settings`，不修改 Drift schema。API Key 经现有 SecretStore 加密；替换前先记录待清理引用，再写新密文和提交引用，保存失败保留旧引用。新旧密文删除失败的引用持久化，后续编辑或重载重试。
- `AgentController` 构造注入 GetConnect、配置控制器、SecretStore、SessionController 和对话仓库，保留运行编排与生命周期。同一 Dart library 的 `agent_history.dart`、`agent_api.dart`、`agent_tools.dart`、`agent_queue.dart` 分别管理历史持久化、模型 API、工具执行与消息队列，API 部分直接使用注入的 GetConnect；`AgentApiCodec` 仅做 JSON 映射。AI 使用的 GetConnect 超时 90 秒，不跟随重定向，不调用 SDK 云服务、不引入遥测。
- 内置六项技能：PagaShell 使用、SSH 运维、Linux 系统调优、数据库运维、软件安装与部署、RDP 运维。模型通过 `read_skill` 按需加载。
- Agent 回复通过纯 Dart `markdown` 解析 GitHub Flavored Markdown，再映射为原生组件，支持标题、粗体/斜体/删除线、行内代码、嵌套有序/无序列表、任务列表、引用、分隔线及表格。正文可选择，宽表格横向滚动，代码块保留语言、原文复制和横向滚动；用户消息保留原文。历史存储仍保存原始消息，恢复时重新渲染。链接与图片显示可复制的标签和地址，不自动跳转或加载远程图片，HTML 作为文本显示。

## 协议

| 设置格式 | 请求 | 鉴权 | 工具结果 |
|---|---|---|---|
| OpenAI Chat Completions | `POST /v1/chat/completions`；`messages` 含 system | `Authorization: Bearer` | assistant `tool_calls` 与 tool `tool_call_id` |
| OpenAI Responses | `POST /v1/responses`；`instructions`、`input`、`store: false` | `Authorization: Bearer` | `function_call` 与 `function_call_output` 通过 `call_id` 关联；保留并回放 reasoning 和原始 output 项目 |
| Anthropic Messages | `POST /v1/messages`；顶层 `system`、自动读取的 `max_tokens` | `x-api-key`、`anthropic-version: 2023-06-01` | assistant `tool_use` 与 user `tool_result` |

地址可为根路径、版本路径或完整接口，切换协议或获取模型时归一化已知接口后缀，保留自定义路径前缀。新建地址为空，示例只作 placeholder，切换协议不改写输入值。API Key 位于模型 ID 上方。模型 ID 可手动填写，也可点击刷新，通过当前地址、协议和 Key 获取 `GET /v1/models` 目录后下拉选择；支持游标分页、去重和输入过滤。编辑时 Key 留空从保险库复用，目录仅存在表单内存，修改地址、协议或 Key 会清除旧候选并忽略迟到结果。目录失败不阻止手动保存。

刷新按钮位于默认模型 ID 标签行最右侧，输入框与其他字段等高。弹窗底部「测试连接」使用尚未保存的配置发起模型请求；Key 留空时复用已保存的保险库引用。测试不保存配置或 Key、不写入聊天记录，也不执行返回的工具调用。测试期间显示进行状态并禁用重复测试与保存，仍可关闭弹窗；修改连接字段后清除旧测试结果。保存后保留表单，显示结果并清空 Key 输入。旧多配置数据以原先选中项作为当前 API，其他配置和密钥引用保留，继续使用原有密钥提交和清理事务。

Agent 输入框底栏显示当前模型并支持直接切换。首次拉取服务商的模型目录后会持久化缓存在本机配置中，后续打开面板或切换模型直接读取缓存、不重复请求；如需更新目录，可在「设置 → AI 设置」点击默认模型旁的刷新按钮重新拉取。保存新的 API 地址、协议或 Key 后，旧服务商的缓存目录与能力缓存随之失效，迟到目录结果不污染新配置。

输入框内可选择思考强度，默认「自动」省略所有思考控制参数。OpenAI Chat Completions 使用 `reasoning_effort`，Responses 使用 `reasoning.effort`。Anthropic 根据模型目录的 `capabilities.effort` 和 `capabilities.thinking.types` 限定档位，自适应模式发送 `thinking.type: adaptive` 与 `output_config.effort`；仅支持旧式 `enabled` 的模型将低/中/高映射为内部预算 1024/8192/32768，且始终小于服务商返回的输出上限，不要求用户配置 Token。未报告能力的兼容服务提供协议档位，由服务商校验；不支持时提示改用自动或其他档位，不猜测模型名称。

没有用户可配的输出上限，存量 `maxTokens` 字段读取时忽略，下次保存不再写入。OpenAI 两种格式均省略输出 Token 上限参数；Anthropic Messages 要求 `max_tokens`，自动使用模型目录返回的正整数最大值，未缓存时先从 `GET /v1/models/{model_id}` 读取，再尝试列表。该能力信息只在运行内存缓存；第三方兼容服务未提供能力时省略参数，允许采用服务端默认值。若该服务同时强制要求 `max_tokens`，会明确提示模型接口缺少能力信息，不使用固定 4096 截断。模型与服务商自身的长度限制仍然有效。

三种协议的聊天请求都支持 SSE，收到文字即增量显示。兼容接口可直接返回完整 JSON，明确拒绝流式请求时会以普通 JSON 重试。工具调用在收到完整回复、校验参数后开始。流出错或手动停止时保留已接收的文字，并标记「已中断」。服务商返回的思考文本或摘要可在「思考与工具调用」中展开；工具记录显示目标、耗时、输出字数或取消状态，签名、加密数据和原始工具输出不在此处展示。

每段执行最多 24 批工具调用，单次模型响应最多接受 8 个工具。每批工具结果与调用 ID 完整配对后写入历史。模型上下文保留最多 20 个用户轮次，按 120,000 字符预算优先移除完整较早轮次，再裁剪超长的旧工具结果；可见聊天仍保留。单个工具输出上限为 24,000 字符，缩略保留首尾。Responses 原始 output 和加密 reasoning、Anthropic 思考签名只在兼容的协议范围内重放，切换模型或密钥后回退为通用工具表示。错误提示不回显请求头或服务端原文。

参考 [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[OpenAI 思考参数](https://developers.openai.com/api/docs/guides/reasoning)、[Responses 迁移与无状态工具往返](https://developers.openai.com/api/docs/guides/migrate-to-responses)、[Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort)、[思考与工具往返](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows) 与 [Anthropic 模型能力](https://platform.claude.com/docs/en/api/models/list)。

## 数据与操作

默认仅发送用户消息及技能说明。输入 `@` 或点击输入框左下角「+」打开同一个独立宽度的 Popover。弹层按来源分组，当前提供「会话」分组，可继续扩展其他来源。会话显示为「名称 · 终端 / 远程桌面」，可继续输入名称或地址实时筛选，支持空格分词与中文组词并保留输入焦点；支持点击、上下键定位和 Enter/Tab 选择，Escape 关闭。选择后用高亮的 `@服务名` 替换当前查询或选区，保留两侧草稿并将光标放在尾随空格后；同名会话用类型和序号区分。可在同一输入框引用多个会话，不显示额外会话标签。引用保留真实文本，删改任意字符即取消该处高亮与关联；手工补回、粘贴或撤销不会重新绑定，其他引用继续有效，同一会话的有效引用按 ID 去重。每轮在异步请求前固定所有引用的 session、terminal 和 engine，切换活动页签或编辑下一条草稿不改变目标。关闭或重连使对应引用失效，保留文字但取消高亮，需重新选择；会话绑定仅在运行内存保存。发送后清空草稿；失败或取消的消息可在原连接仍有效时重试。

思考强度与审核模式是全局偏好，选择后串行保存到 `app_settings.ai_settings`；新建、恢复历史、切换目标和重启均沿用最近选择。旧配置默认自动思考与请求批准。保存失败保留当前选择并提示重试，退出前等待保存队列并重试。具体会话与待批准命令句柄不会随偏好恢复。

Enter 直接发送消息，Shift+Enter 在光标或选区插入换行；保留 Cmd/Ctrl+Enter 发送。候选 Popover 打开时 Enter/Tab 先选择候选；中文等输入法仍在组词时 Enter 不触发发送。

运行模型请求、调用工具或等待命令批准时仍可继续发送，消息按 FIFO 排队。每次发送立即清空草稿并展示用户消息，分别标记处理中、排队中、请求失败或已取消，回复和工具记录放在对应用户消息之后；输入框上方显示排队数量及停止按钮，底部始终保留发送按钮。一条消息的完整工具轮次结束后才执行下一条；未来消息不提前进入当前模型上下文。单条失败保留脱敏错误，后续排队消息继续执行。

每条消息在提交时固定文本、引用标签、会话连接、模型配置与密钥引用、思考强度和审核模式。排队期间仍可编辑下一条草稿、选择会话及修改模式，已提交的请求不随之变化；改为完全访问也不会自动批准之前的命令。轮到执行时重新校验原连接并读取最新终端输出；排队会话已关闭或同 ID 重连时该条失败，需重新选择后发送。

消息列表在底部跟随新输出。浏览历史时，重试及持续输出都保留阅读位置；发送新消息、滚到底部或点击「回到底部」可恢复跟随。

引用会话后发送白名单元数据（会话 ID、引用名称、hostname、port、协议、页签、连接状态、是否经网关），并分别从各 SSH 会话的 paga_terminal 当前屏幕镜像和近期回滚读取输出；每个会话默认最近 120 行，工具最多 200 行、16000 字符。`read_terminal_output` 可重新读取，或最多等候 5 秒获取新输出，不注入任何探测命令，也不重复订阅 SSH 输出流。切入 alternate screen 时读取当前屏幕。输出作为不可信数据处理，可能包含后台活动或用户自行显示的内容；仅引用的会话输出会发送到配置的 API。不读取凭据保险库中的密码、私钥、主机备注或 RDP 图像。SSH 状态通过现有只读状态通道采集；单次 Linux CPU 无百分比，不能解释成 0%。已发送的上下文仍在当前对话中，点击新对话后不再用于新的请求，旧记录保留在历史管理中。

读写工具使用 `session_id` 指定本轮已引用的可用 SSH 会话。只引用一个会话时可省略；多个会话时必须精确指定。审批和真正执行前均核对原连接身份，重连后需要重新引用。配置文件走固定后台脚本；内容通过 stdin 传输，不进入远端进程参数。拒绝凭据路径、私钥以及检测到的常见密码或令牌字段。操作要求绝对路径、普通 UTF-8 文本文件（最多 2 MiB），不修改末端符号链接。提权使用 `sudo -n`；目录必须具备安全的属主及写权限。

| 工具 | 用途 |
|---|---|
| `read_skill` | 按 ID 加载一项内置运维手册 |
| `get_workspace_context` | 读取本轮引用的会话信息 |
| `inspect_server_profile` | 读取 OS、硬件、包管理器、句柄、sysctl 和已安装服务 |
| `get_server_status` | 读取负载、内存、Swap、文件系统和存储 |
| `get_processes` | 按 CPU 或内存列出进程，不返回命令行参数 |
| `get_network_ports` | 读取监听端口及已知关联进程 |
| `get_docker_resources` | 读取指定类型的资源列表或精确 ID 的概要，不读容器环境变量 |
| `list_remote_dir` | 通过 SFTP 读取绝对路径的目录条目 |
| `read_remote_file` | 按行读取文本与 SHA-256，可申请非交互提权 |
| `exec_ssh_command` | 提交后台命令，返回退出码与分离输出 |
| `edit_remote_file` | 预览并批准精准替换或整文件写入；支持备份和指定的配置校验 |
| `read_terminal_output` | 获取指定会话的终端输出 |
| `propose_ssh_command` | 提交需要交互的终端命令 |

发送输入前开始观察终端变化，输出安静 600ms 或观察达到 8 秒后将近期输出返回模型继续分析；超时无新输出也明确记录，不自动重复发送。输出变化、安静或超时均不证明命令完成或成功，长任务可由读取工具继续观察。停止、清空或原会话失效会解除批准/输出等待并丢弃迟到回复，不撤销已排入终端的输入。RDP 仅提供上下文、建议和复制，不执行 PowerShell 或发送键鼠。

停止、新建、切换或删除当前对话、退出以及正在运行的目标会话失效，都会取消当前消息及全部待执行消息，使运行代次失效；迟到响应不追加消息或调用工具。已打开的 SSE 响应会停止读取；已发出的请求可能仍在服务商运行。

## 历史对话

标题右侧的历史入口管理所有非空对话，按更新时间倒序显示标题、模型、时间和消息数，可打开继续或确认删除。新建对话会保留旧记录，失败和停止的请求也保留可见内容；空对话不创建历史项。恢复时使用当前 AI 设置中的默认模型并沿用全局思考强度和审核模式，清除原会话绑定，需重新用 `@` 选择会话。历史命令只读展示目标、用途和结果状态，不恢复执行句柄。

`DriftAgentConversationRepository` 按对话复用 `app_settings` 记录，无 schema 变更。标题、可见消息、已提交的模型上下文与协议原始思考块整体使用 AES-256-GCM 加密；独立数据密钥存 SecretStore，记录 ID 用作认证数据。中断时历史记录已完成工具及未确认结果的状态，保持调用和结果成对。重启后保留退出码、Diff 摘要、备份和回滚状态；卡片只读，连接和审批不会恢复。保存和删除串行执行，失败时保留可重试的快照。

请求状态及脱敏错误随用户消息保存。未完成和待执行消息恢复为已取消，保留提交原文；不持久化队列中的连接句柄和执行授权，打开历史或重启均不会自动重发。

窗口关闭和系统退出先停止当前 Agent 轮次并等待对话、模式偏好的本地写入队列完成，不等待服务商的迟到请求。保存失败时保留窗口，可取消退出后重试，也可明确选择丢弃未保存数据退出。已成功删除的 ID 会过滤迟到读取和重试快照，避免重新出现在列表或数据库中。

## 验证入口

```bash
flutter analyze --no-pub
flutter test --no-pub test/application/ai_settings_controller_test.dart test/application/agent_controller_test.dart test/application/agent_queue_test.dart test/infrastructure/agent_http_test.dart test/infrastructure/agent_stream_http_test.dart test/infrastructure/agent_conversation_repository_test.dart test/agent_input_controller_test.dart test/agent_message_body_test.dart test/agent_ui_test.dart test/theme_mode_test.dart
```

本机 HTTP 契约测试真实经过 GetConnect，覆盖三种协议的模型目录、设置默认模型、思考参数、技能往返及后续聊天。队列控制器与组件测试覆盖三协议连续发送、完整轮次顺序、上下文隔离、每条配置和会话快照、审批等待期间排队、单条失败后继续、取消整队、同步状态通知取消、同 ID 重连、迟到响应隔离及历史恢复不重发。控制器和组件测试还覆盖 `@` 分组 Popover 的独立宽度、会话命名、同名会话引用与目标 ID 映射、输入框内多引用高亮、删改解除关联、整段删除、输入法组词和重连失效、中英文长列表键盘定位、反复开关、模式持久化及保存失败重试、Enter/Shift+Enter 和输入法组词、审核模式切换、目标固定、批准/拒绝/停止、完全访问与输出返回模型、输出限额、重连失效，以及直接设置表单、复用 Key、迟到目录结果、思考签名回传、聊天、折叠保留输入、拖宽、800×600 macOS/Windows/Linux 主题布局及语言切换。历史测试覆盖新建保留、恢复续聊、删除当前和旧对话、保存失败重试、迟到响应隔离、只读命令恢复、数据库关闭重开及密文/密钥异常。它们不代表真实第三方服务商、Windows/Linux 原生运行或真实远程命令执行验收。实际服务商需在设置中提供用户自己的 URL、模型 ID 和 API Key 后测试连接。

</details>
