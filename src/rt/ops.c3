module fastjs::rt;
import std::math, std::core::dstring, std::collections::list, std::sort;

fn bool truthy(Value v)
{
	switch
	{
		case v.is_int(): return v.as_int() != 0;
		case v.is_double():
			double d = v.as_double();
			return d == d && d != 0;
		case v.is_string(): return v.as_string().len > 0;
		case v.is_object() || v.is_symbol(): return true;
		default: return v == TRUE;
	}
}

<*
 ToPrimitive: an object becomes the result of valueOf or toString (toString first for string hints).

 @return? THROWN
*>
fn Value? Vm.to_primitive(&self, Value v, bool prefer_string = false)
{
	if (!v.is_object()) return v;
	Value first = prefer_string ? self.atoms.to_string : self.atoms.value_of;
	Value second = prefer_string ? self.atoms.value_of : self.atoms.to_string;
	foreach (name : (Value[2]){ first, second })
	{
		Value method = self.get(v, name)!;
		if (!method.is_function()) continue;
		Value result = self.call(method, v, {})!;
		if (!result.is_object()) return result;
	}
	return self.throw_error(TYPE_ERROR, "Cannot convert object to primitive value")~;
}

<*
 @return? THROWN
*>
fn double? Vm.to_number(&self, Value v)
{
	switch
	{
		case v.is_int(): return (double)v.as_int();
		case v.is_double(): return v.as_double();
		case v.is_string(): return v.as_string().to_number();
		case v.is_undefined(): return double::nan;
		case v.is_null() || v == FALSE: return 0;
		case v == TRUE: return 1;
		case v.is_symbol(): return self.throw_error(TYPE_ERROR, "Cannot convert a Symbol value to a number")~;
		default: return self.to_number(self.to_primitive(v)!);
	}
}

<*
 @return? THROWN
*>
fn JsString*? Vm.to_string(&self, Value v)
{
	switch
	{
		case v.is_string(): return v.as_string();
		case v.is_int():
			int i = v.as_int();
			if (i >= 0 && i < 10)
			{
				char c = (char)('0' + i);
				return self.heap.string_from_latin1((&c)[:1]) ?? self.oom()~;
			}
			return self.heap.number_to_string((double)i) ?? self.oom()~;
		case v.is_double(): return self.heap.number_to_string(v.as_double()) ?? self.oom()~;
		case v.is_undefined(): return self.atoms.undefined_str.as_string();
		case v.is_null(): return self.atoms.null_str.as_string();
		case v == TRUE: return self.atoms.true_str.as_string();
		case v == FALSE: return self.atoms.false_str.as_string();
		case v.is_symbol(): return self.throw_error(TYPE_ERROR, "Cannot convert a Symbol value to a string")~;
		default: return self.to_string(self.to_primitive(v, true)!);
	}
}

<*
 Out of memory surfaces to scripts as a RangeError, like other engines' allocation limits.
*>
fn fault Vm.oom(&self)
{
	self.exception = self.atoms.empty;
	// The error itself is small; let it past the limit so the script gets a real RangeError.
	usz limit = self.heap.limit;
	self.heap.limit = 0;
	defer self.heap.limit = limit;
	return self.throw_error(RANGE_ERROR, "Out of memory");
}

<*
 A canonical property key: a non-negative int32 for array-index-like keys, else an atom or a symbol.
 Keeping one form means o[1] and o["1"] always find the same property.

 @return? THROWN
*>
fn Value? Vm.to_key(&self, Value v)
{
	switch
	{
		case v.is_int():
			if (v.as_int() >= 0) return v;
		case v.is_double():
			double d = v.as_double();
			if (d >= 0 && d <= (double)int::max && d == math::floor(d)) return integer((int)d);
		case v.is_string():
			JsString* s = v.as_string();
			uint index;
			if (s.array_index(&index) && index <= (uint)int::max) return integer((int)index);
			return string_value(self.heap.intern(s));
		case v.is_symbol():
			return v;
		default:
			break;
	}
	return self.to_key(string_value(self.to_string(self.to_primitive(v, true)!)!));
}

