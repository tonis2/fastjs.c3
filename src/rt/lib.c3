module fastjs::rt;
import std::math, std::core::dstring, std::collections::list, std::time;

// The standard library: Object, Array, String, Number, Math, JSON, Function, Symbol, Reflect.

fn Value? Vm.str_value(&self, String s) => string_value(self.heap.string_from_utf8(s) ?? self.oom()~!);

fn void? Vm.define_getter(&self, JsObject* obj, String name, NativeFn getter)
{
	JsFunction* f = self.new_native(string::tformat("get %s", name).copy(mem), getter, 0)!;
	self.owned_names.push(f.native_name);
	self.define_accessor(obj, self.atom_value(name)!, object_value(f), UNDEFINED, METHOD_PROP) ?? OUT_OF_MEMORY~!;
}

// ---- generic array-like access, with fast paths for real arrays and typed arrays ----

fn uint? Vm.length_of(&self, Value o)
{
	if (o.is_object())
	{
		JsObject* obj = o.as_object();
		if (obj.kind == ARRAY) return ((JsArray*)obj).length;
		if (obj.kind == TYPED_ARRAY) return ((JsTypedArray*)obj).length;
	}
	double d = self.to_number(self.get(o, self.atoms.length)!)!;
	if (d != d || d <= 0) return 0;
	return d >= 4294967295.0 ? uint::max - 1 : (uint)d;
}

fn bool? Vm.has_index(&self, Value o, uint i)
{
	if (o.is_object())
	{
		JsObject* obj = o.as_object();
		if (obj.kind == ARRAY) return ((JsArray*)obj).get(i) != EMPTY || (obj.proto() != self.array_proto && self.has_property(o, integer((int)i))!);
		if (obj.kind == TYPED_ARRAY) return i < ((JsTypedArray*)obj).length;
	}
	if (o.is_string()) return i < o.as_string().len;
	return self.has_property(o, integer((int)i));
}

fn Value? Vm.index_get(&self, Value o, uint i)
{
	if (o.is_object())
	{
		JsObject* obj = o.as_object();
		if (obj.kind == ARRAY)
		{
			Value v = ((JsArray*)obj).get(i);
			if (v != EMPTY) return v;
		}
		else if (obj.kind == TYPED_ARRAY)
		{
			JsTypedArray* t = (JsTypedArray*)obj;
			return i < t.length ? t.get(i) : UNDEFINED;
		}
	}
	return self.get(o, integer((int)i));
}

fn Value? Vm.callback(&self, Value[] args, String method)
{
	Value f = arg(args, 0);
	if (!f.is_function()) return self.throw_error(TYPE_ERROR, "%s is not a function", self.describe(f))~;
	return f;
}

fn JsArray*? Vm.new_js_array(&self, uint capacity = 0) => self.heap.new_array(self.array_proto, capacity) ?? self.oom()~;

// ---- Object ----

fn Value? native_object_values(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return vm.object_entries(arg(args, 0), (int)callee.magic);
}

<*
 Object.keys (0), values (1) and entries (2).
*>
fn Value? Vm.object_entries(&self, Value v, int which)
{
	if (v.is_nullish()) return self.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	JsArray* out = self.new_js_array()!;
	if (!v.is_object()) return object_value(out);
	List {Value} keys;
	keys.init(mem);
	defer keys.free();
	self.own_keys(v.as_object(), &keys)!;
	foreach (key : keys)
	{
		Value name = key.is_int() ? string_value(self.to_string(key)!) : key;
		switch (which)
		{
			case 0: out.push(name);
			case 1: out.push(self.get(v, key)!);
			default: out.push(self.pair(name, self.get(v, key)!)!);
		}
	}
	return object_value(out);
}

fn Value? native_object_assign(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	if (!target.is_object()) return vm.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	foreach (src : args[1..])
	{
		if (!src.is_object()) continue;
		List {Value} keys;
		keys.init(mem);
		defer keys.free();
		vm.own_keys(src.as_object(), &keys, true)!;
		foreach (key : keys) vm.set(target, key, vm.get(src, key)!)!;
	}
	return target;
}

fn Value? native_object_freeze(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (!v.is_object()) return v;
	JsObject* o = v.as_object();
	uint n = o.shape.count;
	if (n)
	{
		Shape*[] nodes = mem::new_array(Shape*, n);
		defer free(nodes);
		o.shape.nodes(nodes);
		foreach (node : nodes)
		{
			if (node.key.is_private_key()) continue;
			PropFlags f = node.flags;
			f.configurable = false;
			if (!f.accessor) f.writable = false;
			if (f != node.flags) o.reshape(&vm.heap, EMPTY, node.key, f) ?? vm.oom()~!;
		}
	}
	o.frozen_extensions = true;
	if (o.kind == ARRAY) ((JsArray*)o).frozen = true;
	return v;
}

fn Value? native_object_is_frozen(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (!v.is_object()) return TRUE;
	JsObject* o = v.as_object();
	if (!o.frozen_extensions) return FALSE;
	for (Shape* s = o.shape; s.parent; s = s.parent)
	{
		if (s.key.is_private_key()) continue;
		if (s.flags.configurable || (!s.flags.accessor && s.flags.writable)) return FALSE;
	}
	return TRUE;
}

fn Value? native_object_prevent_extensions(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_object()) v.as_object().frozen_extensions = true;
	return v;
}

<*
 Apply one property descriptor, as Object.defineProperty does.
*>
fn void? Vm.define_from_descriptor(&self, Value target, Value key, Value desc)
{
	if (!desc.is_object()) return self.throw_error(TYPE_ERROR, "Property description must be an object: %s", self.describe(desc))~;
	JsObject* o = target.as_object();
	Shape* existing = o.find_own(key);
	PropFlags old = existing ? existing.flags : {};
	PropFlags flags = old;
	Value v;
	if (self.has_property(desc, self.atom_value("enumerable")!)!) flags.enumerable = truthy(self.get(desc, self.atom_value("enumerable")!)!);
	if (self.has_property(desc, self.atom_value("configurable")!)!) flags.configurable = truthy(self.get(desc, self.atom_value("configurable")!)!);
	if (existing && !old.configurable)
	{
		// A non-configurable property may only have its value changed, and only if writable.
		bool has_value = self.has_property(desc, self.atoms.value)!;
		if (!has_value || old.accessor || !old.writable) return self.throw_error(TYPE_ERROR, "Cannot redefine property: %s", self.key_text(key))~;
	}
	Value getter = self.get(desc, self.atom_value("get")!)!;
	Value setter = self.get(desc, self.atom_value("set")!)!;
	if (!getter.is_undefined() || !setter.is_undefined())
	{
		if (!getter.is_undefined() && !getter.is_function()) return self.throw_error(TYPE_ERROR, "Getter must be a function: %s", self.describe(getter))~;
		if (!setter.is_undefined() && !setter.is_function()) return self.throw_error(TYPE_ERROR, "Setter must be a function: %s", self.describe(setter))~;
		flags.writable = false;
		if (existing && !old.accessor) o.remove(&self.heap, key) ?? self.oom()~!;
		self.define_accessor(o, key, getter, setter, flags)!;
		return;
	}
	if (self.has_property(desc, self.atom_value("writable")!)!) flags.writable = truthy(self.get(desc, self.atom_value("writable")!)!);
	flags.accessor = false;
	if (self.has_property(desc, self.atoms.value)!)
	{
		v = self.get(desc, self.atoms.value)!;
	}
	else
	{
		v = existing && !old.accessor ? o.slots[existing.slot()] : UNDEFINED;
	}
	if (o.kind == ARRAY && key.is_int())
	{
		((JsArray*)o).set((uint)key.as_int(), v);
		return;
	}
	if (existing && old.accessor) o.remove(&self.heap, key) ?? self.oom()~!;
	self.define(o, key, v, flags)!;
}

fn Value? native_object_define_property(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	if (!target.is_object()) return vm.throw_error(TYPE_ERROR, "Object.defineProperty called on non-object")~;
	vm.define_from_descriptor(target, vm.to_key(arg(args, 1))!, arg(args, 2))!;
	return target;
}

fn Value? native_object_define_properties(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	Value props = arg(args, 1);
	if (!target.is_object()) return vm.throw_error(TYPE_ERROR, "Object.defineProperties called on non-object")~;
	if (!props.is_object()) return target;
	List {Value} keys;
	keys.init(mem);
	defer keys.free();
	vm.own_keys(props.as_object(), &keys, true)!;
	foreach (key : keys) vm.define_from_descriptor(target, key, vm.get(props, key)!)!;
	return target;
}

fn Value? native_object_get_own_property_descriptor(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	if (!target.is_object()) return UNDEFINED;
	Value key = vm.to_key(arg(args, 1))!;
	JsObject* o = target.as_object();
	JsObject* d = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
	if (o.kind == ARRAY && key.is_int())
	{
		Value v = ((JsArray*)o).get((uint)key.as_int());
		if (v == EMPTY) return UNDEFINED;
		vm.define(d, vm.atoms.value, v)!;
		foreach (name : (String[3]){ "writable", "enumerable", "configurable" }) vm.define(d, vm.atom_value(name)!, TRUE)!;
		return object_value(d);
	}
	if (o.kind == ARRAY && key == vm.atoms.length)
	{
		vm.define(d, vm.atoms.value, integer((int)((JsArray*)o).length))!;
		vm.define(d, vm.atom_value("writable")!, TRUE)!;
		vm.define(d, vm.atom_value("enumerable")!, FALSE)!;
		vm.define(d, vm.atom_value("configurable")!, FALSE)!;
		return object_value(d);
	}
	Shape* s = o.find_own(key);
	if (!s) return UNDEFINED;
	if (s.flags.accessor)
	{
		Accessor* acc = (Accessor*)o.slots[s.slot()].as_object();
		vm.define(d, vm.atom_value("get")!, acc.getter)!;
		vm.define(d, vm.atom_value("set")!, acc.setter)!;
	}
	else
	{
		vm.define(d, vm.atoms.value, o.slots[s.slot()])!;
		vm.define(d, vm.atom_value("writable")!, boolean(s.flags.writable))!;
	}
	vm.define(d, vm.atom_value("enumerable")!, boolean(s.flags.enumerable))!;
	vm.define(d, vm.atom_value("configurable")!, boolean(s.flags.configurable))!;
	return object_value(d);
}

