module fastjs::rt;
import std::math;

enum TypedKind : char (String name, uint size)
{
	INT8 { "Int8Array", 1 },
	UINT8 { "Uint8Array", 1 },
	UINT8_CLAMPED { "Uint8ClampedArray", 1 },
	INT16 { "Int16Array", 2 },
	UINT16 { "Uint16Array", 2 },
	INT32 { "Int32Array", 4 },
	UINT32 { "Uint32Array", 4 },
	FLOAT32 { "Float32Array", 4 },
	FLOAT64 { "Float64Array", 8 },
}

struct JsArrayBuffer
{
	inline JsObject object;
	char* data;
	usz byte_length;
	// Memory the host owns (a view onto C3 data); never freed by the GC.
	bool external;
	// Scripts may read but not write it (Context.freeze).
	bool immutable;
}

struct JsTypedArray
{
	inline JsObject object;
	JsArrayBuffer* buffer;
	// buffer.data + byte_offset, cached.
	char* data;
	uint byte_offset;
	uint length;
	TypedKind tkind;
}

fn Value JsTypedArray.get(&self, uint i) @inline
{
	char* p = self.data + (usz)i * self.tkind.size;
	switch (self.tkind)
	{
		case INT8: return integer(*(ichar*)p);
		case UINT8:
		case UINT8_CLAMPED: return integer(*p);
		case INT16: return integer(*(short*)p);
		case UINT16: return integer(*(ushort*)p);
		case INT32: return integer(*(int*)p);
		case UINT32: return number((double)*(uint*)p);
		case FLOAT32: return double_value((double)*(float*)p);
		case FLOAT64: return double_value(*(double*)p);
	}
}

fn void JsTypedArray.set_number(&self, uint i, double d) @inline
{
	char* p = self.data + (usz)i * self.tkind.size;
	switch (self.tkind)
	{
		case INT8: *(ichar*)p = (ichar)to_int32(d);
		case UINT8: *p = (char)to_int32(d);
		case UINT8_CLAMPED:
			// Clamp, then round half to even.
			if (d != d || d <= 0)
			{
				*p = 0;
			}
			else if (d >= 255)
			{
				*p = 255;
			}
			else
			{
				double f = math::floor(d);
				double diff = d - f;
				int r = (int)f;
				if (diff > 0.5 || (diff == 0.5 && (r & 1))) r++;
				*p = (char)r;
			}
		case INT16: *(short*)p = (short)to_int32(d);
		case UINT16: *(ushort*)p = (ushort)to_int32(d);
		case INT32: *(int*)p = to_int32(d);
		case UINT32: *(uint*)p = (uint)to_int32(d);
		case FLOAT32: *(float*)p = (float)d;
		case FLOAT64: *(double*)p = d;
	}
}

fn void JsTypedArray.set_int(&self, uint i, int v) @inline
{
	switch (self.tkind)
	{
		case FLOAT32: *(float*)(self.data + (usz)i * 4) = (float)v;
		case FLOAT64: *(double*)(self.data + (usz)i * 8) = (double)v;
		case INT32: *(int*)(self.data + (usz)i * 4) = v;
		default: self.set_number(i, (double)v);
	}
}

<*
 A zeroed buffer of n bytes, counted toward GC pressure.

 @return? THROWN
*>
fn JsArrayBuffer*? Vm.new_buffer(&self, usz n)
{
	if (n > 1u << 31) return self.throw_error(RANGE_ERROR, "Array buffer allocation failed")~;
	if (usz limit = self.heap.limit)
	{
		self.heap.take_growth();
		if (self.heap.bytes + n > limit && @catch(self.heap.make_room(n))) return self.throw_error(RANGE_ERROR, "Array buffer allocation failed")~;
	}
	JsArrayBuffer* b = (JsArrayBuffer*)self.heap.new_object(self.array_buffer_proto, ARRAY_BUFFER, JsArrayBuffer::size) ?? self.oom()~!;
	b.data = n ? (char*)mem::calloc((sz)n) : null;
	b.byte_length = n;
	self.heap.bytes += n;
	return b;
}

