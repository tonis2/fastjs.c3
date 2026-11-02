module fastjs::rt;
import std::collections::list;

// Proxy. three.c3's UI is built on one (a Widget *is* a Proxy whose set trap marks it dirty), and
// its uniform tables and tracked classes use them too, so they are supported: get, set, has,
// deleteProperty, ownKeys, getOwnPropertyDescriptor, defineProperty, getPrototypeOf, apply and
// construct.
//
// A proxy is a JsFunction-sized object with `is_proxy` set, its target in native_data and its
// handler in native_data2. A proxy of a function is a native function (kind FUNCTION), so calls and
// `new` reach native_proxy_call. Every proxy has the shape `proxy_shape` and its property traffic
// goes through the slow paths, which check `is_proxy` first; no inline cache is ever filled for
// that shape, so the fast paths can't bypass a trap. Nothing but proxies pays for this.

fn Value JsObject.proxy_target(&self) @inline => ((JsFunction*)self).native_data;
fn Value JsObject.proxy_handler(&self) @inline => ((JsFunction*)self).native_data2;

fn Value? native_proxy(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Constructor Proxy requires 'new'")~;
	Value target = arg(args, 0);
	Value handler = arg(args, 1);
	if (!target.is_object() || !handler.is_object()) return vm.throw_error(TYPE_ERROR, "Cannot create proxy with a non-object as target or handler")~;
	bool callable = target.is_function();
	JsFunction* p = (JsFunction*)vm.heap.new_object(vm.proxy_holder, callable ? FUNCTION : PROXY, JsFunction::size) ?? vm.oom()~!;
	p.is_proxy = true;
	p.fields_init = UNDEFINED;
	p.bound_this = UNDEFINED;
	p.native_data = target;
	p.native_data2 = handler;
	if (callable)
	{
		JsFunction* f = (JsFunction*)target.as_object();
		p.native = &native_proxy_call;
		p.native_name = f.native ? f.native_name : f.proto.name;
		p.native_arity = f.native ? f.native_arity : f.proto.length;
	}
	return object_value(p);
}

<*
 The handler's trap called name, or UNDEFINED when there is none.

 @return? THROWN
*>
fn Value? Vm.proxy_trap(&self, JsObject* p, String name)
{
	Value trap = self.get(p.proxy_handler(), self.atom_value(name)!)!;
	if (trap.is_nullish()) return UNDEFINED;
	if (!trap.is_function()) return self.throw_error(TYPE_ERROR, "proxy trap '%s' is not a function", name)~;
	return trap;
}

<*
 A canonical key as a trap sees it: index keys become strings.

 @return? THROWN
*>
fn Value? Vm.trap_key(&self, Value key)
{
	if (key.is_int()) return string_value(self.to_string(key)!);
	return key;
}

fn Value? Vm.proxy_get(&self, JsObject* p, Value key, Value receiver)
{
	Value trap = self.proxy_trap(p, "get")!;
	if (trap.is_undefined()) return self.get_from(p.proxy_target().as_object(), key, receiver);
	Value[3] args = { p.proxy_target(), self.trap_key(key)!, receiver };
	return self.call(trap, p.proxy_handler(), &args);
}

fn void? Vm.proxy_set(&self, JsObject* p, Value key, Value v, Value receiver)
{
	Value trap = self.proxy_trap(p, "set")!;
	if (trap.is_undefined()) return self.set(p.proxy_target(), key, v);
	Value[4] args = { p.proxy_target(), self.trap_key(key)!, v, receiver };
	if (!truthy(self.call(trap, p.proxy_handler(), &args)!))
	{
		return self.throw_error(TYPE_ERROR, "'set' on proxy: trap returned falsish for property '%s'", self.key_text(key))~;
	}
}

fn bool? Vm.proxy_has(&self, JsObject* p, Value key)
{
	Value trap = self.proxy_trap(p, "has")!;
	if (trap.is_undefined()) return self.has_property(p.proxy_target(), key);
	Value[2] args = { p.proxy_target(), self.trap_key(key)! };
	return truthy(self.call(trap, p.proxy_handler(), &args)!);
}

fn bool? Vm.proxy_delete(&self, JsObject* p, Value key)
{
	Value trap = self.proxy_trap(p, "deleteProperty")!;
	if (trap.is_undefined()) return self.delete_property(p.proxy_target(), key);
	Value[2] args = { p.proxy_target(), self.trap_key(key)! };
	if (!truthy(self.call(trap, p.proxy_handler(), &args)!))
	{
		return self.throw_error(TYPE_ERROR, "'deleteProperty' on proxy: trap returned falsish for property '%s'", self.key_text(key))~;
	}
	return true;
}

<*
 Define on a proxy: the defineProperty trap with a data descriptor, or the target.