<*
 Every own property's descriptor, keyed by name (symbols included).
*>
fn Value? native_object_get_own_property_descriptors(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	if (target.is_nullish()) return vm.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	JsObject* out = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
	if (!target.is_object()) return object_value(out);
	JsObject* o = target.as_object();
	List {Value} keys;
	keys.init(mem);
	defer keys.free();
	if (o.kind == ARRAY)
	{
		JsArray* a = (JsArray*)o;
		for (uint i = 0; i < a.length; i++)
		{
			if (a.elements[i] != EMPTY) keys.push(integer((int)i));
		}
		keys.push(vm.atoms.length);
	}
	uint n = o.shape.count;
	Shape*[] nodes = mem::new_array(Shape*, n ? n : 1);
	defer free(nodes);
	o.shape.nodes(nodes);
	foreach (node : nodes[:n])
	{
		if (!node.key.is_private_key()) keys.push(node.key);
	}
	foreach (key : keys)
	{
		Value[2] dargs = { target, key };
		Value d = native_object_get_own_property_descriptor(vm, UNDEFINED, &dargs, callee)!;
		if (!d.is_undefined()) vm.define(out, key, d)!;
	}
	return object_value(out);
}

fn Value? native_object_get_own_property_names(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	JsArray* out = vm.new_js_array()!;
	if (!v.is_object()) return object_value(out);
	JsObject* o = v.as_object();
	if (o.kind == ARRAY)
	{
		JsArray* a = (JsArray*)o;
		for (uint i = 0; i < a.length; i++)
		{
			if (a.elements[i] != EMPTY) out.push(string_value(vm.to_string(integer((int)i))!));
		}
		out.push(vm.atoms.length);
	}
	uint n = o.shape.count;
	Shape*[] nodes = mem::new_array(Shape*, n ? n : 1);
	defer free(nodes);
	o.shape.nodes(nodes);
	foreach (node : nodes[:n])
	{
		if (node.key.is_symbol()) continue;
		out.push(node.key.is_int() ? string_value(vm.to_string(node.key)!) : node.key);
	}
	return object_value(out);
}

fn Value? native_object_create(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value proto = arg(args, 0);
	if (!proto.is_object() && !proto.is_null()) return vm.throw_error(TYPE_ERROR, "Object prototype may only be an Object or null: %s", vm.describe(proto))~;
	JsObject* o = vm.heap.new_object(proto.is_null() ? null : proto.as_object()) ?? vm.oom()~!;
	Value props = arg(args, 1);
	if (props.is_object())
	{
		Value[2] define_args = { object_value(o), props };
		(void)native_object_define_properties(vm, UNDEFINED, &define_args, callee)!;
	}
	return object_value(o);
}

fn Value? native_object_set_prototype_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	Value proto = arg(args, 1);
	if (!proto.is_object() && !proto.is_null()) return vm.throw_error(TYPE_ERROR, "Object prototype may only be an Object or null: %s", vm.describe(proto))~;
	if (!target.is_object()) return target;
	target.as_object().set_proto(&vm.heap, proto.is_null() ? null : proto.as_object()) ?? vm.oom()~!;
	return target;
}

fn Value? native_object_from_entries(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsObject* o = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
	JsArray* entries = vm.iterable_to_array(arg(args, 0))!;
	for (uint i = 0; i < entries.length; i++)
	{
		Value e = entries.elements[i];
		vm.define(o, vm.to_key(vm.get(e, integer(0))!)!, vm.get(e, integer(1))!)!;
	}
	return object_value(o);
}

fn bool same_value(Value a, Value b)
{
	if (a.is_number() && b.is_number())
	{
		double x = a.as_number();
		double y = b.as_number();
		if (x != x && y != y) return true;
		if (x == 0 && y == 0) return bitcast(x, ulong) == bitcast(y, ulong);
		return x == y;
	}
	return strict_equals(a, b);
}

fn Value? native_object_is(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => boolean(same_value(arg(args, 0), arg(args, 1)));

fn Value? native_object_has_own(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value[1] key = { arg(args, 1) };
	return native_has_own_property(vm, arg(args, 0), &key, callee);
}

fn Value? native_object_value_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => this_value;

fn Value? native_object_is_prototype_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (!v.is_object() || !this_value.is_object()) return FALSE;
	for (JsObject* o = v.as_object().proto(); o; o = o.proto())
	{
		if (o == this_value.as_object()) return TRUE;
	}
	return FALSE;
}

fn Value? native_property_is_enumerable(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object()) return FALSE;
	Value key = vm.to_key(arg(args, 0))!;
	JsObject* o = this_value.as_object();
	if (o.kind == ARRAY && key.is_int()) return boolean(((JsArray*)o).get((uint)key.as_int()) != EMPTY);
	Shape* s = o.find_own(key);
	return boolean(s && s.flags.enumerable);
}

// ---- Function ----

fn Value? native_function_call(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return vm.call(this_value, arg(args, 0), args.len > 1 ? args[1..] : (Value[]){});
}

fn Value? native_function_apply(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value list = arg(args, 1);
	if (list.is_nullish()) return vm.call(this_value, arg(args, 0), {});
	uint n = vm.length_of(list)!;
	Value[] call_args = mem::new_array(Value, n ? n : 1)[:n];
	defer free(call_args);
	for (uint i = 0; i < n; i++) call_args[i] = vm.index_get(list, i)!;
	return vm.call(this_value, arg(args, 0), call_args);
}

fn Value? native_bound_call(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* bound = (JsArray*)callee.native_data2.as_object();
	uint n = bound.length + (uint)args.len;
	Value[] all = mem::new_array(Value, n ? n : 1)[:n];
	defer free(all);
	for (uint i = 0; i < bound.length; i++) all[i] = bound.elements[i];
	foreach (i, a : args) all[bound.length + i] = a;
	if (this_value == EMPTY) return vm.construct(callee.native_data, all);
	return vm.call(callee.native_data, callee.bound_this, all);
}

fn Value? native_function_bind(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_function()) return vm.throw_error(TYPE_ERROR, "Bind must be called on a function")~;
	JsFunction* target = (JsFunction*)this_value.as_object();
	JsArray* bound = vm.new_js_array()!;
	if (args.len > 1) foreach (a : args[1..]) bound.push(a);
	String name = string::format(mem, "bound %s", target.native ? target.native_name : target.proto.name);
	vm.owned_names.push(name);
	uint length = target.native ? target.native_arity : target.proto.length;
	JsFunction* f = vm.new_native(name, &native_bound_call, length > bound.length ? length - bound.length : 0)!;
	f.native_data = this_value;
	f.native_data2 = object_value(bound);
	f.bound_this = arg(args, 0);
	return object_value(f);
}

fn Value? native_function_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_function()) return vm.throw_error(TYPE_ERROR, "Function.prototype.toString requires that 'this' be a Function")~;
	JsFunction* f = (JsFunction*)this_value.as_object();
	if (f.proto && f.proto.source.len) return vm.str_value(f.proto.source);
	@pool()
	{
		String name = f.native ? f.native_name : f.proto.name;
		if (f.proto && f.proto.is_class_constructor) return vm.str_value(string::tformat("class %s { }", name));
		return vm.str_value(string::tformat("function %s() { [native code] }", name));
	};
}

// ---- Array ----

fn Value? native_array_from(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value src = arg(args, 0);
	Value map = arg(args, 1);
	if (src.is_nullish()) return vm.throw_error(TYPE_ERROR, "%s is not iterable", vm.describe(src))~;
	JsArray* out;
	if (src.is_string() || (src.is_object() && vm.get(src, vm.sym_iterator)!.is_function()))
	{
		out = vm.iterable_to_array(src)!;
	}
	else
	{
		uint n = vm.length_of(src)!;
		out = vm.new_js_array(n)!;
		for (uint i = 0; i < n; i++) out.push(vm.index_get(src, i)!);
	}
	if (map.is_function())
	{
		for (uint i = 0; i < out.length; i++)
		{
			Value[2] call_args = { out.elements[i], integer((int)i) };
			out.elements[i] = vm.call(map, arg(args, 2), &call_args)!;
		}
	}
	return object_value(out);
}

fn Value? native_array_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* out = vm.new_js_array((uint)args.len)!;
	foreach (a : args) out.push(a);
	return object_value(out);
}

fn Value? native_array_shift(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "shift")!;
	if (a.length == 0) return UNDEFINED;
	Value v = a.elements[0];
	mem::move(a.elements, a.elements + 1, (usz)(a.length - 1) * Value::size);
	a.length--;
	return v == EMPTY ? UNDEFINED : v;
}

fn Value? native_array_unshift(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "unshift")!;
	uint n = (uint)args.len;
	a.reserve(a.length + n);
	mem::move(a.elements + n, a.elements, (usz)a.length * Value::size);
	foreach (i, v : args) a.elements[i] = v;
	a.length += n;
	return integer((int)a.length);
}

fn Value? native_array_splice(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "splice")!;
	uint len = a.length;
	uint start = vm.relative_index(arg(args, 0), len, 0)!;
	uint remove;
	if (args.len == 0)
	{
		remove = 0;
	}
	else if (args.len == 1)
	{
		remove = len - start;
	}
	else
	{
		double d = vm.to_number(args[1])!;
		remove = d != d || d < 0 ? 0 : (uint)math::min(d, (double)(len - start));
	}
	JsArray* removed = vm.new_js_array(remove)!;
	for (uint i = 0; i < remove; i++) removed.push(a.elements[start + i]);
	uint insert = args.len > 2 ? (uint)args.len - 2 : 0;
	uint new_len = len - remove + insert;
	a.reserve(new_len);
	mem::move(a.elements + start + insert, a.elements + start + remove, (usz)(len - start - remove) * Value::size);
	for (uint i = 0; i < insert; i++) a.elements[start + i] = args[2 + i];
	a.length = new_len;
	return object_value(removed);
}

