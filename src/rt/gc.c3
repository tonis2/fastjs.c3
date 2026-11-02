module fastjs::rt;
import std::collections::list, std::time, std::io;

// Incremental mark and lazy sweep. GC work happens only at safe points: instruction boundaries
// in the interpreter, and never while a native function is on the C stack, so native code never
// has to protect its own temporaries. Everything live is then reachable from registers, frames,
// globals, built-ins, script slots and the host's roots.
//
// Marking runs in slices between safe points (tri-color: white unmarked, gray marked and on the
// gray stack, black marked and traced). What keeps it sound while the script runs on:
//  - Blocks allocated while marking start gray, so whatever they are filled with gets traced.
//  - A store into a marked block puts the block back on the gray stack (`Heap.touch`), so a
//    reference moved into an already-traced block is seen. Natives are never interrupted by a
//    slice, so instead of barriers inside every native, the interpreter touches a native's
//    `this`, arguments and callee after it returns.
//  - Roots are not barriered: the final remark marks them again and drains the gray stack, in
//    one pause.
// Under --gc-stress every remark is checked against a full reachability walk (verify_marking).

const usz GC_MIN_THRESHOLD = 4 * 1024 * 1024;
// Blocks traced per safe point while marking: at least the minimum, more when the script allocates.
const uint MARK_SLICE_MIN = 64;
const uint MARK_PER_ALLOC = 8;

const ushort GC_GRAY = 1;
const ushort GC_COUNTED = 2;
const ushort GC_VERIFIED = 4;
const ushort GC_DOOMED = 8;

struct MarkStack
{
	List {GcHeader*} stack;
	// Checking a finished mark: every block reached must already be marked.
	bool verify;
}

fn void mark_ptr(MarkStack* m, void* p) @inline
{
	GcHeader* h = p;
	if (!h) return;
	// A freed (poisoned) block here means a root or a field still points at dead memory.
	assert((char)h.kind < (char)HeapKind::len && h.size != 0xEEEEEEEE, "GC reached a freed block");
	if (m.verify)
	{
		assert(h.marked, "incremental marking missed a reachable %s block: a store is missing its barrier", h.kind);
		if (h.flags & GC_VERIFIED) return;
		h.flags |= GC_VERIFIED;
		m.stack.push(h);
		return;
	}
	if (h.marked) return;
	h.marked = true;
	h.flags |= GC_GRAY;
	m.stack.push(h);
}

fn void mark_value(MarkStack* stack, Value v) @inline
{
	if (v.is_heap()) mark_ptr(stack, v.as_pointer());
}

<*
 Collect if the heap has grown past its threshold and this is a safe point.
*>
fn void Vm.maybe_gc(&self) @inline
{
	// Sweeping is paid for by allocating (sweep_ratio blocks per block), so it keeps ahead of
	// new garbage without landing in one frame, which freeing a collection's worth at once would.
	if ((self.heap.sweep_link || self.heap.doomed) && self.heap.sweep_credit)
	{
		self.sweep_step(min(self.heap.sweep_credit * self.heap.sweep_ratio, SWEEP_SLICE));
		self.heap.sweep_credit = 0;
	}
	// Growth outside blocks is folded in by the next allocation, not here: this runs at every
	// backward jump, and touching the counter here made a plain loop 4x slower.
	if (self.heap.bytes - self.heap.dead_pending >= self.heap.threshold && self.native_depth == 0) self.gc_work();
}

<*
 The GC's turn at a safe point: start marking, mark a slice, or finish.
*>
fn void Vm.gc_work(&self)
{
	Heap* heap = &self.heap;
	if (!heap.marking)
	{
		// A mark can't start until the last sweep is done. Rather than finish it in one pause,
		// sweep a slice per safe point until it is; only the memory limit can't wait.
		if ((heap.sweep_link || heap.doomed) && !heap.urgent && !self.gc_stress)
		{
			self.sweep_step(SWEEP_SLICE);
			return;
		}
		// Under stress, alternate whole collections with incremental ones in tiny slices.
		if (!self.incremental || heap.urgent || (self.gc_stress && self.gc_count % 2 == 0))
		{
			self.collect();
			return;
		}
		self.start_marking();
		return;
	}
	if (heap.urgent)
	{
		self.finish_marking();
		return;
	}
	// Marking must outpace allocation, since every new block starts gray. Under stress, slices
	// are as small as that allows, to interleave with the script as often as possible.
	uint budget = self.gc_stress ? heap.sweep_credit * 4 + 8 : max(heap.sweep_credit * MARK_PER_ALLOC, MARK_SLICE_MIN);
	heap.sweep_credit = 0;
	if (self.mark_slice(budget)) self.finish_marking();
}

