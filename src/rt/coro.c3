module fastjs::rt;
import std::collections::list;

// Generators, async functions, promises and the job queue.
//
// A generator or async call is a coroutine. While it runs, its registers live on the VM stack like
// any frame's. When it suspends (yield, await, or the initial stop of a generator) its register
// window is copied into the coroutine object, and copied back onto the stack when it resumes, as a
// `stop` frame run from native code. Windows are small, so the copy is cheaper than giving every
// coroutine a stack of its own.

enum CoroState : char
{
	// A generator created but not yet started: next() runs it from the top.
	SUSPENDED_START,
	SUSPENDED,
	RUNNING,
	DONE,
}

enum ResumeMode : char
{
	NEXT,
	THROW,
	RETURN,
}

struct JsCoroutine
{
	inline JsObject object;
	JsFunction* function;
	// The saved register window while suspended; null once done.
	Value* regs;
	uint nregs;
	uint pc;
	CoroState state;
	bool is_async;
	// Async functions: the promise the call returned.
	Value promise;
}

<*
 A new coroutine for the function running in f.

 @return? THROWN
*>
fn JsCoroutine*? Vm.new_coroutine(&self, Frame* f, bool is_async)
{
	JsObject* proto = is_async ? self.object_proto : self.generator_proto;
	JsCoroutine* c = (JsCoroutine*)self.heap.new_object(proto, COROUTINE, JsCoroutine::size) ?? self.oom()~!;
	c.function = f.function;
	c.nregs = f.proto.nregs;
	c.regs = mem::new_array(Value, c.nregs).ptr;
	account((sz)c.nregs * Value::size);
	c.promise = UNDEFINED;
	c.is_async = is_async;
	return c;
}

<*
 Copy a frame's registers into its coroutine, to continue at pc later.
*>
fn void Vm.save_frame(&self, JsCoroutine* c, Frame* f, uint pc) @inline
{
	mem::copy(c.regs, self.stack + f.base, (usz)c.nregs * Value::size);
	c.pc = pc;
}

fn void JsCoroutine.finish(&self)
{
	self.state = DONE;
	if (self.regs) account(-(sz)self.nregs * Value::size);
	free(self.regs);
	self.regs = null;
	self.nregs = 0;
}

<*
 A coroutine's function returned v. An async function resolves its promise with v, and the
 promise becomes the value its caller sees.
*>
fn Value Vm.coroutine_returned(&self, JsCoroutine* c, Value v)
{
	c.finish();
	if (!c.is_async) return v;
	self.resolve_promise((JsPromise*)c.promise.as_object(), v);
	return c.promise;
}

<*
 Run a suspended coroutine until it suspends again or finishes. Returns what it yielded or
 returned; c.state tells which.

 @require c.state == SUSPENDED || c.state == SUSPENDED_START : "Coroutine is not suspended"
 @return? THROWN
*>
fn Value? Vm.resume(&self, JsCoroutine* c, Value v, ResumeMode mode)
{
	FunctionProto* p = c.function.proto;
	bool throwing = false;
	if (c.state == SUSPENDED)
	{
		// Hand the value to the instruction that suspended.
		uint ins = p.code[c.pc - 1];
		c.regs[ins_a(ins)] = v;
		bool delegating = ins_op(ins) == YIELD && ins_c(ins) != 0;
		if (ins_op(ins) == YIELD) c.regs[ins_b(ins)] = integer((int)mode.ordinal);
		throwing = mode == THROW && !delegating;
	}
	uint saved_top = self.stack_top;
	defer self.stack_top = saved_top;
	uint base = self.stack_top + 1;
	if (self.frame_count == MAX_FRAMES || base + p.nregs + 2 >= STACK_SIZE)
	{
		return self.throw_error(RANGE_ERROR, "Maximum call stack size exceeded")~;
	}
	self.stack[base - 1] = UNDEFINED;
	mem::copy(self.stack + base, c.regs, (usz)c.nregs * Value::size);
	Frame* f = &self.frames[self.frame_count++];
	*f = { .proto = p, .function = c.function, .pc = c.pc, .base = base, .new_target = UNDEFINED, .stop = true, .coroutine = c };
	self.stack_top = base + p.nregs;
	c.state = RUNNING;
	if (throwing) self.exception = v;
	return self.execute(throwing);
}

