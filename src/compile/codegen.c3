module fastjs::compile;
import std::collections::list, std::math, fastjs::ast, fastjs::lex, fastjs::rt;

const uint MAX_REGS = 250;
// A destination meaning "the value isn't needed", for expression statements.
const uint DISCARD = 0xFFFF;

enum JumpKind : char
{
	LOOP,
	SWITCH,
	FINALLY,
	// A labelled statement other than a loop: only `break label` leaves it.
	LABEL,
}

<*
 A break or continue that leaves a try-finally: it records a completion code, runs the finally
 block, and the finally's dispatch then performs the jump.
*>
struct FinallyExit
{
	uint code;
	bool is_break;
	JumpCtx* target;
}

struct JumpCtx
{
	JumpCtx* outer;
	JumpKind kind;
	List {uint} breaks;
	List {uint} continues;
	// FINALLY: completion type (0 normal, 1 throw, 2 return, 3+ the exits) and its value.
	uint ctype;
	uint cval;
	List {uint} entries;
	List {FinallyExit} exits;
	bool has_return;
	uint next_code;
	// A for-of loop: leaving it early calls the iterator's return(), whose state starts here.
	bool closes_iterator;
	uint iter_reg;
	// A for await: the close awaits what return() gives.
	bool async_close;
	// The outermost of the labels on this loop or statement (a LABELED chain), or null.
	Node* labels;
}

struct FuncState
{
	FuncState* parent;
	FuncInfo* info;
	List {uint} code;
	List {uint} lines;
	List {Value} consts;
	List {FunctionProto*} protos;
	List {Handler} handlers;
	List {SiteName} site_names;
	uint free_reg;
	uint max_reg;
	uint line;
	JumpCtx* jumps;
	// Labels on the loop about to be compiled, which its push_jump(LOOP) takes.
	Node* pending_labels;
	// Jumps to the short-circuit of the innermost optional chain.
	List {uint}* chain_nils;
	// In a class constructor: `this` starts uninitialized (derived) and fields run at the start or after super().
	bool derived_ctor;
	bool class_has_fields;
}

struct Codegen
{
	Vm* vm;
	Allocator arena;
	FuncState* fs;
	String source_name;
	// The source being compiled, owned by the Script or module record, which functions slice.
	String source_text;
	// Set while compiling a class's constructor, so it knows whether instance fields exist.
	bool pending_class_fields;
	String error;
	uint error_line;
	uint error_col;
	char[200] error_buf;
}

fn fault Codegen.fail(&self, Node* at, String message)
{
	self.error = message;
	self.error_line = at ? at.line : self.fs.line;
	self.error_col = at ? at.col : 0;
	return COMPILE_ERROR;
}

fn fault Codegen.unsupported(&self, Node* at, String what)
{
	return self.fail(at, string::bformat(&self.error_buf, "%s are not supported yet", what));
}

// ---- emitting ----

fn uint Codegen.pc(&self) @inline => (uint)self.fs.code.len();

fn uint Codegen.emit(&self, uint ins)
{
	self.fs.code.push(ins);
	self.fs.lines.push(self.fs.line);
	return (uint)self.fs.code.len() - 1;
}

fn void Codegen.emit_abc(&self, Op op, uint a, uint b = 0, uint c = 0) => (void)self.emit(rt::encode_abc(op, a, b, c));
fn void Codegen.emit_abx(&self, Op op, uint a, uint bx) => (void)self.emit(rt::encode_abx(op, a, bx));

fn uint? Codegen.alloc(&self, uint n = 1)
{
	uint r = self.fs.free_reg;
	self.fs.free_reg += n;
	if (self.fs.free_reg > MAX_REGS) return self.fail(null, "function needs too many registers")~;
	if (self.fs.free_reg > self.fs.max_reg) self.fs.max_reg = self.fs.free_reg;
	return r;
}

fn void Codegen.release(&self, uint to) @inline => self.fs.free_reg = to;

fn uint? Codegen.const_index(&self, Value v)
{
	foreach (i, c : self.fs.consts)
	{
		if (c == v) return (uint)i;
	}
	if (self.fs.consts.len() >= 65535) return self.fail(null, "function has too many constants")~;
	self.fs.consts.push(v);
	return (uint)self.fs.consts.len() - 1;
}

fn Value? Codegen.atom(&self, String name)
{
	return rt::string_value(self.vm.heap.atom(name) ?? self.fail(null, "out of memory")~!);
}

fn uint? Codegen.atom_const(&self, String name) => self.const_index(self.atom(name)!);

fn uint? Codegen.emit_jump(&self, Op op, uint a = 0)
{
	if (op == JMP) return self.emit(rt::encode_sax(JMP, 0));
	return self.emit(rt::encode_asbx(op, a, 0));
}

<*
 Point the jump at pc `at` to target.
*>
fn void? Codegen.patch_to(&self, uint at, uint target)
{
	uint ins = self.fs.code[at];
	Op op = rt::ins_op(ins);
	int offset = (int)target - (int)(at + 1);
	if (op == JMP)
	{
		self.fs.code[at] = rt::encode_sax(JMP, offset);
		return;
	}
	if (offset > rt::SBX_MAX || offset < rt::SBX_MIN) return self.fail(null, "function too large: a conditional jump is out of range")~;
	self.fs.code[at] = rt::encode_asbx(op, rt::ins_a(ins), offset);
}

fn void? Codegen.patch(&self, uint at) => self.patch_to(at, self.pc());

fn void? Codegen.patch_all(&self, List {uint}* jumps, uint target)
{
	foreach (j : *jumps) self.patch_to(j, target)!;
}

fn void? Codegen.jump_back(&self, Op op, uint a, uint target)
{
	uint at = self.emit_jump(op, a)!;
	self.patch_to(at, target)!;
}

// ---- constants ----

fn Value? Codegen.string_const(&self, String raw, bool escaped, bool template)
{
	Heap* h = &self.vm.heap;
	JsString* s;
	if (escaped || (template && raw.contains("\r")))
	{
		s = h.cook(raw, template) ?? self.fail(null, "string too long")~!;
	}
	else
	{
		s = h.string_from_utf8(raw) ?? self.fail(null, "string too long")~!;
	}
	return rt::string_value(h.intern(s));
}

<*
 A property key as a canonical constant: an int for array-index-like keys, else an atom.
*>
fn Value? Codegen.key_const(&self, Node* key)
{
	switch (key.kind)
	{
		case IDENT:
			return self.atom(key.name);
		case STRING:
			Value v = self.string_const(key.name, key.flags.escaped, false)!;
			uint index;
			if (v.as_string().array_index(&index) && index <= (uint)int::max) return rt::integer((int)index);
			return v;
		case NUMBER:
			double d = key.number;
			if (d >= 0 && d <= (double)int::max && d == math::floor(d)) return rt::integer((int)d);
			JsString* s = self.vm.heap.number_to_string(d) ?? self.fail(key, "out of memory")~!;
			return rt::string_value(self.vm.heap.intern(s));
		default:
			return self.fail(key, "invalid property key")~;
	}
}

fn void? Codegen.load_value(&self, uint dest, Value v)
{
	if (v.is_int() && v.as_int() >= rt::SBX_MIN && v.as_int() <= rt::SBX_MAX)
	{
		self.emit((uint)rt::encode_asbx(LOADI, dest, v.as_int()));
		return;
	}
	self.emit_abx(LOADK, dest, self.const_index(v)!);
}

fn void? Codegen.get_key(&self, uint dest, uint obj, Value key)
{
	uint k = self.const_index(key)!;
	if (k <= 255)
	{
		self.emit_abc(GETPROP, dest, obj, k);
		return;
	}
	uint t = self.alloc()!;
	self.emit_abx(LOADK, t, k);
	self.emit_abc(GETELEM, dest, obj, t);
	self.release(t);
}

fn void? Codegen.set_key(&self, uint obj, Value key, uint src)
{
	uint k = self.const_index(key)!;
	if (k <= 255)
	{
		self.emit_abc(SETPROP, obj, k, src);
		return;
	}
	uint t = self.alloc()!;
	self.emit_abx(LOADK, t, k);
	self.emit_abc(SETELEM, obj, t, src);
	self.release(t);
}

// ---- bindings ----

fn uint? Codegen.capture_index(&self, Binding* b, Node* at)
{
	foreach (i, c : self.fs.info.captures)
	{
		if (c == b) return (uint)i;
	}
	return self.fail(at, "internal error: variable not captured")~;
}

<*
 Reserve a register for a local binding (slots need none).
*>
fn void? Codegen.alloc_storage(&self, Binding* b)
{
	if (b.is_slot) return;
	b.reg = (int)self.alloc()!;
}

<*
 Put a binding into its pre-initialization state: a fresh box when captured, or the TDZ marker.
*>
fn void? Codegen.init_storage(&self, Binding* b)
{
	if (b.is_slot)
	{
		if (b.kind == LET || b.kind == CONST || b.kind == CLASS)
		{
			uint t = self.alloc()!;
			self.emit_abc(LOADTDZ, t);
			self.emit_abx(INITSLOT, t, b.slot);
			self.release(t);
		}
		return;
	}
	if (b.captured)
	{
		self.emit_abc(NEWBOX, (uint)b.reg);
	}
	else if (b.tdz_used)
	{
		self.emit_abc(LOADTDZ, (uint)b.reg);
	}
}

fn bool Codegen.is_plain_local(&self, Binding* b) => b && !b.is_slot && !b.captured && b.func == self.fs.info;

fn void? Codegen.load_binding(&self, Node* ident, uint dest)
{
	Binding* b = ident.sema;
	if (!b)
	{
		self.emit_abx(GETGLOBAL, dest, self.atom_const(ident.name)!);
		return;
	}
	switch
	{
		case b.is_slot:
			self.emit_abx(GETSLOT, dest, b.slot);
		case b.func != self.fs.info:
			self.emit_abc(GETCAP, dest, self.capture_index(b, ident)!);
		case b.captured:
			self.emit_abc(GETBOX, dest, (uint)b.reg);
		default:
			if (dest != (uint)b.reg) self.emit_abc(MOVE, dest, (uint)b.reg);
			if (ident.flags.needs_tdz) self.emit_abx(CHECKTDZ, dest, self.atom_const(ident.name)!);
	}
}

<*
 Store src into the variable an identifier names. init is true for the declaration itself.