<*
 GC work in time the host has to spare, such as the idle end of a frame: finish the sweep,
 advance a mark, and start the next mark early once the heap is three quarters of the way to
 its threshold, so less of it is left for the script's own safe points.
*>
fn void Vm.gc_step(&self, long budget_ns)
{
	if (self.native_depth) return;
	Clock started = clock::now();
	Heap* heap = &self.heap;
	heap.take_growth();
	while ((long)started.to_now() < budget_ns)
	{
		if (heap.marking)
		{
			if (self.mark_slice(256)) self.finish_marking();
			continue;
		}
		if (heap.sweep_link || heap.doomed)
		{
			self.sweep_step(256);
			continue;
		}
		if (heap.bytes - heap.dead_pending < heap.threshold / 4 * 3) break;
		self.start_marking();
	}
}

<*
 Begin an incremental mark: gray the roots. Every safe point after this marks a slice.
*>
fn void Vm.start_marking(&self)
{
	Clock started = clock::now();
	Heap* heap = &self.heap;
	self.finish_sweep();
	if (self.gc_trace && (long)started.to_now() > 500_000) io::eprintfn("fastjs gc: finishing the last sweep took %.3f ms (ratio %d, %d blocks)", (long)started.to_now() / 1e6, heap.sweep_ratio, heap.blocks);
	heap.take_growth();
	heap.poison = self.gc_stress;
	heap.marked_live = 0;
	heap.gray.stack.clear();
	heap.marking = true;
	self.mark_roots(&heap.gray);
	heap.threshold = 0;
	heap.sweep_credit = 0;
	self.note_pause((long)started.to_now(), true, "start of marking");
}

<*
 Trace up to budget gray blocks. Returns whether the gray stack is empty.
*>
fn bool Vm.mark_slice(&self, uint budget)
{
	Clock started = clock::now();
	Heap* heap = &self.heap;
	MarkStack* m = &heap.gray;
	bool done = false;
	while (budget-- > 0)
	{
		GcHeader*? h = m.stack.pop();
		if (catch h)
		{
			done = true;
			break;
		}
		h.flags &= (ushort)~GC_GRAY;
		if (!(h.flags & GC_COUNTED))
		{
			h.flags |= GC_COUNTED;
			heap.marked_live += h.size + extra_size(h);
		}
		trace(m, h);
	}
	self.note_pause((long)started.to_now(), true);
	return done || m.stack.is_empty();
}

<*
 Collect everything unreachable now, finishing a mark in progress if there is one.
*>
fn void Vm.collect(&self)
{
	if (!self.heap.marking) self.start_marking();
	self.finish_marking();
}

fn void Vm.note_pause(&self, long ns, bool marking, String what = "slice")
{
	if (self.gc_trace && ns > 500_000) io::eprintfn("fastjs gc: %s took %.3f ms", what, ns / 1e6);
	self.gc_total_ns += ns;
	if (marking) self.gc_mark_ns += ns;
	if (ns > self.gc_max_ns) self.gc_max_ns = ns;
}

