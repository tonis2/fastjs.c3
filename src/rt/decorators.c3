module fastjs::rt;

// Decorators (the TC39 proposal, as TypeScript 5, Babel and esbuild implement it).
//
// A class with decorators or `accessor` fields keeps a decoration state, an array made by
// DECSTART and held in a hidden class-scope constant:
//   [DEC_CLASS_EXTRAS]     addInitializer functions of class decorators, run once the class is done
//   [DEC_STATIC_EXTRAS]    of static methods and accessors, run before the static fields
//   [DEC_INSTANCE_EXTRAS]  of instance methods and accessors, run on each instance before its fields
//   [DEC_METADATA]         context.metadata, which becomes C[Symbol.metadata]
//   [DEC_RECORDS]          the decorated elements, four values each: kind | static, key, decorators, entry
// then three slots per decorated field or accessor ("entry"): its initializers, its own
// addInitializer functions, and an accessor's storage key.
//
// Methods and accessors are defined as usual while the class body is evaluated. DECAPPLY then
// runs the element decorators and redefines what they replace, DECCLASS the class decorators.

const uint DEC_CLASS_EXTRAS = 0;
const uint DEC_STATIC_EXTRAS = 1;
const uint DEC_INSTANCE_EXTRAS = 2;
const uint DEC_METADATA = 3;
const uint DEC_RECORDS = 4;
const uint DEC_ENTRIES = 5;

// The kind operand of DECREC; DEC_STATIC is or'ed in for static elements.
const uint DEC_METHOD = 1;
const uint DEC_GETTER = 2;
const uint DEC_SETTER = 3;
const uint DEC_ACCESSOR = 4;
const uint DEC_FIELD = 5;
const uint DEC_STATIC = 8;

const String[6] DEC_KIND_NAMES = { "class", "method", "getter", "setter", "accessor", "field" };

fn uint dec_entry_slot(uint entry) @inline => DEC_ENTRIES + entry * 3;

fn Value dec_slot(Value state, uint slot) @inline => ((JsArray*)state.as_object()).elements[slot];

<*
 DECSTART: a new decoration state with room for entries; the metadata inherits the parent class's.

 @return? THROWN
*>
fn Value? Vm.decoration_start(&self, Value parent, uint entries)
{
	JsObject* meta_proto = null;
	if (parent.is_object())
	{
		Value inherited = self.get(parent, self.sym_metadata)!;
		if (inherited.is_object()) meta_proto = inherited.as_object();
	}
	JsArray* state = self.new_js_array(DEC_ENTRIES + entries * 3)!;
	for (uint i = 0; i < DEC_METADATA; i++) state.push(object_value(self.new_js_array()!));
	state.push(object_value(self.heap.new_object(meta_proto) ?? self.oom()~!));
	state.push(object_value(self.new_js_array()!));
	for (uint i = 0; i < entries; i++)
	{
		state.push(object_value(self.new_js_array()!));
		state.push(object_value(self.new_js_array()!));
		state.push(UNDEFINED);
	}
	return object_value(state);
}

<*
 DECREC: remember a decorated element until the class body has been evaluated.
*>
fn void Vm.decoration_record(&self, Value state, uint kind, Value key, Value decorators, uint entry)
{
	JsArray* records = (JsArray*)dec_slot(state, DEC_RECORDS).as_object();
	records.push(integer((int)kind));
	records.push(key);
	records.push(decorators);
	records.push(integer((int)entry));
	self.heap.touch(records);
}

<*
 DECAPPLY: run the element decorators, static methods and accessors first, then instance ones,
 then static fields, then instance fields; each group in source order.

 @return? THROWN
*>
fn void? Vm.apply_decorations(&self, Value state, Value cls, Value proto)
{
	self.native_depth++;
	defer self.native_depth--;
	JsArray* records = (JsArray*)dec_slot(state, DEC_RECORDS).as_object();
	for (uint pass = 0; pass < 4; pass++)
	{
		bool want_static = pass % 2 == 0;
		bool want_field = pass >= 2;
		for (uint i = 0; i < records.length; i += 4)
		{
			uint flags = (uint)records.elements[i].as_int();
			uint kind = flags & 7;
			bool is_static = (flags & DEC_STATIC) != 0;
			if (is_static != want_static || (kind == DEC_FIELD) != want_field) continue;
			Value target = is_static ? cls : proto;
			self.decorate_element(state, target, kind, is_static, records.elements[i + 1], records.elements[i + 2], (uint)records.elements[i + 3].as_int())!;
		}
	}
}

