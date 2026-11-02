module fastjs::compile;
import std::collections::list, fastjs::ast, fastjs::lex, fastjs::rt;

excuse COMPILE_ERROR;

enum BindingKind : char
{
	LET,
	CONST,
	FUNCTION,
	PARAM,
	CLASS,
	CATCH,
	// A named function expression's own name, visible only inside it.
	SELF,
}

struct Binding
{
	String name;
	BindingKind kind;
	FuncInfo* func;
	Node* decl;
	// Register assigned by codegen; for a captured binding the register holds its Box.
	int reg;
	// Top-level script bindings live in VM slots shared between scripts.
	uint slot;
	bool is_slot;
	// Referenced from an inner function, so it lives in a Box.
	bool captured;
	// The resolver has walked past the declaration (so later reads in the same function are safe).
	bool declared;
	// Some read needs a TDZ check, so the register must start out uninitialized.
	bool tdz_used;
}

struct Scope
{
	Scope* parent;
	FuncInfo* func;
	List {Binding*} bindings;
}

struct FuncInfo
{
	FuncInfo* parent;
	Node* node;
	Scope* scope;
	// Bindings of enclosing functions this one uses, in capture-index order.
	List {Binding*} captures;
	Binding* self_binding;
}

struct Resolver
{
	Allocator arena;
	Vm* vm;
	Scope* scope;
	FuncInfo* func;
	bool is_module;
	String error;
	uint error_line;
	uint error_col;
	char[200] error_buf;
}

fn fault Resolver.fail(&self, Node* at, String message)
{
	self.error = message;
	self.error_line = at.line;
	self.error_col = at.col;
	return COMPILE_ERROR;
}

fn Scope* Resolver.push_scope(&self)
{
	Scope* s = alloc::new(self.arena, Scope);
	s.parent = self.scope;
	s.func = self.func;
	s.bindings.init(self.arena);
	self.scope = s;
	return s;
}

fn void Resolver.pop_scope(&self) => self.scope = self.scope.parent;

fn bool Resolver.at_script_top(&self) => !self.is_module && self.func.parent == null && self.scope.parent == null;

<*
 Declare name in the current scope.

 @return? COMPILE_ERROR
*>
fn Binding*? Resolver.declare(&self, String name, BindingKind kind, Node* decl)
{
	foreach (b : self.scope.bindings)
	{
		if (b.name == name)
		{
			return self.fail(decl, string::bformat(&self.error_buf, "Identifier '%s' has already been declared", name))~;
		}
	}
	Binding* b = alloc::new(self.arena, Binding);
	b.name = name;
	b.kind = kind;
	b.func = self.func;
	b.decl = decl;
	b.reg = -1;
	if (self.at_script_top())
	{
		JsString* atom = self.vm.heap.atom(name) ?? self.fail(decl, "out of memory")~!;
		b.is_slot = true;
		b.slot = self.vm.slot_for(atom, kind == CONST);
	}
	self.scope.bindings.push(b);
	return b;
}

fn void? Resolver.declare_pattern(&self, Node* p, BindingKind kind)
{
	switch (p.kind)
	{
		case IDENT:
			p.sema = self.declare(p.name, kind, p)!;
		case ARRAY_PATTERN:
			foreach (el : p.list)
			{
				if (el.kind != HOLE) self.declare_pattern(el, kind)!;
			}
		case OBJECT_PATTERN:
			foreach (prop : p.list) self.declare_pattern(prop.kind == REST ? prop.a : prop.b, kind)!;
		case ASSIGN_PATTERN:
		case REST:
			self.declare_pattern(p.a, kind)!;
		default:
			return self.fail(p, "invalid binding pattern")~;
	}
}

fn void Resolver.mark_declared(&self, Node* p)
{
	switch (p.kind)
	{
		case IDENT:
			if (p.sema) ((Binding*)p.sema).declared = true;
		case ARRAY_PATTERN:
			foreach (el : p.list)
			{
				if (el.kind != HOLE) self.mark_declared(el);
			}
		case OBJECT_PATTERN:
			foreach (prop : p.list) self.mark_declared(prop.kind == REST ? prop.a : prop.b);
		case ASSIGN_PATTERN:
		case REST:
			self.mark_declared(p.a);
		default:
			break;
	}
}

<*
 Walk the expressions inside a binding pattern: default values and computed keys.
