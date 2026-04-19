# Partitioning tests by RequiredTestIsolation

Business Central test codeunits can declare, per codeunit, which transactional isolation they require from the test runner. AL-Go for GitHub can use those declarations to split a single test stage into multiple runs, each with a test runner whose `TestIsolation` property matches the codeunits' needs. Tests then behave the same in CI as they do when executed from the BC Test Tool.

## Background: three AL properties

| Property | Applies to | Values | Runtime |
|---|---|---|---|
| `TestIsolation` | Test **runner** codeunit (`Subtype = TestRunner`) | `Disabled` (default), `Codeunit`, `Function` | 1.0 |
| `RequiredTestIsolation` | Test codeunit (`Subtype = Test`) | `None` (default), `Disabled`, `Codeunit`, `Function` | 16.0 (BC 2025 W2+) |
| `TestType` | Test codeunit | `UnitTest` (default), `IntegrationTest`, `Uncategorized`, `AITest` | 16.0 |

- The runner's `TestIsolation` decides actual database rollback behavior after tests execute.
- The test codeunit's `RequiredTestIsolation` is a declaration of what the codeunit expects. If the runner doesn't satisfy it, the test may fail.

See Microsoft's [TestIsolation property](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/properties/devenv-testisolation-property) and [RequiredTestIsolation property](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/properties/devenv-requiredtestisolation-property) docs for full semantics.

## When to enable this

Enable `testIsolation` only if your test codeunits declare non-default `RequiredTestIsolation` values. Projects whose tests all run under the default runner do not need it. Enabling partitioning on a project that does not need it simply produces a single partition and runs exactly as before.

## Configuration

Add a `testIsolation` block to your `.AL-Go/settings.json` (or any higher-precedence settings location — see [settings.md](settings.md#where-are-the-settings-located)):

```json
{
  "testIsolation": {
    "enabled": true,
    "defaultRunnerCodeunitId": 0,
    "runners": {
      "Disabled": 130450,
      "Codeunit": 130451,
      "Function": 130452
    },
    "testTypeFilter": [],
    "failOnMissingRequiredIsolationRunner": true
  }
}
```

| Key | Meaning |
|---|---|
| `enabled` | Turns partitioning on. When `false` (default) AL-Go uses the single-pass test behavior. |
| `defaultRunnerCodeunitId` | Runner used for test codeunits that declare `RequiredTestIsolation = None` or do not declare the property. `0` means "let BcContainerHelper pick the default runner." |
| `runners.Disabled` / `.Codeunit` / `.Function` | Map each `RequiredTestIsolation` value to a runner codeunit whose `TestIsolation` property satisfies it. You supply the runner codeunit — for example from your own test app, or by adopting a runner from [BCApps Test Runner](https://github.com/microsoft/BCApps/tree/main/src/Tools/Test%20Framework/Test%20Runner). `0` means "no runner mapped." |
| `testTypeFilter` | If non-empty, only test codeunits whose `TestType` property matches one of the listed values are executed. Useful for running only `IntegrationTest` codeunits in a nightly workflow, for example. |
| `failOnMissingRequiredIsolationRunner` | When `true` (default), AL-Go fails fast if a test codeunit declares a `RequiredTestIsolation` value with no runner mapped in `runners`. When `false`, it falls back to `defaultRunnerCodeunitId` and writes a warning. |

## How AL-Go uses this

Before invoking `Run-AlPipeline`, AL-Go:

1. Scans `.al` files in your test folders and extracts every test codeunit's `RequiredTestIsolation` and `TestType` property values.
2. Groups the codeunits by `(RequiredTestIsolation, TestType)` and applies `testTypeFilter`.
3. Maps each group to the configured runner codeunit id.
4. Registers a `RunTestsInBcContainer` scriptblock override that, for each test app, invokes `Run-TestsInBcContainer` once per codeunit using the partition's runner. Results are appended into the same JUnit file that downstream reporting already consumes.

Container lifecycle, app installation, and `disabledTests.json` discovery continue to be handled by `Run-AlPipeline` exactly as before.

## Workflow-specific overrides

The normal AL-Go settings cascade applies. To use partitioning only in the nightly workflow, add a `.AL-Go/<workflow-name>.settings.json` with the `testIsolation` block — the CI workflow runs unchanged.

## Compatibility

- **BC runtime 16+** is required for `RequiredTestIsolation` / `TestType`. On older runtimes these properties don't exist, so the scanner finds nothing and every codeunit lands in the default partition. The feature is safe to leave off in old projects.
- **Existing projects are not affected** unless they opt in via `testIsolation.enabled = true`.

## Performance

Enabling partitioning approximately multiplies test-stage wall time by the number of partitions, because each partition runs in a separate test-runner invocation. Enable this only when your tests actually require it.

## Related

- [TestIsolation property](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/properties/devenv-testisolation-property)
- [RequiredTestIsolation property](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/properties/devenv-requiredtestisolation-property)
- [TestType property](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/properties/devenv-testtype-property)
- [Test Runner codeunits](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-testrunner-codeunits)
- [BCApps Test Runner](https://github.com/microsoft/BCApps/tree/main/src/Tools/Test%20Framework/Test%20Runner)

______________________________________________________________________

[back](../README.md)
