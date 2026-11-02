module api_test;
import std::io, std::math, fastjs::js, fastjs::js::opt;

// The embedding API, used the way three.c3 uses it.

fn String text_of(Engine* js, String source)
{
	Value v = js.eval(source)!!;
	return js.text(v, tmem);
}

fn void test_eval_and_values() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Value v = js.eval("const a = 20; a * 2 + 2", "<test>")!!;
	test::eq(js.number(v)!!, 42.0);
	assert(v.is_int());
	test::eq(text_of(js, "'h' + 'i' + 1.5"), "hi1.5");
	Value o = js.eval("({ x: [1, 2, 3], y: 'z' })")!!;
	String json = js.json(o, tmem);
	test::eq(json, `{"x":[1,2,3],"y":"z"}`);
	Value xs = js.get(o, "x")!!;
	test::eq(js.length(xs)!!, 3);
	test::eq(js.number(js.get(xs, 1)!!)!!, 2.0);
	assert(js.truth(o));
	Key y = js.key("y")!!;
	test::eq(js.text(js.get(o, y)!!, tmem), "z");
	js.set(o, y, js::integer(9))!!;
	js.set(xs, 5, js::number(0.5))!!;
	test::eq(js.json(o, tmem), `{"x":[1,2,3,null,null,0.5],"y":9}`);
	assert(js.has(o, "x")!!);
	assert(!js.has(o, "nope")!!);
	Value made = js.object()!!;
	js.set(made, "list", js.numbers({ 1, 2.5 })!!)!!;
	js.set(made, "name", js.string("é")!!)!!;
	test::eq(js.json(made, tmem), `{"list":[1,2.5],"name":"é"}`);
	Value parsed = js.from_json(`{"a":[true,null]}`)!!;
	test::eq(js.json(js.get(parsed, "a")!!, tmem), "[true,null]");
}

fn void test_exception_text() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	if (try js.eval("function boom() { throw new TypeError('bad thing'); }\nboom();", "file.js")) assert(false, "should throw");
	assert(js.has_error());
	String message = js.take_error(tmem);
	assert(message.starts_with("TypeError: bad thing"), "got %s", message);
	assert(message.contains("file.js:1"), "no stack in %s", message);
	test::eq(js.take_error(tmem), "");
	if (try js.eval("let = ;", "bad.js")) assert(false, "should not compile");
	String syntax = js.take_error(tmem);
	assert(syntax.starts_with("SyntaxError"), "got %s", syntax);
}

// ---- typed host functions ----

struct Counter
{
	int calls;
	double last;
}

fn double add(Counter* c, double a, double b)
{
	c.calls++;
	return a + b;
}

fn int? checked(int n)
{
	if (n < 0) return js::THREW~;
	return n * 2;
}

fn int? strict(Call* c, int n)
{
	if (n < 0) return c.fail("negative: %d", n)~;
	return n * 2;
}

fn String greet(String who, Opt {String} greeting) => string::tformat("%s, %s", greeting.or("hello"), who);

fn bool flags(bool a, Opt {bool} b) => a && b.or(true);

fn void store(Counter* c, float x) { c.last = x; }

fn float sum(float[] xs)
{
	float s;
	foreach (x : xs) s += x;
	return s;
}

fn long count_bytes(char[] data) => data.len;

fn Value? point(Engine* js, int x)
{
	Value p = js.object()!;
	js.set(p, "x", js::integer(x))!;
	js.set(p, "label", js.string("pt")!)!;
	return p;
}

fn Value first(Value v) => v;

fn double many(double a, double b, double c, double d, double e, double f, double g, double h, double i, double j, double k, double l, double m, double n, double o, double p, double q, double r, double s, double t, double u)
{
	return a + u * 1000;
}

// A converter defined by the host, as three.c3 does for its vectors.
struct Vec2
{
	float x;
	float y;
}

fn void? Vec2.from_js(&self, Call* c, int at)
{
	Value v = c.get(at);
	if (!v.is_object()) return c.type_error(at, "an {x, y}")~;
	self.x = (float)c.js.get_number(v, "x")!;
	self.y = (float)c.js.get_number(v, "y")!;
}

fn Value? Vec2.to_js(&self, Engine* js) => js.numbers({ self.x, self.y });

fn Vec2 swap(Vec2 v) => { v.y, v.x };

