module fastjs::compile;
import std::core::mem::allocators, fastjs::ast, fastjs::parse, fastjs::rt;

struct CompileError
{
	String message;
	uint line;
	uint col;
	char[256] buf;
}

fn void CompileError.set(&self, String message, uint line, uint col)
{
	sz n = min(message.len, self.buf.len);
	self.buf[:n] = message[:n];
	self.message = (String)self.buf[:n];
	self.line = line;
	self.col = col;
}

<*
 Compile a script. The VM owns the result, which stays valid until the VM is freed.

 @param [&inout] vm : "The VM the script will run in"
 @param [&out] err : "Filled in when compiling fails"
 @param async_body : "Compile source as the body of an async function and call it: `await` and `return` work at top level, declarations stay local, and the script's value is the call's promise"
 @return? COMPILE_ERROR
*>
fn Script*? compile_script(Vm* vm, String source, String name, CompileError* err, bool async_body = false)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 64 * 1024);
	defer arena.free();

	// The wrapper sits on a line of its own, numbered 0, so positions in source stay exact.
	if (async_body) source = string::format(&arena, "(async () => {\n%s\n})()", source);
	Parser p;
	p.init(&arena, source, false, async_body ? 0 : 1);
	defer p.free();
	Node*? program = p.parse_program();
	if (catch program)
	{
		err.set(p.error, p.error_line, p.error_col);
		return COMPILE_ERROR~;
	}

	Resolver r = { .arena = &arena, .vm = vm };
	if (catch r.resolve_program(program))
	{
		err.set(r.error, r.error_line, r.error_col);
		return COMPILE_ERROR~;
	}

	Script* script = mem::new(Script);
	script.name = name.copy(mem);
	script.source = source.copy(mem);
	Codegen g = { .vm = vm, .arena = &arena, .source_name = script.name, .source_text = script.source };
	FunctionProto*? main = g.compile_program(program);
	if (catch main)
	{
		err.set(g.error, g.error_line, g.error_col);
		free(script.name);
		free(script.source);
		free(script);
		return COMPILE_ERROR~;
	}
	script.main = main;
	vm.scripts.push(script);
	return script;
}
