---
name: repo-state
description: >-
  检索本机 Claude、Codex 会话、用户裁定和工具执行证据，维护本地会话忽略规则，
  按消息接续工作、追查文件修改或复盘协作摩擦；也可把指定本地材料打包为 ZIP。
  日常现状先读项目文档。本技能不包含网络同步、服务器检索或上传功能。
metadata:
  default_mode: direct
  write_policy: may_edit_inputs
  owner: dev
  version: 4.4.0
---

# Repo State

从原始会话恢复问题、事实与裁定，并取得可继续读取的证据。当前行为看代码和实际产物，当前目标看用户最新决定；历史用于解释来源，不能给模型过去的建议增加权威。

所有索引、查询、忽略规则和打包操作均在本机完成。安装和依赖要求见 [README](README.md)。

## 选择入口

脚本位于 `~/.agents/skills/repo-state/scripts/transcriptctl.py`。Claude 与 Codex 使用同一份引擎和索引。

| 要解决的问题 | 入口与后续读取 |
|---|---|
| 当前项目做到哪一步 | 先读项目指定的现状与当前阶段文档；文档缺信息时再查历史。 |
| 接手最近会话或指定会话 | 已有 session id 就读 `get-session`；否则 `sessions` 定位，再按页读取。 |
| 用户怎样决定过某件事 | `search` 带完整问题和 `--speaker original-user` 定位，再用 `context` 读相邻对话。 |
| 某个文件、命令或工具怎样用过 | `tool-history` 找工具身份，再用 `get-tool` 读对应参数或结果。 |
| 哪里发生过执行失败 | `failures` 按项目、时间或工具筛选，再用 `get-tool` 读完整错误。 |
| 已知消息原文或短确认 | `get-message` 读原文；`context` 查看确认所回应的内容。 |
| 跨多个会话做精确聚合 | 普通命令不足时读 [查询接口](references/query-api.md)，使用 `query` 或 `query-python --trusted`。 |
| 忽略旧会话、恢复收录 | 使用 `ignore-session`、`unignore-session` 和显式 `index`；规则只保存在本机。 |

```bash
E=~/.agents/skills/repo-state/scripts/transcriptctl.py
python3 "$E" search '当时为什么决定把配置条件放在产品介绍里' --speaker original-user
python3 "$E" context <message-id> --session <session-id> --before 2 --after 2
python3 "$E" get-session <session-id> --offset 0 --limit 6
python3 "$E" get-message <message-id> --session <session-id> --offset 0 --limit 10000
python3 "$E" tool-history 'path/to/file' --exclude-current-session
python3 "$E" failures 'JSONDecodeError' --after 2026-09-01 --tool Bash
python3 "$E" get-tool <tool-id> --session <session-id> --part input
python3 "$E" get-tool <tool-id> --session <session-id> --part output
```

会话排除策略独立保存在 `~/.repo-state/session-policy.json`，不随 SQLite 全量重建丢失：

```bash
python3 "$E" ignore-session claude:<session-id>
python3 "$E" ignore-session codex:<session-id>
python3 "$E" unignore-session <session-id>
python3 "$E" ignored-sessions
```

`ignore-session` 支持多个完整 ID，保留原始源文件，清理索引并阻止后续增量索引、全量重建、查询 overlay 再次收录。`unignore-session` 不自动读取源文件，普通查询不会重新摄入，需要显式运行 `index`。策略文件只记录身份、修订号和等待显式索引的记录，不保存正文。

`retention-candidates --older-than 180d` 只列出按最后活动时间筛选的会话身份和大小，供选择后批量忽略。

各子命令的 `--help` 给出实际参数。查询命令输出一个 JSON 对象，诊断信息在 `diagnostics` 内，结果在 `data`；参数错误、运行错误和输出预算不足返回非零状态及 `error`。程序化调用直接解析 stdout，再检查状态、错误与完整性。`query-python` 用 `result` 返回结果，脚本打印的信息进入诊断字段。不要为了取得 JSON 去裁剪命令输出。

## 找到足够的原始依据

先确定本次要补齐的具体缺口。跨项目裁定显式用 `--all-projects`；普通查询默认当前项目。`search`、`tool-history`、`failures` 都支持 `--session`、`--current-session`、`--exclude-current-session`，三者互斥。当前会话身份解析不可靠时，显式身份过滤会报错，不猜最近会话。