<*
 The context object a decorator gets. done is the addInitializer function, to close after the call.

 @return? THROWN
*>
fn Value? Vm.decorator_context(&self, uint kind, Value name, bool is_static, Value metadata, Value extras, Value key, JsFunction** add)
{
	JsObject* ctx = self.heap.new_object(self.object_proto) ?? self.oom()~!;
	Value result = object_value(ctx);
	self.define(ctx, self.atom_value("kind")!, self.atom_value(DEC_KIND_NAMES[kind])!)!;
	self.define(ctx, self.atoms.name, name)!;
	self.define(ctx, self.atom_value("metadata")!, metadata)!;
	JsFunction* add_init = self.new_native("addInitializer", &native_decorator_add_initializer, 1)!;
	add_init.native_data = extras;
	*add = add_init;
	self.define(ctx, self.atom_value("addInitializer")!, object_value(add_init))!;
	if (kind == 0) return result;
	self.define(ctx, self.atom_value("static")!, boolean(is_static))!;
	self.define(ctx, self.atom_value("private")!, FALSE)!;
	JsObject* access = self.heap.new_object(self.object_proto) ?? self.oom()~!;
	self.define(ctx, self.atom_value("access")!, object_value(access))!;
	JsFunction* has = self.new_native("has", &native_decorator_access_has, 1)!;
	has.native_data = key;
	self.define(access, self.atom_value("has")!, object_value(has))!;
	if (kind != DEC_SETTER)
	{
		JsFunction* get = self.new_native("get", &native_decorator_access_get, 1)!;
		get.native_data = key;
		self.define(access, self.atom_value("get")!, object_value(get))!;
	}
	if (kind >= DEC_SETTER)
	{
		JsFunction* set = self.new_native("set", &native_decorator_access_set, 2)!;
		set.native_data = key;
		self.define(access, self.atom_value("set")!, object_value(set))!;
	}
	return result;
}

<*
 Fail unless v is a function or undefined: what a decorator, or an accessor decorator's get, set
 and init, may give back.

 @return? THROWN
*>
fn void? Vm.expect_decorator_fn(&self, Value v, String what)
{
	if (!v.is_undefined() && !v.is_function()) return self.throw_error(TYPE_ERROR, "%s must be a function or undefined, not %s", what, self.describe(v))~;
}

<*
 Apply one element's decorators, last first, and define what they return.

 @return? THROWN
