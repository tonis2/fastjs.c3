# fastjs.c3: a lean, fast JS-dialect engine in C3 for three.c3

This file is the working plan and the progress log. Read **Progress** at the bottom first, then pick
up the next unchecked item. Update the log at the end of each session.

Related repos (all under `~/Documents/c3/`):
- `quickjs.c3`: the current QuickJS binding; the API to mirror is in `src/quickjs.c3`
- `three.c3`: the game engine, and the compatibility target. Its scripts are in `examples/*.js`
  and `src/js/prelude/*.js`; its C3 glue is `src/js/*.c3`.

## Context

three.c3 scripts its whole game layer in JS through QuickJS (the `qjs` binding, vendored at
`three.c3/lib/quickjs.c3l`). The engine's own comments measure the cost:
- ~380 ns per C3↔JS crossing (`src/js/bind_query.c3:455`)
- 70–150 ns per entity per frame of JS-side work whatever the data layout; 0.575 ms at 5000 entities
  (`src/js/prelude/entity.js:49-64`)
- crowd separation moved to C3 because "in QuickJS it is milliseconds" (`src/scene/steer.c3:17`)
- fixed-step rate capped at 240 Hz so the interpreter isn't the bottleneck (`src/scene/clock.c3:61`)
- the shim can't do opaque native data, key enumeration, non-Uint8 typed-array reads, promise results,
  or async eval, so the binding has workarounds for each

Goal: a new engine, written in C3, for the JS **dialect** three.c3 actually uses. It drops the parts of
the spec that block fast implementation, keeps classes, and is a drop-in for the `qjs` C3 API.
Target: 2–5× QuickJS on game-style code, and crossings an order of magnitude cheaper.

**Decisions made with the user:**
- every three.c3 example runs **unmodified**; the prelude may be lightly edited
- **async/await is in v1**
- the engine is a **new sibling repo** whose C3 API mirrors quickjs.c3's `Context`/`Value`

Working name: `fastjs.c3` (rename freely).

## The language: what the census of three.c3 says (37 files, ~28k lines)

**Supported (all used, most heavily):**
- **Classes**
  - `extends` (88), `super()` (79), `super.m()`
  - static methods and **static fields** (`static columns = {...}`)
  - instance fields (135)
  - **get/set accessors (317)**
  - computed members (`[Symbol.iterator]()`, `static [Symbol.iterator]()`)
  - generator methods
  - `new.target`
- **Declarations:** `const`/`let` only. There is no `var` anywhere.
- **Functions and literals**
  - arrows, function declarations, default params
  - rest/spread in calls, arrays and objects
  - array and object destructuring
  - shorthand methods, object-literal getters, computed keys
- **Expressions**
  - template literals, including multi-line WGSL shader source
  - `?.`, `??`, `**`, bitwise ops, ternary, `===`
  - loose `==`, only ever `== null`
  - `typeof`, `instanceof`, `in`, `delete`, unary `+`
- **Control flow:** `for..of`, C-style `for`, `while`, `switch`, `for..in` (widget.js), try/catch/finally, throw
- **Async:** generators, `async`/`await`, Promises. These are the engine's own plumbing: `run()` wraps
  every script as an async IIFE, and `three.nextFrame()` and the upload resolvers are promises.
- **ES modules:** named and default exports, side-effect imports. The prelude is modules; the examples
  are plain scripts.
- **Builtins**
  - Object: `keys/values/entries/assign/defineProperty/defineProperties/fromEntries`, `prototype.hasOwnProperty`
  - Array: `isArray/from`, plus `push/pop/splice/slice/map/filter/some/find/forEach/fill/join/includes/indexOf/sort`
  - Number: `isFinite/isInteger/isNaN`, `toFixed`
  - String: `slice/indexOf/split/padStart/startsWith/endsWith/trim/toLowerCase/charCodeAt/replace`
  - `Math.*` (including `imul` and `hypot`), JSON (with `toJSON`), Map, Set, Symbol (keys plus
    `Symbol.iterator`), the Error family
  - Float32/Float64/Int32/Uint32/Uint8/Uint16/Int16/Int8Array with `subarray/set/fill`, ArrayBuffer and `isView`
  - `.call/.apply/.bind`, `globalThis`, `console`
- **RegExp, minimal:** a backtracking subset (`^ $ . [] | () * + ? {n,m} \d \w \s`, flags `i g`).
  `examples/editor.js:1244` needs it. It's about 600 lines.

**Dropped:**
- `var`, `with`, `eval`, `new Function`, `arguments`
- labels, do-while, BigInt, WeakMap/WeakRef
- `__proto__`/setPrototypeOf, private `#fields`, `??=`
- sloppy mode: everything is strict
- getters/setters on Array index slots
- Proxy and Reflect (prelude edits below)

**Semantics trimmed for speed, without breaking the census:**
- Number storage is int32 plus double, stored unboxed.
- An object's prototype is fixed at creation.
- Arrays are always dense. Holes are an error, or store `undefined`.
- `Object.defineProperty` is supported, since entity.js installs column accessors on prototypes with it.
  It's a slow path that changes the object's shape.
- ToPrimitive calls `toString`/`valueOf` only on the slow path. MorphWeights relies on `toString`.

**Prelude edits:** about 10 sites, all in `three.c3/src/js/prelude/`.
- `entity.js:668`: the Proxy construct guard becomes a check in the tracked class's constructor. It
  uses `new.target` plus the `pending` flag it already consults. `Reflect.construct` (`:437`, `:678`)
  becomes `new Class(...args)`.
- `shader.js:357`: the uniform-column Proxy becomes an indexed-accessor class, the same way
  `mesh.js:173` MorphWeights already does it.
- Regex uses stay, because the subset covers them.

## Architecture (new repo `fastjs.c3/`)

