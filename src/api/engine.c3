<*
 The embedding API: run scripts, build and read values, hold values across calls, define host
 functions and host objects.

 **Values are not owned.** A `Value` is the engine's own 8-byte word. Inside a host function
 nothing is collected, so any Value it sees or makes stays valid until it returns. Outside one,
 a Value in a C3 variable stays valid until the next call that can run JS or collect (`eval`,
 `call`, `step_job`, `gc_step`, `collect`); `hold` keeps one for longer.

 Host functions come in two forms. `@bind` takes a plain typed C3 function and generates the
 glue (see bind.c3). `function` takes a `HostFn(Call*)` for the cases that need the arguments
 raw.
*>
module fastjs::js;
import std::io, std::core::dstring, std::collections::list, fastjs::rt, fastjs::compile;

alias Value = rt::Value;
alias Vm = rt::Vm;
alias NativeClass = rt::NativeClass;
alias Finalizer = rt::NativeFinalizer;
alias ModuleHooks = rt::ModuleHooks;
alias ErrorKind = rt::ErrorKind;
alias TypedKind = rt::TypedKind;
alias InterruptFn = fn int(void* engine, void* opaque);
<*
 A host function in its raw form. Return the result, or `c.fail(...)~` to throw.
*>
alias HostFn = fn Value?(Call* c);

const Value UNDEFINED = rt::UNDEFINED;
const Value NULL = rt::NULL;
const Value TRUE = rt::TRUE;
const Value FALSE = rt::FALSE;

<*
 A JS exception is pending: `take_error` gives it as text. Every API call that can run JS or
 throw returns this on failure; so do typed host functions, after `fail`.
*>
excuse THREW, NO_ENGINE, NOT_A_VIEW;

enum EvalMode
{
	// The value is the last expression statement's.
	SCRIPT,
	// The body of an async function called at once: top-level `await` and `return` work, and
	// the value is the call's promise.
	ASYNC,
	// An ES module; the value is a promise for its evaluation.
	MODULE,
}

enum PromiseState
{
	NOT_A_PROMISE,
	PENDING,
	FULFILLED,
	REJECTED,
}

<*
 A property name interned once, so reading or writing it does no string work.
*>
typedef Key = Value;

<*
 A Value the host keeps alive until `drop`. Zero is no root.
*>
typedef Root = uint;
const Root NO_ROOT = (Root)0;

<*
 The engine. Its address must not change after `init`: host functions and hooks point at it.
*>
struct Engine
{
	inline Vm vm;
	// Distinct for every engine this process starts, so caches of keys can tell
	// a new engine at an old address from the one they were made for.
	uint id;
}

uint next_engine_id @local;

<*
 @param [&out] self : "The engine to start"
 @param memory_limit : "Bytes the heap may grow to, or 0 for no limit"
 @return? NO_ENGINE
*>
fn void? Engine.init(&self, usz memory_limit = 0)
{
	if (catch self.vm.init(memory_limit)) return NO_ENGINE~;
	self.vm.exception = rt::EMPTY;
	self.id = ++next_engine_id;
}

<*
 Shut the engine down; every Root it handed out is gone with it.
*>
fn void Engine.free(&self) => self.vm.free();

<*
 A new engine on the heap; `close` frees it.

 @return? NO_ENGINE
*>
fn Engine*? open(usz memory_limit = 0)
{
	Engine* e = mem::new(Engine);
	if (catch err = e.init(memory_limit))
	{
		free(e);
		return err~;
	}
	return e;
}

<*
 Shut down and free an engine made by `open`.
*>
fn void Engine.close(&self)
{
	self.free();
	free(self);
}

// ---- running code ----

<*
 Run source.

 @return? THREW : "It threw or would not compile; take_error says why"
*>
fn Value? Engine.eval(&self, String source, String name = "<eval>", EvalMode mode = SCRIPT)
{
	Vm* vm = &self.vm;
	if (mode == MODULE)
	{
		Value? promise = compile::eval_module(vm, source, name);
		if (catch promise) return THREW~;
		return promise;
	}
	CompileError err;
	Script*? script = compile::compile_script(vm, source, name, &err, mode == ASYNC);
	if (catch script)
	{
		(void)vm.throw_error(SYNTAX_ERROR, "%s\n    at %s:%d:%d", err.message, name, err.line, err.col);
		return THREW~;
	}
	Value? result = vm.run_script(script);
	if (catch result) return THREW~;
	return result;
}

