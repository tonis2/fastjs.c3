module fastjs::rt;
import std::collections::list;

// ES modules. A module compiles to an async function whose top-level bindings (imports included)
// are all captures. Linking gives every module a box per binding: its own declarations get fresh
// boxes, and an import gets the exporting module's box itself, so imports are live and cyclic
// graphs link fine. Hoisted function declarations are created at link time, before any module
// body runs, as the spec has it.

enum ModuleState : char
{
	COMPILED,
	LINKED,
	// On the evaluation stack, waiting for its imports: an import cycle back to it doesn't wait.
	EVALUATING,
	// Its body has started, or is scheduled to once imports with top-level await finish.
	STARTED,
}

<*
 One capture of a module function: the module's own binding, or an import.
*>
struct ModuleCell
{
	bool imported;
	// Imports: index into requests, and the name imported ("*" for a namespace).
	uint request;
	String import_name;
}

struct ModuleExport
{
	String name;
	// A local export names a cell; an indirect one (export { x } from 'm') names a request.
	bool indirect;
	uint cell;
	uint request;
	String import_name;
}

<*
 A function declaration at module top level: nested proto `proto`, stored into cell `cell`.
*>
struct HoistedFunction
{
	uint proto;
	uint cell;
}

struct ModuleRecord
{
	String name;
	// Kept for Function.prototype.toString, which slices it.
	String source;
	FunctionProto* main;
	// Specifiers as written, and the modules they resolved to (filled in while loading).
	List {String} requests;
	List {ModuleRecord*} deps;
	ModuleCell[] cells;
	ModuleExport[] exports;
	// Requests whose exports are all re-exported (export * from).
	uint[] star_exports;
	HoistedFunction[] hoisted;
	// One box per cell, once linked.
	Box** boxes;
	JsFunction* function;
	Value namespace;
	// The evaluation's promise.
	Value promise;
	ModuleState state;
}

<*
 Resolve and load hooks, the same shape quickjs.c3's are: the host decides what an import means.
 normalize writes the resolved name into out (NUL-terminated) and returns 0, or refuses.
 load returns the module's bytes (borrowed until the next call) or null.
*>
alias ModuleNormalizeFn = fn int(ZString base, ZString name, char* out, usz out_size, void* opaque);
alias ModuleLoadFn = fn char*(ZString name, usz* len_out, void* opaque);

struct ModuleHooks
{
	ModuleNormalizeFn normalize;
	ModuleLoadFn load;
	void* opaque;
}

fn void ModuleRecord.free(&self)
{
	free(self.name);
	free(self.source);
	if (self.main)
	{
		self.main.free();
		free(self.main);
	}
	foreach (r : self.requests) free(r);
	self.requests.free();
	self.deps.free();
	foreach (c : self.cells) free(c.import_name);
	free(self.cells);
	foreach (e : self.exports)
	{
		free(e.name);
		free(e.import_name);
	}
	free(self.exports);
	free(self.star_exports);
	free(self.hoisted);
	free(self.boxes);
	free(self);
}

fn ModuleRecord* Vm.find_module(&self, String name)
{
	foreach (m : self.modules)
	{
		if (m.name == name) return m;
	}
	return null;
}

<*
 The box behind export `name` of m, following re-exports. Null when m has no such export.
*>
fn Box* Vm.resolve_export(&self, ModuleRecord* m, String name, uint depth = 0)
{
	if (depth > 64) return null;
	foreach (e : m.exports)
	{
		if (e.name != name) continue;
		if (!e.indirect) return m.boxes[e.cell];
		return self.resolve_export(m.deps[e.request], e.import_name, depth + 1);
	}
	if (name == "default") return null;
	foreach (req : m.star_exports)
	{
		Box* b = self.resolve_export(m.deps[req], name, depth + 1);
		if (b) return b;
	}
	return null;
}

fn void Vm.collect_unlinked(&self, ModuleRecord* m, List {ModuleRecord*}* out)
{
	if (m.state != COMPILED || out.contains(m)) return;
	out.push(m);
	foreach (d : m.deps) self.collect_unlinked(d, out);
}

<*
 Link m and everything it imports that isn't linked yet.

 @return? THROWN
*>
fn void? Vm.link_module(&self, ModuleRecord* root)
{
	List {ModuleRecord*} todo;
	todo.init(mem);
	defer todo.free();
	self.collect_unlinked(root, &todo);
	// Own bindings first, so every import below finds its exporter's box in place.
	foreach (m : todo)
	{
		m.boxes = mem::new_array(Box*, m.cells.len ? m.cells.len : 1).ptr;
		foreach (i, c : m.cells)
		{
			if (c.imported) continue;
			Box* box = self.heap.alloc(BOX, Box::size) ?? self.oom()~!;
			box.value = UNINITIALIZED;
			m.boxes[i] = box;
		}
	}
	foreach (m : todo)
	{
		foreach (i, c : m.cells)
		{
			if (!c.imported) continue;
			ModuleRecord* from = m.deps[c.request];
			if (c.import_name == "*")
			{
				Box* box = self.heap.alloc(BOX, Box::size) ?? self.oom()~!;
				box.value = self.module_namespace(from)!;
				m.boxes[i] = box;
				continue;
			}
			Box* box = self.resolve_export(from, c.import_name);
			if (!box)
			{
				return self.throw_error(SYNTAX_ERROR, "The requested module '%s' does not provide an export named '%s'", m.requests[c.request], c.import_name)~;
			}
			m.boxes[i] = box;
		}
	}
	foreach (m : todo)
	{
		JsFunction* fun = (JsFunction*)self.heap.new_object(self.function_proto, FUNCTION, JsFunction::size) ?? self.oom()~!;
		fun.proto = m.main;
		fun.fields_init = UNDEFINED;
		fun.bound_this = UNDEFINED;
		fun.native_data = UNDEFINED;
		fun.native_data2 = UNDEFINED;
		fun.captures = mem::new_array(Box*, m.cells.len ? m.cells.len : 1).ptr;
		for (usz i = 0; i < m.cells.len; i++) fun.captures[i] = m.boxes[i];
		m.function = fun;
		m.state = LINKED;
	}
	// Function declarations exist before any module body runs.
	foreach (m : todo)
	{
		foreach (h : m.hoisted)
		{
			FunctionProto* proto = m.main.protos[h.proto];
			JsFunction* f = (JsFunction*)self.heap.new_object(self.function_proto_for(proto), FUNCTION, JsFunction::size) ?? self.oom()~!;
			f.proto = proto;
			f.fields_init = UNDEFINED;
			f.bound_this = UNDEFINED;
			f.native_data = UNDEFINED;
			f.native_data2 = UNDEFINED;
			if (proto.captures.len)
			{
				f.captures = mem::new_array(Box*, proto.captures.len).ptr;
				// At module top level, everything a function can capture is a module binding.
				foreach (j, src : proto.captures) f.captures[j] = m.function.captures[src.index];
			}
			m.boxes[h.cell].value = object_value(f);
		}
	}
}

