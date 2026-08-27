# ReceivedAttention 主机 Tiling 双轨复现、构建与验证任务书

## 1. 任务目标

本任务在具备真实 CANN、AscendC 编译工具链和目标平台信息的环境中，执行两条相互独立的主机侧实现与验证路线。

### 路线 A：现有源码增量验证

以导出包中的 `attention/received_attention` 源码为起点，完整阅读《ReceivedAttention 算子主机 Tiling 实现与真实 CANN 环境验证交接指南》，在现有实现上增量完成：

1. CANN API、宏和构建系统适配；
2. op_host 编译和链接；
3. 生产 planner 单元测试接入；
4. `TilingContext` 注册、路由和 TilingData 测试；
5. 主机侧合法/非法输入功能测试；
6. 对真实环境暴露的问题进行最小范围修复；
7. 保存完整构建、运行、测试和修复证据。

### 路线 B：仅凭交接指南盲实现

物理屏蔽路线 A 的 RA 源码、Git 历史、测试、构建产物和对话上下文。实现 AI 只能把交接指南作为 RA 专有语义来源，可以参考仓库中 FIA Arch22/V3、attention 公共模块和目标 CANN 公开接口，从头实现：

```text
attention/received_attention_opencode
```

新算子框架名称为：

```text
ReceivedAttentionOpencode
```

它应与 `ReceivedAttention` 具有相同的输入输出语义、主机 tiling 方法、两阶段分核策略、Workspace 协议和可观察行为，但必须使用独立名称，能够与原算子同时编译和注册，不发生符号冲突。

### 本轮边界

本轮“构建、运行”至少必须覆盖：

```text
op_host真实编译和链接
纯主机生产调度器测试
InferShape/InferDataType测试
TilingContext路由与TilingData测试
非法输入失败路径测试
CPU reference或独立集合oracle测试
```

当前导出源码不包含完整设备 kernel，因此本任务不允许把空 kernel、固定输出或无条件成功的 stub 宣称为端到端数值运行成功。若仓库构建流程强制要求 kernel，可以添加明确标记为“仅供构建接入、不可用于数值验收”的最小 stub；主机任务的完成状态必须与设备端到端状态分开报告。

## 2. 权威资料与优先级

RA 业务和主机设计的权威说明是：

```text
ReceivedAttention算子主机Tiling实现与真实CANN环境验证交接指南.md
```

若资料之间存在冲突，按以下顺序处理：

1. 本任务书规定实验过程、隔离规则和验收方式；
2. 交接指南规定 RA 的业务语义、Tiling 契约和已知缺口；
3. 目标环境当前版本的 CANN 头文件、宏定义和构建规则决定具体 API 写法；
4. FIA Arch22/V3 和 attention 公共源码用于理解框架接法；
5. 路线 A 的已有源码仅对路线 A 可见，不能成为路线 B 的信息源。

遇到交接指南与目标 CANN 版本不一致时，不得悄悄改变业务语义。应记录差异、给出适配理由，并用测试证明适配前后的可观察契约一致。

## 3. 角色和执行顺序

建议由四个角色完成实验；角色可以由人或相互隔离的 AI 会话承担：

```text
实验控制者
    准备两套工作区、执行信息隔离、保管隐藏测试和最终对照结果

路线A实现者
    可读取完整导出源码和全部RA文档，负责增量修复与验证

路线B实现者
    只能进入净化工作区，只能读取交接指南和非RA公共参考代码

最终验收者
    路线B提交冻结后，执行两算子的黑盒对照和隔离审计
```

强制顺序：

```text
准备并审计两个隔离工作区
-> 路线A独立实现和冻结
-> 路线B在持续隔离下独立实现和冻结
-> 最终验收者解除单向隔离并进行黑盒对照
-> 最后才允许源码结构对照
```

路线 B 冻结前，禁止把路线 A 的错误信息、补丁、源码 diff、测试 golden、构建日志或实现建议转发给路线 B。

## 4. 工作区准备与隔离

### 4.1 推荐目录

在真实环境中建立三个彼此独立的目录，不要让两个实现共用 build 目录、编译缓存或 IDE 索引：

```text
<experiment_root>/
  track_a_full_source/
  track_b_blind_source/
  evaluator_only/
```

`track_a_full_source` 接收完整导出包。

