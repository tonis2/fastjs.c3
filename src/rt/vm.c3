module fastjs::rt;
import std::collections::list, std::core::dstring, std::time, std::io, std::os::env;

// A JS exception is pending in Vm.exception.
excuse THROWN;

const uint STACK_SIZE = 256 * 1024;
const uint MAX_FRAMES = 8 * 1024;

alias NativeFn = fn Value?(Vm* vm, Value this_value, Value[] args, JsFunction* callee);
// Returns non-zero to stop the running script.
alias InterruptHandler = fn int(void* runtime, void* opaque);
const uint INTERRUPT_INTERVAL = 10000;

<*
 A captured variable: closures share the box, not the value.
*>
struct Box
{
	inline GcHeader header;
	Value value;
}

struct JsFunction
{
	inline JsObject object;
	// Null for a native function.
	FunctionProto* proto;
	NativeFn native;
	Box** captures;
	// An arrow function's `this`, fixed when it was created.
	Value bound_this;
	// Methods: `super` lookups start at this object's prototype.
	JsObject* home_object;
	// Class constructors: the function that defines instance fields on a new instance.
	Value fields_init;
	String native_name;
	uint native_arity;
	// Lets one native serve several built-ins, e.g. which ErrorKind an error constructor makes.
	int magic;
	// Per-native state, e.g. a bound function's target and arguments.
	Value native_data;
	Value native_data2;
	// Functions the embedding host registered: its callback and the pointer handed back to it.
	void* host_fn;
	void* host_opaque;
}

struct Frame
{
	FunctionProto* proto;
	JsFunction* function;
	uint pc;
	// Stack index of r0, which holds `this`.
	uint base;
	Value new_target;
	// A `new` call: the result is `this` unless the function returns an object.
	bool construct;
	// execute() returns when this frame does; set on frames entered from native code.
	bool stop;
	// A generator or async call: where the frame is saved when it suspends.
	JsCoroutine* coroutine;
}

enum ErrorKind : char
{
	ERROR,
	TYPE_ERROR,
	RANGE_ERROR,
	REFERENCE_ERROR,
	SYNTAX_ERROR,
}

<*
 Atoms the engine itself needs, interned once.
*>
struct Atoms
{
	Value length;
	Value prototype;
	Value constructor;
	Value name;
	Value message;
	Value stack;
	Value to_string;
	Value value_of;
	Value next;
	Value done;
	Value value;
	Value empty;
	Value undefined_str;
	Value null_str;
	Value true_str;
	Value false_str;
	Value object_str;
	Value function_str;
	Value number_str;
	Value string_str;
	Value boolean_str;
	Value symbol_str;
	Value return_str;
	Value last_index;
	Value then;
	Value throw_str;
}

<*
 A compiled script: keeps its code alive while anything can still call it.
*>
struct Script
{
	FunctionProto* main;
	String name;
	String source;
}

