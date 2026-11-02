module fastjs::rt;
import std::collections::list;

struct JsSymbol
{
	inline GcHeader header;
	// A string, or UNDEFINED for Symbol().
	Value description;
}

fn Value symbol_value(JsSymbol* s) @inline => pointer_value(TAG_SYMBOL, s);
fn JsSymbol* Value.as_symbol(self) @inline => (JsSymbol*)(uptr)((ulong)self & PAYLOAD_MASK);

<*
 @return? OUT_OF_MEMORY
*>
fn Value? Vm.new_symbol(&self, Value description)
{
	JsSymbol* s = self.heap.alloc(SYMBOL, JsSymbol::size)!;
	s.description = description;
	return symbol_value(s);
}

fn String Vm.symbol_text(&self, Value sym)
{
	Value d = sym.as_symbol().description;
	return d.is_string() ? string::tformat("Symbol(%s)", d.as_string().tutf8()) : "Symbol()";
}

// ---- iterator objects: what arr.values(), map.entries() and friends return ----

enum IterKind : char
{
	ARRAY_VALUES,
	ARRAY_KEYS,
	ARRAY_ENTRIES,
	MAP_KEYS,
	MAP_VALUES,
	MAP_ENTRIES,
	SET_VALUES,
	SET_ENTRIES,
}

struct JsIterator
{
	inline JsObject object;
	Value target;
	uint index;
	IterKind iter_kind;
	bool done;
}

<*
 @return? THROWN
*>
fn Value? Vm.new_iterator(&self, Value target, IterKind kind)
{
	JsIterator* it = (JsIterator*)self.heap.new_object(self.iterator_proto, ITERATOR, JsIterator::size) ?? self.oom()~!;
	it.target = target;
	it.iter_kind = kind;
	return object_value(it);
}

<*
 { value, done } as iterator results are shaped.

 @return? THROWN
*>
fn Value? Vm.iter_result(&self, Value value, bool done)
{
	JsObject* o = self.heap.new_object(self.object_proto) ?? self.oom()~!;
	o.add(&self.heap, self.atoms.value, value) ?? self.oom()~!;
	o.add(&self.heap, self.atoms.done, boolean(done)) ?? self.oom()~!;
	return object_value(o);
}

<*
 A two-element array, for entries().

 @return? THROWN
*>
fn Value? Vm.pair(&self, Value a, Value b)
{
	JsArray* arr = self.heap.new_array(self.array_proto, 2) ?? self.oom()~!;
	arr.push(a);
	arr.push(b);
	return object_value(arr);
}

<*
 Advance a built-in iterator. Returns false when exhausted.

 @return? THROWN
*>
fn bool? Vm.builtin_iter_step(&self, JsIterator* it, Value* out)
{
	if (it.done) return false;
	switch (it.iter_kind)
	{
		case ARRAY_VALUES:
		case ARRAY_KEYS:
		case ARRAY_ENTRIES:
			Value t = it.target;
			uint len;
			if (t.is_object() && t.as_object().kind == ARRAY)
			{
				len = ((JsArray*)t.as_object()).length;
			}
			else if (t.is_object() && t.as_object().kind == TYPED_ARRAY)
			{
				len = ((JsTypedArray*)t.as_object()).length;
			}
			else
			{
				len = (uint)self.to_number(self.get(t, self.atoms.length)!)!;
			}
			if (it.index >= len)
			{
				it.done = true;
				return false;
			}
			uint i = it.index++;
			switch (it.iter_kind)
			{
				case ARRAY_KEYS: *out = integer((int)i);
				case ARRAY_VALUES: *out = self.get(t, integer((int)i))!;
				default: *out = self.pair(integer((int)i), self.get(t, integer((int)i))!)!;
			}
			return true;
		default:
			JsMap* m = (JsMap*)it.target.as_object();
			while (it.index < m.used && m.entries[it.index].key == EMPTY) it.index++;
			if (it.index >= m.used)
			{
				it.done = true;
				return false;
			}
			MapEntry* e = &m.entries[it.index++];
			switch (it.iter_kind)
			{
				case MAP_KEYS:
				case SET_VALUES:
					*out = e.key;
				case MAP_VALUES:
					*out = e.value;
				case SET_ENTRIES:
					*out = self.pair(e.key, e.key)!;
				default:
					*out = self.pair(e.key, e.value)!;
			}
			return true;
	}
}

fn Value? native_iterator_next(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != ITERATOR) return vm.throw_error(TYPE_ERROR, "next method called on an incompatible receiver")~;
	Value v;
	if (vm.builtin_iter_step((JsIterator*)this_value.as_object(), &v)!) return vm.iter_result(v, false);
	return vm.iter_result(UNDEFINED, true);
}