```
src/lex.c3        hand-written single-pass lexer; zero-copy token slices; template-literal states
src/parse.c3      Pratt expressions + recursive-descent statements → arena-allocated AST
src/resolve.c3    scopes → local register / upvalue / module slot / global; TDZ for let/const;
                  class field + method layout collected per class
src/compile.c3    AST → register bytecode (Lua-5 style, 32-bit instrs), constant pool, line table
src/value.c3      NaN-boxed 8-byte Value: double | int32 | bool | null | undefined | ptr kinds
src/object.c3     Shapes (hidden classes, transition tree), slots, accessor slots, dense arrays
src/ic.c3         inline caches per GET/SET/CALL site: (shape → slot | getter | setter), mono + 4-way poly
src/string.c3     interned atoms for property keys; 1-byte/2-byte strings; ropes for `+`/templates
src/vm.c3         computed-goto interpreter; frames on segmented, heap-owned stacks (suspendable)
src/gc.c3         incremental tri-color mark-sweep with write barrier; no refcounting; step budget API
src/coro.c3       generators = suspended frame; async = generator + promise driver; job queue
src/module.c3     ES module records, linking, loader hooks (same shape as quickjs.c3 ModuleHooks)
src/builtins/     object, array, string, number, math, json, map_set, symbol, error, typed, promise, regexp
src/api.c3        embedding API (below)
test/             unit + differential tests
bench/            micro + three.c3-shaped benchmarks
```

Key design points:
- **Classes compile to a precomputed instance shape.** The constructor allocates the object directly
  in its final shape: fields plus the slots the constructor assigns, learned after the first run.
  Methods and accessors live on the prototype's shape, so `this.position` reaches its getter through
  one IC hit.
- **Accessor-aware ICs** matter because three.c3 is built on getters and setters (317). An IC entry
  caches the getter's function and calls it without a property lookup. A trivial getter (`return this._x`)
  is inlined into the IC as a slot load.
- **Typed arrays are first-class VM objects.** Indexed element access gets a dedicated opcode
  (`GET_ELEM_F32` and the like, picked by the IC), so `pos[0] += v` compiles to a load, an add and a store.
- **Native column views.** Add an engine-level `subarray` that doesn't allocate a new ArrayBuffer view
  object for each access. This removes the per-access allocation in entity columns.
- **Frames live on growable stack segments owned by a coroutine object.** Suspending a generator or an
  async function never copies a frame, and `await three.nextFrame()` is cheap.
- **GC:**
  - `ctx.gc_step(budget_us)` is called once per frame from `frame_loop.c3`, so there are no
    stop-the-world pauses.
  - Roots held by C3 live in a handle table (`retain`/`release`).
  - The memory limit is checked when the heap grows.
- **Interrupts:** the interpreter polls a counter on backward jumps and calls, and invokes the
  `InterruptFn`. This matches the existing budget logic in `runtime.c3:1169`.
- **Errors:** an `Error.stack` built from the line table (`file:line:col`), plus parse errors with the
  source line, because the AI-agent workflow in three.c3 depends on good messages.

## Embedding API — drop-in for `qjs`

Mirror the existing signatures in `quickjs.c3/src/quickjs.c3`:
- runtime: `open(memory_limit, stack_limit)`, `close`, `eval(source, name, EVAL_GLOBAL|EVAL_MODULE)`
- errors: `exception`, `raise`, `error`
- reading values: `text`, `number`, `truth`, `global`, `property`, `set_property`, `index`,
  `set_index`, `length`
- creating values: `array`, `object`, `string`
- functions: `function(HostFn, name, arity, opaque)`, `call`, `is_function`
- lifetime: `retain`, `release`
- data: `json`, `from_json`, `bytes`, `buffer`, `buffer_copy`, `typed_array`
- jobs and modules: `on_interrupt`, `step_job`, `jobs_waiting`, `collect`, `on_modules`, `ModuleHooks`

three.c3 calls these about 1000 times (`set_property` 223, `raise` 162, `set_index` 133, …). Moving
three.c3 over means changing its import and nothing else.

**New API**, which closes the gaps that forced workarounds in three.c3:
- `Atom ctx.atom(name)` plus `get(obj, atom)`/`set(obj, atom, v)`: no string interning per call
- native classes with opaque data: `ctx.native_class(...)`, `set_opaque`/`get_opaque`. These replace
  the `(index, generation)` number pairs.
- `ctx.keys(obj)`: removes the ui.js normalisation workaround
- `ctx.view(value) -> (kind, ptr, len)` for any typed array: removes the 3-argument buffer/offset/length
  workaround
- `ctx.promise_state(v)` / `promise_result(v)` and `ctx.eval(..., EVAL_ASYNC)`: remove the `then`-hook
  workaround in `await_settled`
- **typed fast host functions**: register `fn double(double, double)`-style signatures. The VM calls
  them directly, without boxing args into a `Value[]`. Target: a crossing under 20 ns, against 380 ns now.
- `ctx.gc_step(budget_us)`

## C3 conventions for the engine (c3c 0.8.6 installed, langrev 1)

- 0.8.x syntax only: `excuse`, `T?`, `return X~`, `alias`/`typedef`, `List {T}`, `@cname`.
- **Two error channels, kept separate:**
  - Parse and compile failures are `T?` with excuses (`SYNTAX`, `TOO_MANY_LOCALS`), and they carry a
    diagnostic record.
  - A JS `throw` is VM state (a pending-exception slot plus unwinding), not a C3 optional. Mixing the
    two would put a check after every opcode.
  - API functions that can surface a JS exception return `Value?` with `THREW`, matching quickjs.c3.
- **Memory:**
  - The AST and the parser scratch space live in an arena freed after compiling. `tmem` is used only
    inside one `@pool` per compile.
  - Bytecode, the constant pool and the line table are owned by the function object on the heap.
  - The GC heap is its own page allocator. It is not `mem`, because it must be walkable and stay inside
    the memory limit.
