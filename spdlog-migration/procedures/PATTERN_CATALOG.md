# messagefacility → spdlog: pattern and edge-case catalog

**Bucket 3 artifact** (reusable knowledge, instance-free). Distilled from
`SPDLOG_MIGRATION_PLAN.md` (rev 2) and `SPDLOG_MIGRATION_PLAN_MULTIPACKAGE.md`
(rev 3), with all file names, line numbers, counts and effort estimates removed.

Companion to `PROCEDURE.md`, which references sections here by number. This file
answers *"what might I find, and what do I do about it"*; `PROCEDURE.md` answers
*"in what order"*.

Every pattern below was found at least once in a real package. Absence of a pattern
from a new file set is normal; presence of a pattern **not** listed here is a signal
to stop and extend this catalog (see §9).

---

## 1. The three load-bearing invariants

Violating any of these produces a defect that compiles cleanly and fails later — at
runtime, or silently, or only in a downstream package. They are stated first because
every other rule is subordinate to them.

### 1.1 The message body is an argument, never a format string

```cpp
spdlog::log(level, "{}: {}", where, body);   // correct
spdlog::log(level, body);                    // WRONG
```

The second form parses `body` as a fmt format string. Any message containing a literal
`{` — array/vector dumpers emit `{ 0; 0; 0 }`, and some ID types print braces — yields
`[*** LOG ERROR ***] invalid format string` **at runtime**, replacing exactly the
diagnostic you needed. It cannot be caught by the compiler, and it only triggers for
the subset of messages that happen to contain braces.

Applies to the sink's destructor and to any hand-written `spdlog::` call added later.

### 1.2 The accumulating buffer must reduce to `std::ostream&`

The log sink accumulates into a `std::ostringstream`. This is not an implementation
detail; it is the contract that makes three separate things work:

- types whose only stream support is a non-template, `std::ostream`-only ADL
  `operator<<` (see §3.4);
- generic manipulators declared as `template <typename Stream> Stream& operator<<(Stream&&, X&&)`;
- everything with an ordinary ostream inserter and no `fmt::formatter`.

Replacing it with an `fmt::memory_buffer` or similar "optimization" breaks all such
sites simultaneously. Mark it with a comment in the header saying so.

### 1.3 Any log type stored or returned by value needs a disarming move constructor

A sink that declares a destructor gets **no implicitly generated move constructor**;
if it also deletes the copy constructor, it cannot be stored by value or returned by
value at all. This exact defect appeared in two successive plan revisions before being
caught, in both cases because the design was written before being compiled against
real call sites.

The move constructor must **disarm the source** so the message is emitted exactly once
by whichever object survives:

```cpp
LogStream(LogStream&& other)
  : buf_{std::move(other.buf_)}, where_{other.where_}
  , level_{other.level_}, active_{other.active_}
{ other.active_ = false; }
```

Delete move-assignment; messagefacility deletes it too, so no existing code can depend
on it.

---

## 2. Call-site forms and their mapping

### 2.1 Level mapping

| messagefacility | spdlog level |
|---|---|
| `LogError`, `MF_LOG_ERROR`, `LogProblem`, `LogSystem` | `err` |
| `LogWarning`, `MF_LOG_WARNING`, `LogPrint` | `warn` |
| `LogInfo`, `MF_LOG_INFO`, `LogVerbatim`, `MF_LOG_VERBATIM`, `LogAbsolute`, `LogImportant` | `info` |
| `LogDebug`, `MF_LOG_DEBUG` | `debug` |
| `LogTrace`, `MF_LOG_TRACE` | `trace` |
| `isDebugEnabled()` | `should_log(debug)` wrapper |

The `Verbatim`/`Problem`/`Print`/`Absolute` variants differ from their counterparts
only in that mf suppresses the record prefix. Under a single spdlog pattern the
distinction disappears globally; acceptable where the output is read by humans rather
than parsed, which must be confirmed rather than assumed for a new file set.

`LogAbsolute`, `LogSystem`, `LogImportant`, `EndMessageFacility`, `FlushMessageLog`
had no uses in the packages surveyed so far; the mapping is given for completeness and
is unverified.

### 2.2 Mechanical form: single-statement temporary

The overwhelming majority. Swap the include, drop the category argument, drop any
manual class/method prefix already embedded in the message text — the macro supplies
it now. Also drop redundant trailing `std::endl`, which produced a stray blank line
under mf as well.