`track_b_blind_source` 应从不含 RA 的基础仓库快照创建，只额外放入：

```text
spec/ReceivedAttention算子主机Tiling实现与真实CANN环境验证交接指南.md
spec/ReceivedAttention主机Tiling双轨复现构建与验证任务书.md
```

第二份任务书只规定过程和验收；路线 B 的 RA 专有实现语义仍必须追溯到第一份交接指南。

`evaluator_only` 保存隐藏测试、两条路线的标准化 dump 和最终比较报告。在路线 B 冻结前，不向路线 B 挂载该目录。

### 4.2 路线 B 必须排除的内容

净化副本中必须排除：

```text
attention/received_attention/**
任何其它RA设计md，交接指南除外
路线A的Git提交、补丁、diff和分支
路线A的测试源码、golden、日志和构建产物
包含RA源码历史的.git目录
IDE索引、编译数据库和缓存
本次历史对话、AI记忆、线程摘要和先前代理输出
```

仅删除工作树文件但保留原 `.git` 不算隔离，因为实现者仍能用 `git show` 恢复源码。推荐从基础仓库生成不带 `.git` 的净化归档，再在净化目录中执行新的 `git init`。

路线 B 可以读取：

```text
目标CANN安装目录中的公开头文件和示例
仓库构建脚本
attention/fused_infer_attention_score的Arch22/V3源码和测试
attention/common中的公共结构与算法
其它非RA算子的注册、InferShape和UT示例
官方CANN文档
```

路线 B 禁止通过网络、远程 Git、对象缓存或其他工作区搜索 `received_attention` 原实现。若需要访问官方文档，搜索范围不得包含原 RA 分支、提交号或源码文件名。

### 4.3 隔离审计

路线 B 开始前由实验控制者执行并保存结果：

```bash
pwd
find . -path '*/attention/received_attention' -o -path '*/attention/received_attention/*'
find . -iname '*received_attention*'
find . -name '.git' -type d
find . -name 'compile_commands.json' -o -name 'CMakeCache.txt'
```

预期只出现 `spec` 中的两份文档；开始实现后才允许出现 `attention/received_attention_opencode`。

还应保存净化目录的文件清单和 SHA-256 清单。若实现 AI 曾访问禁止内容，本轮路线 B 状态立即标记为：

```text
CONTAMINATED
```

污染轮次不得继续作为盲实现结果，应保留污染记录，重新创建净化目录并启动无继承上下文的新会话。

## 5. 两条路线共同遵守的工程规则

1. 修改必须限制在各自算子目录、对应测试目录及必要的顶层构建接入文件中。
2. 不得修改 FIA 或 attention 公共实现来掩盖本算子的错误；确需修复公共模块时，单独提交并解释影响范围。
3. 主机测试必须调用生产实现，不能在测试中复制一套调度算法再让两份复制互相证明。
4. CPU oracle 必须从数学定义直接枚举，不得调用生产 planner 生成预期结果。
5. 不得通过删除测试、弱化断言、扩大误差或修改 golden 来掩盖失败。
6. 每解决一个独立问题就形成一个小提交，禁止把环境适配、业务改写和测试删除混在同一提交中。
7. 所有失败命令和原始日志必须保留；只展示最终成功日志不算完成。
8. 任何整数乘加、字节偏移和数组索引都要执行溢出及范围检查。
9. 正式结果不得依赖未纳入版本控制的手工文件或上一次构建残留。
10. 最终提交前执行 clean build，证明结果可从干净状态复现。

## 6. 路线 A：基于现有源码增量完成

### A0. 建立基线

先保存：

```bash
git status --short --branch
git log -5 --oneline
git rev-parse HEAD
sha256sum /path/to/received_attention.zip
```

编写本任务书时的已知源码节点为：

```text
77ebf93  feat(received_attention): complete host tiling pipeline
156face  refactor(received_attention): retire task-book ABI and document handoff
```

若导出包保留 Git 历史，应至少包含上述两个节点；若是无 Git 的源码归档，则以归档 SHA-256 和文件清单为基线，不要只依赖文档中的旧节点号。

检查 `attention/received_attention` 中生产文件、测试和交接指南齐全。不要恢复已废除的显式 task-book 原型；当前生产调度协议是固定布局 TilingData 加每核右开终点。

创建独立分支，例如：

