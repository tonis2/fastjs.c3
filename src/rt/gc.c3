module fastjs::rt;
import std::collections::list;

// Stop-the-world mark and sweep. Collection happens only at safe points: instruction boundaries
// in the interpreter, and never while a native function is on the C stack, so native code never
// has to protect its own temporaries. Everything live is then reachable from registers, frames,
// globals, built-ins, script slots and the host's roots.

const usz GC_MIN_THRESHOLD = 4 * 1024 * 1024;

alias MarkStack = List {GcHeader*};

fn void mark_ptr(MarkStack* stack, void* p) @inline
{
	GcHeader* h = p;
	if (!h) return;
	// A freed (poisoned) block here means a root or a field still points at dead memory.
	assert((char)h.kind < (char)HeapKind::len && h.size != 0xEEEEEEEE, "GC reached a freed block");
	if (h.marked) return;
	h.marked = true;
	stack.push(h);
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
	if (self.heap.bytes >= self.gc_threshold && self.native_depth == 0) self.collect();
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
	mark_ptr(stack, self.data_view_proto);
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
				case COROUTINE:
					JsCoroutine* c = (JsCoroutine*)o;
					mark_ptr(stack, c.function);
					mark_value(stack, c.promise);
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

<*
 Free everything unreachable.
*>
fn void Vm.collect(&self)
{
	MarkStack stack;
	stack.init(mem, 256);
	defer stack.free();
	self.mark_roots(&stack);
	while (try h = stack.pop()) trace(&stack, h);

	// Dead shapes must leave their parents' transition lists before they are freed.
	for (GcHeader* h = self.heap.all; h; h = h.next)
	{
		if (h.kind != SHAPE || !h.marked) continue;
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
	// An unmarked prototype root can't be reused either.
	for (GcHeader* h = self.heap.all; h; h = h.next)
	{
		if (h.kind == OBJECT && h.marked)
		{
			JsObject* o = (JsObject*)h;
			if (o.child_root && !o.child_root.marked) o.child_root = null;
		}
	}

	GcHeader** link = &self.heap.all;
	usz freed = 0;
	while (GcHeader* h = *link)
	{
		// Atoms are permanent until the atom table becomes weak.
		if (h.marked || (h.kind == STRING && ((JsString*)h).atom))
		{
			h.marked = false;
			link = &h.next;
			continue;
		}
		*link = h.next;
		self.heap.bytes -= h.size;
		if (h.kind == OBJECT && ((JsObject*)h).kind == ARRAY_BUFFER && !((JsArrayBuffer*)h).external) self.heap.bytes -= ((JsArrayBuffer*)h).byte_length;
		finalize(h);
		// Under stress, poison dead blocks so a use after free crashes where it happens.
		if (self.gc_stress) mem::set(h, 0xEE, h.size);
		free(h);
		freed++;
	}
	foreach (script : self.scripts) script.main.clear_ics();
	foreach (m : self.modules) m.main.clear_ics();
	if (self.gc_stress) self.verify_heap();
	self.gc_count++;
	self.gc_freed += freed;
	self.gc_threshold = self.gc_stress ? 0 : max(self.heap.bytes * 2, GC_MIN_THRESHOLD);
}

<*
 Check heap invariants; used under --gc-stress to catch corruption close to its cause.
*>
fn void Vm.verify_heap(&self)
{
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
