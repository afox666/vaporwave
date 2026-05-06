# 自定义因子工作台设计

## 背景

当前回测系统支持固定内置因子，前端通过 `/api/factors` 获取因子列表，回测请求通过 `factors: string[]` 选择因子。Zig 后端使用 enum 表示因子，`backtest_factors.zig` 逐个计算，`factor_daily` 按固定因子名缓存结果。

新需求是支持用户自定义因子，但目标用户有金融基础、不熟悉电脑操作。因此第一版不提供公式编辑器或拖拽画布，而是提供专业模板工作台：用户用大按钮选择金融参数，系统提交结构化因子定义，后端执行受限白名单引擎。

## 目标

- 支持基于专业模板的自定义因子。
- 前端页面与现有 vaporwave / CRT 风格一致，不照搬 TradingView 视觉。
- 用户不需要写公式、拖拽节点或编辑 JSON。
- 后端只执行结构化白名单定义，不执行任意表达式字符串。
- 自定义因子可回测、可缓存、可进入 IC 分析、五分组收益和持仓明细。
- 旧的内置因子请求、CLI 请求、历史任务继续兼容。

## 非目标

- 第一版不做任意公式输入。
- 第一版不做拖拽积木编辑器。
- 第一版不做数据库级用户模板库。
- 第一版不缓存自定义因子的组件中间值，只缓存最终因子值。
- 第一版不引入新的前端 UI 框架。
- 第一版不支持任意嵌套表达式或用户自定义 SQL。

## 产品设计

### 交互模型

采用三层渐进式交互：

1. 模板入口：默认展示成品专业模板，例如 `稳健动量`、`低波反转`、`估值修复`、`量价确认`。
2. 工作台层：进入模板后展示启用的因子维度表格和右侧属性面板。
3. 高级层：默认折叠，只读展示结构化定义、最大 lookback、缓存 key、引擎版本和样本有效率。

TradingView 只作为信息架构参考：顶部筛选、中心图表和表格、右侧属性面板。视觉上继续使用现有项目的 `CRTFrame`、`neon-btn`、`vapor-input`、霓虹色、终端字体和暗色背景。

### 前端布局

在 `frontend/src/views/Backtest.vue` 中扩展因子选择区，复杂度增长后拆出以下组件：

- `frontend/src/components/backtest/FactorWorkbench.vue`
- `frontend/src/components/backtest/FactorTemplateCard.vue`
- `frontend/src/components/backtest/FactorInspector.vue`
- `frontend/src/components/backtest/FactorValidationPanel.vue`

工作台内容：

- 顶部：`内置因子 / 自定义工作台` 切换。
- 模板区：专业模板卡片，使用现有卡片视觉，不使用圆角过大的营销卡片。
- 表格区：列为 `维度`、`参数`、`方向`、`权重`、`状态`。
- 属性区：用大按钮调整窗口期、排序方向、权重方案。
- 摘要区：自然语言确认当前定义，例如 `使用60日趋势动量，并用20日波动率做风险惩罚`。
- 校验区：展示 `可运行`、`有警告`、`不可运行`，每个状态都有文字说明，不只依赖颜色。

### 易用性约束

- 不依赖 hover、拖拽或右键。
- 主要操作按钮保持足够点击面积。
- Tab 顺序清晰，允许键盘操作。
- 调整窗口、方向、权重后，右侧解释面板同步说明影响。
- 校验错误必须可操作，例如 `120日窗口历史不足，建议改为60日`。
- 前端用 localStorage 保存未提交草稿，刷新后不丢失工作台状态。草稿 key 固定为 `vaporwave:backtest:customFactorDraft:v1`，值包含 `schema_version`、`saved_at`、`custom_factors` 和工作台 UI 状态；版本不匹配时丢弃草稿并提示用户重新选择模板，不尝试静默迁移。

## API 设计

### 兼容策略

旧请求保持可用：

```json
{
  "factors": ["momentum_20d", "volatility_20d"],
  "start_date": "2024-01-01",
  "end_date": "2026-05-01"
}
```

新增自定义因子字段：

```json
{
  "factors": ["custom:4f9a2c10d7b831aa"],
  "custom_factors": [
    {
      "schema_version": 1,
      "engine_version": "custom-factor-v1",
      "id": "custom:4f9a2c10d7b831aa",
      "name": "稳健动量",
      "description": "60日趋势动量 + 20日波动率惩罚",
      "combine": "weighted_sum",
      "normalize": "cross_section_rank",
      "components": [
        {
          "kind": "momentum",
          "field": "close",
          "window": 60,
          "direction": "higher",
          "weight": 0.55
        },
        {
          "kind": "volatility",
          "field": "close",
          "window": 20,
          "direction": "lower",
          "weight": 0.45
        }
      ]
    }
  ],
  "start_date": "2024-01-01",
  "end_date": "2026-05-01",
  "rebalance_period": 20
}
```