```text
ai/received-attention-realenv-validation
```

### A1. 记录真实工具链

根据实际安装位置加载 CANN 环境，然后保存：

```bash
source /usr/local/Ascend/cann/set_env.sh
cmake --version
c++ --version
bisheng --version || true
ccec --version || true
npu-smi info || true
env | sort
```

`set_env.sh` 路径必须按现场安装调整。环境日志可能含敏感路径或令牌，提交前应脱敏，但原始日志应保存在受控验证目录。

### A2. 首次 op_host 编译

先阅读目标仓库当前 `build.sh --help`，再使用仓库原生命令。当前仓库可优先尝试：

```bash
bash build.sh --ophost --module=attention --soc=ascend910b -j16 -O0
```

如果现场 SoC 不是 `ascend910b`，改为目标 Arch22/V3 对应值并记录原因。首次构建必须保存完整 stdout、stderr 和退出码。

检查产物和符号：

```bash
find build output -name '*ophost*' -o -name '*received_attention*'
nm -C /path/to/libophost_transformer.so | grep -E 'ReceivedAttention|DoOpTilingReceivedAttention|RaTilingNonQuant'
```

首次构建的验收点：

- schema、InferShape、tiling 注册和 Arch22 源文件真实进入编译；
- `ra_sparse_range.cpp`、`ra_stream_length_split.cpp` 和 `ra_tiling_nonquant.cpp` 被链接；
- `attention/common/op_host/split_core.cpp` 不产生缺符号或重复符号；
- 静态 tiling 注册对象没有被链接器裁掉；
- 不依赖设备 kernel 即可构建 op_host，或将构建系统限制清楚标记。

### A3. 增量修复原则

对每个编译错误执行：

```text
记录原始错误
-> 在目标CANN头文件或FIA同架构源码中确认真实接口
-> 做最小适配
-> 只重编受影响目标
-> 重新执行相关测试
-> 单独提交
```

首次 CMake 配置成功后，优先直接构建已有对象目标，以避免每次全量清理。实际目标名以生成结果为准，可从下面的候选命令开始：

```bash
cmake --build build --target ophost_transformer_tiling_obj -j16 --verbose
cmake --build build --target ophost_transformer -j16
```

高优先级核查：

- `TilingInputsDataDependency` 在目标版本中的参数形式；
- optional tensor/desc 的读取 API；
- `PlatformAscendC::CalcTschBlockDim` 签名；
- libapi Workspace 查询和 `GetUserWorkspace()` 契约；
- TilingData 宏对 `uint64_t` 和数组的布局支持；
- `OP_LOG*` 格式化类型；
- 自有 tiling registry 的静态初始化与链接保留；
- `split_core.cpp` 是否应直接加入目标还是链接公共库。

不得为了通过编译删除输入校验、Workspace 溢出保护、阶段完整组约束或框架注册。

### A4. 把测试接入仓库框架

现有纯 C++ 分核测试首先可以直接编译运行，且不能定义 `NDEBUG`：

```bash
mkdir -p build/ra_host_tests
c++ -std=c++17 -O0 -g \
  attention/received_attention/tests/test_ra_stream_length_split.cpp \
  attention/received_attention/op_host/arch22/ra_stream_length_split.cpp \
  -o build/ra_host_tests/test_ra_stream_length_split
build/ra_host_tests/test_ra_stream_length_split
```

随后仿照 FIA 的测试结构建立正式 UT 接入：

```text
attention/received_attention/tests/CMakeLists.txt
attention/received_attention/tests/ut/CMakeLists.txt
attention/received_attention/tests/ut/op_host/CMakeLists.txt
attention/received_attention/tests/ut/op_host/arch22/CMakeLists.txt
```

Arch22 tiling UT 应使用仓库已有 `add_modules_ut_sources`、`gert::TilingContextPara` 和公共测试框架，禁止另造一套与正式入口脱节的 mock ABI。

根据现场 `build.sh test` 帮助选择命令，候选形式为：

```bash
bash build.sh --ophost_test --ops=received_attention --soc=ascend910b -j16
ctest --test-dir build -R received_attention --output-on-failure
```

如果命令形式与现场仓库不兼容，记录实际可用命令，不要静默跳过正式 UT。

### A5. `TilingContext` 路由冒烟