<*
 The namespace object of `import * as ns`: a getter per export, so it stays live.

 @return? THROWN
*>
fn Value? Vm.module_namespace(&self, ModuleRecord* m)
{
	if (m.namespace.is_object()) return m.namespace;
	JsObject* ns = self.heap.new_object(null) ?? self.oom()~!;
	m.namespace = object_value(ns);
	List {String} names;
	names.init(mem);
	defer names.free();
	self.export_names(m, &names, 0);
	foreach (name : names)
	{
		Box* box = self.resolve_export(m, name);
		if (!box) continue;
		JsFunction* getter = self.new_native("", &native_namespace_get, 0)!;
		getter.native_data = pointer_value(TAG_OBJECT, box);
		self.define_accessor(ns, self.atom_value(name)!, object_value(getter), UNDEFINED, { .enumerable = true }) ?? self.oom()~!;
	}
	ns.frozen_extensions = true;
	return m.namespace;
}

fn void Vm.export_names(&self, ModuleRecord* m, List {String}* out, uint depth)
{
	if (depth > 64) return;
	foreach (e : m.exports)
	{
		if (!out.contains(e.name)) out.push(e.name);
	}
	foreach (req : m.star_exports)
	{
		List {String} inner;
		inner.init(mem);
		defer inner.free();
		self.export_names(m.deps[req], &inner, depth + 1);
		foreach (n : inner)
		{
			if (n != "default" && !out.contains(n)) out.push(n);
		}
	}
}

fn Value? native_namespace_get(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = ((Box*)callee.native_data.as_pointer()).value;
	if (v == UNINITIALIZED) return vm.throw_error(REFERENCE_ERROR, "Cannot access a module binding before initialization")~;
	return v;
}

<*
 Run m after its imports, returning a promise for the evaluation. Modules without top-level
 await finish synchronously, so the promise comes back already settled. A module in a cycle
 doesn't wait for the module that imported it, as in the spec.

 @return? THROWN
*>
fn Value? Vm.evaluate_module(&self, ModuleRecord* m)
{
	if (m.state != LINKED) return m.promise;
	m.state = EVALUATING;
	JsPromise* done = self.new_promise()!;
	m.promise = object_value(done);
	m.function.native_data = m.promise;
	List {Value} pending;
	pending.init(mem);
	defer pending.free();
	foreach (dep : m.deps)
	{
		// A dependency still on the evaluation stack is part of a cycle: don't wait for it.
		if (dep.state == EVALUATING) continue;
		Value p = self.evaluate_module(dep)!;
		JsPromise* dp = (JsPromise*)p.as_object();
		switch (dp.state)
		{
			case FULFILLED:
				break;
			case REJECTED:
				dp.handled = true;
				self.forget_unhandled(dp);
				self.reject_promise(done, dp.result);
				m.state = STARTED;
				return m.promise;
			case PENDING:
				pending.push(p);
		}
	}
	m.state = STARTED;
	if (pending.len())
	{
		// Wait for the dependencies still running top-level awaits, then start.
		JsArray* list = self.heap.new_array(self.array_proto, (uint)pending.len()) ?? self.oom()~!;
		foreach (p : pending) list.push(p);
		JsPromise* all = self.combine(ALL, object_value(list))!;
		JsFunction* start = self.new_native("", &native_module_start, 0)!;
		start.native_data = object_value(m.function);
		self.perform_then(all, object_value(start), UNDEFINED, m.promise);
		return m.promise;
	}
	self.start_module(m.function)!;
	return m.promise;
}

fn void? Vm.start_module(&self, JsFunction* fun)
{
	JsPromise* done = (JsPromise*)fun.native_data.as_object();
	Value q = self.call(object_value(fun), UNDEFINED, {})!;
	JsPromise* body = (JsPromise*)q.as_object();
	switch (body.state)
	{
		case FULFILLED:
			self.settle(done, UNDEFINED, false);
		case REJECTED:
			body.handled = true;
			self.forget_unhandled(body);
			self.settle(done, body.result, true);
		case PENDING:
			self.perform_then(body, UNDEFINED, UNDEFINED, object_value(done));
	}
}

// Run a module once the dependencies it waited for are done. Its result settles the reaction's
// target, the module's own promise.
fn Value? native_module_start(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsFunction* fun = (JsFunction*)callee.native_data.as_object();
	return vm.call(object_value(fun), UNDEFINED, {});
}