*>
fn void? Resolver.visit_pattern_parts(&self, Node* p)
{
	switch (p.kind)
	{
		case ARRAY_PATTERN:
			foreach (el : p.list)
			{
				if (el.kind != HOLE) self.visit_pattern_parts(el)!;
			}
		case OBJECT_PATTERN:
			foreach (prop : p.list)
			{
				if (prop.kind == REST)
				{
					self.visit_pattern_parts(prop.a)!;
					continue;
				}
				if (prop.flags.computed) self.visit(prop.a)!;
				self.visit_pattern_parts(prop.b)!;
			}
		case ASSIGN_PATTERN:
			self.visit_pattern_parts(p.a)!;
			self.visit(p.b)!;
		case REST:
			self.visit_pattern_parts(p.a)!;
		default:
			break;
	}
}

<*
 Declare the let/const/function/class names of a statement list up front, so every reference
 in the block (even one before the declaration) resolves to them.
*>
fn void? Resolver.hoist(&self, Node*[] stmts)
{
	foreach (s : stmts) self.hoist_one(s)!;
}

fn void? Resolver.hoist_one(&self, Node* s)
{
	switch (s.kind)
	{
		case VAR_DECL:
			BindingKind kind = s.op == KW_CONST ? CONST : LET;
			foreach (d : s.list) self.declare_pattern(d.a, kind)!;
		case FUNCTION:
			if (s.flags.declaration) self.declare(s.name, FUNCTION, s)!;
		case CLASS:
			if (!s.flags.declaration) break;
			// The class node's own sema becomes its body scope, so the outer binding hangs off d.
			Node* decl_id = self.synth(IDENT, s, s.name);
			decl_id.sema = self.declare(s.name, CLASS, s)!;
			s.d = decl_id;
		case EXPORT:
			if (s.a) self.hoist_one(s.a)!;
		case EXPORT_DEFAULT:
			if (s.a.flags.declaration) self.hoist_one(s.a)!;
		default:
			break;
	}
}

fn Binding* Resolver.lookup(&self, String name)
{
	for (Scope* s = self.scope; s; s = s.parent)
	{
		foreach (b : s.bindings)
		{
			if (b.name == name) return b;
		}
	}
	return null;
}

<*
 Resolve a read or write of an identifier.
*>
fn void? Resolver.reference(&self, Node* ident)
{
	Binding* b = self.lookup(ident.name);
	if (!b)
	{
		// A top-level name declared by an earlier script.
		JsString* atom = self.vm.heap.atom(ident.name) ?? self.fail(ident, "out of memory")~!;
		int slot = self.vm.find_slot(atom);
		if (slot >= 0)
		{
			b = alloc::new(self.arena, Binding);
			b.name = ident.name;
			b.kind = self.vm.slot_const[slot] ? CONST : LET;
			b.is_slot = true;
			b.slot = (uint)slot;
			b.declared = true;
			b.reg = -1;
		}
		ident.sema = b;
		return;
	}
	ident.sema = b;
	if (b.is_slot) return;
	if (b.func != self.func)
	{
		b.captured = true;
		for (FuncInfo* f = self.func; f && f != b.func; f = f.parent)
		{
			if (!f.captures.contains(b)) f.captures.push(b);
		}
	}
	bool lexical = b.kind == LET || b.kind == CONST || b.kind == CLASS;
	if (lexical && (b.func != self.func || !b.declared))
	{
		ident.flags.needs_tdz = true;
		b.tdz_used = true;
	}
}

<*
 Resolve a whole program. Every identifier gets its Binding (or null for a global property),
 every block its Scope, every function its FuncInfo.

 @return? COMPILE_ERROR
*>
fn void? Resolver.resolve_program(&self, Node* program)
{
	FuncInfo* info = alloc::new(self.arena, FuncInfo);
	info.node = program;
	info.captures.init(self.arena);
	program.sema = info;
	self.func = info;
	info.scope = self.push_scope();
	self.hoist(program.list)!;
	foreach (s : program.list) self.visit(s)!;
}