fn void Vm.mark_roots(&self, MarkStack* stack)
{
	// Scan every live frame's whole register window. A callee's window can end below its caller's
	// dead temporaries; skipping those would free objects whose pointers come back into view when
	// the callee returns.
	uint top = self.stack_top;
	for (uint i = 0; i < self.frame_count; i++)
	{
		Frame* f = &self.frames[i];
		top = max(top, f.base + f.proto.nregs);
	}
	for (uint i = 0; i < top; i++) mark_value(stack, self.stack[i]);
	for (uint i = 0; i < self.frame_count; i++)
	{
		Frame* f = &self.frames[i];
		mark_ptr(stack, f.function);
		mark_value(stack, f.new_target);
		mark_ptr(stack, f.coroutine);
	}
	mark_ptr(stack, self.generator_proto);
	mark_ptr(stack, self.async_generator_proto);
	mark_ptr(stack, self.async_generator_function_proto);
	mark_ptr(stack, self.async_function_proto);
	mark_ptr(stack, self.generator_function_proto);
	mark_ptr(stack, self.data_view_proto);
	mark_ptr(stack, self.proxy_holder);
	mark_ptr(stack, self.promise_proto);
	for (sz i = self.job_head; i < self.jobs.len(); i++) mark_job(stack, &self.jobs[i]);
	mark_job(stack, &self.current_job);
	foreach (v : self.unhandled) mark_value(stack, v);
	foreach (m : self.modules)
	{
		if (m.boxes)
		{
			for (usz i = 0; i < m.cells.len; i++) mark_ptr(stack, m.boxes[i]);
		}
		mark_ptr(stack, m.function);
		foreach (e : m.exports) mark_ptr(stack, e.box);
		mark_value(stack, m.namespace);
		mark_value(stack, m.promise);
	}
	mark_value(stack, self.exception);
	mark_ptr(stack, self.global);
	mark_ptr(stack, self.object_proto);
	mark_ptr(stack, self.function_proto);
	mark_ptr(stack, self.array_proto);
	mark_ptr(stack, self.string_proto);
	mark_ptr(stack, self.number_proto);
	mark_ptr(stack, self.boolean_proto);
	foreach (p : self.error_protos) mark_ptr(stack, p);
	foreach (v : self.slots) mark_value(stack, v);
	foreach (v : self.roots) mark_value(stack, v);
	foreach (v : self.template_objects) mark_value(stack, v);
	foreach (c : self.native_classes) mark_ptr(stack, c.proto);
	mark_ptr(stack, self.heap.null_root);
	mark_ptr(stack, self.symbol_proto);
	mark_ptr(stack, self.iterator_proto);
	mark_ptr(stack, self.map_proto);
	mark_ptr(stack, self.set_proto);
	mark_ptr(stack, self.array_buffer_proto);
	mark_ptr(stack, self.regexp_proto);
	foreach (p : self.typed_protos) mark_ptr(stack, p);
	mark_value(stack, self.sym_iterator);
	mark_value(stack, self.sym_async_iterator);
	mark_value(stack, self.sym_species);
	mark_value(stack, self.promise_ctor);
}

fn void mark_job(MarkStack* stack, Job* job)
{
	mark_value(stack, job.handler);
	mark_value(stack, job.target);
	mark_value(stack, job.argument);
}

fn void trace(MarkStack* stack, GcHeader* h)
{
	switch (h.kind)
	{
		case STRING:
			JsString* str = (JsString*)h;
			if (str.buffered()) mark_ptr(stack, str.buffer());
		case STRBUF:
			break;
		case SYMBOL:
			mark_value(stack, ((JsSymbol*)h).description);
		case BOX:
			mark_value(stack, ((Box*)h).value);
		case SHAPE:
			Shape* s = (Shape*)h;
			mark_ptr(stack, s.parent);
			mark_ptr(stack, s.proto);
			mark_value(stack, s.key);
		case OBJECT:
			JsObject* o = (JsObject*)h;
			mark_ptr(stack, o.shape);
			mark_ptr(stack, o.child_root);
			for (uint i = 0; i < o.shape.count; i++) mark_value(stack, o.slots[i]);
			switch (o.kind)
			{
				case ARRAY:
					JsArray* a = (JsArray*)o;
					for (uint i = 0; i < a.length; i++) mark_value(stack, a.elements[i]);
				case FUNCTION:
					JsFunction* f = (JsFunction*)o;
					if (f.proto)
					{
						for (usz i = 0; i < f.proto.captures.len; i++) mark_ptr(stack, f.captures[i]);
					}
					mark_value(stack, f.bound_this);
					mark_ptr(stack, f.home_object);
					mark_value(stack, f.fields_init);
					mark_value(stack, f.native_data);
					mark_value(stack, f.native_data2);
				case MAP:
					JsMap* m = (JsMap*)o;
					for (uint i = 0; i < m.used; i++)
					{
						mark_value(stack, m.entries[i].key);
						mark_value(stack, m.entries[i].value);
					}
				case ITERATOR:
					mark_value(stack, ((JsIterator*)o).target);
				case TYPED_ARRAY:
				case DATA_VIEW:
					mark_ptr(stack, ((JsTypedArray*)o).buffer);
				case REGEXP:
					mark_value(stack, ((JsRegExp*)o).source);
					mark_value(stack, ((JsRegExp*)o).flags);
				case PROXY:
					mark_value(stack, ((JsFunction*)o).native_data);
					mark_value(stack, ((JsFunction*)o).native_data2);
				case COROUTINE:
					JsCoroutine* c = (JsCoroutine*)o;
					mark_ptr(stack, c.function);
					mark_value(stack, c.promise);
					mark_value(stack, c.queue);
					for (uint i = 0; i < c.nregs; i++) mark_value(stack, c.regs[i]);
				case PROMISE:
					JsPromise* p = (JsPromise*)o;
					mark_value(stack, p.result);
					foreach (r : p.reactions)
					{
						mark_value(stack, r.target);
						mark_value(stack, r.on_fulfilled);
						mark_value(stack, r.on_rejected);
					}
				case ACCESSOR:
					Accessor* acc = (Accessor*)o;
					mark_value(stack, acc.getter);
					mark_value(stack, acc.setter);
				default:
					break;
			}
	}
}