- **Contracts:**
  - `@require` goes on the internal invariants (register indices, slot bounds, shape kinds).
  - The release build is `-O3 --safe=no`, so contracts cost nothing in the interpreter loop.
  - Script input is never trusted to a contract; the parser validates it.
- **Dispatch:** C3 has no computed goto. The interpreter is a `switch` over an `enum Op` with no
  `default`, so every opcode must be handled. Measure it against a jump table of function pointers
  before tuning anything else.
- **Tests:** `@test` functions in `test/`, which `c3c test` runs in safe mode with leak checking. The
  differential runner is a separate `c3c run diff` target.

## Phases (each ends in something runnable and measurable)

1. **Skeleton and harness.**
   - Repo, `project.json`, a test runner.
   - A **differential runner**: it runs a `.js` file in fastjs and in QuickJS (through quickjs.c3)
     and diffs the `console.log` output.
2. **Lexer and parser.**
   - Milestone: every file in three.c3's `examples/` and `src/js/prelude/` parses.
   - An AST pretty-printer round-trips them.
   - Parse time is benchmarked against QuickJS's.
3. **Core VM.**
   - Resolver, compiler, interpreter.
   - Value types, NaN-boxing, functions and closures, plain objects (dictionary mode at first),
     arrays, strings, control flow, exceptions, a simple stop-the-world GC.
   - Milestone: the differential suite passes for core semantics.
4. **Full dialect syntax.**
   - Classes in full (fields, statics, accessors, super, computed keys, `new.target`).
   - Destructuring, spread/rest, template literals, `?.`/`??`, `for..of` through the iterator
     protocol, `for..in`, switch.
5. **Speed layer.**
   - Shapes, transition tree and accessor-aware ICs.
   - Typed-array opcodes, int32 fast paths, string ropes.
   - Benchmark against QuickJS on micro-benchmarks plus a port of the entity gather loop.
6. **Builtins.** The census list above, plus the minimal RegExp.
7. **Coroutines.** Generators, Promise, async/await, the job queue, `Promise.all`.
8. **Embedding.**
   - Modules and the `qjs`-compatible `api.c3`, plus the new API.
   - The incremental GC with `gc_step`, interrupts, memory limits.
9. **three.c3 integration.**
   - Swap the import and apply the prelude edits.
   - Then gradually adopt atoms, native classes, typed host functions and `gc_step` in `src/js/bind_*.c3`.

Rough size: 15–20k lines of C3. The parser and compiler take about 5k, the VM, objects and GC about
6k, builtins and regex about 5k, and the API and modules about 2k.

## Verification

- **Differential tests:** each feature gets small `.js` cases checked against QuickJS output. The
  three.c3 prelude's pure modules (`math.js`, `cooldown.js`, `query.js`) are run headless in both engines.
- **Parse coverage:** all 37 three.c3 files parse; this goes in CI.
- **three.c3 end to end:** run every example in both builds and compare the screenshots:
  `./build/three --headless --script examples/<x>.js --frames 900 --screenshot out-%03d.png --every 150`.
  The scenes are deterministic and the textures are generated, so the images should match.
- **Performance against the QuickJS baselines recorded in three.c3's comments:**
  - crossing cost: 380 ns
  - entity gather: 0.575 ms at 5000 entities
  - per-frame JS time in `wumpa_run.js` and `tank_yard.js`, using `frameStats`
  - GC pause times under `gc_step`: none over 1 ms

## Progress

Mark items `[x]` when done, and add a dated line to the log.

### Phase 1: skeleton and lexer
- [x] repo, `project.json`, `plan.md`
- [x] `src/lex.c3`: tokens, numbers, strings, templates (brace-depth stack), regex rescan, comments, ASI newline flag
- [x] `test/lex_test.c3`: unit tests (15, all passing)
- [x] `tools/lexcheck.c3`: lexes every three.c3 script and reports errors (target `lexcheck`)
- [ ] differential test runner (moved to phase 3; it needs the VM)

### Phase 2: parser
- [x] `src/ast.c3`: one `Node` struct (kind, op, flags, a/b/c/d children, list, name, number), arena-allocated
- [x] `src/parse.c3`: precedence climbing for binary operators, recursive descent for statements, classes, modules
- [x] cover grammar for arrows and destructuring: `to_pattern` / `to_params` reinterpret a parsed expression
- [x] regex rescan in prefix position; one-token `peek()` that snapshots `LexState`
- [x] `src/print.c3`: a fully parenthesized printer; `tools/parsecheck.c3` runs parse → print → parse → print
- [x] `test/parse_test.c3`: 13 test groups (precedence, arrows, destructuring, classes, ASI, modules, the
      error message for each dropped feature, error positions)

### Phase 3: core VM (breakdown)
The goal is to run plain scripts: numbers, strings, let/const, functions and closures, objects,
arrays, control flow, exceptions and `console.log`. Classes, generators and builtins come in later
phases, but the data layouts below are designed for them now.

- [x] **3a `src/rt/value.c3`: NaN-boxed `Value` (`ulong`).**
  - Doubles are stored raw. A non-double has top 16 bits 0xFFF9–0xFFFF:
    - 0xFFF9: int32
    - 0xFFFA: special (undefined, null, false, true, plus internal `empty`/hole and `uninitialized` for TDZ)
    - 0xFFFB: string pointer
    - 0xFFFC: object pointer
    - 0xFFFD: symbol pointer
  - x86's default NaN is 0xFFF8…, which still counts as a double. Any other NaN, such as one read
    from a Float64Array, is canonicalized when it enters a `Value`.
- [x] **3b Heap and strings** (`src/rt/heap.c3`, `src/rt/string.c3`).
  - Every heap object starts with `GcHeader { next, kind, mark }`.
  - `JsString` holds a length, a hash, and a flexible array of either 1-byte (Latin-1) or 2-byte
    (UTF-16) code units.
  - Property keys are interned atoms, so key comparison is pointer comparison. Array index keys
    stay int32.
  - Cooking escapes turns raw source into a `JsString`.