fn Value? native_array_slice(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	uint len = vm.length_of(this_value)!;
	uint start = vm.relative_index(arg(args, 0), len, 0)!;
	uint end = vm.relative_index(arg(args, 1), len, len)!;
	JsArray* out = vm.new_js_array(end > start ? end - start : 0)!;
	for (uint i = start; i < end; i++) out.push(vm.has_index(this_value, i)! ? vm.index_get(this_value, i)! : EMPTY);
	return object_value(out);
}

fn Value? native_array_concat(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* out = vm.new_js_array()!;
	Value[] parts = mem::new_array(Value, args.len + 1);
	defer free(parts);
	parts[0] = this_value;
	foreach (i, a : args) parts[i + 1] = a;
	foreach (part : parts)
	{
		if (part.is_object() && part.as_object().kind == ARRAY)
		{
			JsArray* src = (JsArray*)part.as_object();
			for (uint i = 0; i < src.length; i++) out.push(src.elements[i]);
			continue;
		}
		out.push(part);
	}
	return object_value(out);
}

fn Value? native_array_reverse(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "reverse")!;
	for (uint i = 0; i < a.length / 2; i++)
	{
		Value t = a.elements[i];
		a.elements[i] = a.elements[a.length - 1 - i];
		a.elements[a.length - 1 - i] = t;
	}
	return this_value;
}

fn Value? native_array_fill(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "fill")!;
	uint start = vm.relative_index(arg(args, 1), a.length, 0)!;
	uint end = vm.relative_index(arg(args, 2), a.length, a.length)!;
	for (uint i = start; i < end; i++) a.elements[i] = arg(args, 0);
	return this_value;
}

fn Value? native_array_copy_within(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "copyWithin")!;
	uint len = a.length;
	uint to = vm.relative_index(arg(args, 0), len, 0)!;
	uint from = vm.relative_index(arg(args, 1), len, 0)!;
	uint end = arg(args, 2).is_undefined() ? len : vm.relative_index(args[2], len, len)!;
	if (end > from && to < len)
	{
		uint count = min(end - from, len - to);
		mem::move(a.elements + to, a.elements + from, (usz)count * Value::size);
	}
	return this_value;
}

fn Value? native_array_last_index_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	uint len = vm.length_of(this_value)!;
	Value target = arg(args, 0);
	for (uint i = len; i > 0; i--)
	{
		if (vm.has_index(this_value, i - 1)! && strict_equals(vm.index_get(this_value, i - 1)!, target)) return integer((int)i - 1);
	}
	return integer(-1);
}

fn Value? native_array_includes(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	uint len = vm.length_of(this_value)!;
	Value target = arg(args, 0);
	for (uint i = vm.relative_index(arg(args, 1), len, 0)!; i < len; i++)
	{
		if (same_value_zero(vm.index_get(this_value, i)!, target)) return TRUE;
	}
	return FALSE;
}

<*
 forEach (0), map (1), filter (2), some (3), every (4), find (5), findIndex (6), findLast (7), findLastIndex (8).
*>
fn Value? native_array_iterate(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value fun = vm.callback(args, "callback")!;
	Value this_arg = arg(args, 1);
	uint len = vm.length_of(this_value)!;
	int mode = callee.magic;
	JsArray* out;
	if (mode == 1)
	{
		out = vm.new_js_array(len)!;
		out.set_length(len);
	}
	if (mode == 2) out = vm.new_js_array()!;
	bool backwards = mode == 7 || mode == 8;
	for (uint n = 0; n < len; n++)
	{
		uint i = backwards ? len - 1 - n : n;
		bool present = mode >= 5 || vm.has_index(this_value, i)!;
		if (!present) continue;
		Value v = vm.index_get(this_value, i)!;
		Value[3] call_args = { v, integer((int)i), this_value };
		Value r = vm.call(fun, this_arg, &call_args)!;
		switch (mode)
		{
			case 1: out.elements[i] = r;
			case 2: if (truthy(r)) out.push(v);
			case 3: if (truthy(r)) return TRUE;
			case 4: if (!truthy(r)) return FALSE;
			case 5: case 7: if (truthy(r)) return v;
			case 6: case 8: if (truthy(r)) return integer((int)i);
			default: break;
		}
	}
	switch (mode)
	{
		case 1: case 2: return object_value(out);
		case 3: return FALSE;
		case 4: return TRUE;
		case 6: case 8: return integer(-1);
		default: return UNDEFINED;
	}
}

fn Value? native_array_reduce(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value fun = vm.callback(args, "reducer")!;
	uint len = vm.length_of(this_value)!;
	bool right = callee.magic == 1;
	uint n = 0;
	Value acc;
	if (args.len >= 2)
	{
		acc = args[1];
	}
	else
	{
		bool found = false;
		for (; n < len; n++)
		{
			uint i = right ? len - 1 - n : n;
			if (vm.has_index(this_value, i)!)
			{
				acc = vm.index_get(this_value, i)!;
				found = true;
				n++;
				break;
			}
		}
		if (!found) return vm.throw_error(TYPE_ERROR, "Reduce of empty array with no initial value")~;
	}
	for (; n < len; n++)
	{
		uint i = right ? len - 1 - n : n;
		if (!vm.has_index(this_value, i)!) continue;
		Value[4] call_args = { acc, vm.index_get(this_value, i)!, integer((int)i), this_value };
		acc = vm.call(fun, UNDEFINED, &call_args)!;
	}
	return acc;
}

fn Value? native_array_index_of_generic(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	uint len = vm.length_of(this_value)!;
	Value target = arg(args, 0);
	for (uint i = vm.relative_index(arg(args, 1), len, 0)!; i < len; i++)
	{
		if (vm.has_index(this_value, i)! && strict_equals(vm.index_get(this_value, i)!, target)) return integer((int)i);
	}
	return integer(-1);
}

fn Value? native_array_join_generic(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	uint len = vm.length_of(this_value)!;
	JsString* sep = arg(args, 0).is_undefined() ? vm.heap.string_from_latin1(",") ?? vm.oom()~! : vm.to_string(args[0])!;
	@pool()
	{
		DString out;
		out.tinit();
		for (uint i = 0; i < len; i++)
		{
			if (i > 0) sep.to_utf8(&out);
			Value v = vm.index_get(this_value, i)!;
			if (v.is_nullish()) continue;
			vm.to_string(v)!.to_utf8(&out);
		}
		return vm.str_value(out.str_view());
	};
}

fn Value? native_array_at(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	uint len = vm.length_of(this_value)!;
	double d = arg(args, 0).is_undefined() ? 0 : math::trunc(vm.to_number(args[0])!);
	if (d != d) d = 0;
	if (d < 0) d += len;
	if (d < 0 || d >= len) return UNDEFINED;
	return vm.index_get(this_value, (uint)d);
}

fn void? Vm.flatten_into(&self, JsArray* out, Value src, double depth)
{
	uint len = self.length_of(src)!;
	for (uint i = 0; i < len; i++)
	{
		if (!self.has_index(src, i)!) continue;
		Value v = self.index_get(src, i)!;
		if (depth > 0 && v.is_object() && v.as_object().kind == ARRAY)
		{
			self.flatten_into(out, v, depth - 1)!;
			continue;
		}
		out.push(v);
	}
}

fn Value? native_array_flat(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double depth = arg(args, 0).is_undefined() ? 1 : vm.to_number(args[0])!;
	JsArray* out = vm.new_js_array()!;
	vm.flatten_into(out, this_value, depth)!;
	return object_value(out);
}

fn Value? native_array_flat_map(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value fun = vm.callback(args, "flatMap")!;
	uint len = vm.length_of(this_value)!;
	JsArray* out = vm.new_js_array()!;
	for (uint i = 0; i < len; i++)
	{
		if (!vm.has_index(this_value, i)!) continue;
		Value[3] call_args = { vm.index_get(this_value, i)!, integer((int)i), this_value };
		Value r = vm.call(fun, arg(args, 1), &call_args)!;
		if (r.is_object() && r.as_object().kind == ARRAY)
		{
			vm.flatten_into(out, r, 0)!;
			continue;
		}
		out.push(r);
	}
	return object_value(out);
}

<*
 The default sort order: undefined last, everything else compared as strings.
*>
fn int? Vm.sort_compare(&self, Value a, Value b, Value fun)
{
	if (a.is_undefined()) return b.is_undefined() ? 0 : 1;
	if (b.is_undefined()) return -1;
	if (fun.is_function())
	{
		Value[2] call_args = { a, b };
		double d = self.to_number(self.call(fun, UNDEFINED, &call_args)!)!;
		return d < 0 ? -1 : d > 0 ? 1 : 0;
	}
	if (a.is_int() && b.is_int() && a.as_int() >= 0 && b.as_int() >= 0)
	{
		// Non-negative ints compare as their decimal strings: compare digit by digit.
		char[16] x;
		char[16] y;
		String sx = string::bformat(&x, "%d", a.as_int());
		String sy = string::bformat(&y, "%d", b.as_int());
		sz n = min(sx.len, sy.len);
		for (sz i = 0; i < n; i++)
		{
			if (sx[i] != sy[i]) return sx[i] < sy[i] ? -1 : 1;
		}
		return sx.len < sy.len ? -1 : sx.len > sy.len ? 1 : 0;
	}
	return self.to_string(a)!.compare(self.to_string(b)!);
}

fn void? Vm.merge_sort(&self, Value[] items, Value[] tmp, Value fun)
{
	if (items.len < 2) return;
	usz mid = items.len / 2;
	self.merge_sort(items[:mid], tmp[:mid], fun)!;
	self.merge_sort(items[mid..], tmp[mid..], fun)!;
	usz i = 0;
	usz j = mid;
	usz k = 0;
	while (i < mid && j < items.len)
	{
		// <= keeps equal elements in their original order (a stable sort).
		if (self.sort_compare(items[i], items[j], fun)! <= 0)
		{
			tmp[k++] = items[i++];
		}
		else
		{
			tmp[k++] = items[j++];
		}
	}
	while (i < mid) tmp[k++] = items[i++];
	while (j < items.len) tmp[k++] = items[j++];
	items[..] = tmp[:items.len];
}