fn String Vm.key_text(&self, Value key)
{
	if (key.is_string()) return key.as_string().tutf8();
	if (key.is_int()) return string::tformat("%d", key.as_int());
	return self.symbol_text(key);
}

fn int to_int32(double d)
{
	if (d != d || d == double::inf || d == -double::inf) return 0;
	double m = math::trunc(d) % 4294967296.0;
	if (m < 0) m += 4294967296.0;
	return (int)(uint)(ulong)m;
}

<*
 @return? THROWN
*>
fn int? Vm.to_int32(&self, Value v) @inline
{
	if (v.is_int()) return v.as_int();
	return to_int32(self.to_number(v)!);
}

fn Value Vm.type_of(&self, Value v)
{
	switch
	{
		case v.is_number(): return self.atoms.number_str;
		case v.is_string(): return self.atoms.string_str;
		case v.is_undefined(): return self.atoms.undefined_str;
		case v.is_bool(): return self.atoms.boolean_str;
		case v.is_symbol(): return self.atoms.symbol_str;
		case v.is_function(): return self.atoms.function_str;
		default: return self.atoms.object_str;
	}
}

fn bool strict_equals(Value a, Value b)
{
	if (a.is_number() && b.is_number())
	{
		if (a.is_int() && b.is_int()) return a == b;
		return a.as_number() == b.as_number();
	}
	if (a.is_string() && b.is_string()) return a.as_string().equals(b.as_string());
	return a == b;
}

<*
 @return? THROWN
*>
fn bool? Vm.loose_equals(&self, Value a, Value b)
{
	while (true)
	{
		if (a.is_number() && b.is_number()) return strict_equals(a, b);
		if (a.is_string() && b.is_string()) return strict_equals(a, b);
		if (a.is_nullish() || b.is_nullish()) return a.is_nullish() && b.is_nullish();
		if (a.is_object() && b.is_object()) return a == b;
		if (a.is_symbol() || b.is_symbol()) return a == b;
		switch
		{
			case a.is_bool(): a = integer(a == TRUE ? 1 : 0);
			case b.is_bool(): b = integer(b == TRUE ? 1 : 0);
			case a.is_object(): a = self.to_primitive(a)!;
			case b.is_object(): b = self.to_primitive(b)!;
			case a.is_string(): a = double_value(a.as_string().to_number());
			case b.is_string(): b = double_value(b.as_string().to_number());
			default: return false;
		}
	}
}

<*
 The + operator: string concatenation if either side is a string after ToPrimitive, else addition.

 @return? THROWN
*>
fn Value? Vm.add(&self, Value a, Value b)
{
	if (a.is_number() && b.is_number()) return double_value(a.as_number() + b.as_number());
	if (a.is_string() && b.is_string()) return string_value(self.heap.concat(a.as_string(), b.as_string()) ?? self.oom()~);
	Value pa = self.to_primitive(a)!;
	Value pb = self.to_primitive(b)!;
	if (pa.is_string() || pb.is_string())
	{
		JsString* sa = self.to_string(pa)!;
		JsString* sb = self.to_string(pb)!;
		return string_value(self.heap.concat(sa, sb) ?? self.oom()~);
	}
	return double_value(self.to_number(pa)! + self.to_number(pb)!);
}

<*
 a < b, with undefined (NaN involved) reported as false. Strings compare by code units.

 @return? THROWN
*>
fn bool? Vm.less_than(&self, Value a, Value b, bool or_equal)
{
	if (a.is_int() && b.is_int()) return or_equal ? a.as_int() <= b.as_int() : a.as_int() < b.as_int();
	Value pa = self.to_primitive(a)!;
	Value pb = self.to_primitive(b)!;
	if (pa.is_string() && pb.is_string())
	{
		int c = pa.as_string().compare(pb.as_string());
		return or_equal ? c <= 0 : c < 0;
	}
	double x = self.to_number(pa)!;
	double y = self.to_number(pb)!;
	return or_equal ? x <= y : x < y;
}

fn double js_mod(double x, double y) => x % y;