- [x] **3c Objects with shapes from the start** (`src/rt/object.c3`).
  - Layout: `JsObject { header, Shape*, Value* slots, proto }`.
  - A `Shape` is a node in a transition tree: parent, key, slot index, attributes, transitions, and a
    lookup hash once the shape grows large.
  - An object with many deleted keys switches to dictionary mode.
  - Arrays have dense `Value* elements` plus a length.
  - Inline caches come in phase 5, but they can be added without changing this layout.
- [x] **3d `src/compile/resolve.c3`: scope analysis.**
  - Every binding is resolved to one of: a register, a captured box, a module slot or a global.
  - `let`/`const` get TDZ checks, and function declarations are hoisted.
  - A captured variable lives in a **Box**, a heap cell. Closures hold a flat array of box pointers,
    in the Lua style, with no environment chain.
  - A `let` in a loop gets a fresh box each iteration, which gives per-iteration closure semantics.
- [x] **3e Bytecode** (`src/rt/bytecode.c3`).
  - Register-based, 32-bit instructions: `op:8 A:8 B:8 C:8`, or `op:8 A:8 Bx:16`.
  - A function has at most 255 registers and a constant pool.
  - A line table maps the pc to source lines.
  - Each function has a handler table of `(start, end, handler_pc, catch_reg)` entries.
  - `finally` is compiled by duplicating its code at each exit.
- [x] **3f `src/compile/codegen.c3`:** AST to bytecode. Entry point: `compile::compile_script` in `src/compile/compile.c3`.
- [x] **3g The VM** (`src/rt/vm.c3` frames and calls, `src/rt/interp.c3` the loop, `src/rt/ops.c3` semantics).
  - JS→JS calls don't recurse on the C stack: a frame records its proto, closure, pc and register
    base. That is what lets phase 7 suspend a frame.
  - The register file is a per-fiber stack.
  - JS semantics: ToNumber, ToString, ToPrimitive, `==`/`===`, `typeof`, property get and set
    through the prototype chain.
  - Number to string uses the shortest representation that round-trips.
- [x] **3h GC** (`src/rt/gc.c3`): stop-the-world mark-sweep with an explicit mark stack. stop-the-world mark-sweep. The roots are fiber stacks, globals and the C3 handle
      table. It becomes incremental in phase 8.
- [x] **3i Test runner** (`test/js/run.sh`, `test/js/regen.sh`).
  - Each test file has a `.out` file of expected `console.log` output, generated with
    `node test/js/x.js`. Node is installed at `~/.nvm`.
  - The runner diffs our output against the `.out` file.
- [x] **3j** `console.log` with node's exact layout (`src/rt/inspect.c3`), plus starter built-ins (`src/rt/builtins.c3`).

### Phase 3 known gaps (pick these up later)
- Error messages say "undefined is not a function"; V8 says "o.foo is not a function", using
  source text. That needs the callee's text recorded at compile time.
- `run()` stores `f.pc = pc` on every instruction. That's cheap but could be limited to ops that
  can throw.
- `expr_any` hands back a variable's own register, so `x + (x = 5)` reads the new x. Fix by copying
  when the right side assigns.
- for-of handles arrays and strings only. `Symbol.iterator`, generators and `ITERCLOSE` come in
  phases 6–7.
- Not compiled yet: object rest patterns `{a, ...rest}`, classes, regex, generators,
  async/await, modules. Each fails with "X are not supported yet".
- `s += x` copies the whole string (6× slower than QuickJS on `bench/strings.js`). Use ropes
  (phase 5).
- Node runs test files in sloppy mode. Our dialect is always strict, so tests must not rely on
  `this` being globalThis inside plain functions.

### Benchmarks (2026-11-02, `bench/run.sh`, fjs at -O3 --safe=no, QuickJS at -O2)
| benchmark | fastjs | quickjs | speedup |
|---|---|---|---|
| closures  | 0.049s | 0.106s | 2.2x |
| fib       | 0.074s | 0.145s | 2.0x |
| loop      | 0.497s | 1.226s | 2.5x |
| methods   | 0.238s | 0.294s | 1.2x |
| particles | 0.090s | 0.093s | 1.0x |
| strings   | 0.192s | 0.033s | 0.17x (needs ropes) |

These numbers come before any phase 5 work: no inline caches, and `f.pc` is stored on every
instruction.

### Phase 4: classes and the remaining syntax
- [x] Classes: everything below is supported.
  - `extends`, `super()`, `super.m()`, `super.x`
  - static and instance fields, accessors, computed members
  - `new.target`, non-enumerable methods, `new`-only constructors
  - V8's exact TDZ errors for `this`
  - subclassing natives (`extends Error`)
  - printing as `[class B extends A] { statics }`
  - How it's built:
    - The resolver synthesizes default constructors as AST and puts field initializers in hidden
      methods (`CLASS.b` instance, `CLASS.c` static).
    - Codegen's `class_expr` emits `DEFCLASS`, then `DEFMETHOD`/`DEFGETTER`/`DEFSETTER`.
    - `super()` is `SUPERCALL` + `SETTHIS`, followed by the field initializer.
- [x] Object rest patterns (`OBJREST`).
- [ ] Still missing:
  - computed field names (`[k] = 1`)
  - `super[x]` and `super.x = v`
  - `super` in object-literal methods
  - private `#x` (dropped by design)

### Phase 3h: GC (done)
- Collects only at safe points: `JMP`, `CALL`/`NEW`, `NEWOBJ`/`NEWARR`/`CLOSURE`/`NEWBOX`, and
  only when `native_depth == 0`. Native code never needs to root its temporaries. The cost is that
  a long JS callback running inside a native (e.g. `forEach`) defers collection until it returns.
