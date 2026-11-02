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
	// Everything the engine owns: GC blocks plus the memory they own outside themselves (slots,
	// elements, tables, buffer data). See extra_size.
	usz bytes;
	// Bytes of the last collection's garbage not swept yet; they don't count toward the next one.
	usz dead_pending;
	// Collect at the next safe point once bytes (less dead_pending) reach this.
	usz threshold;
	// 0 means no limit.
	usz limit;
	// What the last collection found live, and whether that alone was at the limit.
	usz live;
	bool at_limit;
	// Poison freed blocks (under --gc-stress), so a use after free crashes where it happens.
	bool poison;
	usz freed;
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
	growth = 0;
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

// Memory that objects grew or released outside their blocks since the heap last looked. Growth
// sites (slots, elements, tables) don't know their heap, so they count here and the heap folds it
// in at its next allocation or collection.
tlocal sz growth;

<*
 Count bytes an object took (or gave back, when negative) outside its GC block.
*>
fn void account(sz delta) @inline
{
	growth += delta;
}

fn void Heap.take_growth(&self) @inline
{
	self.bytes += (usz)growth;
	growth = 0;
}

<*
 A zeroed block of size bytes whose first field is a GcHeader of the given kind.

 @require size >= GcHeader::size : "Block smaller than its header"
 @require size <= uint::max : "Block too large"
 @return? OUT_OF_MEMORY
*>
fn void*? Heap.alloc(&self, HeapKind kind, usz size)
{
	self.take_growth();
	if (self.limit && self.bytes + size > self.limit) self.make_room(size)!;
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

fn void Heap.release_block(&self, GcHeader* h)
{
	self.bytes -= h.size + extra_size(h);
	finalize(h);
	if (self.poison) mem::set(h, 0xEE, h.size);
	free(h);
	self.freed++;
}

<*
 Sweep up to `budget` blocks of the last collection. Returns whether the sweep is done.
*>
fn bool Heap.sweep_step(&self, uint budget = SWEEP_SLICE)
{
	GcHeader** link = self.sweep_link;
	if (!link) return true;
	while (budget-- > 0)
	{
		GcHeader* h = *link;
		if (!h)
		{
			// Done: the survivors go back in front of everything allocated since.
			*link = self.all;
			self.all = self.unswept;
			self.unswept = null;
			self.sweep_link = null;
			self.dead_pending = 0;
			return true;
		}
		// Atoms are permanent until the atom table becomes weak.
		if (h.marked || (h.kind == STRING && ((JsString*)h).atom))
		{
			h.marked = false;
			link = &h.next;
			continue;
		}
		*link = h.next;
		usz size = h.size + extra_size(h);
		self.dead_pending = self.dead_pending > size ? self.dead_pending - size : 0;
		self.release_block(h);
	}
	self.sweep_link = link;
	return false;
}

fn void Heap.finish_sweep(&self)
{
	while (!self.sweep_step(uint::max)) {}
}

<*
 Room for size more bytes over the limit. Collecting can't happen here, since callers hold
 unrooted pointers: finish the last collection's sweep, then let the heap run over by an eighth
 of the limit and ask for a collection at the next safe point. Past that headroom it fails.

 @return? OUT_OF_MEMORY
*>
fn void? Heap.make_room(&self, usz size)
{
	self.finish_sweep();
	if (self.bytes + size <= self.limit) return;
	if (self.bytes + size > self.limit + self.limit / 8)
	{
		// Whatever the script drops while handling the error is collected at the next safe point.
		self.threshold = 0;
		return OUT_OF_MEMORY~;
	}
	// After a collection that found the heap full, only ask again once enough was allocated
	// since for it to have a chance; asking at every allocation would collect at every one.
	if (!self.at_limit || self.bytes - self.live >= self.limit / 16) self.threshold = 0;
}