<*
 One step of a generator: next(v), throw(v) or return(v). Returns whether it is done; out gets
 the yielded or returned value.

 @return? THROWN
*>
fn bool? Vm.generator_step(&self, JsCoroutine* c, Value v, ResumeMode mode, Value* out)
{
	if (c.state == RUNNING) return self.throw_error(TYPE_ERROR, "Generator is already running")~;
	// A generator that never started has no try blocks to run: throw and return finish it at once.
	if (c.state == SUSPENDED_START && mode != NEXT) c.finish();
	if (c.state == DONE)
	{
		switch (mode)
		{
			case NEXT:
				*out = UNDEFINED;
			case RETURN:
				*out = v;
			case THROW:
				return self.throw_value(v)~;
		}
		return true;
	}
	*out = self.resume(c, v, mode)!;
	return c.state == DONE;
}

fn JsCoroutine*? Vm.this_generator(&self, Value v, String method)
{
	if (v.is_object() && v.as_object().kind == COROUTINE && !((JsCoroutine*)v.as_object()).is_async) return (JsCoroutine*)v.as_object();
	return self.throw_error(TYPE_ERROR, "%s method called on incompatible receiver %s", method, self.describe(v))~;
}

// next, throw and return share one native; magic is the ResumeMode.
fn Value? native_generator_resume(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	ResumeMode mode = ResumeMode::from_ordinal(callee.magic);
	JsCoroutine* c = vm.this_generator(this_value, callee.native_name)!;
	Value out;
	bool done = vm.generator_step(c, arg(args, 0), mode, &out)!;
	return vm.iter_result(out, done);
}

// ---- promises ----

enum PromiseState : char
{
	PENDING,
	FULFILLED,
	REJECTED,
}

<*
 What to do when a promise settles: call a handler and settle `target` (a promise, or nothing)
 with its result, or resume `target` when it is an async function waiting in `await`.
*>
struct Reaction
{
	Value target;
	Value on_fulfilled;
	Value on_rejected;
}

struct JsPromise
{
	inline JsObject object;
	Value result;
	List {Reaction} reactions;
	PromiseState state;
	// Something has subscribed to the outcome, so a rejection is not "unhandled".
	bool handled;
}

enum JobKind : char
{
	// Run a reaction with a settled value.
	REACTION,
	// Resolve promise `target` from a thenable `argument` by calling its `then`, `handler`.
	THENABLE,
	// queueMicrotask(handler).
	CALLBACK,
}

struct Job
{
	JobKind kind;
	bool rejected;
	Value handler;
	Value target;
	Value argument;
}

fn bool Value.is_promise(self) => self.is_object() && self.as_object().kind == PROMISE;

<*
 @return? THROWN
*>
fn JsPromise*? Vm.new_promise(&self)
{
	JsPromise* p = (JsPromise*)self.heap.new_object(self.promise_proto, PROMISE, JsPromise::size) ?? self.oom()~!;
	p.result = UNDEFINED;
	p.reactions.init(mem);
	return p;
}

fn void Vm.enqueue(&self, Job job)
{
	self.jobs.push(job);
}

fn void Vm.enqueue_reaction(&self, Reaction r, Value v, bool rejected)
{
	self.enqueue({ .kind = REACTION, .rejected = rejected, .handler = rejected ? r.on_rejected : r.on_fulfilled, .target = r.target, .argument = v });
}

fn void Vm.settle(&self, JsPromise* p, Value v, bool rejected)
{
	if (p.state != PENDING) return;
	p.state = rejected ? REJECTED : FULFILLED;
	p.result = v;
	foreach (r : p.reactions) self.enqueue_reaction(r, v, rejected);
	p.reactions.free();
	if (rejected && !p.handled) self.unhandled.push(object_value(p));
}