`factors` 内部使用稳定 key。内置因子仍使用现有名称，自定义因子使用 `custom:<hash>`。展示名不参与 key，也不参与缓存 hash。

### 新增接口

`GET /api/factor-templates`

返回后端统一维护的专业模板定义。前端只负责展示和微调，CLI 和前端共享同一套模板认知。

`POST /api/factors/validate`

用于工作台实时校验，返回：

- `factor_key`
- `factor_label`
- `summary`
- `schema_valid`
- `lookback`
- `engine_version`
- `estimated_valid_observation_rate`
- `component_missing_counts`
- `sample_scope`
- `warnings`
- `errors`
- `suggestions`

请求体包含两个层级：

```json
{
  "mode": "schema",
  "factors": ["custom:4f9a2c10d7b831aa"],
  "custom_factors": [
    {
      "schema_version": 1,
      "engine_version": "custom-factor-v1",
      "name": "稳健动量",
      "combine": "weighted_sum",
      "normalize": "cross_section_rank",
      "components": [
        {
          "kind": "momentum",
          "field": "close",
          "window": 60,
          "direction": "higher",
          "weight": 0.55
        },
        {
          "kind": "volatility",
          "field": "close",
          "window": 20,
          "direction": "lower",
          "weight": 0.45
        }
      ]
    }
  ],
  "context": {
    "start_date": "2024-01-01",
    "end_date": "2026-05-01",
    "rebalance_period": 20,
    "pool_size": 100,
    "pool_mode": "dynamic",
    "industry": null,
    "min_amount": 10000000,
    "min_listed_days": 60,
    "limit_pct": 9.8
  }
}
```

`mode` 控制成本边界：

- `schema`：默认模式，不访问 DuckDB，只做 JSON 结构、白名单、窗口、权重、稳定 hash、lookback 和可读摘要校验。前端可在用户修改控件后 debounce 调用，目标是轻量、快速、无行情依赖。
- `sample`：样本预估模式，需要 `context`，使用与回测一致的日期、股票池、行业、成交额、新股和涨跌停参数估算组件缺失与有效样本率。该模式不构建组合、不计算收益、不写缓存。

`sample` 模式必须有明确上限：默认最多检查 200 只股票、12 个调仓日；如果实际范围更大，返回 `sample_scope` 说明抽样数量、调仓日数量和 `estimated: true`。最终回测仍按完整股票池和完整调仓日期重新计算，`validate` 的样本率只作为提交前预警。前端只在用户点击 `先看因子效果`、切换模板后稳定停顿，或运行回测前调用 `sample`，避免每个控件变化都触发昂贵检查。

### 返回结构

回测结果新增：

```json
{
  "config": {
    "factors": ["custom:4f9a2c10d7b831aa"],
    "factor_labels": {
      "custom:4f9a2c10d7b831aa": "稳健动量"
    },
    "factor_definitions": [
      {
        "key": "custom:4f9a2c10d7b831aa",
        "name": "稳健动量",
        "description": "60日趋势动量 + 20日波动率惩罚",
        "schema_version": 1,
        "engine_version": "custom-factor-v1",
        "lookback": 62,
        "components": [
          {
            "kind": "momentum",
            "field": "close",
            "window": 60,
            "direction": "higher",
            "weight": 0.55
          },
          {
            "kind": "volatility",
            "field": "close",
            "window": 20,
            "direction": "lower",
            "weight": 0.45
          }
        ]
      }
    ]
  },
  "ic_analysis": {
    "custom:4f9a2c10d7b831aa": {}
  },
  "factor_research": {
    "custom:4f9a2c10d7b831aa": {}
  }
}
```

程序内部统一使用 key，前端展示时通过 `factor_labels` 映射为中文名。持仓明细中的 `factors` 和 `factor_scores` 也使用稳定 key。

## 后端设计

### 模块拆分

新增模块：

- `zig/src/backtest_factor_specs.zig`：解析内置和自定义因子，生成统一 `FactorSpec`。
- `zig/src/backtest_custom_factors.zig`：计算自定义因子组件原始值，并执行横截面合成。

修改模块：