测试必须从正式注册或正式入口发起，确认调用链实际到达非量化 Arch22/V3 模板。至少检查：

```text
返回状态
InferShape输出[T]
InferDataType输出FP32
tiling key
schedule mode
numBlocks/blockDim
raw TilingData长度和反序列化结果
Workspace总量和业务区布局
```

actual-length 测试张量必须提供可被 `GetData<int64_t>()` 读取的真实 host 数据。只设置 shape、不提供 host value 不能代表精确 tiling 路线通过。

### A6. 完成已知主机缺口

交接指南标明 `isMaxWorkspace` 尚未实现。真实环境应先确认框架是否会在 actual-length 数据不可读时调用最大 Workspace 路线：

- 若目标 CANN 版本提供并要求该流程，本轮必须增量实现、测试并单独提交；
- 若接口不可获得或构建场景根本不会触发，必须保留失败证据并将该项标记为 `BLOCKED` 或明确的扩展项；
- 不允许把精确 tiling 失败后无条件返回一个常量大空间当成正式实现。

测试和对照必须把两种能力分开编号：

```text
M0：当前精确tiling基线
    actual-length host data可读；数据不可读时预期明确失败

M1：max-workspace扩展
    actual-length host data不可读；只生成安全Workspace上界
```

先冻结并通过 M0，再决定是否实现 M1。若本轮实现 M1，路线 A 和路线 B 必须各自独立完成，最终对照不能把一条路线的 M1 与另一条路线的 M0 混为“等价”。

## 7. 路线 B：仅凭交接指南从头实现

### B0. 开始前确认

路线 B AI 在第一次修改文件前必须输出：

```text
当前工作目录
可见RA专有资料清单
禁止访问目录清单
允许参考的FIA/common目录
隔离扫描结果
```

若能看到 `attention/received_attention`、路线 A 分支、原 `.git` 历史或路线 A 构建目录，应立即停止，不得继续实现。

### B1. 独立命名规则

所有新文件放在：

```text
attention/received_attention_opencode/
```

至少保证下列外部符号独立：

```text
目录/OPTYPE             received_attention_opencode
框架算子类型             ReceivedAttentionOpencode
tiling入口               DoOpTilingReceivedAttentionOpencode
V3入口                   TilingReceivedAttentionOpencodeV3
总TilingData             ReceivedAttentionOpencodeTilingData
TilingData注册类          ReceivedAttentionOpencode_0
测试过滤名                received_attention_opencode
```

内部类可以使用 `Rao`、`RaOpen` 或完整 `ReceivedAttentionOpencode` 前缀，但不得导出与原 RA 相同的全局符号。

新算子应能与 `ReceivedAttention` 同时存在于同一仓库中：

```text
两者都可注册
两者都可构建
测试可分别过滤
TilingData注册名不冲突
CMake目标和生成文件不覆盖
```

### B2. 允许参考与禁止复用

路线 B 可以按交接指南的阅读方向研究 FIA Arch22/V3 和 attention 公共 API，但必须自己编写 RA 专有代码。

禁止：

```text
include attention/received_attention中的任何文件
复制或改名原RA源码
cherry-pick原RA提交
读取原RA测试后照抄golden
链接原RA目标来替代新实现
生成代码时把原RA目录作为模板输入
```

允许直接复用的是仓库已有公共模块及其公开结构，例如 FIA/common 中本来就供多算子使用的接口；每一项公共复用都应记录到 `PROVENANCE.md`。

### B3. 从头实现顺序

严格按以下顺序推进，每一步都要先编译再进入下一步：

1. 新算子目录和 CMake 接入；
2. schema、输入顺序、属性、输出定义；
3. InferShape 和 InferDataType；
4. tiling compile info、输入索引和 TilingData；
5. `IMPL_OP_OPTILING` 注册与数据依赖；
6. SoC 入口和 Arch22/V3 路由；
7. tiling 模板 registry、base class 和非量化模板；
8. 输入解析与统一 request actual-length helper；
9. tile 尺寸、sparse 范围和阶段一任务流；
10. 阶段二转置列任务流；
11. 流长分核器和每核右开终点；
12. Workspace 布局、溢出检查和 TilingData 填充；
13. numBlocks、BATCH_MODE、tiling key 和 Context 提交；
14. 单元测试、TilingContext 测试和失败路径；
15. 目标版本需要时实现 `isMaxWorkspace`。