fn void Vm.reject_promise(&self, JsPromise* p, Value reason) => self.settle(p, reason, true);

<*
 Resolve p with a value that may itself be a promise or thenable, which p then follows.
 Never throws: a failure while looking at the value rejects p instead.
*>
fn void Vm.resolve_promise(&self, JsPromise* p, Value v)
{
	if (p.state != PENDING) return;
	if (v == object_value(p))
	{
		(void)self.throw_error(TYPE_ERROR, "Chaining cycle detected for promise #<Promise>");
		self.reject_with_exception(p);
		return;
	}
	if (!v.is_object())
	{
		self.settle(p, v, false);
		return;
	}
	Value? then = self.get(v, self.atoms.then);
	if (catch then)
	{
		self.reject_with_exception(p);
		return;
	}
	if (!then.is_function())
	{
		self.settle(p, v, false);
		return;
	}
	self.enqueue({ .kind = THENABLE, .handler = then, .target = object_value(p), .argument = v });
}

fn void Vm.reject_with_exception(&self, JsPromise* p)
{
	Value e = self.exception;
	self.exception = UNDEFINED;
	self.reject_promise(p, e);
}

<*
 Subscribe to p: target is settled (or resumed) with the handlers' outcome.
*>
fn void Vm.perform_then(&self, JsPromise* p, Value on_fulfilled, Value on_rejected, Value target)
{
	Reaction r = { target, on_fulfilled.is_function() ? on_fulfilled : UNDEFINED, on_rejected.is_function() ? on_rejected : UNDEFINED };
	switch (p.state)
	{
		case PENDING:
			p.reactions.push(r);
		case FULFILLED:
			self.enqueue_reaction(r, p.result, false);
		case REJECTED:
			if (!p.handled) self.forget_unhandled(p);
			self.enqueue_reaction(r, p.result, true);
	}
	p.handled = true;
}

fn void Vm.forget_unhandled(&self, JsPromise* p)
{
	foreach (i, v : self.unhandled)
	{
		if (v == object_value(p))
		{
			self.unhandled.remove_at(i);
			return;
		}
	}
}

<*
 Promise.resolve(v) for the built-in Promise: v itself if it already is one.

 @return? THROWN
*>
fn JsPromise*? Vm.promise_resolve(&self, Value v)
{
	if (v.is_promise() && v.as_object().proto() == self.promise_proto) return (JsPromise*)v.as_object();
	JsPromise* p = self.new_promise()!;
	self.resolve_promise(p, v);
	return p;
}

<*
 `await v` in coroutine c: resume c when v settles. Plain values skip the promise allocation;
 the job runs on the same tick either way.

 @return? THROWN
*>
fn void? Vm.await_value(&self, JsCoroutine* c, Value v)
{
	if (!v.is_object())
	{
		self.enqueue({ .kind = REACTION, .target = object_value(c), .argument = v, .handler = UNDEFINED });
		return;
	}
	JsPromise* p = self.promise_resolve(v)!;
	self.perform_then(p, UNDEFINED, UNDEFINED, object_value(c));
}

<*
 The resolve and reject functions handed to an executor or a thenable's `then`. Each points at the
 other, so the first call can disarm both.

 @return? THROWN
*>
fn void? Vm.resolving_functions(&self, JsPromise* p, Value* resolve, Value* reject)
{
	JsFunction* res = self.new_native("", &native_resolving_function, 1) ?? self.oom()~!;
	JsFunction* rej = self.new_native("", &native_resolving_function, 1) ?? self.oom()~!;
	rej.magic = 1;
	res.native_data = object_value(p);
	rej.native_data = object_value(p);
	res.native_data2 = object_value(rej);
	rej.native_data2 = object_value(res);
	*resolve = object_value(res);
	*reject = object_value(rej);
}