fn void test_typed_functions() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Counter counter;
	Value g = js.global();
	js.@bind(g, "add", &add, &counter)!!;
	js.@bind(g, "checked", &checked)!!;
	js.@bind(g, "strict", &strict)!!;
	js.@bind(g, "greet", &greet)!!;
	js.@bind(g, "flags", &flags)!!;
	js.@bind(g, "store", &store, &counter)!!;
	js.@bind(g, "sum", &sum)!!;
	js.@bind(g, "count", &count_bytes)!!;
	js.@bind(g, "point", &point)!!;
	js.@bind(g, "first", &first)!!;
	js.@bind(g, "many", &many)!!;
	js.@bind(g, "swap", &swap)!!;

	Value r = js.eval("let s = 0; for (let i = 0; i < 100; i++) s = add(s, i); s")!!;
	test::eq(js.number(r)!!, 4950.0);
	test::eq(counter.calls, 100);
	test::eq(text_of(js, "[add.name, add.length, greet.length, point.length, many.length].join()"), "add,2,2,1,21");
	test::eq(text_of(js, "[add(1), add('2', { valueOf() { return 3 } }), checked(4), checked(2.9), checked(NaN)].join()"), "1,5,8,4,0");
	test::eq(text_of(js, "(() => { try { strict(-3) } catch (e) { return e.constructor.name + ': ' + e.message } })()"), "Error: negative: -3");
	test::eq(text_of(js, "[greet('you'), greet('you', 'hi'), greet('you', undefined), greet(42)].join('|')"), "hello, you|hi, you|hello, you|hello, 42");
	test::eq(text_of(js, "[flags(true), flags(true, false), flags(false, true), flags(1, 0)].join()"), "true,false,false,false");
	js.eval("store(2.5)")!!;
	test::eq(counter.last, 2.5);
	test::eq(text_of(js, "[sum(new Float32Array([1, 2, 3.5])), sum(new Float32Array([1, 2, 3, 4]).subarray(2)), sum()].join()"), "6.5,7,0");
	test::eq(text_of(js, "(() => { try { sum([1, 2]) } catch (e) { return e.constructor.name + ': ' + e.message } })()"), "TypeError: sum: argument 1 must be a Float32Array, not object");
	test::eq(text_of(js, "[count(new Uint16Array(3)), count(new ArrayBuffer(5)), count(new DataView(new ArrayBuffer(8), 2))].join()"), "6,5,6");
	test::eq(text_of(js, "const p = point(3); p.x * 2 + p.label"), "6pt");
	test::eq(text_of(js, "first('same') + (first() === undefined)"), "sametrue");
	test::eq(text_of(js, "many(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)"), "2001");
	test::eq(text_of(js, "swap({ x: 1, y: 2 }).join()"), "2,1");
	test::eq(text_of(js, "(() => { try { swap(3) } catch (e) { return e.message } })()"), "swap: argument 1 must be an {x, y}, not 3");
	// A failing conversion throws what the argument's own valueOf threw.
	test::eq(text_of(js, "(() => { try { add({ valueOf() { throw new RangeError('no') } }) } catch (e) { return e.constructor.name } })()"), "RangeError");

	// The raw form.
	Value f = js.function(fn Value?(Call* c) => js::integer((int)c.args.len), "argc", 0)!!;
	js.set(g, "argc", f)!!;
	test::eq(text_of(js, "argc(1, 2, 3)"), "3");
	Value[2] args = { js::integer(2), js::number(0.5) };
	Value total = js.call(js.get(g, "add")!!, js::UNDEFINED, &args)!!;
	test::eq(js.number(total)!!, 2.5);
}

fn void test_async_and_jobs() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Value promise = js.eval("(async()=>{ await null; const v = await Promise.resolve(41); return v + 1; })()")!!;
	Root held = js.hold(promise);
	defer js.drop(&held);
	int steps;
	while (js.jobs_waiting())
	{
		js.step_job()!!;
		steps++;
	}
	assert(js::promise_state(js.held(held)) == FULFILLED);
	test::eq(js.number(js.promise_result(js.held(held)))!!, 42.0);
	assert(steps > 0);
}

