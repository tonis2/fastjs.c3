module fastjs::vm_test;
import std::core::dstring, fastjs::rt, fastjs::compile;

<*
 Run src in vm and return what it printed, in temp memory.
*>
fn String run(Vm* vm, String src)
{
	DString out;
	out.tinit();
	vm.output = &out;
	defer vm.output = null;
	CompileError err;
	Script* script = compile::compile_script(vm, src, "<test>", &err) ?? null;
	if (!script) return string::tformat("SyntaxError: %s", err.message);
	if (catch vm.run_script(script))
	{
		DString msg;
		msg.tinit();
		(void)vm.inspect(vm.exception, &msg, 0, false);
		return string::tformat("Uncaught %s", msg.str_view());
	}
	return out.str_view().trim();
}

fn void garbage_is_collected() @test
{
	Vm vm;
	vm.init()!!;
	defer vm.free();
	@pool()
	{
		String out = run(&vm, `
			let keep = 0;
			for (let i = 0; i < 100000; i++) {
				const o = { a: i, b: [i, i + 1], s: "n" + i };
				keep += o.b[1] - o.a;
			}
			console.log(keep);
		`);
		test::eq(out, "100000");
	};
	test::gt(vm.gc_count, 0u);
	// Each iteration leaves ~200 bytes of garbage, about 20 MB in all; the heap must stay well below that.
	test::lt(vm.heap.bytes, 12u * 1024 * 1024);
}

fn void live_data_survives_collection() @test
{
	Vm vm;
	vm.init()!!;
	defer vm.free();
	vm.gc_stress = true;
	vm.gc_threshold = 0;
	@pool()
	{
		String out = run(&vm, `
			const objs = [];
			for (let i = 0; i < 2000; i++) objs.push({ id: i, name: "obj" + i, tags: [i % 3] });
			const counters = [];
			for (let i = 0; i < 50; i++) { let n = i; counters.push(() => n++); }
			for (let i = 0; i < 1000; i++) { const junk = { x: [1, 2, 3] }; }
			class Node { constructor(v, next) { this.v = v; this.next = next; } }
			let list = null;
			for (let i = 0; i < 500; i++) list = new Node(i, list);
			let sum = 0;
			for (const o of objs) sum += o.id + o.tags[0];
			let len = 0;
			for (let n = list; n; n = n.next) len++;
			console.log(sum, objs[1999].name, counters[49](), counters[49](), len);
		`);
		test::eq(out, "2000999 obj1999 49 50 500");
	};
	test::gt(vm.gc_count, 100u);
}

fn void scripts_share_top_level_bindings() @test
{
	Vm vm;
	vm.init()!!;
	defer vm.free();
	@pool()
	{
		test::eq(run(&vm, "let counter = 1; function bump() { return ++counter; }"), "");
		test::eq(run(&vm, "bump(); console.log(counter, bump())"), "2 3");
		// Re-running a script that declares the same names is allowed (hot reload).
		test::eq(run(&vm, "let counter = 10; console.log(counter)"), "10");
	};
}

fn void errors_have_stack_traces() @test
{
	Vm vm;
	vm.init()!!;
	defer vm.free();
	@pool()
	{
		String out = run(&vm, "function inner() { throw new TypeError('bad'); }\nfunction outer() { inner(); }\nouter();");
		test::@check(out.starts_with("Uncaught TypeError: bad"), "got %s", out);
		test::@check(out.contains("at inner (<test>:1)"), "got %s", out);
		test::@check(out.contains("at outer (<test>:2)"), "got %s", out);
	};
}