fn Value? native_resolving_function(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value target = callee.native_data;
	if (!target.is_object()) return UNDEFINED;
	callee.native_data = UNDEFINED;
	((JsFunction*)callee.native_data2.as_object()).native_data = UNDEFINED;
	JsPromise* p = (JsPromise*)target.as_object();
	if (callee.magic == 0)
	{
		vm.resolve_promise(p, arg(args, 0));
	}
	else
	{
		vm.reject_promise(p, arg(args, 0));
	}
	return UNDEFINED;
}

// ---- running jobs ----

<*
 Run the oldest pending job. Returns false when there was none. A queueMicrotask callback that
 throws returns THROWN with the exception pending; promise handlers that throw reject their
 promise instead.

 @return? THROWN
*>
fn bool? Vm.run_job(&self)
{
	if (self.job_head >= self.jobs.len()) return false;
	Job job = self.jobs[self.job_head++];
	if (self.job_head == self.jobs.len())
	{
		self.jobs.clear();
		self.job_head = 0;
	}
	else if (self.job_head >= 1024 && self.job_head * 2 >= self.jobs.len())
	{
		// Drop the finished prefix, so a long chain of awaits doesn't grow the queue forever.
		sz live = self.jobs.len() - self.job_head;
		mem::move(self.jobs.entries, self.jobs.entries + self.job_head, live * Job::size);
		self.jobs.size = live;
		self.job_head = 0;
	}
	// Keep the job's values reachable while it runs; a collection can happen inside it.
	Job saved = self.current_job;
	self.current_job = job;
	defer self.current_job = saved;
	switch (job.kind)
	{
		case REACTION:
			if (job.target.is_object() && job.target.as_object().kind == COROUTINE)
			{
				(void)self.resume((JsCoroutine*)job.target.as_object(), job.argument, job.rejected ? THROW : NEXT)!;
				return true;
			}
			Value result = job.argument;
			bool threw = job.rejected;
			if (job.handler.is_function())
			{
				Value[1] call_args = { job.argument };
				Value? r = self.call(job.handler, UNDEFINED, &call_args);
				threw = false;
				if (catch r)
				{
					threw = true;
					result = self.exception;
					self.exception = UNDEFINED;
				}
				else
				{
					result = r;
				}
			}
			if (job.target.is_promise())
			{
				JsPromise* p = (JsPromise*)job.target.as_object();
				if (threw)
				{
					self.reject_promise(p, result);
				}
				else
				{
					self.resolve_promise(p, result);
				}
			}
		case THENABLE:
			JsPromise* p = (JsPromise*)job.target.as_object();
			Value[2] fns;
			self.resolving_functions(p, &fns[0], &fns[1])!;
			if (catch self.call(job.handler, job.argument, &fns))
			{
				Value[1] reason = { self.exception };
				self.exception = UNDEFINED;
				(void)self.call(fns[1], UNDEFINED, &reason)!;
			}
		case CALLBACK:
			(void)self.call(job.handler, UNDEFINED, {})!;
	}
	return true;
}

fn bool Vm.jobs_waiting(&self) => self.job_head < self.jobs.len();

<*
 Take the next promise that was rejected with nobody listening, for the host to report.
*>
fn bool Vm.take_unhandled(&self, Value* reason)
{
	if (!self.unhandled.len()) return false;
	Value p = self.unhandled.pop_first()!!;
	*reason = ((JsPromise*)p.as_object()).result;
	return true;
}

// ---- Promise built-ins ----

fn JsPromise*? Vm.this_promise(&self, Value v, String method)
{
	if (v.is_promise()) return (JsPromise*)v.as_object();
	return self.throw_error(TYPE_ERROR, "Method Promise.prototype.%s called on incompatible receiver %s", method, self.describe(v))~;
}

fn Value? native_promise(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (this_value != EMPTY) return vm.throw_error(TYPE_ERROR, "Promise constructor cannot be invoked without 'new'")~;
	Value executor = arg(args, 0);
	if (!executor.is_function()) return vm.throw_error(TYPE_ERROR, "Promise resolver %s is not a function", vm.describe(executor))~;
	JsPromise* p = vm.new_promise()!;
	Value[2] fns;
	vm.resolving_functions(p, &fns[0], &fns[1])!;
	if (catch vm.call(executor, UNDEFINED, &fns))
	{
		Value[1] reason = { vm.exception };
		vm.exception = UNDEFINED;
		(void)vm.call(fns[1], UNDEFINED, &reason)!;
	}
	return object_value(p);
}

