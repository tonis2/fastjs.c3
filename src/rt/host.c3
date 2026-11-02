module fastjs::rt;
import std::collections::list;

// Objects an embedding host defines: each carries a pointer of the host's own data.

alias NativeFinalizer = fn void(void* data, void* opaque);

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