fn bool Engine.has_error(&self) => self.vm.exception != rt::EMPTY;

<*
 The pending exception, taken: none is pending afterwards. EMPTY when there was none.
*>
fn Value Engine.take_exception(&self)
{
	Value thrown = self.vm.exception;
	self.vm.exception = rt::EMPTY;
	self.vm.uncatchable = false;
	return thrown;
}

<*
 The pending exception as text, followed by its stack trace when it is an Error; empty when
 nothing is pending. Taking it clears it.
*>
fn String Engine.take_error(&self, Allocator allocator = mem)
{
	Value thrown = self.take_exception();
	if (thrown == rt::EMPTY || thrown == rt::UNINITIALIZED) return "".copy(allocator);
	return self.error_text(thrown, allocator);
}

<*
 How a thrown value reads in a report: an Error's stack (which starts with "Name: message"),
 or String(v) for anything else.
*>
fn String Engine.error_text(&self, Value thrown, Allocator allocator = mem)
{
	if (thrown.is_nullish()) return "".copy(allocator);
	Vm* vm = &self.vm;
	vm.roots.push(thrown);
	defer (void)vm.roots.pop();
	String message = self.text(thrown, allocator);
	if (!is_error(thrown)) return message;
	Value stack = vm.get(thrown, vm.atoms.stack) ?? UNDEFINED;
	vm.exception = rt::EMPTY;
	if (!stack.is_string()) return message;
	String trace = self.text(stack, allocator);
	if (trace.len == 0)
	{
		alloc::free(allocator, trace.ptr);
		return message;
	}
	if (trace.starts_with(message))
	{
		alloc::free(allocator, message.ptr);
		return trace;
	}
	String joined = string::format(allocator, "%s\n%s", message, trace);
	alloc::free(allocator, message.ptr);
	alloc::free(allocator, trace.ptr);
	return joined;
}

fn bool is_error(Value v) => v.is_object() && v.as_object().kind == ERROR;

<*
 Throw an Error with a formatted message. `return js.fail("…")~;` from a host function.
*>
fn fault Engine.fail(&self, String format, args...) @format(1)
{
	return self.vm.throw_error(ERROR, "%s", string::tformat(format, ...args));
}

<*
 Throw an error of a given kind (TYPE_ERROR, RANGE_ERROR, …) with a formatted message.
*>
fn fault Engine.fail_with(&self, ErrorKind kind, String format, args...) @format(2)
{
	return self.vm.throw_error(kind, "%s", string::tformat(format, ...args));
}

<*
 Throw any value.
*>
fn fault Engine.throw(&self, Value v) => self.vm.throw_value(v);

// ---- reading values ----

<*
 v as String(v) gives it; empty for a symbol, or when converting threw.
*>
fn String Engine.text(&self, Value v, Allocator allocator = mem)
{
	if (v.is_symbol()) return "".copy(allocator);
	JsString*? s = self.vm.to_string(v);
	if (catch s)
	{
		self.vm.exception = rt::EMPTY;
		return "".copy(allocator);
	}
	@pool()
	{
		DString out;
		out.tinit((sz)s.len + 1);
		s.to_utf8(&out);
		return out.str_view().copy(allocator);
	};
}

<*
 v as a number, as Number(v) gives it.

 @return? THREW
*>
fn double? Engine.number(&self, Value v)
{
	if (v.is_int()) return (double)v.as_int();
	if (v.is_double()) return v.as_double();
	double? d = self.vm.to_number(v);
	if (catch d) return THREW~;
	return d;
}

fn bool Engine.truth(&self, Value v) => rt::truthy(v);

<*
 A short description for messages: "undefined", "\"text\"", a function's name, "object". Temp memory.
*>
fn String Engine.describe(&self, Value v) => self.vm.describe(v);

<*
 typeof v.
*>
fn String Engine.type_of(&self, Value v) => self.vm.type_of(v).as_string().tutf8();