struct Vm
{
	Heap heap;
	Value* stack;
	// First free stack slot above the current frame's registers.
	uint stack_top;
	Frame* frames;
	uint frame_count;
	Value exception;
	Atoms atoms;
	JsObject* global;
	JsObject* object_proto;
	JsObject* function_proto;
	JsObject* array_proto;
	JsObject* string_proto;
	JsObject* number_proto;
	JsObject* boolean_proto;
	JsObject*[ErrorKind::len] error_protos;
	JsObject* symbol_proto;
	JsObject* iterator_proto;
	JsObject* map_proto;
	JsObject* set_proto;
	JsObject* array_buffer_proto;
	JsObject* regexp_proto;
	JsObject*[TypedKind::len] typed_protos;
	JsObject* data_view_proto;
	JsObject* proxy_holder;
	JsObject* generator_proto;
	// Prototypes of async and generator functions, whose `constructor`s are AsyncFunction and
	// GeneratorFunction (hosts tell an async callback by that name).
	JsObject* async_function_proto;
	JsObject* generator_function_proto;
	JsObject* promise_proto;
	// Promise jobs, oldest first from job_head; the running one is kept in current_job.
	List {Job} jobs;
	sz job_head;
	Job current_job;
	// Rejected promises nobody has subscribed to yet.
	List {Value} unhandled;
	// Every module loaded, by resolved name, and how imports are resolved and loaded.
	List {ModuleRecord*} modules;
	ModuleHooks* module_hooks;
	Value sym_iterator;
	Value sym_async_iterator;
	ulong random_state;
	Clock start_clock;
	// Heap-allocated names of natives created at runtime (bound functions, getters).
	List {String} owned_names;
	// Compiled regex programs, shared by every RegExp with the same pattern and flags.
	List {RegexCacheEntry} regex_cache;
	// Top-level let/const/function/class of scripts live in slots shared by every script.
	List {Value} slots;
	List {JsString*} slot_names;
	List {bool} slot_const;
	List {Script*} scripts;
	// Where console output goes; the test runner captures it.
	DString* output;
	// Values the host keeps alive (handles).
	List {Value} roots;
	// Functions whose inline caches still need clearing of dead shapes (see scan_ics).
	List {FunctionProto*} ic_scan;
	// Kinds of host objects, by id (see host.c3).
	List {NativeClass*} native_classes;
	// A fast host function raised an exception (see native_fast_call).
	bool host_raised;
	// Native functions currently on the C stack; collection waits until there are none.
	uint native_depth;
	usz gc_min_threshold;
	// Mark in slices between safe points (FASTJS_GC_ATOMIC=1 turns it off).
	bool incremental;
	// Check every incremental mark against a full walk (FASTJS_GC_VERIFY=1, and --gc-stress).
	bool gc_verify;
	// Asked now and then whether to stop a long-running script (see check_interrupt).
	InterruptHandler interrupt;
	void* interrupt_runtime;
	void* interrupt_opaque;
	uint interrupt_countdown;
	// The pending exception can't be caught by script code (an interrupt).
	bool uncatchable;
	// Collect at every safe point, to flush out rooting bugs.
	bool gc_stress;
	usz gc_count;
	// Time spent collecting, for tuning: total, the longest pause, and its parts.
	long gc_total_ns;
	long gc_max_ns;
	long gc_mark_ns;
	long gc_sweep_ns;
	usz gc_live_max;
	// FASTJS_GC_TRACE: print every collection.
	bool gc_trace;
}

<*
 Create a VM with its global object and built-ins.

 @param [&out] self : "The VM to initialize"
 @return? OUT_OF_MEMORY
*>
fn void? Vm.init(&self, usz memory_limit = 0)
{
	*self = {};
	self.heap.init(memory_limit);
	self.stack = mem::new_array(Value, STACK_SIZE).ptr;
	self.frames = mem::new_array(Frame, MAX_FRAMES).ptr;
	self.slots.init(mem);
	self.slot_names.init(mem);
	self.slot_const.init(mem);
	self.scripts.init(mem);
	self.roots.init(mem);
	self.native_classes.init(mem);
	self.ic_scan.init(mem);
	self.owned_names.init(mem);
	self.regex_cache.init(mem);
	self.jobs.init(mem);
	self.unhandled.init(mem);
	self.modules.init(mem);
	self.heap.threshold = GC_MIN_THRESHOLD;
	self.gc_min_threshold = GC_MIN_THRESHOLD;
	self.gc_trace = @ok(env::tget_var("FASTJS_GC_TRACE"));
	self.incremental = !@ok(env::tget_var("FASTJS_GC_ATOMIC"));
	self.gc_verify = @ok(env::tget_var("FASTJS_GC_VERIFY"));
	if (try mb = env::tget_var("FASTJS_GC_MB")) self.gc_min_threshold = (usz)(mb.to_int() ?? 4) * 1024 * 1024;
	self.init_atoms()!;
	self.init_builtins()!;
}