### 2.3 Named accumulating object

Held in a local, streamed to across several statements, often inside conditionals and
loops, flushed by its destructor at end of scope. The substitution is one line
(`mf::LogX log("cat");` → `auto log = LAR_LOG_X;`) **provided** the sink has the same
destructor-flush lifetime semantics. Do not restructure the surrounding control flow.

Two sub-cases needing care:

- **Enclosing braces may be load-bearing.** A `{ }` block sometimes exists specifically
  so the message flushes before a subsequent statement can throw. Keep the block.
- **Alive across a `throw`.** The object accumulates, then the scope exits via
  exception; the message is emitted during unwinding. Works unchanged, but note that a
  nearby `// will throw` comment may be describing the *logger*, which is wrong — see §5.3.

### 2.4 Log object passed through `Stream&&` templates

A generic printing protocol, `template <typename Stream> void Print*(Stream&& out, ...)`,
instantiated both with `std::ostream&` and with log objects, and frequently
re-`std::forward`ed through further template levels inside loops and switches.

This is the single constraint that rules out converting to `fmt` format strings — those
call sites pass the log object *itself* into templates that stream to it. Any
replacement type must be usable as a `Stream&&` template argument and survive repeated
forwarding within one full-expression.

Two failure modes to watch for in the *existing* code (both pre-existing, neither
introduced by the migration):

- an entry point declared `Stream&&` that forwards its parameter as an **lvalue**
  (missing `std::forward`), so two public entry points of the same class have
  *different* ownership semantics — one moves the log in, the other binds a reference
  to the caller's temporary. Both work with a correct sink, but a test must cover both.
- a helper returning `Stream&` — an lvalue reference to what may be a temporary. Latent
  dangling reference. Do not make it worse; fixing it is out of scope for a logging
  migration.

### 2.5 Log object stored **by value** as a class member

The case that breaks naive designs. A class template holds `Stream out;` — by value,
not by reference — so it *owns* the log object and flushes when the member dies, which
is after the caller's full-expression has ended. Requires §1.3. Verify both the
by-value instantiation (prvalue argument) and the by-reference instantiation (lvalue
argument) compile and emit exactly once.

Note the behavioural consequence: when a sink is constructed at a call site and moved
into such a member, the compile-time prefix records **the call site**, not the internals
of the class that owns it. That is usually desirable — the reader wants to know who
asked for the dump — but it differs from what someone assuming "prefix captured where
the message is composed" would expect. Document it wherever the ownership transfer
happens.

### 2.6 Generic dump/manipulator helpers

Helpers declared `template <typename Stream> Stream& operator<<(Stream&&, X&&)` must
**stay generic**. Narrowing them to `std::ostream&` is tempting during a migration and
breaks every downstream package that streams them into a log object. Their output
frequently contains literal braces — see §1.1.

### 2.7 Runtime level query

`mf::isDebugEnabled()` → a `should_log(debug)` wrapper. Do **not** use the sink's
`explicit operator bool` for this: it constructs a temporary.

### 2.8 Initialization and context

- `StartMessageFacility` / `SetApplicationName` → one init shim, called once.
- `SetContextSinglet` / `SetContextIteration` → **no equivalent** if the available
  spdlog build lacks `spdlog/mdc.h`. Delete the calls; the scoped-name prefix conveys
  strictly more information.
- Packages often rely on a *shared* test-support header for initialization rather than
  calling init themselves. One shim can therefore cover several packages at no extra
  cost. Confirm which packages initialize and which merely inherit.

---

## 3. Type-system and formatting hazards

### 3.1 iomanip

`std::setw` / `std::setprecision` / `std::fixed` return manipulators taking
**`std::ios_base&`**, not `std::ostream&`. A sink with only the `std::ostream&`
manipulator overload will not accept them. Both overloads are required:

```cpp
LogStream& operator<<(std::ostream&  (*manip)(std::ostream&));   // std::endl, std::flush
LogStream& operator<<(std::ios_base& (*manip)(std::ios_base&));  // std::setw, std::fixed
```

The hardest single shape combines all of it: a named object, plus iomanip, plus a loop,
plus embedded `\n` — a column-formatted table built across many statements.

### 3.2 Custom `operator<<` types with no `fmt::formatter`