fn Value Engine.global(&self) => rt::object_value(self.vm.global);

<*
 The key for name. Keys live as long as the engine.

 @return? THREW
*>
fn Key? Engine.key(&self, String name)
{
	Value? s = self.vm.atom_value(name);
	if (catch s) return THREW~;
	Value? key = self.vm.to_key(s);
	if (catch key) return THREW~;
	return (Key)key;
}

macro Value? Engine.@key_of(&self, key)
{
	$switch $Typeof(key):
		$case Key: return (Value)key;
		$case String: return (Value)self.key(key);
		$case ZString: return (Value)self.key(key.str_view());
		$default:
			$if types::is_int($Typeof(key)):
				if (key >= 0 && key <= int::max) return rt::integer((int)key);
				return self.vm.to_key(rt::number((double)key));
			$else
				$error "A key is a Key, a String or an integer index";
			$endif
	$endswitch
}

<*
 obj[key], for a Key, a String or an integer index.

 @return? THREW
*>
macro Value? Engine.get(&self, Value obj, key)
{
	$if types::is_int($Typeof(key)):
		if (obj.is_object() && obj.as_object().kind == ARRAY && key >= 0)
		{
			Value v = ((JsArray*)obj.as_object()).get((uint)key);
			return v == rt::EMPTY ? UNDEFINED : v;
		}
	$endif
	Value? v = self.vm.get(obj, self.@key_of(key));
	if (catch v) return THREW~;
	return v;
}

<*
 obj[key] as a number; fallback when it is missing or undefined.

 @return? THREW
*>
macro double? Engine.get_number(&self, Value obj, key, double fallback = 0)
{
	Value v = self.get(obj, key)!;
	if (v.is_undefined()) return fallback;
	return self.number(v);
}

<*
 obj[key] = v.

 @return? THREW
*>
macro void? Engine.set(&self, Value obj, key, Value v)
{
	if (!obj.is_object()) return self.fail_with(TYPE_ERROR, "cannot set a property of %s", self.describe(obj))~;
	$if types::is_int($Typeof(key)):
		if (obj.as_object().kind == ARRAY && key >= 0 && key <= int::max)
		{
			((JsArray*)obj.as_object()).set((uint)key, v);
			self.vm.heap.touch(obj.as_object());
			return;
		}
	$endif
	if (catch self.vm.set(obj, self.@key_of(key), v)) return THREW~;
}

<*
 Whether obj has key, own or inherited.

 @return? THREW
*>
macro bool? Engine.has(&self, Value obj, key)
{
	if (!obj.is_object()) return false;
	bool? r = self.vm.has_property(obj, self.@key_of(key));
	if (catch r) return THREW~;
	return r;
}

<*
 Define key on obj as an accessor, enumerable and configurable.

 @return? THREW
*>
macro void? Engine.accessor(&self, Value obj, key, Value getter, Value setter = UNDEFINED)
{
	if (!obj.is_object()) return self.fail_with(TYPE_ERROR, "cannot define a property of %s", self.describe(obj))~;
	if (catch self.vm.define_accessor(obj.as_object(), self.@key_of(key), getter, setter, { .enumerable = true, .configurable = true })) return THREW~;
}

<*
 value.length as JS reads it; -1 when it has none.

 @return? THREW
*>
fn long? Engine.length(&self, Value v)
{
	if (v.is_object())
	{
		JsObject* o = v.as_object();
		if (o.kind == ARRAY) return ((JsArray*)o).length;
		if (o.kind == TYPED_ARRAY) return ((JsTypedArray*)o).length;
	}
	if (v.is_string()) return v.as_string().len;
	if (!v.is_object()) return -1;
	Value len = self.get(v, self.vm.atoms.length.as_key())!;
	double d = self.number(len)!;
	if (d != d || d < 0) return 0;
	if (d > 9007199254740991.0) return 9007199254740991;
	return (long)d;
}

fn Key Value.as_key(self) @inline => (Key)self;

<*
 Object.keys(obj): its own enumerable string keys, in order. Temp memory.

 @return? THREW