fn void Vm.free(&self)
{
	if (@ok(env::tget_var("FASTJS_GC_STATS")))
	{
		io::eprintfn("fastjs gc: %d collections, %.2f ms total (mark %.2f, sweep %.2f), longest pause %.3f ms, heap now %d KiB", self.gc_count, self.gc_total_ns / 1e6, self.gc_mark_ns / 1e6, self.gc_sweep_ns / 1e6, self.gc_max_ns / 1e6, self.heap.bytes / 1024);
	}
	foreach (s : self.scripts)
	{
		s.main.free();
		free(s.main);
		free(s.name);
		free(s.source);
		free(s);
	}
	self.scripts.free();
	self.roots.free();
	foreach (n : self.owned_names) free(n);
	self.owned_names.free();
	foreach (e : self.regex_cache)
	{
		e.re.free();
		free(e.re);
	}
	self.regex_cache.free();
	self.jobs.free();
	self.unhandled.free();
	foreach (m : self.modules) m.free();
	self.modules.free();
	self.slots.free();
	self.slot_names.free();
	self.slot_const.free();
	free(self.stack);
	free(self.frames);
	// Finalizers in the heap still read their classes.
	self.heap.free();
	foreach (c : self.native_classes)
	{
		free(c.name);
		free(c);
	}
	self.native_classes.free();
	self.ic_scan.free();
}

fn Value? Vm.atom_value(&self, String name) => string_value(self.heap.atom(name)!);

fn void? Vm.init_atoms(&self)
{
	Atoms* a = &self.atoms;
	a.length = self.atom_value("length")!;
	a.prototype = self.atom_value("prototype")!;
	a.constructor = self.atom_value("constructor")!;
	a.name = self.atom_value("name")!;
	a.message = self.atom_value("message")!;
	a.stack = self.atom_value("stack")!;
	a.to_string = self.atom_value("toString")!;
	a.value_of = self.atom_value("valueOf")!;
	a.next = self.atom_value("next")!;
	a.done = self.atom_value("done")!;
	a.value = self.atom_value("value")!;
	a.empty = self.atom_value("")!;
	a.undefined_str = self.atom_value("undefined")!;
	a.null_str = self.atom_value("null")!;
	a.true_str = self.atom_value("true")!;
	a.false_str = self.atom_value("false")!;
	a.object_str = self.atom_value("object")!;
	a.function_str = self.atom_value("function")!;
	a.number_str = self.atom_value("number")!;
	a.string_str = self.atom_value("string")!;
	a.boolean_str = self.atom_value("boolean")!;
	a.symbol_str = self.atom_value("symbol")!;
	a.return_str = self.atom_value("return")!;
	a.last_index = self.atom_value("lastIndex")!;
	a.then = self.atom_value("then")!;
	a.throw_str = self.atom_value("throw")!;
}

<*
 The slot for a top-level script binding, created on first use. A later script that declares
 the same name gets the same slot, so re-running a script works.
*>
fn uint Vm.slot_for(&self, JsString* name, bool is_const)
{
	foreach (i, n : self.slot_names)
	{
		if (n == name)
		{
			self.slot_const[i] = is_const;
			return (uint)i;
		}
	}
	self.slots.push(UNINITIALIZED);
	self.slot_names.push(name);
	self.slot_const.push(is_const);
	return (uint)self.slots.len() - 1;
}

<*
 An existing slot, or -1.
*>
fn int Vm.find_slot(&self, JsString* name)
{
	foreach (i, n : self.slot_names)
	{
		if (n == name) return (int)i;
	}
	return -1;
}

// ---- errors ----

<*
 Throw a new error of the given kind. Always returns THROWN, for `return vm.throw_error(...)~`.
*>
fn fault Vm.throw_error(&self, ErrorKind kind, String fmt, args...)
{
	@pool()
	{
		String message = string::tformat(fmt, ...args);
		if (try err = self.make_error(kind, message))
		{
			self.exception = object_value(err);
		}
		else
		{
			// Out of memory while reporting: throw the message as a string, if even that works.
			self.exception = string_value(self.heap.string_from_utf8(message) ?? (JsString*)self.atoms.empty.as_pointer());
		}
	};
	return THROWN;
}

