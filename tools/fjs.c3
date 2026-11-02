// Run a script:   fjs file.js
// Show bytecode:  fjs --dump file.js
// GC torture:     fjs --gc-stress file.js   (collects at every safe point)
module fjs;
import std::io, std::core::dstring, fastjs::rt, fastjs::compile;

fn int main(String[] args)
{
	bool dump = args.len > 1 && args[1] == "--dump";
	bool stress = args.len > 1 && args[1] == "--gc-stress";
	String[] files = dump || stress ? args[2..] : args[1..];
	if (files.len == 0)
	{
		io::eprintn("usage: fjs [--dump] <file.js>...");
		return 2;
	}
	Vm vm;
	if (catch vm.init())
	{
		io::eprintn("fjs: out of memory");
		return 1;
	}
	defer vm.free();
	if (stress)
	{
		vm.gc_stress = true;
		vm.gc_threshold = 0;
	}
	foreach (path : files)
	{
		char[]? data = file::load(mem, path);
		if (catch err = data)
		{
			io::eprintfn("%s: cannot read (%s)", path, err);
			return 1;
		}
		defer free(data);
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
		// Then the microtasks, as node runs them after the script.
		while (true)
		{
			bool? more = vm.run_job();
			if (catch more)
			{
				report(&vm, "Uncaught ", vm.exception);
				return 1;
			}
			if (!more) break;
		}
		Value reason;
		if (vm.take_unhandled(&reason))
		{
			report(&vm, "Uncaught (in promise) ", reason);
			return 1;
		}
	}
	return 0;
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