fn void test_roots_survive_collection() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Root keep = js.hold(js.eval("({ name: 'kept', list: [1, 2, 3].map(x => ({ x })) })")!!);
	Root other = js.hold(js.eval("[1]")!!);
	js.drop(&other);
	test::eq(other, js::NO_ROOT);
	// The freed slot is reused.
	Root again = js.hold(js.eval("'again'")!!);
	test::eq(again, (Root)2);
	js.eval("for (let i = 0; i < 20000; i++) ({ junk: [i, String(i)] })")!!;
	js.collect();
	test::eq(js.json(js.held(keep), tmem), `{"name":"kept","list":[{"x":1},{"x":2},{"x":3}]}`);
	test::eq(js.text(js.held(again), tmem), "again");
	js.rehold(&again, js::integer(5));
	test::eq(js.number(js.held(again))!!, 5.0);
	js.drop(&keep);
	js.drop(&again);
	js.drop(&again);
	js.collect();
}

fn void test_typed_arrays() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	float[4] data = { 1, 2, 3, 4 };
	Value buffer = js.buffer_copy(((char*)&data)[:float::size * 4])!!;
	Value view = js.typed_array(FLOAT32, buffer, 1, 3)!!;
	js.set(js.global(), "view", view)!!;
	test::eq(text_of(js, "view[0] = 10; view.reduce((a, b) => a + b, 0)"), "17");
	char[] bytes = js::bytes(js.eval("view")!!);
	test::eq(bytes.len, 12);
	test::eq(((float*)bytes.ptr)[0], 10.0f);
	char[] raw = js::bytes(js.eval("new Uint8Array([7, 8, 9]).subarray(1)")!!);
	test::eq(raw.len, 2);
	test::eq(raw[0], 8);
	Value copy = js.typed_copy(UINT8, { 5, 6 })!!;
	test::eq(js.json(copy, tmem), `{"0":5,"1":6}`);
	char[3] outside = { 1, 2, 3 };
	Value ext = js.buffer(&outside, 3)!!;
	assert(js::freeze(ext));
	js.set(js.global(), "ext", ext)!!;
	test::eq(text_of(js, "const u = new Uint8Array(ext); u[0] = 9; u.join()"), "1,2,3");
	js.detach(ext);
	test::eq(text_of(js, "u.length + ',' + ext.byteLength"), "0,0");
}

fn int stop_now(void* engine, void* opaque)
{
	*(int*)opaque += 1;
	return 1;
}

fn void test_interrupt() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	int asked;
	js.on_interrupt(&stop_now, &asked);
	if (try js.eval("try { while (true) {} } catch (e) { 'caught' }")) assert(false, "should be stopped");
	String message = js.take_error(tmem);
	assert(message.starts_with("Error: interrupted"), "got %s", message);
	test::eq(asked, 1);
	js.on_interrupt(null);
	test::eq(text_of(js, "1 + 1"), "2");
}

const EmbeddedModule[3] PARTS = {
	{ "app:main.js", `import { greet } from './lib/greet.js'; import { N } from './lib/n.js'; globalThis.out = greet('world') + N;` },
	{ "app:lib/greet.js", `import { N } from './n.js'; export function greet(who) { return 'hello ' + who + ' ' + N; }` },
	{ "app:lib/n.js", `export const N = 7;` },
};

fn void test_modules() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	ModuleLoader modules;
	defer modules.free();
	modules.set_embedded("app:", &PARTS);
	modules.install(js);
	js.eval((String)PARTS[0].source, "app:main.js", MODULE)!!;
	while (js.jobs_waiting()) js.step_job()!!;
	test::eq(text_of(js, "out"), "hello world 77");
	// Script code can't reach into the embedded space.
	if (try js.eval("import { N } from 'app:lib/n.js';", "game.js", MODULE)) assert(false, "should be refused");
	String refused = js.take_error(tmem);
	assert(refused.contains("cannot import"), "got %s", refused);
}

fn void test_memory_limit() @test
{
	Engine* js = js::open(4 * 1024 * 1024)!!;
	defer js.close();
	// Several times the limit in garbage: collections must come before the limit does.
	test::eq(text_of(js, "let keep = null; for (let i = 0; i < 60000; i++) keep = { a: [i, i + 1, i + 2], s: 'x' + i, m: new Map([[i, i]]) }; keep.a[2]"), "60001");
	// Keeping everything does run out, as a catchable RangeError.
	test::eq(text_of(js, "(() => { const big = []; try { for (;;) big.push({ s: 'y' + big.length, xs: [1, 2, 3] }); } catch (e) { const n = big.length; big.length = 0; return e.name + ': ' + e.message + ' ' + (n > 1000); } })()"), "RangeError: Out of memory true");
	test::eq(text_of(js, "let n = 0; for (let i = 0; i < 20000; i++) n += [i].length; n"), "20000");
	if (try js.eval("new ArrayBuffer(64 * 1024 * 1024)")) assert(false, "should not fit");
	String message = js.take_error(tmem);
	assert(message.starts_with("RangeError"), "got %s", message);
}