fn double js_pow(double x, double y)
{
	// JS: 1 ** NaN and (+/-1) ** Infinity are NaN, where C's pow says 1.
	if (y != y) return double::nan;
	if ((x == 1 || x == -1) && (y == double::inf || y == -double::inf)) return double::nan;
	return math::pow(x, y);
}

// ---- property access ----

<*
 The `name`, `length` and lazily created `prototype` of a function, or EMPTY.

 @return? THROWN
*>
fn Value? Vm.function_special(&self, JsFunction* f, Value key)
{
	if (key == self.atoms.name)
	{
		String name = f.native ? f.native_name : f.proto.name;
		return string_value(self.heap.string_from_utf8(name) ?? self.oom()~);
	}
	if (key == self.atoms.length) return integer(f.native ? (int)f.native_arity : (int)f.proto.length);
	if (key == self.atoms.prototype && !f.native && f.proto.is_constructor())
	{
		JsObject* proto = self.heap.new_object(self.object_proto) ?? self.oom()~!;
		proto.add(&self.heap, self.atoms.constructor, object_value(f), METHOD_PROP) ?? self.oom()~!;
		f.add(&self.heap, self.atoms.prototype, object_value(proto), { .writable = true }) ?? self.oom()~!;
		return object_value(proto);
	}
	return EMPTY;
}

<*
 obj[key] with a canonical key, following prototypes and calling getters.

 @return? THROWN
*>
fn Value? Vm.get(&self, Value obj, Value key)
{
	JsObject* o;
	switch
	{
		case obj.is_object():
			o = obj.as_object();
		case obj.is_string():
			JsString* s = obj.as_string();
			if (key == self.atoms.length) return integer((int)s.len);
			if (key.is_int())
			{
				uint i = (uint)key.as_int();
				if (i >= s.len) return UNDEFINED;
				return string_value(self.heap.substring(s, i, i + 1) ?? self.oom()~);
			}
			o = self.string_proto;
		case obj.is_number():
			o = self.number_proto;
		case obj.is_bool():
			o = self.boolean_proto;
		case obj.is_symbol():
			o = self.symbol_proto;
		default:
			return self.throw_error(TYPE_ERROR, "Cannot read properties of %s (reading '%s')", self.describe(obj), self.key_text(key))~;
	}
	return self.get_from(o, key, obj);
}

<*
 Look key up starting at object o, calling getters with receiver as `this`. `super.x` starts
 at the home object's prototype this way.

 @return? THROWN
*>
fn Value? Vm.get_from(&self, JsObject* o, Value key, Value receiver)
{
	while (o)
	{
		if (o.is_proxy) return self.proxy_get(o, key, receiver);
		if (o.kind == ARRAY)
		{
			JsArray* arr = (JsArray*)o;
			if (key.is_int())
			{
				Value v = arr.get((uint)key.as_int());
				if (v != EMPTY) return v;
			}
			else if (key == self.atoms.length)
			{
				return number((double)arr.length);
			}
		}
		else if (o.kind == TYPED_ARRAY && key.is_int())
		{
			// Typed arrays own every index below their length, and nothing above it.
			JsTypedArray* t = (JsTypedArray*)o;
			uint i = (uint)key.as_int();
			return i < t.length ? t.get(i) : UNDEFINED;
		}
		Shape* s = o.find_own(key);
		if (s)
		{
			Value v = o.slots[s.slot()];
			if (!s.flags.accessor) return v;
			Accessor* acc = (Accessor*)v.as_object();
			if (acc.getter.is_undefined()) return UNDEFINED;
			return self.call(acc.getter, receiver, {});
		}
		if (o.kind == FUNCTION)
		{
			Value v = self.function_special((JsFunction*)o, key)!;
			if (v != EMPTY) return v;
		}
		o = o.proto();
	}
	return UNDEFINED;
}

<*
 obj[key] = v with a canonical key, calling setters and refusing read-only properties.

 @return? THROWN
