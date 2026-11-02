module fastjs::rt;
import std::io, std::math, std::core::dstring, std::collections::list;

fn Value arg(Value[] args, usz i) @inline => i < args.len ? args[i] : UNDEFINED;

fn void? Vm.define_value(&self, JsObject* obj, String name, Value v, PropFlags flags = METHOD_PROP)
{
	obj.add(&self.heap, self.atom_value(name)!, v, flags)!;
}

<*
 A native constructor with a `prototype` object whose `constructor` points back at it.

 @return? OUT_OF_MEMORY
*>
fn JsFunction*? Vm.define_constructor(&self, String name, NativeFn native, uint arity, JsObject* proto)
{
	JsFunction* f = self.define_native(self.global, name, native, arity)!;
	f.add(&self.heap, self.atoms.prototype, object_value(proto), {})!;
	proto.add(&self.heap, self.atoms.constructor, object_value(f), METHOD_PROP)!;
	return f;
}

fn void? Vm.init_builtins(&self)
{
	Heap* h = &self.heap;
	self.object_proto = h.new_object(null)!;
	self.function_proto = h.new_object(self.object_proto, FUNCTION, JsFunction::size)!;
	((JsFunction*)self.function_proto).native = &native_noop;
	self.array_proto = (JsObject*)h.new_array(self.object_proto)!;
	self.string_proto = h.new_object(self.object_proto)!;
	self.number_proto = h.new_object(self.object_proto)!;
	self.boolean_proto = h.new_object(self.object_proto)!;
	self.global = h.new_object(self.object_proto)!;
	self.define_value(self.global, "globalThis", object_value(self.global))!;

	// Error, TypeError, ...: each prototype carries its name, and inherits from Error.prototype.
	String[ErrorKind::len] names = { "Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError" };
	foreach (i, name : names)
	{
		JsObject* proto = h.new_object(i == 0 ? self.object_proto : self.error_protos[0])!;
		self.error_protos[i] = proto;
		self.define_value(proto, "name", self.atom_value(name)!)!;
		self.define_value(proto, "message", self.atoms.empty)!;
		JsFunction* ctor = self.define_constructor(name, &native_error, 1, proto)!;
		ctor.magic = (int)i;
	}
	self.define_native(self.error_protos[0], "toString", &native_error_to_string, 0)!;

	JsObject* console = h.new_object(self.object_proto)!;
	self.define_value(self.global, "console", object_value(console))!;
	foreach (name : (String[4]){ "log", "info", "warn", "error" }) self.define_native(console, name, &native_console_log, 0)!;

	self.define_native(self.object_proto, "hasOwnProperty", &native_has_own_property, 1)!;
	self.define_native(self.object_proto, "toString", &native_object_to_string, 0)!;
	JsFunction* object_ctor = self.define_constructor("Object", &native_object, 1, self.object_proto)!;
	self.define_native(object_ctor, "keys", &native_object_keys, 1)!;
	self.define_native(object_ctor, "getPrototypeOf", &native_object_get_prototype_of, 1)!;

	JsFunction* array_ctor = self.define_constructor("Array", &native_array, 1, self.array_proto)!;
	self.define_native(array_ctor, "isArray", &native_array_is_array, 1)!;
	self.define_native(self.array_proto, "push", &native_array_push, 1)!;
	self.define_native(self.array_proto, "pop", &native_array_pop, 0)!;

	self.define_constructor("String", &native_string, 1, self.string_proto)!;
	self.define_native(self.string_proto, "charCodeAt", &native_string_char_code_at, 1)!;
	self.define_native(self.string_proto, "toUpperCase", &native_string_to_upper, 0)!;
	self.define_native(self.string_proto, "toString", &native_string_value_of, 0)!;
	self.define_native(self.string_proto, "valueOf", &native_string_value_of, 0)!;

	JsFunction* number_ctor = self.define_constructor("Number", &native_number, 1, self.number_proto)!;
	self.define_native(number_ctor, "isInteger", &native_number_is_integer, 1)!;
	self.define_native(self.number_proto, "toString", &native_number_to_string, 1)!;
	self.define_native(self.number_proto, "valueOf", &native_number_value_of, 0)!;
	self.define_native(self.number_proto, "toFixed", &native_number_to_fixed, 1)!;
	self.define_constructor("Boolean", &native_boolean, 1, self.boolean_proto)!;

	JsObject* m = h.new_object(self.object_proto)!;
	self.define_value(self.global, "Math", object_value(m))!;
	self.define_value(m, "PI", double_value(math::PI), {})!;
	self.define_native(m, "floor", &native_math_floor, 1)!;
	self.define_native(m, "sqrt", &native_math_sqrt, 1)!;
	self.define_native(m, "abs", &native_math_abs, 1)!;
	self.define_native(m, "max", &native_math_max, 2)!;
	self.define_native(m, "min", &native_math_min, 2)!;

	self.define_value(self.global, "NaN", double_value(double::nan), {})!;
	self.define_value(self.global, "Infinity", double_value(double::inf), {})!;
	self.define_value(self.global, "undefined", UNDEFINED, {})!;
	self.init_lib()!;
	self.init_regexp()!;
	self.init_coroutines()!;
}

