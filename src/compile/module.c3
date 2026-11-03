module fastjs::compile;
import std::core::mem::allocators, std::collections::list, fastjs::ast, fastjs::parse, fastjs::rt;

const usz MAX_SPECIFIER = 4096;

<*
 Compile one module's source into a record (not yet loaded, linked or run).

 @return? COMPILE_ERROR
*>
fn ModuleRecord*? compile_module(Vm* vm, String source, String name, CompileError* err)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 64 * 1024);
	defer arena.free();

	Parser p;
	p.init(&arena, source, true);
	defer p.free();
	Node*? program = p.parse_program();
	if (catch program)
	{
		err.set(p.error, p.error_line, p.error_col);
		return COMPILE_ERROR~;
	}
	Resolver r = { .arena = &arena, .vm = vm, .is_module = true };
	if (catch r.resolve_module(program))
	{
		err.set(r.error, r.error_line, r.error_col);
		return COMPILE_ERROR~;
	}

	ModuleRecord* m = mem::new(ModuleRecord);
	m.name = name.copy(mem);
	m.source = source.copy(mem);
	m.namespace = rt::UNDEFINED;
	m.promise = rt::UNDEFINED;
	m.requests.init(mem);
	m.deps.init(mem);
	List {HoistedFunction} hoisted;
	hoisted.init(mem);
	defer hoisted.free();
	Codegen g = { .vm = vm, .arena = &arena, .source_name = m.name, .source_text = m.source };
	FunctionProto*? main = g.compile_module(program, &hoisted);
	if (catch main)
	{
		err.set(g.error, g.error_line, g.error_col);
		m.free();
		return COMPILE_ERROR~;
	}
	m.main = main;
	m.hoisted = @clone_slice(hoisted.array_view());

	FuncInfo* info = program.sema;
	m.cells = mem::new_array(ModuleCell, info.captures.len());
	foreach (i, b : info.captures)
	{
		if (!b.import_spec) continue;
		m.cells[i] = { .imported = true, .request = add_request(m, b.import_from.name), .import_name = b.import_spec.name.copy(mem) };
	}
	List {ModuleExport} exports;
	exports.init(mem);
	defer exports.free();
	List {uint} stars;
	stars.init(mem);
	defer stars.free();
	foreach (s : program.list)
	{
		switch (s.kind)
		{
			case IMPORT:
				// Side-effect imports still load and run the module.
				(void)add_request(m, s.name);
			case EXPORT:
				if (s.flags.delegate)
				{
					stars.push(add_request(m, s.name));
					continue;
				}
				if (s.a)
				{
					declared_names(s.a, info, &exports);
					continue;
				}
				foreach (spec : s.list)
				{
					if (s.name.len)
					{
						exports.push({ .name = spec.name.copy(mem), .indirect = true, .request = add_request(m, s.name), .import_name = spec.a.name.copy(mem) });
						continue;
					}
					Binding* b = spec.a.sema;
					uint cell = cell_of(info, b);
					// `import { x } from 'm'; export { x }` is an indirect export, as
					// `export { x } from 'm'` is. As a local one it would name this
					// module's box for the import, which linking fills in only when it
					// reaches this module: a module importing x from here, linked
					// first, would find no box and no export.
					if (m.cells[cell].imported)
					{
						exports.push({ .name = spec.name.copy(mem), .indirect = true, .request = m.cells[cell].request,
							.import_name = m.cells[cell].import_name.copy(mem) });
						continue;
					}
					exports.push({ .name = spec.name.copy(mem), .cell = cell });
				}
			case EXPORT_DEFAULT:
				Binding* b = s.a.flags.declaration ? (s.a.kind == CLASS ? (Binding*)s.a.d.sema : find_binding(info, s.a.name)) : (Binding*)s.sema;
				exports.push({ .name = "default".copy(mem), .cell = cell_of(info, b) });
			default:
				break;
		}
	}
	m.exports = @clone_slice(exports.array_view());
	m.star_exports = @clone_slice(stars.array_view());
	return m;
}

fn uint add_request(ModuleRecord* m, String specifier)
{
	foreach (i, r : m.requests)
	{
		if (r == specifier) return (uint)i;
	}
	m.requests.push(specifier.copy(mem));
	return (uint)m.requests.len() - 1;
}

