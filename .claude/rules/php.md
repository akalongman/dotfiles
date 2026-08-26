---
name: rules-php
description: Apply PHP coding standards for any task that creates, edits, reviews, refactors, or formats PHP code;
paths:
  - "**/*.php"
  - "**/composer.json"
  - "**/composer.lock"
  - "**/phpunit.xml"
---

# Laravel & PHP Guidelines for AI Code Assistants

This file contains Laravel and PHP coding standards optimized for AI code assistants like Claude Code, Gemini, or Cursor.

## Core Laravel Principle

**Follow Laravel conventions first.** If Laravel has a documented way to do something, use it. Only deviate when you have a clear justification.

**Prefer the framework's implementation over the native PHP equivalent.** When Laravel (or the active framework) ships a helper, facade, or class that covers what a native PHP function does, reach for that instead of the raw function.

```php
// Prefer
Str::lower($value);      // over strtolower($value)
Str::upper($value);      // over strtoupper($value)
Str::contains($h, $n);   // over str_contains($h, $n)
Arr::get($data, 'a.b');  // over nested isset() / null coalescing
now();                   // over Carbon::now() (see Code Quality Reminders)
Http::get($url);         // over curl_* / file_get_contents
Storage::get($path);     // over file_get_contents on a local path
```

Why it is the default, not dogma: the framework versions are usually multibyte-safe (`Str::lower` wraps `mb_strtolower`), fluent and chainable, macroable, and mockable in tests, and they keep a codebase reading in one idiom. Still apply judgment. If the native call is genuinely simpler and the helper adds nothing (a plain `count()`, `array_map` on a real array), do not wrap it just to wrap it. The rule is "prefer the framework tool when it exists and adds value," not "never call a native function."

## PHP Standards

- Follow PSR-1, PSR-2, and PSR-12
- Use camelCase for non-public-facing strings
- Use short nullable notation: `?string` not `string|null`
- Always specify `void` return types when methods return nothing
- Post-increment operator should be used only as single instruction

## Class Structure
- Use typed properties, not docblocks
- Constructor property promotion when all properties can be promoted
- One trait per line
- Put methods by visibility from top to bottom: public methods, protected methods and private methods

## Type Declarations & Docblocks
- Use typed properties over docblocks
- Specify return types including `void`
- Use short nullable syntax: `?Type` not `Type|null`
- Document iterables with generics:
  ```php
  /** @return Collection<int, User> */
  public function getUsers(): Collection
  ```

### Docblock Rules
- Don't use docblocks for fully type-hinted methods (unless description needed)
- **Always use fully qualified names in docblocks**
  ```php
  /** @return \Longman\Url\Url */
  ```
- Use one-line docblocks when possible: `/** @var string */`
- Add inline `/** @var \FQCN $variable */` annotations for variable assignments where the IDE / static analysis cannot infer the concrete type. Common triggers: `Collection::first()` / `firstOrFail()` returning generic `mixed`, factory `create()` / `make()` returning the base `Model` class, `app(Contract::class)` container resolutions, partial Mockery mocks. Place the annotation as a one-line block on its own line, immediately above the assignment, using a fully-qualified class name. Skip the annotation when the right-hand side is already typed (method return-type declared, constructor `new ConcreteClass()`, fully-typed factory call).
  ```php
  // Add — return type is generic mixed:
  /** @var \App\Models\Courses\Course $course */
  $course = FakeDataProvider::createRandomCourses()->first();

  // Skip — service method's return type already declares Course:
  $course = $this->coursesService->findOneByIdOrFail($scope, $id);

  // Skip — constructor literal is unambiguous:
  $resource = new CourseEquivalencyResource($model);
  ```
- Most common type should be first in multi-type docblocks:
  ```php
  /** @var \Illuminate\Support\Collection|\SomeWeirdVendor\Collection */
  ```
- If one parameter needs docblock, add docblocks for all parameters
- For iterables, always specify key and value types:
  ```php
  /**
   * @param array<int, MyObject> $myArray
   * @param int $typedArgument
   */
  function someFunction(array $myArray, int $typedArgument) {}
  ```
- Use array shape notation for fixed keys, put each key on it's own line:
  ```php
  /** @return array{
     first: SomeClass,
     second: SomeClass
  } */
  ```

## Control Flow
- **Happy path last**: Handle error conditions first, success case last
- **Avoid else**: Use early returns instead of nested conditions
- **Separate conditions**: Prefer multiple if statements over compound conditions
- **Always use curly brackets** even for single statements
- **Ternary operators**: Each part on own line unless very short