// ---- console ----

fn void Vm.print(&self, String s)
{
	if (self.output)
	{
		self.output.append(s);
		return;
	}
	io::print(s);
}

fn Value? native_console_log(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	@pool()
	{
		DString out;
		out.tinit();
		foreach (i, v : args)
		{
			if (i > 0) out.append(' ');
			vm.inspect(v, &out, 0, true)!;
		}
		out.append('\n');
		vm.print(out.str_view());
	};
	return UNDEFINED;
}

// ---- natives ----

fn Value? native_noop(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => UNDEFINED;

fn Value? native_error(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsObject* err = vm.heap.new_object(vm.error_protos[callee.magic], ERROR) ?? vm.oom()~!;
	Value msg = arg(args, 0);
	JsString* text = msg.is_undefined() ? vm.atoms.empty.as_string() : vm.to_string(msg)!;
	if (!msg.is_undefined()) err.add(&vm.heap, vm.atoms.message, string_value(text), METHOD_PROP) ?? vm.oom()~!;
	vm.attach_stack(err, text) ?? vm.oom()~!;
	return object_value(err);
}

fn Value? native_error_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* name = vm.to_string(vm.get(this_value, vm.atoms.name)!)!;
	JsString* msg = vm.to_string(vm.get(this_value, vm.atoms.message)!)!;
	if (msg.len == 0) return string_value(name);
	if (name.len == 0) return string_value(msg);
	JsString* sep = vm.heap.string_from_latin1(": ") ?? vm.oom()~!;
	JsString* left = vm.heap.concat(name, sep) ?? vm.oom()~!;
	return string_value(vm.heap.concat(left, msg) ?? vm.oom()~!);
}

fn Value? native_has_own_property(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object()) return FALSE;
	Value key = vm.to_key(arg(args, 0))!;
	JsObject* o = this_value.as_object();
	if (o.kind == ARRAY && key.is_int()) return boolean(((JsArray*)o).get((uint)key.as_int()) != EMPTY);
	return boolean(o.find_own(key) != null);
}

fn Value? native_object_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	String tag = "[object Object]";
	switch
	{
		case this_value.is_undefined(): tag = "[object Undefined]";
		case this_value.is_null(): tag = "[object Null]";
		case this_value.is_object() && this_value.as_object().kind == ARRAY: tag = "[object Array]";
		case this_value.is_function(): tag = "[object Function]";
	}
	return vm.atom_value(tag) ?? vm.oom()~;
}

fn Value? native_object(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_object()) return v;
	return object_value(vm.heap.new_object(vm.object_proto) ?? vm.oom()~!);
}