fn Value? native_return_this(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => this_value;

// ---- the iteration protocol used by for-of, spread and destructuring ----

<*
 Start iterating v. state[0..1] holds either (array, index) for the fast path over arrays,
 strings and typed arrays, or (iterator, next method) for everything else.

 @return? THROWN
*>
fn void? Vm.get_iterator(&self, Value v, Value* state)
{
	if (v.is_object())
	{
		JsObject* o = v.as_object();
		if (o.kind == ARRAY && o.proto() == self.array_proto && !o.find_own(self.sym_iterator))
		{
			state[0] = v;
			state[1] = integer(0);
			return;
		}
		if (o.kind == TYPED_ARRAY)
		{
			// Typed arrays step through a plain array copy; they never change length.
			JsTypedArray* ta = (JsTypedArray*)o;
			JsArray* copy = self.heap.new_array(self.array_proto, ta.length) ?? self.oom()~!;
			for (uint i = 0; i < ta.length; i++) copy.push(ta.get(i));
			state[0] = object_value(copy);
			state[1] = integer(0);
			return;
		}
	}
	if (v.is_string())
	{
		// Iterate by code point.
		JsString* s = v.as_string();
		JsArray* chars = self.heap.new_array(self.array_proto) ?? self.oom()~!;
		state[0] = object_value(chars);
		state[1] = integer(0);
		uint i = 0;
		while (i < s.len)
		{
			uint end = i + 1;
			ushort u = s.at(i);
			if (u >= 0xD800 && u <= 0xDBFF && end < s.len)
			{
				ushort lo = s.at(end);
				if (lo >= 0xDC00 && lo <= 0xDFFF) end++;
			}
			chars.push(string_value(self.heap.substring(s, i, end) ?? self.oom()~!));
			i = end;
		}
		return;
	}
	if (v.is_nullish()) return self.throw_error(TYPE_ERROR, "%s is not iterable", self.describe(v))~;
	Value method = self.get(v, self.sym_iterator)!;
	if (!method.is_function()) return self.throw_error(TYPE_ERROR, "%s is not iterable", self.describe(v))~;
	Value iterator = self.call(method, v, {})!;
	if (!iterator.is_object()) return self.throw_error(TYPE_ERROR, "Result of the Symbol.iterator method is not an object")~;
	state[0] = iterator;
	state[1] = self.get(iterator, self.atoms.next)!;
}

<*
 The next value from an iteration started by get_iterator. Returns false when done.

 @return? THROWN
*>
fn bool? Vm.iter_next(&self, Value* state, Value* out)
{
	if (state[1].is_int())
	{
		JsArray* arr = (JsArray*)state[0].as_object();
		uint i = (uint)state[1].as_int();
		if (i >= arr.length) return false;
		Value v = arr.elements[i];
		*out = v == EMPTY ? UNDEFINED : v;
		state[1] = integer((int)i + 1);
		return true;
	}
	// Built-in iterators step without allocating a result object.
	if (state[0].is_object() && state[0].as_object().kind == ITERATOR && state[1].is_function() && ((JsFunction*)state[1].as_object()).native == &native_iterator_next)
	{
		return self.builtin_iter_step((JsIterator*)state[0].as_object(), out);
	}
	// So do generators, which go straight to resume().
	if (state[0].is_object() && state[0].as_object().kind == COROUTINE && state[1].is_function())
	{
		JsFunction* next = (JsFunction*)state[1].as_object();
		if (next.native == &native_generator_resume && next.magic == 0)
		{
			Value v;
			if (self.generator_step((JsCoroutine*)state[0].as_object(), UNDEFINED, NEXT, &v)!) return false;
			*out = v;
			return true;
		}
	}
	Value result = self.call(state[1], state[0], {})!;
	if (!result.is_object()) return self.throw_error(TYPE_ERROR, "Iterator result %s is not an object", self.describe(result))~;
	if (truthy(self.get(result, self.atoms.done)!)) return false;
	*out = self.get(result, self.atoms.value)!;
	return true;
}

<*
 Tell an iterator we are leaving early (break or an exception), via its `return` method.

 @return? THROWN
*>
fn void? Vm.iter_close(&self, Value* state)
{
	if (state[1].is_int() || !state[0].is_object()) return;
	if (state[0].as_object().kind == ITERATOR) return;
	Value ret = self.get(state[0], self.atoms.return_str)!;
	if (ret.is_function()) (void)self.call(ret, state[0], {})!;
}

<*
 Collect everything an iterable yields into a new array.

 @return? THROWN
*>
fn JsArray*? Vm.iterable_to_array(&self, Value v)
{
	Value[2] state;
	self.get_iterator(v, &state)!;
	JsArray* out = self.heap.new_array(self.array_proto) ?? self.oom()~!;
	Value item;
	while (self.iter_next(&state, &item)!) out.push(item);
	return out;
}

<*
 Turn a fast-path iteration state (array, index) into a real iterator object and its next
 method, for yield*, which talks to the iterator directly.

 @return? THROWN
*>
fn void? Vm.wrap_fast_iterator(&self, Value* state)
{
	Value it = self.new_iterator(state[0], ARRAY_VALUES)!;
	((JsIterator*)it.as_object()).index = (uint)state[1].as_int();
	state[0] = it;
	state[1] = self.get(it, self.atoms.next)!;
}
