module fastjs::rt;

bitstruct PropFlags : char
{
	bool writable;
	bool enumerable;
	bool configurable;
	// The slot holds an Accessor rather than a value.
	bool accessor;
}

const PropFlags DATA_PROP = { .writable = true, .enumerable = true, .configurable = true };
// Built-in methods and class methods: writable and configurable, but not enumerable.
const PropFlags METHOD_PROP = { .writable = true, .configurable = true };

const uint SHAPE_TABLE_MIN = 8;

<*
 A hidden class: one node of a transition tree. Objects with the same prototype that gained the
 same keys in the same order share a shape, so a shape check proves both the layout and the prototype.
*>
struct Shape
{
	inline GcHeader header;
	Shape* parent;
	JsObject* proto;
	// The key this node adds (an atom string or a symbol); UNDEFINED on a root.
	Value key;
	PropFlags flags;
	// Properties up to and including this one; this key's slot is count - 1.
	uint count;
	Shape* first_child;
	Shape* next_sibling;
	// key -> defining node, built on first lookup once count reaches SHAPE_TABLE_MIN.
	Shape** table;
	uint table_cap;
}

enum ObjectKind : char
{
	PLAIN,
	ARRAY,
	FUNCTION,
	ERROR,
	ACCESSOR,
	BOX,
	MAP,
	ITERATOR,
	TYPED_ARRAY,
	ARRAY_BUFFER,
	REGEXP,
	COROUTINE,
	PROMISE,
	// A JsTypedArray of bytes with no indexed elements, read through get/set methods.
	DATA_VIEW,
	// A Proxy of a non-callable target (a proxy of a function is a FUNCTION).
	PROXY,
	// A JsNative: an object carrying an embedding host's data.
	NATIVE,
	// A JsDate.
	DATE,
}

struct JsObject
{
	inline GcHeader header;
	ObjectKind kind;
	bool frozen_extensions;
	// A Proxy (see proxy.c3): property operations go to its handler's traps.
	bool is_proxy;
	Shape* shape;
	Value* slots;
	uint slot_cap;
	// Root of the shape tree for objects that have this object as their prototype; created lazily.
	Shape* child_root;
}

<*
 Arrays are always dense: a hole is the EMPTY value.
*>
struct JsArray
{
	inline JsObject object;
	Value* elements;
	uint length;
	uint cap;
	// Object.freeze: elements are read-only too.
	bool frozen;
}

<*
 The value of a getter/setter property.
*>
struct Accessor
{
	inline JsObject object;
	Value getter;
	Value setter;
}

fn Value object_value(JsObject* o) @inline => pointer_value(TAG_OBJECT, o);
fn JsObject* Value.as_object(self) @inline => (JsObject*)(uptr)((ulong)self & PAYLOAD_MASK);

fn uint Shape.slot(&self) @inline => self.count - 1;

<*
 @return? OUT_OF_MEMORY
*>
fn Shape*? Heap.new_shape(&self, Shape* parent, JsObject* proto, Value key, PropFlags flags)
{
	Shape* s = self.alloc(SHAPE, Shape::size)!;
	s.parent = parent;
	s.proto = proto;
	s.key = key;
	s.flags = flags;
	s.count = parent ? parent.count + 1 : 0;
	return s;
}

<*
 The empty shape for objects whose prototype is proto (which may be null).

 @return? OUT_OF_MEMORY
*>
fn Shape*? Heap.root_shape(&self, JsObject* proto)
{
	if (!proto)
	{
		if (!self.null_root) self.null_root = self.new_shape(null, null, UNDEFINED, {})!;
		return self.null_root;
	}
	if (!proto.child_root)
	{
		proto.child_root = self.new_shape(null, proto, UNDEFINED, {})!;
		self.touch(proto);
	}
	return proto.child_root;
}

<*
 The shape after adding key with flags to s: shared with every other object that took the same step.

 @return? OUT_OF_MEMORY
*>
fn Shape*? Heap.shape_with(&self, Shape* s, Value key, PropFlags flags)
{
	for (Shape* c = s.first_child; c; c = c.next_sibling)
	{
		if (c.key == key && c.flags == flags) return c;
	}
	Shape* c = self.new_shape(s, s.proto, key, flags)!;
	c.next_sibling = s.first_child;
	s.first_child = c;
	return c;
}

fn usz key_hash(Value key) @inline => (usz)(((ulong)key * 0x9E3779B97F4A7C15UL) >> 32);