fn Value? native_object_keys(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_nullish()) return vm.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	JsArray* out = vm.heap.new_array(vm.array_proto) ?? vm.oom()~!;
	if (!v.is_object()) return object_value(out);
	List {Value} keys;
	keys.init(mem);
	defer keys.free();
	vm.own_keys(v.as_object(), &keys)!;
	foreach (key : keys) out.push(key.is_int() ? string_value(vm.to_string(key)!) : key);
	return object_value(out);
}

fn Value? native_object_get_prototype_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_nullish()) return vm.throw_error(TYPE_ERROR, "Cannot convert undefined or null to object")~;
	JsObject* proto;
	switch
	{
		case v.is_object(): proto = v.as_object().proto();
		case v.is_string(): proto = vm.string_proto;
		case v.is_number(): proto = vm.number_proto;
		case v.is_bool(): proto = vm.boolean_proto;
		default: proto = vm.object_proto;
	}
	return proto ? object_value(proto) : NULL;
}

fn JsArray*? Vm.this_array(&self, Value this_value, String method)
{
	if (!this_value.is_object() || this_value.as_object().kind != ARRAY)
	{
		return self.throw_error(TYPE_ERROR, "Array.prototype.%s called on a non-array", method)~;
	}
	return (JsArray*)this_value.as_object();
}

fn Value? native_array(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.heap.new_array(vm.array_proto) ?? vm.oom()~!;
	if (args.len == 1 && args[0].is_number())
	{
		double n = args[0].as_number();
		if (n < 0 || n > 4294967295.0 || n != math::floor(n)) return vm.throw_error(RANGE_ERROR, "Invalid array length")~;
		a.set_length((uint)n);
		return object_value(a);
	}
	foreach (v : args) a.push(v);
	return object_value(a);
}

fn Value? native_array_is_array(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	return boolean(v.is_object() && v.as_object().kind == ARRAY);
}

fn Value? native_array_push(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "push")!;
	foreach (v : args) a.push(v);
	return number((double)a.length);
}

fn Value? native_array_pop(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArray* a = vm.this_array(this_value, "pop")!;
	if (a.length == 0) return UNDEFINED;
	Value v = a.elements[--a.length];
	return v == EMPTY ? UNDEFINED : v;
}

fn Value? native_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (args.len == 0) return vm.atoms.empty;
	if (args[0].is_symbol())
	{
		@pool()
		{
			return vm.str_value(vm.symbol_text(args[0]));
		};
	}
	return string_value(vm.to_string(args[0])!);
}

fn JsString*? Vm.this_string(&self, Value this_value)
{
	if (this_value.is_nullish()) return self.throw_error(TYPE_ERROR, "String.prototype method called on null or undefined")~;
	return self.to_string(this_value);
}

fn Value? native_string_char_code_at(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	double i = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	if (i != i) i = 0;
	if (i < 0 || i >= s.len) return double_value(double::nan);
	return integer(s.at((uint)i));
}

// Case mapping for Latin-1, Greek and Cyrillic; full Unicode tables come with the string library.
fn uint to_upper_cp(uint c)
{
	switch
	{
		case c >= 'a' && c <= 'z': return c - 32;
		case c >= 0xE0 && c <= 0xFE && c != 0xF7: return c - 32;
		case c == 0xFF: return 0x178;
		case c == 0xB5: return 0x39C;
		case c >= 0x3B1 && c <= 0x3C9 && c != 0x3C2: return c - 32;
		case c == 0x3C2: return 0x3A3;
		case c >= 0x430 && c <= 0x44F: return c - 32;
		case c >= 0x450 && c <= 0x45F: return c - 80;
		default: return c;
	}
}

fn Value? native_string_to_upper(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	@pool()
	{
		ushort[] units = mem::temp_array(ushort, s.len);
		for (uint i = 0; i < s.len; i++) units[i] = (ushort)to_upper_cp(s.at(i));
		return string_value(vm.heap.string_from_units(units) ?? vm.oom()~!);
	};
}