<*
 @return? THROWN
*>
fn JsTypedArray*? Vm.new_typed(&self, TypedKind kind, JsArrayBuffer* buffer, uint offset, uint length)
{
	JsTypedArray* t = (JsTypedArray*)self.heap.new_object(self.typed_protos[kind.ordinal], TYPED_ARRAY, JsTypedArray::size) ?? self.oom()~!;
	t.buffer = buffer;
	t.byte_offset = offset;
	t.length = length;
	t.tkind = kind;
	t.data = buffer.data + offset;
	return t;
}

fn Value? native_array_buffer(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Constructor ArrayBuffer requires 'new'")~;
	double n = arg(args, 0).is_undefined() ? 0 : vm.to_number(args[0])!;
	if (n < 0 || n != n || n > 2147483648.0) return vm.throw_error(RANGE_ERROR, "Invalid array buffer length")~;
	return object_value(vm.new_buffer((usz)n)!);
}

fn Value? native_array_buffer_is_view(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 0);
	return boolean(v.is_object() && v.as_object().kind == TYPED_ARRAY);
}

fn JsArrayBuffer*? Vm.this_buffer(&self, Value v)
{
	if (v.is_object() && v.as_object().kind == ARRAY_BUFFER) return (JsArrayBuffer*)v.as_object();
	return self.throw_error(TYPE_ERROR, "Receiver is not an ArrayBuffer")~;
}

fn Value? native_buffer_byte_length(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return number((double)vm.this_buffer(this_value)!.byte_length);
}

<*
 Clamp a relative index argument (negative counts from the end) into [0, len].
*>
fn uint? Vm.relative_index(&self, Value v, uint len, uint fallback)
{
	if (v.is_undefined()) return fallback;
	double d = self.to_number(v)!;
	if (d != d) return 0;
	d = math::trunc(d);
	if (d < 0) d = math::max(0.0, (double)len + d);
	return (uint)math::min(d, (double)len);
}

fn Value? native_buffer_slice(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsArrayBuffer* b = vm.this_buffer(this_value)!;
	uint len = (uint)b.byte_length;
	uint start = vm.relative_index(arg(args, 0), len, 0)!;
	uint end = vm.relative_index(arg(args, 1), len, len)!;
	uint n = end > start ? end - start : 0;
	JsArrayBuffer* out = vm.new_buffer(n)!;
	if (n) mem::copy(out.data, b.data + start, n);
	return object_value(out);
}