fn uint cell_of(FuncInfo* info, Binding* b)
{
	foreach (i, c : info.captures)
	{
		if (c == b) return (uint)i;
	}
	unreachable("export of a binding outside the module scope");
}

fn Binding* find_binding(FuncInfo* info, String name)
{
	foreach (c : info.captures)
	{
		if (c.name == name) return c;
	}
	return null;
}

<*
 The names an exported declaration binds: `export const {a, b} = ...` exports a and b.
*>
fn void declared_names(Node* decl, FuncInfo* info, List {ModuleExport}* out)
{
	switch (decl.kind)
	{
		case VAR_DECL:
			foreach (d : decl.list) pattern_names(d.a, info, out);
		case FUNCTION:
			out.push({ .name = decl.name.copy(mem), .cell = cell_of(info, find_binding(info, decl.name)) });
		case CLASS:
			out.push({ .name = decl.name.copy(mem), .cell = cell_of(info, decl.d.sema) });
		default:
			break;
	}
}

fn void pattern_names(Node* p, FuncInfo* info, List {ModuleExport}* out)
{
	switch (p.kind)
	{
		case IDENT:
			out.push({ .name = p.name.copy(mem), .cell = cell_of(info, p.sema) });
		case ARRAY_PATTERN:
			foreach (el : p.list)
			{
				if (el.kind != HOLE) pattern_names(el, info, out);
			}
		case OBJECT_PATTERN:
			foreach (prop : p.list) pattern_names(prop.kind == REST ? prop.a : prop.b, info, out);
		case ASSIGN_PATTERN:
		case REST:
			pattern_names(p.a, info, out);
		default:
			break;
	}
}

// ---- loading a module graph ----

<*
 What an import means when the host installed no normalize hook: a path relative to the
 importing module, with `.` and `..` applied.
*>
fn String default_normalize(String base, String name, Allocator allocator)
{
	if (!name.starts_with("./") && !name.starts_with("../")) return name.copy(allocator);
	List {String} parts;
	parts.tinit();
	usz cut = 0;
	bool has_dir = false;
	foreach (i, c : base)
	{
		if (c == '/')
		{
			cut = (usz)i;
			has_dir = true;
		}
	}
	if (has_dir)
	{
		foreach (part : base[:cut].tsplit("/")) parts.push(part);
	}
	foreach (part : name.tsplit("/"))
	{
		if (part == "." || part.len == 0) continue;
		if (part == ".." && parts.len() && parts[^1] != "..")
		{
			(void)parts.pop();
			continue;
		}
		parts.push(part);
	}
	DString out;
	out.tinit();
	foreach (i, part : parts)
	{
		if (i > 0) out.append('/');
		out.append(part);
	}
	return out.str_view().copy(allocator);
}

<*
 Resolve `name` imported from module `base`.

 @return? rt::THROWN
*>
fn String? resolve_specifier(Vm* vm, String base, String name)
{
	ModuleHooks* hooks = vm.module_hooks;
	if (!hooks || !hooks.normalize) return default_normalize(base, name, tmem);
	char[MAX_SPECIFIER] buf;
	if (hooks.normalize(base.zstr_tcopy(), name.zstr_tcopy(), &buf, buf.len, hooks.opaque) != 0)
	{
		return vm.throw_error(REFERENCE_ERROR, "cannot import '%s' from '%s'", name, base)~;
	}
	return ((ZString)&buf).str_view().tcopy();
}

<*
 Compile a module and, recursively, everything it imports that isn't loaded yet.

 @return? rt::THROWN
*>
fn ModuleRecord*? load_module_source(Vm* vm, String source, String name)
{
	CompileError err;
	ModuleRecord*? m = compile_module(vm, source, name, &err);
	if (catch m)
	{
		return vm.throw_error(SYNTAX_ERROR, "%s (%s:%d:%d)", err.message, name, err.line, err.col)~;
	}
	vm.modules.push(m);
	foreach (request : m.requests)
	{
		@pool()
		{
			String resolved = resolve_specifier(vm, m.name, request)!;
			ModuleRecord* dep = vm.find_module(resolved);
			if (!dep) dep = load_module_file(vm, resolved)!;
			m.deps.push(dep);
		};
	}
	return m;
}