fn void Shape.build_table(&self)
{
	uint cap = 16;
	while (cap < self.count * 2) cap *= 2;
	self.table = mem::new_array(Shape*, cap).ptr;
	account((sz)(cap - self.table_cap) * Shape*::size);
	self.table_cap = cap;
	for (Shape* s = self; s.parent; s = s.parent)
	{
		usz mask = (usz)cap - 1;
		usz i = key_hash(s.key) & mask;
		while (self.table[i]) i = (i + 1) & mask;
		self.table[i] = s;
	}
}

<*
 The node of this shape's chain that defines key, or null.
*>
fn Shape* Shape.lookup(&self, Value key)
{
	if (self.count >= SHAPE_TABLE_MIN)
	{
		if (!self.table) self.build_table();
		usz mask = (usz)self.table_cap - 1;
		usz i = key_hash(key) & mask;
		while (Shape* s = self.table[i])
		{
			if (s.key == key) return s;
			i = (i + 1) & mask;
		}
		return null;
	}
	for (Shape* s = self; s.parent; s = s.parent)
	{
		if (s.key == key) return s;
	}
	return null;
}

<*
 Fill out with this shape's nodes in property order (the order keys were added).

 @require out.len >= self.count : "Output too small"
*>
fn void Shape.nodes(&self, Shape*[] out)
{
	for (Shape* s = self; s.parent; s = s.parent) out[s.count - 1] = s;
}

<*
 @require size >= JsObject::size : "Size smaller than an object"
 @return? OUT_OF_MEMORY
*>
fn JsObject*? Heap.new_object(&self, JsObject* proto, ObjectKind kind = PLAIN, usz size = JsObject::size)
{
	Shape* root = self.root_shape(proto)!;
	JsObject* o = self.alloc(OBJECT, size)!;
	o.kind = kind;
	o.shape = root;
	return o;
}

<*
 @return? OUT_OF_MEMORY
*>
fn JsArray*? Heap.new_array(&self, JsObject* proto, uint capacity = 0)
{
	JsArray* a = (JsArray*)self.new_object(proto, ARRAY, JsArray::size)!;
	if (capacity) a.reserve(capacity);
	return a;
}

fn JsObject* JsObject.proto(&self) @inline => self.shape.proto;

<*
 The shape node of an own property, or null.
*>
fn Shape* JsObject.find_own(&self, Value key) @inline => self.shape.lookup(key);

fn void JsObject.ensure_slots(&self, uint needed)
{
	if (needed <= self.slot_cap) return;
	uint cap = self.slot_cap ? self.slot_cap * 2 : 4;
	while (cap < needed) cap *= 2;
	self.slots = (Value*)mem::realloc(self.slots, (sz)cap * Value::size);
	account((sz)(cap - self.slot_cap) * Value::size);
	self.slot_cap = cap;
}

<*
 Add a property the object doesn't have yet.

 @require !self.find_own(key) : "Property already exists"
 @return? OUT_OF_MEMORY
*>
fn void? JsObject.add(&self, Heap* heap, Value key, Value value, PropFlags flags = DATA_PROP)
{
	Shape* next = heap.shape_with(self.shape, key, flags)!;
	self.ensure_slots(next.count);
	self.slots[next.count - 1] = value;
	self.shape = next;
	heap.touch(self);
}

<*
 Rebuild this object's shape from its root with one property dropped (or none), and one property's
 flags replaced. This is the slow path for delete and for changing attributes.

 @return? OUT_OF_MEMORY
*>
fn void? JsObject.reshape(&self, Heap* heap, Value drop, Value change = EMPTY, PropFlags new_flags = {}, JsObject* new_proto = (JsObject*)1)
{
	uint n = self.shape.count;
	Shape*[] nodes = mem::new_array(Shape*, n);
	defer free(nodes);
	Value[] values = mem::new_array(Value, n);
	defer free(values);
	self.shape.nodes(nodes);
	for (uint i = 0; i < n; i++) values[i] = self.slots[i];
	Shape* s = heap.root_shape(new_proto == (JsObject*)1 ? self.shape.proto : new_proto)!;
	uint out = 0;
	for (uint i = 0; i < n; i++)
	{
		Shape* node = nodes[i];
		if (node.key == drop) continue;
		PropFlags flags = node.key == change ? new_flags : node.flags;
		s = heap.shape_with(s, node.key, flags)!;
		self.slots[out++] = values[i];
	}
	self.shape = s;
	heap.touch(self);
}