ID types, geometry/vector types from external libraries, exception types, and
`const char*` accessors are typically ostream-insertable and have no fmt formatter.
They work through the ostringstream (§1.2) and need no per-type work — which is
precisely the argument against a format-string rewrite.

### 3.3 Multi-line bodies

Embedded `\n` and statements physically wrapped across source lines are common house
style. spdlog emits a multi-line body as a single record; this is fine. The wrapping
matters for tooling, not semantics — see §5.1.

### 3.4 ostream-only ADL `operator<<` — a concentrated failure mode

A dimensional-analysis or units type system may provide stream support as a
**non-templated, `std::ostream`-only** free function found by ADL. These work through
the ostringstream, but they concentrate risk: if the sink ever stops reducing to
`std::ostream&`, every such site fails at once, and a single file can hold dozens.

Mitigation: compile **one** such site before the bulk edit (the smoke test in
`PROCEDURE.md`), and keep the §1.2 comment in the header.

---

## 4. Behavioural regressions to detect and mitigate

These are the migration's real risk surface. All are cases where the code still
compiles and the tests still pass while the behaviour has changed.

### 4.1 Rate limiting is lost

mf capped repeated messages per category (`limit`, `timespan`). A single default logger
has no equivalent. Harmless for a message on a cold path; a flood for a message in a
loop or a comparison operator.

**Detection is a required step, not an optional one.** For every migrated site, ask
whether it can be reached repeatedly. Two shapes found in practice:

- a warning in an accessor called from a comparison operator — sorting a container then
  emits O(n log n) messages;
- a warning inside a decompression or parsing loop — one malformed input emits
  thousands.

**Mitigations**, in order of preference:
1. one-shot guard (function-local `static std::once_flag`) — for "this configuration is
   wrong" messages that are equally useful once;
2. counter guard ("... and N more suppressed") — for data-dependent messages where the
   *count* is diagnostically meaningful, e.g. corrupt input. Use this for raw data, test,
   and decompression / compression / parsing loops;
3. demote to `debug` — smallest change, but hides real data corruption; acceptable only
   when the message is genuinely not actionable.

Never leave an unguarded log in a hot path on the grounds that mf used to cap it.

### 4.2 Levels silently vanishing

The most likely invisible regression in the whole exercise. If the old test
configuration set a verbose threshold (e.g. `DEBUG`), then `trace`/`debug` sites are
visible today. spdlog defaults to `info`, so after migration they disappear with **no
compile error and no test failure**. The init shim must set the level explicitly to
match the old threshold.

### 4.3 Do not set `SPDLOG_ACTIVE_LEVEL`

Compile-time level suppression looks like a free win and is not. Test-support code may
deliberately assert that trace/debug statements are *not* compiled away. Use runtime
levels only.

### 4.4 Per-category routing is lost

Categories disappear as routing keys. The scoped-name prefix replaces them as a
*human* filtering aid and is strictly more precise — categories are typically
inconsistent in practice (one string shared by several classes; occasional empty
category strings). Record the loss; do not try to rebuild a category registry.

### 4.5 Configuration blocks describing mf destinations

Config files may contain a messagefacility destination DSL (console + file + per-category
limits + statistics summary). The honest translation is a level plus at most a two-sink
setup. Keep the config key so existing user configuration does not hard-fail, ignore the
mf-specific sub-keys, and emit **one** warning naming what was ignored. Record dropped
capabilities as a comment in the file itself.

### 4.6 Prefix-free (`Verbatim`) output

Under mf, `Verbatim`/`Problem` suppressed the record prefix per call. Under spdlog the
pattern is global. If a file's output is compared or read as a table, choose the
minimal pattern; see the open decision in §8.

---

## 5. Mechanical traps

### 5.1 No regex or `sed` bulk rewrite

Statements wrap across source lines and `<<` chains contain string literals with
parentheses and braces. A naive `sed` silently corrupts continuation lines. Use an
AST-aware tool or a careful file-by-file pass.

The special danger: a file of many near-identical `if (ok) LogVerbatim ... else
{ ++nErrors; LogProblem ... }` pairs is the most `sed`-able thing in the tree and also
the one where a bad rewrite **converts failures into silent successes**.

### 5.2 Logging used as a test-assertion reporter

