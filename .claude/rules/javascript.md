---
name: rules-javascript
description: Apply JavaScript coding standards for any task that creates, edits, reviews, refactors, or formats JavaScript or TypeScript code; use for variable declarations, comparisons, functions, destructuring, and Prettier configuration to align with this JS conventions.
paths:
  - "**/*.js"
  - "**/*.mjs"
  - "**/*.cjs"
  - "**/*.ts"
  - "**/*.jsx"
  - "**/*.tsx"
  - "**/*.vue"
  - "**/package.json"
  - "**/tsconfig.json"
---

# JavaScript Guidelines

## Overview
Apply JavaScript coding standards to keep JS/TS code consistent and readable.

## When to Activate
- Activate this skill for any JavaScript or TypeScript coding work.
- Activate this skill when working on `.js`, `.ts`, `.jsx`, `.tsx`, or `.vue` files.
- Activate this skill when configuring Prettier or ESLint for a project.

## Scope
- In scope: JavaScript, TypeScript, Vue single-file components, Prettier/ESLint configuration.
- Out of scope: PHP, Laravel, CSS-only files, server configuration.

## Prettier Configuration
- Indentation: 4 spaces (via `.editorconfig`, not Prettier default of 2)
- Print width: 120 characters (not Prettier default of 80)
- Quote style: single quotes

## Variable Declarations
- Prefer `const` over `let`. Only use `let` when a variable will be reassigned.
- Never use `var`.
- Reassigning object properties is fine with `const` — the reference is not reassigned.

## Variable Names
- Don't abbreviate variable names in multi-line functions. Use full, descriptive names.
- Exception: single-line arrow functions where context is obvious.

```javascript
// Good — full names in multi-line functions
function saveUserSession(userSession) {
    // ...
}

// Acceptable — short name in single-line arrow
userSessions.forEach(s => saveUserSession(s));
```

## Comparisons
- Always use `===` (strict equality). Never use `==`.
- If unsure of the type, cast it first:

```javascript
const number = parseInt(input);

if (number === 5) {
    // ...
}
```

## Functions

### Function Declarations
- Use the `function` keyword for named functions to clearly signal it's a function.

### Arrow Functions
- Use for terse, single-line operations.
- Use for anonymous callbacks.
- Use in higher-order functions when it improves readability.
- Don't use arrow functions when you need `this` context (e.g., jQuery event handlers).

### Object Methods
- Use shorthand method syntax:

```javascript
// Good
const obj = {
    handleClick(event) {
        // ...
    },
};

// Avoid
const obj = {
    handleClick: function(event) {
        // ...
    },
};
```

## Destructuring
- Prefer destructuring over manual property/index access:

```javascript
// Good
const [hours, minutes] = '12:00'.split(':');

// Good — configuration objects with defaults
function createUser({ name, email, role = 'member' }) {
    // ...
}

// Avoid
const parts = '12:00'.split(':');
const hours = parts[0];
const minutes = parts[1];
```

## TypeScript

Everything above is style. This section is type-system architecture, a separate axis. It applies to `.ts`, `.tsx`, and the `<script lang="ts">` block of `.vue` files. Where a rule assumes a pure functional codebase and Vue reactivity makes that awkward, a Vue note calls it out.

### Strict config
Prefer the strictest practical compiler configuration. At minimum:

```json
{
    "compilerOptions": {
        "strict": true,
        "noUncheckedIndexedAccess": true,
        "noUnusedLocals": true,
        "noUnusedParameters": true,
        "exactOptionalPropertyTypes": true,
        "noFallthroughCasesInSwitch": true,
        "forceConsistentCasingInFileNames": true,
        "verbatimModuleSyntax": true
    }
}
```

Avoid `// @ts-ignore`. Use `// @ts-expect-error` only with a written reason on the same line, and only when the type-clean alternative is genuinely worse. It is self-documenting: when the underlying error stops firing, the directive itself becomes an error.

### Type decision gates
1. `any` is never the answer. Use `unknown` and narrow. A function that accepts anything accepts `unknown`, and the caller proves what it is. Set ESLint `@typescript-eslint/no-explicit-any` to `error`.
2. Type assertions (`as`) belong only at validated system boundaries (parsing external JSON, DOM element access), never to silence the compiler mid-logic. Prefer `satisfies` over `as`: `const config = { ... } satisfies Config` checks the shape without widening or dropping literal types.
3. The non-null assertion (`!`) claims non-null without proof. Use narrowing or optional chaining instead.
4. Discriminated unions over class hierarchies. TypeScript's structural typing makes a tagged union with an exhaustive `switch` the natural pattern. Guard exhaustiveness with a `never` check:

