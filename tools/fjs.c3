// Run a script:   fjs file.js
// Show bytecode:  fjs --dump file.js
// GC torture:     fjs --gc-stress file.js   (collects at every safe point)
// Modules:       fjs file.mjs, or fjs --module file.js   (imports resolve relative to the importer)
module fjs;
import std::io, std::os::env, std::core::dstring, fastjs::rt, fastjs::compile;

char[] module_buffer;

fn char* load_from_disk(ZString name, usz* len, void* opaque)
{
	char[]? data = file::load(mem, name.str_view());
	if (catch data) return null;
	if (module_buffer.len) free(module_buffer);
	module_buffer = data;
	*len = data.len;
	return data.ptr;
}

fn int main(String[] args)
{
	bool dump;
	bool stress;
	bool as_module;
	usz first = 1;
	for (; first < args.len && args[first].starts_with("--"); first++)
	{
		switch (args[first])
		{
			case "--dump": dump = true;
			case "--gc-stress": stress = true;
			case "--module": as_module = true;
			default:
				io::eprintfn("fjs: unknown option %s", args[first]);
				return 2;
		}
	}
	String[] files = args[first..];
	if (files.len == 0)
	{
		io::eprintn("usage: fjs [--dump] [--gc-stress] [--module] <file.js>...");
		return 2;
	}
	usz limit = 0;
	if (try mb = env::tget_var("FASTJS_LIMIT_MB")) limit = (usz)(mb.to_int() ?? 0) * 1024 * 1024;
	Vm vm;
	if (catch vm.init(limit))
	{
		io::eprintn("fjs: out of memory");
		return 1;
	}
	defer vm.free();
	if (stress)
	{
		vm.gc_stress = true;
		vm.heap.threshold = 0;
	}
	// Modules load from disk, relative to the importer: for a module's imports, and for
	// import() in a script as much as in a module.
	ModuleHooks hooks = { .load = &load_from_disk };
	vm.module_hooks = &hooks;
	foreach (path : files)
	{
		char[]? data = file::load(mem, path);
		if (catch err = data)
		{
			io::eprintfn("%s: cannot read (%s)", path, err);
			return 1;
		}
		defer free(data);
		if (as_module || path.ends_with(".mjs"))
		{
			if (!run_module(&vm, (String)data, path)) return 1;
			continue;
		}
		CompileError err;
		Script*? script = compile::compile_script(&vm, (String)data, path, &err);
		if (catch script)
		{
			io::eprintfn("%s:%d:%d: SyntaxError: %s", path, err.line, err.col, err.message);
			return 1;
		}
		if (dump)
		{
			script.main.dump();
			continue;
		}
		if (catch vm.run_script(script))
		{
			report(&vm, "Uncaught ", vm.exception);
			return 1;
		}
		if (!drain(&vm)) return 1;
	}
	if (module_buffer.len) free(module_buffer);
	return 0;
}

fn bool run_module(Vm* vm, String source, String path)
{
	Value? promise = compile::eval_module(vm, source, path);
	if (catch promise)
	{
		report(vm, "Uncaught ", vm.exception);
		return false;
	}
	return drain(vm);
}

<*
 Run the microtasks, as node does after the script, then report a rejection nobody handled.
*>
fn bool drain(Vm* vm)
{
	while (true)
	{
		bool? more = vm.run_job();
		if (catch more)
		{
			report(vm, "Uncaught ", vm.exception);
			return false;
		}
		if (!more) break;
	}
	Value reason;
	if (vm.take_unhandled(&reason))
	{
		report(vm, "Uncaught (in promise) ", reason);
		return false;
	}
	return true;
}

fn void report(Vm* vm, String prefix, Value error)
{
	@pool()
	{
		DString out;
		out.tinit();
		out.append(prefix);
		if (catch vm.inspect(error, &out, 0, false)) out.append("<exception while printing the exception>");
		io::eprintn(out.str_view());
	};
}