- Roots: the stack up to `stack_top`, frames, the exception, global and built-ins, script slots,
  `Vm.roots` (for the host), and `heap.null_root`.
- Atoms are permanent (strings with the atom flag are never swept). Dead shapes are unlinked from
  their parents' transition lists; a dead `child_root` is cleared.
- `fjs --gc-stress` and `FJS_FLAGS=--gc-stress test/js/run.sh` collect at every safe point; all
  tests pass that way.
- Not counted toward the threshold: slot and element arrays (`mem::realloc` outside the GC
  blocks). Count them when the allocator is reworked.

### Phase 5: speed (in progress)
- [x] **Inline caches** on GETPROP/SETPROP/INITPROP/GETGLOBAL. `IcEntry` per instruction lives in
      `FunctionProto.ics`.
  - Kinds: OWN, PROTO (direct prototype; pins its shape), OWN_GETTER and PROTO_GETTER (call the
    getter directly), ARRAY_LENGTH, ADD (a shape transition when a property is added).
  - Slow paths `get_ic`/`set_ic`/`define_ic` are in `ops.c3`.
  - Every IC is cleared after a GC, since its shape pointers may be dead.
  - Known gap: ADD only re-checks the direct prototype's shape, so a setter added later to a
    grandparent prototype is missed. Use validity cells if it ever matters.
- [x] Statement-position updates and assignments don't compute their value (`DISCARD`).
      `i++`/`x += e` on plain locals work on the register in place.
- [x] Fused compare-and-branch (`JNLT`...`JNSNE` plus a JMP word) for if/while/for tests.
- [x] Constant-operand arithmetic (`ADDK`/`SUBK`/`MULK`/`DIVK`).
- [ ] Ropes or append buffers for `s += x`. `bench/strings.js` is still 0.7× QuickJS. It changes
      the JsString layout, since data must be able to live outside the header.
- [ ] Store `f.pc` only before ops that can throw or call, not every instruction.
- [ ] Typed-array element opcodes (with phase 6 typed arrays).
- [ ] Deeper prototype ICs (class hierarchies more than one level deep miss PROTO today).

### Benchmarks after phase 5 so far (2026-11-02)
| benchmark | fastjs | quickjs | speedup |
|---|---|---|---|
| closures  | 0.048s | 0.101s | 2.1x |
| fib       | 0.075s | 0.139s | 1.9x |
| loop      | 0.434s | 1.203s | 2.8x |
| methods   | 0.177s | 0.296s | 1.7x |
| particles | 0.053s | 0.095s | 1.8x |
| strings   | 0.044s | 0.031s | 0.7x |

### GC bug found by stress mode (2026-11-02), for the record
During a call, `stack_top` covers only the callee's window, which can end below the caller's dead
temporaries. Objects those temporaries pointed at were freed, and the stale pointers came back into
the scanned range when the callee returned. The GC then set mark bits in freed memory.
- Fix: scan every live frame's full window (`mark_roots`), and clear the result slot below frames
  that `Vm.call`, `construct` and `run_script` push.
- Debug aids kept for next time:
  - `--gc-stress` poisons freed blocks with 0xEE.
  - In safe builds, `mark_ptr` asserts it never reaches a freed block, and `verify_heap` checks
    invariants after each stress collection.
- `gdb -batch -ex run -ex bt --args ./build/fjs --gc-stress x.js` then shows the path. ASan can't
  link here: `/usr/lib64/libasan.so.8` isn't installed.

### Phase 6: built-ins (mostly done)
- [x] Symbols (`src/rt/symbol.c3`): `Symbol()`, `Symbol.iterator`/`asyncIterator`, `description`.
      Symbol keys come after string keys, as in the spec.
- [x] Iterator protocol (`get_iterator`/`iter_next`/`iter_close` in `symbol.c3`).
  - Arrays, strings and typed arrays take a fast path.
  - Built-in iterator objects (`JsIterator`) step without allocating result objects.
  - FORNEXT, ITERSTEP, ITERREST and APPENDSPREAD use it.
- [x] Map/Set (`src/rt/collections.c3`): insertion-ordered with SameValueZero keys. Deleted
      entries keep their slot, so live iterators keep their place.
- [x] Typed arrays and ArrayBuffer (`src/rt/typed.c3`).
  - All 9 kinds with JS conversion rules; views share a buffer.
  - `subarray/slice/set/fill/map/filter` plus borrowed generic Array methods.
  - Buffer bytes count toward GC pressure.
  - GETELEM/SETELEM have typed-array fast paths.
- [x] `src/rt/lib.c3` covers:
  - Object: `values/entries/assign/freeze/isFrozen/defineProperty(ies)/getOwnPropertyDescriptor/getOwnPropertyNames/create/setPrototypeOf/fromEntries/is/hasOwn`
  - Array: the full set, generic over array-likes, with a stable merge sort
  - String: the full set except regex-backed matching
  - Number: `isFinite/isNaN/isSafeInteger/parseInt/parseFloat`, `toString(radix)`, and the constants
  - Math: everything
  - JSON: `stringify` with indent, `toJSON` and a replacer function; strict `parse`
  - Function: `call/apply/bind` (bound functions are natives with `native_data`)
  - Reflect: `construct/has/ownKeys`
  - `Date.now`, `performance.now`
- [x] RegExp (`src/rt/regexp.c3`).
  - Engine: an ECMAScript backtracking matcher on UTF-16 units with an explicit stack.
    - Syntax: groups (capturing, `(?:)`, named `(?<n>)`), lookahead `(?=)`/`(?!)`, greedy and
      lazy quantifiers including `{n,m}`, classes, `\d\w\s\b`, backreferences.
    - Flags: `g i m s y` (`u` only for advancing past surrogate pairs).
    - Guards: a PROGRESS check stops empty loops, and a step budget raises RangeError instead of
      hanging.
  - Compiled programs are cached per (pattern, flags) atom in `Vm.regex_cache`. Literals are
    validated at compile time.
  - API: `exec/test/lastIndex/toString`, flag getters, and the String methods
    `match/matchAll/replace(All)/split/search` with regex patterns.
  - **Why not `std::encoding::regex`:** it's POSIX ERE (leftmost-longest), so `/a|ab/` on "ab"
    would give "ab" where JS gives "a". It also lacks `(?:)`, lookahead, lazy quantifiers and
    named groups, and works on UTF-8 bytes while JS indices are UTF-16 units. The user suggested
    it; checked 2026-11-02 and rejected for those reasons.
  - Missing: lookbehind, `\p{...}`, case folding beyond Latin-1/Greek/Cyrillic.