*>
fn void? Codegen.store_binding(&self, Node* ident, uint src, bool init)
{
	Binding* b = ident.sema;
	if (!b)
	{
		self.emit_abx(SETGLOBAL, src, self.atom_const(ident.name)!);
		return;
	}
	if (!init && (b.kind == CONST || b.kind == SELF))
	{
		self.emit_abx(THROWCONST, 0, self.atom_const(ident.name)!);
		return;
	}
	switch
	{
		case b.is_slot:
			self.emit_abx(init ? INITSLOT : SETSLOT, src, b.slot);
		case b.func != self.fs.info:
			self.emit_abc(init ? INITCAP : SETCAP, src, self.capture_index(b, ident)!);
		case b.captured:
			self.emit_abc(init ? INITBOX : SETBOX, src, (uint)b.reg);
		default:
			if (!init && ident.flags.needs_tdz) self.emit_abx(CHECKTDZ, (uint)b.reg, self.atom_const(ident.name)!);
			if (src != (uint)b.reg) self.emit_abc(MOVE, (uint)b.reg, src);
	}
}

fn void? Codegen.store_binding_value(&self, Binding* b, uint src)
{
	Node fake = { .kind = IDENT, .name = b.name, .sema = b };
	self.store_binding(&fake, src, true)!;
}

<*
 Enter a scope: reserve storage for its bindings, then create its hoisted functions.
*>
fn void? Codegen.enter_scope(&self, Scope* s)
{
	if (!s) return;
	foreach (b : s.bindings)
	{
		if (b.kind == PARAM || b.kind == SELF) continue;
		self.alloc_storage(b)!;
		self.init_storage(b)!;
	}
	foreach (b : s.bindings)
	{
		if (b.kind != FUNCTION) continue;
		uint t = self.alloc()!;
		self.closure(b.decl, t, b.name)!;
		self.store_binding_value(b, t)!;
		self.release(t);
	}
}

// ---- functions ----

fn void Codegen.begin_function(&self, FuncState* fs, FuncInfo* info)
{
	*fs = { .parent = self.fs, .info = info, .line = info.node.line };
	fs.code.init(mem);
	fs.lines.init(mem);
	fs.consts.init(mem);
	fs.protos.init(mem);
	fs.handlers.init(mem);
	fs.site_names.init(mem);
	self.fs = fs;
}

<*
 Remember how the source wrote e, for the error if the instruction emitted next fails: the
 callee of a call or the iterable of a for-of, the way V8 words it ("o.foo is not a function").
*>
fn void Codegen.name_site(&self, Node* e)
{
	DString out;
	out.init(mem);
	site_text(&out, e);
	self.fs.site_names.push({ .pc = self.pc(), .text = out.copy_str(mem) });
	out.free();
}

fn void Codegen.name_spread_argument(&self)
{
	self.fs.site_names.push({ .pc = self.pc(), .text = rt::SPREAD_ARGUMENT_SITE.copy(mem) });
}

fn void site_text(DString* out, Node* e)
{
	switch (e.kind)
	{
		case IDENT:
			out.append(e.name);
		case THIS:
			out.append("this");
		case NUMBER:
			out.append(e.name);
		case STRING:
			out.appendf("\"%s\"", e.name);
		case NULL:
			out.append("null");
		case TRUE:
			out.append("true");
		case FALSE:
			out.append("false");
		case OPTIONAL_CHAIN:
			site_text(out, e.a);
		case CALL:
			site_text(out, e.a);
			out.append("(...)");
		case MEMBER:
			site_text(out, e.a);
			if (!e.flags.computed)
			{
				out.append(e.flags.optional ? "?." : ".");
				out.append(e.name);
				return;
			}
			if (e.flags.optional) out.append("?.");
			switch (e.b.kind)
			{
				case STRING:
					out.appendf(".%s", e.b.name);
				case IDENT:
				case NUMBER:
				case MEMBER:
				case CALL:
				case THIS:
					out.append('[');
					site_text(out, e.b);
					out.append(']');
				default:
					out.append("[...]");
			}
		case ARRAY:
			foreach (el : e.list)
			{
				switch (el.kind)
				{
					case NUMBER:
					case STRING:
					case IDENT:
					case NULL:
					case TRUE:
					case FALSE:
						break;
					default:
						out.append("(intermediate value)");
						return;
				}
			}
			out.append('[');
			foreach (i, el : e.list)
			{
				if (i) out.append(',');
				site_text(out, el);
			}
			out.append(']');
		default:
			// V8's words for anything it doesn't print: super, function expressions, operators.
			out.append("(intermediate value)");
	}
}

fn void FuncState.free_parts(&self)
{
	foreach (p : self.protos)
	{
		p.free();
		free(p);
	}
	self.code.free();
	self.lines.free();
	self.consts.free();
	self.protos.free();
	self.handlers.free();
	foreach (n : self.site_names) free(n.text);
	self.site_names.free();
}

macro copy_list(list) => @clone_slice(list.array_view());

fn FunctionProto* Codegen.end_function(&self, FuncState* fs, Node* node, String name, uint nparams, bool has_rest)
{
	FunctionProto* p = mem::new(FunctionProto);
	p.name = name.copy(mem);
	p.source_name = self.source_name;
	p.code = copy_list(fs.code);
	p.ics = mem::new_array(IcEntry, p.code.len);
	p.lines = copy_list(fs.lines);
	p.consts = copy_list(fs.consts);
	p.protos = copy_list(fs.protos);
	p.handlers = copy_list(fs.handlers);
	p.site_names = copy_list(fs.site_names);
	fs.site_names.clear();
	p.nparams = nparams;
	foreach (param : node.list)
	{
		if (param.kind == REST || param.kind == ASSIGN_PATTERN) break;
		p.length++;
	}
	p.nregs = fs.max_reg + 1;
	p.line = node.line;
	p.has_rest = has_rest;
	if (node.end > node.start && node.end <= self.source_text.len) p.source = self.source_text[node.start:node.end - node.start];
	if (node.kind == FUNCTION)
	{
		p.is_arrow = node.flags.arrow;
		p.is_async = node.flags.is_async;
		p.is_generator = node.flags.generator;
		p.is_method = node.flags.method;
		p.is_class_constructor = node.flags.class_constructor;
		p.is_derived = node.flags.derived;
	}
	CaptureSource[] captures = mem::new_array(CaptureSource, fs.info.captures.len());
	FuncState* parent = fs.parent;
	// A module function's captures are its module's boxes, wired up when it is linked.
	if (!parent)
	{
		free(captures);
		captures = {};
	}
	foreach (i, b : parent ? fs.info.captures.array_view() : {})
	{
		if (b.func == parent.info)
		{
			captures[i] = { .from_capture = false, .index = (uint)b.reg };
			continue;
		}
		foreach (j, pc : parent.info.captures)
		{
			if (pc == b) captures[i] = { .from_capture = true, .index = (uint)j };
		}
	}
	p.captures = captures.len ? captures : {};
	if (!captures.len) free(captures);
	fs.protos.clear();
	fs.free_parts();
	self.fs = fs.parent;
	return p;
}

<*
 Compile a nested function and emit CLOSURE for it into dest.
*>
fn void? Codegen.closure(&self, Node* node, uint dest, String name_hint)
{
	FunctionProto* p = self.compile_function(node, node.name.len ? node.name : name_hint)!;
	self.fs.protos.push(p);
	self.emit_abx(CLOSURE, dest, (uint)self.fs.protos.len() - 1);
}

fn FunctionProto*? Codegen.compile_function(&self, Node* node, String name)
{
	FuncInfo* info = node.sema;
	FuncState fs;
	self.begin_function(&fs, info);
	defer (catch err)
	{
		self.fs = fs.parent;
		fs.free_parts();
	}
	uint nparams = 0;
	bool has_rest = false;
	foreach (p : node.list)
	{
		if (p.kind == REST)
		{
			has_rest = true;
		}
		else
		{
			nparams++;
		}
	}
	if (nparams + 2 > MAX_REGS) return self.fail(node, "too many parameters")~;
	fs.free_reg = 1 + nparams + (has_rest ? 1 : 0);
	fs.max_reg = fs.free_reg;
	if (node.flags.class_constructor)
	{
		fs.derived_ctor = node.flags.derived;
		fs.class_has_fields = self.pending_class_fields;
	}
	if (node.flags.field)
	{
		self.field_initializers(node.a, node.flags.is_static)!;
		self.emit_abc(RETUNDEF, 0);
		return self.end_function(&fs, node, name, 0, false);
	}
	// An async call makes its promise first, so even a failing parameter default rejects it. An
	// async generator is a generator (GENSTART below) whose next() makes the promises.
	if (node.flags.is_async && !node.flags.generator) self.emit_abc(ASYNCSTART, 0);
	if (info.self_binding)
	{
		Binding* b = info.self_binding;
		self.alloc_storage(b)!;
		if (b.captured) self.emit_abc(NEWBOX, (uint)b.reg);
		uint t = self.alloc()!;
		self.emit_abc(CURRENTFN, t);
		self.store_binding_value(b, t)!;
		self.release(t);
	}
	uint preg = 1;
	foreach (p : node.list)
	{
		uint reg = p.kind == REST ? 1 + nparams : preg++;
		Node* target = p.kind == REST ? p.a : p;
		if (target.kind == ASSIGN_PATTERN)
		{
			uint skip = self.emit_jump(JMPNOTUNDEF, reg)!;
			self.expr_named(target.b, reg, target.a.kind == IDENT ? target.a.name : "")!;
			self.patch(skip)!;
			target = target.a;
		}
		if (target.kind == IDENT && !((Binding*)target.sema).captured)
		{
			((Binding*)target.sema).reg = (int)reg;
			continue;
		}
		self.pattern_storage(target)!;
		self.assign_pattern(target, reg, true)!;
	}
	// A base class sets up its fields before the constructor body; a derived one after super().
	if (fs.class_has_fields && !fs.derived_ctor) self.run_fields()!;
	if (node.flags.expression_body)
	{
		uint r = self.alloc()!;
		self.expr(node.a, r)!;
		self.emit_abc(RET, r);
	}
	else
	{
		self.enter_scope(info.scope)!;
		if (node.flags.generator)
		{
			// Parameters are set up when the generator is called; the body waits for next().
			uint t = self.alloc()!;
			self.emit_abc(GENSTART, t);
			self.release(t);
		}
		foreach (s : node.a.list) self.stmt(s)!;
		self.emit_abc(RETUNDEF, 0);
	}
	return self.end_function(&fs, node, name, nparams, has_rest);
}

<*
 Compile a module body into an async function with no parameters. Its top-level function
 declarations are compiled as nested protos and listed in `hoisted`, for the linker to create.