fn fault Vm.throw_value(&self, Value v)
{
	self.exception = v;
	return THROWN;
}

<*
 A new error object with message and a stack trace from the current frames.

 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsObject*? Vm.make_error(&self, ErrorKind kind, String message)
{
	JsObject* err = self.heap.new_object(self.error_protos[kind.ordinal], ERROR)!;
	JsString* msg = self.heap.string_from_utf8(message)!;
	err.add(&self.heap, self.atoms.message, string_value(msg), METHOD_PROP)!;
	self.attach_stack(err, msg)!;
	return err;
}

<*
 Give an error object a `stack` string: "Name: message" and then one line per active frame.
*>
fn void? Vm.attach_stack(&self, JsObject* err, JsString* message)
{
	@pool()
	{
		DString out;
		out.tinit();
		Value name = self.get(object_value(err), self.atoms.name) ?? UNDEFINED;
		if (name.is_string()) name.as_string().to_utf8(&out);
		if (message.len)
		{
			out.append(": ");
			message.to_utf8(&out);
		}
		for (uint i = self.frame_count; i > 0; i--)
		{
			Frame* f = &self.frames[i - 1];
			uint pc = f.pc ? f.pc - 1 : 0;
			uint line = pc < f.proto.lines.len ? f.proto.lines[pc] : f.proto.line;
			out.appendf("\n    at %s (%s:%d)", f.proto.name.len ? f.proto.name : "<anonymous>", f.proto.source_name, line);
		}
		JsString* s = self.heap.string_from_utf8(out.str_view())!;
		Shape* existing = err.find_own(self.atoms.stack);
		if (existing)
		{
			err.slots[existing.slot()] = string_value(s);
			self.heap.touch(err);
			return;
		}
		err.add(&self.heap, self.atoms.stack, string_value(s), METHOD_PROP)!;
	};
}

// ---- functions and calls ----

<*
 @return? OUT_OF_MEMORY
*>
fn JsFunction*? Vm.new_native(&self, String name, NativeFn native, uint arity)
{
	JsFunction* f = (JsFunction*)self.heap.new_object(self.function_proto, FUNCTION, JsFunction::size)!;
	f.fields_init = UNDEFINED;
	f.native_data = UNDEFINED;
	f.native_data2 = UNDEFINED;
	f.bound_this = UNDEFINED;
	f.native = native;
	f.native_name = name;
	f.native_arity = arity;
	return f;
}

<*
 Define a native method on obj, non-enumerable like the built-ins.

 @return? OUT_OF_MEMORY
*>
fn JsFunction*? Vm.define_native(&self, JsObject* obj, String name, NativeFn native, uint arity)
{
	JsFunction* f = self.new_native(name, native, arity)!;
	obj.add(&self.heap, self.atom_value(name)!, object_value(f), METHOD_PROP)!;
	return f;
}

fn bool Value.is_function(self) => self.is_object() && self.as_object().kind == FUNCTION;

<*
 The prototype a new closure of p gets.
*>
fn JsObject* Vm.function_proto_for(&self, FunctionProto* p) @inline
{
	if (p.is_async) return self.async_function_proto;
	if (p.is_generator) return self.generator_function_proto;
	return self.function_proto;
}

<*
 Push a frame for a JS function whose arguments are already at stack[base + 1 ...].

 @return? THROWN
