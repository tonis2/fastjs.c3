module api_test;
import std::io, std::math, fastjs::qjs;

// The qjs-compatible embedding API, used the way three.c3 uses quickjs.c3.

fn void test_eval_and_values() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	Value v = js.eval("const a = 20; a * 2 + 2", "<test>")!!;
	defer js.release(v);
	test::eq(js.number(v), 42.0);
	test::eq(v.tag(), qjs::TAG_INT);
	Value s = js.eval("'h' + 'i' + 1.5")!!;
	defer js.release(s);
	String text = js.text(s);
	defer free(text);
	test::eq(text, "hi1.5");
	test::eq(s.tag(), qjs::TAG_STRING);
	Value o = js.eval("({ x: [1, 2, 3], y: 'z' })")!!;
	defer js.release(o);
	test::eq(o.tag(), qjs::TAG_OBJECT);
	String json = js.json(o);
	defer free(json);
	test::eq(json, `{"x":[1,2,3],"y":"z"}`);
	Value xs = js.property(o, "x");
	defer js.release(xs);
	test::eq(js.length(xs), 3);
	Value second = js.index(xs, 1);
	test::eq(js.number(second), 2.0);
	assert(js.truth(o));
	assert(qjs::undefined_value().is_undefined());
}

fn void test_exception_text() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	if (try js.eval("function boom() { throw new TypeError('bad thing'); }\nboom();", "file.js")) assert(false, "should throw");
	String message = js.exception();
	defer free(message);
	assert(message.starts_with("TypeError: bad thing"), "got %s", message);
	assert(message.contains("file.js:1"), "no stack in %s", message);
	String none = js.exception();
	defer free(none);
	test::eq(none, "");
	if (try js.eval("let = ;", "bad.js")) assert(false, "should not compile");
	String syntax = js.exception();
	defer free(syntax);
	assert(syntax.starts_with("SyntaxError"), "got %s", syntax);
}

fn void add(ContextRef ctx, Value* this_val, int argc, Value* args, void* opaque, Value* out)
{
	Context js = qjs::wrap(ctx);
	if (argc < 2)
	{
		*out = js.raise("add wants two numbers");
		return;
	}
	*(int*)opaque += 1;
	*out = qjs::number_value(js.number(args[0]) + js.number(args[1]));
}

fn void make_point(ContextRef ctx, Value* this_val, int argc, Value* args, void* opaque, Value* out)
{
	Context js = qjs::wrap(ctx);
	Value p = js.object();
	js.set_property(p, "x", qjs::int_value(3));
	js.set_property(p, "label", js.string("pt"));
	*out = p;
}

fn void test_host_functions() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	int calls;
	Value global = js.global();
	defer js.release(global);
	js.set_property(global, "add", js.function(&add, "add", 2, &calls));
	js.set_property(global, "point", js.function(&make_point, "point", 0));
	Value r = js.eval("let s = 0; for (let i = 0; i < 100; i++) s = add(s, i); s")!!;
	test::eq(js.number(r), 4950.0);
	test::eq(calls, 100);
	Value msg = js.eval("(() => { try { add(1) } catch (e) { return e.message + '|' + (e instanceof Error) } })()")!!;
	defer js.release(msg);
	String text = js.text(msg);
	defer free(text);
	test::eq(text, "add wants two numbers|true");
	Value p = js.eval("const p = point(); p.x * 2 + p.label")!!;
	defer js.release(p);
	String ptext = js.text(p);
	defer free(ptext);
	test::eq(ptext, "6pt");
	Value f = js.property(global, "add");
	defer js.release(f);
	assert(js.is_function(f));
	Value[2] args = { qjs::int_value(2), qjs::number_value(0.5) };
	Value sum = js.call(f, qjs::undefined_value(), &args)!!;
	test::eq(js.number(sum), 2.5);
}

fn void settle(ContextRef ctx, Value* this_val, int argc, Value* args, void* opaque, Value* out)
{
	Context js = qjs::wrap(ctx);
	String* into = opaque;
	*into = js.text(args[0]);
}

fn void test_async_and_jobs() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	// three.c3 wraps every script in an async IIFE and drains jobs until it settles.
	Value promise = js.eval("(async()=>{ await null; const v = await Promise.resolve(41); return v + 1; })()")!!;
	defer js.release(promise);
	String result;
	defer free(result);
	Value then = js.property(promise, "then");
	defer js.release(then);
	Value on_ok = js.function(&settle, "resolve", 1, &result);
	defer js.release(on_ok);
	Value[1] handlers = { on_ok };
	Value attached = js.call(then, promise, &handlers)!!;
	js.release(attached);
	int steps;
	while (js.jobs_waiting())
	{
		js.step_job();
		steps++;
	}
	test::eq(result, "42");
	assert(steps > 0);
}

