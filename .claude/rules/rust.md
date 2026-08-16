---
name: rules-rust
description: Apply Rust architecture and coding standards for any task that creates, edits, reviews, or refactors Rust code. Covers ownership and lifetime gates, trait vs enum vs concrete-type decisions, type-level discipline, crate and test layout, error design, review smells, and the strongest-tool-per-verification-layer mapping.
paths:
  - "**/*.rs"
  - "**/Cargo.toml"
  - "**/Cargo.lock"
  - "**/clippy.toml"
---

# Rust Guidelines

## Overview
Architecture-first Rust standards. The burden of proof is on the more complex form: at every fork, justify structure by what the domain models, never by today's implementation count. These rules describe properties the code must have, not a house style to apply mechanically.

## When to Activate
- Any task that writes, edits, reviews, or refactors `.rs` files.
- Designing crate boundaries, module layout, or a public API surface.
- Choosing between a trait, an enum, and a concrete type.
- Configuring `clippy`, `cargo-deny`, or a Rust test harness.

## Scope
- In scope: Rust architecture, ownership and lifetime design, type-level modeling, crate and workspace layout, error surfaces, lint policy, test organization.
- Out of scope: other languages, and project-specific business logic.

## Architecture foundations
These are language-agnostic principles the Rust-specific gates below depend on. Your training data is heavily object-oriented (class hierarchies, dependency injection, shared mutable state). Those instincts produce poor Rust. Prefer the following.

1. Ownership. Every value has one owner. Design data flow around who creates, who consumes, who stores. When data seems to be needed in two places, ask "who is the real owner?" before reaching for shared state. Most sharing is unnecessary: data can flow through function parameters.
2. Functional core, imperative shell. Pure logic (parsing, validation, transformation, selection) is separated from side effects (I/O, network, database, UI). A file is entirely pure or entirely effectful. Pure files must not import effectful files. This is an architectural boundary, not a suggestion.
3. Flat control flow. Guard clauses and early returns discharge exceptional cases first, then continue flat. When a branch body needs its own context, extract it into a named function. Deep nesting is a structural problem: decompose the function, do not reindent it.
4. Make illegal states unrepresentable. Use the type system to prevent invalid states at compile time: wrapper types with private fields and fallible constructors over raw primitives, enums over booleans, typestate for multi-phase objects, and "parse, don't validate" (validate at boundaries, carry proof in types).
5. Escalation hierarchy: `concrete type` to `enum (closed set)` to `narrow trait` to `dynamic dispatch`. Each models a different domain reality. Pick the form that matches the domain, not the form that matches today's implementation count. If the domain models a capability, the trait exists even with one implementor.

### LLM failure modes to watch in your own output
1. Coordinator objects with no invariant: a type with a vague method (`process`, `handle`, `execute`) that orchestrates others but owns no state worth protecting. If it enforces no invariant, it is indirection.
2. Counting implementations to decide on traits: the count is irrelevant. The question is whether the domain models a capability.
3. Shared-state-as-architecture: reaching for shared mutable state as the first design instead of the last resort.
4. Clone or copy to silence the compiler: copying data to satisfy the borrow checker instead of asking "who should own this?"
5. Marking things async or concurrent "for future use" when no concurrent work happens.
6. Unjustified builders: a builder for a type where simple construction is perfectly clear.
7. Reinventing code that already exists in the codebase because training data is easier to reach than reading the project.

## Decision gates
At each architecture fork, pick the correct Rust form. The burden of proof is on the complex form.