*>
fn FunctionProto*? Codegen.compile_module(&self, Node* program, List {HoistedFunction}* hoisted)
{
	FuncInfo* info = program.sema;
	FuncState fs;
	self.begin_function(&fs, info);
	defer (catch err)
	{
		self.fs = fs.parent;
		fs.free_parts();
	}
	fs.free_reg = 1;
	fs.max_reg = 1;
	self.emit_abc(ASYNCSTART, 0);
	foreach (i, b : info.captures)
	{
		if (b.kind != FUNCTION) continue;
		FunctionProto* p = self.compile_function(b.decl, b.name)!;
		fs.protos.push(p);
		hoisted.push({ .proto = (uint)fs.protos.len() - 1, .cell = (uint)i });
	}
	foreach (s : program.list) self.stmt(s)!;
	self.emit_abc(RETUNDEF, 0);
	Node fake = { .kind = FUNCTION, .flags = { .is_async = true } };
	FunctionProto* p = self.end_function(&fs, &fake, "<module>", 0, false);
	p.line = 1;
	return p;
}

<*
 Compile a whole script into its top-level function.
*>
fn FunctionProto*? Codegen.compile_program(&self, Node* program)
{
	FuncInfo* info = program.sema;
	FuncState fs;
	self.begin_function(&fs, info);
	defer (catch err)
	{
		self.fs = fs.parent;
		fs.free_parts();
	}
	fs.free_reg = 1;
	fs.max_reg = 1;
	self.enter_scope(info.scope)!;
	// A script's value is its last expression statement's, what eval hands back:
	// `(async () => { ... })()` gives the host its promise.
	usz n = program.list.len;
	bool ends_in_expression = n > 0 && program.list[n - 1].kind == EXPR_STMT;
	foreach (i, s : program.list)
	{
		if (ends_in_expression && (usz)i == n - 1) break;
		self.stmt(s)!;
	}
	if (ends_in_expression)
	{
		Node* last = program.list[n - 1];
		self.fs.line = last.line;
		uint r = self.alloc()!;
		self.expr(last.a, r)!;
		self.emit_abc(RET, r);
	}
	else
	{
		self.emit_abc(RETUNDEF, 0);
	}
	FunctionProto* p = mem::new(FunctionProto);
	p.name = "<script>".copy(mem);
	p.source_name = self.source_name;
	p.code = copy_list(fs.code);
	p.ics = mem::new_array(IcEntry, p.code.len);
	p.lines = copy_list(fs.lines);
	p.consts = copy_list(fs.consts);
	p.protos = copy_list(fs.protos);
	p.handlers = copy_list(fs.handlers);
	p.site_names = copy_list(fs.site_names);
	fs.site_names.clear();
	p.nregs = fs.max_reg + 1;
	p.line = 1;
	fs.protos.clear();
	fs.free_parts();
	self.fs = null;
	return p;
}

// ---- patterns ----

<*
 Reserve and initialize storage for every binding a declaration pattern introduces.
*>
fn void? Codegen.pattern_storage(&self, Node* p)
{
	switch (p.kind)
	{
		case IDENT:
			Binding* b = p.sema;
			if (b.reg < 0) self.alloc_storage(b)!;
			self.init_storage(b)!;
		case ARRAY_PATTERN:
			foreach (el : p.list)
			{
				if (el.kind != HOLE) self.pattern_storage(el)!;
			}
		case OBJECT_PATTERN:
			foreach (prop : p.list) self.pattern_storage(prop.kind == REST ? prop.a : prop.b)!;
		case ASSIGN_PATTERN:
		case REST:
			self.pattern_storage(p.a)!;
		default:
			break;
	}
}

<*
 Assign the value in src to a pattern. init is true for declarations, false for assignments.
*>
fn void? Codegen.assign_pattern(&self, Node* p, uint src, bool init)
{
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	switch (p.kind)
	{
		case IDENT:
			self.store_binding(p, src, init)!;
		case MEMBER:
			uint obj = self.expr_any(p.a)!;
			if (p.flags.computed)
			{
				uint key = self.expr_any(p.b)!;
				self.emit_abc(SETELEM, obj, key, src);
				return;
			}
			self.set_key(obj, self.atom(p.name)!, src)!;
		case ASSIGN_PATTERN:
			uint t = self.alloc()!;
			self.emit_abc(MOVE, t, src);
			uint skip = self.emit_jump(JMPNOTUNDEF, t)!;
			self.expr_named(p.b, t, p.a.kind == IDENT ? p.a.name : "")!;
			self.patch(skip)!;
			self.assign_pattern(p.a, t, init)!;
		case ARRAY_PATTERN:
			uint base = self.alloc(3)!;
			self.emit_abc(GETITER, base, src);
			foreach (el : p.list)
			{
				switch (el.kind)
				{
					case HOLE:
						self.emit_abc(ITERSTEP, base);
					case REST:
						uint rest = self.alloc()!;
						self.emit_abc(ITERREST, base, rest);
						self.assign_pattern(el.a, rest, init)!;
						self.release(rest);
					default:
						self.emit_abc(ITERSTEP, base);
						self.assign_pattern(el, base + 2, init)!;
				}
			}
			// Stopping before the iterator is done tells it so.
			if (!p.list.len || p.list[^1].kind != REST) self.emit_abc(ITERCLOSE, base);
		case OBJECT_PATTERN:
			if (p.list.len == 0)
			{
				// `{} = x` still requires x to be an object or primitive, not null or undefined.
				uint t = self.alloc()!;
				self.get_key(t, src, self.atom("constructor")!)!;
				return;
			}
			// With a rest element, the keys taken so far are collected so the rest can skip them.
			bool has_rest = p.list[^1].kind == REST;
			uint taken;
			if (has_rest)
			{
				taken = self.alloc()!;
				self.emit_abc(NEWARR, taken, p.list.len > 255 ? 255 : (uint)p.list.len);
			}
			foreach (prop : p.list)
			{
				uint mark = self.fs.free_reg;
				if (prop.kind == REST)
				{
					uint rest = self.alloc()!;
					self.emit_abc(OBJREST, rest, src, taken);
					self.assign_pattern(prop.a, rest, init)!;
					self.release(mark);
					continue;
				}
				uint key = self.alloc()!;
				if (prop.flags.computed)
				{
					self.expr(prop.a, key)!;
				}
				else
				{
					self.load_value(key, self.key_const(prop.a)!)!;
				}
				if (has_rest) self.emit_abc(APPEND, taken, key);
				uint t = self.alloc()!;
				self.emit_abc(GETELEM, t, src, key);
				self.assign_pattern(prop.b, t, init)!;
				self.release(mark);
			}
		default:
			return self.fail(p, "invalid assignment target")~;
	}
}

// ---- expressions ----

<*
 A register holding e's value: a local variable's own register when possible, else a new temp.
 The caller must not write to it.
*>
fn uint? Codegen.expr_any(&self, Node* e)
{
	if (e.kind == IDENT && !e.flags.needs_tdz && self.is_plain_local(e.sema)) return (uint)((Binding*)e.sema).reg;
	uint r = self.alloc()!;
	self.expr(e, r)!;
	return r;
}

fn Op fused_jump(TokenKind k)
{
	switch (k)
	{
		case LT: return JNLT;
		case LE: return JNLE;
		case GT: return JNGT;
		case GE: return JNGE;
		case EQ_STRICT: return JNSEQ;
		case NE_STRICT: return JNSNE;
		default: return NOP;
	}
}

<*
 Emit a jump taken when test is falsy; returns the site to patch. Comparisons become one fused
 compare-and-branch instead of compare, test and jump.
*>
fn uint? Codegen.jump_if_false(&self, Node* test)
{
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	self.fs.line = test.line;
	if (test.kind == BINARY && fused_jump(test.op) != NOP)
	{
		uint b = self.expr_any(test.a)!;
		uint c = self.expr_any(test.b)!;
		self.fs.line = test.line;
		self.emit_abc(fused_jump(test.op), b, c);
		return self.emit_jump(JMP);
	}
	uint t = self.expr_any(test)!;
	return self.emit_jump(JMPF, t);
}

fn Op k_op(TokenKind k)
{
	switch (k)
	{
		case PLUS: case PLUS_ASSIGN: return ADDK;
		case MINUS: case MINUS_ASSIGN: return SUBK;
		case STAR: case STAR_ASSIGN: return MULK;
		case SLASH: case SLASH_ASSIGN: return DIVK;
		default: return NOP;
	}
}

<*
 Emit r[dest] = r[b] op e. A number-literal right side uses a constant operand.
*>
fn void? Codegen.binary_to(&self, TokenKind op, uint dest, uint b, Node* right)
{
	if (right.kind == NUMBER && k_op(op) != NOP)
	{
		uint kidx = self.const_index(rt::number(right.number))!;
		if (kidx <= 255)
		{
			self.emit_abc(k_op(op), dest, b, kidx);
			return;
		}
	}
	uint c = self.expr_any(right)!;
	self.emit_abc(binary_op(op), dest, b, c);
}

<*
 Evaluate e for its side effects only.
*>
fn void? Codegen.expr_discard(&self, Node* e)
{
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	self.fs.line = e.line;
	switch (e.kind)
	{
		case ASSIGN:
			self.assign(e, DISCARD)!;
		case UPDATE:
			self.update(e, DISCARD)!;
		default:
			uint t = self.alloc()!;
			self.expr(e, t)!;
	}
}

fn void? Codegen.expr_named(&self, Node* e, uint dest, String name)
{
	if (e.kind == CLASS && !e.name.len)
	{
		self.fs.line = e.line;
		self.class_expr(e, dest, name)!;
		return;
	}
	if (e.kind == FUNCTION && !e.name.len)
	{
		self.fs.line = e.line;
		self.closure(e, dest, name)!;
		return;
	}
	self.expr(e, dest)!;
}

fn Op binary_op(TokenKind k)
{
	switch (k)
	{
		case PLUS: case PLUS_ASSIGN: return ADD;
		case MINUS: case MINUS_ASSIGN: return SUB;
		case STAR: case STAR_ASSIGN: return MUL;
		case SLASH: case SLASH_ASSIGN: return DIV;
		case PERCENT: case PERCENT_ASSIGN: return MOD;
		case STAR_STAR: case STAR_STAR_ASSIGN: return POW;
		case AMP: case AMP_ASSIGN: return BAND;
		case PIPE: case PIPE_ASSIGN: return BOR;
		case CARET: case CARET_ASSIGN: return BXOR;
		case SHL: case SHL_ASSIGN: return SHL;
		case SAR: case SAR_ASSIGN: return SAR;
		case SHR: case SHR_ASSIGN: return SHR;
		case EQ: return EQ;
		case NE: return NE;
		case EQ_STRICT: return SEQ;
		case NE_STRICT: return SNE;
		case LT: return LT;
		case LE: return LE;
		case GT: return GT;
		case GE: return GE;
		case KW_INSTANCEOF: return INSTANCEOF;
		case KW_IN: return IN;
		default: return NOP;
	}
}