fn Value? native_typed_array(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	TypedKind kind = TypedKind::from_ordinal(callee.magic);
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Constructor %s requires 'new'", kind.name)~;
	Value first = arg(args, 0);
	// new Float32Array(buffer, byteOffset, length): a view, no copy.
	if (first.is_object() && first.as_object().kind == ARRAY_BUFFER)
	{
		JsArrayBuffer* b = (JsArrayBuffer*)first.as_object();
		double off = arg(args, 1).is_undefined() ? 0 : vm.to_number(args[1])!;
		if (off != off) off = 0;
		if (off > (double)b.byte_length) return vm.throw_error(RANGE_ERROR, "Start offset %s is outside the bounds of the buffer", vm.describe(args[1]))~;
		if (off < 0 || (ulong)off % kind.size != 0) return vm.throw_error(RANGE_ERROR, "start offset of %s should be a multiple of %d", kind.name, kind.size)~;
		if (off > b.byte_length) return vm.throw_error(RANGE_ERROR, "Start offset %d is outside the bounds of the buffer", (ulong)off)~;
		double len;
		if (arg(args, 2).is_undefined())
		{
			if ((b.byte_length - (usz)off) % kind.size != 0) return vm.throw_error(RANGE_ERROR, "byte length of %s should be a multiple of %d", kind.name, kind.size)~;
			len = (double)((b.byte_length - (usz)off) / kind.size);
		}
		else
		{
			len = vm.to_number(args[2])!;
			if (len < 0 || off + len * kind.size > b.byte_length) return vm.throw_error(RANGE_ERROR, "Invalid typed array length: %d", (long)len)~;
		}
		return object_value(vm.new_typed(kind, b, (uint)off, (uint)len)!);
	}
	// new Float32Array(length)
	if (!first.is_object())
	{
		double n = first.is_undefined() ? 0 : vm.to_number(first)!;
		if (n < 0 || n != n || n != math::floor(n) || n * kind.size > (double)(1u << 31)) return vm.throw_error(RANGE_ERROR, "Invalid typed array length: %s", vm.describe(first))~;
		JsArrayBuffer* b = vm.new_buffer((usz)n * kind.size)!;
		return object_value(vm.new_typed(kind, b, 0, (uint)n)!);
	}
	// new Float32Array(arrayOrIterable): a copy.
	JsArray* source;
	if (first.as_object().kind == TYPED_ARRAY)
	{
		JsTypedArray* src = (JsTypedArray*)first.as_object();
		JsTypedArray* t = vm.new_typed(kind, vm.new_buffer((usz)src.length * kind.size)!, 0, src.length)!;
		for (uint i = 0; i < src.length; i++) t.set_number(i, src.get(i).as_number());
		return object_value(t);
	}
	if (first.as_object().kind == ARRAY)
	{
		source = (JsArray*)first.as_object();
	}
	else if (vm.get(first, vm.sym_iterator)!.is_function())
	{
		source = vm.iterable_to_array(first)!;
	}
	else
	{
		// An array-like: anything with a length.
		uint n = (uint)vm.to_number(vm.get(first, vm.atoms.length)!)!;
		JsTypedArray* t = vm.new_typed(kind, vm.new_buffer((usz)n * kind.size)!, 0, n)!;
		for (uint i = 0; i < n; i++) t.set_number(i, vm.to_number(vm.get(first, integer((int)i))!)!);
		return object_value(t);
	}
	JsTypedArray* t = vm.new_typed(kind, vm.new_buffer((usz)source.length * kind.size)!, 0, source.length)!;
	for (uint i = 0; i < source.length; i++)
	{
		Value v = source.elements[i];
		t.set_number(i, v == EMPTY ? double::nan : vm.to_number(v)!);
	}
	return object_value(t);
}

fn JsTypedArray*? Vm.this_typed(&self, Value v, String method)
{
	if (v.is_object() && v.as_object().kind == TYPED_ARRAY) return (JsTypedArray*)v.as_object();
	return self.throw_error(TYPE_ERROR, "TypedArray.prototype.%s called on incompatible receiver %s", method, self.describe(v))~;
}

fn Value? native_typed_length(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => integer((int)vm.this_typed(this_value, "length")!.length);
fn Value? native_typed_byte_length(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, "byteLength")!;
	return number((double)t.length * t.tkind.size);
}
fn Value? native_typed_byte_offset(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => integer((int)vm.this_typed(this_value, "byteOffset")!.byte_offset);
fn Value? native_typed_buffer(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => object_value(vm.this_typed(this_value, "buffer")!.buffer);

fn Value? native_typed_subarray(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, "subarray")!;
	uint start = vm.relative_index(arg(args, 0), t.length, 0)!;
	uint end = vm.relative_index(arg(args, 1), t.length, t.length)!;
	uint n = end > start ? end - start : 0;
	return object_value(vm.new_typed(t.tkind, t.buffer, t.byte_offset + start * t.tkind.size, n)!);
}

fn Value? native_typed_slice(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, "slice")!;
	uint start = vm.relative_index(arg(args, 0), t.length, 0)!;
	uint end = vm.relative_index(arg(args, 1), t.length, t.length)!;
	uint n = end > start ? end - start : 0;
	JsTypedArray* out = vm.new_typed(t.tkind, vm.new_buffer((usz)n * t.tkind.size)!, 0, n)!;
	if (n) mem::copy(out.data, t.data + (usz)start * t.tkind.size, (usz)n * t.tkind.size);
	return object_value(out);
}