*>
fn Key[]? Engine.keys(&self, Value obj)
{
	if (!obj.is_object()) return (Key[]){};
	List {Value} out;
	out.tinit();
	Vm* vm = &self.vm;
	if (catch vm.own_keys(obj.as_object(), &out, false)) return THREW~;
	Key[] keys = mem::talloc_array(Key, out.len());
	foreach (i, k : out) keys[i] = (Key)k;
	return keys;
}

<*
 A key as text, for messages and switches. Temp memory.
*>
fn String Engine.key_text(&self, Key k) => self.vm.key_text((Value)k);

<*
 Run the body for each own enumerable string-keyed property of obj, in order:
 `js.@each(obj; String name, Value v) { … }`. A getter that throws stops it with THREW.
*>
macro void? Engine.@each(&self, Value obj; @body(String name, Value v))
{
	@pool()
	{
		foreach (k : self.keys(obj)!)
		{
			Value v = self.get(obj, k)!;
			@body(self.key_text(k), v);
		}
	};
}

// ---- making values ----

fn Value number(double d) @inline => rt::number(d);
fn Value integer(int i) @inline => rt::integer(i);
fn Value boolean(bool b) @inline => rt::boolean(b);

<*
 @return? THREW
*>
fn Value? Engine.string(&self, String text)
{
	Value? s = self.vm.str_value(text);
	if (catch s) return THREW~;
	return s;
}

<*
 A new plain object, inheriting from proto when given (Object.prototype otherwise).

 @return? THREW
*>
fn Value? Engine.object(&self, Value proto = UNDEFINED)
{
	JsObject* p = proto.is_object() ? proto.as_object() : proto.is_null() ? null : self.vm.object_proto;
	JsObject*? o = self.vm.heap.new_object(p);
	if (catch o) return self.out_of_memory()~;
	return rt::object_value(o);
}

<*
 @return? THREW
*>
fn Value? Engine.array(&self, uint capacity = 0)
{
	JsArray*? a = self.vm.heap.new_array(self.vm.array_proto, capacity);
	if (catch a) return self.out_of_memory()~;
	return rt::object_value(a);
}

<*
 An array of numbers.

 @return? THREW
*>
fn Value? Engine.numbers(&self, double[] list)
{
	Value array = self.array((uint)list.len)!;
	JsArray* a = (JsArray*)array.as_object();
	foreach (n : list) a.push(rt::number(n));
	return array;
}

<*
 Append v to a JS array.

 @require array.is_object() && array.as_object().kind == ARRAY : "Not an array"
*>
fn void Engine.push(&self, Value array, Value v)
{
	JsArray* a = (JsArray*)array.as_object();
	a.push(v);
	self.vm.heap.touch(a);
}

<*
 A new Error with message.

 @return? THREW
*>
fn Value? Engine.error(&self, String message, ErrorKind kind = ERROR)
{
	JsObject*? err = self.vm.make_error(kind, message);
	if (catch err) return THREW~;
	return rt::object_value(err);
}

fn fault Engine.out_of_memory(&self) => self.vm.oom();

<*
 v as JSON; empty when it has none (undefined, a function) or stringifying threw.
*>
fn String Engine.json(&self, Value v, Allocator allocator = mem)
{
	Vm* vm = &self.vm;
	Value[1] args = { v };
	vm.native_depth++;
	Value? text = rt::native_json_stringify(vm, UNDEFINED, &args, null);
	vm.native_depth--;
	if (catch text)
	{
		vm.exception = rt::EMPTY;
		return "".copy(allocator);
	}
	if (!text.is_string()) return "".copy(allocator);
	return self.text(text, allocator);
}

<*
 text parsed as JSON.

 @return? THREW
*>
fn Value? Engine.from_json(&self, String text)
{
	Vm* vm = &self.vm;
	Value s = self.string(text)!;
	Value[1] args = { s };
	vm.native_depth++;
	Value? v = rt::native_json_parse(vm, UNDEFINED, &args, null);
	vm.native_depth--;
	if (catch v) return THREW~;
	return v;
}

// ---- holding values ----

<*
 Keep v alive until `drop`.
