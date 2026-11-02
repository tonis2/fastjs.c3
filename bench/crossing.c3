module crossing;
import std::io, std::time, fastjs::qjs;

// What one C3<->JS crossing costs, for each way a host can expose a function. Each loop makes
// N calls of the form three.c3 uses (`H.verb(a, b)`); the empty loop is subtracted.

const int N = 10_000_000;

fn void host_add(ContextRef ctx, Value* this_val, int argc, Value* args, void* opaque, Value* out)
{
	Context js = qjs::wrap(ctx);
	*out = qjs::number_value(js.number(args[0]) + js.number(args[1]));
}

fn double fast_add(void* opaque, double* args, int argc) => args[0] + args[1];

fn double method_get(void* opaque, void* self_data, double* args, int argc) => *(double*)self_data + args[0];

fn double time_ms(Context js, String source)
{
	Clock started = clock::now();
	Value v = js.eval(source)!!;
	js.release(v);
	return (long)started.to_now() / 1e6;
}

fn void main()
{
	Context js = qjs::open()!!;
	defer js.close();
	Value h = js.object();
	js.set_property(h, "host", js.function(&host_add, "host", 2));
	js.set_property(h, "fast", js.number_function(&fast_add, "fast", 2));
	double data = 1;
	ClassId cls = js.native_class("Thing");
	js.number_method(cls, "get", &method_get, 1);
	js.set_property(h, "thing", js.native_object(cls, &data));
	Value global = js.global();
	js.set_property(global, "H", h);
	js.release(global);
	js.eval("H.js = (a, b) => a + b; globalThis.N = " +++ "10000000")!!;
	double empty = time_ms(js, "{ let s = 0; for (let i = 0; i < N; i++) s += i; s }");
	io::printfn("%-34s %6.1f ns/iteration", "empty loop", empty * 1e6 / N);
	foreach (c : (String[2][7]){
		{ "local const f = H.fast; f(i, 1)", "{ const f = H.fast; let s = 0; for (let i = 0; i < N; i++) s += f(i, 1); s }" },
		{ "local const f = H.host; f(i, 1)", "{ const f = H.host; let s = 0; for (let i = 0; i < N; i++) s += f(i, 1); s }" },
		{ "local const f = H.js; f(i, 1)", "{ const f = H.js; let s = 0; for (let i = 0; i < N; i++) s += f(i, 1); s }" },
		{ "JS arrow H.js(i, 1)", "{ let s = 0; for (let i = 0; i < N; i++) s += H.js(i, 1); s }" },
		{ "host function H.host(i, 1)", "{ let s = 0; for (let i = 0; i < N; i++) s += H.host(i, 1); s }" },
		{ "number_function H.fast(i, 1)", "{ let s = 0; for (let i = 0; i < N; i++) s += H.fast(i, 1); s }" },
		{ "number_method t.get(i)", "{ const t = H.thing; let s = 0; for (let i = 0; i < N; i++) s += t.get(i); s }" },
	})
	{
		double ms = time_ms(js, c[1]);
		io::printfn("%-34s %6.1f ns/call", c[0], (ms - empty) * 1e6 / N);
	}
}
