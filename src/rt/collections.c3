module fastjs::rt;
import std::collections::list;

// Map and Set: entries in insertion order, plus an open-addressing index from hash to entry.
// A deleted entry keeps its place with key EMPTY so live iterators keep their position.

struct MapEntry
{
	Value key;
	Value value;
	uint hash;
}

struct JsMap
{
	inline JsObject object;
	MapEntry* entries;
	// Entries used, including deleted ones.
	uint used;
	uint live;
	uint cap;
	// Entry index + 1, or 0 for a free index slot.
	uint* index;
	uint index_cap;
	bool is_set;
}

<*
 SameValueZero hashing: equal keys hash alike whatever their representation.
*>
fn uint key_hash32(Value v)
{
	ulong bits;
	if (v.is_number())
	{
		double d = v.as_number();
		if (d == 0) d = 0;
		if (d != d) d = double::nan;
		bits = bitcast(d, ulong);
	}
	else if (v.is_string())
	{
		return v.as_string().hash_code();
	}
	else
	{
		bits = (ulong)v;
	}
	bits ^= bits >> 33;
	bits *= 0xff51afd7ed558ccdUL;
	bits ^= bits >> 33;
	return (uint)bits | 1;
}

fn bool same_value_zero(Value a, Value b)
{
	if (a.is_number() && b.is_number())
	{
		double x = a.as_number();
		double y = b.as_number();
		return x == y || (x != x && y != y);
	}
	return strict_equals(a, b);
}

fn int JsMap.find(&self, Value key, uint hash)
{
	if (!self.index_cap) return -1;
	uint mask = self.index_cap - 1;
	uint i = hash & mask;
	while (uint slot = self.index[i])
	{
		MapEntry* e = &self.entries[slot - 1];
		if (e.hash == hash && e.key != EMPTY && same_value_zero(e.key, key)) return (int)slot - 1;
		i = (i + 1) & mask;
	}
	return -1;
}

fn void JsMap.rebuild_index(&self, uint cap)
{
	free(self.index);
	self.index = mem::new_array(uint, cap).ptr;
	self.index_cap = cap;
	for (uint e = 0; e < self.used; e++)
	{
		if (self.entries[e].key == EMPTY) continue;
		uint i = self.entries[e].hash & (cap - 1);
		while (self.index[i]) i = (i + 1) & (cap - 1);
		self.index[i] = e + 1;
	}
}

fn void JsMap.put(&self, Value key, Value value)
{
	// -0 is stored as +0, as the spec says.
	if (key.is_double() && key.as_double() == 0) key = integer(0);
	uint hash = key_hash32(key);
	int found = self.find(key, hash);
	if (found >= 0)
	{
		self.entries[found].value = value;
		return;
	}
	if (self.used == self.cap)
	{
		self.cap = self.cap ? self.cap * 2 : 8;
		self.entries = (MapEntry*)mem::realloc(self.entries, (sz)self.cap * MapEntry::size);
	}
	self.entries[self.used++] = { key, value, hash };
	self.live++;
	if (self.used * 2 >= self.index_cap)
	{
		self.rebuild_index(self.index_cap ? self.index_cap * 2 : 16);
		return;
	}
	uint mask = self.index_cap - 1;
	uint i = hash & mask;
	while (self.index[i]) i = (i + 1) & mask;
	self.index[i] = self.used;
}

fn bool JsMap.remove(&self, Value key)
{
	int found = self.find(key, key_hash32(key));
	if (found < 0) return false;
	self.entries[found].key = EMPTY;
	self.entries[found].value = UNDEFINED;
	self.live--;
	// The index still points at the dead entry; find() skips it, and the next rebuild drops it.
	return true;
}

fn void JsMap.clear(&self)
{
	for (uint i = 0; i < self.used; i++)
	{
		self.entries[i].key = EMPTY;
		self.entries[i].value = UNDEFINED;
	}
	self.live = 0;
	if (self.index) mem::clear(self.index, (sz)self.index_cap * uint::size);
}

fn JsMap*? Vm.this_map(&self, Value v, bool is_set, String method)
{
	if (v.is_object() && v.as_object().kind == MAP && ((JsMap*)v.as_object()).is_set == is_set) return (JsMap*)v.as_object();
	return self.throw_error(TYPE_ERROR, "Method %s.prototype.%s called on incompatible receiver %s", is_set ? "Set" : "Map", method, self.describe(v))~;
}

fn Value? Vm.construct_map(&self, Value[] args, bool is_set)
{
	JsMap* m = (JsMap*)self.heap.new_object(is_set ? self.set_proto : self.map_proto, MAP, JsMap::size) ?? self.oom()~!;
	m.is_set = is_set;
	Value init = arg(args, 0);
	if (init.is_nullish()) return object_value(m);
	// Keep the new map reachable from a register-like root while user iterators run.
	self.roots.push(object_value(m));
	defer (void)self.roots.pop();
	Value[2] state;
	self.get_iterator(init, &state)!;
	self.roots.push(state[0]);
	self.roots.push(state[1]);
	defer
	{
		(void)self.roots.pop();
		(void)self.roots.pop();
	}
	Value item;
	while (self.iter_next(&state, &item)!)
	{
		if (is_set)
		{
			m.put(item, item);
			continue;
		}
		if (!item.is_object()) return self.throw_error(TYPE_ERROR, "Iterator value %s is not an entry object", self.describe(item))~;
		m.put(self.get(item, integer(0))!, self.get(item, integer(1))!);
	}
	return object_value(m);
}