const uint SWEEP_SLICE = 1024;

<*
 The remark: mark the roots again, drain the gray stack, then hand the dead to the lazy sweep.
 Shapes are swept at once, because dead ones must leave their parents' transition lists first.
*>
fn void Vm.finish_marking(&self)
{
	Clock started = clock::now();
	Heap* heap = &self.heap;
	self.mark_roots(&heap.gray);
	while (!self.mark_slice(uint::max)) {}
	if (self.gc_stress || self.gc_verify) self.verify_marking();
	heap.marking = false;
	heap.urgent = false;
	usz live = heap.marked_live;
	long marked_ns = (long)started.to_now();

	// Dead shapes leave their parents' transition lists now, so nothing can reach them again,
	// but they are freed only once every inline cache that points at one has been cleared,
	// which scan_ics does lazily: scanning every cache at once was most of the pause.
	for (GcHeader* h = heap.shapes; h; h = h.next)
	{
		if (!h.marked) continue;
		Shape** link = &((Shape*)h).first_child;
		while (Shape* child = *link)
		{
			if (child.marked)
			{
				link = &child.next_sibling;
			}
			else
			{
				*link = child.next_sibling;
			}
		}
	}
	GcHeader** link = &heap.shapes;
	while (GcHeader* h = *link)
	{
		if (h.marked)
		{
			h.marked = false;
			h.flags = 0;
			link = &h.next;
			continue;
		}
		*link = h.next;
		// Checking: nothing but a cache may touch a doomed shape, so poison everything after its header.
		if (self.gc_verify)
		{
			Shape* dead = (Shape*)h;
			heap.bytes -= extra_size(h);
			free(dead.table);
			mem::set((char*)h + GcHeader::size, 0xEE, h.size - GcHeader::size);
			dead.table = null;
		}
		h.flags = GC_DOOMED;
		h.next = heap.doomed;
		heap.doomed = h;
	}
	self.ic_scan.clear();
	if (heap.doomed)
	{
		foreach (script : self.scripts) self.ic_scan.push(script.main);
		foreach (m : self.modules) self.ic_scan.push(m.main);
	}
	// Objects allocated from here on go on a fresh list; the marked one is swept lazily.
	heap.unswept = heap.all;
	heap.all = null;
	heap.sweep_link = &heap.unswept;
	heap.dead_pending = heap.bytes > live ? heap.bytes - live : 0;
	if (self.gc_stress)
	{
		self.finish_sweep();
		self.verify_heap();
	}
	self.gc_count++;
	long total_ns = (long)started.to_now();
	self.gc_sweep_ns += total_ns - marked_ns;
	self.note_pause(total_ns, false, "remark");
	heap.threshold = self.next_threshold(live);
	heap.live = live;
	// Sweep fast enough to be done by the time the heap reaches the next threshold.
	usz average = heap.blocks ? max(heap.bytes / heap.blocks, (usz)16) : 64;
	usz allocations = max((heap.threshold > live ? heap.threshold - live : 0) / average, (usz)1);
	heap.sweep_ratio = (uint)min(max(heap.blocks / allocations + 1, (usz)2), (usz)64);
	heap.at_limit = heap.limit && live >= heap.limit;
	if (self.gc_trace) io::eprintfn("fastjs gc #%d: remark %.3f ms (mark %.3f), live %d KiB, next at %d KiB, %d blocks, sweep ratio %d, %d host roots", self.gc_count, total_ns / 1e6, marked_ns / 1e6, live / 1024, heap.threshold / 1024, heap.blocks, heap.sweep_ratio, self.roots.len());
}