*>
fn void? Vm.set(&self, Value obj, Value key, Value v)
{
	if (!obj.is_object())
	{
		if (obj.is_nullish()) return self.throw_error(TYPE_ERROR, "Cannot set properties of %s (setting '%s')", self.describe(obj), self.key_text(key))~;
		return;
	}
	JsObject* o = obj.as_object();
	if (o.is_proxy) return self.proxy_set(o, key, v, obj);
	if (o.kind == TYPED_ARRAY && key.is_int())
	{
		JsTypedArray* t = (JsTypedArray*)o;
		double d = self.to_number(v)!;
		if ((uint)key.as_int() < t.length) t.set_number((uint)key.as_int(), d);
		return;
	}
	if (o.kind == ARRAY)
	{
		JsArray* arr = (JsArray*)o;
		if (key.is_int())
		{
			if (arr.frozen) return self.throw_error(TYPE_ERROR, "Cannot assign to read only property '%d' of object", key.as_int())~;
			if (o.frozen_extensions && (uint)key.as_int() >= arr.length) return self.throw_error(TYPE_ERROR, "Cannot add property %d, object is not extensible", key.as_int())~;
			arr.set((uint)key.as_int(), v);
			self.heap.touch(arr);
			return;
		}
		if (key == self.atoms.length)
		{
			double d = self.to_number(v)!;
			if (d < 0 || d > 4294967295.0 || d != math::floor(d)) return self.throw_error(RANGE_ERROR, "Invalid array length")~;
			arr.set_length((uint)d);
			return;
		}
	}
	Shape* s = o.find_own(key);
	if (s)
	{
		if (s.flags.accessor) return self.call_setter(o.slots[s.slot()], obj, key, v);
		if (!s.flags.writable) return self.throw_error(TYPE_ERROR, "Cannot assign to read only property '%s' of object", self.key_text(key))~;
		o.slots[s.slot()] = v;
		self.heap.touch(o);
		return;
	}
	for (JsObject* p = o.proto(); p; p = p.proto())
	{
		Shape* ps = p.find_own(key);
		if (!ps) continue;
		if (ps.flags.accessor) return self.call_setter(p.slots[ps.slot()], obj, key, v);
		if (!ps.flags.writable) return self.throw_error(TYPE_ERROR, "Cannot assign to read only property '%s' of object", self.key_text(key))~;
		break;
	}
	if (o.frozen_extensions) return self.throw_error(TYPE_ERROR, "Cannot add property %s, object is not extensible", self.key_text(key))~;
	o.add(&self.heap, key, v) ?? self.oom()~!;
}

fn void? Vm.call_setter(&self, Value accessor, Value receiver, Value key, Value v)
{
	Accessor* acc = (Accessor*)accessor.as_object();
	if (acc.setter.is_undefined()) return self.throw_error(TYPE_ERROR, "Cannot set property %s of object which has only a getter", self.key_text(key))~;
	Value[1] args = { v };
	(void)self.call(acc.setter, receiver, &args)!;
}

<*
 Define an own data property, replacing any existing one: what object literals and class fields do.

 @return? THROWN
*>
fn void? Vm.define(&self, JsObject* o, Value key, Value v, PropFlags flags = DATA_PROP)
{
	if (o.is_proxy) return self.proxy_define(o, key, v, flags);
	if (o.kind == ARRAY && key.is_int())
	{
		((JsArray*)o).set((uint)key.as_int(), v);
		self.heap.touch(o);
		return;
	}
	Shape* s = o.find_own(key);
	if (!s)
	{
		o.add(&self.heap, key, v, flags) ?? self.oom()~!;
		return;
	}
	if (s.flags != flags) o.reshape(&self.heap, EMPTY, key, flags) ?? self.oom()~!;
	o.slots[o.find_own(key).slot()] = v;
	self.heap.touch(o);
}

<*
 Define a getter or setter half of an accessor property, keeping the other half if present.

 @return? THROWN
*>
fn void? Vm.define_accessor(&self, JsObject* o, Value key, Value getter, Value setter, PropFlags flags)
{
	if (o.is_proxy) return self.define_accessor(o.proxy_target().as_object(), key, getter, setter, flags);
	flags.accessor = true;
	Shape* s = o.find_own(key);
	if (s && s.flags.accessor)
	{
		Accessor* acc = (Accessor*)o.slots[s.slot()].as_object();
		if (!getter.is_undefined()) acc.getter = getter;
		if (!setter.is_undefined()) acc.setter = setter;
		self.heap.touch(acc);
		return;
	}
	Accessor* acc = (Accessor*)self.heap.new_object(null, ACCESSOR, Accessor::size) ?? self.oom()~!;
	acc.getter = getter;
	acc.setter = setter;
	self.define(o, key, object_value(acc), flags)!;
}