*>
fn Root Engine.hold(&self, Value v)
{
	Vm* vm = &self.vm;
	if (vm.host_free.len())
	{
		uint slot = vm.host_free.pop()!!;
		vm.host_roots[slot] = v;
		return (Root)(slot + 1);
	}
	vm.host_roots.push(v);
	return (Root)vm.host_roots.len();
}

<*
 The value r holds; undefined for NO_ROOT.
*>
fn Value Engine.held(&self, Root r) @inline
{
	return r == NO_ROOT ? UNDEFINED : self.vm.host_roots[(usz)r - 1];
}

<*
 Let go of *r and set it to NO_ROOT. Safe on NO_ROOT.
*>
fn void Engine.drop(&self, Root* r)
{
	if (*r == NO_ROOT) return;
	uint slot = (uint)*r - 1;
	self.vm.host_roots[slot] = UNDEFINED;
	self.vm.host_free.push(slot);
	*r = NO_ROOT;
}

<*
 Point *r at v instead, holding it if it held nothing.
*>
fn void Engine.rehold(&self, Root* r, Value v)
{
	if (*r == NO_ROOT)
	{
		*r = self.hold(v);
		return;
	}
	self.vm.host_roots[(usz)*r - 1] = v;
}

// ---- functions ----

<*
 What a host function is called with.
*>
struct Call
{
	Engine* js;
	// undefined when called with `new`
	Value this;
	Value[] args;
	// what the function was registered with
	void* host;
	JsFunction* callee;
}

fn Value Call.arg(&self, usz at) @inline => at < self.args.len ? self.args[at] : UNDEFINED;
fn bool Call.given(&self, usz at) @inline => at < self.args.len && !self.args[at].is_undefined();
fn fault Call.fail(&self, String format, args...) @format(1)
{
	return self.js.vm.throw_error(ERROR, "%s", string::tformat(format, ...args));
}

fn Value? raw_trampoline(Vm* vm, Value this_value, Value[] args, JsFunction* callee) @local
{
	Call c = { (Engine*)vm, this_value == rt::EMPTY ? UNDEFINED : this_value, args, callee.host_opaque, callee };
	Value? r = ((HostFn)callee.host_fn)(&c);
	if (catch r) return rt::THROWN~;
	return r;
}

<*
 A name the engine keeps for as long as it lives.
*>
fn String Engine.keep_name(&self, String name)
{
	String copied = name.copy(mem);
	self.vm.owned_names.push(copied);
	return copied;
}

<*
 A JS function backed by a raw NativeFn: what `@bind` makes.

 @return? THREW
*>
fn Value? Engine.native(&self, rt::NativeFn body, String name, uint arity, void* host = null, void* data = null)
{
	JsFunction*? f = self.vm.new_native(self.keep_name(name), body, arity);
	if (catch f) return THREW~;
	f.host_opaque = host;
	f.host_fn = data;
	return rt::object_value(f);
}

<*
 A JS function that calls body with the arguments raw.

 @param name : "What the function calls itself in stack traces"
 @param arity : "What fn.length reports"
 @param host : "Handed to body as c.host"
 @return? THREW
*>
fn Value? Engine.function(&self, HostFn body, String name, uint arity = 0, void* host = null)
{
	return self.native(&raw_trampoline, name, arity, host, (void*)body);
}

<*
 Call f with this_value and args.

 @return? THREW
*>
fn Value? Engine.call(&self, Value f, Value this_value = UNDEFINED, Value[] args = {})
{
	Value? r = self.vm.call(f, this_value, args);
	if (catch r) return THREW~;
	return r;
}

// ---- host objects ----

<*
 A new kind of host object. finalizer, when given, runs with an instance's data when the
 instance is collected or the engine closes; it must not call into the engine.

 @return? THREW
*>
fn NativeClass*? Engine.class(&self, String name, Finalizer finalizer = null, void* opaque = null)
{
	NativeClass*? c = self.vm.new_native_class(name, finalizer, opaque);
	if (catch c) return THREW~;
	return c;
}

<*
 The prototype every instance of cls has: where its methods go.
*>
fn Value Engine.prototype(&self, NativeClass* cls) => rt::object_value(cls.proto);

<*
 A new instance of cls carrying data.

 @return? THREW