- [ ] Not done yet:
  - Proxy: dropped by design; edit the two prelude uses
  - JSON.parse reviver, Array.prototype.copyWithin
  - Full Unicode case mapping: Latin-1, Greek and Cyrillic only for now
  - String.raw and tagged templates

### Phase 7: coroutines (done)
- [x] **Coroutines** (`src/rt/coro.c3`). A generator or async call is a `JsCoroutine` (ObjectKind
      COROUTINE).
  - While it runs, its registers are an ordinary frame on the VM stack (`Frame.coroutine` points
    back at it).
  - When it suspends, the register window is copied into the coroutine. `Vm.resume` copies it
    back as a `stop` frame and runs it from native code.
  - Windows are small (≤ 250 registers, usually under 30), so copying beats per-coroutine stacks
    in simplicity, and is cheap enough.
  - The plan's "segmented stacks" idea is dropped.
- [x] Ops:
  - `GENSTART`: after parameter setup, suspend and return the generator. Defaults run at the
    call, as in the spec.
  - `ASYNCSTART`: pc 0 of an async function; creates the promise, so a failing parameter default
    rejects it.
  - `YIELD a b c`: the resume value goes to r[a] and the mode to r[b]. Codegen turns mode 2
    (`return()`) into a normal `return` through the finally machinery; the VM throws `throw()`
    at the yield.
  - `AWAIT a`: suspends and leaves like a `return` (via `nextcase RET`), handing the caller the
    promise.
  - `YSTEP`: one `yield*` step. `GETITER` with c=1 wraps the array fast path into a real
    iterator.
- [x] `RET` in a coroutine frame finishes it; an async function resolves its promise and returns
      that.
  - `unwind` turns an exception leaving an async frame into a rejection, then returns
    `HANDLED`/`RETURNED`.
- [x] Promise (`JsPromise`, ObjectKind PROMISE) with spec job ordering. `async.js` matches node's
      microtask order exactly, including thenables (+2 ticks) and returning a promise from an
      async function.
  - `then/catch/finally`
  - `resolve/reject/all/allSettled/any/race/withResolvers`
  - `queueMicrotask`
  - `await` of a non-object skips the promise allocation.
- [x] Job queue:
  - `Vm.run_job()` runs one job and returns false when the queue is empty. A
    `queueMicrotask` callback that throws returns THROWN.
  - `Vm.jobs_waiting()` reports whether any are pending.
  - `Vm.take_unhandled()` hands back unhandled rejections; `fjs` reports them as
    "Uncaught (in promise)".
  - Jobs from `job_head` onward, and `current_job`, are GC roots. The queue compacts itself
    during long drains.
- [x] GC:
  - `native_generator_resume` doesn't count toward `native_depth`, so generator bodies can
    collect.
  - A job runs with `native_depth == 0`, so async bodies collect too.
  - Coroutines trace their saved registers, and promises trace their reactions.
- [x] Iterator closing:
  - `break` or `return` out of for-of calls `return()` on the iterator (`JumpCtx.closes_iterator`).
  - Array destructuring closes an iterator it didn't exhaust (ITERSTEP clears r[a] when done).
- [x] inspect prints:
  - `Promise { 1 }`, `Promise { <pending> }`, `Promise { <rejected> x }`
  - `Object [Generator] {}`
  - `[AsyncFunction: f]`, `[GeneratorFunction: g]`
- Not done:
  - async generators and `for await` (three.c3 uses neither)
  - closing the iterator when a for-of body throws
  - per-function `g.prototype` objects: generator objects inherit `%GeneratorPrototype%` directly
  - Promise subclassing / species
- Perf idea: resume generators inside the interpreter loop (FORNEXT pushes the frame, YIELD
  returns like RET) instead of a nested `execute()` per step.

### Phase 8: modules and the embedding API (mostly done)
- [x] **ES modules.** Files:
  - `src/rt/module.c3`: records, linking, evaluation
  - `src/compile/module.c3`: compiling a module and loading its graph
  - `Resolver.resolve_module`, `Codegen.compile_module`
- [x] How modules compile:
  - Every top-level binding of a module, imports included, lives in a scope above the module
    function, so every use of one is a capture.
  - Linking gives each module a box per binding. An import *is* the exporter's box, so bindings
    are live and import cycles link fine. (The prelude has three cycles:
    asset↔layers↔api, scene↔physics.)
  - Hoisted function declarations are compiled as nested protos (`ModuleRecord.hoisted`) and
    created at link time, before any body runs. A cycle can therefore call them early, as in
    the spec.
  - The module body is an async function, so top-level await works.
  - `evaluate_module` runs imports depth-first and skips modules still on the evaluation stack
    (cycles). A module waits on imports that are still awaiting at top level
    (`Vm.combine(ALL, …)`).
  - Without TLA, the evaluation promise comes back already settled.
- [x] Supported forms:
  - imports: named, `as`, default, `* as ns` (a namespace with live getters), side-effect
  - exports: declarations, `export {a as b}`, `export default` expressions, functions and
    classes, `export {x} from`, `export * from`
  - Not supported: `export * as ns`.