*>
fn Frame*? Vm.push_frame(&self, JsFunction* fun, uint base, uint argc, bool construct, Value new_target)
{
	FunctionProto* p = fun.proto;
	if (self.frame_count == MAX_FRAMES || base + p.nregs + 2 >= STACK_SIZE)
	{
		return self.throw_error(RANGE_ERROR, "Maximum call stack size exceeded")~;
	}
	Value* r = self.stack + base;
	if (p.is_arrow) r[0] = fun.bound_this;
	if (p.has_rest)
	{
		JsArray* rest = self.heap.new_array(self.array_proto)!;
		for (uint i = p.nparams + 1; i <= argc; i++) rest.push(r[i]);
		for (uint i = argc + 1; i <= p.nparams; i++) r[i] = UNDEFINED;
		r[p.nparams + 1] = object_value(rest);
		for (uint i = p.nparams + 2; i < p.nregs; i++) r[i] = UNDEFINED;
	}
	else
	{
		uint first_free = argc < p.nparams ? argc + 1 : p.nparams + 1;
		for (uint i = first_free; i < p.nregs; i++) r[i] = UNDEFINED;
	}
	Frame* f = &self.frames[self.frame_count++];
	*f = { .proto = p, .function = fun, .base = base, .construct = construct, .new_target = new_target };
	self.stack_top = base + p.nregs;
	return f;
}

<*
 Call any function value from native code.

 @return? THROWN
*>
fn Value? Vm.call(&self, Value callee, Value this_value, Value[] args)
{
	if (!callee.is_function()) return self.throw_error(TYPE_ERROR, "%s is not a function", self.describe(callee))~;
	JsFunction* fun = (JsFunction*)callee.as_object();
	if (fun.native)
	{
		uint depth = fun.native == &native_generator_resume ? 0 : 1;
		self.native_depth += depth;
		defer self.native_depth -= depth;
		defer self.after_native(this_value, args, fun);
		return fun.native(self, this_value, args, fun);
	}
	if (fun.proto.is_class_constructor) return self.throw_error(TYPE_ERROR, "Class constructor %s cannot be invoked without 'new'", fun.proto.name)~;
	uint saved_top = self.stack_top;
	defer self.stack_top = saved_top;
	// stack[base - 1] receives the result, stack[base] is `this`.
	uint base = self.stack_top + 1;
	if (base + args.len + 2 >= STACK_SIZE) return self.throw_error(RANGE_ERROR, "Maximum call stack size exceeded")~;
	// The result slot below the frame may hold a stale pointer the GC would scan; clear it.
	self.stack[base - 1] = UNDEFINED;
	self.stack[base] = this_value;
	foreach (i, a : args) self.stack[(sz)base + 1 + i] = a;
	Frame* f = self.push_frame(fun, base, (uint)args.len, false, UNDEFINED)!;
	f.stop = true;
	return self.execute();
}

<*
 `new callee(...args)` from native code.

 @return? THROWN
*>
fn Value? Vm.construct(&self, Value callee, Value[] args, Value new_target = EMPTY)
{
	if (new_target == EMPTY) new_target = callee;
	if (!callee.is_function()) return self.throw_error(TYPE_ERROR, "%s is not a constructor", self.describe(callee))~;
	JsFunction* fun = (JsFunction*)callee.as_object();
	if (fun.native)
	{
		self.native_depth++;
		defer self.native_depth--;
		defer self.after_native(EMPTY, args, fun);
		return fun.native(self, EMPTY, args, fun);
	}
	if (!fun.proto.is_constructor()) return self.throw_error(TYPE_ERROR, "%s is not a constructor", self.describe(callee))~;
	Value this_value = fun.proto.is_derived ? UNINITIALIZED : object_value(self.new_instance(new_target)!);
	uint saved_top = self.stack_top;
	defer self.stack_top = saved_top;
	uint base = self.stack_top + 1;
	if (base + args.len + 2 >= STACK_SIZE) return self.throw_error(RANGE_ERROR, "Maximum call stack size exceeded")~;
	// The result slot below the frame may hold a stale pointer the GC would scan; clear it.
	self.stack[base - 1] = UNDEFINED;
	self.stack[base] = this_value;
	foreach (i, a : args) self.stack[(sz)base + 1 + i] = a;
	Frame* f = self.push_frame(fun, base, (uint)args.len, true, new_target)!;
	f.stop = true;
	return self.execute();
}

<*
 The `this` for `new F()`: an object whose prototype is F.prototype.

 @return? THROWN
