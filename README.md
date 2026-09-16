# Repo State

Repo State 为本机 Claude Code 和 Codex 会话建立 SQLite 全文索引，用来查找历史决定、接续会话、核对消息原文和读取工具执行证据。支持中文检索、按项目查询、持久忽略会话和本地 ZIP 打包。

本仓库是独立的纯本地版本。运行时没有服务器连接、会话上传、远端检索、遥测、自动更新或同步 hook。旧的 `sync.json`、`machine.json` 和服务器快照环境变量不会启用任何功能。索引与原始会话留在本机。

这是一次性提供的版本，不设后续维护或与其他仓库同步的流程。

## 安装

支持 macOS、Linux 和 WSL。需要 Python 3.11+，且该 Python 链接的 SQLite 为 3.43+ 并支持 FTS5。原生 Windows 不适用，因为程序使用 Unix 文件锁和信号；Windows 请在 WSL 中运行。

把仓库放在 `~/.agents/skills/repo-state`，Claude 与 Codex 可以共用这份技能。也可以放在其他目录，直接调用其中的脚本。

```bash
mkdir -p ~/.agents/skills
git clone https://github.com/xwysyy-studio/repo-state.git ~/.agents/skills/repo-state
python3 -m venv ~/.repo-state/venv
~/.repo-state/venv/bin/python -m pip install -r ~/.agents/skills/repo-state/requirements.txt
```

私有仓库克隆需要已有的 GitHub 访问权限。上面的 Git 克隆和 pip 安装是用户主动执行的获取步骤，会访问网络；程序运行时不会下载依赖或连接服务。公司电脑需要离线安装时，可先通过获准的渠道准备仓库文件和适配目标系统、CPU 与 Python 版本的依赖 wheel，再从本地目录安装：

```bash
~/.repo-state/venv/bin/python -m pip install --no-index --find-links /path/to/wheels \
  -r ~/.agents/skills/repo-state/requirements.txt
```

确认实际 Python 的 SQLite 能力后建立索引：

```bash
P=~/.repo-state/venv/bin/python
E=~/.agents/skills/repo-state/scripts/transcriptctl.py
"$P" -c 'import sqlite3; print(sqlite3.sqlite_version); c=sqlite3.connect(":memory:"); c.execute("CREATE VIRTUAL TABLE probe USING fts5(text, content=\x27\x27, contentless_delete=1)")'
"$P" "$E" index
```

技能调用脚本时应使用已安装依赖的 Python。虚拟环境可通过 `source ~/.repo-state/venv/bin/activate` 加入当前终端 PATH，或直接使用上面的绝对路径。

## 日常使用

在目标项目目录中运行，普通搜索默认只查该项目；跨项目查询显式加 `--all-projects`。

```bash
"$P" "$E" search '当时为什么选择这个实现' --speaker original-user
"$P" "$E" sessions --limit 10
"$P" "$E" get-session <session-id> --offset 0 --limit 6
"$P" "$E" context <message-id> --session <session-id> --before 2 --after 2
"$P" "$E" get-message <message-id> --session <session-id>
"$P" "$E" tool-history 'path/to/file'
"$P" "$E" get-tool <tool-id> --session <session-id> --part output
"$P" "$E" failures 'JSONDecodeError'
```

查询返回 JSON。检查退出码、`error` 和 `index_freshness.complete`；索引覆盖不完整时，不能据此断言最新会话不存在。长文本使用返回的 `next_offset` 继续读取，原始记录未保存的内容无法恢复。

忽略会话只修改本地策略和索引，原始会话文件不删除。取消忽略后，需要显式执行 `index` 才恢复收录。

```bash
"$P" "$E" ignore-session claude:<session-id> codex:<session-id>
"$P" "$E" ignored-sessions
"$P" "$E" unignore-session claude:<session-id>
"$P" "$E" index
```

详细取证流程见 [SKILL.md](SKILL.md)，程序化查询、分页和证据状态见 [查询接口](references/query-api.md)。

## 数据与执行边界

默认读取 `~/.claude/projects` 和 `~/.codex/sessions`，Codex 根目录也识别 `CODEX_HOME`。索引保存在 `~/.repo-state/transcripts.sqlite`，忽略规则在同目录的 `session-policy.json`，敏感读取审计日志默认为 `~/.repo-state/query-audit.jsonl`。

可通过 `REPO_STATE_CLAUDE_DIR`、`REPO_STATE_CODEX_DIR`、`REPO_STATE_DB`、`REPO_STATE_POLICY` 和 `REPO_STATE_AUDIT_LOG` 指定其他本地位置。前两项是 `.claude`、`.codex` 根目录。索引包含会话内容，应保存在本机数据目录中。

`query-python --trusted` 执行用户提供的 Python 代码，用于本地复杂聚合。它不是安全沙箱，提供的代码拥有普通 Python 进程的能力，必须自行信任；Repo State 不会为这段代码限制网络或文件访问。普通查询可以使用结构化 JSON `query` 接口。

`scripts/packctl.py` 只把明确指定的本地材料生成 ZIP，进行隐私检查、清单生成及字节核验，不上传 ZIP。该工具不是使用索引和检索的前置步骤。

## 验证

所有测试使用临时合成会话，不需要个人历史或服务器：

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
for phase in c d e f g h i; do
  bash "tests/phase_${phase}.sh" || exit 1
done
```

`test_local_only.py` 在真实 CLI 调用中拦截 socket、非预期子进程和服务器配置读取，覆盖建库、检索、原文读取、忽略、取消忽略和恢复索引。生命周期套件还检查中文检索、源文件变更、只读查询、工具证据及本地打包。