fn void? Codegen.chain_nil(&self, uint reg, Node* at)
{
	if (!self.fs.chain_nils) return self.fail(at, "internal error: '?.' outside an optional chain")~;
	self.fs.chain_nils.push(self.emit_jump(JMPNULLISH, reg)!);
}

fn void? Codegen.expr(&self, Node* e, uint dest)
{
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	self.fs.line = e.line;
	switch (e.kind)
	{
		case NUMBER:
			double d = e.number;
			if (d == math::floor(d) && d >= rt::SBX_MIN && d <= rt::SBX_MAX && !(d == 0 && bitcast(d, ulong) != 0))
			{
				self.emit((uint)rt::encode_asbx(LOADI, dest, (int)d));
			}
			else
			{
				self.emit_abx(LOADK, dest, self.const_index(rt::number(d))!);
			}
		case STRING:
			self.emit_abx(LOADK, dest, self.const_index(self.string_const(e.name, e.flags.escaped, false)!)!);
		case TEMPLATE:
			self.template(e, dest)!;
		case IDENT:
			self.load_binding(e, dest)!;
		case THIS:
			if (dest != 0) self.emit_abc(MOVE, dest, 0);
			if (self.fs.derived_ctor) self.emit_abc(CHECKTHIS, dest);
		case NULL:
			self.emit_abc(LOADNULL, dest);
		case TRUE:
			self.emit_abc(LOADTRUE, dest);
		case FALSE:
			self.emit_abc(LOADFALSE, dest);
		case NEW_TARGET:
			self.emit_abc(NEWTARGET, dest);
		case ARRAY:
			self.emit_abc(NEWARR, dest, e.list.len > 255 ? 255 : (uint)e.list.len);
			foreach (el : e.list)
			{
				uint mark = self.fs.free_reg;
				switch (el.kind)
				{
					case HOLE:
						self.emit_abc(APPENDHOLE, dest);
					case SPREAD:
						uint src = self.expr_any(el.a)!;
						self.name_site(el.a);
						self.emit_abc(APPENDSPREAD, dest, src);
					default:
						self.emit_abc(APPEND, dest, self.expr_any(el)!);
				}
				self.release(mark);
			}
		case OBJECT:
			self.object_literal(e, dest)!;
		case FUNCTION:
			self.closure(e, dest, "")!;
		case UNARY:
			self.unary(e, dest)!;
		case UPDATE:
			self.update(e, dest)!;
		case BINARY:
			uint b = self.expr_any(e.a)!;
			self.fs.line = e.line;
			self.binary_to(e.op, dest, b, e.b)!;
		case LOGICAL:
			self.expr(e.a, dest)!;
			Op jump = e.op == AMP_AMP ? JMPF : e.op == PIPE_PIPE ? JMPT : JMPNOTNULLISH;
			uint end = self.emit_jump(jump, dest)!;
			self.expr(e.b, dest)!;
			self.patch(end)!;
		case ASSIGN:
			self.assign(e, dest)!;
		case CONDITIONAL:
			uint test = self.expr_any(e.a)!;
			uint to_else = self.emit_jump(JMPF, test)!;
			self.expr(e.b, dest)!;
			uint to_end = self.emit_jump(JMP)!;
			self.patch(to_else)!;
			self.expr(e.c, dest)!;
			self.patch(to_end)!;
		case CALL:
			self.call(e, dest)!;
		case NEW:
			self.construct(e, dest)!;
		case MEMBER:
			if (e.a.kind == SUPER)
			{
				if (e.flags.computed)
				{
					self.emit_abc(GETSUPERELEM, dest, self.expr_any(e.b)!);
					break;
				}
				self.emit_abx(GETSUPER, dest, self.atom_const(e.name)!);
				break;
			}
			uint obj = self.expr_any(e.a)!;
			if (e.flags.optional) self.chain_nil(obj, e)!;
			self.fs.line = e.line;
			if (e.flags.computed)
			{
				self.emit_abc(GETELEM, dest, obj, self.expr_any(e.b)!);
			}
			else
			{
				self.get_key(dest, obj, self.atom(e.name)!)!;
			}
		case OPTIONAL_CHAIN:
			List {uint} nils;
			nils.init(mem);
			defer nils.free();
			List {uint}* outer = self.fs.chain_nils;
			self.fs.chain_nils = &nils;
			self.expr(e.a, dest)!;
			self.fs.chain_nils = outer;
			if (nils.len())
			{
				uint to_end = self.emit_jump(JMP)!;
				self.patch_all(&nils, self.pc())!;
				self.emit_abc(LOADUNDEF, dest);
				self.patch(to_end)!;
			}
		case SEQUENCE:
			foreach (i, item : e.list)
			{
				if (i == e.list.len - 1)
				{
					self.expr(item, dest)!;
					break;
				}
				uint t = self.alloc()!;
				self.expr(item, t)!;
				self.release(t);
			}
		case CLASS:
			self.class_expr(e, dest, "")!;
		case REGEX:
			self.regex_literal(e, dest)!;
		case YIELD:
			if (e.flags.delegate)
			{
				self.yield_star(e, dest)!;
			}
			else
			{
				self.yield_expr(e, dest)!;
			}
		case AWAIT:
			uint v = dest == DISCARD ? self.alloc()! : dest;
			self.expr(e.a, v)!;
			self.fs.line = e.line;
			self.emit_abc(AWAIT, v);
		case SUPER:
			return self.fail(e, "'super' keyword unexpected here")~;
		default:
			return self.fail(e, string::bformat(&self.error_buf, "unexpected %s in an expression", e.kind.text))~;
	}
}

const uint MAX_CONCAT = 32;

<*
 A tagged template's first argument: the frozen array of its cooked strings (undefined where an
 escape was invalid), with the frozen array of raw ones as `raw`. Made once per site, as the
 spec wants, and rooted in the VM.
*>
fn Value? Codegen.template_object(&self, Node* e)
{
	Vm* vm = self.vm;
	Heap* h = &vm.heap;
	JsArray* cooked = h.new_array(vm.array_proto, (uint)e.list.len) ?? self.fail(e, "out of memory")~!;
	vm.template_objects.push(rt::object_value(cooked));
	JsArray* raw = h.new_array(vm.array_proto, (uint)e.list.len) ?? self.fail(e, "out of memory")~!;
	foreach (part : e.list)
	{
		cooked.push(part.flags.bad_escape ? rt::UNDEFINED : self.string_const(part.name, part.flags.escaped, true)!);
		raw.push(self.raw_string(part.name)!);
	}
	rt::freeze_array(raw);
	PropFlags hidden = {};
	cooked.add(h, vm.atoms.raw, rt::object_value(raw), hidden) ?? self.fail(e, "out of memory")~!;
	rt::freeze_array(cooked);
	return rt::object_value(cooked);
}

<*
 A template piece's raw text, with its line endings (CR LF, CR) made LF as the spec says.
*>
fn Value? Codegen.raw_string(&self, String text)
{
	Heap* h = &self.vm.heap;
	if (!text.contains("\r")) return rt::string_value(h.intern(h.string_from_utf8(text) ?? self.fail(null, "string too long")~!));
	DString out;
	out.init(mem);
	defer out.free();
	for (usz i = 0; i < text.len; i++)
	{
		if (text[i] != '\r')
		{
			out.append(text[i]);
			continue;
		}
		out.append('\n');
		if (i + 1 < text.len && text[i + 1] == '\n') i++;
	}
	return rt::string_value(h.intern(h.string_from_utf8(out.str_view()) ?? self.fail(null, "string too long")~!));
}

fn void? Codegen.template(&self, Node* e, uint dest)
{
	if (e.flags.tagged)
	{
		self.emit_abx(LOADK, dest, self.const_index(self.template_object(e)!)!);
		return;
	}
	Value first = self.string_const(e.list[0].name, e.list[0].flags.escaped, true)!;
	if (e.list.len == 1)
	{
		self.emit_abx(LOADK, dest, self.const_index(first)!);
		return;
	}
	// Every non-empty piece goes in its own register, as a string, then one CONCATN joins them
	// in a single allocation. A long template joins in chunks, each chunk's result leading the next.
	uint start = self.fs.free_reg;
	uint count = 0;
	if (e.list[0].name.len)
	{
		self.emit_abx(LOADK, self.alloc()!, self.const_index(first)!);
		count++;
	}
	foreach (i, part : e.list[1..])
	{
		bool is_expr = i % 2 == 0;
		if (!is_expr && part.name.len == 0) continue;
		if (count == MAX_CONCAT)
		{
			self.emit_abc(CONCATN, start, start, count);
			self.release(start + 1);
			count = 1;
		}
		uint r = self.alloc()!;
		if (is_expr)
		{
			self.expr(part, r)!;
			self.emit_abc(TOSTRING, r, r);
		}
		else
		{
			self.emit_abx(LOADK, r, self.const_index(self.string_const(part.name, part.flags.escaped, true)!)!);
		}
		self.release(r + 1);
		count++;
	}
	self.emit_abc(CONCATN, dest, start, count);
	self.release(start);
}

fn void? Codegen.object_literal(&self, Node* e, uint dest)
{
	self.emit_abc(NEWOBJ, dest);
	foreach (p : e.list)
	{
		uint mark = self.fs.free_reg;
		self.fs.line = p.line;
		if (p.kind == SPREAD)
		{
			self.emit_abc(COPYPROPS, dest, self.expr_any(p.a)!);
			self.release(mark);
			continue;
		}
		if (p.flags.getter || p.flags.setter)
		{
			uint key = self.alloc()!;
			if (p.flags.computed)
			{
				self.expr(p.a, key)!;
			}
			else
			{
				self.load_value(key, self.key_const(p.a)!)!;
			}
			uint fun = self.alloc()!;
			self.closure(p.b, fun, p.flags.computed ? "" : p.a.name)!;
			// `super` inside it starts at the literal's prototype.
			self.emit_abc(SETHOME, fun, dest);
			self.emit_abc(p.flags.getter ? INITGETTER : INITSETTER, dest, key, fun);
			self.release(mark);
			continue;
		}
		if (p.flags.computed)
		{
			uint key = self.expr_any(p.a)!;
			uint v = self.alloc()!;
			self.expr(p.b, v)!;
			if (p.flags.method) self.emit_abc(SETHOME, v, dest);
			self.emit_abc(INITELEM, dest, key, v);
			self.release(mark);
			continue;
		}
		// `__proto__: value` (not shorthand, not a method) sets the prototype instead.
		if (!p.flags.shorthand && !p.flags.method && p.a.kind != NUMBER && p.a.name == "__proto__")
		{
			uint pv = self.expr_any(p.b)!;
			self.emit_abc(INITPROTO, dest, pv);
			self.release(mark);
			continue;
		}
		Value key = self.key_const(p.a)!;
		uint v = self.alloc()!;
		self.expr_named(p.b, v, key.is_string() ? key.as_string().tutf8() : "")!;
		if (p.flags.method) self.emit_abc(SETHOME, v, dest);
		uint k = self.const_index(key)!;
		if (k <= 255)
		{
			self.emit_abc(INITPROP, dest, k, v);
		}
		else
		{
			uint kr = self.alloc()!;
			self.emit_abx(LOADK, kr, k);
			self.emit_abc(INITELEM, dest, kr, v);
		}
		self.release(mark);
	}
}