- [x] Loading:
  - Through `ModuleHooks` (normalize, load), the same shape as quickjs.c3's.
  - Without a normalize hook, a specifier is a path relative to the importer.
  - Hook failures give "cannot import 'x' from 'y'"; a missing export gives V8's "does not
    provide an export named".
- [x] `fjs file.mjs` / `fjs --module file.js`. `test/js/modules.mjs` (with `test/js/mod/`) matches
      node on cycles, TLA, live bindings, namespaces and re-exports.
- [x] **The whole three.c3 prelude (25 modules) evaluates.**
  - Test setup: host verbs stubbed by a generated `host_stub.js`; the files were copied to the
    scratchpad and math.js was changed to import the stub.
  - The `three` object has the same 153 members node sees.
  - It needed `DataView`, now in `typed.c3`.
- [x] **`src/api/qjs.c3`, module `fastjs::qjs`:** the quickjs.c3 API call for call, so three.c3
      switches by changing `import qjs;` to `import fastjs::qjs;`.
  - `qjs::Value` is a distinct `ulong` typedef over the NaN-boxed value, whose `tag()` answers
    in quickjs's tag numbering.
  - An owned value is an entry in `Vm.roots`, which `release` removes (searching from the end;
    releases are mostly LIFO). Non-heap values cost nothing.
  - Ownership-taking calls (`set_property`, `set_index`, `accessor`, a host function's `out`)
    drop the host's root.
  - Host functions run through `host_trampoline`, with `JsFunction.host_fn` and `host_opaque`.
    They receive their arguments as a pointer straight into the VM stack, with no copy.
  - `raise` returns the `EXCEPTION` marker. `exception()` gives "Name: message\n    at …"
    without repeating the header.
  - `eval(EVAL_GLOBAL)` returns the script's last expression statement, so the async IIFE
    wrapper hands back its promise.
  - `on_interrupt`: polled every 10k backward jumps or calls; it throws an uncatchable
    "interrupted" error (`Vm.uncatchable` makes unwind skip handlers).
  - Also implemented:
    - `buffer` (external memory)
    - `detach`: walks the heap to empty the views
    - `freeze`: `JsArrayBuffer.immutable`, checked by SETELEM, `set` and `fill`
  - `src/api/modules.c3` is quickjs.c3's `ModuleLoader`, ported unchanged (`faultdef` →
    `excuse`).
  - `test/api_test.c3`: 8 tests using the API the way three.c3 does (host functions, raise,
    async IIFE with job draining, handles across GC, typed arrays, interrupt, embedded modules).
- [ ] Not done:
  - the new API (atoms, native classes with opaque data, `keys`, `view`, promise state, typed
    fast host calls, `gc_step`)
  - an incremental GC
  - the memory limit is only what `Heap.init` already enforces

### Status of three.c3 scripts (compile only, `fjs --dump`)
- All 12 examples compile (2026-11-02).
- The prelude needs ES modules (phase 8).

### Phases 5–9
See **Phases** above. Break each one down when it starts.

### Design decisions log
- 2026-11-02: The lexer is zero-copy. String and template tokens keep their raw slices plus an
  `escaped` flag; cooking (escape decoding) happens in the compiler, which knows the target string
  representation.
- 2026-11-02: Regex vs division is decided by the parser, not the lexer. The lexer always emits
  `SLASH`/`SLASH_ASSIGN`, and the parser calls `rescan_regex(tok)` in prefix position. Each token
  carries the `LexState` at its start, so the rescan can rewind. `tools/lexcheck` uses a
  previous-token heuristic instead, because it has no parser.
- 2026-11-02: Contextual words (`let static get set async await of from as yield`) lex as `IDENT`. The
  parser checks their text. Dropped keywords (`var with do debugger`) are still lexed as keywords,
  so the parser can say "not supported in this dialect".
- 2026-11-02: The parser keeps one current token and peeks by snapshotting `LexState`. There is no
  token buffer, so a regex rescan or a rewind is always safe.
- 2026-11-02: An arrow function is parsed as a primary expression. Callers stop applying suffixes and
  operators to a bare (unparenthesized) arrow, which is why `x => {}(1)` isn't a call.
- 2026-11-02: `a?.b.c` becomes OPTIONAL_CHAIN(MEMBER(MEMBER(a, b, optional), c)). The wrapper is
  where a short-circuit lands.
- 2026-11-02: `{ a = 1 }` in an object literal is counted while parsing and uncounted when it becomes
  a pattern. A count above zero at the end is a syntax error.
- 2026-11-02: Number literals are converted in the lexer with `String.to_double`, which is musl's
  correctly rounded decfloat. `_` separators are stripped first, and BigInt (`1n`) is rejected.

### Log
- 2026-11-02: Plan written; repo created.
- 2026-11-02: Lexer done.
  - `c3c test`: 15 tests pass.
  - `lexcheck` lexes all 64 three.c3 scripts (1.2 MB, 165k tokens) with no errors, finding the 7
    regex literals the census predicted. It runs in 3.4 ms at `-O3 --safe=no`, about 360 MB/s.
- 2026-11-02: Parser done.
  - All 64 three.c3 scripts parse, and print → reparse → print gives identical text.
  - `node --check` accepts all 41 printed example, prelude and fixture files, so the printed output
    is valid JS.
  - Parse plus print of 1.2 MB takes 8.6 ms at `-O3`.
  - `c3c test`: 28 tests pass, with leak checking on.
- 2026-11-02: Runtime core started, in module `fastjs::rt` under `src/rt/`.
  - `value.c3`: NaN-boxing. `rt::number(d)` stores an exact int32 as an int.
  - `heap.c3`: allocation list, per-kind finalizers, the atom table.
  - `string.c3`: Latin-1 or UTF-16 strings kept canonical; cooking; concat and substring;
    Number::toString via snprintf's shortest round-trip; StringToNumber.
  - `object.c3`: shapes, objects, dense arrays, accessors.
    - `delete` and attribute changes rebuild the shape chain (`JsObject.reshape`) instead of
      switching to a dictionary mode.
    - The prototype lives in the shape (each proto has its own root, `child_root`).
  - `c3c test`: 39 tests pass. `format_number` is checked against node for 80 doubles, including
    random bit patterns.
  - Atoms are never collected yet; revisit once the GC exists.
  - **Next:** 3d–3g, the resolver, bytecode, compiler and VM, aiming for `console.log(1 + 2)` end to end.

