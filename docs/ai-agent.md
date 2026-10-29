# AI Agent

## 结构与边界

- `ShellPage` 的外层 `AgentWorkspace` 将左侧服务栏、完整会话工作区与 Agent 分成独立区域，Agent 不再嵌入中间 `TabPane` 的内容或圆角外框。右栏有独立顶部拖窗区、开关和拖宽分隔条，使用与左侧服务栏相同的宽度过渡、时长与曲线；动画只裁剪固定宽度的聊天，避免反复换行。窄窗口不足以容纳三栏时临时收起左栏，保持中间工作区与右栏并排，不覆盖主区域，也不改写左栏显隐偏好；关闭 Agent 或加宽窗口后恢复。此时点击左栏展开入口会收起 Agent 并恢复服务栏。收起后右栏不占宽度，通过顶部 Agent 按钮重新展开。聊天和会话子树均保持挂载，RDP 全屏立即隐藏右栏。Windows/Linux 窗口按钮固定在窗口右上角，不跟随右栏动画移动。
- `SettingsDialog` 使用 shadcn Tabs 提供通用和 AI 两类设置；AI Tab 直接填写一组 API 协议、地址、Key 和默认模型 ID，底部提供测试连接与保存。长表单滚动，底部按钮和结果反馈固定可见，不再通过模型卡片进入第二层编辑弹窗。
- `AiSettingsController` 串行提交配置快照。`DriftAiSettingsRepository` 复用 `app_settings.ai_settings`，不修改 Drift schema。API Key 经现有 SecretStore 加密；替换前先记录待清理引用，再写新密文和提交引用，保存失败保留旧引用。新旧密文删除失败的引用持久化，后续编辑或重载重试。
- `AgentController` 构造注入 GetConnect、配置控制器、SecretStore、SessionController 和对话仓库，直接发 HTTP；`AgentApiCodec` 仅做 JSON 映射。AI 独立 HTTP 客户端超时 90 秒，不跟随重定向，不调用 SDK 云服务、不引入遥测。
- 内置技能位于 `domain/ai/agent_skill.dart`，仅三项，模型通过 `read_skill` 按需加载。没有外部技能市场或通用插件框架。
- Agent 回复通过纯 Dart `markdown` 解析 GitHub Flavored Markdown，再映射为原生组件，支持标题、粗体/斜体/删除线、行内代码、嵌套有序/无序列表、任务列表、引用、分隔线及表格。正文可选择，宽表格横向滚动，代码块保留语言、原文复制和横向滚动；用户消息保留原文。历史存储仍保存原始消息，恢复时重新渲染。链接与图片显示可复制的标签和地址，不自动跳转或加载远程图片，HTML 作为文本显示。

## 协议

| 设置格式 | 请求 | 鉴权 | 工具结果 |
|---|---|---|---|
| OpenAI | `POST /v1/chat/completions`；`messages` 含 system | `Authorization: Bearer` | assistant `tool_calls` 与 tool `tool_call_id` |
| OpenAI Responses | `POST /v1/responses`；`instructions`、`input`、`store: false` | `Authorization: Bearer` | `function_call` 与 `function_call_output` 通过 `call_id` 关联；保留并回放 reasoning 和原始 output 项目 |
| Anthropic | `POST /v1/messages`；顶层 `system`、自动读取的 `max_tokens` | `x-api-key`、`anthropic-version: 2023-06-01` | assistant `tool_use` 与 user `tool_result` |

地址可为根路径、版本路径或完整接口，切换协议或获取模型时归一化已知接口后缀，保留自定义路径前缀。新建地址为空，示例只作 placeholder，切换协议不改写输入值。API Key 位于模型 ID 上方。模型 ID 可手动填写，也可点击刷新，通过当前地址、协议和 Key 获取 `GET /v1/models` 目录后下拉选择；支持游标分页、去重和输入过滤。编辑时 Key 留空从保险库复用，目录仅存在表单内存，修改地址、协议或 Key 会清除旧候选并忽略迟到结果。目录失败不阻止手动保存。

刷新按钮位于默认模型 ID 标签行最右侧，输入框与其他字段等高。弹窗底部「测试连接」使用尚未保存的配置发起模型请求；Key 留空时复用已保存的保险库引用。测试不保存配置或 Key、不写入聊天记录，也不执行返回的工具调用。测试期间显示进行状态并禁用重复测试与保存，仍可关闭弹窗；修改连接字段后清除旧测试结果。保存后保留表单，显示结果并清空 Key 输入。旧多配置数据以原先选中项作为当前 API，其他配置和密钥引用保留，继续使用原有密钥提交和清理事务。

