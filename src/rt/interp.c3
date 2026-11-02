module fastjs::rt;
import std::math, std::collections::list;

<*
 Run from the top frame until a frame marked `stop` returns, handling exceptions on the way.
 With `throwing`, the pending exception is first thrown at the top frame's current instruction.

 @return? THROWN
*>
fn Value? Vm.execute(&self, bool throwing = false)
{
	while (true)
	{
		if (!throwing)
		{
			Value? v = self.run();
			if (try v) return v;
		}
		throwing = false;
		Value result;
		switch (self.unwind(&result))
		{
			case HANDLED: continue;
			case PROPAGATE: return THROWN~;
			case RETURNED: return result;
		}
	}
}

enum Unwind : char
{
	// A handler was found, or an async call turned the exception into its rejected promise.
	HANDLED,
	// The exception leaves a `stop` frame; its native caller sees it.
	PROPAGATE,
	// A `stop` frame that was an async call returned its rejected promise instead.
	RETURNED,
}

<*
 Find a handler for the pending exception, popping frames that have none. An async call doesn't
 pass the exception on: its promise is rejected and returned as the call's value.
*>
fn Unwind Vm.unwind(&self, Value* result)
{
	while (self.frame_count > 0)
	{
		Frame* f = &self.frames[self.frame_count - 1];
		uint pc = f.pc - 1;
		foreach (h : f.proto.handlers)
		{
			if (pc >= h.start && pc < h.end && !self.uncatchable)
			{
				self.stack[f.base + h.reg] = self.exception;
				f.pc = h.handler;
				self.stack_top = f.base + f.proto.nregs;
				return HANDLED;
			}
		}
		bool stop = f.stop;
		uint base = f.base;
		JsCoroutine* c = f.coroutine;
		self.frame_count--;
		if (self.frame_count > 0)
		{
			Frame* caller = &self.frames[self.frame_count - 1];
			self.stack_top = caller.base + caller.proto.nregs;
		}
		if (c)
		{
			c.finish();
			if (c.is_async)
			{
				self.reject_with_exception((JsPromise*)c.promise.as_object());
				self.stack[base - 1] = c.promise;
				*result = c.promise;
				return stop ? RETURNED : HANDLED;
			}
		}
		if (stop) return PROPAGATE;
	}
	return PROPAGATE;
}

<*
 The object whose prototype a `super` reference in frame f starts from.

 @return? THROWN
*>
fn JsObject*? Vm.super_home(&self, Frame* f, Value* r) @inline
{
	JsObject* home = f.function.home_object;
	if (!home) return self.throw_error(SYNTAX_ERROR, "'super' keyword unexpected here")~;
	if (r[0] == UNINITIALIZED) return self.no_super_error()~;
	return home;
}

<*
 `super[key] = v`: look key up from start, but with `this` as the receiver: a setter found
 is called on it, and otherwise the property is written on it, not on the prototype.

 @return? THROWN
*>
fn void? Vm.set_super(&self, JsObject* start, Value key, Value v, Value receiver)
{
	for (JsObject* o = start; o; o = o.proto())
	{
		Shape* s = o.find_own(key);
		if (!s) continue;
		if (s.flags.accessor) return self.call_setter(o.slots[s.slot()], receiver, key, v);
		if (!s.flags.writable) return self.throw_error(TYPE_ERROR, "Cannot assign to read only property '%s' of object", self.key_text(key))~;
		break;
	}
	if (!receiver.is_object()) return self.throw_error(TYPE_ERROR, "Cannot assign to property '%s' of %s", self.key_text(key), self.describe(receiver))~;
	JsObject* target = receiver.as_object();
	Shape* own = target.find_own(key);
	if (own && !own.flags.accessor && own.flags.writable)
	{
		target.slots[own.slot()] = v;
		self.heap.touch(target);
		return;
	}
	self.define(target, key, v)!;
}

<*
 The generator of a for-of's iterator state, when the loop can run it inline: a generator
 object stepped by the built-in next, not running already. A finished one is returned too, so
 the loop just ends.
*>
fn JsCoroutine* Vm.inline_generator(&self, Value* state) @inline
{
	if (!state[0].is_object() || state[0].as_object().kind != COROUTINE || !state[1].is_function()) return null;
	JsFunction* next = (JsFunction*)state[1].as_object();
	if (next.native != &native_generator_resume || next.magic != 0) return null;
	JsCoroutine* c = (JsCoroutine*)state[0].as_object();
	if (c.is_async || c.async_gen || c.state == RUNNING) return null;
	return c;
}

<*
 Push generator c's frame to run inside the interpreter loop, as resume() would for next():
 what it yields goes to stack[dest] and the caller carries on at its own pc; when it returns,
 the caller goes to exit.

 @return? THROWN
*>
fn Frame*? Vm.enter_generator(&self, JsCoroutine* c, uint dest, uint exit)
{
	FunctionProto* p = c.function.proto;
	if (c.state == SUSPENDED)
	{
		// The value next() sends, and NEXT for the suspending YIELD's mode register.
		uint ins = p.code[c.pc - 1];
		c.regs[ins_a(ins)] = UNDEFINED;
		if (ins_op(ins) == YIELD) c.regs[ins_b(ins)] = integer((int)ResumeMode.NEXT.ordinal);
		self.heap.touch(c);
	}
	uint base = self.stack_top + 1;
	if (self.frame_count == MAX_FRAMES || base + p.nregs + 2 >= STACK_SIZE)
	{
		return self.throw_error(RANGE_ERROR, "Maximum call stack size exceeded")~;
	}
	self.stack[base - 1] = UNDEFINED;
	copy_values(self.stack + base, c.regs, c.nregs);
	Frame* g = &self.frames[self.frame_count++];
	*g = { .proto = p, .function = c.function, .pc = c.pc, .base = base, .new_target = UNDEFINED, .coroutine = c, .inline_iter = true, .iter_dest = dest, .iter_exit = exit };
	self.stack_top = base + p.nregs;
	c.state = RUNNING;
	return g;
}

fn Value int_or_double(long v) @inline
{
	if (v >= int::min && v <= int::max) return integer((int)v);
	return double_value((double)v);
}