fn Value? native_typed_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, "set")!;
	if (t.buffer.immutable) return vm.throw_error(TYPE_ERROR, "ArrayBuffer is immutable")~;
	Value src = arg(args, 0);
	double off = arg(args, 1).is_undefined() ? 0 : vm.to_number(args[1])!;
	if (off < 0) return vm.throw_error(RANGE_ERROR, "offset is out of bounds")~;
	uint offset = (uint)off;
	if (src.is_object() && src.as_object().kind == TYPED_ARRAY)
	{
		JsTypedArray* s = (JsTypedArray*)src.as_object();
		if ((ulong)offset + s.length > t.length) return vm.throw_error(RANGE_ERROR, "offset is out of bounds")~;
		if (s.tkind == t.tkind)
		{
			// memmove: source and target may share a buffer.
			mem::move(t.data + (usz)offset * t.tkind.size, s.data, (usz)s.length * s.tkind.size);
			return UNDEFINED;
		}
		for (uint i = 0; i < s.length; i++) t.set_number(offset + i, s.get(i).as_number());
		return UNDEFINED;
	}
	if (src.is_object() && src.as_object().kind == ARRAY)
	{
		JsArray* s = (JsArray*)src.as_object();
		if ((ulong)offset + s.length > t.length) return vm.throw_error(RANGE_ERROR, "offset is out of bounds")~;
		for (uint i = 0; i < s.length; i++)
		{
			Value v = s.elements[i];
			t.set_number(offset + i, v == EMPTY ? double::nan : vm.to_number(v)!);
		}
		return UNDEFINED;
	}
	uint n = (uint)vm.to_number(vm.get(src, vm.atoms.length)!)!;
	if ((ulong)offset + n > t.length) return vm.throw_error(RANGE_ERROR, "offset is out of bounds")~;
	for (uint i = 0; i < n; i++) t.set_number(offset + i, vm.to_number(vm.get(src, integer((int)i))!)!);
	return UNDEFINED;
}

<*
 copyWithin(target, start, end) on a typed array: one memmove.
*>
fn Value? native_typed_copy_within(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, "copyWithin")!;
	if (t.buffer.immutable) return vm.throw_error(TYPE_ERROR, "ArrayBuffer is immutable")~;
	uint len = t.length;
	uint to = vm.relative_index(arg(args, 0), len, 0)!;
	uint from = vm.relative_index(arg(args, 1), len, 0)!;
	uint end = arg(args, 2).is_undefined() ? len : vm.relative_index(args[2], len, len)!;
	if (end > from && to < len)
	{
		uint count = min(end - from, len - to);
		usz size = t.tkind.size;
		mem::move(t.data + (usz)to * size, t.data + (usz)from * size, (sz)((usz)count * size));
	}
	return this_value;
}

fn Value? native_typed_fill(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, "fill")!;
	if (t.buffer.immutable) return vm.throw_error(TYPE_ERROR, "ArrayBuffer is immutable")~;
	double v = vm.to_number(arg(args, 0))!;
	uint start = vm.relative_index(arg(args, 1), t.length, 0)!;
	uint end = vm.relative_index(arg(args, 2), t.length, t.length)!;
	for (uint i = start; i < end; i++) t.set_number(i, v);
	return this_value;
}

<*
 map (0) and filter (1) for typed arrays: the result is a typed array of the same kind.