fn void test_handles_survive_collection() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	Value keep = js.eval("({ name: 'kept', list: [1, 2, 3].map(x => ({ x })) })")!!;
	js.eval("for (let i = 0; i < 20000; i++) ({ junk: [i, String(i)] })")!!;
	js.collect();
	String json = js.json(keep);
	defer free(json);
	test::eq(json, `{"name":"kept","list":[{"x":1},{"x":2},{"x":3}]}`);
	js.release(keep);
	js.collect();
}

fn void test_typed_arrays() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	float[4] data = { 1, 2, 3, 4 };
	Value buffer = js.buffer_copy((char*)&data, float::size * 4);
	defer js.release(buffer);
	Value view = js.typed_array(qjs::ARRAY_FLOAT32, buffer, 1, 3);
	defer js.release(view);
	Value global = js.global();
	defer js.release(global);
	js.set_property(global, "view", js.retain(view));
	Value sum = js.eval("view[0] = 10; view.reduce((a, b) => a + b, 0)")!!;
	test::eq(js.number(sum), 17.0);
	char[] bytes = js.bytes(view);
	test::eq(bytes.len, 12);
	test::eq(((float*)bytes.ptr)[0], 10.0f);
	Value made = js.eval("new Uint8Array([7, 8, 9]).subarray(1)")!!;
	defer js.release(made);
	char[] raw = js.bytes(made);
	test::eq(raw.len, 2);
	test::eq(raw[0], 8);
}

fn int stop_now(Runtime rt, void* opaque)
{
	*(int*)opaque += 1;
	return 1;
}

fn void test_interrupt() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	int asked;
	js.on_interrupt(&stop_now, &asked);
	if (try js.eval("try { while (true) {} } catch (e) { 'caught' }")) assert(false, "should be stopped");
	String message = js.exception();
	defer free(message);
	assert(message.starts_with("Error: interrupted"), "got %s", message);
	test::eq(asked, 1);
	js.on_interrupt(null);
	Value ok = js.eval("1 + 1")!!;
	test::eq(js.number(ok), 2.0);
}

const EmbeddedModule[3] PARTS = {
	{ "app:main.js", `import { greet } from './lib/greet.js'; import { N } from './lib/n.js'; globalThis.out = greet('world') + N;` },
	{ "app:lib/greet.js", `import { N } from './n.js'; export function greet(who) { return 'hello ' + who + ' ' + N; }` },
	{ "app:lib/n.js", `export const N = 7;` },
};

fn void test_modules() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	ModuleLoader modules;
	defer modules.free();
	modules.set_embedded("app:", &PARTS);
	modules.install(js);
	Value done = js.eval((String)PARTS[0].source, "app:main.js", qjs::EVAL_MODULE)!!;
	defer js.release(done);
	while (js.jobs_waiting()) js.step_job();
	Value out = js.eval("out")!!;
	defer js.release(out);
	String text = js.text(out);
	defer free(text);
	test::eq(text, "hello world 77");
	// Script code can't reach into the embedded space.
	if (try js.eval("import { N } from 'app:lib/n.js';", "game.js", qjs::EVAL_MODULE)) assert(false, "should be refused");
	String refused = js.exception();
	defer free(refused);
	assert(refused.contains("cannot import"), "got %s", refused);
}

fn void test_memory_limit() @test
{
	Context js = qjs::open(4 * 1024 * 1024)!!;
	defer js.close();
	// Several times the limit in garbage: collections must come before the limit does.
	Value ok = js.eval("let keep = null; for (let i = 0; i < 60000; i++) keep = { a: [i, i + 1, i + 2], s: 'x' + i, m: new Map([[i, i]]) }; keep.a[2]")!!;
	test::eq(js.number(ok), 60001.0);
	// Keeping everything does run out, as a catchable RangeError.
	Value caught = js.eval("(() => { const big = []; try { for (;;) big.push({ s: 'y' + big.length, xs: [1, 2, 3] }); } catch (e) { const n = big.length; big.length = 0; return e.name + ': ' + e.message + ' ' + (n > 1000); } })()")!!;
	defer js.release(caught);
	String text = js.text(caught);
	defer free(text);
	test::eq(text, "RangeError: Out of memory true");
	// And the engine still works afterwards.
	Value again = js.eval("let n = 0; for (let i = 0; i < 20000; i++) n += [i].length; n")!!;
	test::eq(js.number(again), 20000.0);
	if (try js.eval("new ArrayBuffer(64 * 1024 * 1024)")) assert(false, "should not fit");
	String message = js.exception();
	defer free(message);
	assert(message.starts_with("RangeError"), "got %s", message);
}