1. Trait introduction. Does the domain model a capability, something that exists independently of who fulfills it? Yes, use a trait regardless of current impl count. No, use a concrete type or enum.
2. Async marking. Does this function actually `.await`? Is it I/O-bound with real concurrency? No, keep it sync. Extract pure logic (parsing, encoding, transforms) out of async boundaries.
3. Shared state. Can data flow through parameters? Yes, pass it. `Arc<Mutex<T>>` is narrow synchronization for a specific resource, never architecture.
4. Task spawning. Can this be a returned `Future`/`Stream`? Yes, return it. Never spawn from `&self` or constructors.
5. Clone. Handle clone (`Arc::clone`) is cheap and correct. Data clone needs justification. Borrow-checker laundering (cloning to silence a borrow error) is rejected: ask "who should own this?"
6. `&self` methods. Enforces an invariant or operates on the type's data, keep it a method. Never accesses self, make it a free function.
7. Naming. Weasel words (`Service`, `Manager`, `Factory`, `Handler`, `Processor`) are scrutinized. The test: does the type own a real invariant? Process lifecycle, connection pool, session state, the name can stand. Just a coordination namespace, rename it to a domain noun.
8. Typestate vs runtime state. Does the object have a lifecycle where certain operations are valid only in certain phases? Yes, encode phases as type parameters and make invalid transitions a compile error. No, a plain enum field is fine. Never `panic!("invalid state")` in a match arm.
9. Trait object vs enum dispatch. Is the set of variants open to downstream extension? Yes, `dyn Trait`. No, enum with exhaustive matching. Default to enum; `Box<dyn Trait>` requires justification.
10. Parse, don't validate. Does a function guard an invariant with a runtime check then continue with the raw type? Wrap it in a newtype that enforces the invariant at construction (`NonEmptyVec<T>`, `ValidatedEmail`). No `.unwrap()` or `assert!` as a substitute for types.
11. Sealed traits. Is the trait an internal abstraction rather than an extension point? Seal it. Unsealed public traits are a compatibility promise.
12. Compile-time evaluation. No heap allocation, no runtime dispatch, no I/O? Evaluate at compile time. Push computation as early as possible.
13. Do not fight the borrow checker. On borrow errors, do not just satisfy it at any cost with a "pragmatic solution" as a crutch. Consider whether refactoring removes the fight entirely.

## Ownership and lifetimes
1. Own stored data and return values. Accept borrowed inputs (`&str`, `&[T]`, `&Path`) when the function does not need ownership.
2. Lifetime accumulation is a design checkpoint. A struct gaining lifetime parameters is a signal: should it own the data instead?
3. Never add `'static` or lifetime parameters to silence the compiler. The question is "is the scope boundary correct?"
4. Accept flexible inputs (`impl Into<String>`, `impl AsRef<Path>`), return concrete types.
5. Use `Cow<'_, T>` when callers sometimes own and sometimes borrow. Prefer it over an unconditional clone or forced ownership.

## Type-level discipline
1. `PhantomData` and marker types for zero-cost type-level tags: units, currency, ID namespaces, typestate phase parameters.
2. `#[must_use]` on `Result`-returning functions and on types where ignoring the return is almost certainly a bug.
3. `#[non_exhaustive]` on public enums and structs for forward compatibility across crate boundaries.
4. Newtype over a primitive when two values of the same type can be confused (`UserId(u64)` vs `OrderId(u64)`). Enum over `bool` for parameters, struct fields, and return values. Multiple boolean fields in a type are unnamed states.
5. `From` and `TryFrom` for conversions, not ad-hoc `fn to_foo(&self) -> Foo` methods.

## Iterator and allocation discipline
1. Return `impl Iterator<Item = T>` when the caller may not need all items. Collect at the call site, not inside the function.
2. RAII and `Drop` guards for scope-bound resource cleanup. No manual cleanup scattered across code paths.
3. Avoid eager allocation: `&str` over `String`, `&[T]` over `Vec<T>` in function signatures that only read.

## Crate design
Split a crate when there are different consumers, a pure or effectful seam, a generated or manual seam, different dependency stacks, or different change pressure. Do not split for mere file organization or to create a junk-drawer `-types` crate with no concrete consumer. A crate that exposes no meaningful public contract should be a module.