每个阶段只能依据交接指南和公共框架接口作出 RA 语义决定。指南未明确而又会改变输出或 ABI 的问题，必须写入 `OPEN_QUESTIONS.md`，不得查看路线 A 寻找答案。

### B4. 构建和测试

路线 B 使用独立 build 目录，候选主机构建命令为：

```bash
bash build.sh --ophost --module=attention --soc=ascend910b -j16 -O0
```

正式 UT 的候选命令为：

```bash
bash build.sh --ophost_test --ops=received_attention_opencode --soc=ascend910b -j16
ctest --test-dir build -R received_attention_opencode --output-on-failure
```

必须至少完成：

- planner 纯主机测试；
- InferShape/InferDataType 测试；
- `TilingContext` 注册和路由测试；
- TilingData 字段与 Workspace 测试；
- 合法和非法输入测试；
- 与数学定义独立的 CPU oracle 或稀疏 tile 集合 oracle；
- clean build；
- 泄漏扫描和未授权依赖扫描。

### B5. 冻结规则

路线 B 完成后，在查看任何路线 A 信息前执行：

```bash
git status --short
git diff --check
git log -10 --oneline
git rev-parse HEAD
```

然后生成源码、测试和日志的 SHA-256 清单，把最终提交标记为“blind frozen”。冻结 SHA 产生后才能把结果交给最终验收者。

## 8. 两条路线共用的主机测试矩阵

两条路线必须运行语义相同的测试矩阵，但测试源码应在各自路线中独立编写。最终验收者另行持有一份不依赖任一实现细节的黑盒测试。

### 8.1 基础合法场景

至少覆盖：

1. 单 request、单 KV head、`G=1`、无 mask、Q/KV 均小于一个 tile；
2. 单 request、GQA、多 KV head、每个 KV head 对应多个 Q head；
3. 多 request、Q 累计长度、KV 每 request 独立长度；
4. 相邻 Q 累计终点相同形成空 request；
5. FP16 query/key cache；
6. BF16 query/key cache；
7. sparse mode 0；
8. sparse mode 3 和 FIA 兼容的 `2048 x 2048` mask；
9. `qLen < kvLen` 的历史 KV 偏移因果场景；
10. page size、KV 长度和当前后缀起点均不凑 tile。

### 8.2 tile 边界

Q 和 KV 长度至少覆盖：

```text
0
1
511
512
513
1023
1024
1025
```

重点验证：

- Q 尾 tile；
- KV 尾 tile；
- 当前 Q 后缀起点落在 S2 tile 中间；
- 历史-only S2 列被阶段二剪掉；
- 第一个同时含历史和当前 token 的混合 tile 被保留，并由设备协议进一步裁剪；
- 空 request 不产生有效任务但不破坏字典序游标。

### 8.3 分核与覆盖

平台/测试桩分别设置：

```text
1个AIC / 2个AIV
2个AIC / 4个AIV
20个AIC / 40个AIV
核数大于不可拆分组数
```

必须验证：

- 阶段一遍历顺序和稀疏范围符合交接指南；
- 一条完整 S1G tile 行不跨 AIC；
- 阶段二一个完整 `(b,S2 tile)` 列包含全部 N2 与有效 S1G，不跨 AIC；
- 每个有效二维 tile 恰好被覆盖一次；
- 无效 tile 不进入任务流；
- 每核右开终点单调；
- core `i` 的起点等于 core `i-1` 的终点；
- 最后一核终点等于稀疏任务流的全局末尾；
- 任务不足时允许空核，所有已启动核仍保留阶段屏障参与资格；
- 超过动态流长帽的第一个完整组被 force 接收，而不是拆成单 tile。
- 端点数组中 `[usedCoreNum, capacity)` 的未使用元素保持确定的零值。

### 8.4 Workspace 和算术安全

必须验证：

- QK relay 按 `usedCoreNum × ping/pong × qkResSize × sizeof(float)` 预算；
- 两阶段复用同一 relay，空间取最大而不是相加；
- 每个 AIC 的两个槽互不重叠；
- `rowStatsCount == T * num_q_heads`；
- rowMax 与 rowInvSum 均为 FP32 数组；
- 各业务 offset 至少 32 字节对齐；
- QK relay、rowMax、rowInvSum 不重叠；
- CANN libapi reserve 与业务 Workspace 基址契约符合目标版本；
- checked add/multiply/align 能拒绝溢出；
- TilingData 数组容量能覆盖 `usedCoreNum`，不能越界写入。
- raw TilingData buffer 容量恰好足够时成功，少一个字节时安全失败，不能静默截断。