fn Value? native_promise_then(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsPromise* p = vm.this_promise(this_value, "then")!;
	JsPromise* derived = vm.new_promise()!;
	vm.perform_then(p, arg(args, 0), arg(args, 1), object_value(derived));
	return object_value(derived);
}

fn Value? native_promise_catch(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value then = vm.get(this_value, vm.atoms.then)!;
	Value[2] then_args = { UNDEFINED, arg(args, 0) };
	return vm.call(then, this_value, &then_args);
}

// finally(f): run f, wait for what it returns, then pass the original outcome through.
fn Value? native_promise_finally(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value then = vm.get(this_value, vm.atoms.then)!;
	Value on_finally = arg(args, 0);
	Value[2] then_args = { on_finally, on_finally };
	if (on_finally.is_function())
	{
		JsFunction* on_value = vm.new_native("", &native_finally_step, 1)!;
		JsFunction* on_reason = vm.new_native("", &native_finally_step, 1)!;
		on_value.native_data = on_finally;
		on_reason.native_data = on_finally;
		on_reason.magic = 1;
		then_args = { object_value(on_value), object_value(on_reason) };
	}
	return vm.call(then, this_value, &then_args);
}

fn Value? native_finally_step(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value result = vm.call(callee.native_data, UNDEFINED, {})!;
	JsPromise* p = vm.promise_resolve(result)!;
	// The outcome to restore: a function returning the value, or one rethrowing the reason.
	JsFunction* restore = vm.new_native("", &native_finally_restore, 0)!;
	restore.native_data = arg(args, 0);
	restore.magic = callee.magic;
	JsPromise* derived = vm.new_promise()!;
	vm.perform_then(p, object_value(restore), UNDEFINED, object_value(derived));
	return object_value(derived);
}

fn Value? native_finally_restore(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (callee.magic) return vm.throw_value(callee.native_data)~;
	return callee.native_data;
}

fn Value? native_promise_resolve(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return object_value(vm.promise_resolve(arg(args, 0))!);
}

fn Value? native_promise_reject(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsPromise* p = vm.new_promise()!;
	vm.reject_promise(p, arg(args, 0));
	return object_value(p);
}

fn Value? native_promise_with_resolvers(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsPromise* p = vm.new_promise()!;
	Value resolve;
	Value reject;
	vm.resolving_functions(p, &resolve, &reject)!;
	JsObject* o = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
	vm.define(o, vm.atom_value("promise")!, object_value(p))!;
	vm.define(o, vm.atom_value("resolve")!, resolve)!;
	vm.define(o, vm.atom_value("reject")!, reject)!;
	return object_value(o);
}

enum Combinator : char
{
	ALL,
	ALL_SETTLED,
	ANY,
	RACE,
}

// Shared state of one Promise.all/allSettled/any call, kept in an array: [values, remaining, promise].
const uint COMBINE_VALUES = 0;
const uint COMBINE_REMAINING = 1;
const uint COMBINE_PROMISE = 2;

fn Value? native_promise_combine(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return object_value(vm.combine(Combinator::from_ordinal(callee.magic), arg(args, 0))!);
}

<*
 Promise.all, allSettled, any or race over an iterable.

 @return? THROWN