*>
fn Value? native_typed_map(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* t = vm.this_typed(this_value, callee.magic == 0 ? "map" : "filter")!;
	Value fun = vm.callback(args, "callback")!;
	JsArray* kept = vm.new_js_array(t.length)!;
	for (uint i = 0; i < t.length; i++)
	{
		Value v = t.get(i);
		Value[3] call_args = { v, integer((int)i), this_value };
		Value r = vm.call(fun, arg(args, 1), &call_args)!;
		if (callee.magic == 0)
		{
			kept.push(r);
		}
		else if (truthy(r))
		{
			kept.push(v);
		}
	}
	JsTypedArray* out = vm.new_typed(t.tkind, vm.new_buffer((usz)kept.length * t.tkind.size)!, 0, kept.length)!;
	for (uint i = 0; i < kept.length; i++) out.set_number(i, vm.to_number(kept.elements[i])!);
	return object_value(out);
}

<*
 Detach a buffer: it and every view of it become empty, so nothing reads the memory afterwards.
 Views cache their data pointer, so they are found by walking the heap; detaching is rare.
*>
fn void Vm.detach_buffer(&self, JsArrayBuffer* b)
{
	if (!b.external && b.data)
	{
		free(b.data);
		self.heap.bytes -= b.byte_length;
	}
	b.data = null;
	b.byte_length = 0;
	b.external = true;
	self.finish_sweep();
	for (GcHeader* h = self.heap.all; h; h = h.next)
	{
		if (h.kind != OBJECT) continue;
		JsObject* o = (JsObject*)h;
		if (o.kind != TYPED_ARRAY && o.kind != DATA_VIEW) continue;
		JsTypedArray* t = (JsTypedArray*)o;
		if (t.buffer != b) continue;
		t.data = null;
		t.length = 0;
		t.byte_offset = 0;
	}
}

<*
 Float32Array.from(source, mapFn?) and Float32Array.of(...items); magic is the TypedKind, plus
 0x100 for `of`.
*>
fn Value? native_typed_from(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	TypedKind kind = TypedKind::from_ordinal(callee.magic & 0xFF);
	JsArray* items;
	if (callee.magic & 0x100)
	{
		items = vm.heap.new_array(vm.array_proto, (uint)args.len) ?? vm.oom()~!;
		foreach (a : args) items.push(a);
	}
	else
	{
		Value source = arg(args, 0);
		if (source.is_nullish()) return vm.throw_error(TYPE_ERROR, "%s.from requires an array-like or iterable object", kind.name)~;
		if (source.is_string() || (source.is_object() && vm.get(source, vm.sym_iterator)!.is_function()))
		{
			items = vm.iterable_to_array(source)!;
		}
		else
		{
			uint n = vm.length_of(source)!;
			items = vm.heap.new_array(vm.array_proto, n) ?? vm.oom()~!;
			for (uint i = 0; i < n; i++) items.push(vm.index_get(source, i)!);
		}
	}
	// Keep the items reachable while a map function runs.
	vm.native_depth++;
	defer vm.native_depth--;
	Value map = arg(args, 1);
	if (!(callee.magic & 0x100) && !map.is_undefined() && !map.is_function()) return vm.throw_error(TYPE_ERROR, "%s is not a function", vm.describe(map))~;
	JsTypedArray* t = vm.new_typed(kind, vm.new_buffer((usz)items.length * kind.size)!, 0, items.length)!;
	for (uint i = 0; i < items.length; i++)
	{
		Value v = items.elements[i] == EMPTY ? UNDEFINED : items.elements[i];
		if (map.is_function() && !(callee.magic & 0x100))
		{
			Value[2] margs = { v, integer((int)i) };
			v = vm.call(map, arg(args, 2), &margs)!;
		}
		t.set_number(i, vm.to_number(v)!);
	}
	return object_value(t);
}

// ---- DataView ----