*>
fn void? Vm.decorate_element(&self, Value state, Value target, uint kind, bool is_static, Value key, Value decorators, uint entry)
{
	JsObject* t = target.as_object();
	Value value = UNDEFINED;
	Value getter = UNDEFINED;
	Value setter = UNDEFINED;
	if (kind != DEC_FIELD)
	{
		Shape* s = t.find_own(key);
		if (s && s.flags.accessor)
		{
			Accessor* acc = (Accessor*)t.slots[s.slot()].as_object();
			getter = acc.getter;
			setter = acc.setter;
		}
		else if (s)
		{
			value = t.slots[s.slot()];
		}
	}
	bool per_entry = kind == DEC_FIELD || kind == DEC_ACCESSOR;
	Value initializers = per_entry ? dec_slot(state, dec_entry_slot(entry)) : UNDEFINED;
	Value extras = per_entry ? dec_slot(state, dec_entry_slot(entry) + 1) : dec_slot(state, is_static ? DEC_STATIC_EXTRAS : DEC_INSTANCE_EXTRAS);
	Value name = key.is_int() ? string_value(self.to_string(key)!) : key;
	Value metadata = dec_slot(state, DEC_METADATA);
	JsArray* decs = (JsArray*)decorators.as_object();
	for (uint i = decs.length; i-- > 0;)
	{
		JsFunction* add;
		Value ctx = self.decorator_context(kind, name, is_static, metadata, extras, key, &add)!;
		Value arg;
		switch (kind)
		{
			case DEC_METHOD: arg = value;
			case DEC_GETTER: arg = getter;
			case DEC_SETTER: arg = setter;
			case DEC_ACCESSOR:
				JsObject* pair = self.heap.new_object(self.object_proto) ?? self.oom()~!;
				self.define(pair, self.atom_value("get")!, getter)!;
				self.define(pair, self.atom_value("set")!, setter)!;
				arg = object_value(pair);
			default: arg = UNDEFINED;
		}
		Value? it = self.call(decs.elements[i], UNDEFINED, { arg, ctx });
		add.magic = 1;
		Value result = it!;
		if (result.is_undefined()) continue;
		switch (kind)
		{
			case DEC_METHOD:
				self.expect_decorator_fn(result, "A method decorator's result")!;
				value = result;
			case DEC_GETTER:
				self.expect_decorator_fn(result, "A getter decorator's result")!;
				getter = result;
			case DEC_SETTER:
				self.expect_decorator_fn(result, "A setter decorator's result")!;
				setter = result;
			case DEC_FIELD:
				self.expect_decorator_fn(result, "A field decorator's result")!;
				self.push_initializer(initializers, result);
			default:
				if (!result.is_object()) return self.throw_error(TYPE_ERROR, "An accessor decorator's result must be an object or undefined, not %s", self.describe(result))~;
				Value g = self.get(result, self.atom_value("get")!)!;
				self.expect_decorator_fn(g, "An accessor decorator's get")!;
				Value st = self.get(result, self.atom_value("set")!)!;
				self.expect_decorator_fn(st, "An accessor decorator's set")!;
				Value init = self.get(result, self.atom_value("init")!)!;
				self.expect_decorator_fn(init, "An accessor decorator's init")!;
				if (!g.is_undefined()) getter = g;
				if (!st.is_undefined()) setter = st;
				if (!init.is_undefined()) self.push_initializer(initializers, init);
		}
	}
	switch (kind)
	{
		case DEC_METHOD: self.define(t, key, value, METHOD_PROP)!;
		case DEC_GETTER:
		case DEC_SETTER:
		case DEC_ACCESSOR: self.define_accessor(t, key, getter, setter, METHOD_PROP)!;
		default: break;
	}
}

// Initializers are kept in application order (innermost decorator first) and run last to first.
fn void Vm.push_initializer(&self, Value list, Value f)
{
	JsArray* a = (JsArray*)list.as_object();
	a.push(f);
	self.heap.touch(a);
}

<*
 DECCLASS: apply the class decorators to cls, last first, and give the result its metadata.

 @return? THROWN
*>
fn Value? Vm.decorate_class(&self, Value cls, Value decorators, Value state)
{
	self.native_depth++;
	defer self.native_depth--;
	Value metadata = dec_slot(state, DEC_METADATA);
	if (decorators.is_object())
	{
		Value name = self.get(cls, self.atoms.name)!;
		JsArray* decs = (JsArray*)decorators.as_object();
		for (uint i = decs.length; i-- > 0;)
		{
			JsFunction* add;
			Value ctx = self.decorator_context(0, name, false, metadata, dec_slot(state, DEC_CLASS_EXTRAS), UNDEFINED, &add)!;
			Value? it = self.call(decs.elements[i], UNDEFINED, { cls, ctx });
			add.magic = 1;
			Value result = it!;
			if (result.is_undefined()) continue;
			self.expect_decorator_fn(result, "A class decorator's result")!;
			cls = result;
		}
	}
	// A class whose only extra is an undecorated `accessor` has no metadata to show.
	JsArray* records = (JsArray*)dec_slot(state, DEC_RECORDS).as_object();
	if (decorators.is_object() || records.length) self.define(cls.as_object(), self.sym_metadata, metadata)!;
	return cls;
}

<*
 RUNINITS: call each function of a state list with `this`.

 @return? THROWN