<*
 Arithmetic and bitwise operators on non-int operands.

 @return? THROWN
*>
fn Value? Vm.arith(&self, Op op, Value b, Value c)
{
	if (op == ADD) return self.add(b, c);
	switch (op)
	{
		case BAND:
		case BOR:
		case BXOR:
		case SHL:
		case SAR:
		case SHR:
			int x = self.to_int32(b)!;
			int y = self.to_int32(c)!;
			switch (op)
			{
				case BAND: return integer(x & y);
				case BOR: return integer(x | y);
				case BXOR: return integer(x ^ y);
				case SHL: return integer(x << (y & 31));
				case SAR: return integer(x >> (y & 31));
				default: return number((double)((uint)x >> (y & 31)));
			}
		default:
			break;
	}
	double x = self.to_number(b)!;
	double y = self.to_number(c)!;
	switch (op)
	{
		case SUB: return double_value(x - y);
		case MUL: return double_value(x * y);
		case DIV: return double_value(x / y);
		case MOD: return double_value(js_mod(x, y));
		case POW: return double_value(js_pow(x, y));
		default: unreachable("not an arithmetic op");
	}
}

<*
 Comparison operators.

 @return? THROWN
*>
fn bool? Vm.compare(&self, Op op, Value b, Value c)
{
	switch (op)
	{
		case EQ: return self.loose_equals(b, c);
		case NE: return !self.loose_equals(b, c)!;
		case SEQ: return strict_equals(b, c);
		case SNE: return !strict_equals(b, c);
		case LT: return self.less_than(b, c, false);
		case LE: return self.less_than(c, b, false)! ? false : !self.is_nan_compare(b, c)!;
		case GT: return self.less_than(c, b, false);
		case GE: return self.less_than(b, c, false)! ? false : !self.is_nan_compare(b, c)!;
		case INSTANCEOF: return self.instance_of(b, c);
		case IN: return self.has_property(c, self.to_key(b)!);
		default: unreachable("not a comparison op");
	}
}

// a <= b is !(b < a), except that any NaN makes every comparison false.
fn bool? Vm.is_nan_compare(&self, Value b, Value c)
{
	Value pb = self.to_primitive(b)!;
	Value pc = self.to_primitive(c)!;
	if (pb.is_string() && pc.is_string()) return false;
	double x = self.to_number(pb)!;
	double y = self.to_number(pc)!;
	return x != x || y != y;
}

<*
 Build a closure for proto, capturing from the creating frame.

 @return? THROWN
*>
fn Value? Vm.make_closure(&self, Frame* f, FunctionProto* proto)
{
	JsFunction* fun = (JsFunction*)self.heap.new_object(self.function_proto_for(proto), FUNCTION, JsFunction::size) ?? self.oom()~!;
	fun.proto = proto;
	if (proto.captures.len)
	{
		fun.captures = mem::new_array(Box*, proto.captures.len).ptr;
		Value* r = self.stack + f.base;
		foreach (i, src : proto.captures)
		{
			fun.captures[i] = src.from_capture ? f.function.captures[src.index] : (Box*)r[src.index].as_pointer();
		}
	}
	fun.fields_init = UNDEFINED;
	if (proto.is_arrow)
	{
		fun.bound_this = self.stack[f.base];
		fun.home_object = f.function.home_object;
	}
	return object_value(fun);
}

<*
 Move the argument array at r[a + 2] into consecutive registers from r[a + 2].

 @return? THROWN
*>
fn uint? Vm.unpack_spread(&self, Value* r, uint base, uint a)
{
	JsArray* list = (JsArray*)r[a + 2].as_object();
	uint argc = list.length;
	if (base + a + 2 + argc + 2 >= STACK_SIZE) return self.throw_error(RANGE_ERROR, "Maximum call stack size exceeded")~;
	// The array is read while its own register is being overwritten, so copy it out first.
	Value* tmp = mem::new_array(Value, argc ? argc : 1).ptr;
	defer free(tmp);
	for (uint i = 0; i < argc; i++) tmp[i] = list.elements[i] == EMPTY ? UNDEFINED : list.elements[i];
	for (uint i = 0; i < argc; i++) r[a + 2 + i] = tmp[i];
	return argc;
}

<*
 Every INTERRUPT_INTERVAL backward jumps and calls, ask the host whether to stop. Stopping throws
 an error no try/catch in the script can catch.

 @return? THROWN
*>
fn void? Vm.check_interrupt(&self)
{
	if (--self.interrupt_countdown > 0) return;
	self.interrupt_countdown = INTERRUPT_INTERVAL;
	if (!self.interrupt(self.interrupt_runtime, self.interrupt_opaque)) return;
	(void)self.throw_error(ERROR, "interrupted");
	self.uncatchable = true;
	return THROWN~;
}