<*
 The `in` operator.

 @return? THROWN
*>
fn bool? Vm.has_property(&self, Value obj, Value key)
{
	if (!obj.is_object()) return self.throw_error(TYPE_ERROR, "Cannot use 'in' operator to search for '%s' in %s", self.key_text(key), self.describe(obj))~;
	for (JsObject* o = obj.as_object(); o; o = o.proto())
	{
		if (o.is_proxy) return self.proxy_has(o, key);
		if (o.kind == ARRAY)
		{
			JsArray* arr = (JsArray*)o;
			if (key.is_int() && arr.get((uint)key.as_int()) != EMPTY) return true;
			if (key == self.atoms.length) return true;
		}
		if (o.kind == TYPED_ARRAY && key.is_int()) return (uint)key.as_int() < ((JsTypedArray*)o).length;
		if (o.find_own(key)) return true;
		if (o.kind == FUNCTION && (key == self.atoms.name || key == self.atoms.length)) return true;
	}
	return false;
}

<*
 The `delete` operator on a canonical key.

 @return? THROWN
*>
fn bool? Vm.delete_property(&self, Value obj, Value key)
{
	if (!obj.is_object())
	{
		if (obj.is_nullish()) return self.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
		return true;
	}
	JsObject* o = obj.as_object();
	if (o.is_proxy) return self.proxy_delete(o, key);
	if (o.kind == ARRAY && key.is_int())
	{
		JsArray* arr = (JsArray*)o;
		uint i = (uint)key.as_int();
		if (i < arr.length) arr.elements[i] = EMPTY;
		return true;
	}
	bool removed = o.remove(&self.heap, key) ?? self.oom()~!;
	if (!removed) return self.throw_error(TYPE_ERROR, "Cannot delete property '%s'", self.key_text(key))~;
	return true;
}

<*
 `instanceof`: is constructor.prototype on the prototype chain of v?

 @return? THROWN
*>
fn bool? Vm.instance_of(&self, Value v, Value constructor)
{
	if (!constructor.is_function()) return self.throw_error(TYPE_ERROR, "Right-hand side of 'instanceof' is not callable")~;
	if (!v.is_object()) return false;
	Value proto = self.get(constructor, self.atoms.prototype)!;
	if (!proto.is_object()) return self.throw_error(TYPE_ERROR, "Function has non-object prototype in instanceof check")~;
	JsObject* target = proto.as_object();
	for (JsObject* o = self.proto_of(v.as_object())!; o; o = self.proto_of(o)!)
	{
		if (o == target) return true;
	}
	return false;
}

<*
 Own enumerable keys in JS order: integer keys ascending, then strings in insertion order.

 @return? THROWN
*>
fn void? Vm.own_keys(&self, JsObject* o, List {Value}* out, bool include_symbols = false)
{
	if (o.is_proxy) return self.proxy_own_keys(o, out, include_symbols);
	if (o.kind == ARRAY)
	{
		JsArray* arr = (JsArray*)o;
		for (uint i = 0; i < arr.length; i++)
		{
			if (arr.elements[i] != EMPTY) out.push(integer((int)i));
		}
	}
	if (o.kind == TYPED_ARRAY)
	{
		for (uint i = 0; i < ((JsTypedArray*)o).length; i++) out.push(integer((int)i));
	}
	uint n = o.shape.count;
	if (n == 0) return;
	Shape*[] nodes = mem::new_array(Shape*, n);
	defer free(nodes);
	o.shape.nodes(nodes);
	sz first_int = out.len();
	foreach (node : nodes)
	{
		if (node.key.is_int() && node.flags.enumerable) out.push(node.key);
	}
	// Integer keys come first, in ascending order.
	Value[] ints = out.array_view()[first_int..];
	quicksort(ints, fn int(Value a, Value b) => a.as_int() - b.as_int());
	// Strings in creation order, then symbols in creation order.
	foreach (node : nodes)
	{
		if (!node.flags.enumerable || node.key.is_int() || node.key.is_symbol()) continue;
		out.push(node.key);
	}
	if (!include_symbols) return;
	foreach (node : nodes)
	{
		if (node.flags.enumerable && node.key.is_symbol()) out.push(node.key);
	}
}