- `zig/src/backtest_config.zig`：`Request.factors` 从 enum 列表升级为 `FactorSpec` 列表。
- `zig/src/backtest.zig`：观察值结构支持自定义因子的组件计算和合成。
- `zig/src/backtest_factor_cache.zig`：缓存 key 从 enum 因子名扩展为稳定 factor key。
- `zig/src/main.zig`：新增模板接口和校验接口。
- `frontend/src/api/index.ts`：补充自定义因子类型、模板接口、校验接口。

### 兼容与迁移

- 旧请求只有 `factors: string[]` 时，服务端把每个字符串解析为 `builtin FactorSpec`，继续走现有内置因子计算逻辑。
- 新请求中 `factors` 可以混合内置因子 key 和 `custom:<hash>`。每个 `custom:<hash>` 必须能在同一请求的 `custom_factors` 中通过服务端重新计算得到；缺失定义或 hash 不一致时返回 400。
- 旧 `.backtest_history/` 文件、旧 `.backtest_tasks/` 持久化请求和旧同步回测 JSON 继续按旧结构读取。前端展示旧结果时，`factor_labels` 缺失则直接使用 `config.factors` 里的字符串作为展示名。
- 旧结果缓存保持只读兼容，不批量迁移。新结果缓存 key 使用新的 cache schema version，例如 `backtest-result-v2`，并纳入规范化 custom factor hash、`schema_version` 和 `engine_version`。
- 内置因子的 `factor_daily` 缓存继续使用现有 `calc_version = zig-factor-v1`；自定义最终因子使用 `calc_version = custom-factor-v1` 和 `factor_name = custom:<hash>`。
- 任务恢复时，如果任务处于完成态且已有 `result`，即使请求中的自定义定义无法重新校验，也优先展示已保存结果；重新运行同一请求时必须重新通过新校验。

### FactorSpec

统一因子类型：

- `builtin`：包装现有 enum 因子。
- `custom`：保存 `key`、`name`、`description`、`components`、`normalize`、`combine`、`lookback`、`schema_version`、`engine_version`。

第一版白名单组件：

- `momentum`
- `volatility`
- `ma_deviation`
- `volume_ratio`
- `rsi`
- `price_percentile`
- `pe_percentile`

第一版白名单字段：

- `close`
- `volume`
- `amount`

组件参数形态：

- `momentum`：`field` + `window`
- `volatility`：`field = close` + `window`
- `ma_deviation`：`field = close` + `window`
- `volume_ratio`：`field = volume` + `short_window` + `long_window`
- `rsi`：`field = close` + `window`
- `price_percentile`：`field = close` + `window`
- `pe_percentile`：不使用 `field`，第一版不接受 `window`，语义与现有内置 `pe_percentile` 保持一致，即使用调仓日及以前的可用 PE 估值点计算历史百分位；lookback 贡献沿用内置因子的 60 个交易日数据缓冲。

窗口限制：

- 普通窗口 `5..252`
- 双窗口组件要求 `short_window < long_window`
- 自定义因子组件数量限制为 `1..5`
- 总因子数量仍受 `MAX_FACTORS` 控制
- 横截面组件合成最小样本数为 5，和当前 IC / 组合分组逻辑保持一致。

### 稳定 hash

自定义因子的 `custom:<hash>` 只基于规范化后的结构化定义：

- 包含 `schema_version`
- 包含 `engine_version`
- 包含 `combine`
- 包含 `normalize`
- 包含组件 kind、field、window、direction、weight
- 不包含 name
- 不包含 description
- 不依赖 JSON 字段顺序

这样用户改中文名不会影响缓存和历史复现。

规范化过程必须可执行：

1. 解析并校验结构，忽略客户端传入的 `id`，由服务端重新计算 `factor_key`；如果请求中带有 `id` 且与服务端结果不一致，`validate` 返回 warning，回测请求返回 400。
2. 组件按规范化 tuple 排序：`kind`、`field`、`window`、`short_window`、`long_window`、`direction`。完全相同的 tuple 视为重复组件并拒绝，避免权重残差和解释文本出现歧义。第一版 `weighted_sum` 是交换律组合，组件顺序不表达语义；未来如果引入顺序敏感表达式，必须升级 `schema_version`。
3. 权重先校验为有限正数，按权重总和归一化。归一化后转换为 `weight_ppm = round(weight / sum * 1_000_000)`；按排序后的组件顺序计算，最后一个组件吸收舍入残差，保证 ppm 总和等于 `1_000_000`。
4. 生成无空白 canonical JSON，字段顺序固定为 `schema_version`、`engine_version`、`combine`、`normalize`、`components`。组件字段顺序固定为 `kind`、`field`、`window`、`short_window`、`long_window`、`direction`、`weight_ppm`。不适用的字段写 `null`，字符串使用小写枚举值。
5. 对 canonical JSON 做 SHA-256，取小写十六进制前 16 位，生成 `custom:<hex16>`。