<*
 Under --gc-stress: walk everything reachable again and check the incremental mark found it.
*>
fn void Vm.verify_marking(&self)
{
	MarkStack v = { .verify = true };
	v.stack.init(mem, 256);
	defer v.stack.free();
	self.mark_roots(&v);
	while (try h = v.stack.pop()) trace(&v, h);
	for (GcHeader* h = self.heap.all; h; h = h.next) h.flags &= (ushort)~GC_VERIFIED;
	for (GcHeader* h = self.heap.shapes; h; h = h.next) h.flags &= (ushort)~GC_VERIFIED;
}

<*
 Where the next collection starts: at twice the live size, but with a memory limit, early enough
 that collecting at a safe point comes before the limit does.
*>
fn usz Vm.next_threshold(&self, usz live)
{
	if (self.gc_stress) return 0;
	usz next = max(live * 2, self.gc_min_threshold);
	usz limit = self.heap.limit;
	if (!limit) return next;
	usz room = limit > live ? limit - live : 0;
	return min(next, live + max(room / 2, limit / 16));
}

fn void Vm.release_block(&self, GcHeader* h) @inline => self.heap.release_block(h);
<*
 Sweep up to budget blocks, after clearing the inline caches that point at dead shapes and
 freeing those. Returns whether everything the last mark left behind is done.
*>
fn bool Vm.sweep_step(&self, uint budget = SWEEP_SLICE)
{
	if (self.heap.doomed)
	{
		if (!self.scan_ics(budget * 8)) return false;
		budget /= 2;
	}
	return self.heap.sweep_step(budget);
}

fn void Vm.finish_sweep(&self)
{
	while (!self.sweep_step(uint::max)) {}
}

<*
 Clear inline caches pointing at doomed shapes, about budget entries' worth, then free the
 shapes. Returns whether that is done.
*>
fn bool Vm.scan_ics(&self, uint budget)
{
	usz done = 0;
	while (done < budget)
	{
		FunctionProto*? p = self.ic_scan.pop();
		if (catch p) break;
		p.clear_dead_ics();
		foreach (child : p.protos) self.ic_scan.push(child);
		done += p.ics.len + 1;
	}
	if (self.ic_scan.len()) return false;
	while (GcHeader* h = self.heap.doomed)
	{
		self.heap.doomed = h.next;
		self.release_block(h);
	}
	return true;
}

<*
 Check heap invariants; used under --gc-stress to catch corruption close to its cause.
*>
fn void Vm.verify_heap(&self)
{
	// Every byte the heap counts belongs to a block or to memory a block owns.
	self.heap.take_growth();
	usz counted = 0;
	for (GcHeader* h = self.heap.shapes; h; h = h.next) counted += h.size + extra_size(h);
	for (GcHeader* h = self.heap.all; h; h = h.next) counted += h.size + extra_size(h);
	for (GcHeader* h = self.heap.doomed; h; h = h.next) counted += h.size + extra_size(h);
	assert(counted == self.heap.bytes, "heap counts %d bytes but blocks own %d", self.heap.bytes, counted);
	for (GcHeader* h = self.heap.shapes; h; h = h.next) assert(!h.marked, "mark bit left set on a shape");
	for (GcHeader* h = self.heap.all; h; h = h.next)
	{
		assert(!h.marked, "mark bit left set");
		switch (h.kind)
		{
			case OBJECT:
				JsObject* o = (JsObject*)h;
				assert(o.shape && o.shape.kind == SHAPE, "object without a valid shape");
				assert(o.shape.count <= o.slot_cap || o.shape.count == 0, "shape has more properties than the object has slots");
				if (o.kind == ARRAY) assert(((JsArray*)o).length <= ((JsArray*)o).cap || ((JsArray*)o).length == 0, "array length past capacity");
			case SHAPE:
				Shape* s = (Shape*)h;
				if (s.parent) assert(s.parent.kind == SHAPE, "shape parent is not a shape");
			default:
				break;
		}
	}
}