*>
fn JsPromise*? Vm.combine(&self, Combinator kind, Value iterable)
{
	Vm* vm = self;
	JsPromise* result = vm.new_promise()!;
	JsArray*? items = vm.iterable_to_array(iterable);
	if (catch items)
	{
		vm.reject_with_exception(result);
		return result;
	}
	Value resolve;
	Value reject;
	vm.resolving_functions(result, &resolve, &reject)!;
	JsArray* values = vm.heap.new_array(vm.array_proto, items.length) ?? vm.oom()~!;
	for (uint i = 0; i < items.length; i++) values.push(UNDEFINED);
	JsArray* shared = vm.heap.new_array(vm.array_proto, 3) ?? vm.oom()~!;
	shared.push(object_value(values));
	shared.push(integer((int)items.length));
	shared.push(object_value(result));
	for (uint i = 0; i < items.length; i++)
	{
		JsPromise* next = vm.promise_resolve(items.elements[i])!;
		if (kind == RACE)
		{
			vm.perform_then(next, resolve, reject, UNDEFINED);
			continue;
		}
		JsFunction* on_value = vm.new_native("", &native_combine_element, 1)!;
		on_value.magic = (int)i;
		on_value.native_data = object_value(shared);
		on_value.native_data2 = integer((int)kind.ordinal);
		switch (kind)
		{
			case ALL:
				vm.perform_then(next, object_value(on_value), reject, UNDEFINED);
			case ANY:
				// For any, the rejections are what get collected.
				vm.perform_then(next, resolve, object_value(on_value), UNDEFINED);
			default:
				JsFunction* on_reason = vm.new_native("", &native_combine_element, 1)!;
				on_reason.magic = (int)i;
				on_reason.native_data = object_value(shared);
				on_reason.native_data2 = integer(-1);
				vm.perform_then(next, object_value(on_value), object_value(on_reason), UNDEFINED);
		}
	}
	if (items.length == 0 && kind != RACE) vm.combine_finished(shared, kind)!;
	return result;
}

fn void? Vm.combine_finished(&self, JsArray* shared, Combinator kind)
{
	JsPromise* result = (JsPromise*)shared.elements[COMBINE_PROMISE].as_object();
	Value values = shared.elements[COMBINE_VALUES];
	if (kind != ANY)
	{
		self.resolve_promise(result, values);
		return;
	}
	JsObject* err = self.make_error(ERROR, "All promises were rejected") ?? self.oom()~!;
	self.define(err, self.atom_value("errors")!, values, METHOD_PROP)!;
	self.reject_promise(result, object_value(err));
}

// One element settled. native_data2 is the combinator (ALL, ALL_SETTLED or ANY), or -1 for an
// allSettled rejection. Each element counts once.
fn Value? native_combine_element(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!callee.native_data.is_object()) return UNDEFINED;
	JsArray* shared = (JsArray*)callee.native_data.as_object();
	callee.native_data = UNDEFINED;
	int tag = callee.native_data2.as_int();
	Value v = arg(args, 0);
	if (tag == (int)Combinator.ALL_SETTLED.ordinal || tag < 0)
	{
		JsObject* o = vm.heap.new_object(vm.object_proto) ?? vm.oom()~!;
		bool ok = tag >= 0;
		vm.define(o, vm.atom_value("status")!, vm.atom_value(ok ? "fulfilled" : "rejected")!)!;
		vm.define(o, vm.atom_value(ok ? "value" : "reason")!, v)!;
		v = object_value(o);
	}
	((JsArray*)shared.elements[COMBINE_VALUES].as_object()).elements[callee.magic] = v;
	int remaining = shared.elements[COMBINE_REMAINING].as_int() - 1;
	shared.elements[COMBINE_REMAINING] = integer(remaining);
	if (remaining == 0) vm.combine_finished(shared, tag < 0 ? ALL_SETTLED : Combinator::from_ordinal(tag))!;
	return UNDEFINED;
}

fn Value? native_queue_microtask(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value f = arg(args, 0);
	if (!f.is_function()) return vm.throw_error(TYPE_ERROR, "The \"callback\" argument must be of type function. Received %s", vm.describe(f))~;
	vm.enqueue({ .kind = CALLBACK, .handler = f });
	return UNDEFINED;
}

fn Value? native_function_constructor(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return vm.throw_error(SYNTAX_ERROR, "%s() is not supported: this engine has no eval", callee.native_name)~;
}

