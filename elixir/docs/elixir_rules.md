# Elixir Rules

Rules for structuring code under `elixir/lib/`. These are invariants; deviations need an explicit
justification in the PR.

## Module boundaries

Each top-level namespace under `lib/` is a **boundary**. Typical boundaries are:

- `Core` — The domain core.
- `Web` — Phoenix endpoint, LiveView dashboard, JSON API for observability.
- `Schema` — Data structures (structs, Ecto schemas, types) shared across boundaries, plus
  functions that describe the structure of those data (e.g. type specs, field
  enumerations). See "The `Schema` boundary" below.

Add a new top-level namespace (new boundary) when the code is self-contained and doesn't need to
reach across into `Core`/`Web` internals.

## The `Schema` boundary

`Schema` is the shared vocabulary every other boundary can speak. It is a leaf in the DAG — no
other boundary depends on anything below it besides `Schema` itself, and `Schema` depends on
nothing in this app.

What belongs in `Schema`:

- Structs and Ecto schemas used across boundary lines (if only one boundary uses it, keep it
  local to that boundary).
- Functions that describe the **shape** of that data: field lists, type specs,
  constructors that just build the struct, `__schema__/1`-style accessors.

What does **not** belong in `Schema`:

- Functions that interact with changesets — `changeset/2`, persistence (`Repo.insert`), validation that
  calls out to other boundaries, lifecycle orchestration. These stay in the boundary that owns the
  behavior (usually `Core`). `Schema` defines the struct (or `schema/1`); `Core` applies and acts on it.
- For ecto schemas, the `schema` belongs under `Schema`. The `changeset` belongs under `Core`.
- Business rules or policy. A schema knows its own invariants (required fields, numeric ranges).
  It doesn't know why or when a record gets created.

Rule of thumb: if a file's imports include `Ecto.Repo`, a tracker client, or any other boundary's
modules, it doesn't belong in `Schema`.

## Runtime configuration (`config/runtime.exs`)

`config/runtime.exs` is the single source of truth for anything fixed at boot but not at compile
time: environment-variable reads, paths that depend on the deploy target, workflow/config files,
per-boot secrets. It runs after modules are compiled and loaded, before applications start.

Use it for:

- Reading environment variables (`System.get_env/1`).
- Generating per-boot values (random keys, timestamps).
- Loading external config files (YAML, TOML) *provided the loader is pure* — no Application-env
  reads, no GenServer calls, no side effects beyond file I/O. Document this invariant at the call
  site in `runtime.exs`.
- Wiring OTP-application config for deps (endpoints, repos, telemetry).

Prefer `Application.get_env/2` reads in module code. Keep `Application.put_env/3` off the hot
path; limit it to:

- CLI flag handlers in user-facing entry points (a mix task, an escript `main`) that override boot
  values before `Application.ensure_all_started/1`.
- Test setup replacing a config value for the duration of a test.

If a module body calls `Application.put_env/3` outside those cases, the value probably belongs in
`runtime.exs`. If the entry point needs to hand data to `runtime.exs`, use `System.put_env/2` to
publish it, then let `runtime.exs` pick it up — this keeps writes centralized and reads everywhere.

## Dependency direction

Cross-boundary calls must form a **directed acyclic graph**:

- `Web` may call into `Core` (it renders `Core`'s state).
- `Core` must **not** call into `Web`. Core doesn't know the dashboard exists.
- No boundary may call back into a boundary that already depends on it.

If `Core` needs to push something to `Web` (e.g., live updates), use a pub/sub seam like
`Phoenix.PubSub` where `Core` publishes and `Web` subscribes — `Core` still has no compile-time
dependency on `Web`.

## When to pull something out

Extract a new boundary when a chunk of code:

- Isn't part of the domain core (e.g., an API integration, a new transport),
- Has a clean functional interface for cross-boundary access
- Can be depended on by `Core`, `Web`, or other namespace through a narrow public interface.

Extract when these hold simultaneously. Otherwise keep it under an existing namespace.

## Keeping modules inside a boundary

- Public functions of a boundary are the modules/functions other boundaries are allowed to call.
- Helpers, structs, and sub-namespaces under a boundary are **internal**: other boundaries should not
  reach into them directly if possible.
- If another boundary needs something internal, promote it to the boundary's public surface rather
  than reaching around it.

## Enforcement

Use the [`boundary`](https://hex.pm/packages/boundary) library to make these rules compile-time
invariants instead of convention. Each top-level namespace declares its `deps` (what it may call)
and `exports` (what it exposes). `mix boundary` fails the build on violations.

When adding a new boundary, update its `boundary` declaration in the same change so CI enforces the
DAG from day one.