## Test organization
1. One integration test crate per library: `tests/it/main.rs` with submodules. Never multiple top-level `tests/*.rs` files. Each is a separate binary, causing repeated linking and sequential execution.
2. `doctest = false` in `Cargo.toml` for internal libraries. Each doc test compiles as a separate binary.
3. `#[cfg(test)] mod tests;` in a separate file, not an inline module. Cargo skips library recompilation when only the test file changes.

## Error design
One coherent public error surface per crate. Use `thiserror` for library crates. Semantic variants name what went wrong (`ConnectionRefused`, not `InModule3Error`). Preserve chains with `#[from]` and `#[source]`. No `anyhow` or `Box<dyn Error>` in public library APIs. No stringly-typed errors and no catch-all `Other(String)` variants.

## Public API
1. All public types derive `Debug` (mandatory). Other derives are context-dependent.
2. Public types must be `Send` unless deliberately thread-local.
3. Hide `Arc`, `Rc`, `RefCell` behind clean APIs; these are implementation details. `Box<T>` is fine when heap semantics are intentional.
4. Construction: `new()` when construction is genuinely simple and all params are obvious from context. A builder when construction has staged invariants, orthogonal configuration, or params whose meaning is not obvious from position. Do not count params; ask whether the caller benefits from named, staged construction.

## Review smells
1. Generic coordinator objects: a struct with vague verb methods (`process`, `handle`, `run`) that owns no real invariant.
2. Counting impls to decide on traits: the test is domain modeling, not impl count.
3. A method that ignores `self`: pure namespacing, should be a free function.
4. Clone laundering: `.clone()` before a closure to silence borrow errors instead of fixing ownership.
5. `Arc<Mutex<T>>` as architecture: multiple mutex fields, or a mutex in a public signature.
6. God modules: mixed pure and effectful code, importing from many siblings.
7. Async coloring: `async fn` with no `.await`, or pure logic trapped inside an async boundary.
8. Lifetime laundering: `'static` or extra lifetime params to silence the compiler.
9. Unjustified builders: a builder where `new()` is perfectly clear.
10. Primitive obsession: `String` where a newtype prevents confusion, `bool` params where an enum clarifies.
11. Reinventing existing helpers.
12. Runtime state panic: `panic!("invalid state")` or `unreachable!()` in match arms that should be compile-time impossible via typestate.
13. Reflexive `Box<dyn Trait>`: dynamic dispatch for a closed set of variants that should be an enum.
14. Eager collect: `.collect::<Vec<_>>()` inside a function that could return an iterator.
15. Open traits that should be sealed: a public trait with no intention of downstream impls.
16. Ad-hoc conversions: `fn to_foo()` or `fn as_bar()` methods instead of `From` or `AsRef` impls.
17. Missing `#[must_use]`: a `Result`-returning function where silently ignoring the return is a bug.
18. Deep nesting: needs decomposition or early-exit idioms (`?`, `let-else`, guard clauses), not reformatting.
19. Qualified-path noise: repeated fully-qualified paths in function bodies instead of module-level imports.

## Writing habits
Right fix versus wrong fix for the most common lint failures.