fn void? Codegen.unary(&self, Node* e, uint dest)
{
	switch (e.op)
	{
		case KW_TYPEOF:
			if (e.a.kind == IDENT && !e.a.sema)
			{
				self.emit_abx(TYPEOFGLOBAL, dest, self.atom_const(e.a.name)!);
				return;
			}
			self.emit_abc(TYPEOF, dest, self.expr_any(e.a)!);
		case KW_DELETE:
			Node* t = e.a;
			if (t.kind == OPTIONAL_CHAIN) return self.unsupported(t, "'delete' on optional chains")~;
			if (t.kind == IDENT) return self.fail(t, "delete of an unqualified identifier is not allowed")~;
			if (t.kind != MEMBER)
			{
				uint discard = self.alloc()!;
				self.expr(t, discard)!;
				self.emit_abc(LOADTRUE, dest);
				return;
			}
			uint obj = self.expr_any(t.a)!;
			if (t.flags.computed)
			{
				self.emit_abc(DELELEM, dest, obj, self.expr_any(t.b)!);
				return;
			}
			uint k = self.const_index(self.atom(t.name)!)!;
			if (k <= 255)
			{
				self.emit_abc(DELPROP, dest, obj, k);
				return;
			}
			uint kr = self.alloc()!;
			self.emit_abx(LOADK, kr, k);
			self.emit_abc(DELELEM, dest, obj, kr);
		case KW_VOID:
			uint discard = self.alloc()!;
			self.expr(e.a, discard)!;
			self.emit_abc(LOADUNDEF, dest);
		default:
			Op op;
			switch (e.op)
			{
				case MINUS: op = NEG;
				case PLUS: op = POS;
				case BANG: op = NOT;
				default: op = BNOT;
			}
			self.emit_abc(op, dest, self.expr_any(e.a)!);
	}
}

fn void? Codegen.update(&self, Node* e, uint dest)
{
	Op op = e.op == PLUS_PLUS ? INC : DEC;
	Node* t = e.a;
	if (t.kind == IDENT && self.is_plain_local(t.sema) && ((Binding*)t.sema).kind != CONST)
	{
		uint reg = (uint)((Binding*)t.sema).reg;
		if (t.flags.needs_tdz) self.emit_abx(CHECKTDZ, reg, self.atom_const(t.name)!);
		if (dest == DISCARD || e.flags.prefix)
		{
			self.emit_abc(op, reg, reg);
			if (dest != DISCARD && dest != reg) self.emit_abc(MOVE, dest, reg);
			return;
		}
		self.emit_abc(TONUMERIC, dest, reg);
		self.emit_abc(op, reg, dest);
		return;
	}
	uint cur = self.alloc()!;
	uint obj;
	uint key;
	Value const_key;
	if (t.kind == IDENT)
	{
		self.load_binding(t, cur)!;
	}
	else
	{
		obj = self.expr_any(t.a)!;
		if (t.flags.computed)
		{
			key = self.expr_any(t.b)!;
			self.emit_abc(GETELEM, cur, obj, key);
		}
		else
		{
			const_key = self.atom(t.name)!;
			self.get_key(cur, obj, const_key)!;
		}
	}
	uint result = cur;
	if (e.flags.prefix || dest == DISCARD)
	{
		self.emit_abc(op, cur, cur);
	}
	else
	{
		uint old = self.alloc()!;
		self.emit_abc(TONUMERIC, old, cur);
		self.emit_abc(op, cur, old);
		result = old;
	}
	if (t.kind == IDENT)
	{
		self.store_binding(t, cur, false)!;
	}
	else if (t.flags.computed)
	{
		self.emit_abc(SETELEM, obj, key, cur);
	}
	else
	{
		self.set_key(obj, const_key, cur)!;
	}
	if (dest != DISCARD && dest != result) self.emit_abc(MOVE, dest, result);
}

fn void? Codegen.assign(&self, Node* e, uint dest)
{
	Node* t = e.a;
	if (t.kind == MEMBER && t.a.kind == SUPER) return self.assign_super(e, dest);
	bool logical = e.op == AMP_AMP_ASSIGN || e.op == PIPE_PIPE_ASSIGN || e.op == QUESTION_QUESTION_ASSIGN;
	if (t.kind == IDENT && self.is_plain_local(t.sema) && ((Binding*)t.sema).kind != CONST && !logical)
	{
		uint reg = (uint)((Binding*)t.sema).reg;
		if (e.op == ASSIGN)
		{
			// Evaluate into a temp first: the right side may read the old value.
			uint v = self.alloc()!;
			self.expr_named(e.b, v, t.name)!;
			if (t.flags.needs_tdz) self.emit_abx(CHECKTDZ, reg, self.atom_const(t.name)!);
			self.emit_abc(MOVE, reg, v);
		}
		else
		{
			if (t.flags.needs_tdz) self.emit_abx(CHECKTDZ, reg, self.atom_const(t.name)!);
			self.fs.line = e.line;
			self.binary_to(e.op, reg, reg, e.b)!;
		}
		if (dest != DISCARD && dest != reg) self.emit_abc(MOVE, dest, reg);
		return;
	}
	if (e.op == ASSIGN)
	{
		if (t.kind == MEMBER)
		{
			uint obj = self.expr_any(t.a)!;
			uint key;
			if (t.flags.computed) key = self.expr_any(t.b)!;
			uint v = self.alloc()!;
			self.expr(e.b, v)!;
			self.fs.line = e.line;
			if (t.flags.computed)
			{
				self.emit_abc(SETELEM, obj, key, v);
			}
			else
			{
				self.set_key(obj, self.atom(t.name)!, v)!;
			}
			if (dest != DISCARD && dest != v) self.emit_abc(MOVE, dest, v);
			return;
		}
		uint v = self.alloc()!;
		self.expr_named(e.b, v, t.kind == IDENT ? t.name : "")!;
		self.assign_pattern(t, v, false)!;
		if (dest != DISCARD && dest != v) self.emit_abc(MOVE, dest, v);
		return;
	}
	// Compound and logical assignment: read, combine, write back.
	uint cur = self.alloc()!;
	uint obj;
	uint key;
	Value const_key;
	if (t.kind == IDENT)
	{
		self.load_binding(t, cur)!;
	}
	else
	{
		obj = self.expr_any(t.a)!;
		if (t.flags.computed)
		{
			key = self.expr_any(t.b)!;
			self.emit_abc(GETELEM, cur, obj, key);
		}
		else
		{
			const_key = self.atom(t.name)!;
			self.get_key(cur, obj, const_key)!;
		}
	}
	uint skip;
	if (logical)
	{
		Op jump = e.op == AMP_AMP_ASSIGN ? JMPF : e.op == PIPE_PIPE_ASSIGN ? JMPT : JMPNOTNULLISH;
		skip = self.emit_jump(jump, cur)!;
		self.expr_named(e.b, cur, t.kind == IDENT ? t.name : "")!;
	}
	else
	{
		self.fs.line = e.line;
		self.binary_to(e.op, cur, cur, e.b)!;
	}
	if (t.kind == IDENT)
	{
		self.store_binding(t, cur, false)!;
	}
	else if (t.flags.computed)
	{
		self.emit_abc(SETELEM, obj, key, cur);
	}
	else
	{
		self.set_key(obj, const_key, cur)!;
	}
	if (logical) self.patch(skip)!;
	if (dest != DISCARD && dest != cur) self.emit_abc(MOVE, dest, cur);
}

<*
 `super.x = v`, `super[k] op= v`: through SETSUPERELEM, the key in a register.
*>
fn void? Codegen.assign_super(&self, Node* e, uint dest)
{
	Node* t = e.a;
	bool logical = e.op == AMP_AMP_ASSIGN || e.op == PIPE_PIPE_ASSIGN || e.op == QUESTION_QUESTION_ASSIGN;
	uint key = self.alloc()!;
	if (t.flags.computed)
	{
		self.expr(t.b, key)!;
	}
	else
	{
		self.load_value(key, self.atom(t.name)!)!;
	}
	uint cur = self.alloc()!;
	uint skip;
	if (e.op == ASSIGN)
	{
		self.expr(e.b, cur)!;
	}
	else
	{
		self.emit_abc(GETSUPERELEM, cur, key);
		if (logical)
		{
			Op jump = e.op == AMP_AMP_ASSIGN ? JMPF : e.op == PIPE_PIPE_ASSIGN ? JMPT : JMPNOTNULLISH;
			skip = self.emit_jump(jump, cur)!;
			self.expr(e.b, cur)!;
		}
		else
		{
			self.fs.line = e.line;
			self.binary_to(e.op, cur, cur, e.b)!;
		}
	}
	self.fs.line = e.line;
	self.emit_abc(SETSUPERELEM, key, cur);
	if (logical) self.patch(skip)!;
	if (dest != DISCARD && dest != cur) self.emit_abc(MOVE, dest, cur);
}

fn bool has_spread(Node*[] args)
{
	foreach (a : args)
	{
		if (a.kind == SPREAD) return true;
	}
	return false;
}

<*
 Arguments into consecutive registers from base + 2, or one array there when any is spread.

 @return "The argument count, or -1 for a spread call"
*>
fn int? Codegen.arguments(&self, Node*[] args, uint base)
{
	if (has_spread(args))
	{
		uint arr = self.alloc()!;
		self.emit_abc(NEWARR, arr, args.len > 255 ? 255 : (uint)args.len);
		foreach (a : args)
		{
			uint mark = self.fs.free_reg;
			if (a.kind == SPREAD)
			{
				uint src = self.expr_any(a.a)!;
				self.name_spread_argument();
				self.emit_abc(APPENDSPREAD, arr, src);
			}
			else
			{
				self.emit_abc(APPEND, arr, self.expr_any(a)!);
			}
			self.release(mark);
		}
		return -1;
	}
	if (args.len > 200) return self.fail(args[0], "too many arguments")~;
	foreach (a : args)
	{
		uint r = self.alloc()!;
		self.expr(a, r)!;
		self.release(r + 1);
	}
	return (int)args.len;
}