示例 canonical JSON：

```json
{"schema_version":1,"engine_version":"custom-factor-v1","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"short_window":null,"long_window":null,"direction":"higher","weight_ppm":550000},{"kind":"volatility","field":"close","window":20,"short_window":null,"long_window":null,"direction":"lower","weight_ppm":450000}]}
```

### 计算流程

自定义因子不能在单股阶段直接返回最终值，因为组件需要先做横截面标准化。流程为：

1. 每个调仓日、每只股票计算组件原始值。
2. 缺任一组件值则该股票该调仓日的该自定义因子无效。
3. 对每个组件在当日股票池内做横截面 rank。
4. rank 输出范围为 `0..1`。
5. `direction: lower` 的组件在 rank 后反向。
6. 按权重加权合成最终 custom factor。
7. custom factor 默认方向为 `higher`。
8. 合成后的 custom factor 进入现有组合排序、IC、五分组和持仓展示。

rank 规则：

- null 不参与排名。
- tie 使用平均 rank。
- 少于最小样本数时跳过该日期的该组件。
- 所有组件必须有值，不自动重分配权重。

### 缓存策略

- 内置因子继续使用现有 `factor_daily`。
- 自定义因子只缓存最终合成值。
- 自定义因子写入 `factor_daily.factor_name = custom:<hash>`。
- `source = custom`。
- `calc_version` 使用自定义引擎版本，例如 `custom-factor-v1`。
- 结果缓存 key 必须包含完整规范化 custom factor 定义 hash。

## 数据质量与错误处理

`data_quality` 增加自定义因子校验信息：

- 定义是否合法。
- 最大 lookback 是否可满足。
- 组件缺失统计。
- 自定义因子有效样本率。
- 缓存 key 是否稳定。
- 是否存在未来数据风险。

错误信息必须面向用户可操作：

- `未知组件 kind: xxx`
- `window 必须在 5 到 252 之间`
- `120日窗口需要更多历史数据，建议改为60日`
- `波动率组件缺失较多，可能来自停牌或行情覆盖不足`

## 历史与恢复

- 旧历史任务没有 `custom_factors`，前端按内置因子恢复。
- 新历史任务保存完整 `custom_factors` 和 `factor_definitions`。
- 前端恢复历史任务时根据 `factor_definitions` 重建工作台状态。
- CLI 可以直接提交结构化 JSON。
- 第一版用户自定义模板不写入数据库；保存模板作为后续功能。

## 前端风格约束

- 使用现有全局变量和设计系统。
- 使用 `CRTFrame` 承载工作台区域。
- 使用 `neon-btn` 和 `vapor-input`。
- 卡片边角不超过现有项目风格，不做大圆角营销卡片。
- 页面区域保持工作台密度，避免 landing page 或说明页。
- 专业信息要可扫描，不使用大量解释性文案占用主界面。
- 图表继续使用 ECharts，保持当前回测图表视觉。

## 测试策略

### Zig 测试

- 解析合法自定义因子。
- 拒绝未知 kind。
- 拒绝非法 field。
- 拒绝非法 window。
- 拒绝非法权重。
- 验证 hash 不受 name 和字段顺序影响。
- 验证 `momentum + volatility` 组件能合成最终因子。
- 验证 `direction: lower` 会反向排名。
- 验证缺失组件导致该股票该日期跳过。
- 验证缓存 key 使用 `custom:<hash>`。

### 前端测试与构建

- `cd frontend && npm run build`
- 手工创建 `稳健动量` 模板，修改窗口和权重方案，确认摘要和校验同步变化。
- 运行回测后确认自定义因子出现在指标、IC、五分组、持仓明细和历史恢复中。

### 项目验证

继续执行：

```bash
bash tests/test_zig_only_project.sh
zsh -n tauri-client.sh
zsh -n server.sh
cd frontend && npm run build
./tauri-client.sh ensure-sidecar
```

## 验收标准

- 用户可以不写公式创建一个自定义因子并运行回测。
- 前端视觉与现有回测页面一致。
- 内置因子旧请求继续可用。
- 自定义因子使用稳定 key 和 label 映射。
- 校验接口能在运行回测前发现主要错误。
- 自定义因子结果进入缓存、IC 分析、五分组收益和持仓明细。
- 历史任务可恢复自定义因子定义。
- 不引入任意代码执行、SQL 执行或公式字符串解释风险。