Agent 只使用设置中的默认模型 ID，在标题旁显示该 ID；面板不提供模型下拉或刷新入口，展开时不自动拉取目录。模型目录刷新和选择均在 AI 设置中完成。保存新的 API、Key 或默认 ID 后，后续请求使用新配置并沿用思考强度；模型能力缓存随配置更新失效，旧配置的迟到目录结果不污染新配置。

输入框内可选择思考强度，默认「自动」省略所有思考控制参数。OpenAI Chat Completions 使用 `reasoning_effort`，Responses 使用 `reasoning.effort`。Anthropic 根据模型目录的 `capabilities.effort` 和 `capabilities.thinking.types` 限定档位，自适应模式发送 `thinking.type: adaptive` 与 `output_config.effort`；仅支持旧式 `enabled` 的模型将低/中/高映射为内部预算 1024/8192/32768，且始终小于服务商返回的输出上限，不要求用户配置 Token。未报告能力的兼容服务提供协议档位，由服务商校验；不支持时提示改用自动或其他档位，不猜测模型名称。

没有用户可配的输出上限，存量 `maxTokens` 字段读取时忽略，下次保存不再写入。OpenAI 两种格式均省略输出 Token 上限参数；Anthropic Messages 要求 `max_tokens`，自动使用模型目录返回的正整数最大值，未缓存时先从 `GET /v1/models/{model_id}` 读取，再尝试列表。该能力信息只在运行内存缓存；第三方兼容服务未提供能力时省略参数，允许采用服务端默认值。若该服务同时强制要求 `max_tokens`，会明确提示模型接口缺少能力信息，不使用固定 4096 截断。模型与服务商自身的长度限制仍然有效。

当前采用完整 JSON 响应，尚未实现 SSE 流式输出；第三方 API 必须支持对应文本和工具调用格式。每轮最多 6 次模型请求，每次最多 8 个工具调用。后续请求保留最近 12 个用户轮次、约 60000 字符以内的历史，移除完整早期轮次时保留工具调用配对并在界面提示，当前可见聊天保留。Responses 原始 output 和加密 reasoning 计入历史大小；仅对同一接口、模型和密钥引用回放，切换模型或 Key 时使用通用聊天与工具表示。Anthropic 原始 content（包括 thinking、signature、redacted_thinking 与 tool_use 的顺序）在同一范围完整回传，不展示到聊天；接口、模型、Key、系统上下文、强度改变或历史裁剪后回退为通用文本和工具表示，避免误用思考签名。错误提示丢弃服务端原文，不回显请求头、API Key 或异常中的密文。

