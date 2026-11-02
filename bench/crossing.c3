module crossing;
import std::io, std::time, fastjs::js;

// What one C3<->JS crossing costs, for each way a host can expose a function. Each loop makes
// N calls of the form three.c3 uses (`H.verb(a, b)`); the empty loop is subtracted.

const int N = 10_000_000;

fn Value? raw_add(Call* c) => js::number(c.js.number(c.arg(0))! + c.js.number(c.arg(1))!);

fn double typed_add(double a, double b) => a + b;

fn double thing_get(Thing t, double by) => *t.data + by;

NativeClass* thing_class;

struct Thing
{
	double* data;
}

fn void? Thing.from_js(&self, Call* c, int at)
{
	self.data = js::data_of(c.get(at), thing_class);
	if (!self.data) return c.type_error(at, "a Thing")~;
}

fn double time_ms(Engine* js, String source)
{
	Clock started = clock::now();
	js.eval(source)!!;
	return (long)started.to_now() / 1e6;
}

fn void main()
{
	Engine* js = js::open()!!;
	defer js.close();
	Value h = js.object()!!;
	js.set(h, "raw", js.function(&raw_add, "raw", 2)!!)!!;
	js.@bind(h, "typed", &typed_add)!!;
	double data = 1;
	thing_class = js.class("Thing")!!;
	js.@method(thing_class, "get", &thing_get)!!;
	js.set(h, "thing", js.instance(thing_class, &data)!!)!!;
	js.set(js.global(), "H", h)!!;
	js.eval("H.js = (a, b) => a + b; globalThis.N = " +++ "10000000")!!;
	double empty = time_ms(js, "{ let s = 0; for (let i = 0; i < N; i++) s += i; s }");
	io::printfn("%-34s %6.1f ns/iteration", "empty loop", empty * 1e6 / N);
	foreach (c : (String[2][6]){
		{ "local const f = H.typed; f(i, 1)", "{ const f = H.typed; let s = 0; for (let i = 0; i < N; i++) s += f(i, 1); s }" },
		{ "local const f = H.js; f(i, 1)", "{ const f = H.js; let s = 0; for (let i = 0; i < N; i++) s += f(i, 1); s }" },
		{ "JS arrow H.js(i, 1)", "{ let s = 0; for (let i = 0; i < N; i++) s += H.js(i, 1); s }" },
		{ "raw HostFn H.raw(i, 1)", "{ let s = 0; for (let i = 0; i < N; i++) s += H.raw(i, 1); s }" },
		{ "@bind H.typed(i, 1)", "{ let s = 0; for (let i = 0; i < N; i++) s += H.typed(i, 1); s }" },
		{ "@method t.get(i)", "{ const t = H.thing; let s = 0; for (let i = 0; i < N; i++) s += t.get(i); s }" },
	})
	{
		double ms = time_ms(js, c[1]);
		io::printfn("%-34s %6.1f ns/call", c[0], (ms - empty) * 1e6 / N);
	}
}