- 2026-11-02: Phase 3 core VM working end to end.
  - `test/js/run.sh`: 10 files match node's output exactly.
  - `c3c test`: 39 tests pass.
  - Benchmarks (table above): already 1.0–2.5× QuickJS except strings.
  - **Next:** phase 4, classes, which three.c3 uses everywhere. Then 3h, the GC.

- 2026-11-02: Phase 4 (classes, object rest) and 3h (GC) done.
  - `c3c test`: 43 tests pass, including VM/GC tests in `test/vm_test.c3`.
  - `test/js/run.sh`: 11 files pass, also under `--gc-stress`.
  - Benchmarks vs QuickJS: closures 2.1×, fib 2.2×, loop 2.0×, methods 1.3×, particles 0.84×,
    strings 0.66×.
  - **Next:** phase 5, inline caches. Particles is the game workload and the one benchmark where
    we trail.

- 2026-11-02: Phase 5 partly done: ICs, fused branches, K-arithmetic, statement-level updates.
  - We now beat QuickJS on every benchmark except string building (table above).
  - **Next:** the three.c3 critical path, in this order:
    1. Built-ins breadth (phase 6): Map/Set/Symbol/iterators, TypedArrays, JSON,
       Object.defineProperty and friends, Array/String methods.
    2. Regex (editor.js).
    3. Generators and async/await (phase 7).
    4. Modules and the qjs-compatible embedding API (phase 8).

- 2026-11-02: Phase 6 built-ins done except RegExp.
  - `test/js/run.sh`: 14 files pass, also under `--gc-stress`.
  - **Next:** the regex engine, then generators and async/await (phase 7), then modules and the
    qjs-compatible embedding API (phase 8).
- 2026-11-02: RegExp done.
  - `test/js/run.sh`: 15 files pass, also under `--gc-stress`. `c3c test`: 43 pass.
  - All 12 three.c3 examples compile.
  - **Next:** phase 7 (generators, Promise, async/await, the job queue), then phase 8 (ES modules
    for the prelude, the qjs-compatible API, then switching three.c3 over).

- 2026-11-02: Phase 7 done: generators (with `yield*`, return/throw, finally), async/await,
  Promise and the job queue.
  - `test/js/run.sh`: 17 files pass (new: generators, async), also under `--gc-stress`.
    `c3c test`: 43 pass.
  - New benchmarks:
    - `bench/async.js`: 3.5× QuickJS
    - `bench/generators.js`: 1.5×
    - `qjsrun` now drains jobs and reads `__result`.
  - **Next:** phase 8. ES modules for the prelude, then the qjs-compatible API (`src/api.c3`),
    then switching three.c3 over.

- 2026-11-02: Phase 8 core done: ES modules and the qjs-compatible API.
  - `test/js/run.sh`: 18 files pass (normal and `--gc-stress`). `c3c test`: 51 pass.
  - The three.c3 prelude evaluates as modules, also under `--gc-stress`.
  - **Next:**
    - phase 9: build three.c3 against fastjs (swap `import qjs`) and run its examples headless
    - then the new API, and V8-style "x.y is not a function" messages, which three.c3's agent
      workflow benefits from

**How to run things:**
```sh
c3c build fjs && test/js/run.sh                      # differential tests against node's output
test/js/regen.sh                                    # after adding a test: regenerate .out files with node
./build/fjs --dump file.js                          # see the bytecode
./build/fjs --module main.js                        # run as an ES module (.mjs files always are)
c3c build fjs -O3 --safe=no && bench/run.sh         # benchmarks vs QuickJS (build bench/qjsrun first)
```

**How to check the parser:**
```sh
c3c test
c3c build parsecheck && ./build/parsecheck ../three.c3/examples/*.js ../three.c3/src/js/prelude/*.js
./build/parsecheck --print file.js      # see how a file parsed
```

**How to check the lexer:**
```sh
c3c test
c3c build lexcheck && T=../three.c3 && ./build/lexcheck $T/examples/*.js $T/src/js/prelude/*.js
```

**C3 gotchas hit so far:**
- `@private` is ignored on methods.
- A contract must fit on one line.
- `break` inside a `switch` leaves only the switch, so use a labeled loop.
- `return (void)opt;` silently drops the fault. Return a `fault` and rethrow it with `return f()~;`.
- An `inline` struct member must be the first field.
- `List.len()` and slice `.len` are signed `sz`. Mixing them with `uint`/`usz` needs explicit casts.
- Type properties use `::`: `double::nan`, `double::inf`, `int::max`, `Foo::size`.
- There is no comma operator.
- `char[*] data;` at the end of a struct is a flexible array member. Copy into it with `mem::copy`.
- libc's `snprintf` works through `extern fn CInt snprintf(char*, usz, ZString, ...) @cname("snprintf");`.
- `module`, `import`, `function` and `class` can't be used as field or method names.
- `fn ... => @pool() { ... };` doesn't parse. Put `@pool() { ... };` inside a normal body.
- A `Splitter` can't be iterated with `foreach`; use `while (try x = it.next())`.
- In a `switch`, the `case` bodies are their own scopes, so declaring locals there is fine.
- `%` works on doubles (fmod). There's no `math::fmod`.
- `x ?? FAULT~` is still optional: write `x ?? FAULT~!` to unwrap or return.
- `@clone_slice(s)` copies a slice to the heap. There's no `.copy` on non-string slices.
- `mem::tnew(T)` allocates in temp memory. `foreach` indexes are signed `sz`.