A hand-rolled test main may use an error-level log as its failure reporter, with a
separate counter driving the exit code. Semantics are preserved (an `err` message is
emitted under a default `info` level, and the counter still works), but this must be
verified deliberately — by breaking one assertion on purpose and confirming the test
still fails.

### 5.3 Stale comments that describe the logger

Comments such as `// will throw` next to an error-level log are often wrong: mf's
`LogError` does not throw. Delete the comment. Do **not** "restore" throwing behaviour
that never existed.

### 5.4 Dead includes and commented-out call sites

Files with a messagefacility include and zero live uses, or whose only call site is
inside a comment block, appear in every package. Delete the include and drop the link
dependency; there is nothing to migrate.

### 5.5 Dangling-else

The macro form has the same dangling-else hazard mf had: `if (cond) LAR_LOG_INFO << ...;
else ...` needs braces. No change from current behaviour, but do not introduce it while
reformatting.

### 5.6 Copy-pasted category strings

Categories are often wrong by copy-paste (a file using another file's category). They
become scoped names automatically, so this fixes itself — worth noting only so the
before/after output diff is not surprising.

---

## 6. Build-system rules

### 6.1 Dependency visibility determines blast radius

- `PRIVATE` link of the logging library → no interface change; safe.
- **`INTERFACE`/`PUBLIC`** → required when a **public installed header** contains log
  calls. The logging dependency must be carried the same way the mf dependency was.
- `find_package(... EXPORT)` → re-exported in the package's CMake config, so removing
  it is an interface change **visible to every downstream package**. Do it last, and
  announce it.

### 6.2 Header placement versus the dependency graph

The logging header must live somewhere every participating package already depends on.
When one package sits *outside* the natural home's dependency cone, the options are:
add a new dependency (a layering regression, visible downstream), duplicate the macro,
or move the header to a lower-level package both already depend on. Prefer the lowest
common dependency that the header legitimately belongs to on merit. **Confirm the
candidate package is in scope for edits before committing to it.**

### 6.3 Migration order follows the dependency graph

Packages must be migrated in dependency order, because generic helpers in an upstream
package are streamed into logs by downstream packages. Determine the order before
starting, not during.

### 6.4 Removing the old dependency from the environment

Drop the mf spec from the build environment only after confirming no sibling package in
the development area still needs it.

---

## 7. ROOT / serialization interaction

For packages containing persisted data products, the question is whether logging can be
triggered during I/O — which would mean the logger being invoked from a streamer,
potentially at static-initialization time. Check, in order:

1. **Do any headers contain log calls?** Dictionary sources are generated from headers;
   if no header includes the logging header, the dictionary never sees it. This is the
   decisive structural check.
2. **Any `ClassDef`/`ClassDefNV` or hand-written `Streamer()`?** Selection-XML +
   `genreflex` setups generally have neither.
3. **Do any schema-evolution (`<ioread>`) rules call functions that log?** Read them;
   trivial member assignments are safe.

If all three are clean, no logging occurs during deserialization. Note that spdlog's
*lazily created* default logger makes even the static-init scenario safe, but confirm
rather than assume.

Related: watch for functions invoked from **namespace-scope initializers** (before
`main()`). Do not add logging to them. spdlog's lazy default logger would tolerate it;
mf would not have.

---

## 8. Decisions that must be fixed before an unattended run

These are the plan's open questions, restated as parameters the workflow needs. Each
must have a committed default, or the workflow will stop and ask.

| Decision | Options | Notes |
|---|---|---|
| Output pattern | timestamped+level, or bare `%v` | bare `%v` makes the before/after output diff far easier; timestamps must otherwise be normalized away |
| Header home | lowest common dependency (preferred), new dependency, or duplication | §6.2; **blocks the foundation phase** |
| File destinations from old config | keep as a second sink, or drop | §4.5 |
| Deprecation window for renamed public init functions | one release with forwarders, or break immediately | affects out-of-package callers |

---

## 9. Extending this catalog

A new file set may contain a pattern not listed here. The workflow's classification
step must report any log call site it cannot place in §2, rather than guessing.

The lesson from two failed plan revisions: **a sink design must be compiled against the
real call-site shapes before it is written into a plan.** Both the missing move
constructor (§1.3) and the format-string hazard (§1.1) were found by prototyping, not
by review. When a new shape appears, write a minimal prototype that reproduces it —
including one that is *expected to fail* against the current design, if that is what
the finding is — before editing production code.