fn Value? native_string_value_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_string()) return vm.throw_error(TYPE_ERROR, "String.prototype.valueOf requires a string")~;
	return this_value;
}

fn Value? native_number(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (args.len == 0) return integer(0);
	return number(vm.to_number(args[0])!);
}

fn Value? native_number_is_integer(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	if (v.is_int()) return TRUE;
	if (!v.is_double()) return FALSE;
	double d = v.as_double();
	return boolean(d == math::floor(d) && d != double::inf && d != -double::inf);
}

fn Value? native_number_value_of(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_number()) return vm.throw_error(TYPE_ERROR, "Number.prototype.valueOf requires a number")~;
	return this_value;
}

fn Value? native_number_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_number()) return vm.throw_error(TYPE_ERROR, "Number.prototype.toString requires a number")~;
	return string_value(vm.to_string(this_value)!);
}

fn Value? native_number_to_fixed(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_number()) return vm.throw_error(TYPE_ERROR, "Number.prototype.toFixed requires a number")~;
	double digits = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	if (digits < 0 || digits > 100) return vm.throw_error(RANGE_ERROR, "toFixed() digits argument must be between 0 and 100")~;
	double d = this_value.as_number();
	if (d != d || d >= 1e21 || d <= -1e21) return string_value(vm.to_string(this_value)!);
	// Round half up on the exact decimal expansion, as JS does; printf would round half to even.
	int f = (int)digits;
	bool negative = d < 0;
	char[260] buf;
	CInt n = snprintf(&buf, buf.len, "%.*f", (CInt)(f + 60), negative ? -d : d);
	usz dot = 0;
	while (buf[dot] != '.') dot++;
	usz keep = f > 0 ? dot + 1 + (usz)f : dot;
	bool up = buf[dot + 1 + (usz)f] >= '5';
	char[260] out;
	usz len = 0;
	if (negative) out[len++] = '-';
	usz first_digit = len;
	for (usz i = 0; i < keep; i++) out[len++] = buf[i];
	if (up)
	{
		usz i = len;
		while (true)
		{
			if (i == first_digit)
			{
				// Carried past the first digit: 9.99 -> 10.0.
				for (usz k = len; k > first_digit; k--) out[k] = out[k - 1];
				out[first_digit] = '1';
				len++;
				break;
			}
			i--;
			if (out[i] == '.') continue;
			if (out[i] == '9')
			{
				out[i] = '0';
				continue;
			}
			out[i]++;
			break;
		}
	}
	// -0.00 is printed as 0.00.
	bool all_zero = true;
	for (usz i = first_digit; i < len; i++)
	{
		if (out[i] != '0' && out[i] != '.') all_zero = false;
	}
	String text = (String)out[all_zero && negative ? 1 : 0..len - 1];
	return string_value(vm.heap.string_from_latin1(text) ?? vm.oom()~!);
}

fn Value? native_boolean(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => boolean(truthy(arg(args, 0)));

fn double? Vm.arg_number(&self, Value[] args, usz i) => self.to_number(arg(args, i));

fn Value? native_math_floor(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => number(math::floor(vm.arg_number(args, 0)!));
fn Value? native_math_sqrt(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => double_value(math::sqrt(vm.arg_number(args, 0)!));
fn Value? native_math_abs(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => number(math::abs(vm.arg_number(args, 0)!));

fn Value? native_math_max(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double best = -double::inf;
	foreach (i, v : args)
	{
		double d = vm.to_number(v)!;
		if (d != d) return double_value(double::nan);
		if (d > best || (d == 0 && best == 0 && bitcast(best, ulong) != 0)) best = d;
	}
	return number(best);
}

fn Value? native_math_min(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double best = double::inf;
	foreach (i, v : args)
	{
		double d = vm.to_number(v)!;
		if (d != d) return double_value(double::nan);
		if (d < best || (d == 0 && best == 0 && bitcast(d, ulong) != 0)) best = d;
	}
	return number(best);
}