fn void? Codegen.call(&self, Node* e, uint dest)
{
	Node* callee = e.a;
	uint base = self.alloc(2)!;
	if (callee.kind == MEMBER && callee.a.kind == SUPER)
	{
		self.emit_abc(MOVE, base + 1, 0);
		if (callee.flags.computed)
		{
			self.emit_abc(GETSUPERELEM, base, self.expr_any(callee.b)!);
			self.release(base + 2);
		}
		else
		{
			self.emit_abx(GETSUPER, base, self.atom_const(callee.name)!);
		}
	}
	else if (callee.kind == MEMBER)
	{
		self.expr(callee.a, base + 1)!;
		if (callee.flags.optional) self.chain_nil(base + 1, callee)!;
		self.fs.line = callee.line;
		if (callee.flags.computed)
		{
			uint key = self.expr_any(callee.b)!;
			self.emit_abc(GETELEM, base, base + 1, key);
			self.release(base + 2);
		}
		else
		{
			self.get_key(base, base + 1, self.atom(callee.name)!)!;
		}
	}
	else if (callee.kind == SUPER)
	{
		if (!self.fs.derived_ctor) return self.fail(callee, "'super' calls are only valid in a derived class constructor")~;
		int argc = self.arguments(e.list, base)!;
		self.fs.line = e.line;
		if (argc < 0)
		{
			self.emit_abc(SUPERCALLSPREAD, base);
		}
		else
		{
			self.emit_abc(SUPERCALL, base, (uint)argc);
		}
		self.emit_abc(SETTHIS, base);
		if (self.fs.class_has_fields) self.run_fields()!;
		if (dest != base) self.emit_abc(MOVE, dest, base);
		self.release(base);
		return;
	}
	else
	{
		self.expr(callee, base)!;
		self.emit_abc(LOADUNDEF, base + 1);
	}
	if (e.flags.optional) self.chain_nil(base, e)!;
	int argc = self.arguments(e.list, base)!;
	self.fs.line = e.line;
	self.name_site(callee);
	if (argc < 0)
	{
		self.emit_abc(CALLSPREAD, base);
	}
	else
	{
		self.emit_abc(CALL, base, (uint)argc);
	}
	if (dest != base) self.emit_abc(MOVE, dest, base);
	self.release(base);
}

fn void? Codegen.construct(&self, Node* e, uint dest)
{
	uint base = self.alloc(2)!;
	self.expr(e.a, base)!;
	int argc = self.arguments(e.list, base)!;
	self.fs.line = e.line;
	self.name_site(e.a);
	if (argc < 0)
	{
		self.emit_abc(NEWSPREAD, base);
	}
	else
	{
		self.emit_abc(NEW, base, (uint)argc);
	}
	if (dest != base) self.emit_abc(MOVE, dest, base);
	self.release(base);
}

// ---- generators ----

<*
 `yield v`: suspend with v. A return() sent in comes back as mode 2 and returns from here,
 running any finally blocks; a throw() is thrown at the yield by the VM.
*>
fn void? Codegen.yield_expr(&self, Node* e, uint dest)
{
	uint saved = self.fs.free_reg;
	uint v = self.alloc()!;
	uint mode = self.alloc()!;
	if (e.a)
	{
		self.expr(e.a, v)!;
	}
	else
	{
		self.emit_abc(LOADUNDEF, v);
	}
	self.fs.line = e.line;
	// An async generator yields what its operand resolves to.
	if (self.in_async_generator()) self.emit_abc(AWAIT, v);
	self.emit_abc(YIELD, v, mode, 0);
	uint resumed = self.emit_jump(JMPF, mode)!;
	// return(v) on an async generator awaits v, where it would have resumed.
	if (self.in_async_generator()) self.emit_abc(AWAIT, v);
	self.return_out(self.fs.jumps, v)!;
	self.patch(resumed)!;
	if (dest != DISCARD) self.emit_abc(MOVE, dest, v);
	self.release(saved);
}

<*
 `yield* iterable`: forward next/throw/return to an inner iterator until it is done. The four
 registers are [iterator, next, value, mode], as YSTEP expects.
*>
fn bool Codegen.in_async_generator(&self) @inline => self.fs.info.node.flags.is_async && self.fs.info.node.flags.generator;

fn void? Codegen.yield_star(&self, Node* e, uint dest)
{
	if (self.in_async_generator()) return self.yield_star_async(e, dest);
	uint saved = self.fs.free_reg;
	uint base = self.alloc(4)!;
	self.expr(e.a, base + 2)!;
	self.fs.line = e.line;
	self.name_site(e.a);
	self.emit_abc(GETITER, base, base + 2, 1);
	self.emit_abc(LOADUNDEF, base + 2);
	self.emit((uint)rt::encode_asbx(LOADI, base + 3, 0));
	uint top = self.pc();
	uint done = self.emit_jump(YSTEP, base)!;
	self.emit_abc(YIELD, base + 2, base + 3, 1);
	self.jump_back(JMP, 0, top)!;
	self.patch(done)!;
	uint finished = self.emit_jump(JMPF, base + 3)!;
	self.return_out(self.fs.jumps, base + 2)!;
	self.patch(finished)!;
	if (dest != DISCARD) self.emit_abc(MOVE, dest, base + 2);
	self.release(saved);
}

<*
 `yield*` in an async generator: like yield_star, over an async iterator, with each result of
 the inner iterator awaited between sending (YSEND) and unpacking it (YRESULT). The value
 returned through it is awaited too.
*>
fn void? Codegen.yield_star_async(&self, Node* e, uint dest)
{
	uint saved = self.fs.free_reg;
	uint base = self.alloc(4)!;
	self.expr(e.a, base + 2)!;
	self.fs.line = e.line;
	self.name_site(e.a);
	self.emit_abc(GETASYNCITER, base, base + 2);
	self.emit_abc(LOADUNDEF, base + 2);
	self.emit((uint)rt::encode_asbx(LOADI, base + 3, 0));
	uint top = self.pc();
	uint no_return = self.emit_jump(YSEND, base)!;
	self.emit_abc(AWAIT, base + 2);
	uint done = self.emit_jump(YRESULT, base)!;
	self.emit_abc(YIELD, base + 2, base + 3, 1);
	self.jump_back(JMP, 0, top)!;
	self.patch(no_return)!;
	self.patch(done)!;
	uint finished = self.emit_jump(JMPF, base + 3)!;
	self.emit_abc(AWAIT, base + 2);
	self.return_out(self.fs.jumps, base + 2)!;
	self.patch(finished)!;
	if (dest != DISCARD) self.emit_abc(MOVE, dest, base + 2);
	self.release(saved);
}

// ---- statements ----

fn JumpCtx* Codegen.push_jump(&self, JumpKind kind)
{
	JumpCtx* c = alloc::new(self.arena, JumpCtx);
	c.kind = kind;
	c.outer = self.fs.jumps;
	c.breaks.init(self.arena);
	c.continues.init(self.arena);
	c.entries.init(self.arena);
	c.exits.init(self.arena);
	c.next_code = 3;
	if (kind == LOOP)
	{
		c.labels = self.fs.pending_labels;
		self.fs.pending_labels = null;
	}
	self.fs.jumps = c;
	return c;
}

<*
 Jump from the current position to a loop or switch context, running any finally blocks in between.
*>
fn void? Codegen.jump_out(&self, JumpCtx* from, JumpCtx* target, bool is_break)
{
	for (JumpCtx* c = from; c != target; c = c.outer)
	{
		// A labelled jump can leave inner loops: their iterators are closed on the way out.
		if (c.closes_iterator) self.close_iterator(c)!;
		if (c.kind != FINALLY) continue;
		uint code = c.next_code++;
		c.exits.push({ .code = code, .is_break = is_break, .target = target });
		self.emit((uint)rt::encode_asbx(LOADI, c.ctype, (int)code));
		c.entries.push(self.emit_jump(JMP)!);
		return;
	}
	uint j = self.emit_jump(JMP)!;
	if (is_break)
	{
		target.breaks.push(j);
	}
	else
	{
		target.continues.push(j);
	}
}

<*
 Return the value in reg, running any finally blocks between here and the function's end.
*>
fn void? Codegen.return_out(&self, JumpCtx* from, uint reg)
{
	for (JumpCtx* c = from; c; c = c.outer)
	{
		if (c.closes_iterator) self.close_iterator(c)!;
		if (c.kind != FINALLY) continue;
		if (reg != c.cval) self.emit_abc(MOVE, c.cval, reg);
		self.emit((uint)rt::encode_asbx(LOADI, c.ctype, 2));
		c.entries.push(self.emit_jump(JMP)!);
		c.has_return = true;
		return;
	}
	self.emit_abc(RET, reg);
}

<*
 Leave loop c's iteration early: call return(), and for a for await, await what it gives and
 check that it is an object.
*>
fn void? Codegen.close_iterator(&self, JumpCtx* c)
{
	if (!c.async_close)
	{
		self.emit_abc(ITERCLOSE, c.iter_reg);
		return;
	}
	uint saved = self.fs.free_reg;
	uint t = self.alloc()!;
	self.emit_abc(ASYNCCLOSE, c.iter_reg, t, 0);
	self.emit_abc(AWAIT, t);
	self.emit_abc(ASYNCCLOSE, c.iter_reg, t, 2);
	self.release(saved);
}

fn bool JumpCtx.has_label(&self, String name)
{
	for (Node* l = self.labels; l && l.kind == LABELED; l = l.a)
	{
		if (l.name == name) return true;
	}
	return false;
}

fn void? Codegen.stmt_break(&self, Node* n)
{
	bool is_break = n.kind == BREAK;
	if (n.name.len)
	{
		for (JumpCtx* c = self.fs.jumps; c; c = c.outer)
		{
			if (!c.has_label(n.name)) continue;
			if (!is_break && c.kind != LOOP)
			{
				return self.fail(n, string::bformat(&self.error_buf, "Illegal continue statement: '%s' does not denote an iteration statement", n.name))~;
			}
			self.jump_out(self.fs.jumps, c, is_break)!;
			return;
		}
		return self.fail(n, string::bformat(&self.error_buf, "Undefined label '%s'", n.name))~;
	}
	for (JumpCtx* c = self.fs.jumps; c; c = c.outer)
	{
		if (c.kind == LOOP || (is_break && c.kind == SWITCH))
		{
			self.jump_out(self.fs.jumps, c, is_break)!;
			return;
		}
	}
	return self.fail(n, is_break ? "'break' outside of a loop or switch" : "'continue' outside of a loop")~;
}