```php
// Happy path last
if (! $user) {
    return null;
}

if (! $user->isActive()) {
    return null;
}

// Process active user...

// Short ternary
$name = $isFoo ? 'foo' : 'bar';

// Multi-line ternary
$result = $object instanceof Model
    ? $object->name
    : 'A default value';

// Ternary instead of else
$condition
    ? $this->doSomething()
    : $this->doSomethingElse();
```

## Pipe Operator (PHP 8.5+)

When the project's PHP floor is 8.5 or higher, prefer the pipe operator over nested unary function calls, pairing it with first-class callable syntax so no wrapper closures are needed. The pipe passes exactly one value, so a multi-argument step should stay an ordinary call (often the terminal one) rather than being forced into the pipeline behind a closure.

```php
// Avoid: inside-out nesting
return static::applyRelationTree(
    static::$structure,
    static::normalizeRelations(array_merge($alwaysOn, $relations)),
);

// Prefer: the unary chain flattens; the binary terminal call stays ordinary
$tree = array_merge($alwaysOn, $relations)
    |> static::normalizeRelations(...);

return static::applyRelationTree(static::$structure, $tree);
```

## Laravel Conventions

### Routes
- URLs: kebab-case (`/open-source`)
- Route names: camelCase (`->name('openSource')`)
- Parameters: camelCase (`{userId}`)
- Use tuple notation: `[Controller::class, 'method']`

### Controllers
- Plural resource names (`PostsController`)
- Stick to CRUD methods (`index`, `create`, `save`, `show`, `edit`, `update`, `destroy`)
- Extract new controllers for non-CRUD actions

### Configuration
- Files: kebab-case (`pdf-generator.php`)
- Keys: snake_case (`chrome_path`)
- Add service configs to `config/services.php`, don't create new files
- Use `config()` helper, avoid `env()` outside config files

### Artisan Commands
- Names: kebab-case (`delete-old-records`)
- Always provide feedback (`$this->comment('All ok!')`)
- Show progress for loops, summary at end
- Put output BEFORE processing item (easier debugging):
  ```php
  $items->each(function(Item $item) {
      $this->info("Processing item id `{$item->id}`...");
      $this->processItem($item);
  });

  $this->comment("Processed {$items->count()} items.");
  ```

## Strings & Formatting

- **String concatenation** use concatenation over interpolation
- **String quotes** use single quotes where possible

## Enums

- Use PascalCase for enum values

## Comments

Be very critical about adding comments as they often become outdated and can mislead over time. Code should be self-documenting through descriptive variable and function names.

Adding comments should never be the first tactic to make code readable.

*Instead of this:*
```php
// Get the failed checks for this site
$checks = $site->checks()->where('status', 'failed')->get();
```

*Do this:*
```php
$failedChecks = $site->checks()->where('status', 'failed')->get();
```

**Guidelines:**
- Don't add comments that describe what the code does - make the code describe itself
- Short, readable code doesn't need comments explaining it
- Use descriptive variable names instead of generic names + comments
- Only add comments when explaining *why* something non-obvious is done, not *what* is being done
- Never add comments to tests that restate what the test does - the test name should carry that. A non-obvious *why* the name cannot express (for example, why a specific fixture value is pinned) is still allowed, exactly as in the rule above

## Whitespace

- Add blank lines between statements for readability
- Exception: sequences of equivalent single-line operations
- No extra empty lines between `{}` brackets
- Let code "breathe" - avoid cramped formatting

## Validation

- Use array notation for multiple rules (easier for custom rule classes):
  ```php
  public function rules() {
      return [
          'email' => ['required', 'email'],
      ];
  }
  ```
- Custom validation rules use snake_case:
  ```php
  Validator::extend('organisation_type', function ($attribute, $value) {
      return OrganisationType::isValid($value);
  });
  ```

## Blade Templates

- Indent with 4 spaces
- No spaces after control structures:
  ```blade
  @if($condition)
      Something
  @endif
  ```

## Authorization

- Policies use camelCase: `Gate::define('editPost', ...)`
- Use CRUD words, but `view` instead of `show`
- Rely on Laravel's automatic policy discovery. Do NOT register policies in `AuthServiceProvider::$policies` (or `Gate::policy(...)`) when the policy follows the naming convention: `App\Models\...\Foo` resolves to `App\Policies\...\FooPolicy`, mirroring the sub-namespace after `Models\`. The `$policies` array should stay empty. Add an explicit mapping ONLY when a policy's name or namespace deviates from that convention.

