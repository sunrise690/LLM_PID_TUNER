# LLM PID Tuner

这是一个面向 STM32 PID 调参实验的本地部署版工具。它把串口采样、响应指标计算、LLM 参数建议和安全回退串成一个闭环，目标是让已经能运行的控制系统更容易完成 PID 初调和细调。

本仓库基于开源项目 [KINGSTON-115/llm-pid-tuner](https://github.com/KINGSTON-115/llm-pid-tuner) 二次整理，并结合 [laigure/robot-control-prompts](https://github.com/laigure/robot-control-prompts) 中“真实采样、指标驱动、安全回退”的思路做了本地化封装。

## What This Is

这个仓库主要解决三个问题：

- 本地运行一个 CLI/TUI 版 LLM PID 调参器
- 通过串口读取 STM32 或其他控制板持续上报的控制数据
- 根据真实采样数据让 LLM 给出下一轮 PID 建议，并在结果变差时回退

它不是一键保证完美控制的工具，也不能替代硬件保护。真实设备调参前，请先保证限幅、急停、机械保护和电源保护都可靠。

## Local Layout

我本机的推荐目录结构是：

```text
D:\github\LLM_PID_TUNER\llm-pid-tuner-dev
```

如果把它作为 STM32 工程的外部工具调用，可以在 STM32 工程根目录保留很小的包装脚本：

```text
pid-tuner.bat
pid-tuner.ps1
PID_TUNER_USAGE.md
```

这样 STM32 工程不需要包含完整 Python 项目，只负责调用这个外部调参器。

## Quick Start

准备 Python 3.10+，然后在仓库目录中创建虚拟环境并安装依赖：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

复制配置模板：

```powershell
copy config.example.json config.json
```

编辑 `config.json`，至少填写：

```json
{
  "SERIAL_PORT": "AUTO",
  "BAUD_RATE": 115200,
  "LLM_API_KEY": "your-api-key",
  "LLM_API_BASE_URL": "https://api.openai.com/v1",
  "LLM_MODEL_NAME": "gpt-5.5",
  "LLM_PROVIDER": "openai"
}
```

检查环境：

```powershell
.\run-local.ps1 -Mode doctor
```

运行本地仿真：

```powershell
.\run-local.ps1 -Mode sim
```

连接真实硬件调参：

```powershell
.\run-local.ps1 -Mode tune
```

指定串口：

```powershell
.\run-local.ps1 -Mode tune -SerialPort COM5
```

## STM32 Telemetry Protocol

硬件模式默认期望 MCU 持续通过串口输出 CSV 数据：

```text
timestamp_ms,setpoint,input,pwm,error,p,i,d
```

字段含义：

- `timestamp_ms`: MCU 时间戳，单位 ms
- `setpoint`: 目标值
- `input`: 当前测量值
- `pwm`: 控制输出或执行器输出
- `error`: 当前误差
- `p/i/d`: 当前 PID 参数

PC 端会根据采样窗口计算平均误差、最大误差、超调、稳态误差和振荡状态，并把这些指标交给 LLM 生成下一轮建议。

## Tuning Rules

硬件调参时的核心原则：

- 只根据真实采样数据决策下一组 PID
- 没有采到有效遥测时，先修通信或协议，不继续盲调
- 每轮都观察超调、稳态误差、振荡次数和 PWM 行为
- 参数变化要保守，接近稳定时更要小步调整
- 响应变差或出现风险时，回退到已知最佳安全参数

这些规则已经写入硬件模式的 prompt context，位置在：

```text
sim/prompt_context.py
```

## Prompt Strategy

这个版本不是简单把采样数据丢给 LLM，而是在提示词里明确告诉模型：它必须像一个保守的嵌入式调参助手一样工作。

硬件模式会额外注入这些上下文：

```text
source: serial_hardware
serial_port: 当前串口
controller_output_signal: PWM
expected_telemetry_frame: timestamp_ms,setpoint,input,pwm,error,p,i,d
closed_loop_rule: 只能根据真实采样数据决定下一轮 PID
required_sample_policy: 每组参数都要先采样，再计算指标，再判断
scoring_policy_hint: 优先降低超调、稳态误差、振荡和 PWM 抖动
safety_policy_hint: 出现危险响应、通信中断或样本缺失时先回退
per_round_guardrail_hint: 真实硬件上不要激进地同时大幅调整 P/I/D
```

核心提示词位置：

```text
llm/prompts.py
```

硬件上下文位置：

```text
sim/prompt_context.py
```

如果要继续改调参风格，通常改这两处：

- `llm/prompts.py`：修改 LLM 的总体角色、输出 JSON 格式、P/I/D 调参顺序
- `sim/prompt_context.py`：修改真实硬件、仿真、Simulink 等不同模式的额外约束

本仓库借鉴了 `robot-control-prompts` 的几个提示词原则：

- 先扫描或确认控制对象和通信协议，再进入调参
- 每轮都必须有真实 samples 和 metrics
- 没有数据时不允许继续猜 PID
- 搜索策略应从粗调到细调，而不是随机跳参
- 输出结果要能追溯到指标，而不是只给一个参数结论

一个适合本项目硬件调参的简化提示词思路如下：

```text
你是一个嵌入式 PID 调参助手。
目标是在真实硬件安全的前提下，根据串口遥测数据迭代 PID。
你只能使用真实采样数据做判断。
如果样本缺失、通信异常或响应危险，必须先建议回退或修复通信。
每轮分析必须关注：平均误差、最大误差、超调、稳态误差、振荡次数、PWM 输出行为。
输出必须是合法 JSON，包含 analysis_summary、tuning_action、p、i、d、status。
```

## Full Prompt Template

下面是一份适合放进 AI IDE、ChatGPT、Claude Code 或其他可执行终端代理里的完整提示词。它更适合做“工程接入 + 协议适配 + 自动调参脚本生成”的任务；如果只是使用本仓库现有 CLI 调参器，一般不需要每次手动复制它。

```text
你是一个可执行终端命令的嵌入式 PID 调参代理。目标是对真实设备完成
“连接 -> 下发参数 -> 采样 -> 计算指标 -> 生成下一组参数 -> 安全校验 -> 继续迭代”
的闭环。禁止伪造数据。

1. 先做工程扫描并输出结论
- 扫描项目中与控制、通信、主循环、定时中断相关文件。
- 明确哪些文件负责 PID 参数、哪些文件负责通信收发、哪些位置发送遥测。
- 输出“将修改的文件列表 + 新增函数列表 + 验证方法”后再开始调参。

2. 通信方式必须做成可切换适配层
- 支持至少：Serial(UART/USB/蓝牙SPP)、BLE GATT、TCP/UDP。
- 可选扩展：CAN、MQTT、ROS topic。
- 所有通信统一抽象为接口：connect() / disconnect() / send_frame() / read_frames()。
- BLE 必须处理 MTU 分片；Serial/TCP 必须处理粘包拆包。

3. 脚本交付要求
- 生成可直接运行的 Python 脚本，推荐 asyncio 架构。
- 脚本最少包含模块职责：
  a) transport 适配层：多通信方式
  b) protocol 编解码层：命令帧、遥测帧、校验
  c) collector 采样层：按时间窗采集、丢包统计、时间戳对齐
  d) metrics 指标层：超调、整定时间、稳态误差、振荡、控制抖动等
  e) tuner 搜索层：粗搜 + 细搜
  f) safety 安全层：越界、振荡、倾倒阈值、回退
  g) reporter 输出层：排名表、JSON、日志
- 每轮必须记录：本轮参数、样本数、关键指标、得分、是否安全、是否回退。
- 出错时不得直接退出，优先重试或回退到最佳已知参数。

4. 协议与数据要求
- 命令帧至少支持设置 PID 参数并带 seq。
- 遥测帧至少包含：seq、t(ms)、setpoint、measured、control_output。
- 多环系统需额外上报每个环的 pv/u，例如 angle/speed/turn。
- 主循环必须持续周期上报，不得只在参数更新时上报。
- 若当前项目使用本仓库默认 CSV 协议，遥测行应为：
  timestamp_ms,setpoint,input,pwm,error,p,i,d

5. 调参策略
- 单次连接完成完整搜索，减少频繁重连。
- 第一轮粗搜索：覆盖主要增益变化方向，建议 10-20 组。
- 第二轮细搜索：围绕第一轮最优参数做 +/-5% 到 +/-15% 局部搜索。
- 每组参数流程固定：稳定等待 -> 采样窗口 -> 指标计算 -> 评分 -> 安全判断。
- 评分函数和目标阈值必须可配置。
- 参数每步变化幅度可限制，例如 <=30%，并有全局上下界。
- 若对象是高风险真实硬件，默认采用保守步长，禁止同时大幅提升 P/I/D。

6. 安全策略
- 任一高风险指标触发时立即停止或回退。
- 高风险指标包括：角度方差过大、超调过高、振荡次数过多、控制输出长时间饱和、
  样本缺失、通信中断、传感器异常、执行器异常。
- 回退时下发“当前最佳参数”，并验证设备恢复稳定后再继续。
- 发生通信中断时先重连；不成功则输出已完成结果和中断原因。

7. 对 STM32 项目的落地映射
- 先定位 PID 参数定义、控制循环、串口收发、定时器中断和主循环文件。
- 在串口接收路径中接入命令解析函数。
- 在主循环或定时周期中持续发送遥测帧。
- 遥测必须包含目标值、测量值、控制输出、误差、当前 PID 和时间戳。
- 如果是多环控制，需要分别上报每个环的 setpoint/pv/u 或 pv/u。
- 固件侧必须保留限幅、异常保护和人工停止手段。

8. 最终输出格式
- 先输出本轮执行命令与关键指标。
- 再输出最终 JSON：
{
  "best_pid": {
    "loop1": {"kp": 0, "ki": 0, "kd": 0},
    "loop2": {"kp": 0, "ki": 0, "kd": 0},
    "loop3": {"kp": 0, "ki": 0, "kd": 0}
  },
  "final_score": 0.0,
  "top_candidates": [
    {"rank": 1, "params": {}, "score": 0.0, "metrics": {}},
    {"rank": 2, "params": {}, "score": 0.0, "metrics": {}},
    {"rank": 3, "params": {}, "score": 0.0, "metrics": {}}
  ],
  "safety_events": [],
  "next_action": "是否建议继续细调及方向"
}

9. 执行约束
- 只能基于真实采样数据决策下一组参数。
- 未采到数据时必须先修复通信或协议，不得继续盲调。
- 所有关键决策都要给出指标依据。
- 不要为了看起来完成任务而伪造采样、评分或调参结果。
```

## Useful Commands

运行自检：

```powershell
.\run-local.ps1 -Mode doctor
```

本地仿真：

```powershell
.\run-local.ps1 -Mode sim
```

真实硬件：

```powershell
.\run-local.ps1 -Mode tune -SerialPort COM5
```

直接使用 Python 入口也可以：

```powershell
.\.venv\Scripts\python.exe launcher.py sim
.\.venv\Scripts\python.exe launcher.py tune COM5
.\.venv\Scripts\python.exe doctor.py
```

## Important Security Notes

不要把 `config.json` 上传到 GitHub，它里面可能包含 API Key。

本仓库的 `.gitignore` 已经忽略：

```text
config.json
.venv/
.pytest_cache/
__pycache__/
logs/
artifacts/
```

提交前可以检查：

```powershell
git status --short --ignored
git check-ignore -v config.json .venv
```

## Tests

运行测试：

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

如果只想快速确认 prompt 和启动器没有坏：

```powershell
.\.venv\Scripts\python.exe -m pytest -q tests\test_prompt_context.py tests\test_launcher.py
```

## Credits

本仓库是在以下项目基础上整理和本地化的：

- [KINGSTON-115/llm-pid-tuner](https://github.com/KINGSTON-115/llm-pid-tuner): LLM PID 调参器主体
- [laigure/robot-control-prompts](https://github.com/laigure/robot-control-prompts): 真实设备调参 prompt 与安全策略参考

这里保留原项目许可证文件。若继续分发或二次开发，请遵守上游项目许可证。