<*
 `a: b: statement`. A loop takes its labels into its own LOOP context, so `continue a` works;
 any other statement gets a LABEL context that `break a` leaves.
*>
fn void? Codegen.stmt_labeled(&self, Node* n)
{
	Node* body = n;
	while (body.kind == LABELED)
	{
		for (JumpCtx* c = self.fs.jumps; c; c = c.outer)
		{
			if (c.has_label(body.name)) return self.fail(body, string::bformat(&self.error_buf, "Label '%s' has already been declared", body.name))~;
		}
		for (Node* l = n; l != body; l = l.a)
		{
			if (l.name == body.name) return self.fail(body, string::bformat(&self.error_buf, "Label '%s' has already been declared", body.name))~;
		}
		body = body.a;
	}
	switch (body.kind)
	{
		case WHILE:
		case FOR:
		case FOR_OF:
		case FOR_IN:
			self.fs.pending_labels = n;
			self.stmt(body)!;
		default:
			JumpCtx* c = self.push_jump(LABEL);
			c.labels = n;
			self.stmt(body)!;
			self.fs.jumps = c.outer;
			self.patch_all(&c.breaks, self.pc())!;
	}
}

fn void? Codegen.block(&self, Node* n)
{
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	self.enter_scope(n.sema)!;
	foreach (s : n.list) self.stmt(s)!;
}

fn void? Codegen.stmt(&self, Node* n)
{
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	self.fs.line = n.line;
	switch (n.kind)
	{
		case EXPR_STMT:
			self.expr_discard(n.a)!;
		case VAR_DECL:
			foreach (d : n.list)
			{
				self.fs.line = d.line;
				Node* target = d.a;
				if (target.kind == IDENT && self.is_plain_local(target.sema))
				{
					uint reg = (uint)((Binding*)target.sema).reg;
					if (d.b)
					{
						self.expr_named(d.b, reg, target.name)!;
					}
					else
					{
						self.emit_abc(LOADUNDEF, reg);
					}
					continue;
				}
				uint v = self.alloc()!;
				if (d.b)
				{
					self.expr_named(d.b, v, target.kind == IDENT ? target.name : "")!;
				}
				else
				{
					self.emit_abc(LOADUNDEF, v);
				}
				self.assign_pattern(target, v, true)!;
				self.release(v);
			}
		case FUNCTION:
			// Hoisted: created when its scope was entered.
			break;
		case CLASS:
			uint t = self.alloc()!;
			self.class_expr(n, t, "")!;
			self.store_binding(n.d, t, true)!;
		case BLOCK:
			self.block(n)!;
		case EMPTY:
			break;
		case IF:
			uint to_else = self.jump_if_false(n.a)!;
			self.stmt(n.b)!;
			if (n.c)
			{
				uint to_end = self.emit_jump(JMP)!;
				self.patch(to_else)!;
				self.stmt(n.c)!;
				self.patch(to_end)!;
			}
			else
			{
				self.patch(to_else)!;
			}
		case WHILE:
			uint top = self.pc();
			uint exit = self.jump_if_false(n.a)!;
			JumpCtx* loop = self.push_jump(LOOP);
			self.stmt(n.d)!;
			self.fs.jumps = loop.outer;
			self.patch_all(&loop.continues, top)!;
			self.jump_back(JMP, 0, top)!;
			self.patch(exit)!;
			self.patch_all(&loop.breaks, self.pc())!;
		case FOR:
			self.stmt_for(n)!;
		case FOR_OF:
		case FOR_IN:
			self.stmt_for_of(n)!;
		case RETURN:
			uint v;
			if (n.a)
			{
				v = self.expr_any(n.a)!;
			}
			else
			{
				v = self.alloc()!;
				self.emit_abc(LOADUNDEF, v);
			}
			self.fs.line = n.line;
			if (self.in_async_generator())
			{
				// AWAIT writes its result back, and v may be a variable.
				uint t = self.alloc()!;
				self.emit_abc(MOVE, t, v);
				self.emit_abc(AWAIT, t);
				v = t;
			}
			self.return_out(self.fs.jumps, v)!;
		case BREAK:
		case CONTINUE:
			self.stmt_break(n)!;
		case LABELED:
			self.stmt_labeled(n)!;
		case THROW:
			uint v = self.expr_any(n.a)!;
			self.fs.line = n.line;
			self.emit_abc(THROW, v);
		case TRY:
			self.stmt_try(n)!;
		case SWITCH:
			self.stmt_switch(n)!;
		case IMPORT:
			// Bound when the module was linked.
			break;
		case EXPORT:
			if (n.a) self.stmt(n.a)!;
		case EXPORT_DEFAULT:
			Node* d = n.a;
			if (d.flags.declaration)
			{
				// A function is hoisted; a class is a declaration like any other.
				if (d.kind == CLASS) self.stmt(d)!;
				break;
			}
			uint t = self.alloc()!;
			self.expr_named(d, t, "default")!;
			self.store_binding_value(n.sema, t)!;
		default:
			return self.fail(n, string::bformat(&self.error_buf, "unexpected %s in a statement", n.kind.text))~;
	}
}

fn void? Codegen.stmt_for(&self, Node* n)
{
	Scope* scope = n.sema;
	self.enter_scope(scope)!;
	if (n.a)
	{
		if (n.a.kind == VAR_DECL)
		{
			self.stmt(n.a)!;
		}
		else
		{
			uint t = self.alloc()!;
			self.expr(n.a, t)!;
			self.release(t);
		}
	}
	uint top = self.pc();
	uint exit;
	bool has_test = n.b != null;
	if (has_test) exit = self.jump_if_false(n.b)!;
	JumpCtx* loop = self.push_jump(LOOP);
	self.stmt(n.d)!;
	self.fs.jumps = loop.outer;
	self.patch_all(&loop.continues, self.pc())!;
	// Captured loop variables get a fresh box per iteration, so each closure sees its own value.
	foreach (b : scope.bindings)
	{
		if (!b.captured || b.is_slot) continue;
		uint t = self.alloc()!;
		self.emit_abc(GETBOX, t, (uint)b.reg);
		self.emit_abc(NEWBOX, (uint)b.reg);
		self.emit_abc(INITBOX, t, (uint)b.reg);
		self.release(t);
	}
	if (n.c) self.expr_discard(n.c)!;
	self.jump_back(JMP, 0, top)!;
	if (has_test) self.patch(exit)!;
	self.patch_all(&loop.breaks, self.pc())!;
}

<*
 `for await (x of src)`: call next(), await the result, stop when it is done. A sync iterable
 is stepped through a wrapper that awaits each value (async_iterator_of).
*>
fn void? Codegen.stmt_for_await(&self, Node* n)
{
	Scope* scope = n.sema;
	foreach (b : scope.bindings) self.alloc_storage(b)!;
	foreach (b : scope.bindings) self.init_storage(b)!;
	// base: the iterator, base + 1: its next, base + 2 and up: the call, then value and done.
	uint base = self.alloc(3)!;
	uint src = self.expr_any(n.b)!;
	self.fs.line = n.line;
	self.name_site(n.b);
	self.emit_abc(GETASYNCITER, base, src);
	self.release(base + 2);
	uint call = self.alloc(2)!;
	uint top = self.pc();
	self.emit_abc(MOVE, call, base + 1);
	self.emit_abc(MOVE, call + 1, base);
	self.emit_abc(CALL, call, 0);
	self.emit_abc(AWAIT, call);
	self.emit_abc(ITERRESULT, call);
	uint exit = self.emit_jump(JMPT, call + 1)!;
	if (n.a.kind == VAR_DECL)
	{
		foreach (b : scope.bindings)
		{
			if (b.captured) self.init_storage(b)!;
		}
		self.assign_pattern(n.a.list[0].a, call, true)!;
	}
	else
	{
		self.assign_pattern(n.a, call, false)!;
	}
	JumpCtx* loop = self.push_jump(LOOP);
	loop.closes_iterator = true;
	loop.async_close = true;
	loop.iter_reg = base;
	self.stmt(n.d)!;
	uint body_end = self.pc();
	self.fs.jumps = loop.outer;
	self.patch_all(&loop.continues, top)!;
	self.jump_back(JMP, 0, top)!;
	if (loop.breaks.len())
	{
		self.patch_all(&loop.breaks, self.pc())!;
		self.close_iterator(loop)!;
	}
	self.patch(exit)!;
	// A throw from the binding or the body closes the iterator too (see stmt_for_of), and
	// still awaits return()'s promise. The exception wins over a rejection of that promise.
	uint over = self.emit_jump(JMP)!;
	self.fs.handlers.push({ .start = exit + 1, .end = body_end, .handler = self.pc(), .reg = call });
	self.emit_abc(ASYNCCLOSE, base, call + 1, 1);
	uint wait = self.pc();
	self.emit_abc(AWAIT, call + 1);
	self.fs.handlers.push({ .start = wait, .end = wait + 1, .handler = self.pc(), .reg = call + 1 });
	self.emit_abc(THROW, call);
	self.patch(over)!;
}

fn void? Codegen.stmt_for_of(&self, Node* n)
{
	if (n.flags.is_async) return self.stmt_for_await(n);
	Scope* scope = n.sema;
	foreach (b : scope.bindings) self.alloc_storage(b)!;
	foreach (b : scope.bindings) self.init_storage(b)!;
	uint base = self.alloc(3)!;
	uint src = self.expr_any(n.b)!;
	self.fs.line = n.line;
	if (n.kind == FOR_OF)
	{
		self.name_site(n.b);
		self.emit_abc(GETITER, base, src);
	}
	else
	{
		self.emit_abc(FORINKEYS, base, src);
	}
	self.release(base + 3);
	uint top = self.pc();
	uint exit = self.emit_jump(FORNEXT, base)!;
	if (n.a.kind == VAR_DECL)
	{
		foreach (b : scope.bindings)
		{
			if (b.captured) self.init_storage(b)!;
		}
		self.assign_pattern(n.a.list[0].a, base + 2, true)!;
	}
	else
	{
		self.assign_pattern(n.a, base + 2, false)!;
	}
	JumpCtx* loop = self.push_jump(LOOP);
	loop.closes_iterator = n.kind == FOR_OF;
	loop.iter_reg = base;
	self.stmt(n.d)!;
	uint body_end = self.pc();
	self.fs.jumps = loop.outer;
	self.patch_all(&loop.continues, top)!;
	self.jump_back(JMP, 0, top)!;
	if (loop.closes_iterator && loop.breaks.len())
	{
		// A break closes the iterator; running out of values doesn't.
		self.patch_all(&loop.breaks, self.pc())!;
		self.emit_abc(ITERCLOSE, base);
		self.patch(exit)!;
	}
	else
	{
		self.patch(exit)!;
		self.patch_all(&loop.breaks, self.pc())!;
	}
	if (n.kind != FOR_OF) return;
	// So does a throw from the binding or the body, though not one from next() itself, which
	// is the FORNEXT just before the range. The value register is dead then and takes the
	// exception.
	uint over = self.emit_jump(JMP)!;
	self.fs.handlers.push({ .start = top + 1, .end = body_end, .handler = self.pc(), .reg = base + 2 });
	self.emit_abc(ITERCLOSE, base, 0, 1);
	self.emit_abc(THROW, base + 2);
	self.patch(over)!;
}