fn Value? native_data_view(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Constructor DataView requires 'new'")~;
	Value b = arg(args, 0);
	if (!b.is_object() || b.as_object().kind != ARRAY_BUFFER) return vm.throw_error(TYPE_ERROR, "First argument to DataView constructor must be an ArrayBuffer")~;
	JsArrayBuffer* buffer = (JsArrayBuffer*)b.as_object();
	double offset = arg(args, 1).is_undefined() ? 0 : vm.to_number(arg(args, 1))!;
	if (offset != offset) offset = 0;
	if (offset < 0 || offset > (double)buffer.byte_length) return vm.throw_error(RANGE_ERROR, "Start offset %s is outside the bounds of the buffer", offset)~;
	double length = arg(args, 2).is_undefined() ? (double)buffer.byte_length - offset : vm.to_number(arg(args, 2))!;
	if (length < 0 || offset + length > (double)buffer.byte_length) return vm.throw_error(RANGE_ERROR, "Invalid DataView length %s", length)~;
	JsTypedArray* view = (JsTypedArray*)vm.heap.new_object(vm.data_view_proto, DATA_VIEW, JsTypedArray::size) ?? vm.oom()~!;
	view.buffer = buffer;
	view.byte_offset = (uint)offset;
	view.data = buffer.data + view.byte_offset;
	view.length = (uint)length;
	view.tkind = UINT8;
	return object_value(view);
}

fn JsTypedArray*? Vm.this_data_view(&self, Value v)
{
	if (v.is_object() && v.as_object().kind == DATA_VIEW) return (JsTypedArray*)v.as_object();
	return self.throw_error(TYPE_ERROR, "Receiver is not a DataView")~;
}

<*
 The bytes of one element at byte offset `at`, in host (little-endian) order.

 @return? THROWN
*>
fn char*? Vm.data_view_slot(&self, JsTypedArray* view, Value at, TypedKind kind)
{
	double offset = self.to_number(at)!;
	if (offset != offset) offset = 0;
	if (offset < 0 || offset + kind.size > (double)view.length) return self.throw_error(RANGE_ERROR, "Offset is outside the bounds of the DataView")~;
	return view.data + (usz)offset;
}

// getInt8 ... getFloat64; magic is the TypedKind.
fn Value? native_data_view_get(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* view = vm.this_data_view(this_value)!;
	TypedKind kind = TypedKind::from_ordinal(callee.magic);
	char* p = vm.data_view_slot(view, arg(args, 0), kind)!;
	char[8] bytes;
	bool little = truthy(arg(args, 1));
	for (uint i = 0; i < kind.size; i++) bytes[i] = little ? p[i] : p[kind.size - 1 - i];
	JsTypedArray tmp = { .data = &bytes, .length = 1, .tkind = kind };
	return tmp.get(0);
}

fn Value? native_data_view_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsTypedArray* view = vm.this_data_view(this_value)!;
	TypedKind kind = TypedKind::from_ordinal(callee.magic);
	char* p = vm.data_view_slot(view, arg(args, 0), kind)!;
	double d = vm.to_number(arg(args, 1))!;
	char[8] bytes;
	JsTypedArray tmp = { .data = &bytes, .length = 1, .tkind = kind };
	tmp.set_number(0, d);
	bool little = truthy(arg(args, 2));
	for (uint i = 0; i < kind.size; i++) p[i] = little ? bytes[i] : bytes[kind.size - 1 - i];
	return UNDEFINED;
}