fn Value? native_map(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Constructor Map requires 'new'")~;
	return vm.construct_map(args, false);
}

fn Value? native_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Constructor Set requires 'new'")~;
	return vm.construct_map(args, true);
}

fn Value? native_map_get(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsMap* m = vm.this_map(this_value, false, "get")!;
	Value key = arg(args, 0);
	int found = m.find(key, key_hash32(key));
	return found < 0 ? UNDEFINED : m.entries[found].value;
}

fn Value? native_map_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsMap* m = vm.this_map(this_value, false, "set")!;
	m.put(arg(args, 0), arg(args, 1));
	return this_value;
}

fn Value? native_set_add(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsMap* m = vm.this_map(this_value, true, "add")!;
	m.put(arg(args, 0), arg(args, 0));
	return this_value;
}

fn Value? native_map_has(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != MAP) return vm.throw_error(TYPE_ERROR, "has called on incompatible receiver")~;
	JsMap* m = (JsMap*)this_value.as_object();
	Value key = arg(args, 0);
	return boolean(m.find(key, key_hash32(key)) >= 0);
}

fn Value? native_map_delete(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != MAP) return vm.throw_error(TYPE_ERROR, "delete called on incompatible receiver")~;
	return boolean(((JsMap*)this_value.as_object()).remove(arg(args, 0)));
}

fn Value? native_map_clear(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != MAP) return vm.throw_error(TYPE_ERROR, "clear called on incompatible receiver")~;
	((JsMap*)this_value.as_object()).clear();
	return UNDEFINED;
}

fn Value? native_map_size(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != MAP) return vm.throw_error(TYPE_ERROR, "size called on incompatible receiver")~;
	return integer((int)((JsMap*)this_value.as_object()).live);
}

fn Value? native_map_for_each(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != MAP) return vm.throw_error(TYPE_ERROR, "forEach called on incompatible receiver")~;
	JsMap* m = (JsMap*)this_value.as_object();
	Value fun = arg(args, 0);
	if (!fun.is_function()) return vm.throw_error(TYPE_ERROR, "%s is not a function", vm.describe(fun))~;
	for (uint i = 0; i < m.used; i++)
	{
		MapEntry e = m.entries[i];
		if (e.key == EMPTY) continue;
		Value[3] call_args = { e.value, e.key, this_value };
		(void)vm.call(fun, arg(args, 1), &call_args)!;
	}
	return UNDEFINED;
}

fn Value? native_map_iter(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object() || this_value.as_object().kind != MAP) return vm.throw_error(TYPE_ERROR, "iterator method called on incompatible receiver")~;
	return vm.new_iterator(this_value, (IterKind)callee.magic);
}

fn void? Vm.init_collections(&self)
{
	self.map_proto = self.heap.new_object(self.object_proto)!;
	self.set_proto = self.heap.new_object(self.object_proto)!;
	self.define_constructor("Map", &native_map, 0, self.map_proto)!;
	self.define_constructor("Set", &native_set, 0, self.set_proto)!;
	foreach (proto : (JsObject*[2]){ self.map_proto, self.set_proto })
	{
		bool is_set = proto == self.set_proto;
		self.define_native(proto, "has", &native_map_has, 1)!;
		self.define_native(proto, "delete", &native_map_delete, 1)!;
		self.define_native(proto, "clear", &native_map_clear, 0)!;
		self.define_native(proto, "forEach", &native_map_for_each, 1)!;
		self.define_getter(proto, "size", &native_map_size)!;
		if (is_set)
		{
			self.define_native(proto, "add", &native_set_add, 1)!;
			JsFunction* values = self.define_native(proto, "values", &native_map_iter, 0)!;
			values.magic = (int)IterKind.SET_VALUES.ordinal;
			proto.add(&self.heap, self.atom_value("keys")!, object_value(values), METHOD_PROP)!;
			proto.add(&self.heap, self.sym_iterator, object_value(values), METHOD_PROP)!;
			self.define_native(proto, "entries", &native_map_iter, 0)!.magic = (int)IterKind.SET_ENTRIES.ordinal;
		}
		else
		{
			self.define_native(proto, "get", &native_map_get, 1)!;
			self.define_native(proto, "set", &native_map_set, 2)!;
			self.define_native(proto, "keys", &native_map_iter, 0)!.magic = (int)IterKind.MAP_KEYS.ordinal;
			self.define_native(proto, "values", &native_map_iter, 0)!.magic = (int)IterKind.MAP_VALUES.ordinal;
			JsFunction* entries = self.define_native(proto, "entries", &native_map_iter, 0)!;
			entries.magic = (int)IterKind.MAP_ENTRIES.ordinal;
			proto.add(&self.heap, self.sym_iterator, object_value(entries), METHOD_PROP)!;
		}
	}
}
