module fastjs::print;
import std::core::dstring, fastjs::ast, fastjs::lex;

// Prints an AST back as JavaScript with every compound expression parenthesized. Printing,
// reparsing and printing again must give the same text, which is how the parser is checked.
struct Printer
{
	DString out;
	int indent;
}

<*
 The program as JavaScript, allocated from allocator.

 @param [&in] program : "A PROGRAM node"
 @return "The source text; the caller frees it"
*>
fn String to_js(Allocator allocator, Node* program)
{
	Printer p;
	p.out.init(mem);
	defer p.out.free();
	foreach (s : program.list) p.statement(s);
	return p.out.copy_str(allocator);
}

<*
 One expression as JavaScript, allocated from allocator.

 @param [&in] e : "An expression node"
 @return "The source text; the caller frees it"
*>
fn String expression_to_js(Allocator allocator, Node* e)
{
	Printer p;
	p.out.init(mem);
	defer p.out.free();
	p.expr(e);
	return p.out.copy_str(allocator);
}

fn void Printer.put(&self, String s) => self.out.append(s);

fn void Printer.pad(&self)
{
	for (int i = 0; i < self.indent; i++) self.out.append('\t');
}

fn void Printer.statement(&self, Node* n)
{
	self.pad();
	self.statement_inline(n);
}

fn void Printer.block(&self, Node* n)
{
	self.put("{\n");
	self.indent++;
	foreach (s : n.list) self.statement(s);
	self.indent--;
	self.pad();
	self.put("}");
}

// A statement body always prints as a block, which keeps `else` unambiguous.
fn void Printer.body(&self, Node* n)
{
	if (n.kind == BLOCK)
	{
		self.block(n);
		return;
	}
	self.put("{\n");
	self.indent++;
	self.statement(n);
	self.indent--;
	self.pad();
	self.put("}");
}

fn void Printer.statement_inline(&self, Node* n)
{
	switch (n.kind)
	{
		case EXPR_STMT:
			self.expr(n.a);
			self.put(";\n");
		case VAR_DECL:
			self.declaration(n);
			self.put(";\n");
		case FUNCTION:
			self.function_expr(n);
			self.put("\n");
		case CLASS:
			self.class_expr(n);
			self.put("\n");
		case BLOCK:
			self.block(n);
			self.put("\n");
		case EMPTY:
			self.put(";\n");
		case IF:
			self.put("if (");
			self.expr(n.a);
			self.put(") ");
			self.body(n.b);
			if (n.c)
			{
				self.put(" else ");
				self.body(n.c);
			}
			self.put("\n");
		case FOR:
			self.put("for (");
			if (n.a)
			{
				if (n.a.kind == VAR_DECL)
				{
					self.declaration(n.a);
				}
				else
				{
					self.expr(n.a);
				}
			}
			self.put(";");
			if (n.b)
			{
				self.put(" ");
				self.expr(n.b);
			}
			self.put(";");
			if (n.c)
			{
				self.put(" ");
				self.expr(n.c);
			}
			self.put(") ");
			self.body(n.d);
			self.put("\n");
		case FOR_OF:
		case FOR_IN:
			self.put("for (");
			if (n.a.kind == VAR_DECL)
			{
				self.declaration(n.a);
			}
			else
			{
				self.pattern(n.a);
			}
			self.put(n.kind == FOR_OF ? " of " : " in ");
			self.expr(n.b);
			self.put(") ");
			self.body(n.d);
			self.put("\n");
		case WHILE:
			self.put("while (");
			self.expr(n.a);
			self.put(") ");
			self.body(n.d);
			self.put("\n");
		case RETURN:
			self.put("return");
			if (n.a)
			{
				self.put(" ");
				self.expr(n.a);
			}
			self.put(";\n");
		case BREAK:
			self.put("break;\n");
		case CONTINUE:
			self.put("continue;\n");
		case THROW:
			self.put("throw ");
			self.expr(n.a);
			self.put(";\n");
		case TRY:
			self.put("try ");
			self.block(n.a);
			if (n.c)
			{
				self.put(" catch ");
				if (n.b)
				{
					self.put("(");
					self.pattern(n.b);
					self.put(") ");
				}
				self.block(n.c);
			}
			if (n.d)
			{
				self.put(" finally ");
				self.block(n.d);
			}
			self.put("\n");
		case SWITCH:
			self.put("switch (");
			self.expr(n.a);
			self.put(") {\n");
			self.indent++;
			foreach (c : n.list)
			{
				self.pad();
				if (c.a)
				{
					self.put("case ");
					self.expr(c.a);
					self.put(":\n");
				}
				else
				{
					self.put("default:\n");
				}
				self.indent++;
				foreach (s : c.list) self.statement(s);
				self.indent--;
			}
			self.indent--;
			self.pad();
			self.put("}\n");
		case IMPORT:
			self.import_decl(n);
		case EXPORT:
			self.put("export ");
			if (n.a)
			{
				self.statement_inline(n.a);
				return;
			}
			self.put("{");
			foreach (i, spec : n.list)
			{
				if (i > 0) self.put(", ");
				self.put(spec.a.name);
				if (spec.name != spec.a.name)
				{
					self.put(" as ");
					self.put(spec.name);
				}
			}
			self.put("}");
			if (n.name.len)
			{
				self.put(" from \"");
				self.put(n.name);
				self.put("\"");
			}
			self.put(";\n");
		case EXPORT_DEFAULT:
			self.put("export default ");
			if (n.a.flags.declaration)
			{
				self.statement_inline(n.a);
				return;
			}
			self.expr(n.a);
			self.put(";\n");
		default:
			self.put("/* unexpected ");
			self.put(n.kind.text);
			self.put(" */\n");
	}
}