### 8.5 框架与 ABI

合法 case 至少检查：

```text
GRAPH_SUCCESS
输出shape为[T]
输出dtype为FP32
路由到Arch22/V3非量化模板
模板优先级符合约定
tilingKey为当前约定值
scheduleMode为BATCH_MODE
numBlocks由目标平台CalcTschBlockDim产生
raw TilingData长度正确
各子结构字段可正确反序列化
workspaceSize等于libapi reserve加业务区
```

FP16 和 BF16 当前可共用主机 tiling key，但必须各跑一个 Context case；不得因为共用 key 而忽略输入 dtype 验证。

还应加入两类 metamorphic 测试：

- 只改变合法 block table 中的物理 page id，不改变 shape，主机 tiling 不应改变；
- 只改变 `scale`，分核终点、Workspace、key 和 blockDim 不应改变，只有下发的 scale 字段变化。

### 8.6 非法输入

至少验证以下输入稳定返回失败并产生日志：

```text
query不是3维TND
key_cache不是3维paged cache
query和key_cache dtype不一致
query或key_cache不是FP16/BF16
headDim不一致
num_q_heads不能被num_kv_heads整除
actual_seq_lengths缺失、dtype错误或维数错误
actual_seq_lengths_kv缺失、dtype错误或维数错误
Q累计结束位置非单调
Q累计最后值不等于T
qLen大于kvLen
KV长度超过block_table可表达容量
block_table缺失、dtype错误或shape错误
sparse mode不受支持
sparse mode 3的mask缺失或shape不合法
receivedCount上界溢出
任务计数、Workspace字节数或展平坐标溢出
平台AIC/AIV比例不满足Arch22约定
平台AIC数超过TilingData端点数组容量
```

### 8.7 统一代表性 case

两条路线和最终隐藏验收都应包含以下自洽场景：

```text
query                  [1564, 16, 256]
key_cache              [1336, 128, 1024]
num_q_heads            16
num_kv_heads           4
G                       4
D                       256
actual_seq_lengths      [1536, 1564]
actual_seq_lengths_kv   [1536, 1500]
block_table             [2, >=12]
sparse_mode             3
atten_mask              [2048, 2048]
scale                   1/sqrt(256) = 0.0625
received_score          [1564], FP32
```

该 case 明确把 query 第二维 `16` 解释为 16 个 Q head。若要验证 32 个 Q head，必须把 query 改成 `[1564, 32, 256]`，并重新计算 `G`、`rowStatsCount`、任务流和 Workspace；不得同时声称 shape 第二维为 16、Q head 数为 32。

必须检查：

```text
B                 = 2
qLen              = [1536, 28]
qPackedStart      = [0, 1536]
currentKvStart    = [0, 1472]
N2                = 4
G                 = 4
rowStatsCount     = 1564 * 16 = 25024
qTileSize         = 512
kvTileSize        = 512
s1Size            = 1536
s2Size            = 1536
```

其余任务流和每核终点应由独立集合 oracle 展开验证，不要把路线 A 的二进制 TilingData 直接当作路线 B 的预期答案。

## 9. 独立 oracle 要求

### 9.1 稀疏 tile 集合 oracle

测试侧直接按 request、head、Q token、KV token 和 sparse 规则枚举有效元素，再投影到 `(S1G tile,S2 tile)`。它用于验证：

```text
阶段一有效tile集合
阶段二转置后的有效tile集合
历史列剪枝
覆盖次数
完整行/列所有权
```

oracle 不得调用生产 `CalcS2Range`、生产 request helper 或生产流长 planner。

### 9.2 CPU 数学 reference

若本轮增加主机数学 reference，应直接：

1. 通过 block table 还原逻辑 K；
2. 使用 FP32 计算 scaled QK；
3. 应用 sparse mask；
4. 每行计算稳定 softmax；
5. 对每个逻辑 KV token 的有效贡献求和和计数；
6. 对贡献取平均；
7. 只把当前 Q 对应 KV 后缀写到 packed `[T]`。