- Ordering. Semantic, not alphabetical. Variants follow lifecycle (`Initial`, `DomContentLoaded`, `Load`, `NetworkIdle`). Fields follow domain (`url, method, headers, body`). Methods follow use (`new`, `configure`, `execute`, `close`). Module items: `mod`/`use`, then macros, then `const`, then types, then `fn`. Alphabetical ordering destroys domain structure.
- `const fn`. Add `const` when there is no heap, no dispatch, no I/O, no `&mut`, no trait calls. Constructors and field accessors almost always qualify. Leaving a pure accessor non-const is the wrong fix.
- Async. Remove `async` if there is no `.await`. If the API needs async, implement real I/O; do not stub. `async {}.await` to appease a lint is wrong, and a stub returning `Ok(default)` is wrong; implement the real error path.
- Parameters. `&T` for reads. Small `Copy` types by value: `fn foo(x: u32)`, not `fn foo(x: &u32)`. `&bool` and `&usize` are unnecessary indirection. An owned `String` where `&str` suffices is wrong.
- Decomposition. 80-line function limit. Match arms become single-expression function calls with destructured fields: `PageAction::Click { frame, target } => handle_click(session, frame, target).await`. Passing the whole enum to a sub-function that re-matches it with catch-all arms is wrong.
- Must-use discards. Ask why first. An error you should handle propagates with `?`. Best-effort cleanup uses `drop(expr)`. Genuinely unneeded uses `let _: Type = expr;`. A bare `let _ = fallible_op();` silently swallows errors; `let _ = login().await;` is a bug, not a discard.
- Struct fields. Private fields, a `pub(crate)` constructor, and accessors. `pub(crate)` on each field exposes internals and bypasses invariants.
- Numerics. `i64::from(x)` or `u32::try_from(x)?`. Suffixes with separators: `10_u64`, `0x42_u8`. Bare `as` silently truncates; `10u64` is unseparated.
- Match. No `_ =>` on enums; list every variant. Combine identical arms: `A | B => body`. A single pattern with an else becomes `if let`. A wildcard catch-all swallows future variants.
- Docs. Backtick identifiers: ``[`FrameRef`]``. End paragraphs with punctuation. `/// # Errors` on every public `Result` function.
- Imports. All paths in a `use` block at the top. `format!("{x}")`, not `format!("{}", x)`. `use Trait as _` for method-only imports. Inline `std::time::Duration` in a function body is wrong.
- Trait impls. Parameter names must exactly match the trait definition. Renaming `f` to `writer` in `fn fmt` is wrong.
- One impl block. One `impl Type` per type per file. Find the existing block and add to it. Appending a second `impl Type` at the bottom is a reflexive LLM habit; do not.

## Lint suppression
`#[allow]` is banned; enforce via `clippy::allow_attributes`. All suppressions go through `#[expect]` with a mandatory reason; enforce via `clippy::allow_attributes_without_reason`.

1. Default is deny. Suppress a lint only when the lint-clean alternative would violate a principle in this file (wrong ownership, forced shared state, a broken type-level invariant, a worse abstraction). Fixing the code is the first option, always.
2. The reason string states why the lint-clean version is architecturally worse. Format: `reason = "<why lint-clean is worse>"`.
3. `#[expect]` is self-removing: if the suppressed lint stops firing, the expect itself warns, so stale suppressions do not accumulate. Prefer it over `#[allow]` for exactly this reason.

## Verification layer mapping
When a requirement must be proven, use the strongest tool that can express the check. Layers, strongest and most permanent first:
- L1: compile-time and type-system enforcement (the declaration is the proof).
- L2: negative compilation tests (invalid code must not compile).
- L3: static analysis gates (linters, dependency checkers, CI scripts).
- L4: property and unit tests (prefer property tests for universal claims).
- L5: integration and end-to-end tests.

Prefer L1 over L4 when the compiler can enforce it: if a check can be a type, do not write a test for it.

| Layer | Strongest tools (in order) |
|-------|---------------------------|
| L1 | `pub(in ...)` / `pub(crate)` visibility, crate boundaries, `nutype` validated newtypes, exhaustive match, `const { assert!() }` trait-bound assertions, manual sealed-trait pattern, `#[must_use]`, `#[non_exhaustive]` |
| L2 | `trybuild` compile_fail tests, proving invalid code does not compile (replaces grep-based absence checks) |
| L3 | `cargo-deny` (transitive dependency enforcement), then per-crate `clippy.toml` `disallowed-types`, then workspace `clippy` deny lints, then CI scripts, then grep only when nothing above can express the check |
| L4 | `proptest` with `test-strategy` and `proptest-derive` (`#[derive(Arbitrary)]`) for property tests, `#[test]` unit tests |
| L5 | integration tests with real dependencies (real browser, real I/O), no mocks |
