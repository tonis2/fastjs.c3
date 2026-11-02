module fastjs::rt;

// Async generators and `for await`.
//
// An async generator is a generator coroutine (async_gen set) with a queue of requests: each
// next/return/throw call adds [mode, value, promise] and returns the promise. The queue is
// served one request at a time. The body runs until it yields, which settles the request at
// the head with { value, done: false }; or awaits, after which the job queue resumes it through
// async_gen_run; or finishes, which settles the head with done: true (or rejects it) and every
// later request at once.
//
// `for await` gets an async iterator (async_iterator_of): obj[Symbol.asyncIterator](), or a
// sync iterator wrapped so that each step's value is awaited.

const uint ASYNC_REQUEST = 3;

<*
 A next/return/throw call on an async generator: queue it, and start it if nothing runs.

 @return? THROWN
*>
fn Value? native_async_gen_method(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsPromise* p = vm.new_promise()!;
	if (!this_value.is_object() || this_value.as_object().kind != COROUTINE || !((JsCoroutine*)this_value.as_object()).async_gen)
	{
		JsObject* err = vm.make_error(TYPE_ERROR, "AsyncGenerator method called on an incompatible receiver")!;
		vm.reject_promise(p, object_value(err));
		return object_value(p);
	}
	JsCoroutine* c = (JsCoroutine*)this_value.as_object();
	if (!c.queue.is_object()) c.queue = object_value(vm.heap.new_array(vm.array_proto) ?? vm.oom()~!);
	JsArray* q = (JsArray*)c.queue.as_object();
	q.push(integer(callee.magic));
	q.push(arg(args, 0));
	q.push(object_value(p));
	vm.heap.touch(q);
	vm.heap.touch(c);
	vm.async_gen_drain(c)!;
	return object_value(p);
}

<*
 Serve queued requests while the generator is free to take them.

 @return? THROWN
*>
fn void? Vm.async_gen_drain(&self, JsCoroutine* c)
{
	if (!c.queue.is_object()) return;
	JsArray* q = (JsArray*)c.queue.as_object();
	while ((c.queue_head + 1) * ASYNC_REQUEST <= q.length)
	{
		if (c.state == RUNNING || c.awaiting) return;
		uint at = c.queue_head * ASYNC_REQUEST;
		ResumeMode mode = ResumeMode::from_ordinal(q.elements[at].as_int());
		Value v = q.elements[at + 1];
		// Nothing has run yet, so there is no try block to send return or throw into.
		if (c.state == SUSPENDED_START && mode != NEXT) c.finish();
		if (c.state == DONE)
		{
			switch (mode)
			{
				case NEXT: self.async_gen_settle(c, UNDEFINED, false, true)!;
				case RETURN: self.async_gen_settle(c, v, false, true)!;
				case THROW: self.async_gen_settle(c, v, true, true)!;
			}
			continue;
		}
		self.async_gen_run(c, v, mode)!;
	}
	// Every request is settled: start the queue over.
	q.length = 0;
	c.queue_head = 0;
}

<*
 Run the generator from where it stopped, until it yields, awaits or finishes.

 @return? THROWN
*>
fn void? Vm.async_gen_run(&self, JsCoroutine* c, Value v, ResumeMode mode)
{
	c.awaiting = false;
	Value? r = self.resume(c, v, mode);
	if (catch err = r)
	{
		// The script can't catch an interrupt, so neither does the generator's caller.
		if (self.uncatchable) return err~;
		Value reason = self.exception;
		self.exception = UNDEFINED;
		return self.async_gen_settle(c, reason, true, true);
	}
	if (c.state == DONE) return self.async_gen_settle(c, r, false, true);
	if (ins_op(c.function.proto.code[c.pc - 1]) == AWAIT)
	{
		// The job queue resumes it when the awaited value settles (run_job).
		c.awaiting = true;
		return;
	}
	self.async_gen_settle(c, r, false, false)!;
}

<*
 Settle the request at the head of the queue.

 @return? THROWN
*>
fn void? Vm.async_gen_settle(&self, JsCoroutine* c, Value v, bool rejected, bool done)
{
	JsArray* q = (JsArray*)c.queue.as_object();
	JsPromise* p = (JsPromise*)q.elements[c.queue_head * ASYNC_REQUEST + 2].as_object();
	c.queue_head++;
	if (rejected)
	{
		self.reject_promise(p, v);
		return;
	}
	self.resolve_promise(p, self.iter_result(v, done)!);
}

<*
 An await inside an async generator finished: carry on, then serve what queued meanwhile.

 @return? THROWN
*>
fn void? Vm.async_gen_continue(&self, JsCoroutine* c, Value v, bool rejected)
{
	self.async_gen_run(c, v, rejected ? THROW : NEXT)!;
	self.async_gen_drain(c)!;
}

// ---- for await ----

<*
 The async iterator `for await` steps, into state[0] (the iterator) and state[1] (its next).

 @return? THROWN