fn Value? native_array_sort(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value fun = arg(args, 0);
	if (!fun.is_undefined() && !fun.is_function()) return vm.throw_error(TYPE_ERROR, "The comparison function must be either a function or undefined")~;
	JsArray* a = vm.this_array(this_value, "sort")!;
	// Holes move to the end; the rest are sorted.
	uint n = 0;
	for (uint i = 0; i < a.length; i++)
	{
		if (a.elements[i] != EMPTY) a.elements[n++] = a.elements[i];
	}
	for (uint i = n; i < a.length; i++) a.elements[i] = EMPTY;
	Value[] items = a.elements[:n];
	Value[] tmp = mem::new_array(Value, n ? n : 1);
	defer free(tmp);
	vm.merge_sort(items, tmp, fun)!;
	return this_value;
}

fn Value? native_array_iterator(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value.is_nullish()) return vm.throw_error(TYPE_ERROR, "Array iterator called on null or undefined")~;
	return vm.new_iterator(this_value, (IterKind)callee.magic);
}

// ---- String ----

fn JsString*? Vm.arg_string(&self, Value[] args, usz i) => self.to_string(arg(args, i));

fn int string_index_of(JsString* s, JsString* needle, uint from)
{
	if (needle.len == 0) return from <= s.len ? (int)from : (int)s.len;
	if (needle.len > s.len) return -1;
	for (uint i = from; i + needle.len <= s.len; i++)
	{
		bool match = true;
		for (uint j = 0; j < needle.len; j++)
		{
			if (s.at(i + j) != needle.at(j))
			{
				match = false;
				break;
			}
		}
		if (match) return (int)i;
	}
	return -1;
}

fn Value? native_string_index_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	JsString* needle = vm.arg_string(args, 0)!;
	uint from = vm.relative_index(arg(args, 1), s.len, 0)!;
	if (!arg(args, 1).is_undefined() && vm.to_number(args[1])! < 0) from = 0;
	return integer(string_index_of(s, needle, from));
}

fn Value? native_string_last_index_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	JsString* needle = vm.arg_string(args, 0)!;
	int best = -1;
	for (uint i = 0; i + needle.len <= s.len; i++)
	{
		int at = string_index_of(s, needle, i);
		if (at < 0) break;
		best = at;
		i = (uint)at;
	}
	return integer(best);
}

fn Value? native_string_includes(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	if (arg(args, 0).is_object() && arg(args, 0).as_object().kind == REGEXP) return vm.throw_error(TYPE_ERROR, "First argument to String.prototype.includes must not be a regular expression")~;
	return boolean(string_index_of(s, vm.arg_string(args, 0)!, vm.relative_index(arg(args, 1), s.len, 0)!) >= 0);
}

fn Value? native_string_starts_with(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	JsString* p = vm.arg_string(args, 0)!;
	uint at = vm.relative_index(arg(args, 1), s.len, 0)!;
	if (at + p.len > s.len) return FALSE;
	for (uint i = 0; i < p.len; i++)
	{
		if (s.at(at + i) != p.at(i)) return FALSE;
	}
	return TRUE;
}

fn Value? native_string_ends_with(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	JsString* p = vm.arg_string(args, 0)!;
	uint end = vm.relative_index(arg(args, 1), s.len, s.len)!;
	if (p.len > end) return FALSE;
	for (uint i = 0; i < p.len; i++)
	{
		if (s.at(end - p.len + i) != p.at(i)) return FALSE;
	}
	return TRUE;
}

fn Value? native_string_slice(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	uint start = vm.relative_index(arg(args, 0), s.len, 0)!;
	uint end = vm.relative_index(arg(args, 1), s.len, s.len)!;
	if (end <= start) return vm.atoms.empty;
	return string_value(vm.heap.substring(s, start, end) ?? vm.oom()~!);
}

fn Value? native_string_substring(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double a = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	double b = arg(args, 1).is_undefined() ? s.len : vm.to_number(args[1])!;
	if (a != a) a = 0;
	if (b != b) b = 0;
	uint start = (uint)math::min(math::max(a, 0.0), (double)s.len);
	uint end = (uint)math::min(math::max(b, 0.0), (double)s.len);
	if (start > end)
	{
		uint t = start;
		start = end;
		end = t;
	}
	return string_value(vm.heap.substring(s, start, end) ?? vm.oom()~!);
}

fn Value? native_string_char_at(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double i = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	if (i != i) i = 0;
	if (i < 0 || i >= s.len) return vm.atoms.empty;
	return string_value(vm.heap.substring(s, (uint)i, (uint)i + 1) ?? vm.oom()~!);
}

fn Value? native_string_code_point_at(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double d = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	if (d != d) d = 0;
	if (d < 0 || d >= s.len) return UNDEFINED;
	uint i = (uint)d;
	uint c = s.at(i);
	if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.len)
	{
		uint lo = s.at(i + 1);
		if (lo >= 0xDC00 && lo <= 0xDFFF) return integer((int)(0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)));
	}
	return integer((int)c);
}

fn Value? native_string_at(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double d = arg(args, 0).is_undefined() ? 0 : math::trunc(vm.to_number(args[0])!);
	if (d != d) d = 0;
	if (d < 0) d += s.len;
	if (d < 0 || d >= s.len) return UNDEFINED;
	return string_value(vm.heap.substring(s, (uint)d, (uint)d + 1) ?? vm.oom()~!);
}

fn Value? native_string_to_lower(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return string_value(vm.change_case(vm.this_string(this_value)!, false)!);
}

<*
 trim (0), trimStart (1), trimEnd (2).
*>
fn Value? native_string_trim(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	uint start = 0;
	uint end = s.len;
	if (callee.magic != 2) while (start < end && is_js_space(s.at(start))) start++;
	if (callee.magic != 1) while (end > start && is_js_space(s.at(end - 1))) end--;
	return string_value(vm.heap.substring(s, start, end) ?? vm.oom()~!);
}

fn Value? native_string_pad(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double target = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	JsString* fill = arg(args, 1).is_undefined() ? vm.heap.string_from_latin1(" ") ?? vm.oom()~! : vm.to_string(args[1])!;
	if (target <= s.len || fill.len == 0) return string_value(s);
	if (target > MAX_STRING_LENGTH) return vm.throw_error(RANGE_ERROR, "Invalid string length")~;
	uint need = (uint)target - s.len;
	@pool()
	{
		ushort[] units = mem::temp_array(ushort, (usz)need + s.len);
		bool at_start = callee.magic == 0;
		uint base = at_start ? 0 : s.len;
		for (uint i = 0; i < need; i++) units[base + i] = fill.at(i % fill.len);
		uint text = at_start ? need : 0;
		for (uint i = 0; i < s.len; i++) units[text + i] = s.at(i);
		return string_value(vm.heap.string_from_units(units) ?? vm.oom()~!);
	};
}

fn Value? native_string_repeat(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double n = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	if (n < 0 || n == double::inf) return vm.throw_error(RANGE_ERROR, "Invalid count value: %s", vm.describe(args[0]))~;
	if (n != n) n = 0;
	if (s.len == 0) return string_value(s);
	if (n * s.len > MAX_STRING_LENGTH) return vm.throw_error(RANGE_ERROR, "Invalid string length")~;
	uint count = (uint)n;
	@pool()
	{
		ushort[] units = mem::temp_array(ushort, (usz)count * s.len);
		for (uint r = 0; r < count; r++)
		{
			for (uint i = 0; i < s.len; i++) units[r * s.len + i] = s.at(i);
		}
		return string_value(vm.heap.string_from_units(units) ?? vm.oom()~!);
	};
}

fn Value? native_string_split(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	Value sep_value = arg(args, 0);
	if (sep_value.is_object() && sep_value.as_object().kind == REGEXP) return vm.regexp_split(s, sep_value, arg(args, 1));
	uint limit = arg(args, 1).is_undefined() ? uint::max : (uint)to_int32(vm.to_number(args[1])!);
	JsArray* out = vm.new_js_array()!;
	if (limit == 0) return object_value(out);
	if (sep_value.is_undefined())
	{
		out.push(string_value(s));
		return object_value(out);
	}
	JsString* sep = vm.to_string(sep_value)!;
	if (sep.len == 0)
	{
		for (uint i = 0; i < s.len && out.length < limit; i++) out.push(string_value(vm.heap.substring(s, i, i + 1) ?? vm.oom()~!));
		return object_value(out);
	}
	uint start = 0;
	while (out.length < limit)
	{
		int at = string_index_of(s, sep, start);
		if (at < 0)
		{
			out.push(string_value(vm.heap.substring(s, start, s.len) ?? vm.oom()~!));
			break;
		}
		out.push(string_value(vm.heap.substring(s, start, (uint)at) ?? vm.oom()~!));
		start = (uint)at + sep.len;
	}
	return object_value(out);
}

<*
 replace (0) and replaceAll (1) with a string pattern; regex patterns go to the regex engine.
*>
fn Value? native_string_replace(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	Value pattern = arg(args, 0);
	Value replacement = arg(args, 1);
	if (pattern.is_object() && pattern.as_object().kind == REGEXP) return vm.regexp_replace(s, pattern, replacement, callee.magic == 1);
	JsString* needle = vm.to_string(pattern)!;
	bool all = callee.magic == 1;
	@pool()
	{
		DString out;
		out.tinit();
		uint start = 0;
		while (true)
		{
			int at = string_index_of(s, needle, start);
			if (at < 0) break;
			vm.heap.substring(s, start, (uint)at)!!.to_utf8(&out);
			if (replacement.is_function())
			{
				Value[3] call_args = { string_value(needle), integer(at), string_value(s) };
				vm.to_string(vm.call(replacement, UNDEFINED, &call_args)!)!.to_utf8(&out);
			}
			else
			{
				vm.expand_replacement(&out, vm.to_string(replacement)!, s, (uint)at, (uint)at + needle.len, {})!;
			}
			start = (uint)at + needle.len;
			if (!all) break;
			if (needle.len == 0)
			{
				if (start >= s.len) break;
				vm.heap.substring(s, start, start + 1)!!.to_utf8(&out);
				start++;
			}
		}
		vm.heap.substring(s, start, s.len)!!.to_utf8(&out);
		return vm.str_value(out.str_view());
	};
}