## Translations

- Use `__()` function over `@lang`:

## API Routing

- Use plural resource names: `/errors`
- Use kebab-case: `/error-occurrences`
- You can use deep nesting:
  ```
  /errors/1/occurrences/2/records
  ```

## Testing

- Use descriptive test method names
- Follow the arrange-act-assert pattern

## Concurrency and row locking

Before claiming a locking read (`SELECT ... FOR UPDATE`, `lockForUpdate()`,
`sharedLock()`) makes something safe, establish what it actually locks. In InnoDB
the lock follows the **query plan**, not the `WHERE` clause. Run `EXPLAIN` on the
exact statement and read the chosen `key`. The planner picks whichever index it
judges most selective, so a lock you believe is scoped to one column can land on
another and change as the table fills.

Consequences to check for, each of which is a real defect and not a theoretical one:

- **A range or index scan takes gap and next-key locks**, so it can block unrelated
  rows. Two operations that share nothing but a neighbouring index entry will
  serialise against each other.
- **Gap locks do not conflict with other gap locks**, so a lock that degenerates
  into one serialises nothing while still looking like protection.
- **A point lock on the primary key (`WHERE id = ?`, `EXPLAIN` shows
  `type=const`, `key=PRIMARY`) takes no gap locks.** Prefer it. When the thing to
  serialise is "repeated operations on this record", lock that record's own row.
- **Lock waits and deadlocks surface as exceptions** (`1205`, `1213`). Decide what
  the user sees. An uncaught one is a 500, not a refusal message.

Verify at realistic scale, not at whatever the dev database happens to hold. A
handful of rows makes the planner full-scan and lock everything, which looks like
correct serialisation and disappears the moment the table grows. Prove the negative
too: run the same race with the lock removed and confirm it fails, otherwise the
test proves nothing.

Read stale data as stale. Values loaded before the transaction opened may already
be wrong by the time it runs; re-read from the locked row whatever the logic
branches on.

Do not write a `SHALL` into a spec about which index is used. That is the planner's
choice, not the code's, so no implementation can enforce it. Specify the guarantee
(what is serialised against what), not the mechanism.

When a check cannot be made atomic, say so plainly in the code comment and the
spec. "Narrows the window" is an honest and useful claim; "closes the race" when it
does not is worse than no claim, because it stops the next reader looking.

## Quick Reference

### Naming Conventions
- **Classes**: PascalCase (`UserController`, `OrderStatus`)
- **Methods/Variables**: camelCase (`getUserName`, `$firstName`)
- **Routes**: kebab-case (`/open-source`, `/user-profile`)
- **Config files**: kebab-case (`pdf-generator.php`)
- **Config keys**: snake_case (`chrome_path`)
- **Artisan commands**: kebab-case (`php artisan delete-old-records`)

### File Structure
- Controllers: plural resource name + `Controller` (`PostsController`)
- Views: camelCase (`openSource.blade.php`)
- Jobs: action-based (`CreateUser`, `SendEmailNotification`)
- Events: tense-based (`UserRegistering`, `UserRegistered`)
- Listeners: action + `Listener` suffix (`SendInvitationMailListener`)
- Requests: action + `Request` suffix (`SaveUserRequest`)
- Commands: action + `Command` suffix (`PublishScheduledPostsCommand`)
- Mailables: purpose + `Mail` suffix (`AccountActivatedMail`)
- Resources/Transformers: plural + `Resource`/`Transformer` (`UsersResource`)
- Enums: descriptive name, no prefix (`OrderStatus`, `BookingType`)

### Migrations
- Check other migrations before adding new one

### Composer Dependencies

- When adopting an API introduced mid-major in a dependency (e.g. a method added in PHPUnit 13.2 while the constraint says `^13.0`), raise the composer constraint floor to that minor in the same change. The locked version is not the contract; the constraint is. CI runs or fresh installs that resolve an older minor will fail on the missing API even though it works locally.

### Code Quality Reminders

#### PHP
- Use typed properties over docblocks
- Prefer early returns over nested if/else
- Use constructor property promotion when all properties can be promoted
- Avoid `else` statements when possible
- Use string concatenation over interpolation
- Always use curly braces for control structures
- Closure not using "$this" should be declared static
- PHP internal functions must be imported
- In Laravel project use now() helper instead of Carbon::now()
- All PHP files must declare declare(strict_types=1) at the top