fn ModuleRecord*? load_module_file(Vm* vm, String name)
{
	ModuleHooks* hooks = vm.module_hooks;
	if (!hooks || !hooks.load) return vm.throw_error(REFERENCE_ERROR, "could not load module '%s'", name)~;
	usz len;
	char* bytes = hooks.load(name.zstr_tcopy(), &len, hooks.opaque);
	if (!bytes) return vm.throw_error(REFERENCE_ERROR, "could not load module '%s'", name)~;
	// The hook may reuse its buffer for the imports loaded below, so compile from a copy.
	String source = ((String)bytes[:len]).copy(mem);
	defer free(source);
	return load_module_source(vm, source, name);
}

<*
 Evaluate source as an ES module named `name`: load what it imports, link, and run. Returns a
 promise for the evaluation, already settled unless some module awaits at top level.

 @return? rt::THROWN
*>
fn Value? eval_module(Vm* vm, String source, String name)
{
	ModuleRecord* existing = vm.find_module(name);
	if (existing && existing.state != ModuleState.COMPILED) return existing.promise;
	ModuleRecord* m = load_module_source(vm, source, name)!;
	vm.link_module(m)!;
	return vm.evaluate_module(m);
}

<*
 `import(specifier)`, called from code in `base` (the name of the module or script the call
 is in): a promise for the module's namespace.

 The module is resolved, loaded and linked the way a static import is, against the same hooks,
 and its body starts before this returns, as an imported module's does. A module already loaded
 is not loaded or run again; the promise follows its first evaluation.

 Nothing the specifier or the module does throws here: one that does not resolve, load or link,
 and a body that throws, all reject the promise. Records loaded for an import that then failed
 are dropped again, so a later import of the same name starts clean rather than finding a
 module with half its imports.

 @return? rt::THROWN : "Out of memory, or an interrupt, which a script must not be able to catch"
*>
fn Value? dynamic_import(Vm* vm, Value specifier, String base)
{
	sz mark = vm.modules.len();
	ModuleRecord*? loaded = import_record(vm, specifier, base);
	if (catch loaded)
	{
		if (vm.uncatchable) return rt::THROWN~;
		drop_unlinked_since(vm, mark);
		JsPromise* failed = vm.new_promise()!;
		vm.reject_with_exception(failed);
		return rt::object_value(failed);
	}
	ModuleRecord* m = loaded;
	// Runs the body (and any import of it not yet run). The module's promise and namespace are
	// on its record, which the collector treats as a root, so nothing here needs holding.
	Value evaluated = vm.evaluate_module(m)!;
	Value ns = vm.module_namespace(m)!;
	JsPromise* result = vm.new_promise()!;
	JsFunction* answer = vm.new_native("", &native_import_answer, 1)!;
	answer.native_data = ns;
	vm.perform_then((JsPromise*)evaluated.as_object(), rt::object_value(answer), rt::UNDEFINED, rt::object_value(result));
	return rt::object_value(result);
}

<*
 The specifier as text, resolved, loaded and linked.

 @return? rt::THROWN
*>
fn ModuleRecord*? import_record(Vm* vm, Value specifier, String base) @local
{
	JsString* text = vm.to_string(specifier)!;
	@pool()
	{
		String resolved = resolve_specifier(vm, base, text.tutf8())!;
		ModuleRecord* m = vm.find_module(resolved);
		if (!m) m = load_module_file(vm, resolved)!;
		vm.link_module(m)!;
		return m;
	};
}

<*
 Free the module records added since `mark` that never linked: what a failed import loaded.
 Nothing linked can point at them, because linking takes in everything a module imports.
*>
fn void drop_unlinked_since(Vm* vm, sz mark) @local
{
	for (sz i = vm.modules.len(); i > mark; i--)
	{
		ModuleRecord* m = vm.modules[i - 1];
		if (m.state != COMPILED) continue;
		vm.modules.remove_at(i - 1);
		m.free();
	}
}

<*
 The fulfilment handler of an import's promise: the namespace, kept in native_data.
*>
fn Value? native_import_answer(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => callee.native_data;

fn void install_dynamic_import() @init
{
	rt::dynamic_import_hook = &dynamic_import;
}