<*
 Expand $&, $1..$99, $`, $' and $$ in a replacement string.
*>
fn void? Vm.expand_replacement(&self, DString* out, JsString* rep, JsString* s, uint match_start, uint match_end, Value[] groups)
{
	for (uint i = 0; i < rep.len; i++)
	{
		ushort c = rep.at(i);
		if (c != '$' || i + 1 >= rep.len)
		{
			append_code_point(out, c);
			continue;
		}
		ushort n = rep.at(i + 1);
		switch
		{
			case n == '$':
				out.append('$');
				i++;
			case n == '&':
				self.heap.substring(s, match_start, match_end)!!.to_utf8(out);
				i++;
			case n == '`':
				self.heap.substring(s, 0, match_start)!!.to_utf8(out);
				i++;
			case n == '\'':
				self.heap.substring(s, match_end, s.len)!!.to_utf8(out);
				i++;
			case n >= '0' && n <= '9':
				uint g = n - '0';
				uint used = 1;
				if (i + 2 < rep.len && rep.at(i + 2) >= '0' && rep.at(i + 2) <= '9' && (sz)(g * 10 + (rep.at(i + 2) - '0')) <= groups.len)
				{
					g = g * 10 + (rep.at(i + 2) - '0');
					used = 2;
				}
				if (g == 0 || g > groups.len)
				{
					out.append('$');
					break;
				}
				Value v = groups[g - 1];
				if (!v.is_undefined()) self.to_string(v)!.to_utf8(out);
				i += used;
			default:
				out.append('$');
		}
	}
}

fn Value? native_string_concat(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	foreach (a : args) s = vm.heap.concat(s, vm.to_string(a)!) ?? vm.oom()~!;
	return string_value(s);
}

fn Value? native_string_locale_compare(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	int c = vm.this_string(this_value)!.compare(vm.arg_string(args, 0)!);
	return integer(c < 0 ? -1 : c > 0 ? 1 : 0);
}

fn Value? native_string_from_char_code(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	@pool()
	{
		ushort[] units = mem::temp_array(ushort, args.len);
		foreach (i, a : args) units[i] = (ushort)to_int32(vm.to_number(a)!);
		return string_value(vm.heap.string_from_units(units) ?? vm.oom()~!);
	};
}

fn Value? native_string_from_code_point(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	@pool()
	{
		List {ushort} units;
		units.tinit();
		foreach (a : args)
		{
			double d = vm.to_number(a)!;
			if (d < 0 || d > 0x10FFFF || d != math::floor(d)) return vm.throw_error(RANGE_ERROR, "Invalid code point %s", vm.describe(a))~;
			push_code_point(&units, (uint)d);
		}
		return string_value(vm.heap.string_from_units(units.array_view()) ?? vm.oom()~!);
	};
}

// ---- Number and globals ----

fn Value? native_number_is_finite(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_int()) return TRUE;
	if (!v.is_double()) return FALSE;
	double d = v.as_double();
	return boolean(d == d && d != double::inf && d != -double::inf);
}

fn Value? native_number_is_nan(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	return boolean(v.is_double() && v.as_double() != v.as_double());
}

fn Value? native_number_is_safe_integer(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_int()) return TRUE;
	if (!v.is_double()) return FALSE;
	double d = v.as_double();
	return boolean(d == math::floor(d) && math::abs(d) <= 9007199254740991.0);
}

fn Value? native_global_is_nan(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double d = vm.to_number(arg(args, 0))!;
	return boolean(d != d);
}

fn Value? native_global_is_finite(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double d = vm.to_number(arg(args, 0))!;
	return boolean(d == d && d != double::inf && d != -double::inf);
}

fn Value? native_parse_float(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.to_string(arg(args, 0))!;
	uint i = 0;
	while (i < s.len && is_js_space(s.at(i))) i++;
	// The longest prefix that is a decimal literal (or Infinity).
	uint start = i;
	if (i < s.len && (s.at(i) == '+' || s.at(i) == '-')) i++;
	uint digits_start = i;
	@pool()
	{
		String rest = vm.heap.substring(s, i, s.len)!!.tutf8();
		if (rest.starts_with("Infinity"))
		{
			return double_value(s.at(start) == '-' ? -double::inf : double::inf);
		}
	};
	bool found_digit = false;
	while (i < s.len && s.at(i) >= '0' && s.at(i) <= '9')
	{
		i++;
		found_digit = true;
	}
	if (i < s.len && s.at(i) == '.')
	{
		i++;
		while (i < s.len && s.at(i) >= '0' && s.at(i) <= '9')
		{
			i++;
			found_digit = true;
		}
	}
	if (!found_digit) return double_value(double::nan);
	if (i < s.len && (s.at(i) | 0x20) == 'e')
	{
		uint save = i;
		i++;
		if (i < s.len && (s.at(i) == '+' || s.at(i) == '-')) i++;
		uint exp_start = i;
		while (i < s.len && s.at(i) >= '0' && s.at(i) <= '9') i++;
		if (i == exp_start) i = save;
	}
	if (digits_start == i) return double_value(double::nan);
	JsString* part = vm.heap.substring(s, start, i) ?? vm.oom()~!;
	return number(part.to_number());
}

fn Value? native_parse_int(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.to_string(arg(args, 0))!;
	int radix = arg(args, 1).is_undefined() ? 0 : vm.to_int32(args[1])!;
	uint i = 0;
	while (i < s.len && is_js_space(s.at(i))) i++;
	bool negative = false;
	if (i < s.len && (s.at(i) == '+' || s.at(i) == '-'))
	{
		negative = s.at(i) == '-';
		i++;
	}
	if (radix == 0 || radix == 16)
	{
		if (i + 1 < s.len && s.at(i) == '0' && (s.at(i + 1) | 0x20) == 'x')
		{
			i += 2;
			radix = 16;
		}
	}
	if (radix == 0) radix = 10;
	if (radix < 2 || radix > 36) return double_value(double::nan);
	double v = 0;
	bool found_digit = false;
	for (; i < s.len; i++)
	{
		ushort c = s.at(i);
		int d;
		switch
		{
			case c >= '0' && c <= '9': d = c - '0';
			case c >= 'a' && c <= 'z': d = c - 'a' + 10;
			case c >= 'A' && c <= 'Z': d = c - 'A' + 10;
			default: d = 99;
		}
		if (d >= radix) break;
		v = v * radix + d;
		found_digit = true;
	}
	if (!found_digit) return double_value(double::nan);
	return number(negative ? -v : v);
}

fn Value? native_number_to_string_radix(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_number()) return vm.throw_error(TYPE_ERROR, "Number.prototype.toString requires that 'this' be a Number")~;
	int radix = arg(args, 0).is_undefined() ? 10 : vm.to_int32(args[0])!;
	if (radix < 2 || radix > 36) return vm.throw_error(RANGE_ERROR, "toString() radix must be between 2 and 36")~;
	double d = this_value.as_number();
	if (radix == 10 || d != d || d == double::inf || d == -double::inf) return string_value(vm.to_string(this_value)!);
	char[1100] buf;
	usz pos = buf.len;
	bool negative = d < 0;
	if (negative) d = -d;
	double int_part = math::floor(d);
	double frac = d - int_part;
	// Fraction digits, up to 52 for a double; integer digits are written backwards.
	char[64] frac_digits;
	usz nfrac = 0;
	while (frac > 0 && nfrac < 52)
	{
		frac *= radix;
		int digit = (int)frac;
		frac -= digit;
		frac_digits[nfrac++] = "0123456789abcdefghijklmnopqrstuvwxyz"[digit];
	}
	do
	{
		double q = math::floor(int_part / radix);
		int digit = (int)(int_part - q * radix);
		buf[--pos] = "0123456789abcdefghijklmnopqrstuvwxyz"[digit];
		int_part = q;
	} while (int_part > 0 && pos > 1);
	if (negative) buf[--pos] = '-';
	@pool()
	{
		String text = (String)buf[pos..];
		if (nfrac) text = string::tformat("%s.%s", text, (String)frac_digits[:nfrac]);
		return vm.str_value(text);
	};
}

// ---- Math ----

fn double xorshift(ulong* state)
{
	ulong x = *state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	*state = x;
	return (double)(x >> 11) / 9007199254740992.0;
}

fn double js_round(double x)
{
	if (x != x || x == double::inf || x == -double::inf) return x;
	if (x >= -0.5 && x < 0) return -0.0;
	double r = math::floor(x);
	if (x - r >= 0.5) r += 1;
	return r;
}

<*
 The one-argument Math functions, chosen by magic.
*>
fn Value? native_math1(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	// Integer fast paths for the rounding family (floor, ceil, round, trunc: an
	// integer is already its own answer). Not abs, whose answer for a negative
	// integer is not itself.
	if (v.is_int() && callee.magic <= 3) return v;
	double x = vm.to_number(v)!;
	double r;
	switch (callee.magic)
	{
		case 0: r = math::floor(x);
		case 1: r = math::ceil(x);
		case 2: r = js_round(x);
		case 3: r = math::trunc(x);
		case 4: r = math::abs(x);
		case 5: r = math::sqrt(x);
		case 6: r = math::sin(x);
		case 7: r = math::cos(x);
		case 8: r = math::tan(x);
		case 9: r = math::asin(x);
		case 10: r = math::acos(x);
		case 11: r = math::atan(x);
		case 12: r = math::exp(x);
		case 13: r = math::ln(x);
		case 14: r = math::log2(x);
		case 15: r = math::log10(x);
		case 16: r = x != x ? x : x > 0 ? 1 : x < 0 ? -1 : x;
		case 17: r = x < 0 ? -math::pow(-x, 1.0 / 3.0) : math::pow(x, 1.0 / 3.0);
		case 18: r = (double)(float)x;
		case 19: r = math::sinh(x);
		case 20: r = math::cosh(x);
		case 21: r = math::tanh(x);
		case 22: r = math::ln(x + math::sqrt(x * x + 1));
		case 23: r = math::ln(x + math::sqrt(x * x - 1));
		case 24: r = 0.5 * math::ln((1 + x) / (1 - x));
		case 25: r = math::exp(x) - 1;
		case 26: r = math::ln(1 + x);
		case 27:
			uint u = (uint)to_int32(x);
			int n = 0;
			if (u == 0)
			{
				n = 32;
			}
			else
			{
				while (!(u & 0x8000_0000))
				{
					u <<= 1;
					n++;
				}
			}
			r = n;
		default: r = double::nan;
	}
	return number(r);
}