```typescript
default: {
    const _exhaustive: never = value;
    return _exhaustive;
}
```

5. Branded types over raw primitives when two values of the same underlying type can be confused: `type ChapterId = string & { readonly __brand: unique symbol }`, with a constructor that validates and brands.
6. Avoid the TypeScript `enum`. Use `as const` objects or union types. `enum` emits runtime code and has confusing assignability.
7. Absence: pick one representation per context. Use `T | undefined` for optional parameters. When absence carries meaning, prefer a discriminated union (`{ kind: 'found', value: T } | { kind: 'not_found' }`) over `T | null`. Do not mix `T | null | undefined`.
8. Signatures accept the narrowest useful input and return the widest useful output: `(input: ReadonlyArray<string>) => Map<string, number>`, not `(input: string[]) => any`.
9. Validate external data (API responses, `localStorage`, URL params, user input) with a schema (for example Zod) at entry points. Inside the validated boundary, trust the types and do not re-validate.

### Immutability
Prefer `readonly` properties, `ReadonlyArray<T>`, and `Readonly<Record<K, V>>` by default. Use mutable types only when in-place mutation is the point.

Vue note: reactive state (`ref`, `reactive`, `defineModel`, Pinia stores) is mutable by design, and marking it `readonly` fights the framework. Keep the immutability default for plain data, DTOs, function inputs, and pure helpers; let reactive containers stay mutable where mutation is their job.

### Error design
1. For expected failures, prefer a `Result` union over a thrown exception: `type Result<T, E> = { ok: true; value: T } | { ok: false; error: E }`.
2. Throw only for programmer errors (bugs, invariant violations).
3. Error types are specific discriminated unions, not strings: `type ParseError = { kind: 'missing_field'; field: string } | { kind: 'invalid_format'; expected: string; got: string }`.
4. No `catch (e: any)`. Caught values are `unknown`; narrow before use.

### Module design
1. One export per concept, or a cohesive set. Avoid barrel files that re-export everything: they hurt tree-shaking and invite circular dependencies.
2. Circular imports are architectural bugs. If A imports B and B imports A, extract the shared concept into C.
3. Annotate return types on exported functions. Do not rely on inference across a module boundary.
4. Co-locate tests: `foo.ts` and `foo.test.ts` in the same directory.

### Functional core, imperative shell (optional pattern)
Where it fits (libraries, business logic, parsers, state reducers), separate pure logic from side effects. Pure modules export pure functions and types only, with no `document`, `window`, `fetch`, `console.log`, or mutable module-level state, and never import effectful modules. A `src/core/` (pure) and `src/shell/` or `src/app/` (effectful) split makes the boundary enforceable via ESLint `no-restricted-imports`. Treat this as a strong pattern for logic-heavy code, not a mandate for every small app or view component.

### Review smells
1. `any`, or `Promise<any>`. Use `unknown` and narrow.
2. `as` mid-logic to silence the compiler instead of fixing the type.
3. `!` non-null assertion without proof.
4. Mutable module-level state (`let` at module scope, exported mutable objects) outside reactive containers.
5. TypeScript `enum` where `as const` or a union fits.
6. `Object`, `{}`, or `Function` as a type. Too wide; use a specific type.
7. String-based dispatch (`if (type === 'foo')`) instead of a discriminated union with an exhaustive switch.
8. Missing return-type annotations on exported functions.
9. `T | null | undefined` mixing two absence representations in one place.

### Verification layer mapping
Use the strongest tool that can express the check. Strongest and most permanent first:

| Layer | Strongest tools (in order) |
|-------|---------------------------|
| L1 | `readonly`, branded types, discriminated unions, `satisfies`, template-literal types, module-boundary conventions |
| L2 | `tsd` or `expect-type`, compile-time type assertions that prove invalid code does not compile |
| L3 | strict ESLint rules (`no-explicit-any`, `no-restricted-imports`, `consistent-type-assertions`), custom module-boundary rules, schema validation at build time |
| L4 | Vitest with property-based testing (`fast-check`) and unit tests |
| L5 | Playwright or integration tests with a real browser, no mocks |