// ---- host classes ----

struct Point
{
	double x;
	double y;
}

fn double point_length(Point* p) => math::sqrt(p.x * p.x + p.y * p.y);

fn void point_scale(Point* p, double by)
{
	p.x *= by;
	p.y *= by;
}

fn double point_x(Point* p) => p.x;

NativeClass* point_class;


fn void free_point(void* data, void* opaque)
{
	*(int*)opaque += 1;
}

// A host type as a parameter: a pointer read from an instance of its class.
struct PointRef
{
	Point* p;
}

fn void? PointRef.from_js(&self, Call* c, int at)
{
	self.p = js::data_of(c.get(at), point_class);
	if (!self.p) return c.type_error(at, "a live Point")~;
}

fn double ref_length(PointRef r) => point_length(r.p);
fn void ref_scale(PointRef r, double by) => point_scale(r.p, by);
fn double ref_x(PointRef r) => r.p.x;
fn double distance(PointRef a, PointRef b) => math::sqrt((a.p.x - b.p.x) * (a.p.x - b.p.x) + (a.p.y - b.p.y) * (a.p.y - b.p.y));

fn void test_native_classes() @test
{
	int freed;
	Point[3] points = { { 3, 4 }, { 6, 8 }, { 1, 0 } };
	{
		Engine* js = js::open()!!;
		defer js.close();
		point_class = js.class("Point", &free_point, &freed)!!;
		js.@method(point_class, "length", &ref_length)!!;
		js.@method(point_class, "scale", &ref_scale)!!;
		js.@getter(point_class, "x", &ref_x)!!;
		Value g = js.global();
		js.@bind(g, "distance", &distance)!!;
		Value a = js.instance(point_class, &points[0])!!;
		test::eq((Point*)js::data_of(a, point_class), &points[0]);
		js.set(g, "a", a)!!;
		js.set(g, "b", js.instance(point_class, &points[1])!!)!!;
		test::eq(text_of(js, "a.scale(2); [a.length(), b.length(), a.x, a instanceof Object, typeof a.scale, a.scale.length, Object.getPrototypeOf(a) === Object.getPrototypeOf(b), distance(a, b)].join()"), "10,10,6,true,function,1,true,0");
		test::eq(points[0].x, 6.0);
		test::eq(text_of(js, "(() => { try { a.length.call({}) } catch (e) { return e.constructor.name + ': ' + e.message } })()"), "TypeError: length: the receiver must be a live Point, not object");
		test::eq(text_of(js, "(() => { try { distance(a, 5) } catch (e) { return e.message } })()"), "distance: argument 2 must be a live Point, not 5");
		// An unreachable instance is finalized by a collection.
		js.instance(point_class, &points[2])!!;
		js.eval("for (let i = 0; i < 1000; i++) ({ i })")!!;
		js.collect();
		js.collect();
		test::eq(freed, 1);
		// Clearing the data makes methods throw and skips the finalizer.
		assert(js::set_data(js.eval("b")!!, point_class, null));
		if (try js.eval("b.length()")) assert(false, "should throw");
		assert(js.take_error(tmem).starts_with("TypeError"));
	}
	// Closing finalizes the rest: a, but not b, whose data was cleared.
	test::eq(freed, 2);
}