fn Value? native_math_pow(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => number(js_pow(vm.arg_number(args, 0)!, vm.arg_number(args, 1)!));
fn Value? native_math_atan2(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => number(math::atan2(vm.arg_number(args, 0)!, vm.arg_number(args, 1)!));
fn Value? native_math_imul(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => integer(vm.to_int32(arg(args, 0))! * vm.to_int32(arg(args, 1))!);
fn Value? native_math_random(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => double_value(xorshift(&vm.random_state));

fn Value? native_math_hypot(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double sum = 0;
	bool nan = false;
	foreach (a : args)
	{
		double d = vm.to_number(a)!;
		if (d == double::inf || d == -double::inf) return double_value(double::inf);
		if (d != d) nan = true;
		sum += d * d;
	}
	return nan ? double_value(double::nan) : number(math::sqrt(sum));
}

// ---- JSON ----

struct JsonWriter
{
	DString out;
	String indent;
	List {JsObject*} stack;
	Value replacer;
}

fn void json_quote(DString* out, JsString* s)
{
	out.append('"');
	for (uint i = 0; i < s.len; i++)
	{
		uint c = s.at(i);
		switch (c)
		{
			case '"': out.append("\\\"");
			case '\\': out.append("\\\\");
			case '\n': out.append("\\n");
			case '\r': out.append("\\r");
			case '\t': out.append("\\t");
			case 8: out.append("\\b");
			case 12: out.append("\\f");
			default:
				if (c < 0x20)
				{
					out.appendf("\\u%04x", c);
				}
				else if (c >= 0xD800 && c <= 0xDFFF)
				{
					// Keep valid surrogate pairs; escape lone halves.
					uint lo = i + 1 < s.len ? s.at(i + 1) : 0;
					if (c <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF)
					{
						append_code_point(out, 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00));
						i++;
					}
					else
					{
						out.appendf("\\u%04x", c);
					}
				}
				else
				{
					append_code_point(out, c);
				}
		}
	}
	out.append('"');
}

fn void JsonWriter.newline(&self, int depth)
{
	if (!self.indent.len) return;
	self.out.append('\n');
	for (int i = 0; i < depth; i++) self.out.append(self.indent);
}

<*
 Serialize v, or return false if it has no JSON form (undefined, functions, symbols).
*>
fn bool? Vm.json_write(&self, JsonWriter* w, Value holder, Value key, Value v, int depth)
{
	if (v.is_object())
	{
		Value to_json = self.get(v, self.atom_value("toJSON")!)!;
		if (to_json.is_function())
		{
			Value[1] call_args = { key.is_int() ? string_value(self.to_string(key)!) : key };
			v = self.call(to_json, v, &call_args)!;
		}
	}
	if (w.replacer.is_function())
	{
		Value[2] call_args = { key.is_int() ? string_value(self.to_string(key)!) : key, v };
		v = self.call(w.replacer, holder, &call_args)!;
	}
	switch
	{
		case v.is_null(): w.out.append("null");
		case v == TRUE: w.out.append("true");
		case v == FALSE: w.out.append("false");
		case v.is_string(): json_quote(&w.out, v.as_string());
		case v.is_number():
			double d = v.as_number();
			if (d != d || d == double::inf || d == -double::inf)
			{
				w.out.append("null");
			}
			else
			{
				char[40] buf;
				w.out.append(format_number(d, &buf));
			}
		case v.is_undefined() || v.is_symbol() || v.is_function():
			return false;
		default:
			JsObject* o = v.as_object();
			if (w.stack.contains(o)) return self.throw_error(TYPE_ERROR, "Converting circular structure to JSON")~;
			w.stack.push(o);
			defer (void)w.stack.pop();
			// Typed arrays aren't arrays to JSON: they serialize as objects keyed by index.
			if (o.kind == ARRAY)
			{
				uint len = self.length_of(v)!;
				w.out.append('[');
				for (uint i = 0; i < len; i++)
				{
					if (i > 0) w.out.append(',');
					w.newline(depth + 1);
					if (!self.json_write(w, v, integer((int)i), self.index_get(v, i)!, depth + 1)!) w.out.append("null");
				}
				if (len) w.newline(depth);
				w.out.append(']');
				return true;
			}
			List {Value} keys;
			keys.init(mem);
			defer keys.free();
			self.own_keys(o, &keys)!;
			w.out.append('{');
			bool first = true;
			foreach (k : keys)
			{
				sz mark = w.out.len();
				if (!first) w.out.append(',');
				w.newline(depth + 1);
				JsString* name = self.to_string(k)!;
				json_quote(&w.out, name);
				w.out.append(w.indent.len ? ": " : ":");
				if (!self.json_write(w, v, k, self.get(v, k)!, depth + 1)!)
				{
					// No JSON form: drop the key as well.
					w.out.chop(mark);
					continue;
				}
				first = false;
			}
			if (!first) w.newline(depth);
			w.out.append('}');
	}
	return true;
}

fn Value? native_json_stringify(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsonWriter w;
	w.out.init(mem);
	defer w.out.free();
	w.stack.init(mem);
	defer w.stack.free();
	w.replacer = arg(args, 1);
	Value space = arg(args, 2);
	char[10] indent;
	if (space.is_number())
	{
		int n = (int)math::min(10.0, math::max(0.0, space.as_number()));
		for (int i = 0; i < n; i++) indent[i] = ' ';
		w.indent = (String)indent[:n];
	}
	else if (space.is_string())
	{
		@pool()
		{
			String s = space.as_string().tutf8();
			sz n = min(s.len, 10);
			indent[:n] = s[:n];
			w.indent = (String)indent[:n];
		};
	}
	JsObject* wrapper = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
	if (!vm.json_write(&w, object_value(wrapper), vm.atoms.empty, arg(args, 0), 0)!) return UNDEFINED;
	return vm.str_value(w.out.str_view());
}

struct JsonReader
{
	String text;
	usz pos;
}

fn void JsonReader.skip_space(&self)
{
	while (self.pos < self.text.len)
	{
		char c = self.text[self.pos];
		if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return;
		self.pos++;
	}
}

fn fault Vm.json_error(&self, JsonReader* r)
{
	if (r.pos >= r.text.len) return self.throw_error(SYNTAX_ERROR, "Unexpected end of JSON input");
	return self.throw_error(SYNTAX_ERROR, "Unexpected token '%c', \"%s\" is not valid JSON", r.text[r.pos], r.text.len > 30 ? string::tformat("%s...", r.text[:30]) : r.text);
}

fn Value? Vm.json_read(&self, JsonReader* r, int depth)
{
	if (depth > 1000) return self.throw_error(RANGE_ERROR, "JSON nested too deeply")~;
	r.skip_space();
	if (r.pos >= r.text.len) return self.json_error(r)~;
	char c = r.text[r.pos];
	switch
	{
		case c == '{':
			r.pos++;
			JsObject* o = self.heap.new_object(self.object_proto) ?? self.oom()~!;
			r.skip_space();
			if (r.pos < r.text.len && r.text[r.pos] == '}')
			{
				r.pos++;
				return object_value(o);
			}
			while (true)
			{
				r.skip_space();
				if (r.pos >= r.text.len || r.text[r.pos] != '"') return self.json_error(r)~;
				Value key = self.to_key(self.json_read(r, depth + 1)!)!;
				r.skip_space();
				if (r.pos >= r.text.len || r.text[r.pos] != ':') return self.json_error(r)~;
				r.pos++;
				self.define(o, key, self.json_read(r, depth + 1)!)!;
				r.skip_space();
				if (r.pos < r.text.len && r.text[r.pos] == ',')
				{
					r.pos++;
					continue;
				}
				if (r.pos < r.text.len && r.text[r.pos] == '}')
				{
					r.pos++;
					return object_value(o);
				}
				return self.json_error(r)~;
			}
		case c == '[':
			r.pos++;
			JsArray* a = self.new_js_array()!;
			r.skip_space();
			if (r.pos < r.text.len && r.text[r.pos] == ']')
			{
				r.pos++;
				return object_value(a);
			}
			while (true)
			{
				a.push(self.json_read(r, depth + 1)!);
				r.skip_space();
				if (r.pos < r.text.len && r.text[r.pos] == ',')
				{
					r.pos++;
					continue;
				}
				if (r.pos < r.text.len && r.text[r.pos] == ']')
				{
					r.pos++;
					return object_value(a);
				}
				return self.json_error(r)~;
			}
		case c == '"':
			usz start = ++r.pos;
			bool escaped = false;
			while (r.pos < r.text.len && r.text[r.pos] != '"')
			{
				if (r.text[r.pos] < 0x20) return self.json_error(r)~;
				if (r.text[r.pos] == '\\')
				{
					escaped = true;
					r.pos++;
					if (r.pos >= r.text.len) return self.json_error(r)~;
					switch (r.text[r.pos])
					{
						case '"': case '\\': case '/': case 'b': case 'f': case 'n': case 'r': case 't':
							break;
						case 'u':
							for (int i = 1; i <= 4; i++)
							{
								if (r.pos + (usz)i >= r.text.len || hex_digit(r.text[r.pos + (usz)i]) < 0) return self.json_error(r)~;
							}
							r.pos += 4;
						default:
							return self.json_error(r)~;
					}
				}
				r.pos++;
			}
			if (r.pos >= r.text.len) return self.json_error(r)~;
			String raw = r.text[start:r.pos - start];
			r.pos++;
			// JSON escapes are a subset of JS string escapes, except \/ which cook() keeps as /.
			JsString* s = escaped ? self.heap.cook(raw, false) ?? self.oom()~! : self.heap.string_from_utf8(raw) ?? self.oom()~!;
			return string_value(s);
		case c == 't' && r.text[r.pos..].starts_with("true"):
			r.pos += 4;
			return TRUE;
		case c == 'f' && r.text[r.pos..].starts_with("false"):
			r.pos += 5;
			return FALSE;
		case c == 'n' && r.text[r.pos..].starts_with("null"):
			r.pos += 4;
			return NULL;
		case c == '-' || (c >= '0' && c <= '9'):
			usz start = r.pos;
			if (r.text[r.pos] == '-') r.pos++;
			if (r.pos >= r.text.len || r.text[r.pos] < '0' || r.text[r.pos] > '9') return self.json_error(r)~;
			if (r.text[r.pos] == '0' && r.pos + 1 < r.text.len && r.text[r.pos + 1] >= '0' && r.text[r.pos + 1] <= '9') return self.json_error(r)~;
			while (r.pos < r.text.len && r.text[r.pos] >= '0' && r.text[r.pos] <= '9') r.pos++;
			if (r.pos < r.text.len && r.text[r.pos] == '.')
			{
				r.pos++;
				usz frac = r.pos;
				while (r.pos < r.text.len && r.text[r.pos] >= '0' && r.text[r.pos] <= '9') r.pos++;
				if (frac == r.pos) return self.json_error(r)~;
			}
			if (r.pos < r.text.len && (r.text[r.pos] | 0x20) == 'e')
			{
				r.pos++;
				if (r.pos < r.text.len && (r.text[r.pos] == '+' || r.text[r.pos] == '-')) r.pos++;
				usz exp = r.pos;
				while (r.pos < r.text.len && r.text[r.pos] >= '0' && r.text[r.pos] <= '9') r.pos++;
				if (exp == r.pos) return self.json_error(r)~;
			}
			return number(r.text[start:r.pos - start].to_double() ?? double::nan);
		default:
			return self.json_error(r)~;
	}
}

fn Value? native_json_parse(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	@pool()
	{
		JsonReader r = { .text = vm.to_string(arg(args, 0))!.tutf8() };
		Value v = vm.json_read(&r, 0)!;
		r.skip_space();
		if (r.pos != r.text.len) return vm.json_error(&r)~;
		Value reviver = arg(args, 1);
		if (!reviver.is_function()) return v;
		// The spec's InternalizeJSONProperty: the reviver sees every value bottom-up, with its
		// holder as `this`, starting from a wrapper object { "": v }.
		JsObject* root = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
		vm.define(root, vm.atoms.empty, v)!;
		return vm.json_revive(object_value(root), vm.atoms.empty, reviver);
	};
}

<*
 @return? THROWN
*>
fn Value? Vm.json_revive(&self, Value holder, Value key, Value reviver)
{
	Value val = self.get(holder, key)!;
	if (val.is_object() && !val.is_function())
	{
		JsObject* o = val.as_object();
		if (o.kind == ARRAY)
		{
			uint n = self.length_of(val)!;
			for (uint i = 0; i < n; i++) self.json_revive_into(val, integer((int)i), reviver)!;
		}
		else
		{
			List {Value} keys;
			keys.init(mem);
			defer keys.free();
			self.own_keys(o, &keys)!;
			foreach (k : keys) self.json_revive_into(val, k, reviver)!;
		}
	}
	Value name = key.is_int() ? string_value(self.to_string(key)!) : key;
	Value[2] call_args = { name, val };
	return self.call(reviver, holder, &call_args);
}

fn void? Vm.json_revive_into(&self, Value holder, Value key, Value reviver)
{
	Value revived = self.json_revive(holder, key, reviver)!;
	if (revived.is_undefined())
	{
		(void)self.delete_property(holder, key)!;
		return;
	}
	self.define(holder.as_object(), key, revived)!;
}

<*
 String.raw(strings, ...subs): strings.raw interleaved with the substitutions.
*>
fn Value? native_string_raw(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value strings = arg(args, 0);
	if (strings.is_nullish()) return vm.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	Value raw = vm.get(strings, vm.atoms.raw)!;
	if (raw.is_nullish()) return vm.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	uint n = vm.length_of(raw)!;
	JsString* out = vm.atoms.empty.as_string();
	for (uint i = 0; i < n; i++)
	{
		out = vm.heap.concat(out, vm.to_string(vm.index_get(raw, i)!)!) ?? vm.oom()~!;
		if (i + 1 < n && (usz)i + 1 < args.len) out = vm.heap.concat(out, vm.to_string(args[i + 1])!) ?? vm.oom()~!;
	}
	return string_value(out);
}

// ---- Symbol, Reflect, Boolean, Date ----

fn Value? native_symbol(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value == EMPTY) return vm.throw_error(TYPE_ERROR, "Symbol is not a constructor")~;
	Value d = arg(args, 0);
	return vm.new_symbol(d.is_undefined() ? UNDEFINED : string_value(vm.to_string(d)!)) ?? vm.oom()~;
}

fn Value? native_symbol_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_symbol()) return vm.throw_error(TYPE_ERROR, "Symbol.prototype.toString requires that 'this' be a Symbol")~;
	@pool()
	{
		return vm.str_value(vm.symbol_text(this_value));
	};
}