*>
fn JsObject*? Vm.new_instance(&self, Value constructor)
{
	Value proto = self.get(constructor, self.atoms.prototype)!;
	JsObject* p = proto.is_object() ? proto.as_object() : self.object_proto;
	return self.heap.new_object(p)!;
}

<*
 The write barrier for natives, which have none of their own: no slice runs while one is on
 the C stack, so whatever it changed among its receiver, arguments and callee (and the callee's
 own state) is put back on the gray stack once it returns.
*>
fn void Vm.after_native(&self, Value this_value, Value[] args, JsFunction* callee) @inline
{
	if (self.heap.marking) self.touch_native_call(this_value, args, callee);
}

fn void Vm.touch_native_call(&self, Value this_value, Value[] args, JsFunction* callee)
{
	Heap* heap = &self.heap;
	heap.touch_value(this_value);
	foreach (a : args) heap.touch_value(a);
	heap.touch(callee);
	heap.touch_value(callee.native_data);
	heap.touch_value(callee.native_data2);
}

<*
 How the call at pc wrote its callee ("o.foo"), or a description of the value when unknown.
*>
fn String Vm.callee_text(&self, Frame* f, uint pc, Value callee)
{
	String name = f.proto.site_name(pc - 1);
	return name.len ? name : self.describe(callee);
}

<*
 The TypeError for iterating v, named after the source when a for-of or spread is doing it.
*>
fn fault Vm.not_iterable(&self, Value v)
{
	String name;
	bool destructuring;
	if (self.frame_count)
	{
		Frame* f = &self.frames[self.frame_count - 1];
		if (f.pc)
		{
			Op op = ins_op(f.proto.code[f.pc - 1]);
			if (op == GETITER || op == APPENDSPREAD) name = f.proto.site_name(f.pc - 1);
			// Destructuring is the unnamed GETITER, which V8 explains for objects.
			destructuring = op == GETITER && !name.len && v.is_object() && !v.is_function();
		}
	}
	if (destructuring) return self.throw_error(TYPE_ERROR, "object is not iterable (cannot read property Symbol(Symbol.iterator))");
	if (name == SPREAD_ARGUMENT_SITE)
	{
		if (!v.is_nullish()) return self.throw_error(TYPE_ERROR, "Spread syntax requires ...iterable[Symbol.iterator] to be a function");
		return self.throw_error(TYPE_ERROR, "%s is not iterable (cannot read property %s)", self.describe(v), self.describe(v));
	}
	return self.throw_error(TYPE_ERROR, "%s is not iterable", name.len ? name : self.describe(v));
}

<*
 A short description of a value for error messages, e.g. "undefined", "\"text\"" or a function's name.
*>
fn String Vm.describe(&self, Value v)
{
	switch
	{
		case v.is_undefined(): return "undefined";
		case v.is_null(): return "null";
		case v == TRUE: return "true";
		case v == FALSE: return "false";
		case v.is_string(): return string::tformat("\"%s\"", v.as_string().tutf8());
		case v.is_number():
			char[40] buf;
			return format_number(v.as_number(), &buf).tcopy();
		case v.is_function():
			JsFunction* f = (JsFunction*)v.as_object();
			String name = f.native ? f.native_name : f.proto.name;
			return name.len ? name.tcopy() : "function";
		case v.is_symbol():
			return self.symbol_text(v);
		default: return "object";
	}
}

<*
 Run a compiled script's top level, with `this` the global object.

 @return? THROWN
*>
fn Value? Vm.run_script(&self, Script* script)
{
	JsFunction* main = (JsFunction*)self.heap.new_object(self.function_proto, FUNCTION, JsFunction::size) ?? self.oom()~!;
	main.proto = script.main;
	uint saved_top = self.stack_top;
	defer self.stack_top = saved_top;
	uint base = self.stack_top + 1;
	self.stack[base - 1] = UNDEFINED;
	self.stack[base] = object_value(self.global);
	Frame* f = self.push_frame(main, base, 0, false, UNDEFINED)!;
	f.stop = true;
	return self.execute();
}