没有设备 kernel 时，该 reference 用于冻结数学语义和未来设备测试输入，不得被描述成硬件算子运行结果。

## 10. 路线 B 冻结后的双实现对照

最终验收者应在相同 CANN、编译器、SoC 配置和测试输入下分别调用：

```text
ReceivedAttention
ReceivedAttentionOpencode
```

先做黑盒对照，不先看源码 diff。

### 10.1 标准化 dump

为两个算子各自反序列化 TilingData，输出不含 C++ 类型名前缀的中性 JSON：

```text
status
outputShape
outputDtype
baseParams
pageAttentionParams
maskParams
splitParams
workspaceParams
tilingKey
scheduleMode
numBlocks
expandedStage1TileOwnership
expandedStage2TileOwnership
```

JSON 中应同时保留：

- 原始每核右开终点；
- 展开后的有效 tile 集合；
- 每个完整行/列的 owner core；
- Workspace 每个区间的 `[begin,end)`。

### 10.2 必须精确相同的项目

除算子名称和注册符号前缀外，相同输入和平台下至少应精确一致：

```text
成功/失败判定
输出shape和dtype
基础维度与派生长度
sparse/mask/page参数
tile尺寸
stage1/stage2任务总流长
每核任务终点
rowStatsCount
业务Workspace各offset和大小
tiling key
schedule mode
numBlocks
```

若因目标 CANN 版本适配导致二者字段布局不同，必须证明标准化后的语义完全一致，并解释为什么设备消费者不会产生歧义。

交接指南没有逐字节冻结所有 C++ packing 细节，因此盲实现验收不得把 raw TilingData 二进制哈希作为唯一硬门槛。raw hash 只用于同一实现、同一编译器下的回归；跨实现正确性以字段级标准化结果、任务覆盖和独立消费者可解析性为准。

### 10.3 必须满足但不要求源码相同的项目

```text
所有有效tile恰好一次覆盖
完整S1G行不跨核
完整(b,S2)列不跨核
不同N2在阶段二同列内完成合并
历史token不写入[T]
Workspace区域不重叠
错误输入被拒绝
无未授权依赖
```

路线 B 冻结后才允许查看源码差异。源码相似度不作为正确性的主要依据；黑盒行为、ABI、覆盖集合和测试证据才是最终依据。

## 11. 日志、报告与提交要求

两条路线都应建立：

```text
PROVENANCE.md
EXPERIMENT_LOG.md
KNOWN_GAPS.md
OPEN_QUESTIONS.md
test-results/<timestamp>/
```

### 11.1 `PROVENANCE.md`

记录：

- 起始仓库/导出包哈希；
- 可读取和禁止读取的资料；
- 参考过的 FIA/common/CANN 文件；
- 路线 B 的净化和隔离证明；
- 使用过的 AI 会话、模型或人工参与边界。

### 11.2 `EXPERIMENT_LOG.md`

每次构建或测试至少记录：

```text
时间
工作区和commit SHA
完整命令
退出码
stdout/stderr文件
CANN、编译器和SoC信息
结果分类
失败分析
采取的修改
复测命令和结果
```

### 11.3 `KNOWN_GAPS.md`

明确区分：

```text
主机已完成
主机未完成
因环境阻塞
设备kernel未实现
设备端到端未运行
性能未优化
```

### 11.4 提交

建议至少形成：

```text
构建/API兼容修复提交
生产planner测试提交
TilingContext/ABI测试提交
max-workspace提交（若实现）
最终验证文档提交
```

每条路线最终必须报告：

```text
分支名
起始SHA
最终SHA
git status
提交列表
源码清单
构建命令
测试命令
通过/失败/跳过数量
原始日志路径
产物路径和SHA-256
已知缺口
```

## 12. 状态定义和禁止性规则

最终状态只允许使用：

```text
PASS
    所有本轮强制主机构建、运行、测试和隔离要求均满足

PARTIAL
    核心路径可运行，但仍有明确未完成的强制项

BLOCKED
    因缺少真实工具链、框架能力、权限或硬件信息无法继续

CONTAMINATED
    路线B接触了被禁止的原RA实现信息

FAIL
    环境具备条件，但实现或测试未达到验收标准
```

禁止：

