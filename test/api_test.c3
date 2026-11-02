module api_test;
import std::io, fastjs::qjs;

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