fn Value? native_symbol_description(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_symbol()) return UNDEFINED;
	return this_value.as_symbol().description;
}

fn Value? native_reflect_construct(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = arg(args, 0);
	Value list = arg(args, 1);
	uint n = list.is_nullish() ? 0 : vm.length_of(list)!;
	Value[] call_args = mem::new_array(Value, n ? n : 1)[:n];
	defer free(call_args);
	for (uint i = 0; i < n; i++) call_args[i] = vm.index_get(list, i)!;
	Value new_target = args.len > 2 ? args[2] : target;
	return vm.construct(target, call_args, new_target);
}

fn Value? native_reflect_has(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => boolean(vm.has_property(arg(args, 0), vm.to_key(arg(args, 1))!)!);

fn Value? native_reflect_own_keys(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (!v.is_object()) return vm.throw_error(TYPE_ERROR, "Reflect.ownKeys called on non-object")~;
	JsArray* out = vm.new_js_array()!;
	JsObject* o = v.as_object();
	uint n = o.shape.count;
	Shape*[] nodes = mem::new_array(Shape*, n ? n : 1);
	defer free(nodes);
	o.shape.nodes(nodes);
	foreach (node : nodes[:n])
	{
		if (!node.key.is_private_key()) out.push(node.key.is_int() ? string_value(vm.to_string(node.key)!) : node.key);
	}
	return object_value(out);
}

fn Value? native_boolean_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_bool()) return vm.throw_error(TYPE_ERROR, "Boolean.prototype.toString requires that 'this' be a Boolean")~;
	return this_value == TRUE ? vm.atoms.true_str : vm.atoms.false_str;
}

fn Value? native_boolean_value_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => this_value;


fn Value? native_performance_now(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return double_value((double)vm.start_clock.to_now() / 1_000_000.0);
}