fn void Printer.import_decl(&self, Node* n)
{
	self.put("import ");
	if (n.list.len > 0)
	{
		bool comma = false;
		bool braces = false;
		foreach (spec : n.list)
		{
			switch
			{
				case spec.flags.default_import:
					self.put(spec.b.name);
					comma = true;
				case spec.name == "*":
					if (comma) self.put(", ");
					self.put("* as ");
					self.put(spec.b.name);
					comma = true;
				default:
					if (!braces)
					{
						if (comma) self.put(", ");
						self.put("{");
						braces = true;
					}
					else
					{
						self.put(", ");
					}
					self.put(spec.name);
					if (spec.name != spec.b.name)
					{
						self.put(" as ");
						self.put(spec.b.name);
					}
			}
		}
		if (braces) self.put("}");
		self.put(" from ");
	}
	self.put("\"");
	self.put(n.name);
	self.put("\";\n");
}

fn void Printer.declaration(&self, Node* n)
{
	self.put(n.op == KW_CONST ? "const " : "let ");
	foreach (i, d : n.list)
	{
		if (i > 0) self.put(", ");
		self.pattern(d.a);
		if (d.b)
		{
			self.put(" = ");
			self.expr(d.b);
		}
	}
}

fn void Printer.list(&self, Node*[] items)
{
	foreach (i, item : items)
	{
		if (i > 0) self.put(", ");
		self.expr(item);
	}
}

fn void Printer.params(&self, Node*[] params)
{
	self.put("(");
	foreach (i, param : params)
	{
		if (i > 0) self.put(", ");
		self.pattern(param);
	}
	self.put(")");
}

fn void Printer.function_expr(&self, Node* f)
{
	bool wrap = !f.flags.declaration;
	if (wrap) self.put("(");
	if (f.flags.is_async) self.put("async ");
	if (f.flags.arrow)
	{
		self.params(f.list);
		self.put(" => ");
		if (f.flags.expression_body)
		{
			self.expr(f.a);
		}
		else
		{
			self.block(f.a);
		}
	}
	else
	{
		self.put("function");
		if (f.flags.generator) self.put("*");
		if (f.name.len)
		{
			self.put(" ");
			self.put(f.name);
		}
		self.params(f.list);
		self.put(" ");
		self.block(f.a);
	}
	if (wrap) self.put(")");
}

fn void Printer.key(&self, Node* p)
{
	if (p.flags.computed)
	{
		self.put("[");
		self.expr(p.a);
		self.put("]");
		return;
	}
	self.expr(p.a);
}

fn void Printer.method(&self, Node* p)
{
	if (p.flags.getter) self.put("get ");
	if (p.flags.setter) self.put("set ");
	if (p.flags.is_async) self.put("async ");
	if (p.flags.generator) self.put("*");
	self.key(p);
	self.params(p.b.list);
	self.put(" ");
	self.block(p.b.a);
}

fn void Printer.class_expr(&self, Node* c)
{
	bool wrap = !c.flags.declaration;
	if (wrap) self.put("(");
	self.put("class");
	if (c.name.len)
	{
		self.put(" ");
		self.put(c.name);
	}
	if (c.a)
	{
		self.put(" extends ");
		self.expr(c.a);
	}
	self.put(" {\n");
	self.indent++;
	foreach (m : c.list)
	{
		self.pad();
		if (m.flags.is_static) self.put("static ");
		if (m.flags.method)
		{
			self.method(m);
			self.put("\n");
			continue;
		}
		self.key(m);
		if (m.b)
		{
			self.put(" = ");
			self.expr(m.b);
		}
		self.put(";\n");
	}
	self.indent--;
	self.pad();
	self.put("}");
	if (wrap) self.put(")");
}

fn void Printer.string(&self, Node* n)
{
	String quote = n.flags.single_quote ? "'" : "\"";
	self.put(quote);
	self.put(n.name);
	self.put(quote);
}

// Members of a number need parentheses: `1.x` would lex as `1.` then `x`.
fn void Printer.object(&self, Node* n)
{
	if (n.kind == NUMBER)
	{
		self.put("(");
		self.expr(n);
		self.put(")");
		return;
	}
	self.expr(n);
}