// ---- inline cache slow paths: do the full operation, then remember what was found ----

<*
 obj.key for an object receiver, filling the instruction's cache when the result is cacheable.

 @return? THROWN
*>
fn Value? Vm.get_ic(&self, JsObject* o, Value key, IcEntry* ic)
{
	if (o.is_proxy) return self.proxy_get(o, key, object_value(o));
	Value receiver = object_value(o);
	if (o.kind == ARRAY && key == self.atoms.length)
	{
		*ic = { .shape = o.shape, .kind = ARRAY_LENGTH };
		return number((double)((JsArray*)o).length);
	}
	if (o.kind == TYPED_ARRAY && key == self.atoms.length && !o.find_own(key))
	{
		*ic = { .shape = o.shape, .kind = ARRAY_LENGTH };
		return number((double)((JsTypedArray*)o).length);
	}
	Shape* s = o.find_own(key);
	if (s)
	{
		*ic = { .shape = o.shape, .slot = s.slot(), .kind = s.flags.accessor ? OWN_GETTER : OWN };
		return self.get_from(o, key, receiver);
	}
	// Functions have lazily created name/length/prototype that live outside the shape.
	JsObject* p = o.proto();
	if (p && o.kind != FUNCTION)
	{
		Shape* ps = p.find_own(key);
		if (ps && !(p.kind == ARRAY && key.is_int()))
		{
			*ic = { .shape = o.shape, .holder_shape = p.shape, .slot = ps.slot(), .kind = ps.flags.accessor ? PROTO_GETTER : PROTO };
		}
	}
	return self.get_from(o, key, receiver);
}

<*
 obj.key = v for an object receiver, caching updates of own data properties and the shape
 transition when the property is added.

 @return? THROWN
*>
fn void? Vm.set_ic(&self, JsObject* o, Value key, Value v, IcEntry* ic)
{
	if (o.is_proxy) return self.proxy_set(o, key, v, object_value(o));
	if (o.kind == ARRAY && key == self.atoms.length) return self.set(object_value(o), key, v);
	Shape* s = o.find_own(key);
	if (s)
	{
		if (!s.flags.accessor && s.flags.writable)
		{
			o.slots[s.slot()] = v;
			self.heap.touch(o);
			*ic = { .shape = o.shape, .slot = s.slot(), .kind = OWN };
			return;
		}
		return self.set(object_value(o), key, v);
	}
	// Adding: only cacheable when nothing on the prototype chain intercepts the assignment.
	for (JsObject* p = o.proto(); p; p = p.proto())
	{
		Shape* ps = p.find_own(key);
		if (ps && (ps.flags.accessor || !ps.flags.writable)) return self.set(object_value(o), key, v);
	}
	if (o.frozen_extensions) return self.set(object_value(o), key, v);
	Shape* old = o.shape;
	o.add(&self.heap, key, v) ?? self.oom()~!;
	JsObject* proto = old.proto;
	*ic = { .shape = old, .new_shape = o.shape, .slot = o.shape.slot(), .holder_shape = proto ? proto.shape : null, .kind = ADD };
}

<*
 Define for object literals and class fields, caching the transition when it adds the property.

 @return? THROWN
*>
fn void? Vm.define_ic(&self, JsObject* o, Value key, Value v, IcEntry* ic)
{
	if (o.is_proxy) return self.proxy_define(o, key, v, DATA_PROP);
	Shape* old = o.shape;
	self.define(o, key, v)!;
	if (o.shape != old && o.shape.parent == old && o.shape.key == key)
	{
		*ic = { .shape = old, .new_shape = o.shape, .slot = o.shape.slot(), .kind = ADD };
	}
}