fn void? Vm.init_lib(&self)
{
	Heap* h = &self.heap;
	JsObject* global = self.global;

	// Symbol first: iterator methods are keyed by it.
	self.symbol_proto = h.new_object(self.object_proto)!;
	JsFunction* symbol_ctor = self.define_constructor("Symbol", &native_symbol, 0, self.symbol_proto)!;
	self.sym_iterator = self.new_symbol(self.str_value("Symbol.iterator") ?? UNDEFINED)!;
	self.sym_async_iterator = self.new_symbol(self.str_value("Symbol.asyncIterator") ?? UNDEFINED)!;
	self.define_value(symbol_ctor, "iterator", self.sym_iterator, {})!;
	self.define_value(symbol_ctor, "asyncIterator", self.sym_async_iterator, {})!;
	self.sym_metadata = self.new_symbol(self.str_value("Symbol.metadata") ?? UNDEFINED)!;
	self.define_value(symbol_ctor, "metadata", self.sym_metadata, {})!;
	self.sym_species = self.new_symbol(self.str_value("Symbol.species") ?? UNDEFINED)!;
	self.define_value(symbol_ctor, "species", self.sym_species, {})!;
	self.sym_to_primitive = self.new_symbol(self.str_value("Symbol.toPrimitive") ?? UNDEFINED)!;
	self.define_value(symbol_ctor, "toPrimitive", self.sym_to_primitive, {})!;
	self.define_native(self.symbol_proto, "toString", &native_symbol_to_string, 0)!;
	self.define_getter(self.symbol_proto, "description", &native_symbol_description)!;

	self.iterator_proto = h.new_object(self.object_proto)!;
	self.define_native(self.iterator_proto, "next", &native_iterator_next, 0)!;
	JsFunction* self_iter = self.new_native("[Symbol.iterator]", &native_return_this, 0)!;
	self.iterator_proto.add(h, self.sym_iterator, object_value(self_iter), METHOD_PROP)!;

	JsFunction* object_ctor = (JsFunction*)self.get(object_value(global), self.atom_value("Object")!)!!.as_object();
	self.define_native(object_ctor, "values", &native_object_values, 1)!.magic = 1;
	self.define_native(object_ctor, "entries", &native_object_values, 1)!.magic = 2;
	self.define_native(object_ctor, "assign", &native_object_assign, 2)!;
	self.define_native(object_ctor, "freeze", &native_object_freeze, 1)!;
	self.define_native(object_ctor, "isFrozen", &native_object_is_frozen, 1)!;
	self.define_native(object_ctor, "preventExtensions", &native_object_prevent_extensions, 1)!;
	self.define_native(object_ctor, "seal", &native_object_prevent_extensions, 1)!;
	self.define_native(object_ctor, "defineProperty", &native_object_define_property, 3)!;
	self.define_native(object_ctor, "defineProperties", &native_object_define_properties, 2)!;
	self.define_native(object_ctor, "getOwnPropertyDescriptor", &native_object_get_own_property_descriptor, 2)!;
	self.define_native(object_ctor, "getOwnPropertyNames", &native_object_get_own_property_names, 1)!;
	self.define_native(object_ctor, "getOwnPropertyDescriptors", &native_object_get_own_property_descriptors, 1)!;
	self.define_native(object_ctor, "create", &native_object_create, 2)!;
	self.define_native(object_ctor, "setPrototypeOf", &native_object_set_prototype_of, 2)!;
	self.define_native(object_ctor, "fromEntries", &native_object_from_entries, 1)!;
	self.define_native(object_ctor, "is", &native_object_is, 2)!;
	self.define_native(object_ctor, "hasOwn", &native_object_has_own, 2)!;
	self.define_native(self.object_proto, "valueOf", &native_object_value_of, 0)!;
	self.define_native(self.object_proto, "isPrototypeOf", &native_object_is_prototype_of, 1)!;
	self.define_native(self.object_proto, "propertyIsEnumerable", &native_property_is_enumerable, 1)!;
	self.define_native(self.object_proto, "toLocaleString", &native_object_to_string, 0)!;

	self.define_native(self.function_proto, "call", &native_function_call, 1)!;
	self.define_native(self.function_proto, "apply", &native_function_apply, 2)!;
	self.define_native(self.function_proto, "bind", &native_function_bind, 1)!;
	self.define_native(self.function_proto, "toString", &native_function_to_string, 0)!;

	JsFunction* array_ctor = (JsFunction*)self.get(object_value(global), self.atom_value("Array")!)!!.as_object();
	self.define_native(array_ctor, "from", &native_array_from, 1)!;
	self.define_native(array_ctor, "of", &native_array_of, 0)!;
	JsObject* ap = self.array_proto;
	self.define_native(ap, "shift", &native_array_shift, 0)!;
	self.define_native(ap, "unshift", &native_array_unshift, 1)!;
	self.define_native(ap, "splice", &native_array_splice, 2)!;
	self.define_native(ap, "slice", &native_array_slice, 2)!;
	self.define_native(ap, "concat", &native_array_concat, 1)!;
	self.define_native(ap, "reverse", &native_array_reverse, 0)!;
	self.define_native(ap, "fill", &native_array_fill, 1)!;
	self.define_native(ap, "copyWithin", &native_array_copy_within, 2)!;
	self.define_native(ap, "lastIndexOf", &native_array_last_index_of, 1)!;
	self.define_native(ap, "includes", &native_array_includes, 1)!;
	self.define_native(ap, "indexOf", &native_array_index_of_generic, 1)!;
	self.define_native(ap, "join", &native_array_join_generic, 1)!;
	self.define_native(ap, "toString", &native_array_join_generic, 0)!;
	String[9] iterate_names = { "forEach", "map", "filter", "some", "every", "find", "findIndex", "findLast", "findLastIndex" };
	foreach (i, name : iterate_names) self.define_native(ap, name, &native_array_iterate, 1)!.magic = (int)i;
	self.define_native(ap, "reduce", &native_array_reduce, 1)!.magic = 0;
	self.define_native(ap, "reduceRight", &native_array_reduce, 1)!.magic = 1;
	self.define_native(ap, "at", &native_array_at, 1)!;
	self.define_native(ap, "flat", &native_array_flat, 0)!;
	self.define_native(ap, "flatMap", &native_array_flat_map, 1)!;
	self.define_native(ap, "sort", &native_array_sort, 1)!;
	self.define_native(ap, "keys", &native_array_iterator, 0)!.magic = (int)IterKind.ARRAY_KEYS.ordinal;
	self.define_native(ap, "entries", &native_array_iterator, 0)!.magic = (int)IterKind.ARRAY_ENTRIES.ordinal;
	JsFunction* values = self.define_native(ap, "values", &native_array_iterator, 0)!;
	values.magic = (int)IterKind.ARRAY_VALUES.ordinal;
	ap.add(h, self.sym_iterator, object_value(values), METHOD_PROP)!;

	JsObject* sp = self.string_proto;
	JsFunction* string_ctor = (JsFunction*)self.get(object_value(global), self.atom_value("String")!)!!.as_object();
	self.define_native(string_ctor, "fromCharCode", &native_string_from_char_code, 1)!;
	self.define_native(string_ctor, "raw", &native_string_raw, 1)!;
	self.define_native(string_ctor, "fromCodePoint", &native_string_from_code_point, 1)!;
	self.define_native(sp, "indexOf", &native_string_index_of, 1)!;
	self.define_native(sp, "lastIndexOf", &native_string_last_index_of, 1)!;
	self.define_native(sp, "includes", &native_string_includes, 1)!;
	self.define_native(sp, "startsWith", &native_string_starts_with, 1)!;
	self.define_native(sp, "endsWith", &native_string_ends_with, 1)!;
	self.define_native(sp, "slice", &native_string_slice, 2)!;
	self.define_native(sp, "substring", &native_string_substring, 2)!;
	self.define_native(sp, "charAt", &native_string_char_at, 1)!;
	self.define_native(sp, "codePointAt", &native_string_code_point_at, 1)!;
	self.define_native(sp, "at", &native_string_at, 1)!;
	self.define_native(sp, "toLowerCase", &native_string_to_lower, 0)!;
	self.define_native(sp, "trim", &native_string_trim, 0)!.magic = 0;
	self.define_native(sp, "trimStart", &native_string_trim, 0)!.magic = 1;
	self.define_native(sp, "trimEnd", &native_string_trim, 0)!.magic = 2;
	self.define_native(sp, "padStart", &native_string_pad, 2)!.magic = 0;
	self.define_native(sp, "padEnd", &native_string_pad, 2)!.magic = 1;
	self.define_native(sp, "repeat", &native_string_repeat, 1)!;
	self.define_native(sp, "split", &native_string_split, 2)!;
	self.define_native(sp, "replace", &native_string_replace, 2)!.magic = 0;
	self.define_native(sp, "replaceAll", &native_string_replace, 2)!.magic = 1;
	self.define_native(sp, "concat", &native_string_concat, 1)!;
	self.define_native(sp, "localeCompare", &native_string_locale_compare, 1)!;

	JsFunction* number_ctor = (JsFunction*)self.get(object_value(global), self.atom_value("Number")!)!!.as_object();
	self.define_native(number_ctor, "isFinite", &native_number_is_finite, 1)!;
	self.define_native(number_ctor, "isNaN", &native_number_is_nan, 1)!;
	self.define_native(number_ctor, "isSafeInteger", &native_number_is_safe_integer, 1)!;
	JsFunction* parse_float = self.define_native(number_ctor, "parseFloat", &native_parse_float, 1)!;
	JsFunction* parse_int = self.define_native(number_ctor, "parseInt", &native_parse_int, 2)!;
	global.add(h, self.atom_value("parseFloat")!, object_value(parse_float), METHOD_PROP)!;
	global.add(h, self.atom_value("parseInt")!, object_value(parse_int), METHOD_PROP)!;
	self.define_native(global, "isNaN", &native_global_is_nan, 1)!;
	self.define_native(global, "isFinite", &native_global_is_finite, 1)!;
	self.define_value(number_ctor, "MAX_SAFE_INTEGER", double_value(9007199254740991.0), {})!;
	self.define_value(number_ctor, "MIN_SAFE_INTEGER", double_value(-9007199254740991.0), {})!;
	self.define_value(number_ctor, "EPSILON", double_value(2.220446049250313e-16), {})!;
	self.define_value(number_ctor, "MAX_VALUE", double_value(1.7976931348623157e308), {})!;
	self.define_value(number_ctor, "MIN_VALUE", double_value(5e-324), {})!;
	self.define_value(number_ctor, "POSITIVE_INFINITY", double_value(double::inf), {})!;
	self.define_value(number_ctor, "NEGATIVE_INFINITY", double_value(-double::inf), {})!;
	self.define_value(number_ctor, "NaN", double_value(double::nan), {})!;
	Shape* to_string_node = self.number_proto.find_own(self.atoms.to_string);
	if (to_string_node) self.number_proto.slots[to_string_node.slot()] = object_value(self.new_native("toString", &native_number_to_string_radix, 1)!);

	JsObject* m = self.get(object_value(global), self.atom_value("Math")!)!!.as_object();
	String[28] math1 = { "floor", "ceil", "round", "trunc", "abs", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan",
		"exp", "log", "log2", "log10", "sign", "cbrt", "fround", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "expm1", "log1p", "clz32" };
	foreach (i, name : math1)
	{
		Value key = self.atom_value(name)!;
		JsFunction* f = self.new_native(name, &native_math1, 1)!;
		f.magic = (int)i;
		self.define(m, key, object_value(f), METHOD_PROP) ?? OUT_OF_MEMORY~!;
	}
	self.define_native(m, "pow", &native_math_pow, 2)!;
	self.define_native(m, "atan2", &native_math_atan2, 2)!;
	self.define_native(m, "imul", &native_math_imul, 2)!;
	self.define_native(m, "random", &native_math_random, 0)!;
	self.define_native(m, "hypot", &native_math_hypot, 2)!;
	self.define_value(m, "E", double_value(math::E), {})!;
	self.define_value(m, "LN2", double_value(math::LN2), {})!;
	self.define_value(m, "LN10", double_value(math::LN10), {})!;
	self.define_value(m, "LOG2E", double_value(math::LOG2E), {})!;
	self.define_value(m, "LOG10E", double_value(math::LOG10E), {})!;
	self.define_value(m, "SQRT2", double_value(math::SQRT2), {})!;
	self.define_value(m, "SQRT1_2", double_value(0.7071067811865476), {})!;
	self.random_state = 0x9E3779B97F4A7C15UL;

	JsObject* json = h.new_object(self.object_proto)!;
	self.define_value(global, "JSON", object_value(json))!;
	self.define_native(json, "stringify", &native_json_stringify, 3)!;
	self.define_native(json, "parse", &native_json_parse, 2)!;

	JsObject* reflect = h.new_object(self.object_proto)!;
	self.define_value(global, "Reflect", object_value(reflect))!;
	self.define_native(reflect, "construct", &native_reflect_construct, 2)!;
	self.define_native(reflect, "has", &native_reflect_has, 2)!;
	self.define_native(reflect, "ownKeys", &native_reflect_own_keys, 1)!;

	self.define_native(self.boolean_proto, "toString", &native_boolean_to_string, 0)!;
	self.define_native(self.boolean_proto, "valueOf", &native_boolean_value_of, 0)!;

	self.init_date()!;
	JsObject* performance = h.new_object(self.object_proto)!;
	self.define_value(global, "performance", object_value(performance))!;
	self.define_native(performance, "now", &native_performance_now, 0)!;
	self.start_clock = clock::now();

	self.init_collections()!;
	self.init_typed_arrays()!;
}