宽问题先保留完整题意。首轮不足时，从问题和已返回内容中选取有依据的文件、工具、错误名称或时间范围再次查询。不要机械增加返回条数或不断翻最近会话来代替定位。

`retrieval.lexical_match` 说明本次搜索的词法匹配：`exact_phrase`、`all_terms`、`partial_only`、`none`。后两者都不能证明历史中不存在该事；先换说法或检索入口，并核对索引完整性。词法命中也不能单独证明内容相关。精确消息 ID 另有 `direct_identity`，目标原文排在引用该 ID 的文字之前。

查用户意图先定位原始人类输入，再展开上下文。`original-user` 排除程序化任务书、压缩摘要和转发；一条“是的”需要连着前面的助手提案阅读。把用户原话、用户确认的提案、模型建议与工具观察分清，检查后来是否有新裁定。读完证据后说明它改变了当前哪个判断，并用实际产物验证要求的落实。

交接给当前问题、项目、原始会话和相关消息入口，新会话按需读取。独立审查给对象与原始依据入口，让审查者自行复原要求。已确认且持续有效的要求进入项目既有的现状或操作文档，并保留出处；日常执行沿这些入口工作，出现差异、缺口或新裁定时再回查。不另建历史台账或完整会话副本。

## 阅读与完整性

`get-session` 按消息身份保留发言顺序，包括不同阶段的相同回答。列表页的 `next_offset` 指向下一批消息；每条消息自己的 `next_offset` 指向尚未读完的正文，用 `get-message` 继续。`context` 返回锚点消息及前后可读原文，`more_before`、`more_after` 表示还有相邻消息，可用首条或末条的身份继续展开。逐页消费，重要原话读完；不要把多页重新拼成一个过大的工具返回。

消息以 `(session_id, uuid)` 定位，工具以 `(session_id, tool_id)` 定位。工具参数与结果分别验证来源并分页读取，纯工具消息应沿 `get-tool` 读取。缺失结果、来源失效和读取完成分别表述。正文、工具返回均来自实际记录；传输记录本身已截断的内容无法通过续读恢复。

每次结果检查 `index_freshness`。`complete=false` 或 `uncovered_changed_sources>0` 表示有新变更未覆盖；不能据此回答“最新”或做历史不存在的结论。主库锁定或只读时，临时 overlay 可覆盖新来源，是否可用由返回的覆盖状态决定。`--no-index` 明确跳过刷新，只用于冻结评测或已接受陈旧性的读取。

默认排除 thinking、注入载荷和被撤回替换的输入。显式点名消息仍返回其状态标签；`--include-meta`、`--include-abandoned` 只在需要追查这些内容时使用。撤回标签来自会话结构推断，不能把被标记输入当作有效裁定。敏感读取须通过审计接口；完整来源校验、范围语义、编程接口及评测方法见 [查询接口](references/query-api.md)。

## 摩擦复盘

用户要求复盘时读 [摩擦复盘方法](references/friction-audit.md)。围绕真实反馈复原从正确状态到错误状态的过程，分清工具失败、使用方法和目标理解问题。已有修复是否解决问题，要看后续使用与产物；配置修改按用户已经授权的范围执行。

## 外发打包

```bash
python3 ~/.agents/skills/repo-state/scripts/packctl.py <文件或目录> --topic <主题>
```

工具只生成本地 ZIP，不上传文件。任务要求写在 ZIP 根层 `TASK.md`，说明目标、输入材料和所需输出；`PROMPT.txt` 是工具生成的固定启动语。

输入冻结后完成隐私扫描、SHA-256 清单及 ZIP 逐字节校验。raw transcript、hidden thinking、密钥、symlink 与 realpath 越界不可豁免；仅不确定的隐私检查 finding 可按工具给出的前缀使用 `--ack PREFIX:REASON`。默认排除 `.git`、`.env*`、SQLite、transcript、cache、`exchange/`、`artifacts/`。

批次默认进入当前项目的 `exchange/<date>-<topic>/`，包含材料、清单及字节校验结果。不要把批次放进技能发现目录，以免材料中的技能文件被再次收录。
