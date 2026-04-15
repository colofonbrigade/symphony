# Elixir Testing

Conventions for testing Elixir apps that use the boundary, config, and
runtime patterns described in [`elixir_rules.md`](elixir_rules.md).

## Test configuration lives in `config/test.exs`

`config/test.exs` is the single place test-env defaults live. Pin values
there once rather than mutating Application env from every test.

### What belongs in `config/test.exs`

- **Test doubles** (fakes, in-memory adapters) configured globally, not
  swapped in per-test. Example shape:
  ```elixir
  config :my_app, MyApp.SomeAdapter, impl: Test.SomeAdapter.Memory
  ```
- **Test-env toggles** (disabled background processes, in-memory repos,
  noisy features turned off).

### Test-only modules

Put test doubles under `test/support/` as `.ex` files (not `.exs`) in a
`Test.*` namespace. Wire them into compilation:

```elixir
# mix.exs
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

This matters when long-lived processes reach those modules during
`Application.start/2` — if the code isn't compiled, the app fails to boot.

## Testing the production implementation

Unit-test the real module directly — it doesn't need to be wired into the
supervision tree to be exercised. Call its functions, assert on results.
Pure modules are the default target; stateful modules (GenServers) can
usually be unit-tested by starting an isolated instance in the test with
`start_supervised!/1` or `start_link/1` with a unique name.

If a test genuinely needs the production implementation live in the
supervision tree (e.g., an end-to-end HTTP roundtrip against the real Phoenix
endpoint), that test is an **integration test**: `async: false`, tagged as
such, and it's acceptable for it to `Application.put_env` + `on_exit` its way
into the setup it needs. These should be rare and isolated.

## Per-test overrides for short-lived callers

For values read from short-lived processes (controllers, test-process-scoped
code, pure functions called from the test process), use `Process.put/2`
combined with a `ProcessTree`-backed accessor (the
[`process_tree`](https://hex.pm/packages/process_tree) library walks up
`$ancestors` so `Process.put` in the test process reaches children spawned
by the test). Scoped to the test process, no cleanup, `async: true` safe.

Most projects wrap this in a thin accessor (e.g. `MyApp.Runtime.get/2`) that
falls back to `Application.get_env` when the key isn't in the tree. That
lets call sites read a single source without repeating the fallback.

Long-lived GenServers must *not* read through this accessor —
`ProcessTree` caches the value in each reader's own process dict, so the
first-seen value pins forever. Those readers go directly through
`Application.get_env`, which always reflects the current env. Document this
split in the project's local rules file.

## Smell check

If a unit test opens with `Application.put_env` + `on_exit(restore)` just to
swap an adapter or mock, ask: is this swapping global infrastructure for a
test that doesn't need global infrastructure? Usually you want one of:

1. **Move the default into `config/test.exs`** if every test wants the same
   override.
2. **Rewrite as a focused unit test** against the module under test rather
   than going through the supervision tree.
3. **Mark it as integration** (`async: false`, tagged) if it genuinely needs
   the real stack wired up.

## Async discipline

- Tests that only touch test-process state (`Process.put`, arguments, return
  values) should be `async: true`.
- Tests that touch BEAM-global state (`Application.put_env`, singleton named
  processes, OS environment, filesystem under a shared path) must be
  `async: false`.
- Don't reach for `async: false` preemptively — it's a correctness choice,
  not a safety blanket. If the test is actually only reading shared state
  read-only, `async: true` is fine.

## What not to test

- **The framework.** Don't test that Phoenix routes a request to a controller
  or that `Ecto.Repo.insert` writes a row. Test the logic *inside* your
  controller or the function that calls `insert`.
- **Third-party libraries.** Don't wrap them in your own tests. If a
  dependency is behaving wrong, that's an issue with the dependency, not a
  test you need to own.
- **Private implementation details.** Test the public contract; let the
  internals change freely. If a private function is complex enough to need
  its own test, it probably wants to be its own module.