<*
 Remove an own property. Returns false when it is not configurable.

 @return? OUT_OF_MEMORY
*>
fn bool? JsObject.remove(&self, Heap* heap, Value key)
{
	Shape* node = self.find_own(key);
	if (!node) return true;
	if (!node.flags.configurable) return false;
	self.reshape(heap, key)!;
	return true;
}

<*
 Give the object a new prototype, keeping its properties.

 @return? OUT_OF_MEMORY
*>
fn void? JsObject.set_proto(&self, Heap* heap, JsObject* proto)
{
	if (self.shape.proto == proto) return;
	if (self.shape.count == 0)
	{
		self.shape = heap.root_shape(proto)!;
		heap.touch(self);
		return;
	}
	self.reshape(heap, EMPTY, EMPTY, {}, proto)!;
}

fn void JsArray.reserve(&self, uint capacity)
{
	if (capacity <= self.cap) return;
	uint cap = self.cap ? self.cap * 2 : 4;
	while (cap < capacity) cap *= 2;
	self.elements = (Value*)mem::realloc(self.elements, (sz)cap * Value::size);
	account((sz)(cap - self.cap) * Value::size);
	self.cap = cap;
}

<*
 Freeze an array whose named properties were all added non-writable already.
*>
fn void freeze_array(JsArray* a)
{
	a.frozen = true;
	a.frozen_extensions = true;
}

fn void JsArray.push(&self, Value v)
{
	self.reserve(self.length + 1);
	self.elements[self.length++] = v;
}

<*
 The element at i, or EMPTY for a hole or past the end.
*>
fn Value JsArray.get(&self, uint i) @inline => i < self.length ? self.elements[i] : EMPTY;

<*
 Set element i, growing the array (with holes) when i is at or past the end.

 @require i < uint::max : "Index out of range"
*>
fn void JsArray.set(&self, uint i, Value v)
{
	if (i >= self.length)
	{
		self.reserve(i + 1);
		for (uint k = self.length; k < i; k++) self.elements[k] = EMPTY;
		self.length = i + 1;
	}
	self.elements[i] = v;
}

fn void JsArray.set_length(&self, uint length)
{
	if (length > self.length)
	{
		self.reserve(length);
		for (uint k = self.length; k < length; k++) self.elements[k] = EMPTY;
	}
	self.length = length;
}

<*
 Bytes a block owns outside itself, as counted by `account` while it grew.
*>
fn usz extra_size(GcHeader* h)
{
	switch (h.kind)
	{
		case OBJECT:
			JsObject* o = (JsObject*)h;
			usz n = (usz)o.slot_cap * Value::size;
			switch (o.kind)
			{
				case ARRAY:
					n += (usz)((JsArray*)o).cap * Value::size;
				case MAP:
					JsMap* m = (JsMap*)o;
					n += (usz)m.cap * MapEntry::size + (usz)m.index_cap * uint::size;
				case ARRAY_BUFFER:
					JsArrayBuffer* b = (JsArrayBuffer*)o;
					if (!b.external) n += b.byte_length;
				case COROUTINE:
					JsCoroutine* c = (JsCoroutine*)o;
					if (c.regs) n += (usz)c.nregs * Value::size;
				default:
					break;
			}
			return n;
		case SHAPE:
			Shape* s = (Shape*)h;
			return s.table ? (usz)s.table_cap * Shape*::size : 0;
		default:
			return 0;
	}
}

<*
 Release memory owned outside the GC block itself. Called before the block is freed.
*>
fn void finalize(GcHeader* h)
{
	switch (h.kind)
	{
		case OBJECT:
			JsObject* o = (JsObject*)h;
			free(o.slots);
			if (o.kind == ARRAY) free(((JsArray*)o).elements);
			switch (o.kind)
			{
				case FUNCTION:
					free(((JsFunction*)o).captures);
				case MAP:
					free(((JsMap*)o).entries);
					free(((JsMap*)o).index);
				case ARRAY_BUFFER:
					JsArrayBuffer* b = (JsArrayBuffer*)o;
					if (!b.external) free(b.data);
				case REGEXP:
					finalize_regexp((JsRegExp*)o);
				case COROUTINE:
					free(((JsCoroutine*)o).regs);
				case PROMISE:
					((JsPromise*)o).reactions.free();
				case NATIVE:
					finalize_native((JsNative*)o);
				default:
					break;
			}
		case SHAPE:
			free(((Shape*)h).table);
		default:
			break;
	}
}