*>
fn Value? Engine.instance(&self, NativeClass* cls, void* data)
{
	JsNative*? n = self.vm.new_native_object(cls, data);
	if (catch n) return THREW~;
	return rt::object_value(n);
}

<*
 v's data when it is an instance of cls, else null.
*>
fn void* data_of(Value v, NativeClass* cls) @inline => rt::native_data_of(v, cls);

<*
 Replace an instance's data; null makes its methods refuse it from then on, and skips the
 finalizer.

 @return "False when v is not an instance of cls"
*>
fn bool set_data(Value v, NativeClass* cls, void* data)
{
	if (!v.is_object() || v.as_object().kind != NATIVE) return false;
	JsNative* n = (JsNative*)v.as_object();
	if (n.cls != cls) return false;
	n.data = data;
	return true;
}

// ---- binary data ----

enum ViewKind
{
	BUFFER,
	DATA_VIEW,
	INT8,
	UINT8,
	UINT8_CLAMPED,
	INT16,
	UINT16,
	INT32,
	UINT32,
	FLOAT32,
	FLOAT64,
}

<*
 Where a typed array, DataView or ArrayBuffer keeps its bytes. Valid until the next call that
 can run JS or collect.
*>
struct View
{
	ViewKind kind;
	char* ptr;
	// Elements for a typed array, bytes otherwise.
	usz len;
	usz byte_len;
}

fn ViewKind view_kind(TypedKind kind) @local
{
	switch (kind)
	{
		case INT8: return INT8;
		case UINT8: return UINT8;
		case UINT8_CLAMPED: return UINT8_CLAMPED;
		case INT16: return INT16;
		case UINT16: return UINT16;
		case INT32: return INT32;
		case UINT32: return UINT32;
		case FLOAT32: return FLOAT32;
		case FLOAT64: return FLOAT64;
	}
}

<*
 @return? NOT_A_VIEW : "v is none of those, or its buffer was detached"
*>
fn View? view(Value v)
{
	if (!v.is_object()) return NOT_A_VIEW~;
	JsObject* o = v.as_object();
	switch (o.kind)
	{
		case ARRAY_BUFFER:
			JsArrayBuffer* b = (JsArrayBuffer*)o;
			if (!b.data && b.external) return NOT_A_VIEW~;
			return { BUFFER, b.data, b.byte_length, b.byte_length };
		case TYPED_ARRAY:
			JsTypedArray* t = (JsTypedArray*)o;
			if (!t.data && t.buffer.external) return NOT_A_VIEW~;
			return { view_kind(t.tkind), t.data, t.length, (usz)t.length * t.tkind.size };
		case DATA_VIEW:
			JsTypedArray* t = (JsTypedArray*)o;
			if (!t.data && t.buffer.external) return NOT_A_VIEW~;
			return { DATA_VIEW, t.data, t.length, t.length };
		default:
			return NOT_A_VIEW~;
	}
}

<*
 The bytes behind a typed array, DataView or ArrayBuffer; empty for anything else.
*>
fn char[] bytes(Value v)
{
	View? w = view(v);
	if (catch w) return {};
	return w.ptr ? w.ptr[:w.byte_len] : {};
}

<*
 An ArrayBuffer over memory the host owns. Nothing is copied; detach it before the memory goes.

 @return? THREW
*>
fn Value? Engine.buffer(&self, char* data, usz byte_len)
{
	Vm* vm = &self.vm;
	JsArrayBuffer*? b = (JsArrayBuffer*)vm.heap.new_object(vm.array_buffer_proto, ARRAY_BUFFER, JsArrayBuffer::size);
	if (catch b) return self.out_of_memory()~;
	b.data = data;
	b.byte_length = byte_len;
	b.external = true;
	return rt::object_value(b);
}

<*
 An ArrayBuffer the engine owns, filled from data.

 @return? THREW
*>
fn Value? Engine.buffer_copy(&self, char[] data)
{
	JsArrayBuffer*? b = self.vm.new_buffer(data.len);
	if (catch b) return THREW~;
	if (data.len) mem::copy(b.data, data.ptr, (sz)data.len);
	return rt::object_value(b);
}

<*
 Detach a buffer: it and every view of it become empty.