fn void? Resolver.visit_function(&self, Node* fn_node)
{
	FuncInfo* info = alloc::new(self.arena, FuncInfo);
	info.parent = self.func;
	info.node = fn_node;
	info.captures.init(self.arena);
	fn_node.sema = info;
	Scope* saved_scope = self.scope;
	FuncInfo* saved_func = self.func;
	defer
	{
		self.scope = saved_scope;
		self.func = saved_func;
	}
	self.func = info;
	bool named_expression = fn_node.kind == FUNCTION && !fn_node.flags.declaration && !fn_node.flags.arrow && !fn_node.flags.method && fn_node.name.len > 0;
	if (named_expression)
	{
		self.push_scope();
		info.self_binding = self.declare(fn_node.name, SELF, fn_node)!;
		info.self_binding.declared = true;
	}
	info.scope = self.push_scope();
	foreach (param : fn_node.list)
	{
		self.declare_pattern(param, PARAM)!;
		self.mark_declared(param);
	}
	foreach (param : fn_node.list) self.visit_pattern_parts(param)!;
	if (fn_node.flags.expression_body)
	{
		self.visit(fn_node.a)!;
		return;
	}
	// The body's statements share the function scope with the parameters.
	fn_node.a.sema = info.scope;
	self.hoist(fn_node.a.list)!;
	foreach (s : fn_node.a.list) self.visit(s)!;
}

<*
 An assignment target: identifiers in it are writes, members are evaluated.
*>
fn void? Resolver.visit_target(&self, Node* t)
{
	switch (t.kind)
	{
		case IDENT:
			self.reference(t)!;
		case ARRAY_PATTERN:
			foreach (el : t.list)
			{
				if (el.kind != HOLE) self.visit_target(el)!;
			}
		case OBJECT_PATTERN:
			foreach (prop : t.list)
			{
				if (prop.kind == REST)
				{
					self.visit_target(prop.a)!;
					continue;
				}
				if (prop.flags.computed) self.visit(prop.a)!;
				self.visit_target(prop.b)!;
			}
		case ASSIGN_PATTERN:
			self.visit_target(t.a)!;
			self.visit(t.b)!;
		case REST:
			self.visit_target(t.a)!;
		default:
			self.visit(t)!;
	}
}

fn void? Resolver.visit_list(&self, Node*[] list)
{
	foreach (n : list) self.visit(n)!;
}

fn void? Resolver.visit(&self, Node* n)
{
	if (!n) return;
	switch (n.kind)
	{
		case IDENT:
			self.reference(n)!;
		case VAR_DECL:
			foreach (d : n.list)
			{
				self.visit(d.b)!;
				self.mark_declared(d.a);
				self.visit_pattern_parts(d.a)!;
			}
		case FUNCTION:
			self.visit_function(n)!;
		case CLASS:
			self.visit_class(n)!;
		case BLOCK:
			n.sema = self.push_scope();
			self.hoist(n.list)!;
			self.visit_list(n.list)!;
			self.pop_scope();
		case FOR:
			n.sema = self.push_scope();
			if (n.a && n.a.kind == VAR_DECL) self.hoist_one(n.a)!;
			self.visit(n.a)!;
			self.visit(n.b)!;
			self.visit(n.c)!;
			self.visit(n.d)!;
			self.pop_scope();
		case FOR_OF:
		case FOR_IN:
			n.sema = self.push_scope();
			if (n.a.kind == VAR_DECL)
			{
				self.hoist_one(n.a)!;
				self.visit(n.b)!;
				self.mark_declared(n.a.list[0].a);
				self.visit_pattern_parts(n.a.list[0].a)!;
			}
			else
			{
				self.visit(n.b)!;
				self.visit_target(n.a)!;
			}
			self.visit(n.d)!;
			self.pop_scope();
		case TRY:
			self.visit(n.a)!;
			if (n.c)
			{
				n.sema = self.push_scope();
				if (n.b)
				{
					self.declare_pattern(n.b, CATCH)!;
					self.mark_declared(n.b);
					self.visit_pattern_parts(n.b)!;
				}
				self.visit(n.c)!;
				self.pop_scope();
			}
			self.visit(n.d)!;
		case SWITCH:
			self.visit(n.a)!;
			n.sema = self.push_scope();
			foreach (c : n.list) self.hoist(c.list)!;
			foreach (c : n.list)
			{
				self.visit(c.a)!;
				self.visit_list(c.list)!;
			}
			self.pop_scope();
		case ASSIGN:
			self.visit_target(n.a)!;
			self.visit(n.b)!;
		case UPDATE:
			self.visit_target(n.a)!;
		case PROPERTY:
			if (n.flags.computed) self.visit(n.a)!;
			self.visit(n.b)!;
		case MEMBER:
			self.visit(n.a)!;
			if (n.flags.computed) self.visit(n.b)!;
		case IMPORT:
		case EXPORT_SPEC:
		case IMPORT_SPEC:
			return self.fail(n, "modules are not supported yet")~;
		case EXPORT:
			if (n.a)
			{
				self.visit(n.a)!;
				return;
			}
			return self.fail(n, "modules are not supported yet")~;
		default:
			self.visit(n.a)!;
			self.visit(n.b)!;
			self.visit(n.c)!;
			self.visit(n.d)!;
			self.visit_list(n.list)!;
	}
}