fn void Printer.elements(&self, Node*[] items, bool as_pattern)
{
	self.put("[");
	foreach (i, el : items)
	{
		if (i > 0) self.put(", ");
		if (el.kind == HOLE) continue;
		if (as_pattern)
		{
			self.pattern(el);
		}
		else
		{
			self.expr(el);
		}
	}
	// A trailing hole needs its own comma, or it disappears on reparse.
	if (items.len > 0 && items[^1].kind == HOLE) self.put(",");
	self.put("]");
}

fn void Printer.pattern(&self, Node* n)
{
	switch (n.kind)
	{
		case ARRAY_PATTERN:
			self.elements(n.list, true);
		case OBJECT_PATTERN:
			self.put("{");
			foreach (i, p : n.list)
			{
				if (i > 0) self.put(", ");
				if (p.kind == REST)
				{
					self.pattern(p);
					continue;
				}
				if (p.flags.shorthand)
				{
					self.pattern(p.b);
					continue;
				}
				self.key(p);
				self.put(": ");
				self.pattern(p.b);
			}
			self.put("}");
		case ASSIGN_PATTERN:
			self.pattern(n.a);
			self.put(" = ");
			self.expr(n.b);
		case REST:
			self.put("...");
			self.pattern(n.a);
		default:
			self.expr(n);
	}
}

fn void Printer.expr(&self, Node* n)
{
	switch (n.kind)
	{
		case NUMBER:
		case REGEX:
		case IDENT:
			self.put(n.name);
		case STRING:
			self.string(n);
		case TEMPLATE:
			self.put("`");
			foreach (i, part : n.list)
			{
				if (i % 2 == 0)
				{
					self.put(part.name);
					continue;
				}
				self.put("${");
				self.expr(part);
				self.put("}");
			}
			self.put("`");
		case THIS: self.put("this");
		case SUPER: self.put("super");
		case NULL: self.put("null");
		case TRUE: self.put("true");
		case FALSE: self.put("false");
		case NEW_TARGET: self.put("new.target");
		case ARRAY:
			self.elements(n.list, false);
		case OBJECT:
			self.put("({");
			foreach (i, p : n.list)
			{
				if (i > 0) self.put(", ");
				if (p.kind == SPREAD)
				{
					self.expr(p);
					continue;
				}
				if (p.flags.method)
				{
					self.method(p);
					continue;
				}
				if (p.flags.shorthand)
				{
					self.pattern(p.b);
					continue;
				}
				self.key(p);
				self.put(": ");
				self.expr(p.b);
			}
			self.put("})");
		case FUNCTION:
			self.function_expr(n);
		case CLASS:
			self.class_expr(n);
		case UNARY:
			self.put("(");
			self.put(n.op.text);
			self.put(" ");
			self.expr(n.a);
			self.put(")");
		case UPDATE:
			self.put("(");
			if (n.flags.prefix) self.put(n.op.text);
			self.expr(n.a);
			if (!n.flags.prefix) self.put(n.op.text);
			self.put(")");
		case BINARY:
		case LOGICAL:
			self.put("(");
			self.expr(n.a);
			self.put(" ");
			self.put(n.op.text);
			self.put(" ");
			self.expr(n.b);
			self.put(")");
		case ASSIGN:
			self.put("(");
			self.pattern(n.a);
			self.put(" ");
			self.put(n.op.text);
			self.put(" ");
			self.expr(n.b);
			self.put(")");
		case CONDITIONAL:
			self.put("(");
			self.expr(n.a);
			self.put(" ? ");
			self.expr(n.b);
			self.put(" : ");
			self.expr(n.c);
			self.put(")");
		case CALL:
			self.object(n.a);
			if (n.flags.optional) self.put("?.");
			self.put("(");
			self.list(n.list);
			self.put(")");
		case NEW:
			self.put("(new (");
			self.expr(n.a);
			self.put(")(");
			self.list(n.list);
			self.put("))");
		case MEMBER:
			self.object(n.a);
			if (n.flags.optional) self.put("?.");
			if (n.flags.computed)
			{
				self.put("[");
				self.expr(n.b);
				self.put("]");
			}
			else
			{
				if (!n.flags.optional) self.put(".");
				self.put(n.name);
			}
		case OPTIONAL_CHAIN:
			self.put("(");
			self.expr(n.a);
			self.put(")");
		case SEQUENCE:
			self.put("(");
			self.list(n.list);
			self.put(")");
		case SPREAD:
			self.put("...");
			self.expr(n.a);
		case YIELD:
			self.put(n.flags.delegate ? "(yield*" : "(yield");
			if (n.a)
			{
				self.put(" ");
				self.expr(n.a);
			}
			self.put(")");
		case AWAIT:
			self.put("(await ");
			self.expr(n.a);
			self.put(")");
		case ARRAY_PATTERN:
		case OBJECT_PATTERN:
		case ASSIGN_PATTERN:
		case REST:
			self.pattern(n);
		default:
			self.put("/* unexpected ");
			self.put(n.kind.text);
			self.put(" */");
	}
}
