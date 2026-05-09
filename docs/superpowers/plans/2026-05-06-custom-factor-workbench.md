# Custom Factor Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first implementation of professional-template custom factors with structured definitions, validation APIs, and a vaporwave-style front-end workbench.

**Architecture:** Add a Zig `FactorSpec` layer that wraps existing built-in enum factors and new custom factor definitions. Custom factors compute raw component values per stock/date, rank components cross-sectionally inside the active pool, and combine them into a final factor value used by the existing portfolio, IC, and research paths. Frontend submits structured JSON and displays factor labels while internal keys remain stable.

**Tech Stack:** Zig sidecar, DuckDB, Vue 3 + Vite + TypeScript, ECharts, existing `CRTFrame` / `neon-btn` / `vapor-input` styles.

---

### Task 1: Factor Spec Parsing And Canonical Hash

**Files:**
- Create: `zig/src/backtest_factor_specs.zig`
- Modify: `zig/src/backtest_config.zig`
- Modify: `tests/test_zig_only_project.sh`

- [ ] **Step 1: Write failing Zig tests**

Add tests in `zig/src/backtest_factor_specs.zig` that assert:

```zig
test "custom factor canonical key ignores display fields and component order" {
    const allocator = std.testing.allocator;
    const body_a =
        \\{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","description":"A","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45},{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55}]}
    ;
    const body_b =
        \\{"description":"B","name":"改名不改key","engine_version":"custom-factor-v1","schema_version":1,"normalize":"cross_section_rank","combine":"weighted_sum","components":[{"weight":55,"direction":"higher","window":60,"field":"close","kind":"momentum"},{"weight":45,"direction":"lower","window":20,"field":"close","kind":"volatility"}]}
    ;
    var a = try parseCustomFactorValue(allocator, try parseJsonValue(allocator, body_a));
    defer a.deinit(allocator);
    var b = try parseCustomFactorValue(allocator, try parseJsonValue(allocator, body_b));
    defer b.deinit(allocator);
    try std.testing.expectEqualStrings(a.key, b.key);
    try std.testing.expect(std.mem.startsWith(u8, a.key, "custom:"));
}
```

Also add tests for rejecting duplicate components and rejecting `pe_percentile` with `window`.

- [ ] **Step 2: Verify RED**

Run: `cd zig && zig build test`

Expected: fail because `backtest_factor_specs.zig` and parser functions do not exist.

- [ ] **Step 3: Implement minimal parser**

Implement built-in factor aliases, custom component parsing, canonical JSON generation, SHA-256 `custom:<hex16>`, `FactorSpec` helpers, and request parsing compatibility in `backtest_config.zig`.

- [ ] **Step 4: Verify GREEN**

Run: `cd zig && zig build test`

Expected: parser tests pass, existing tests still pass.

### Task 2: Factor Templates And Validation API

**Files:**
- Modify: `zig/src/main.zig`
- Modify: `zig/src/backtest_factor_specs.zig`
- Modify: `frontend/src/api/index.ts`

- [ ] **Step 1: Write failing API-shape tests**

Add Zig tests in `main.zig` or `backtest_factor_specs.zig` for `validateRequestJson` that assert schema mode returns a `factor_key`, `summary`, `lookback`, empty `errors`, and `sample_scope.estimated = false`.

- [ ] **Step 2: Verify RED**

Run: `cd zig && zig build test`

Expected: fail because validation rendering does not exist.

- [ ] **Step 3: Implement endpoints**

Add:

```text
GET /api/factor-templates
POST /api/factors/validate
```

Return static backend-maintained templates and schema validation JSON. `sample` mode returns a bounded scope placeholder with `estimated: true` and no portfolio computation in this first implementation.

- [ ] **Step 4: Verify GREEN**

Run: `cd zig && zig build test`

Expected: validation tests pass.

### Task 3: Custom Factor Backtest Computation

**Files:**
- Create: `zig/src/backtest_custom_factors.zig`
- Modify: `zig/src/backtest.zig`
- Modify: `zig/src/backtest_factor_cache.zig`

- [ ] **Step 1: Write failing computation tests**

Add Zig tests that build a small in-memory observation group and verify:

```text
momentum high + volatility low produces higher custom score for the expected stock
```

- [ ] **Step 2: Verify RED**

Run: `cd zig && zig build test`

Expected: fail because custom component rank composition is missing.

- [ ] **Step 3: Implement composition**

Add component raw value computation, store component values on `Observation`, rank components within the active pool group, reverse lower-is-better components, and write final custom factor values into `obs.factors[fi]` before existing score ranking. Keep custom factors out of `factor_daily` caching in this implementation because final custom values depend on the active cross-section.

- [ ] **Step 4: Verify GREEN**

Run: `cd zig && zig build test`

Expected: computation tests pass, existing backtest tests pass.

### Task 4: Frontend Structured Types And Workbench UI

**Files:**
- Modify: `frontend/src/api/index.ts`
- Modify: `frontend/src/views/Backtest.vue`

- [ ] **Step 1: TypeScript build as current baseline**

Run: `cd frontend && npm run build`

Expected: current build status captured before changes.

- [ ] **Step 2: Implement UI**

Add TypeScript interfaces for custom factor definitions, template loading, validation, localStorage draft versioning, and a workbench panel using existing vaporwave styles. Keep old built-in factor toggles usable.

- [ ] **Step 3: Verify build**

Run: `cd frontend && npm run build`

Expected: build completes.

### Task 5: Full Verification

**Files:**
- Modify: `docs/backtest-system.md`
- Modify: `docs/backtest-optimization-plan.md`

- [ ] **Step 1: Update docs**

Document new endpoints and custom factor request shape.

- [ ] **Step 2: Run verification**

Run:

```bash
bash tests/test_zig_only_project.sh
zsh -n tauri-client.sh
zsh -n server.sh
cd frontend && npm run build
./tauri-client.sh ensure-sidecar
```

Expected: commands complete or any failures are reported with exact output.
