module fastjs::rt;
import std::collections::list;

// What an embedding host plugs in besides plain functions: objects carrying its own data, and
// functions with typed number signatures that the VM calls without boxing anything.

alias NativeFinalizer = fn void(void* data, void* opaque);
// Numbers in, a number out: args holds argc numbers (missing ones are NaN up to the arity).
alias FastNumberFn = fn double(void* opaque, double* args, int argc);
// The same for a method of a native class: self_data is `this`'s host data.
alias FastMethodFn = fn double(void* opaque, void* self_data, double* args, int argc);

const uint MAX_FAST_ARGS = 32;

enum FastKind : char
{
	NONE,
	NUMBER,
	METHOD,
}

// What a fast function's double means to JS.
enum FastReturns : char
{
	NUMBER,
	BOOL,
	UNDEFINED,
}

<*
 A kind of host object. Its prototype is where the host puts methods. The finalizer runs when
 an instance is swept, or when the engine closes, and must not touch the engine.
*>
struct NativeClass
{
	String name;
	JsObject* proto;
	NativeFinalizer finalizer;
	void* opaque;
	uint id;
}

struct JsNative
{
	inline JsObject object;
	NativeClass* cls;
	void* data;
}

<*
 A new class of host objects; its id indexes Vm.native_classes.

 @return? THROWN
*>
fn NativeClass*? Vm.new_native_class(&self, String name, NativeFinalizer finalizer, void* opaque)
{
	NativeClass* c = mem::new(NativeClass);
	c.name = name.copy(mem);
	c.finalizer = finalizer;
	c.opaque = opaque;
	c.id = (uint)self.native_classes.len();
	self.native_classes.push(c);
	c.proto = self.heap.new_object(self.object_proto) ?? self.oom()~!;
	return c;
}

<*
 @return? THROWN
*>
fn JsNative*? Vm.new_native_object(&self, NativeClass* cls, void* data)
{
	JsNative* n = (JsNative*)self.heap.new_object(cls.proto, NATIVE, JsNative::size) ?? self.oom()~!;
	n.cls = cls;
	n.data = data;
	return n;
}

<*
 v's host data when it is an instance of cls, else null.
*>
fn void* native_data_of(Value v, NativeClass* cls) @inline
{
	if (!v.is_object()) return null;
	JsObject* o = v.as_object();
	if (o.kind != NATIVE || ((JsNative*)o).cls != cls) return null;
	return ((JsNative*)o).data;
}

fn void finalize_native(JsNative* n)
{
	if (n.cls.finalizer && n.data) n.cls.finalizer(n.data, n.cls.opaque);
	n.data = null;
}

<*
 How every fast host function is called: the arguments become a C array of doubles and the
 host's function is called directly. host_fn holds it, magic its FastKind and native_data2's
 int its FastReturns; a method's class id is native_data's int.
*>
fn Value? native_fast_call(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double[MAX_FAST_ARGS] buf @noinit;
	usz n = args.len < MAX_FAST_ARGS ? args.len : MAX_FAST_ARGS;
	for (usz i = 0; i < n; i++)
	{
		Value a = args[i];
		if (a.is_int())
		{
			buf[i] = (double)a.as_int();
		}
		else if (a.is_double())
		{
			buf[i] = a.as_double();
		}
		else
		{
			buf[i] = vm.to_number(a)!;
		}
	}
	usz arity = callee.native_arity < MAX_FAST_ARGS ? callee.native_arity : MAX_FAST_ARGS;
	for (usz i = n; i < arity; i++) buf[i] = bitcast(CANONICAL_NAN, double);
	vm.host_raised = false;
	double r;
	if ((FastKind)callee.magic == METHOD)
	{
		NativeClass* cls = vm.native_classes[callee.native_data.as_int()];
		void* data = native_data_of(this_value, cls);
		if (!data) return vm.throw_error(TYPE_ERROR, "%s.%s called on an object that is not a live %s", cls.name, callee.native_name, cls.name)~;
		r = ((FastMethodFn)callee.host_fn)(callee.host_opaque, data, &buf, (int)n);
	}
	else
	{
		r = ((FastNumberFn)callee.host_fn)(callee.host_opaque, &buf, (int)n);
	}
	if (vm.host_raised)
	{
		vm.host_raised = false;
		return THROWN~;
	}
	switch ((FastReturns)callee.native_data2.as_int())
	{
		case NUMBER: return number(r);
		case BOOL: return boolean(r != 0);
		case UNDEFINED: return UNDEFINED;
	}
}

<*
 A function the VM calls through native_fast_call.

 @return? THROWN
*>
fn JsFunction*? Vm.new_fast_function(&self, String name, void* body, uint arity, void* opaque, FastKind kind, FastReturns returns, NativeClass* cls = null)
{
	JsFunction* f = self.new_native(name, &native_fast_call, arity)!;
	f.host_fn = body;
	f.host_opaque = opaque;
	f.magic = (int)kind.ordinal;
	f.native_data = cls ? integer((int)cls.id) : UNDEFINED;
	f.native_data2 = integer((int)returns.ordinal);
	return f;
}