fn double hypot2(void* opaque, double* args, int argc) => math::sqrt(args[0] * args[0] + args[1] * args[1]);

fn double count_call(void* opaque, double* args, int argc)
{
	*(int*)opaque += argc;
	return 0;
}

fn double is_positive(void* opaque, double* args, int argc) => args[0] > 0 ? 1 : 0;

fn double refuse(void* opaque, double* args, int argc)
{
	Context js = qjs::wrap(opaque);
	js.raise("refused");
	return 0;
}

fn void test_number_functions() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	int counted;
	Value global = js.global();
	defer js.release(global);
	js.set_property(global, "hyp", js.number_function(&hypot2, "hyp", 2));
	js.set_property(global, "count", js.number_function(&count_call, "count", 0, &counted, UNDEFINED));
	js.set_property(global, "positive", js.number_function(&is_positive, "positive", 1, null, BOOL));
	js.set_property(global, "refuse", js.number_function(&refuse, "refuse", 0, js.ctx));
	Value r = js.eval("[hyp(3, 4), hyp('6', { valueOf() { return 8 } }), Number.isNaN(hyp(3)), count(1, 2, 3), positive(2), positive(-1), hyp.name, hyp.length].join()")!!;
	defer js.release(r);
	String text = js.text(r);
	defer free(text);
	test::eq(text, "5,10,true,,true,false,hyp,2");
	test::eq(counted, 3);
	Value caught = js.eval("(() => { try { refuse(); return 'no' } catch (e) { return e.message } })()")!!;
	defer js.release(caught);
	String message = js.text(caught);
	defer free(message);
	test::eq(message, "refused");
	// A raise in a fast function doesn't leak into the next call.
	Value ok = js.eval("hyp(0, 1)")!!;
	test::eq(js.number(ok), 1.0);
	Value sum = js.eval("let s = 0; for (let i = 0; i < 1000; i++) s += hyp(i, 0); s")!!;
	test::eq(js.number(sum), 499500.0);
}

struct Point
{
	double x;
	double y;
}

fn double point_length(void* opaque, void* self_data, double* args, int argc)
{
	Point* p = self_data;
	return math::sqrt(p.x * p.x + p.y * p.y);
}

fn double point_scale(void* opaque, void* self_data, double* args, int argc)
{
	Point* p = self_data;
	p.x *= args[0];
	p.y *= args[0];
	return 0;
}

fn void free_point(void* data, void* opaque)
{
	*(int*)opaque += 1;
}

fn void test_native_classes() @test
{
	int freed;
	Point[3] points = { { 3, 4 }, { 6, 8 }, { 1, 0 } };
	{
		Context js = qjs::open()!!;
		defer js.close();
		ClassId cls = js.native_class("Point", &free_point, &freed);
		assert(js.number_method(cls, "length", &point_length, 0));
		assert(js.number_method(cls, "scale", &point_scale, 1, null, UNDEFINED));
		Value global = js.global();
		defer js.release(global);
		Value a = js.native_object(cls, &points[0]);
		test::eq((Point*)js.opaque(a, cls), &points[0]);
		js.set_property(global, "a", a);
		js.set_property(global, "b", js.native_object(cls, &points[1]));
		Value r = js.eval("a.scale(2); [a.length(), b.length(), a instanceof Object, typeof a.scale, Object.getPrototypeOf(a) === Object.getPrototypeOf(b)].join()")!!;
		defer js.release(r);
		String text = js.text(r);
		defer free(text);
		test::eq(text, "10,10,true,function,true");
		test::eq(points[0].x, 6.0);
		Value bad = js.eval("(() => { try { a.length.call({}) } catch (e) { return e.constructor.name + ': ' + e.message } })()")!!;
		defer js.release(bad);
		String message = js.text(bad);
		defer free(message);
		test::eq(message, "TypeError: Point.length called on an object that is not a live Point");
		// An unreachable instance is finalized by a collection.
		Value temp = js.native_object(cls, &points[2]);
		js.release(temp);
		js.eval("for (let i = 0; i < 1000; i++) ({ i })")!!;
		js.collect();
		js.collect();
		test::eq(freed, 1);
		// Clearing the data makes methods throw and skips the finalizer.
		Value b = js.eval("b")!!;
		assert(js.set_opaque(b, cls, null));
		js.release(b);
		if (try js.eval("b.length()")) assert(false, "should throw");
		String gone = js.exception();
		defer free(gone);
		assert(gone.starts_with("TypeError"), "got %s", gone);
	}
	// Closing finalizes the rest: a, but not b, whose data was cleared.
	test::eq(freed, 2);
}