参考 [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[OpenAI 思考参数](https://developers.openai.com/api/docs/guides/reasoning)、[Responses 迁移与无状态工具往返](https://developers.openai.com/api/docs/guides/migrate-to-responses)、[Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort)、[思考与工具往返](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows) 与 [Anthropic 模型能力](https://platform.claude.com/docs/en/api/models/list)。

## 数据与操作

默认仅发送用户消息及技能说明。输入 `@` 或点击输入框左下角「+」打开同一个独立宽度的 Popover。弹层按来源分组，当前提供「会话」分组，可继续扩展其他来源。会话显示为「名称 · 终端 / 远程桌面」，可继续输入名称或地址实时筛选，支持空格分词与中文组词并保留输入焦点；支持点击、上下键定位和 Enter/Tab 选择，Escape 关闭。选择后用高亮的 `@服务名` 替换当前查询或选区，保留两侧草稿并将光标放在尾随空格后；同名会话用类型和序号区分。可在同一输入框引用多个会话，不显示额外会话标签。引用保留真实文本，删改任意字符即取消该处高亮与关联；手工补回、粘贴或撤销不会重新绑定，其他引用继续有效，同一会话的有效引用按 ID 去重。每轮在异步请求前固定所有引用的 session、terminal 和 engine，切换活动页签或编辑下一条草稿不改变目标。关闭或重连使对应引用失效，保留文字但取消高亮，需重新选择；关联仅在运行内存保存，发送后随草稿清空。

思考强度与审核模式是全局偏好，选择后串行保存到 `app_settings.ai_settings`；新建、恢复历史、切换目标和重启均沿用最近选择。旧配置默认自动思考与请求批准。保存失败保留当前选择并提示重试，退出前等待保存队列并重试。具体会话与待批准命令句柄不会随偏好恢复。

Enter 直接发送消息，Shift+Enter 在光标或选区插入换行；保留 Cmd/Ctrl+Enter 发送。候选 Popover 打开时 Enter/Tab 先选择候选；中文等输入法仍在组词时 Enter 不触发发送。

引用会话后发送白名单元数据（会话 ID、引用名称、hostname、port、协议、页签、连接状态、是否经网关），并分别从各 SSH 会话的 xterm 当前屏幕和近期回滚读取输出；每个会话默认最近 120 行，工具最多 200 行、16000 字符。`read_terminal_output` 可重新读取，或最多等候 5 秒获取新输出，不注入任何探测命令，也不重复订阅 SSH 输出流。切入 alternate screen 时读取当前屏幕。输出作为不可信数据处理，可能包含后台活动或用户自行显示的内容；仅引用的会话输出会发送到配置的 API。不读取凭据保险库中的密码、私钥、主机备注或 RDP 图像。SSH 状态通过现有只读状态通道采集；单次 Linux CPU 无百分比，不能解释成 0%。已发送的上下文仍在当前对话中，点击新对话后不再用于新的请求，旧记录保留在历史管理中。

思考强度旁提供「请求批准 / 完全访问」。`propose_ssh_command` 在默认「请求批准」下暂停工具循环，用户审阅固定目标、命令和用途，确认后才发送命令及回车，拒绝结果也返回模型；「完全访问」直接发送到指定引用的 SSH 终端。读取与命令工具用 `session_id` 指定本轮引用集合中的一个会话，多引用时省略目标会拒绝操作，单引用时可省略；命令不广播到所有引用。两种模式发送前均重新验证原会话、终端及引擎身份，已关闭、重连、停止、已发送或已拒绝的请求不能发送。引用集合以外的目标 ID 不能操作。

发送输入前开始观察终端变化，输出安静 600ms 或观察达到 8 秒后将近期输出返回模型继续分析；超时无新输出也明确记录，不自动重复发送。输出变化、安静或超时均不证明命令完成或成功，长任务可由读取工具继续观察。停止、清空或原会话失效会解除批准/输出等待并丢弃迟到回复，不撤销已排入终端的输入。RDP 仅提供上下文、建议和复制，不执行 PowerShell 或发送键鼠。

停止、新建、切换或删除当前对话使运行代次失效，迟到响应不追加消息或调用工具。当前 GetConnect 不提供逐请求取消句柄，已发出的请求可能仍在服务商运行。

## 历史对话

标题右侧的历史入口管理所有非空对话，按更新时间倒序显示标题、模型、时间和消息数，可打开继续或确认删除。新建对话会保留旧记录，失败和停止的请求也保留可见内容；空对话不创建历史项。恢复时使用当前 AI 设置中的默认模型并沿用全局思考强度和审核模式，清除原会话绑定，需重新用 `@` 选择会话。历史命令只读展示目标、用途和结果状态，不恢复执行句柄。

`DriftAgentConversationRepository` 按对话复用 `app_settings` 记录，无 schema 变更。标题、可见消息、已提交的模型上下文与协议原始思考块整体使用 AES-256-GCM 加密；独立数据密钥存 SecretStore，记录 ID 用作认证数据。重启后可找回旧对话；未完成轮次仅保存可见内容，不把未配对的工具调用放入续聊上下文。保存和删除串行执行，快照在排队前捕获，防止切换串写或删除后复活。保存失败保留内存记录并提供重试；密文损坏或密钥缺失时报错并保留原记录。

窗口关闭和系统退出先停止当前 Agent 轮次并等待对话、模式偏好的本地写入队列完成，不等待服务商的迟到请求。保存失败时保留窗口，可取消退出后重试，也可明确选择丢弃未保存数据退出。已成功删除的 ID 会过滤迟到读取和重试快照，避免重新出现在列表或数据库中。

## 验证入口

```bash
flutter analyze --no-pub
flutter test --no-pub test/application/ai_settings_controller_test.dart test/application/agent_controller_test.dart test/infrastructure/agent_http_test.dart test/infrastructure/agent_conversation_repository_test.dart test/agent_input_controller_test.dart test/agent_message_body_test.dart test/agent_ui_test.dart test/theme_mode_test.dart
```

本机 HTTP 契约测试真实经过 GetConnect，覆盖三种协议的模型目录、设置默认模型、思考参数、技能往返及后续聊天。控制器和组件测试还覆盖 `@` 分组 Popover 的独立宽度、会话命名、同名会话引用与目标 ID 映射、输入框内多引用高亮、删改解除关联、整段删除、输入法组词和重连失效、中英文长列表键盘定位、反复开关、模式持久化及保存失败重试、Enter/Shift+Enter 和输入法组词、审核模式切换、目标固定、批准/拒绝/停止、完全访问与输出返回模型、输出限额、重连失效，以及直接设置表单、复用 Key、迟到目录结果、思考签名回传、聊天、折叠保留输入、拖宽、800×600 macOS/Windows/Linux 主题布局及语言切换。历史测试覆盖新建保留、恢复续聊、删除当前和旧对话、保存失败重试、迟到响应隔离、只读命令恢复、数据库关闭重开及密文/密钥异常。它们不代表真实第三方服务商、Windows/Linux 原生运行或真实远程命令执行验收。实际服务商需在设置中提供用户自己的 URL、模型 ID 和 API Key 后测试连接。