fn void? Vm.init_coroutines(&self)
{
	Heap* h = &self.heap;
	self.define_constructor("Function", &native_function_constructor, 1, self.function_proto)!;
	self.async_function_proto = h.new_object(self.function_proto)!;
	self.generator_function_proto = h.new_object(self.function_proto)!;
	JsFunction* async_ctor = self.new_native("AsyncFunction", &native_function_constructor, 1)!;
	async_ctor.add(h, self.atoms.prototype, object_value(self.async_function_proto), {})!;
	self.async_function_proto.add(h, self.atoms.constructor, object_value(async_ctor), METHOD_PROP)!;
	JsFunction* gen_ctor = self.new_native("GeneratorFunction", &native_function_constructor, 1)!;
	gen_ctor.add(h, self.atoms.prototype, object_value(self.generator_function_proto), {})!;
	self.generator_function_proto.add(h, self.atoms.constructor, object_value(gen_ctor), METHOD_PROP)!;
	self.generator_proto = h.new_object(self.object_proto)!;
	foreach (i, name : (String[3]){ "next", "throw", "return" })
	{
		self.define_native(self.generator_proto, name, &native_generator_resume, 1)!.magic = (int)i;
	}
	JsFunction* self_iter = self.new_native("[Symbol.iterator]", &native_return_this, 0)!;
	self.generator_proto.add(h, self.sym_iterator, object_value(self_iter), METHOD_PROP)!;

	self.promise_proto = h.new_object(self.object_proto)!;
	JsFunction* ctor = self.define_constructor("Promise", &native_promise, 1, self.promise_proto)!;
	self.define_native(self.promise_proto, "then", &native_promise_then, 2)!;
	self.define_native(self.promise_proto, "catch", &native_promise_catch, 1)!;
	self.define_native(self.promise_proto, "finally", &native_promise_finally, 1)!;
	self.define_native(ctor, "resolve", &native_promise_resolve, 1)!;
	self.define_native(ctor, "reject", &native_promise_reject, 1)!;
	self.define_native(ctor, "withResolvers", &native_promise_with_resolvers, 0)!;
	self.define_native(ctor, "all", &native_promise_combine, 1)!.magic = (int)Combinator.ALL.ordinal;
	self.define_native(ctor, "allSettled", &native_promise_combine, 1)!.magic = (int)Combinator.ALL_SETTLED.ordinal;
	self.define_native(ctor, "any", &native_promise_combine, 1)!.magic = (int)Combinator.ANY.ordinal;
	self.define_native(ctor, "race", &native_promise_combine, 1)!.magic = (int)Combinator.RACE.ordinal;
	self.define_native(self.global, "queueMicrotask", &native_queue_microtask, 1)!;
}

<*
 One step of `yield*`: pass the value and mode the delegating generator was resumed with on to
 the inner iterator. state is [iterator, next, value, mode]. Returns true when the delegation is
 over: value is then the result, and mode is 2 if the outer generator must return it.

 @return? THROWN
*>
fn bool? Vm.yield_star_step(&self, Value* state)
{
	Value it = state[0];
	Value[1] send = { state[2] };
	Value result;
	switch (state[3].as_int())
	{
		case 0:
			result = self.call(state[1], it, &send)!;
		case 1:
			Value m = self.get(it, self.atoms.throw_str)!;
			if (m.is_nullish())
			{
				self.iter_close(state)!;
				return self.throw_error(TYPE_ERROR, "The iterator does not provide a 'throw' method")~;
			}
			result = self.call(m, it, &send)!;
		default:
			Value m = self.get(it, self.atoms.return_str)!;
			if (m.is_nullish()) return true;
			result = self.call(m, it, &send)!;
	}
	if (!result.is_object()) return self.throw_error(TYPE_ERROR, "Iterator result %s is not an object", self.describe(result))~;
	bool done = truthy(self.get(result, self.atoms.done)!);
	state[2] = self.get(result, self.atoms.value)!;
	if (done && state[3].as_int() != 2) state[3] = integer(0);
	return done;
}