fn void test_keys_and_views() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Value o = js.eval("({ x: 1.5, name: 'n', on: true, 0: 'zero', nested: { y: 2 } })")!!;
	test::eq(js.get_number(o, "x")!!, 1.5);
	test::eq(js.get_number(o, "missing", -1)!!, -1.0);
	test::eq(js.text(js.get(o, "0")!!, tmem), "zero");
	test::eq(js.text(js.get(o, 0)!!, tmem), "zero");
	@pool()
	{
		DString seen;
		seen.tinit();
		js.@each(o; String name, Value v)
		{
			seen.appendf("%s=%s;", name, js.type_of(v));
		}!!;
		test::eq(seen.str_view(), "0=string;x=number;name=string;on=boolean;nested=object;");
		Key[] keys = js.keys(js.eval("new Proxy({ a: 1, b: 2 }, { ownKeys: () => ['b', 'a'], getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }) })")!!)!!;
		test::eq(keys.len, 2);
		test::eq(js.key_text(keys[0]), "b");
	};

	View v = js::view(js.eval("new Float32Array([1, 2, 3, 4]).subarray(1, 3)")!!)!!;
	test::eq(v.kind, ViewKind.FLOAT32);
	test::eq(v.len, (usz)2);
	test::eq(v.byte_len, (usz)8);
	test::eq(((float*)v.ptr)[1], 3.0f);
	Value buf = js.eval("new ArrayBuffer(16)")!!;
	test::eq(js::view(buf)!!.kind, ViewKind.BUFFER);
	test::eq(js::view(buf)!!.len, (usz)16);
	View dv = js::view(js.eval("new DataView(new ArrayBuffer(8), 2)")!!)!!;
	test::eq(dv.kind, ViewKind.DATA_VIEW);
	test::eq(dv.len, (usz)6);
	if (try js::view(o)) assert(false, "not a view");
	js.detach(buf);
	if (try js::view(buf)) assert(false, "detached");
}

fn void test_promise_state_and_async_eval() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Value done = js.eval("globalThis.done = Promise.resolve(5)")!!;
	Value failed = js.eval("globalThis.failed = Promise.reject(new Error('nope'))")!!;
	Value pending = js.eval("new Promise(() => {})")!!;
	assert(js::promise_state(done) == FULFILLED);
	assert(js::promise_state(failed) == REJECTED);
	assert(js::promise_state(pending) == PENDING);
	assert(js::promise_state(js::integer(1)) == NOT_A_PROMISE);
	test::eq(js.number(js.promise_result(done))!!, 5.0);
	Value reason = js.promise_result(failed);
	test::eq(js.text(js.get(reason, "message")!!, tmem), "nope");
	assert(js.promise_result(pending).is_undefined());
	// Reading the rejection handled it.
	Value unused;
	assert(!js.vm.take_unhandled(&unused));

	// Async scripts: await and return at top level, declarations stay local.
	for (int i = 0; i < 2; i++)
	{
		Root p = js.hold(js.eval("const a = 40;\nawait null;\nreturn a + 2;", "async.js", ASYNC)!!);
		defer js.drop(&p);
		assert(js::promise_state(js.held(p)) == PENDING);
		while (js.jobs_waiting()) js.step_job()!!;
		assert(js::promise_state(js.held(p)) == FULFILLED);
		test::eq(js.number(js.promise_result(js.held(p)))!!, 42.0);
	}
	Root thrown = js.hold(js.eval("await 1;\n\nthrow new Error('late');", "late.js", ASYNC)!!);
	defer js.drop(&thrown);
	while (js.jobs_waiting()) js.step_job()!!;
	assert(js::promise_state(js.held(thrown)) == REJECTED);
	String st = js.error_text(js.promise_result(js.held(thrown)), tmem);
	assert(st.starts_with("Error: late"), "got %s", st);
	assert(st.contains("late.js:3"), "got %s", st);
	if (try js.eval("let = ;", "bad.js", ASYNC)) assert(false, "should not compile");
	String syntax = js.take_error(tmem);
	assert(syntax.contains("bad.js:1:"), "got %s", syntax);
}

fn void test_gc_step() @test
{
	Engine* js = js::open()!!;
	defer js.close();
	Root keep = js.hold(js.eval("globalThis.keep = []; for (let i = 0; i < 3000; i++) keep.push({ i, s: 'k' + i }); keep")!!);
	defer js.drop(&keep);
	// Garbage up to near the threshold, then let idle-time steps do the collecting.
	for (int frame = 0; frame < 40; frame++)
	{
		js.eval("for (let i = 0; i < 2000; i++) ({ junk: [i, i] })")!!;
		js.gc_step(2000);
	}
	test::eq(js.length(js.held(keep))!!, 3000);
	test::eq(text_of(js, "keep[2999].s"), "k2999");
	assert(js.vm.gc_count > 0, "gc_step never collected");
}
