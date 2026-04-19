# Test Isolation support for AL-Go for GitHub

## Summary

Opt-in support for BC runtime 16's `RequiredTestIsolation` and `TestType` properties. When enabled, AL-Go partitions test codeunits by their declared isolation requirement and runs each partition under a test runner whose `TestIsolation` matches. Off by default — existing projects are unaffected.

## Why

BC runtime 16 (2025 release wave 2) introduced `RequiredTestIsolation` on test codeunits. Microsoft's [property documentation](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/properties/devenv-requiredtestisolation-property) states verbatim that the property *"can be used to group tests for execution and reporting in CI/CD pipelines."*

Today AL-Go runs every test through a single blanket invocation with the BC default runner, ignoring the declaration. Tests that require non-default isolation (e.g. transactional rollback after each function) silently get the wrong runtime semantics in CI even though they pass in the BC Test Tool. This PR closes that gap.

## How it works

1. Before invoking `Run-AlPipeline`, AL-Go regex-scans `.al` files in the project's test folders, extracting `Subtype`, `RequiredTestIsolation`, and `TestType` from each test codeunit. `Subtype = TestRunner` codeunits are excluded.
2. Codeunits are grouped by `(RequiredTestIsolation, TestType)` and each group is mapped to a configured runner codeunit ID.
3. AL-Go installs a scriptblock into Run-AlPipeline's existing `-RunTestsInBcContainer` extension hook. For each partition with codeunits in the current test app, the scriptblock invokes `Run-TestsInBcContainer` **once** with `-testRunnerCodeunitId <runner>` and `-testCodeunitRange "id1|id2|..."`.
4. Results append into the same JUnit file Run-AlPipeline already produces — downstream `AnalyzeTests` works unchanged.

Container lifecycle, app installation, and `disabledTests.json` discovery continue to be handled by Run-AlPipeline. The new module owns only partitioning and the per-partition test invocation.

## Settings

Add a `testIsolation` block to any settings location in the standard cascade (`.AL-Go/settings.json`, workflow-scoped settings, etc.):

```json
{
  "testIsolation": {
    "enabled": true,
    "runners": {
      "Disabled": 130450,
      "Codeunit": 130451,
      "Function": 130452
    }
  }
}
```

Full keys: `defaultRunnerCodeunitId` (`0` = BcContainerHelper default), `testTypeFilter` (filter by `TestType`), `failOnMissingRequiredIsolationRunner` (fail-fast vs warn-and-fall-back). See `Scenarios/TestIsolation.md` for the complete user guide.

## Limitations

- **BC runtime 16+** required for the AL compiler to recognize `RequiredTestIsolation` / `TestType`. On older runtimes the scanner finds no declarations and every codeunit lands in the default partition (safe no-op).
- **Source-level regex scanning**, not symbol-file parsing. Robust on standard AL formatting but may miss codeunit declarations buried in unusual locations (e.g. column-0 block comments).
- **Performance**: each partition adds one `Run-TestsInBcContainer` call — N partitions roughly multiplies test-stage wall time by N. Enable only when tests genuinely require non-default isolation.
- **`testCodeunitRange`** uses BC's cmdline-testtool filter syntax, which BcContainerHelper warns "might not work on all versions of BC." Workaround if hit: declare the affected codeunits as `RequiredTestIsolation = None` so they share the default-runner partition.
- **Code coverage / BCPT**: partitioned runs produce per-partition coverage fragments. This PR does not aggregate across partitions; tracked as a follow-up.
- **`Run-AlLocal`** (the local dev helper in `AL-Go-Helper.ps1`) is not wired — that path forces `-doNotRunTests`, so the override would be dead code today.

## Test plan

- `Tests/TestIsolation.Test.ps1` — Pester tests covering metadata extraction (default values, canonical casing, multi-codeunit files, multi-app tagging, `Subtype = TestRunner` exclusion), partition grouping (isolation + testType keys, `testTypeFilter`, missing-runner behavior in both fail-fast and fallback modes), and the scriptblock factory (per-partition invocation, codeunit-range filter content, runner ID propagation, app filtering).
- `Tests/ReadSettings.Test.ps1` — schema tests for default shape, invalid `testTypeFilter` enum, negative IDs, unknown top-level keys, unknown runner keys.
- All 39 affected tests pass on PowerShell 7 / Pester 5.7.1.
- End-to-end run on a real BC container with mixed `RequiredTestIsolation` declarations — pending reviewer environment.