fn Node* Resolver.synth(&self, NodeKind kind, Node* at, String name = "")
{
	Node* n = alloc::new(self.arena, Node);
	n.kind = kind;
	n.start = at.start;
	n.line = at.line;
	n.col = at.col;
	n.name = name;
	return n;
}

fn Node*[] Resolver.one(&self, Node* n)
{
	Node*[] list = alloc::alloc_array(self.arena, Node*, 1);
	list[0] = n;
	return list;
}

<*
 The constructor a class gets when it doesn't write one: `constructor(...args) { super(...args); }`
 when it extends something, an empty one otherwise. Appended to the class's members.
*>
fn Node* Resolver.default_constructor(&self, Node* cls)
{
	Node* f = self.synth(FUNCTION, cls);
	f.flags.method = true;
	Node* body = self.synth(BLOCK, cls);
	f.a = body;
	if (cls.a)
	{
		Node* rest = self.synth(REST, cls);
		rest.a = self.synth(IDENT, cls, "args");
		f.list = self.one(rest);
		Node* spread = self.synth(SPREAD, cls);
		spread.a = self.synth(IDENT, cls, "args");
		Node* call = self.synth(CALL, cls);
		call.a = self.synth(SUPER, cls);
		call.list = self.one(spread);
		Node* stmt = self.synth(EXPR_STMT, cls);
		stmt.a = call;
		body.list = self.one(stmt);
	}
	Node* prop = self.synth(PROPERTY, cls);
	prop.flags.method = true;
	prop.a = self.synth(IDENT, cls, "constructor");
	prop.b = f;
	Node*[] members = alloc::alloc_array(self.arena, Node*, cls.list.len + 1);
	members[:cls.list.len] = cls.list[..];
	members[^1] = prop;
	cls.list = members;
	return f;
}

fn bool is_constructor_member(Node* m)
{
	return m.flags.method && !m.flags.is_static && !m.flags.computed && !m.flags.getter && !m.flags.setter && m.a.kind == IDENT && m.a.name == "constructor";
}

<*
 A hidden method that runs a class's field initializers (instance or static), with `this` the
 object being initialized. Null when there are no such fields.
*>
fn Node*? Resolver.field_function(&self, Node* cls, bool is_static)
{
	bool has_fields = false;
	foreach (m : cls.list)
	{
		if (m.flags.field && m.flags.is_static == is_static) has_fields = true;
	}
	if (!has_fields) return null;
	Node* f = self.synth(FUNCTION, cls, is_static ? "<static_initializer>" : "<instance_members_initializer>");
	f.flags.method = true;
	f.flags.field = true;
	f.flags.is_static = is_static;
	f.a = cls;
	FuncInfo* info = alloc::new(self.arena, FuncInfo);
	info.parent = self.func;
	info.node = f;
	info.captures.init(self.arena);
	f.sema = info;
	Scope* saved_scope = self.scope;
	FuncInfo* saved_func = self.func;
	defer
	{
		self.scope = saved_scope;
		self.func = saved_func;
	}
	self.func = info;
	info.scope = self.push_scope();
	foreach (m : cls.list)
	{
		if (!m.flags.field || m.flags.is_static != is_static) continue;
		if (m.flags.computed) return self.fail(m, "computed class field names are not supported yet")~;
		self.visit(m.b)!;
	}
	return f;
}

fn void? Resolver.visit_class(&self, Node* n)
{
	// The heritage expression and computed keys run in the enclosing function.
	self.visit(n.a)!;
	Scope* saved = self.scope;
	defer self.scope = saved;
	n.sema = self.push_scope();
	if (n.name.len)
	{
		Binding* inner = self.declare(n.name, CONST, n)!;
		inner.declared = true;
	}
	Node* ctor = null;
	foreach (m : n.list)
	{
		if (is_constructor_member(m)) ctor = m.b;
	}
	if (!ctor) ctor = self.default_constructor(n);
	ctor.flags.class_constructor = true;
	ctor.flags.derived = n.a != null;
	foreach (m : n.list)
	{
		if (m.flags.computed) self.visit(m.a)!;
	}
	foreach (m : n.list)
	{
		if (m.flags.method) self.visit_function(m.b)!;
	}
	n.b = self.field_function(n, false)!;
	n.c = self.field_function(n, true)!;
}
