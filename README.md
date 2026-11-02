# fastjs.c3

A small, fast JavaScript engine written in C3, made for embedding in C3 programs.

It runs the modern JS that game scripts use (classes with fields, accessors and static
members, `async`/`await`, generators, Promises, ES modules, destructuring, spread, template
literals, Map/Set, typed arrays, JSON, a RegExp subset), and leaves out the parts that make
an engine slow: `var`, `eval`, `with`, `arguments`, sloppy mode, holes in arrays, BigInt,
WeakMap. Everything is strict mode. `plan.md` lists exactly what is in and out.

## Install

Add it to your project as a C3 library. The usual way is a git submodule under `lib/`:

```sh
git submodule add -b master https://github.com/tonis2/fastjs.c3.git lib/fastjs.c3l
```

Then in your `project.json`:

```json
"dependency-search-paths": ["lib"],
"dependencies": ["fastjs"],
```

fastjs is pure C3 with no C dependencies, so there is nothing else to link.

## Run a script

```c3
import std::io, fastjs::js;

fn int main()
{
	Engine* js = js::open()!!;   // js::open(memory_limit) to cap the heap
	defer js.close();

	Value? v = js.eval("[1, 2, 3].map(x => x * 2).join(',')");
	if (catch v)
	{
		io::eprintn(js.take_error(tmem));   // message and stack trace
		return 1;
	}
	io::printn(js.text(v, tmem));            // "2,4,6"
	return 0;
}
```

`eval` takes a mode: `SCRIPT` (the default; the value is the last expression), `ASYNC`
(the source is the body of an async function, so top-level `await` and `return` work and
the value is a promise), or `MODULE` (an ES module).

Promise jobs run when you ask. A host with a frame loop runs them each frame:

```c3
while (js.jobs_waiting()) if (catch js.step_job()) io::eprintn(js.take_error(tmem));
js.gc_step(200);   // up to 200 µs of incremental GC in spare time
```

## Bind C3 functions

Write a plain typed C3 function and `@bind` generates the glue that converts arguments
and the result:

```c3
import fastjs::js, fastjs::js::opt;

struct Game { float gravity; int score; }

fn void add_score(Game* g, int points) => g.score += points;

fn float? jump(Game* g, Engine* js, float height, Opt {float} scale)
{
	if (height < 0) return js.fail("height must be positive")~;
	return height * scale.or(1.0f) / g.gravity;
}

fn void? install(Engine* js, Game* game)
{
	Value api = js.object()!;
	js.@bind(api, "addScore", &add_score, game)!;
	js.@bind(api, "jump", &jump, game)!;
	js.set(js.global(), "game", api)!;
}
```

```js
game.addScore(10);
const t = game.jump(2, 1.5);
```

The pointer given to `@bind` (`game` here) is passed to every parameter of that type and
takes no JS argument. Neither do `Engine*` and `Call*`. The rest are read from JS:

| C3 parameter | JS argument |
|---|---|
| `double`, `float`, integers | a number (missing or NaN is 0) |
| `bool` | truthiness |
| `String` | `String(v)`, in temp memory for the call |
| `Value` | the value as is |
| `float[]`, `double[]`, `int[]`, `uint[]`, `short[]`, `ushort[]` | a typed array of that type, read in place |
| `char[]` | the bytes of any typed array, DataView or ArrayBuffer |
| `float[<3>]` and other vectors | that many consecutive numbers |
| `Opt {T}` | a `T`, plus whether it was given |
| any `T` with `fn void? T.from_js(&self, Call* c, int at)` | whatever that reads |

Results go the other way: numbers, bools, strings, `Value`, vectors become arrays, a type
with `fn Value? T.to_js(&self, Engine* js)` uses it, and any other struct becomes an object
with camelCase keys. To throw, return `js.fail("…")~` (or `c.fail(…)~` from a `Call*`); an
empty optional result must have thrown.

When you need the arguments raw, use `js.function(&fn, "name", arity, host)` with a
`fn Value?(Call* c)`; read them with `c.arg(i)`, `c.given(i)` and `c.this`.

## Host objects

A `NativeClass` is a JS class whose instances carry a C3 pointer. Methods and getters bind
like functions; their first converted parameter reads `this`:

```c3
struct Enemy { float hp; }

NativeClass* enemy_class;

fn void? Enemy.from_js(&self, Call* c, int at)
{
	Enemy* e = js::data_of(c.get(at), enemy_class);
	if (!e) return c.type_error(at, "an Enemy")~;
	*self = *e;
}

fn float enemy_hp(Enemy e) => e.hp;

fn void free_enemy(void* data, void* opaque) => free(data);

fn void? setup(Engine* js)
{
	enemy_class = js.class("Enemy", finalizer: &free_enemy)!;   // finalizer is optional
	js.@getter(enemy_class, "hp", &enemy_hp)!;
	Value e = js.instance(enemy_class, mem::new(Enemy, { .hp = 100 }))!;
	js.set(js.global(), "boss", e)!;
}
```


## Values and the GC

A `Value` is an 8-byte word and is not owned. Inside a host function nothing is
collected, so every Value you see stays valid until it returns. Outside one, a Value in a
C3 variable is valid only until the next call that can run JS or collect (`eval`, `call`,
`step_job`, `gc_step`, `collect`). To keep one longer, hold it:

```c3
Root cb = js.hold(callback);      // keep alive
js.call(js.held(cb), js::UNDEFINED, { js::number(dt) })!;
js.drop(&cb);                     // let go
```

Useful calls: `get`/`set`/`has` take a `Key`, a `String` or an integer index (make a `Key`
once with `js.key("name")` for hot paths); `get_number`, `keys`, `@each`, `length`,
`string`, `object`, `array`, `numbers`, `json`/`from_json`, `promise_state`/`promise_result`.
For binary data, `js::view(v)` and `js::bytes(v)` give you a typed array's memory, and
`js.buffer(ptr, len)` wraps host memory in an ArrayBuffer without copying.

`Engine.user` is a free `void*` for your own state, handy in converters that only get the
engine (`(Game*)c.js.user`).

## Modules

`ModuleLoader` gives `import` a root directory it can't escape (`..` past the root is
refused):

```c3
ModuleLoader loader;   // must not move while the engine uses it
defer loader.free();
loader.set_root("scripts");
loader.install(js);

// scripts/main.js can now `import { x } from './util.js'`
Value promise = js.eval(source, "main.js", MODULE)!;
```

It can also serve modules from the binary: `loader.set_embedded("app:", table)` with
a table of `EmbeddedModule { name, source }` (`$embed` the files). That namespace is
closed: only modules already inside it can import from it, so evaluate your entry as
`app:main.js`. For an open namespace read from a directory, such as a plugin's
scripts, use `set_scheme("plugin:", dir)`. For other rules, install your own hooks
with `js.on_modules(&hooks)`.

## Develop

```sh
c3c build fjs              # the command-line runner
./build/fjs file.js        # run a script (.mjs or --module for a module)
./build/fjs --dump file.js # show bytecode
c3c test                   # unit tests
c3c build fjs -O3 --safe=no && bench/run.sh   # benchmarks against QuickJS
```

`plan.md` is the design document and progress log.
