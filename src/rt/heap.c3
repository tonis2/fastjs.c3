module fastjs::rt;

excuse OUT_OF_MEMORY;

<*
 Owns every garbage-collected allocation, and the table of interned property-key strings.
*>
struct Heap
{
	// Everything except shapes, newest first.
	GcHeader* all;
	// Shapes, kept apart so the collector can fix transition lists without walking every object.
	GcHeader* shapes;
	// What the last collection marked and hasn't finished sweeping yet (see Vm.sweep_step).
	GcHeader* unswept;
	GcHeader** sweep_link;
	// Blocks allocated since the sweep last ran: sweeping is paid for by allocating.
	uint sweep_credit;
	usz bytes;
	// 0 means no limit.
	usz limit;
	// Open addressing on the string hash; null marks a free slot. Atoms are never collected yet.
	JsString*[] atoms;
	usz atom_count;
	// Shape-tree root for objects with a null prototype.
	Shape* null_root;
}

<*
 @require limit == 0 || limit >= 4096 : "Limit too small to be useful"
*>
fn void Heap.init(&self, usz limit = 0)
{
	*self = { .limit = limit };
	self.atoms = mem::new_array(JsString*, 256);
}

<*
 Free every allocation, reachable or not.
*>
fn void Heap.free(&self)
{
	foreach (list : (GcHeader*[3]){ self.all, self.shapes, self.unswept })
	{
		GcHeader* h = list;
		while (h)
		{
			GcHeader* next = h.next;
			finalize(h);
			free(h);
			h = next;
		}
	}
	free(self.atoms);
	*self = {};
}

<*
 A zeroed block of size bytes whose first field is a GcHeader of the given kind.

 @require size >= GcHeader::size : "Block smaller than its header"
 @require size <= uint::max : "Block too large"
 @return? OUT_OF_MEMORY
*>
fn void*? Heap.alloc(&self, HeapKind kind, usz size)
{
	if (self.limit && self.bytes + size > self.limit) return OUT_OF_MEMORY~;
	GcHeader* h = (GcHeader*)mem::calloc((sz)size);
	h.kind = kind;
	h.size = (uint)size;
	if (kind == SHAPE)
	{
		h.next = self.shapes;
		self.shapes = h;
	}
	else
	{
		h.next = self.all;
		self.all = h;
	}
	self.bytes += size;
	self.sweep_credit++;
	return h;
}

<*
 The atom with the same contents as s: an existing one, or s itself, which becomes the atom.

 @param [&inout] s : "String to intern"
 @return? OUT_OF_MEMORY
*>
fn JsString* Heap.intern(&self, JsString* s)
{
	if (s.atom) return s;
	uint hash = s.hash_code();
	usz mask = self.atoms.len - 1;
	usz i = hash & mask;
	while (JsString* a = self.atoms[i])
	{
		if (a.hash == hash && a.equals(s)) return a;
		i = (i + 1) & mask;
	}
	s.atom = true;
	self.atoms[i] = s;
	if (++self.atom_count * 2 > self.atoms.len) self.grow_atoms();
	return s;
}

fn void Heap.grow_atoms(&self)
{
	JsString*[] old = self.atoms;
	self.atoms = mem::new_array(JsString*, old.len * 2);
	usz mask = self.atoms.len - 1;
	foreach (a : old)
	{
		if (!a) continue;
		usz i = a.hash & mask;
		while (self.atoms[i]) i = (i + 1) & mask;
		self.atoms[i] = a;
	}
	free(old);
}

<*
 The atom for a UTF-8 name.

 @return? OUT_OF_MEMORY
*>
fn JsString*? Heap.atom(&self, String name)
{
	return self.intern(self.string_from_utf8(name)!);
}