fn fault Vm.no_super_error(&self)
{
	return self.throw_error(REFERENCE_ERROR, "Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
}

<*
 Wire up a class: its prototype object, `constructor`, and inheritance from parent.

 @return? THROWN
*>
fn Value? Vm.define_class(&self, Value ctor_value, Value parent, bool has_extends)
{
	JsFunction* ctor = (JsFunction*)ctor_value.as_object();
	JsObject* proto_parent = self.object_proto;
	if (has_extends)
	{
		if (parent.is_null())
		{
			proto_parent = null;
		}
		else
		{
			bool constructible = parent.is_function() && (((JsFunction*)parent.as_object()).native || ((JsFunction*)parent.as_object()).proto.is_constructor());
			if (!constructible) return self.throw_error(TYPE_ERROR, "Class extends value %s is not a constructor or null", self.describe(parent))~;
			Value pp = self.get(parent, self.atoms.prototype)!;
			if (!pp.is_object() && !pp.is_null()) return self.throw_error(TYPE_ERROR, "Class extends value does not have valid prototype property %s", self.describe(pp))~;
			proto_parent = pp.is_object() ? pp.as_object() : null;
			// Static members are inherited through the constructor's own prototype.
			((JsObject*)ctor).set_proto(&self.heap, parent.as_object()) ?? self.oom()~!;
		}
	}
	JsObject* proto = self.heap.new_object(proto_parent) ?? self.oom()~!;
	proto.add(&self.heap, self.atoms.constructor, ctor_value, METHOD_PROP) ?? self.oom()~!;
	self.define(ctor, self.atoms.prototype, object_value(proto), {})!;
	return object_value(proto);
}

fn fault Vm.tdz_error(&self, Value name)
{
	return self.throw_error(REFERENCE_ERROR, "Cannot access '%s' before initialization", name.as_string().tutf8());
}

<*
 The keys a for-in visits: enumerable string keys, own first, then inherited ones not shadowed.

 @return? THROWN
*>
fn Value? Vm.for_in_keys(&self, Value v)
{
	JsArray* keys = self.heap.new_array(self.array_proto) ?? self.oom()~!;
	if (!v.is_object()) return object_value(keys);
	List {Value} seen;
	seen.init(mem);
	defer seen.free();
	for (JsObject* o = v.as_object(); o; o = o.proto())
	{
		List {Value} own;
		own.init(mem);
		defer own.free();
		self.own_keys(o, &own)!;
		foreach (key : own)
		{
			if (seen.contains(key)) continue;
			seen.push(key);
			keys.push(key.is_int() ? string_value(self.to_string(key)!) : key);
		}
	}
	return object_value(keys);
}

<*
 Execute bytecode from the top frame. Returns when a `stop` frame returns, or with THROWN
 when an instruction throws; the frame's pc then points just past that instruction.

 @return? THROWN
*>
fn Value? Vm.run(&self)
{
	Frame* f = &self.frames[self.frame_count - 1];
	uint* code = f.proto.code.ptr;
	Value* k = f.proto.consts.ptr;
	Value* r = self.stack + f.base;
	uint pc = f.pc;
	while (true)
	{
		uint ins = code[pc++];
		uint a = ins_a(ins);
		// Kept current so a throw from any instruction knows where it happened.
		f.pc = pc;
		switch (ins_op(ins))
		{
			case NOP:
				break;
			case LOADK:
				r[a] = k[ins_bx(ins)];
			case LOADI:
				r[a] = integer(ins_sbx(ins));
			case LOADUNDEF:
				r[a] = UNDEFINED;
			case LOADNULL:
				r[a] = NULL;
			case LOADTRUE:
				r[a] = TRUE;
			case LOADFALSE:
				r[a] = FALSE;
			case LOADTDZ:
				r[a] = UNINITIALIZED;
			case MOVE:
				r[a] = r[ins_b(ins)];

			case GETSLOT:
				Value v = self.slots[ins_bx(ins)];
				if (v == UNINITIALIZED) return self.tdz_error(string_value(self.slot_names[ins_bx(ins)]))~;
				r[a] = v;
			case SETSLOT:
				uint slot = ins_bx(ins);
				if (self.slots[slot] == UNINITIALIZED) return self.tdz_error(string_value(self.slot_names[slot]))~;
				self.slots[slot] = r[a];
			case INITSLOT:
				self.slots[ins_bx(ins)] = r[a];
			case GETGLOBAL:
				IcEntry* ic = &f.proto.ics[pc - 1];
				JsObject* global = self.global;
				if (ic.shape == global.shape && ic.kind == OWN)
				{
					r[a] = global.slots[ic.slot];
					continue;
				}
				Value key = k[ins_bx(ins)];
				Shape* gs = global.find_own(key);
				if (gs && !gs.flags.accessor)
				{
					*ic = { .shape = global.shape, .slot = gs.slot(), .kind = OWN };
					r[a] = global.slots[gs.slot()];
					continue;
				}
				Value g = object_value(global);
				if (!self.has_property(g, key)!) return self.throw_error(REFERENCE_ERROR, "%s is not defined", key.as_string().tutf8())~;
				r[a] = self.get(g, key)!;
			case TYPEOFGLOBAL:
				Value key = k[ins_bx(ins)];
				Value g = object_value(self.global);
				r[a] = self.has_property(g, key)! ? self.type_of(self.get(g, key)!) : self.atoms.undefined_str;
			case SETGLOBAL:
				self.set(object_value(self.global), k[ins_bx(ins)], r[a])!;
			case GETCAP:
				Value v = f.function.captures[ins_b(ins)].value;
				if (v == UNINITIALIZED) return self.throw_error(REFERENCE_ERROR, "Cannot access a variable before initialization")~;
				r[a] = v;
			case SETCAP:
				Box* box = f.function.captures[ins_b(ins)];
				if (box.value == UNINITIALIZED) return self.throw_error(REFERENCE_ERROR, "Cannot access a variable before initialization")~;
				box.value = r[a];
				self.heap.touch(box);
			case INITCAP:
				Box* box = f.function.captures[ins_b(ins)];
				box.value = r[a];
				self.heap.touch(box);
			case NEWBOX:
				self.maybe_gc();
				Box* box = self.heap.alloc(BOX, Box::size) ?? self.oom()~!;
				box.value = UNINITIALIZED;
				r[a] = pointer_value(TAG_OBJECT, box);
			case GETBOX:
				Value v = ((Box*)r[ins_b(ins)].as_pointer()).value;
				if (v == UNINITIALIZED) return self.throw_error(REFERENCE_ERROR, "Cannot access a variable before initialization")~;
				r[a] = v;
			case SETBOX:
				Box* box = (Box*)r[ins_b(ins)].as_pointer();
				if (box.value == UNINITIALIZED) return self.throw_error(REFERENCE_ERROR, "Cannot access a variable before initialization")~;
				box.value = r[a];
				self.heap.touch(box);
			case INITBOX:
				Box* box = (Box*)r[ins_b(ins)].as_pointer();
				box.value = r[a];
				self.heap.touch(box);
			case CHECKTDZ:
				if (r[a] == UNINITIALIZED) return self.tdz_error(k[ins_bx(ins)])~;
			case THROWCONST:
				return self.throw_error(TYPE_ERROR, "Assignment to constant variable.")~;

			case ADD:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				if (b.is_int() && c.is_int())
				{
					r[a] = int_or_double((long)b.as_int() + c.as_int());
				}
				else if (b.is_number() && c.is_number())
				{
					r[a] = double_value(b.as_number() + c.as_number());
				}
				else
				{
					// String concatenation allocates; both operands are safe in registers.
					self.maybe_gc();
					r[a] = self.add(b, c)!;
				}
			case SUB:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				if (b.is_int() && c.is_int())
				{
					r[a] = int_or_double((long)b.as_int() - c.as_int());
				}
				else if (b.is_number() && c.is_number())
				{
					r[a] = double_value(b.as_number() - c.as_number());
				}
				else
				{
					r[a] = self.arith(SUB, b, c)!;
				}
			case MUL:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				if (b.is_int() && c.is_int())
				{
					long p = (long)b.as_int() * c.as_int();
					// 0 * -1 is -0, which only a double can hold.
					if (p == 0 && (b.as_int() < 0 || c.as_int() < 0))
					{
						r[a] = double_value(-0.0);
					}
					else
					{
						r[a] = int_or_double(p);
					}
				}
				else if (b.is_number() && c.is_number())
				{
					r[a] = double_value(b.as_number() * c.as_number());
				}
				else
				{
					r[a] = self.arith(MUL, b, c)!;
				}
			case DIV:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				if (b.is_number() && c.is_number())
				{
					r[a] = double_value(b.as_number() / c.as_number());
				}
				else
				{
					r[a] = self.arith(DIV, b, c)!;
				}
			case MOD:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				if (b.is_int() && c.is_int() && b.as_int() >= 0 && c.as_int() > 0)
				{
					r[a] = integer(b.as_int() % c.as_int());
				}
				else if (b.is_number() && c.is_number())
				{
					r[a] = number(js_mod(b.as_number(), c.as_number()));
				}
				else
				{
					r[a] = self.arith(MOD, b, c)!;
				}
			case POW:
			case BAND:
			case BOR:
			case BXOR:
			case SHL:
			case SAR:
			case SHR:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				Op op = ins_op(ins);
				if (b.is_int() && c.is_int() && op != POW)
				{
					int x = b.as_int();
					int y = c.as_int();
					switch (op)
					{
						case BAND: r[a] = integer(x & y);
						case BOR: r[a] = integer(x | y);
						case BXOR: r[a] = integer(x ^ y);
						case SHL: r[a] = integer(x << (y & 31));
						case SAR: r[a] = integer(x >> (y & 31));
						default: r[a] = number((double)((uint)x >> (y & 31)));
					}
				}
				else
				{
					r[a] = self.arith(op, b, c)!;
				}

			case LT:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				if (b.is_int() && c.is_int())
				{
					r[a] = boolean(b.as_int() < c.as_int());
				}
				else if (b.is_number() && c.is_number())
				{
					r[a] = boolean(b.as_number() < c.as_number());
				}
				else
				{
					r[a] = boolean(self.compare(LT, b, c)!);
				}
			case SEQ:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				r[a] = boolean(b == c ? (b.is_double() ? b.as_double() == b.as_double() : true) : strict_equals(b, c));
			case SNE:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				r[a] = boolean(!(b == c ? (b.is_double() ? b.as_double() == b.as_double() : true) : strict_equals(b, c)));
			case EQ:
			case NE:
			case LE:
			case GT:
			case GE:
			case INSTANCEOF:
			case IN:
				Value b = r[ins_b(ins)];
				Value c = r[ins_c(ins)];
				Op op = ins_op(ins);
				if (b.is_int() && c.is_int() && op != INSTANCEOF && op != IN)
				{
					int x = b.as_int();
					int y = c.as_int();
					switch (op)
					{
						case EQ: r[a] = boolean(x == y);
						case NE: r[a] = boolean(x != y);
						case LE: r[a] = boolean(x <= y);
						case GT: r[a] = boolean(x > y);
						default: r[a] = boolean(x >= y);
					}
				}
				else
				{
					r[a] = boolean(self.compare(op, b, c)!);
				}

			case NEG:
				Value b = r[ins_b(ins)];
				if (b.is_int() && b.as_int() != 0 && b.as_int() != int::min)
				{
					r[a] = integer(-b.as_int());
				}
				else
				{
					r[a] = double_value(-self.to_number(b)!);
				}
			case POS:
			case TONUMERIC:
				Value b = r[ins_b(ins)];
				r[a] = b.is_number() ? b : double_value(self.to_number(b)!);
			case NOT:
				r[a] = boolean(!truthy(r[ins_b(ins)]));
			case BNOT:
				r[a] = integer(~self.to_int32(r[ins_b(ins)])!);
			case TYPEOF:
				r[a] = self.type_of(r[ins_b(ins)]);
			case INC:
				Value b = r[ins_b(ins)];
				if (b.is_int() && b.as_int() != int::max)
				{
					r[a] = integer(b.as_int() + 1);
				}
				else
				{
					r[a] = double_value(self.to_number(b)! + 1);
				}
			case DEC:
				Value b = r[ins_b(ins)];
				if (b.is_int() && b.as_int() != int::min)
				{
					r[a] = integer(b.as_int() - 1);
				}
				else
				{
					r[a] = double_value(self.to_number(b)! - 1);
				}
			case TOSTRING:
				r[a] = string_value(self.to_string(r[ins_b(ins)])!);
			case CONCATN:
				// The pieces are in registers, safe from a collection.
				self.maybe_gc();
				r[a] = string_value(self.heap.concat_many(r + ins_b(ins), ins_c(ins)) ?? self.oom()~!);

			case ADDK:
			case SUBK:
			case MULK:
			case DIVK:
				Value b = r[ins_b(ins)];
				Value c = k[ins_c(ins)];
				Op op = ins_op(ins);
				if (b.is_number())
				{
					double x = b.as_number();
					double y = c.as_number();
					switch (op)
					{
						case ADDK: r[a] = b.is_int() && c.is_int() ? int_or_double((long)b.as_int() + c.as_int()) : double_value(x + y);
						case SUBK: r[a] = b.is_int() && c.is_int() ? int_or_double((long)b.as_int() - c.as_int()) : double_value(x - y);
						case MULK:
							if (b.is_int() && c.is_int() && b.as_int() != 0 && c.as_int() != 0)
							{
								r[a] = int_or_double((long)b.as_int() * c.as_int());
							}
							else
							{
								r[a] = double_value(x * y);
							}
						default: r[a] = double_value(x / y);
					}
					break;
				}
				Op slow;
				switch (op)
				{
					case ADDK: slow = ADD;
					case SUBK: slow = SUB;
					case MULK: slow = MUL;
					default: slow = DIV;
				}
				r[a] = self.arith(slow, b, c)!;
			case JNLT:
			case JNLE:
			case JNGT:
			case JNGE:
			case JNSEQ:
			case JNSNE:
				Value b = r[a];
				Value c = r[ins_b(ins)];
				Op op = ins_op(ins);
				bool cond;
				if (b.is_int() && c.is_int())
				{
					int x = b.as_int();
					int y = c.as_int();
					switch (op)
					{
						case JNLT: cond = x < y;
						case JNLE: cond = x <= y;
						case JNGT: cond = x > y;
						case JNGE: cond = x >= y;
						case JNSEQ: cond = x == y;
						default: cond = x != y;
					}
				}
				else if (b.is_number() && c.is_number())
				{
					double x = b.as_number();
					double y = c.as_number();
					switch (op)
					{
						case JNLT: cond = x < y;
						case JNLE: cond = x <= y;
						case JNGT: cond = x > y;
						case JNGE: cond = x >= y;
						case JNSEQ: cond = x == y;
						default: cond = x != y;
					}
				}
				else
				{
					switch (op)
					{
						case JNLT: cond = self.compare(LT, b, c)!;
						case JNLE: cond = self.compare(LE, b, c)!;
						case JNGT: cond = self.compare(GT, b, c)!;
						case JNGE: cond = self.compare(GE, b, c)!;
						case JNSEQ: cond = strict_equals(b, c);
						default: cond = !strict_equals(b, c);
					}
				}
				if (cond)
				{
					pc++;
				}
				else
				{
					pc = (uint)((int)pc + 1 + ins_sax(code[pc]));
				}

			case JMP:
				pc = (uint)((int)pc + ins_sax(ins));
				self.maybe_gc();
				if (self.interrupt && ins_sax(ins) < 0) self.check_interrupt()!;
			case JMPF:
				if (!truthy(r[a])) pc = (uint)((int)pc + ins_sbx(ins));
			case JMPT:
				if (truthy(r[a])) pc = (uint)((int)pc + ins_sbx(ins));
			case JMPNULLISH:
				if (r[a].is_nullish()) pc = (uint)((int)pc + ins_sbx(ins));
			case JMPNOTNULLISH:
				if (!r[a].is_nullish()) pc = (uint)((int)pc + ins_sbx(ins));
			case JMPNOTUNDEF:
				if (!r[a].is_undefined()) pc = (uint)((int)pc + ins_sbx(ins));

			case GETPROP:
				Value obj = r[ins_b(ins)];
				if (!obj.is_object())
				{
					r[a] = self.get(obj, k[ins_c(ins)])!;
					break;
				}
				JsObject* o = obj.as_object();
				IcEntry* ic = &f.proto.ics[pc - 1];
				if (ic.shape == o.shape)
				{
					switch (ic.kind)
					{
						case OWN:
							assert(ic.slot < o.slot_cap, "IC slot past capacity");
							r[a] = o.slots[ic.slot];
							continue;
						case PROTO:
							JsObject* p = o.shape.proto;
							if (p.shape == ic.holder_shape)
							{
								r[a] = p.slots[ic.slot];
								continue;
							}
						case OWN_GETTER:
							Accessor* acc = (Accessor*)o.slots[ic.slot].as_object();
							r[a] = acc.getter.is_undefined() ? UNDEFINED : self.call(acc.getter, obj, {})!;
							continue;
						case PROTO_GETTER:
							JsObject* p = o.shape.proto;
							if (p.shape == ic.holder_shape)
							{
								Accessor* acc = (Accessor*)p.slots[ic.slot].as_object();
								r[a] = acc.getter.is_undefined() ? UNDEFINED : self.call(acc.getter, obj, {})!;
								continue;
							}
						case ARRAY_LENGTH:
							if (o.kind == ARRAY)
							{
								r[a] = number((double)((JsArray*)o).length);
								continue;
							}
							if (o.kind == TYPED_ARRAY)
							{
								r[a] = integer((int)((JsTypedArray*)o).length);
								continue;
							}
						default:
							break;
					}
				}
				r[a] = self.get_ic(o, k[ins_c(ins)], ic)!;
			case SETPROP:
				Value obj = r[a];
				Value v = r[ins_c(ins)];
				if (!obj.is_object())
				{
					self.set(obj, k[ins_b(ins)], v)!;
					break;
				}
				JsObject* o = obj.as_object();
				IcEntry* ic = &f.proto.ics[pc - 1];
				if (ic.shape == o.shape)
				{
					if (ic.kind == OWN)
					{
						assert(ic.slot < o.slot_cap, "IC slot past capacity");
						o.slots[ic.slot] = v;
						self.heap.touch(o);
						continue;
					}
					JsObject* proto = o.shape.proto;
					// A doomed new_shape (dead at the last mark, its cache not yet cleared) must not
					// be brought back to life by installing it; the slow path makes a fresh one.
					if (ic.kind == ADD && !o.frozen_extensions && (!proto || proto.shape == ic.holder_shape) && !dead_shape(ic.new_shape))
					{
						o.ensure_slots(ic.new_shape.count);
						o.slots[ic.slot] = v;
						o.shape = ic.new_shape;
						self.heap.touch(o);
						continue;
					}
				}
				self.set_ic(o, k[ins_b(ins)], v, ic)!;
			case GETELEM:
				Value obj = r[ins_b(ins)];
				Value key = r[ins_c(ins)];
				if (obj.is_object() && key.is_int() && key.as_int() >= 0)
				{
					JsObject* o = obj.as_object();
					if (o.kind == ARRAY)
					{
						Value v = ((JsArray*)o).get((uint)key.as_int());
						if (v != EMPTY)
						{
							r[a] = v;
							break;
						}
					}
					else if (o.kind == TYPED_ARRAY)
					{
						JsTypedArray* t = (JsTypedArray*)o;
						uint i = (uint)key.as_int();
						r[a] = i < t.length ? t.get(i) : UNDEFINED;
						break;
					}
				}
				r[a] = self.get(obj, self.to_key(key)!)!;
			case SETELEM:
				Value obj = r[a];
				Value key = r[ins_b(ins)];
				if (obj.is_object() && key.is_int() && key.as_int() >= 0)
				{
					JsObject* o = obj.as_object();
					if (o.kind == ARRAY && !o.frozen_extensions)
					{
						((JsArray*)o).set((uint)key.as_int(), r[ins_c(ins)]);
						self.heap.touch(o);
						break;
					}
					if (o.kind == TYPED_ARRAY)
					{
						JsTypedArray* t = (JsTypedArray*)o;
						uint i = (uint)key.as_int();
						Value v = r[ins_c(ins)];
						if (i < t.length && !t.buffer.immutable)
						{
							if (v.is_int())
							{
								t.set_int(i, v.as_int());
							}
							else if (v.is_double())
							{
								t.set_number(i, v.as_double());
							}
							else
							{
								t.set_number(i, self.to_number(v)!);
							}
						}
						break;
					}
				}
				self.set(obj, self.to_key(key)!, r[ins_c(ins)])!;
			case DELPROP:
				r[a] = boolean(self.delete_property(r[ins_b(ins)], k[ins_c(ins)])!);
			case DELELEM:
				r[a] = boolean(self.delete_property(r[ins_b(ins)], self.to_key(r[ins_c(ins)])!)!);

			case NEWOBJ:
				self.maybe_gc();
				r[a] = object_value(self.heap.new_object(self.object_proto) ?? self.oom()~!);
			case NEWARR:
				self.maybe_gc();
				r[a] = object_value(self.heap.new_array(self.array_proto, ins_b(ins)) ?? self.oom()~!);
			case APPEND:
				JsArray* dest = (JsArray*)r[a].as_object();
				dest.push(r[ins_b(ins)]);
				self.heap.touch(dest);
			case APPENDHOLE:
				((JsArray*)r[a].as_object()).push(EMPTY);
			case APPENDSPREAD:
				JsArray* dest = (JsArray*)r[a].as_object();
				Value[2] state;
				self.get_iterator(r[ins_b(ins)], &state)!;
				Value item;
				// Per item: stepping a generator can run a GC slice between two pushes.
				while (self.iter_next(&state, &item)!)
				{
					dest.push(item);
					self.heap.touch(dest);
				}
			case INITPROP:
				JsObject* o = r[a].as_object();
				IcEntry* ic = &f.proto.ics[pc - 1];
				if (ic.shape == o.shape && ic.kind == ADD && !dead_shape(ic.new_shape))
				{
					o.ensure_slots(ic.new_shape.count);
					o.slots[ic.slot] = r[ins_c(ins)];
					o.shape = ic.new_shape;
					self.heap.touch(o);
					continue;
				}
				self.define_ic(o, k[ins_b(ins)], r[ins_c(ins)], ic)!;
			case INITELEM:
				self.define(r[a].as_object(), self.to_key(r[ins_b(ins)])!, r[ins_c(ins)])!;
			case INITGETTER:
				self.define_accessor(r[a].as_object(), self.to_key(r[ins_b(ins)])!, r[ins_c(ins)], UNDEFINED, DATA_PROP)!;
			case INITSETTER:
				self.define_accessor(r[a].as_object(), self.to_key(r[ins_b(ins)])!, UNDEFINED, r[ins_c(ins)], DATA_PROP)!;
			case COPYPROPS:
				Value src = r[ins_b(ins)];
				if (!src.is_object()) break;
				List {Value} keys;
				keys.init(mem);
				defer keys.free();
				self.own_keys(src.as_object(), &keys, true)!;
				foreach (key : keys) self.define(r[a].as_object(), key, self.get(src, key)!)!;
			case NEWREGEXP:
				self.maybe_gc();
				r[a] = self.new_regexp(r[ins_b(ins)].as_string(), r[ins_c(ins)].as_string())!;
			case OBJREST:
				Value src = r[ins_b(ins)];
				if (src.is_nullish()) return self.throw_error(TYPE_ERROR, "Cannot destructure '%s' as it is %s.", self.describe(src), self.describe(src))~;
				JsObject* rest = self.heap.new_object(self.object_proto) ?? self.oom()~!;
				r[a] = object_value(rest);
				if (!src.is_object()) break;
				JsArray* skip = (JsArray*)r[ins_c(ins)].as_object();
				List {Value} keys;
				keys.init(mem);
				defer keys.free();
				self.own_keys(src.as_object(), &keys, true)!;
				foreach (key : keys)
				{
					bool excluded = false;
					for (uint i = 0; i < skip.length; i++)
					{
						if (self.to_key(skip.elements[i])! == key) excluded = true;
					}
					if (!excluded) self.define(rest, key, self.get(src, key)!)!;
				}
			case CLOSURE:
				self.maybe_gc();
				r[a] = self.make_closure(f, f.proto.protos[ins_bx(ins)])!;

			case CALL:
			case NEW:
			case CALLSPREAD:
			case NEWSPREAD:
				self.maybe_gc();
				if (self.interrupt) self.check_interrupt()!;
				Op op = ins_op(ins);
				bool spread = op == CALLSPREAD || op == NEWSPREAD;
				bool construct = op == NEW || op == NEWSPREAD;
				uint argc = ins_b(ins);
				if (spread) argc = self.unpack_spread(r, f.base, a)!;
				Value callee = r[a];
				if (!callee.is_function())
				{
					return self.throw_error(TYPE_ERROR, construct ? "%s is not a constructor" : "%s is not a function", self.callee_text(f, pc, callee))~;
				}
				JsFunction* fun = (JsFunction*)callee.as_object();
				// Arguments past the frame's registers must not be clobbered by a native's nested calls.
				uint top = f.base + a + 2 + argc;
				if (top > self.stack_top) self.stack_top = top;
				if (fun.native)
				{
					Value this_value = construct ? EMPTY : r[a + 1];
					// Resuming a generator holds nothing a collection could free, so it doesn't block one.
					uint depth = fun.native == &native_generator_resume ? 0 : 1;
					self.native_depth += depth;
					Value? result = fun.native(self, this_value, r[a + 2:argc], fun);
					self.native_depth -= depth;
					self.after_native(this_value, r[a + 2:argc], fun);
					r[a] = result!;
					self.stack_top = f.base + f.proto.nregs;
					break;
				}
				if (construct)
				{
					if (!fun.proto.is_constructor()) return self.throw_error(TYPE_ERROR, "%s is not a constructor", self.callee_text(f, pc, callee))~;
					r[a + 1] = fun.proto.is_derived ? UNINITIALIZED : object_value(self.new_instance(callee)!);
				}
				else if (fun.proto.is_class_constructor)
				{
					return self.throw_error(TYPE_ERROR, "Class constructor %s cannot be invoked without 'new'", fun.proto.name)~;
				}
				f = self.push_frame(fun, f.base + a + 1, argc, construct, construct ? callee : UNDEFINED)!;
				code = f.proto.code.ptr;
				k = f.proto.consts.ptr;
				r = self.stack + f.base;
				pc = 0;
			case RET:
			case RETUNDEF:
				// GENSTART and AWAIT finish here too, with the value to return in r[a].
				Value v = ins_op(ins) == RETUNDEF ? UNDEFINED : r[a];
				if (f.coroutine) v = self.coroutine_returned(f.coroutine, v);
				if (f.construct && !v.is_object())
				{
					v = r[0];
					if (v == UNINITIALIZED) return self.no_super_error()~;
				}
				bool stop = f.stop;
				uint base = f.base;
				bool inline_iter = f.inline_iter;
				uint exit = f.iter_exit;
				self.frame_count--;
				self.stack[base - 1] = v;
				if (stop) return v;
				f = &self.frames[self.frame_count - 1];
				code = f.proto.code.ptr;
				k = f.proto.consts.ptr;
				r = self.stack + f.base;
				// A generator a for-of was running is done: the loop is too.
				pc = inline_iter ? exit : f.pc;
				self.stack_top = f.base + f.proto.nregs;
			case THROW:
				return self.throw_value(r[a])~;
			case NEWTARGET:
				r[a] = f.new_target;
			case CURRENTFN:
				r[a] = object_value(f.function);

			case DEFCLASS:
				r[a + 1] = self.define_class(r[a], r[ins_b(ins)], ins_c(ins) != 0)!;
			case DEFMETHOD:
			case DEFGETTER:
			case DEFSETTER:
				JsObject* target = r[a].as_object();
				Value key = self.to_key(r[ins_b(ins)])!;
				Value fun = r[ins_c(ins)];
				((JsFunction*)fun.as_object()).home_object = target;
				self.heap.touch_value(fun);
				switch (ins_op(ins))
				{
					case DEFMETHOD: self.define(target, key, fun, METHOD_PROP)!;
					case DEFGETTER: self.define_accessor(target, key, fun, UNDEFINED, METHOD_PROP)!;
					default: self.define_accessor(target, key, UNDEFINED, fun, METHOD_PROP)!;
				}
			case SETHOME:
				((JsFunction*)r[a].as_object()).home_object = r[ins_b(ins)].as_object();
				self.heap.touch_value(r[a]);
			case SETFIELDS:
				((JsFunction*)r[a].as_object()).fields_init = r[ins_b(ins)];
				self.heap.touch_value(r[a]);
			case GETFIELDS:
				r[a] = f.function.fields_init;
			case SUPERCALL:
			case SUPERCALLSPREAD:
				uint argc = ins_b(ins);
				if (ins_op(ins) == SUPERCALLSPREAD) argc = self.unpack_spread(r, f.base, a)!;
				JsObject* parent_obj = ((JsObject*)f.function).proto();
				Value parent = parent_obj ? object_value(parent_obj) : NULL;
				if (!parent.is_function() || (!((JsFunction*)parent_obj).native && !((JsFunction*)parent_obj).proto.is_constructor()))
				{
					return self.throw_error(TYPE_ERROR, "Super constructor %s of anonymous class is not a constructor", self.describe(parent))~;
				}
				JsFunction* pf = (JsFunction*)parent_obj;
				uint top = f.base + a + 2 + argc;
				if (top > self.stack_top) self.stack_top = top;
				if (pf.native)
				{
					self.native_depth++;
					Value? native_result = pf.native(self, EMPTY, r[a + 2:argc], pf);
					self.native_depth--;
					self.after_native(EMPTY, r[a + 2:argc], pf);
					Value result = native_result!;
					self.stack_top = f.base + f.proto.nregs;
					// A built-in parent made the object; give it the subclass's prototype.
					if (result.is_object())
					{
						Value proto = self.get(f.new_target, self.atoms.prototype)!;
						if (proto.is_object()) result.as_object().set_proto(&self.heap, proto.as_object()) ?? self.oom()~!;
					}
					r[a] = result;
					break;
				}
				r[a + 1] = pf.proto.is_derived ? UNINITIALIZED : object_value(self.new_instance(f.new_target)!);
				Value new_target = f.new_target;
				f = self.push_frame(pf, f.base + a + 1, argc, true, new_target)!;
				code = f.proto.code.ptr;
				k = f.proto.consts.ptr;
				r = self.stack + f.base;
				pc = 0;
			case SETTHIS:
				if (r[0] != UNINITIALIZED) return self.throw_error(REFERENCE_ERROR, "Super constructor may only be called once")~;
				r[0] = r[a];
			case CHECKTHIS:
				if (r[a] == UNINITIALIZED) return self.no_super_error()~;
			case GETSUPER:
				JsObject* home = f.function.home_object;
				if (!home) return self.throw_error(SYNTAX_ERROR, "'super' keyword unexpected here")~;
				if (r[0] == UNINITIALIZED) return self.no_super_error()~;
				r[a] = self.get_from(home.proto(), k[ins_bx(ins)], r[0])!;
			case GETASYNCITER:
				self.async_iterator_of(r[ins_b(ins)], r + a)!;
			case ITERRESULT:
				self.unpack_iter_result(r + a)!;
			case ASYNCCLOSE:
				uint b = ins_b(ins);
				switch (ins_c(ins))
				{
					case 0:
						if (!self.async_iter_close(r + a, r + b)!) pc += 2;
					case 1:
						// The body's exception wins over anything return() throws.
						Value pending = self.exception;
						bool? called = self.async_iter_close(r + a, r + b);
						if (catch err = called)
						{
							if (self.uncatchable) return err~;
							self.exception = pending;
							pc++;
							break;
						}
						if (!called) pc++;
					default:
						if (!r[b].is_object()) return self.throw_error(TYPE_ERROR, "Iterator result %s is not an object", self.describe(r[b]))~;
				}
			case INITPROTO:
				Value proto = r[ins_b(ins)];
				if (proto.is_object())
				{
					r[a].as_object().set_proto(&self.heap, proto.as_object()) ?? self.oom()~!;
				}
				else if (proto.is_null())
				{
					r[a].as_object().set_proto(&self.heap, null) ?? self.oom()~!;
				}
			case GETSUPERELEM:
				JsObject* home = self.super_home(f, r)!;
				r[a] = self.get_from(home.proto(), self.to_key(r[ins_b(ins)])!, r[0])!;
			case SETSUPERELEM:
				JsObject* home = self.super_home(f, r)!;
				self.set_super(home.proto(), self.to_key(r[a])!, r[ins_b(ins)], r[0])!;

			case GETITER:
				self.get_iterator(r[ins_b(ins)], r + a)!;
				if (ins_c(ins) && r[a + 1].is_int()) self.wrap_fast_iterator(r + a)!;
			case FORNEXT:
				if (r[a + 1].is_int())
				{
					JsArray* arr = (JsArray*)r[a].as_object();
					uint i = (uint)r[a + 1].as_int();
					if (i >= arr.length)
					{
						pc = (uint)((int)pc + ins_sbx(ins));
						break;
					}
					Value v = arr.elements[i];
					r[a + 2] = v == EMPTY ? UNDEFINED : v;
					r[a + 1] = integer((int)i + 1);
					break;
				}
				// A plain generator runs right here rather than in a nested execute(): its frame
				// goes on top of this one, and its next yield comes back to the loop body.
				if (JsCoroutine* c = self.inline_generator(r + a))
				{
					if (c.state == DONE)
					{
						pc = (uint)((int)pc + ins_sbx(ins));
						break;
					}
					f = self.enter_generator(c, f.base + a + 2, (uint)((int)pc + ins_sbx(ins)))!;
					code = f.proto.code.ptr;
					k = f.proto.consts.ptr;
					r = self.stack + f.base;
					pc = f.pc;
					break;
				}
				Value item;
				if (!self.iter_next(r + a, &item)!)
				{
					pc = (uint)((int)pc + ins_sbx(ins));
					break;
				}
				r[a + 2] = item;
			case ITERCLOSE:
				// c set: closing because the loop body threw. That exception wins over anything
				// return() throws, so this one is dropped.
				if (ins_c(ins))
				{
					Value pending = self.exception;
					if (catch self.iter_close(r + a)) self.exception = pending;
					break;
				}
				self.iter_close(r + a)!;
			case ITERSTEP:
				// An exhausted iteration has r[a] cleared, so ITERCLOSE knows not to close it.
				Value item;
				if (r[a].is_undefined() || !self.iter_next(r + a, &item)!)
				{
					item = UNDEFINED;
					r[a] = UNDEFINED;
				}
				r[a + 2] = item;
			case ITERREST:
				JsArray* rest = self.heap.new_array(self.array_proto) ?? self.oom()~!;
				r[ins_b(ins)] = object_value(rest);
				Value item;
				if (!r[a].is_undefined())
				{
					while (self.iter_next(r + a, &item)!)
					{
						rest.push(item);
						self.heap.touch(rest);
					}
				}
				r[a] = UNDEFINED;
			case FORINKEYS:
				r[a] = self.for_in_keys(r[ins_b(ins)])!;
				r[a + 1] = integer(0);

			case GENSTART:
				JsCoroutine* c = self.new_coroutine(f, false)!;
				self.save_frame(c, f, pc);
				c.state = SUSPENDED_START;
				r[a] = object_value(c);
				nextcase RET;
			case ASYNCSTART:
				JsCoroutine* c = self.new_coroutine(f, true)!;
				c.promise = object_value(self.new_promise()!);
				c.state = RUNNING;
				f.coroutine = c;
			case YIELD:
				// A generator runs from resume() as a stop frame, or inline from a for-of.
				JsCoroutine* c = f.coroutine;
				self.save_frame(c, f, pc);
				c.state = SUSPENDED;
				Value v = r[a];
				self.frame_count--;
				if (f.stop) return v;
				assert(f.inline_iter, "generator frame neither stop nor inline");
				uint dest = f.iter_dest;
				f = &self.frames[self.frame_count - 1];
				code = f.proto.code.ptr;
				k = f.proto.consts.ptr;
				r = self.stack + f.base;
				pc = f.pc;
				self.stack_top = f.base + f.proto.nregs;
				self.stack[dest] = v;
			case AWAIT:
				JsCoroutine* c = f.coroutine;
				self.await_value(c, r[a])!;
				self.save_frame(c, f, pc);
				c.state = SUSPENDED;
				// Leave like a return, handing the caller (or the job queue) the promise.
				f.coroutine = null;
				r[a] = c.promise;
				nextcase RET;
			case YSTEP:
				if (self.yield_star_step(r + a)!) pc = (uint)((int)pc + ins_sbx(ins));
			case YSEND:
				if (!self.yield_star_send(r + a, true)!) pc = (uint)((int)pc + ins_sbx(ins));
			case YRESULT:
				if (self.yield_star_result(r + a)!) pc = (uint)((int)pc + ins_sbx(ins));
		}
	}
}