*>
fn void Engine.detach(&self, Value buffer)
{
	if (!buffer.is_object() || buffer.as_object().kind != ARRAY_BUFFER) return;
	self.vm.detach_buffer((JsArrayBuffer*)buffer.as_object());
}

<*
 Make a buffer read-only for scripts.

 @return "False when v is not an ArrayBuffer"
*>
fn bool freeze(Value buffer)
{
	if (!buffer.is_object() || buffer.as_object().kind != ARRAY_BUFFER) return false;
	((JsArrayBuffer*)buffer.as_object()).immutable = true;
	return true;
}

<*
 A typed array of count elements of kind over buffer, from element offset on.

 @return? THREW
*>
fn Value? Engine.typed_array(&self, TypedKind kind, Value buffer, usz offset, usz count)
{
	if (!buffer.is_object() || buffer.as_object().kind != ARRAY_BUFFER) return self.fail_with(TYPE_ERROR, "not an ArrayBuffer")~;
	JsArrayBuffer* ab = (JsArrayBuffer*)buffer.as_object();
	usz byte_offset = offset * kind.size;
	if (byte_offset + count * kind.size > ab.byte_length) return self.fail_with(RANGE_ERROR, "invalid typed array length")~;
	JsTypedArray*? t = self.vm.new_typed(kind, ab, (uint)byte_offset, (uint)count);
	if (catch t) return THREW~;
	return rt::object_value(t);
}

<*
 A typed array of kind holding a copy of data.

 @return? THREW
*>
fn Value? Engine.typed_copy(&self, TypedKind kind, char[] data)
{
	Value buffer = self.buffer_copy(data)!;
	return self.typed_array(kind, buffer, 0, data.len / kind.size);
}

// ---- promises, jobs, collection, hooks ----

fn JsPromise* promise_of(Value v) @local
{
	if (!v.is_object() || v.as_object().kind != PROMISE) return null;
	return (JsPromise*)v.as_object();
}

fn PromiseState promise_state(Value v)
{
	JsPromise* p = promise_of(v);
	if (!p) return NOT_A_PROMISE;
	switch (p.state)
	{
		case PENDING: return PENDING;
		case FULFILLED: return FULFILLED;
		case REJECTED: return REJECTED;
	}
}

<*
 A settled promise's value or rejection reason; undefined while it is pending. Reading a
 rejection counts as handling it, so it isn't reported as unhandled.
*>
fn Value Engine.promise_result(&self, Value v)
{
	JsPromise* p = promise_of(v);
	if (!p || p.state == PENDING) return UNDEFINED;
	if (p.state == REJECTED && !p.handled)
	{
		self.vm.forget_unhandled(p);
		p.handled = true;
	}
	return p.result;
}

<*
 Run one queued promise job.

 @return "False when the queue was empty"
 @return? THREW : "The job threw (a queueMicrotask callback)"
*>
fn bool? Engine.step_job(&self)
{
	bool? ran = self.vm.run_job();
	if (catch ran) return THREW~;
	return ran;
}

fn bool Engine.jobs_waiting(&self) => self.vm.jobs_waiting();

<*
 Collect garbage now. Does nothing from inside a host function.
*>
fn void Engine.collect(&self)
{
	if (self.vm.native_depth == 0) self.vm.collect();
}

<*
 Do up to budget_us microseconds of collection work now, in time the host has to spare.
 Does nothing from inside a host function.
*>
fn void Engine.gc_step(&self, long budget_us) => self.vm.gc_step(budget_us * 1000);

<*
 Ask handler, now and then while a script runs, whether to stop it (non-zero stops it with an
 uncatchable error). Null clears it.
*>
fn void Engine.on_interrupt(&self, InterruptFn handler, void* opaque = null)
{
	Vm* vm = &self.vm;
	vm.interrupt = (rt::InterruptHandler)handler;
	vm.interrupt_runtime = self;
	vm.interrupt_opaque = opaque;
	vm.interrupt_countdown = rt::INTERRUPT_INTERVAL;
}

<*
 Install the module hooks, or clear them with null. They must outlive the engine.
*>
fn void Engine.on_modules(&self, ModuleHooks* hooks) => self.vm.module_hooks = hooks;