*>
fn void? Vm.run_initializers(&self, Value this_value, Value list)
{
	self.native_depth++;
	defer self.native_depth--;
	JsArray* a = (JsArray*)list.as_object();
	for (uint i = 0; i < a.length; i++) self.call(a.elements[i], this_value, {})!;
}

<*
 APPLYINITS: pass a field's initial value through its decorators' initializers, outermost first.

 @return? THROWN
*>
fn Value? Vm.apply_initializers(&self, Value this_value, Value list, Value v)
{
	// v lives only here between the calls, so no collection may run meanwhile.
	self.native_depth++;
	defer self.native_depth--;
	JsArray* a = (JsArray*)list.as_object();
	for (uint i = a.length; i-- > 0;) v = self.call(a.elements[i], this_value, { v })!;
	return v;
}

<*
 NEWSLOT: make an `accessor` field's storage key and define its getter and setter on target.

 @return? THROWN
*>
fn void? Vm.new_accessor_slot(&self, Value state, Value target, Value key, uint entry)
{
	Value text = key.is_symbol() ? key.as_symbol().description : string_value(self.to_string(key)!);
	Value slot = self.new_symbol(text)!;
	slot.as_symbol().is_private = true;
	JsArray* s = (JsArray*)state.as_object();
	s.elements[dec_entry_slot(entry) + 2] = slot;
	self.heap.touch(s);
	String name = key.is_symbol() ? (text.is_string() ? string::tformat("[%s]", text.as_string().tutf8()) : "") : text.as_string().tutf8();
	JsFunction* get = self.new_native("", &native_accessor_slot_get, 0)!;
	get.native_data = slot;
	self.define(get, self.atoms.name, self.str_value(string::tformat("get %s", name))!, { .configurable = true })!;
	JsFunction* set = self.new_native("", &native_accessor_slot_set, 1)!;
	set.native_data = slot;
	self.define(set, self.atoms.name, self.str_value(string::tformat("set %s", name))!, { .configurable = true })!;
	self.define_accessor(target.as_object(), key, object_value(get), object_value(set), METHOD_PROP)!;
}

<*
 INITSLOT: give an object an `accessor` field's storage.

 @return? THROWN
*>
fn void? Vm.init_accessor_slot(&self, Value obj, Value slot, Value v)
{
	if (!obj.is_object()) return self.throw_error(TYPE_ERROR, "Cannot initialize accessor storage on %s", self.describe(obj))~;
	JsObject* o = obj.as_object();
	if (o.find_own(slot)) return self.throw_error(TYPE_ERROR, "Cannot initialize accessor storage twice on the same object")~;
	o.add(&self.heap, slot, v, METHOD_PROP) ?? self.oom()~!;
}

fn Value? native_accessor_slot_get(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Shape* s = this_value.is_object() ? this_value.as_object().find_own(callee.native_data) : null;
	if (!s) return vm.throw_error(TYPE_ERROR, "Cannot read private member from an object whose class did not declare it")~;
	return this_value.as_object().slots[s.slot()];
}

fn Value? native_accessor_slot_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Shape* s = this_value.is_object() ? this_value.as_object().find_own(callee.native_data) : null;
	if (!s) return vm.throw_error(TYPE_ERROR, "Cannot write private member to an object whose class did not declare it")~;
	JsObject* o = this_value.as_object();
	o.slots[s.slot()] = arg(args, 0);
	vm.heap.touch(o);
	return UNDEFINED;
}

fn Value? native_decorator_add_initializer(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (callee.magic) return vm.throw_error(TYPE_ERROR, "addInitializer can't be called once the decorator has returned")~;
	Value f = arg(args, 0);
	if (!f.is_function()) return vm.throw_error(TYPE_ERROR, "An initializer must be a function, not %s", vm.describe(f))~;
	vm.push_initializer(callee.native_data, f);
	return UNDEFINED;
}

fn Value? native_decorator_access_has(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return boolean(vm.has_property(arg(args, 0), callee.native_data)!);
}

fn Value? native_decorator_access_get(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return vm.get(arg(args, 0), callee.native_data);
}

fn Value? native_decorator_access_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value v = arg(args, 1);
	vm.set(arg(args, 0), callee.native_data, v)!;
	return v;
}