*>
fn void? Vm.async_iterator_of(&self, Value v, Value* state)
{
	if (v.is_nullish()) return self.not_iterable(v)~;
	Value method = self.get(v, self.sym_async_iterator)!;
	if (!method.is_nullish())
	{
		if (!method.is_function()) return self.throw_error(TYPE_ERROR, "Symbol.asyncIterator is not a function")~;
		Value it = self.call(method, v, {})!;
		if (!it.is_object()) return self.throw_error(TYPE_ERROR, "Result of the Symbol.asyncIterator method is not an object")~;
		state[0] = it;
		state[1] = self.get(it, self.atoms.next)!;
		return;
	}
	// A sync iterable: wrap its iterator so each step's value is awaited.
	Value[2] sync;
	self.get_iterator(v, &sync)!;
	if (sync[1].is_int())
	{
		// The array fast path's state; make it a real iterator, since the wrapper calls next().
		Value values = self.call(self.get(v, self.sym_iterator)!, v, {})!;
		sync[0] = values;
		sync[1] = self.get(values, self.atoms.next)!;
	}
	JsObject* wrapper = self.heap.new_object(self.object_proto) ?? self.oom()~!;
	JsFunction* next = self.new_native("next", &native_async_from_sync_next, 1)!;
	next.native_data = sync[0];
	next.native_data2 = sync[1];
	JsFunction* ret = self.new_native("return", &native_async_from_sync_return, 1)!;
	ret.native_data = sync[0];
	self.define(wrapper, self.atoms.return_str, object_value(ret), METHOD_PROP)!;
	state[0] = object_value(wrapper);
	state[1] = object_value(next);
}

fn Value? native_async_from_sync_next(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsPromise* p = vm.new_promise()!;
	Value? result = vm.call(callee.native_data2, callee.native_data, args);
	if (catch result)
	{
		vm.reject_with_exception(p);
		return object_value(p);
	}
	return vm.async_from_sync_result(result, p);
}

fn Value? native_async_from_sync_return(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsPromise* p = vm.new_promise()!;
	Value ret = vm.get(callee.native_data, vm.atoms.return_str)!;
	if (!ret.is_function())
	{
		vm.resolve_promise(p, vm.iter_result(arg(args, 0), true)!);
		return object_value(p);
	}
	Value? result = vm.call(ret, callee.native_data, args);
	if (catch result)
	{
		vm.reject_with_exception(p);
		return object_value(p);
	}
	return vm.async_from_sync_result(result, p);
}

<*
 Settle p with a sync step's result, its value awaited: { value: await value, done }.

 @return? THROWN
*>
fn Value? Vm.async_from_sync_result(&self, Value result, JsPromise* p)
{
	if (!result.is_object()) return self.throw_error(TYPE_ERROR, "Iterator result %s is not an object", self.describe(result))~;
	bool done = truthy(self.get(result, self.atoms.done)!);
	Value value = self.get(result, self.atoms.value)!;
	JsFunction* wrap = self.new_native("", &native_async_from_sync_wrap, 1)!;
	wrap.magic = done ? 1 : 0;
	self.perform_then(self.promise_resolve(value)!, object_value(wrap), UNDEFINED, object_value(p));
	return object_value(p);
}

fn Value? native_async_from_sync_wrap(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return vm.iter_result(arg(args, 0), callee.magic != 0);
}

<*
 r[a] is an iterator result: r[a] = its value, r[a + 1] = whether it is done.

 @return? THROWN
*>
fn void? Vm.unpack_iter_result(&self, Value* r)
{
	Value result = r[0];
	if (!result.is_object()) return self.throw_error(TYPE_ERROR, "Iterator result %s is not an object", self.describe(result))~;
	r[1] = boolean(truthy(self.get(result, self.atoms.done)!));
	r[0] = self.get(result, self.atoms.value)!;
}

fn void? Vm.init_async_generators(&self)
{
	Heap* h = &self.heap;
	JsObject* async_iterator_proto = h.new_object(self.object_proto)!;
	JsFunction* self_iter = self.new_native("[Symbol.asyncIterator]", &native_return_this, 0)!;
	async_iterator_proto.add(h, self.sym_async_iterator, object_value(self_iter), METHOD_PROP)!;
	self.async_generator_proto = h.new_object(async_iterator_proto)!;
	foreach (i, name : (String[3]){ "next", "throw", "return" })
	{
		self.define_native(self.async_generator_proto, name, &native_async_gen_method, 1)!.magic = (int)i;
	}
	self.async_generator_function_proto = h.new_object(self.function_proto)!;
	JsFunction* ctor = self.new_native("AsyncGeneratorFunction", &native_function_constructor, 1)!;
	ctor.add(h, self.atoms.prototype, object_value(self.async_generator_function_proto), {})!;
	self.async_generator_function_proto.add(h, self.atoms.constructor, object_value(ctor), METHOD_PROP)!;
}