fn void? Codegen.try_catch(&self, Node* n)
{
	uint reg = self.alloc()!;
	uint start = self.pc();
	self.stmt(n.a)!;
	uint end = self.pc();
	uint to_end = self.emit_jump(JMP)!;
	self.fs.handlers.push({ .start = start, .end = end, .handler = self.pc(), .reg = reg });
	uint mark = self.fs.free_reg;
	self.enter_scope(n.sema)!;
	if (n.b) self.assign_pattern(n.b, reg, true)!;
	self.stmt(n.c)!;
	self.release(mark);
	self.patch(to_end)!;
}

fn void? Codegen.stmt_try(&self, Node* n)
{
	if (!n.d)
	{
		self.try_catch(n)!;
		return;
	}
	JumpCtx* fin = self.push_jump(FINALLY);
	fin.ctype = self.alloc()!;
	fin.cval = self.alloc()!;
	uint start = self.pc();
	if (n.c)
	{
		self.try_catch(n)!;
	}
	else
	{
		self.stmt(n.a)!;
	}
	uint end = self.pc();
	self.emit((uint)rt::encode_asbx(LOADI, fin.ctype, 0));
	uint to_finally = self.emit_jump(JMP)!;
	self.fs.handlers.push({ .start = start, .end = end, .handler = self.pc(), .reg = fin.cval });
	self.emit((uint)rt::encode_asbx(LOADI, fin.ctype, 1));
	self.patch(to_finally)!;
	self.patch_all(&fin.entries, self.pc())!;
	self.fs.jumps = fin.outer;
	self.stmt(n.d)!;
	// Finish whatever was interrupted: rethrow, return, or the pending break/continue.
	uint t = self.alloc()!;
	self.emit((uint)rt::encode_asbx(LOADI, t, 1));
	self.emit_abc(SEQ, t, fin.ctype, t);
	uint not_throw = self.emit_jump(JMPF, t)!;
	self.emit_abc(THROW, fin.cval);
	self.patch(not_throw)!;
	if (fin.has_return)
	{
		self.emit((uint)rt::encode_asbx(LOADI, t, 2));
		self.emit_abc(SEQ, t, fin.ctype, t);
		uint skip = self.emit_jump(JMPF, t)!;
		self.return_out(fin.outer, fin.cval)!;
		self.patch(skip)!;
	}
	foreach (exit : fin.exits)
	{
		self.emit((uint)rt::encode_asbx(LOADI, t, (int)exit.code));
		self.emit_abc(SEQ, t, fin.ctype, t);
		uint skip = self.emit_jump(JMPF, t)!;
		self.jump_out(fin.outer, exit.target, exit.is_break)!;
		self.patch(skip)!;
	}
}

fn void? Codegen.stmt_switch(&self, Node* n)
{
	uint d = self.alloc()!;
	self.expr(n.a, d)!;
	self.enter_scope(n.sema)!;
	List {uint} to_case;
	to_case.init(mem);
	defer to_case.free();
	foreach (c : n.list)
	{
		if (!c.a)
		{
			to_case.push(0);
			continue;
		}
		uint t = self.alloc()!;
		self.expr(c.a, t)!;
		self.emit_abc(SEQ, t, d, t);
		to_case.push(self.emit_jump(JMPT, t)!);
		self.release(t);
	}
	uint to_default = self.emit_jump(JMP)!;
	bool has_default = false;
	JumpCtx* sw = self.push_jump(SWITCH);
	foreach (i, c : n.list)
	{
		if (c.a)
		{
			self.patch(to_case[i])!;
		}
		else
		{
			self.patch(to_default)!;
			has_default = true;
		}
		foreach (s : c.list) self.stmt(s)!;
	}
	self.fs.jumps = sw.outer;
	if (!has_default) self.patch(to_default)!;
	self.patch_all(&sw.breaks, self.pc())!;
}

// ---- regex literals ----

fn void? Codegen.regex_literal(&self, Node* e, uint dest)
{
	String text = e.name;
	usz slash = text.len - 1;
	while (text[slash] != '/') slash--;
	String pattern = text[1:slash - 1];
	String flags = text[slash + 1..];
	// Compile once now so a bad pattern is a syntax error, like in other engines.
	@pool()
	{
		JsString* p = self.vm.heap.string_from_utf8(pattern) ?? self.fail(e, "out of memory")~!;
		ushort[] units = mem::temp_array(ushort, p.len);
		for (uint i = 0; i < p.len; i++) units[i] = p.at(i);
		String error;
		Regex*? re = rt::regex_compile(units, flags, &error);
		if (catch re) return self.fail(e, string::bformat(&self.error_buf, "Invalid regular expression: /%s/%s: %s", pattern, flags, error))~;
		re.free();
		free(re);
	};
	uint pr = self.alloc()!;
	uint fr = self.alloc()!;
	self.emit_abx(LOADK, pr, self.const_index(self.atom(pattern)!)!);
	self.emit_abx(LOADK, fr, self.const_index(self.atom(flags)!)!);
	self.emit_abc(NEWREGEXP, dest, pr, fr);
}

// ---- classes ----

<*
 Call the running constructor's instance-field initializer with `this`.
*>
fn void? Codegen.run_fields(&self)
{
	uint t = self.alloc(2)!;
	self.emit_abc(GETFIELDS, t);
	self.emit_abc(MOVE, t + 1, 0);
	self.emit_abc(CALL, t, 0);
	self.release(t);
}

<*
 The body of a field initializer: define each field on `this` in declaration order.
*>
fn void? Codegen.field_initializers(&self, Node* cls, bool is_static)
{
	foreach (m : cls.list)
	{
		if (!m.flags.field || m.flags.is_static != is_static) continue;
		uint mark = self.fs.free_reg;
		self.fs.line = m.line;
		if (m.flags.computed)
		{
			uint kr = self.alloc()!;
			self.expr(m.d, kr)!;
			uint cv = self.alloc()!;
			if (m.b)
			{
				self.expr(m.b, cv)!;
			}
			else
			{
				self.emit_abc(LOADUNDEF, cv);
			}
			self.emit_abc(INITELEM, 0, kr, cv);
			self.release(mark);
			continue;
		}
		Value key = self.key_const(m.a)!;
		uint v = self.alloc()!;
		if (m.b)
		{
			self.expr_named(m.b, v, key.is_string() ? key.as_string().tutf8() : "")!;
		}
		else
		{
			self.emit_abc(LOADUNDEF, v);
		}
		uint k = self.const_index(key)!;
		if (k <= 255)
		{
			self.emit_abc(INITPROP, 0, k, v);
		}
		else
		{
			uint kr = self.alloc()!;
			self.emit_abx(LOADK, kr, k);
			self.emit_abc(INITELEM, 0, kr, v);
		}
		self.release(mark);
	}
}

fn void? Codegen.class_expr(&self, Node* n, uint dest, String name_hint)
{
	String name = n.name.len ? n.name : name_hint;
	uint saved = self.fs.free_reg;
	defer self.release(saved);
	// base: the constructor, base + 1: its prototype, base + 2: the parent class.
	uint base = self.alloc(3)!;
	bool has_extends = n.a != null;
	if (has_extends) self.expr(n.a, base + 2)!;
	Scope* scope = n.sema;
	self.enter_scope(scope)!;
	Node* ctor;
	foreach (m : n.list)
	{
		if (is_constructor_member(m)) ctor = m.b;
	}
	self.fs.line = n.line;
	bool outer_pending = self.pending_class_fields;
	self.pending_class_fields = n.b != null;
	FunctionProto*? p = self.compile_function(ctor, name);
	self.pending_class_fields = outer_pending;
	// A class's toString is the whole class.
	if (try p && n.end > n.start && n.end <= self.source_text.len) p.source = self.source_text[n.start:n.end - n.start];
	self.fs.protos.push(p!);
	self.emit_abx(CLOSURE, base, (uint)self.fs.protos.len() - 1);
	self.emit_abc(DEFCLASS, base, base + 2, has_extends ? 1 : 0);
	// The class's own name inside its body (the scope's other bindings are hidden field keys).
	foreach (b : scope.bindings)
	{
		if (b.name.len && b.name[0] != '#') self.store_binding_value(b, base)!;
	}
	foreach (m : n.list)
	{
		if (m.flags.field && m.flags.computed)
		{
			// Evaluated now, in member order, and once for every instance.
			uint mark = self.fs.free_reg;
			self.fs.line = m.line;
			uint key = self.alloc()!;
			self.expr(m.a, key)!;
			self.store_binding_value((Binding*)m.d.sema, key)!;
			self.release(mark);
			continue;
		}
		if (!m.flags.method || is_constructor_member(m)) continue;
		uint mark = self.fs.free_reg;
		self.fs.line = m.line;
		uint target = m.flags.is_static ? base : base + 1;
		uint key = self.alloc()!;
		String method_name = "";
		if (m.flags.computed)
		{
			self.expr(m.a, key)!;
		}
		else
		{
			Value k = self.key_const(m.a)!;
			self.load_value(key, k)!;
			if (k.is_string()) method_name = k.as_string().tutf8();
		}
		uint fun = self.alloc()!;
		self.closure(m.b, fun, method_name)!;
		Op op = m.flags.getter ? DEFGETTER : m.flags.setter ? DEFSETTER : DEFMETHOD;
		self.emit_abc(op, target, key, fun);
		self.release(mark);
	}
	if (n.b)
	{
		uint t = self.alloc()!;
		self.closure(n.b, t, "")!;
		self.emit_abc(SETHOME, t, base + 1);
		self.emit_abc(SETFIELDS, base, t);
		self.release(t);
	}
	if (n.c)
	{
		uint t = self.alloc(2)!;
		self.closure(n.c, t, "")!;
		self.emit_abc(SETHOME, t, base);
		self.emit_abc(MOVE, t + 1, base);
		self.emit_abc(CALL, t, 0);
		self.release(t);
	}
	if (dest != base) self.emit_abc(MOVE, dest, base);
}