fn void test_atoms_keys_views() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	Value o = js.eval("({ x: 1.5, name: 'n', on: true, 0: 'zero', nested: { y: 2 } })")!!;
	defer js.release(o);
	Atom x = js.atom("x");
	Atom on = js.atom("on");
	Atom zero = js.atom("0");
	Atom missing = js.atom("missing");
	test::eq(js.get_number(o, x), 1.5);
	test::eq(js.get_number(o, missing, -1), -1.0);
	test::eq(js.get_number(o, on, -1), -1.0);
	assert(js.get_bool(o, on));
	assert(!js.get_bool(o, missing));
	Value z = js.get(o, zero);
	defer js.release(z);
	String zt = js.text(z);
	defer free(zt);
	test::eq(zt, "zero");
	assert(js.set(o, x, qjs::int_value(7)));
	test::eq(js.get_number(o, x), 7.0);
	Value keys = js.keys(o);
	defer js.release(keys);
	String kj = js.json(keys);
	defer free(kj);
	test::eq(kj, `["0","x","name","on","nested"]`);

	Value f = js.eval("new Float32Array([1, 2, 3, 4]).subarray(1, 3)")!!;
	defer js.release(f);
	View v = js.view(f)!!;
	test::eq(v.kind, qjs::ARRAY_FLOAT32);
	test::eq(v.len, (usz)2);
	test::eq(v.byte_len, (usz)8);
	test::eq(((float*)v.ptr)[1], 3.0f);
	Value buf = js.eval("new ArrayBuffer(16)")!!;
	defer js.release(buf);
	View bv = js.view(buf)!!;
	test::eq(bv.kind, qjs::VIEW_BUFFER);
	test::eq(bv.len, (usz)16);
	Value dv = js.eval("new DataView(new ArrayBuffer(8), 2)")!!;
	defer js.release(dv);
	test::eq(js.view(dv)!!.kind, qjs::VIEW_DATA);
	test::eq(js.view(dv)!!.len, (usz)6);
	if (try js.view(o)) assert(false, "not a view");
	js.detach(buf);
	if (try js.view(buf)) assert(false, "detached");
}

fn void test_promise_state_and_async_eval() @test
{
	Context js = qjs::open()!!;
	defer js.close();
	Value done = js.eval("Promise.resolve(5)")!!;
	defer js.release(done);
	Value failed = js.eval("Promise.reject(new Error('nope'))")!!;
	defer js.release(failed);
	Value pending = js.eval("new Promise(() => {})")!!;
	defer js.release(pending);
	assert(js.promise_state(done) == FULFILLED);
	assert(js.promise_state(failed) == REJECTED);
	assert(js.promise_state(pending) == PENDING);
	assert(js.promise_state(qjs::int_value(1)) == NOT_A_PROMISE);
	test::eq(js.number(js.promise_result(done)), 5.0);
	Value reason = js.promise_result(failed);
	defer js.release(reason);
	Value message = js.property(reason, "message");
	defer js.release(message);
	String text = js.text(message);
	defer free(text);
	test::eq(text, "nope");
	assert(js.promise_result(pending).is_undefined());
	// Reading the rejection handled it.
	ulong unused;
	assert(!js.vm().take_unhandled((void*)&unused));

	// Async scripts: await and return at top level, declarations stay local.
	for (int i = 0; i < 2; i++)
	{
		Value p = js.eval("const a = 40;\nawait null;\nreturn a + 2;", "async.js", qjs::EVAL_ASYNC)!!;
		defer js.release(p);
		assert(js.promise_state(p) == PENDING);
		while (js.jobs_waiting()) js.step_job();
		assert(js.promise_state(p) == FULFILLED);
		test::eq(js.number(js.promise_result(p)), 42.0);
	}
	Value thrown = js.eval("await 1;\n\nthrow new Error('late');", "late.js", qjs::EVAL_ASYNC)!!;
	defer js.release(thrown);
	while (js.jobs_waiting()) js.step_job();
	assert(js.promise_state(thrown) == REJECTED);
	Value err = js.promise_result(thrown);
	defer js.release(err);
	Value stack = js.property(err, "stack");
	defer js.release(stack);
	String st = js.text(stack);
	defer free(st);
	assert(st.contains("late.js:3"), "got %s", st);
	if (try js.eval("let = ;", "bad.js", qjs::EVAL_ASYNC)) assert(false, "should not compile");
	String syntax = js.exception();
	defer free(syntax);
	assert(syntax.contains("bad.js:1:"), "got %s", syntax);
}