fn Value? native_data_view_buffer(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => object_value(vm.this_data_view(this_value)!.buffer);
fn Value? native_data_view_byte_length(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => integer((int)vm.this_data_view(this_value)!.length);
fn Value? native_data_view_byte_offset(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => integer((int)vm.this_data_view(this_value)!.byte_offset);

fn void? Vm.init_typed_arrays(&self)
{
	self.array_buffer_proto = self.heap.new_object(self.object_proto)!;
	JsFunction* ab = self.define_constructor("ArrayBuffer", &native_array_buffer, 1, self.array_buffer_proto)!;
	self.define_native(ab, "isView", &native_array_buffer_is_view, 1)!;
	self.define_getter(self.array_buffer_proto, "byteLength", &native_buffer_byte_length)!;
	self.define_native(self.array_buffer_proto, "slice", &native_buffer_slice, 2)!;

	// %TypedArray%.prototype holds the shared methods; each kind's prototype inherits from it.
	JsObject* base = self.heap.new_object(self.object_proto)!;
	self.define_getter(base, "length", &native_typed_length)!;
	self.define_getter(base, "byteLength", &native_typed_byte_length)!;
	self.define_getter(base, "byteOffset", &native_typed_byte_offset)!;
	self.define_getter(base, "buffer", &native_typed_buffer)!;
	self.define_native(base, "subarray", &native_typed_subarray, 2)!;
	self.define_native(base, "slice", &native_typed_slice, 2)!;
	self.define_native(base, "set", &native_typed_set, 1)!;
	self.define_native(base, "fill", &native_typed_fill, 1)!;
	self.define_native(base, "copyWithin", &native_typed_copy_within, 2)!;
	// Generic array methods work on typed arrays through get/set with index keys.
	self.define_native(base, "map", &native_typed_map, 1)!.magic = 0;
	self.define_native(base, "filter", &native_typed_map, 1)!.magic = 1;
	foreach (name : (String[9]){ "forEach", "indexOf", "includes", "join", "reduce", "some", "every", "find", "findIndex" })
	{
		Value m = self.get(object_value(self.array_proto), self.atom_value(name)!) ?? UNDEFINED;
		if (m.is_function()) base.add(&self.heap, self.atom_value(name)!, m, METHOD_PROP)!;
	}
	foreach (name : (String[3]){ "values", "keys", "entries" })
	{
		Value m = self.get(object_value(self.array_proto), self.atom_value(name)!) ?? UNDEFINED;
		if (m.is_function()) base.add(&self.heap, self.atom_value(name)!, m, METHOD_PROP)!;
	}
	Value values = self.get(object_value(self.array_proto), self.sym_iterator) ?? UNDEFINED;
	if (values.is_function()) base.add(&self.heap, self.sym_iterator, values, METHOD_PROP)!;
	foreach (kind : TypedKind::values)
	{
		JsObject* proto = self.heap.new_object(base)!;
		self.typed_protos[kind.ordinal] = proto;
		JsFunction* ctor = self.define_constructor(kind.name, &native_typed_array, 3, proto)!;
		ctor.magic = (int)kind.ordinal;
		self.define_native(ctor, "from", &native_typed_from, 1)!.magic = (int)kind.ordinal;
		self.define_native(ctor, "of", &native_typed_from, 0)!.magic = (int)kind.ordinal | 0x100;
		ctor.add(&self.heap, self.atom_value("BYTES_PER_ELEMENT")!, integer((int)kind.size), {})!;
		proto.add(&self.heap, self.atom_value("BYTES_PER_ELEMENT")!, integer((int)kind.size), {})!;
	}

	self.data_view_proto = self.heap.new_object(self.object_proto)!;
	self.define_constructor("DataView", &native_data_view, 1, self.data_view_proto)!;
	self.define_getter(self.data_view_proto, "buffer", &native_data_view_buffer)!;
	self.define_getter(self.data_view_proto, "byteLength", &native_data_view_byte_length)!;
	self.define_getter(self.data_view_proto, "byteOffset", &native_data_view_byte_offset)!;
	foreach (kind : TypedKind::values)
	{
		if (kind == UINT8_CLAMPED) continue;
		String type = kind.name[:kind.name.len - 5];
		JsFunction* getter = self.new_native(string::format(mem, "get%s", type), &native_data_view_get, 1)!;
		JsFunction* setter = self.new_native(string::format(mem, "set%s", type), &native_data_view_set, 2)!;
		self.owned_names.push(getter.native_name);
		self.owned_names.push(setter.native_name);
		getter.magic = (int)kind.ordinal;
		setter.magic = (int)kind.ordinal;
		self.data_view_proto.add(&self.heap, self.atom_value(getter.native_name)!, object_value(getter), METHOD_PROP)!;
		self.data_view_proto.add(&self.heap, self.atom_value(setter.native_name)!, object_value(setter), METHOD_PROP)!;
	}
}