*>
fn void? Vm.proxy_define(&self, JsObject* p, Value key, Value v, PropFlags flags)
{
	Value trap = self.proxy_trap(p, "defineProperty")!;
	if (trap.is_undefined()) return self.define(p.proxy_target().as_object(), key, v, flags);
	JsObject* desc = self.heap.new_object(self.object_proto) ?? self.oom()~!;
	self.define(desc, self.atoms.value, v)!;
	self.define(desc, self.atom_value("writable")!, boolean(flags.writable))!;
	self.define(desc, self.atom_value("enumerable")!, boolean(flags.enumerable))!;
	self.define(desc, self.atom_value("configurable")!, boolean(flags.configurable))!;
	Value[3] args = { p.proxy_target(), self.trap_key(key)!, object_value(desc) };
	(void)self.call(trap, p.proxy_handler(), &args)!;
}

<*
 A proxy's own enumerable keys: the ownKeys trap filtered through getOwnPropertyDescriptor (or
 the target's own flags), or the target's keys when there is no ownKeys trap.

 @return? THROWN
*>
fn void? Vm.proxy_own_keys(&self, JsObject* p, List {Value}* out, bool include_symbols)
{
	Value trap = self.proxy_trap(p, "ownKeys")!;
	if (trap.is_undefined()) return self.own_keys(p.proxy_target().as_object(), out, include_symbols);
	// The key list is held here across trap calls; no collection until we're done with it.
	self.native_depth++;
	defer self.native_depth--;
	Value[1] args = { p.proxy_target() };
	Value list = self.call(trap, p.proxy_handler(), &args)!;
	if (!list.is_object()) return self.throw_error(TYPE_ERROR, "CreateListFromArrayLike called on non-object")~;
	uint n = self.length_of(list)!;
	Value describe = self.proxy_trap(p, "getOwnPropertyDescriptor")!;
	for (uint i = 0; i < n; i++)
	{
		Value key = self.index_get(list, i)!;
		if (key.is_symbol() && !include_symbols) continue;
		Value canonical = self.to_key(key)!;
		bool enumerable;
		if (describe.is_undefined())
		{
			JsObject* t = p.proxy_target().as_object();
			Shape* s = t.find_own(canonical);
			enumerable = s ? s.flags.enumerable : (t.kind == ARRAY && canonical.is_int());
		}
		else
		{
			Value[2] dargs = { p.proxy_target(), self.trap_key(canonical)! };
			Value d = self.call(describe, p.proxy_handler(), &dargs)!;
			enumerable = d.is_object() && truthy(self.get(d, self.atom_value("enumerable")!)!);
		}
		if (enumerable) out.push(canonical);
	}
}

<*
 The prototype of o, asking a proxy's getPrototypeOf trap (or its target).

 @return? THROWN
*>
fn JsObject*? Vm.proto_of(&self, JsObject* o)
{
	if (!o.is_proxy) return o.proto();
	Value trap = self.proxy_trap(o, "getPrototypeOf")!;
	if (trap.is_undefined()) return self.proto_of(o.proxy_target().as_object());
	Value[1] args = { o.proxy_target() };
	Value proto = self.call(trap, o.proxy_handler(), &args)!;
	return proto.is_object() ? proto.as_object() : null;
}

fn bool? Vm.proxy_has_own(&self, JsObject* p, Value key)
{
	Value trap = self.proxy_trap(p, "getOwnPropertyDescriptor")!;
	if (trap.is_undefined())
	{
		JsObject* t = p.proxy_target().as_object();
		if (t.is_proxy) return self.proxy_has_own(t, key);
		if (t.kind == ARRAY && key.is_int()) return ((JsArray*)t).get((uint)key.as_int()) != EMPTY;
		return t.find_own(key) != null;
	}
	Value[2] args = { p.proxy_target(), self.trap_key(key)! };
	return !self.call(trap, p.proxy_handler(), &args)!.is_undefined();
}

// Calling or constructing a proxy of a function: the apply and construct traps.
fn Value? native_proxy_call(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsObject* p = (JsObject*)callee;
	Value target = p.proxy_target();
	bool construct = this_value == EMPTY;
	Value trap = vm.proxy_trap(p, construct ? "construct" : "apply")!;
	if (trap.is_undefined())
	{
		if (construct) return vm.construct(target, args, object_value(callee));
		return vm.call(target, this_value, args);
	}
	JsArray* list = vm.heap.new_array(vm.array_proto, (uint)args.len) ?? vm.oom()~!;
	foreach (a : args) list.push(a);
	if (construct)
	{
		Value[3] trap_args = { target, object_value(list), object_value(callee) };
		Value r = vm.call(trap, p.proxy_handler(), &trap_args)!;
		if (!r.is_object()) return vm.throw_error(TYPE_ERROR, "proxy [[Construct]] must return an object")~;
		return r;
	}
	Value[3] trap_args = { target, this_value, object_value(list) };
	return vm.call(trap, p.proxy_handler(), &trap_args);
}

fn void? Vm.init_proxy(&self)
{
	// Every proxy's shape hangs off this holder, so it's never shared with a real object's.
	self.proxy_holder = self.heap.new_object(null)!;
	self.define_constructor("Proxy", &native_proxy, 2, self.heap.new_object(self.object_proto)!)!;
}