- 把“编译成功”写成“功能测试通过”；
- 把 standalone helper 测试写成“框架路由通过”；
- 把 host tiling 通过写成“设备数值通过”；
- 把未执行的测试记为通过；
- 因缺少 kernel 而伪造输出；
- 删除失败日志或只保留最后一次成功；
- 在路线 B 冻结前进行任何源码或 golden 对照。

## 13. 最终验收门槛

### 13.1 路线 A 完成

- 从干净状态完成 op_host 编译和链接；
- 正式 planner UT 和 `TilingContext` UT 全部运行；
- 框架注册能够路由到 Arch22/V3 非量化模板；
- 合法/非法输入矩阵通过；
- TilingData、blockDim、BATCH_MODE 和 Workspace 得到现场验证；
- 所有真实环境适配均有独立提交和证据；
- 没有把设备 stub 当作数值完成。

### 13.2 路线 B 完成

- 隔离审计通过且未污染；
- `ReceivedAttentionOpencode` 从零实现并独立注册；
- 不包含对 `attention/received_attention` 的 include、链接或生成依赖；
- 可与原算子同时构建，无符号、注册名和产物冲突；
- 运行与路线 A 等价的完整主机测试矩阵；
- clean build 和最终冻结提交可复现。

### 13.3 双轨实验完成

- 两个冻结 commit 均可获取；
- 最终验收者在同一环境运行统一隐藏测试；
- 标准化 TilingData 和任务所有权对照通过；
- 非法输入接受/拒绝行为一致；
- Workspace 和框架元数据一致；
- 路线 B 无信息泄漏；
- 最终报告明确区分主机完成与设备未完成边界。

## 14. 可直接交给两个 AI 的任务摘要

### 给路线 A AI

> 你可以读取导出包中的 `attention/received_attention` 全部源码和文档。请以交接指南为规格，以真实 CANN 环境为准，在现有源码上增量完成 op_host 构建、正式 planner UT、InferShape/InferDataType UT、TilingContext 注册与路由测试、TilingData/Workspace 测试和非法输入测试。所有修改必须最小化并分提交；保留每次失败的完整命令和日志。没有设备 kernel 时，只能报告主机 tiling 已运行，禁止宣称端到端数值成功。最终提交验证报告、日志索引、产物哈希、已知缺口和冻结 commit SHA。

### 给路线 B AI

> 你处在一个已净化的工作区。RA 专有语义只能来自 `spec/ReceivedAttention算子主机Tiling实现与真实CANN环境验证交接指南.md`；你可以参考本仓库 FIA Arch22/V3、attention/common 和目标 CANN 公开接口，但严禁访问、恢复、搜索、复制或链接原 `attention/received_attention` 源码、历史、测试、日志及对话。请从头实现 `attention/received_attention_opencode`，框架算子名为 `ReceivedAttentionOpencode`，完成与交接指南一致的主机注册、InferShape/InferDataType、Arch22/V3非量化路由、输入解析、两阶段流长分核、TilingData、Workspace和主机测试。新算子必须能与原算子同时注册。保留完整失败记录，在查看任何对照信息前提交并冻结 SHA；一旦发生信息泄漏，立即标记 `CONTAMINATED` 并停止本轮。

## 15. 最终报告模板

```markdown
# ReceivedAttention 双轨真实环境验证报告

## 环境
- OS：
- CANN：
- 编译器：
- SoC：
- 基础仓库SHA：

## 路线A
- 起始/最终SHA：
- 构建状态：
- 测试状态：
- 主要修复：
- 产物与日志：
- 已知缺口：

## 路线B
- 隔离审计：PASS/CONTAMINATED
- 起始/最终SHA：
- 构建状态：
- 测试状态：
- 允许参考资料：
- 产物与日志：
- 已知缺口：

## 黑盒等价对照
- schema与Infer：
- 合法/非法输入行为：
- TilingData：
- 两阶段任务覆盖：
- Workspace：
- key/scheduleMode/numBlocks：

## 未执行项目
- 设备kernel：
- 端到端数值：
- 性能：

## 总结
- 路线A：PASS/PARTIAL/BLOCKED/FAIL
- 路线B：PASS/PARTIAL/BLOCKED/CONTAMINATED/FAIL
- 双轨等价性：PASS/PARTIAL/BLOCKED/FAIL
```
