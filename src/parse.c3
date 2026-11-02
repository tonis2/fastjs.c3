module fastjs::parse;
import std::collections::list, fastjs::lex, fastjs::ast;

alias NodeList = List {Node*};

struct Parser
{
	Lexer lx;
	String src;
	Token tok;
	Token prev;
	// Nodes are allocated here and live as long as the caller keeps the arena.
	Allocator arena;
	// Shared stack for building child lists; each list is copied into the arena when complete.
	NodeList scratch;
	bool in_function;
	bool in_async;
	bool in_generator;
	bool is_module;
	// `{ a = 1 }` literals not yet turned into patterns; any left at the end is an error.
	int cover_inits;
	Token cover_init_tok;
	String error;
	uint error_line;
	uint error_col;
	char[256] error_buf;
}

<*
 Prepare to parse src. Nodes are allocated from arena; call free() when done with the parser.
*>
fn void Parser.init(&self, Allocator arena, String src, bool is_module, uint first_line = 1)
{
	*self = { .src = src, .arena = arena, .is_module = is_module };
	self.lx.init(src, first_line);
	self.scratch.init(mem);
}

fn void Parser.free(&self) => self.scratch.free();

<*
 Parse the whole source.

 @return? lex::SYNTAX
 @return "A PROGRAM node"
*>
fn Node*? Parser.parse_program(&self)
{
	self.advance()!;
	Token start = self.tok;
	Node* prog = self.node(PROGRAM, &start);
	prog.flags.is_module = self.is_module;
	sz m = self.scratch.len();
	while (self.tok.kind != EOF) self.scratch.push(self.parse_statement(true)!);
	prog.list = self.finish(m);
	if (self.cover_inits > 0) return self.fail_at(&self.cover_init_tok, "'=' in an object literal is only valid in destructuring")~;
	return prog;
}

// ---- token helpers ----

fn fault Parser.fail_at(&self, Token* t, String message)
{
	self.error = message;
	self.error_line = t.line;
	self.error_col = t.col;
	return lex::SYNTAX;
}

fn fault Parser.fail(&self, String message) => self.fail_at(&self.tok, message);

fn fault Parser.lex_failed(&self)
{
	self.error = self.lx.error;
	self.error_line = self.lx.error_line;
	self.error_col = self.lx.error_col;
	return lex::SYNTAX;
}

fn String Parser.describe(&self, Token* t)
{
	if (t.kind == EOF) return "end of input";
	String text = t.text(self.src);
	return text.len > 40 ? text[:40] : text;
}

fn fault Parser.unexpected(&self)
{
	return self.fail(string::bformat(&self.error_buf, "unexpected '%s'", self.describe(&self.tok)));
}

fn void? Parser.advance(&self)
{
	self.prev = self.tok;
	Token? t = self.lx.next();
	if (catch t) return self.lex_failed()~;
	self.tok = t;
}

<*
 The token after the current one, without consuming anything.
*>
fn Token? Parser.peek(&self)
{
	LexState saved = self.lx.state;
	Token? t = self.lx.next();
	self.lx.state = saved;
	if (catch t) return self.lex_failed()~;
	return t;
}

fn bool? Parser.eat(&self, TokenKind kind)
{
	if (self.tok.kind != kind) return false;
	self.advance()!;
	return true;
}

fn void? Parser.expect(&self, TokenKind kind)
{
	if (self.tok.kind == kind) return self.advance();
	return self.fail(string::bformat(&self.error_buf, "expected '%s' but found '%s'", kind.text, self.describe(&self.tok)))~;
}

fn String Parser.text(&self) => self.tok.text(self.src);

fn bool Parser.at_word(&self, String word) => self.tok.kind == IDENT && self.tok.text(self.src) == word;

fn void? Parser.expect_word(&self, String word)
{
	if (self.at_word(word)) return self.advance();
	return self.fail(string::bformat(&self.error_buf, "expected '%s' but found '%s'", word, self.describe(&self.tok)))~;
}

// Automatic semicolon insertion: a missing ';' is fine before '}', at the end, or after a line break.
fn void? Parser.consume_semicolon(&self)
{
	if (self.tok.kind == SEMICOLON) return self.advance();
	if (self.tok.kind == RBRACE || self.tok.kind == EOF || self.tok.nl_before) return;
	return self.fail(string::bformat(&self.error_buf, "expected ';' but found '%s'", self.describe(&self.tok)))~;
}

// ---- node helpers ----

fn Node* Parser.node(&self, NodeKind kind, Token* at)
{
	Node* n = alloc::new(self.arena, Node);
	n.kind = kind;
	n.start = at.start;
	n.line = at.line;
	n.col = at.col;
	return n;
}

fn Node* Parser.node_at(&self, NodeKind kind, Node* at)
{
	Node* n = alloc::new(self.arena, Node);
	n.kind = kind;
	n.start = at.start;
	n.line = at.line;
	n.col = at.col;
	return n;
}

<*
 Move the scratch entries pushed since mark into an arena list.

 @require mark <= self.scratch.len() : "Mark past the end of scratch"
*>
fn Node*[] Parser.finish(&self, sz mark)
{
	sz n = self.scratch.len() - mark;
	if (n == 0) return {};
	Node*[] out = alloc::alloc_array(self.arena, Node*, n);
	out[..] = self.scratch.array_view()[mark:n];
	self.scratch.size = mark;
	return out;
}

fn Node*[] Parser.one(&self, Node* n)
{
	Node*[] out = alloc::alloc_array(self.arena, Node*, 1);
	out[0] = n;
	return out;
}

fn Node* Parser.ident_from(&self, Token* t)
{
	Node* n = self.node(IDENT, t);
	n.name = t.text(self.src);
	return n;
}

fn bool is_bare_arrow(Node* n) => n.kind == FUNCTION && n.flags.arrow && !n.flags.parenthesized;

fn bool starts_property_key(TokenKind k) => k == IDENT || k.is_keyword() || k == STRING || k == NUMBER || k == LBRACKET || k == HASH;

fn bool ends_expression(TokenKind k)
{
	switch (k)
	{
		case RPAREN:
		case RBRACKET:
		case RBRACE:
		case COMMA:
		case SEMICOLON:
		case COLON:
		case EOF:
		case TEMPLATE_MIDDLE:
		case TEMPLATE_TAIL:
			return true;
		default:
			return false;
	}
}

// ---- statements ----

fn Node*? Parser.parse_statement(&self, bool top_level = false)
{
	Token t = self.tok;
	switch (t.kind)
	{
		case LBRACE:
			return self.parse_block();
		case SEMICOLON:
			self.advance()!;
			return self.node(EMPTY, &t);
		case KW_CONST:
			return self.parse_declaration_statement();
		case KW_FUNCTION:
			return self.parse_function(&t, true, false);
		case KW_CLASS:
			return self.parse_class(true);
		case KW_IF:
			return self.parse_if();
		case KW_FOR:
			return self.parse_for();
		case KW_WHILE:
			self.advance()!;
			Node* n = self.node(WHILE, &t);
			self.expect(LPAREN)!;
			n.a = self.parse_expression()!;
			self.expect(RPAREN)!;
			n.d = self.parse_statement()!;
			return n;
		case KW_RETURN:
			if (!self.in_function) return self.fail("'return' outside of a function")~;
			self.advance()!;
			Node* n = self.node(RETURN, &t);
			if (self.tok.kind != SEMICOLON && self.tok.kind != RBRACE && self.tok.kind != EOF && !self.tok.nl_before)
			{
				n.a = self.parse_expression()!;
			}
			self.consume_semicolon()!;
			return n;
		case KW_BREAK:
		case KW_CONTINUE:
			self.advance()!;
			if (self.tok.kind == IDENT && !self.tok.nl_before) return self.fail("labels are not supported")~;
			self.consume_semicolon()!;
			return self.node(t.kind == KW_BREAK ? BREAK : CONTINUE, &t);
		case KW_THROW:
			self.advance()!;
			if (self.tok.nl_before) return self.fail("no line break is allowed after 'throw'")~;
			Node* n = self.node(THROW, &t);
			n.a = self.parse_expression()!;
			self.consume_semicolon()!;
			return n;
		case KW_TRY:
			return self.parse_try();
		case KW_SWITCH:
			return self.parse_switch();
		case KW_IMPORT:
			if (!top_level || !self.is_module) return self.fail("'import' is only allowed at the top level of a module")~;
			return self.parse_import();
		case KW_EXPORT:
			if (!top_level || !self.is_module) return self.fail("'export' is only allowed at the top level of a module")~;
			return self.parse_export();
		case KW_VAR:
			return self.fail("'var' is not supported; use 'let' or 'const'")~;
		case KW_DO:
			return self.fail("'do...while' is not supported; use 'while'")~;
		case KW_WITH:
			return self.fail("'with' is not supported")~;
		case KW_DEBUGGER:
			return self.fail("'debugger' is not supported")~;
		case IDENT:
			if (self.at_word("let")) return self.parse_declaration_statement();
			Token next = self.peek()!;
			if (next.kind == COLON) return self.fail("labels are not supported")~;
			if (self.at_word("async") && next.kind == KW_FUNCTION && !next.nl_before)
			{
				self.advance()!;
				return self.parse_function(&t, true, true);
			}
		default:
			break;
	}
	Node* n = self.node(EXPR_STMT, &t);
	n.a = self.parse_expression()!;
	self.consume_semicolon()!;
	return n;
}

fn Node*? Parser.parse_block(&self)
{
	Token t = self.tok;
	self.expect(LBRACE)!;
	Node* n = self.node(BLOCK, &t);
	sz m = self.scratch.len();
	while (self.tok.kind != RBRACE)
	{
		if (self.tok.kind == EOF) return self.fail("expected '}' but found end of input")~;
		self.scratch.push(self.parse_statement()!);
	}
	n.list = self.finish(m);
	self.advance()!;
	return n;
}

fn Node*? Parser.parse_declaration_statement(&self)
{
	Node* n = self.parse_declaration(false)!;
	self.consume_semicolon()!;
	return n;
}

<*
 `let` or `const` and its declarators, without the semicolon. no_in stops at `in`, for a for-in head.
*>
fn Node*? Parser.parse_declaration(&self, bool no_in)
{
	Token t = self.tok;
	Node* decl = self.node(VAR_DECL, &t);
	decl.op = t.kind == KW_CONST ? KW_CONST : IDENT;
	self.advance()!;
	sz m = self.scratch.len();
	while (true)
	{
		Token at = self.tok;
		Node* d = self.node(DECLARATOR, &at);
		d.a = self.parse_binding_target()!;
		if (self.eat(ASSIGN)!) d.b = self.parse_assignment(no_in)!;
		self.scratch.push(d);
		if (!self.eat(COMMA)!) break;
	}
	decl.list = self.finish(m);
	return decl;
}

fn Node*? Parser.parse_if(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(IF, &t);
	self.expect(LPAREN)!;
	n.a = self.parse_expression()!;
	self.expect(RPAREN)!;
	n.b = self.parse_statement()!;
	if (self.eat(KW_ELSE)!) n.c = self.parse_statement()!;
	return n;
}

fn Node*? Parser.parse_for(&self)
{
	Token t = self.tok;
	self.advance()!;
	if (self.at_word("await")) return self.fail("'for await' is not supported")~;
	self.expect(LPAREN)!;
	Node* init = null;
	switch
	{
		case self.tok.kind == SEMICOLON:
			break;
		case self.tok.kind == KW_CONST || self.at_word("let"):
			init = self.parse_declaration(true)!;
		case self.tok.kind == KW_VAR:
			return self.fail("'var' is not supported; use 'let' or 'const'")~;
		default:
			init = self.parse_expression(true)!;
	}
	if (init && (self.at_word("of") || self.tok.kind == KW_IN))
	{
		bool of = self.tok.kind == IDENT;
		Token op = self.tok;
		self.advance()!;
		Node* n = self.node(of ? FOR_OF : FOR_IN, &t);
		if (init.kind == VAR_DECL)
		{
			if (init.list.len != 1 || init.list[0].b) return self.fail_at(&op, "a for-of or for-in head declares one variable, without an initializer")~;
		}
		else
		{
			init = self.to_pattern(init, false)!;
		}
		n.a = init;
		n.b = of ? self.parse_assignment()! : self.parse_expression()!;
		self.expect(RPAREN)!;
		n.d = self.parse_statement()!;
		return n;
	}
	Node* n = self.node(FOR, &t);
	n.a = init;
	self.expect(SEMICOLON)!;
	if (self.tok.kind != SEMICOLON) n.b = self.parse_expression()!;
	self.expect(SEMICOLON)!;
	if (self.tok.kind != RPAREN) n.c = self.parse_expression()!;
	self.expect(RPAREN)!;
	n.d = self.parse_statement()!;
	return n;
}

fn Node*? Parser.parse_try(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(TRY, &t);
	n.a = self.parse_block()!;
	if (self.eat(KW_CATCH)!)
	{
		if (self.eat(LPAREN)!)
		{
			n.b = self.parse_binding_target()!;
			self.expect(RPAREN)!;
		}
		n.c = self.parse_block()!;
	}
	if (self.eat(KW_FINALLY)!) n.d = self.parse_block()!;
	if (!n.c && !n.d) return self.fail("'try' needs 'catch' or 'finally'")~;
	return n;
}

fn Node*? Parser.parse_switch(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(SWITCH, &t);
	self.expect(LPAREN)!;
	n.a = self.parse_expression()!;
	self.expect(RPAREN)!;
	self.expect(LBRACE)!;
	sz m = self.scratch.len();
	bool seen_default = false;
	while (self.tok.kind != RBRACE)
	{
		Token ct = self.tok;
		Node* c = self.node(CASE, &ct);
		if (self.eat(KW_CASE)!)
		{
			c.a = self.parse_expression()!;
		}
		else if (self.tok.kind == KW_DEFAULT)
		{
			if (seen_default) return self.fail("more than one 'default' in a switch")~;
			seen_default = true;
			self.advance()!;
		}
		else
		{
			return self.unexpected()~;
		}
		self.expect(COLON)!;
		sz body = self.scratch.len();
		while (self.tok.kind != KW_CASE && self.tok.kind != KW_DEFAULT && self.tok.kind != RBRACE)
		{
			if (self.tok.kind == EOF) return self.fail("expected '}' but found end of input")~;
			self.scratch.push(self.parse_statement()!);
		}
		c.list = self.finish(body);
		self.scratch.push(c);
	}
	n.list = self.finish(m);
	self.advance()!;
	return n;
}

// ---- modules ----

fn Node*? Parser.module_specifier(&self)
{
	if (self.tok.kind != STRING) return self.fail("expected a module name string")~;
	Token t = self.tok;
	Node* s = self.parse_primary()!;
	if (s.flags.escaped) return self.fail_at(&t, "escapes in module names are not supported")~;
	return s;
}

fn Node*? Parser.parse_import(&self)
{
	Token t = self.tok;
	self.advance()!;
	if (self.tok.kind == LPAREN || self.tok.kind == DOT) return self.fail("dynamic import() and import.meta are not supported")~;
	Node* n = self.node(IMPORT, &t);
	if (self.tok.kind == STRING)
	{
		n.name = self.module_specifier()!.name;
		self.consume_semicolon()!;
		return n;
	}
	sz m = self.scratch.len();
	bool more = true;
	if (self.tok.kind == IDENT)
	{
		Token at = self.tok;
		Node* spec = self.node(IMPORT_SPEC, &at);
		spec.name = "default";
		spec.flags.default_import = true;
		spec.b = self.parse_binding_ident()!;
		self.scratch.push(spec);
		more = self.eat(COMMA)!;
	}
	if (more)
	{
		Token at = self.tok;
		switch (at.kind)
		{
			case STAR:
				self.advance()!;
				self.expect_word("as")!;
				Node* spec = self.node(IMPORT_SPEC, &at);
				spec.name = "*";
				spec.b = self.parse_binding_ident()!;
				self.scratch.push(spec);
			case LBRACE:
				self.advance()!;
				while (self.tok.kind != RBRACE)
				{
					Token it = self.tok;
					if (it.kind != IDENT && !it.kind.is_keyword()) return self.unexpected()~;
					Node* spec = self.node(IMPORT_SPEC, &it);
					spec.name = it.text(self.src);
					self.advance()!;
					if (self.at_word("as"))
					{
						self.advance()!;
						spec.b = self.parse_binding_ident()!;
					}
					else
					{
						if (it.kind != IDENT) return self.fail_at(&it, "a keyword import needs 'as'")~;
						spec.b = self.ident_from(&it);
					}
					self.scratch.push(spec);
					if (!self.eat(COMMA)!) break;
				}
				self.expect(RBRACE)!;
			default:
				return self.unexpected()~;
		}
	}
	n.list = self.finish(m);
	self.expect_word("from")!;
	n.name = self.module_specifier()!.name;
	self.consume_semicolon()!;
	return n;
}

fn Node*? Parser.parse_export(&self)
{
	Token t = self.tok;
	self.advance()!;
	if (self.tok.kind == KW_DEFAULT)
	{
		self.advance()!;
		Node* n = self.node(EXPORT_DEFAULT, &t);
		Token at = self.tok;
		switch
		{
			case at.kind == KW_FUNCTION:
				n.a = self.parse_function(&at, false, false)!;
				n.a.flags.declaration = n.a.name.len > 0;
			case at.kind == KW_CLASS:
				n.a = self.parse_class(false)!;
				n.a.flags.declaration = n.a.name.len > 0;
			default:
				n.a = self.parse_assignment()!;
				self.consume_semicolon()!;
		}
		return n;
	}
	Node* n = self.node(EXPORT, &t);
	Token at = self.tok;
	switch
	{
		case at.kind == STAR:
			// export * from 'x': re-export everything x exports except its default.
			self.advance()!;
			if (self.at_word("as")) return self.fail("'export * as name' is not supported")~;
			self.expect_word("from")!;
			n.name = self.module_specifier()!.name;
			n.flags.delegate = true;
			self.consume_semicolon()!;
		case at.kind == LBRACE:
			self.advance()!;
			sz m = self.scratch.len();
			while (self.tok.kind != RBRACE)
			{
				Token it = self.tok;
				if (it.kind != IDENT && !it.kind.is_keyword()) return self.unexpected()~;
				Node* spec = self.node(EXPORT_SPEC, &it);
				spec.a = self.ident_from(&it);
				spec.name = it.text(self.src);
				self.advance()!;
				if (self.at_word("as"))
				{
					self.advance()!;
					if (self.tok.kind != IDENT && !self.tok.kind.is_keyword()) return self.unexpected()~;
					spec.name = self.text();
					self.advance()!;
				}
				self.scratch.push(spec);
				if (!self.eat(COMMA)!) break;
			}
			self.expect(RBRACE)!;
			n.list = self.finish(m);
			if (self.at_word("from"))
			{
				self.advance()!;
				n.name = self.module_specifier()!.name;
			}
			self.consume_semicolon()!;
		case at.kind == KW_CONST || self.at_word("let"):
			n.a = self.parse_declaration_statement()!;
		case at.kind == KW_FUNCTION:
			n.a = self.parse_function(&at, true, false)!;
		case at.kind == KW_CLASS:
			n.a = self.parse_class(true)!;
		case self.at_word("async"):
			self.advance()!;
			if (self.tok.kind != KW_FUNCTION) return self.unexpected()~;
			n.a = self.parse_function(&at, true, true)!;
		default:
			return self.unexpected()~;
	}
	return n;
}

// ---- functions and classes ----

<*
 A `function` declaration or expression; the current token is `function`.
*>
fn Node*? Parser.parse_function(&self, Token* start, bool declaration, bool is_async)
{
	Node* f = self.node(FUNCTION, start);
	f.flags.declaration = declaration;
	f.flags.is_async = is_async;
	self.expect(KW_FUNCTION)!;
	if (self.eat(STAR)!) f.flags.generator = true;
	if (self.tok.kind == IDENT)
	{
		f.name = self.text();
		self.advance()!;
	}
	else if (declaration)
	{
		return self.fail("a function declaration needs a name")~;
	}
	self.parse_function_rest(f)!;
	return f;
}

<*
 Parameters and body of a function, method or accessor whose flags are already set.
*>
fn void? Parser.parse_function_rest(&self, Node* f)
{
	bool was_function = self.in_function;
	bool was_async = self.in_async;
	bool was_generator = self.in_generator;
	defer
	{
		self.in_function = was_function;
		self.in_async = was_async;
		self.in_generator = was_generator;
	}
	self.in_function = true;
	self.in_async = f.flags.is_async;
	self.in_generator = f.flags.generator;
	f.list = self.parse_params()!;
	f.a = self.parse_block()!;
	f.end = self.prev.end;
}

fn Node*[]? Parser.parse_params(&self)
{
	self.expect(LPAREN)!;
	sz m = self.scratch.len();
	while (self.tok.kind != RPAREN)
	{
		if (self.tok.kind == ELLIPSIS)
		{
			Token r = self.tok;
			self.advance()!;
			Node* rest = self.node(REST, &r);
			rest.a = self.parse_binding_target()!;
			self.scratch.push(rest);
			if (self.tok.kind != RPAREN) return self.fail("a rest parameter must be last")~;
			break;
		}
		self.scratch.push(self.parse_binding_element()!);
		if (!self.eat(COMMA)!) break;
	}
	self.expect(RPAREN)!;
	return self.finish(m);
}

<*
 An arrow function after its parameters; the current token is `=>`.
*>
fn Node*? Parser.parse_arrow(&self, Token* start, Node*[] params, bool is_async)
{
	Node* f = self.node(FUNCTION, start);
	f.flags.arrow = true;
	f.flags.is_async = is_async;
	f.list = params;
	self.expect(ARROW)!;
	bool was_function = self.in_function;
	bool was_async = self.in_async;
	bool was_generator = self.in_generator;
	defer
	{
		self.in_function = was_function;
		self.in_async = was_async;
		self.in_generator = was_generator;
	}
	self.in_function = true;
	self.in_async = is_async;
	self.in_generator = false;
	if (self.tok.kind == LBRACE)
	{
		f.a = self.parse_block()!;
	}
	else
	{
		f.flags.expression_body = true;
		f.a = self.parse_assignment()!;
	}
	f.end = self.prev.end;
	return f;
}

<*
 Turn the items of a parenthesised list or call into arrow parameters.
*>
fn Node*[]? Parser.to_params(&self, Node*[] items)
{
	foreach (i, &item : items)
	{
		if ((*item).kind == SPREAD)
		{
			if (i != items.len - 1) return self.fail("a rest parameter must be last")~;
			(*item).kind = REST;
			(*item).a = self.to_pattern((*item).a, true)!;
			continue;
		}
		*item = self.to_pattern(*item, true)!;
	}
	return items;
}

fn Node*? Parser.parse_class(&self, bool declaration)
{
	Token t = self.tok;
	self.advance()!;
	Node* c = self.node(CLASS, &t);
	c.flags.declaration = declaration;
	if (self.tok.kind == IDENT)
	{
		c.name = self.text();
		self.advance()!;
	}
	else if (declaration)
	{
		return self.fail("a class declaration needs a name")~;
	}
	if (self.eat(KW_EXTENDS)!) c.a = self.parse_call_member()!;
	self.expect(LBRACE)!;
	sz m = self.scratch.len();
	while (self.tok.kind != RBRACE)
	{
		if (self.eat(SEMICOLON)!) continue;
		if (self.tok.kind == EOF) return self.fail("expected '}' but found end of input")~;
		self.scratch.push(self.parse_class_member()!);
	}
	c.list = self.finish(m);
	self.advance()!;
	c.end = self.prev.end;
	return c;
}

<*
 Read `get`, `set`, `async` and `*` before a member name. The word is a modifier only when a name follows it.
*>
fn void? Parser.parse_member_modifiers(&self, Node* p)
{
	if (self.tok.kind == IDENT)
	{
		String word = self.text();
		if (word == "get" || word == "set" || word == "async")
		{
			Token next = self.peek()!;
			bool is_async = word == "async";
			if ((starts_property_key(next.kind) || (is_async && next.kind == STAR)) && !(is_async && next.nl_before))
			{
				self.advance()!;
				switch (word)
				{
					case "get": p.flags.getter = true;
					case "set": p.flags.setter = true;
					default: p.flags.is_async = true;
				}
			}
		}
	}
	if (self.tok.kind == STAR && !p.flags.getter && !p.flags.setter)
	{
		self.advance()!;
		p.flags.generator = true;
	}
}

fn Node*? Parser.parse_property_key(&self, Node* p)
{
	Token t = self.tok;
	switch (t.kind)
	{
		case LBRACKET:
			self.advance()!;
			p.flags.computed = true;
			Node* key = self.parse_assignment()!;
			self.expect(RBRACKET)!;
			return key;
		case STRING:
		case NUMBER:
			return self.parse_primary();
		case HASH:
			return self.fail("private '#' members are not supported")~;
		default:
			if (t.kind != IDENT && !t.kind.is_keyword()) return self.unexpected()~;
			self.advance()!;
			return self.ident_from(&t);
	}
}

<*
 The method function for property p, whose key has just been read.
*>
fn Node*? Parser.parse_method(&self, Node* p)
{
	Token at = self.tok;
	Node* f = self.node(FUNCTION, &at);
	// A method's source text starts at its name (and modifiers), as in `get x() { ... }`.
	f.start = p.start;
	f.flags.is_async = p.flags.is_async;
	f.flags.generator = p.flags.generator;
	if (!p.flags.computed) f.name = p.a.name;
	p.flags.method = true;
	f.flags.method = true;
	f.flags.getter = p.flags.getter;
	f.flags.setter = p.flags.setter;
	self.parse_function_rest(f)!;
	return f;
}

fn Node*? Parser.parse_class_member(&self)
{
	Token t = self.tok;
	Node* p = self.node(PROPERTY, &t);
	if (self.at_word("static"))
	{
		Token next = self.peek()!;
		if (next.kind == LBRACE) return self.fail("static blocks are not supported")~;
		if (next.kind != LPAREN && next.kind != ASSIGN && next.kind != SEMICOLON && next.kind != RBRACE)
		{
			self.advance()!;
			p.flags.is_static = true;
			// A static method's source text starts after `static`, as V8 prints it.
			p.start = self.tok.start;
		}
	}
	self.parse_member_modifiers(p)!;
	p.a = self.parse_property_key(p)!;
	if (self.tok.kind == LPAREN || p.flags.getter || p.flags.setter || p.flags.is_async || p.flags.generator)
	{
		p.b = self.parse_method(p)!;
		return p;
	}
	// A field: its initializer runs like a method body, with `this` the instance.
	p.flags.field = true;
	if (self.eat(ASSIGN)!)
	{
		bool was_function = self.in_function;
		bool was_async = self.in_async;
		bool was_generator = self.in_generator;
		self.in_function = true;
		self.in_async = false;
		self.in_generator = false;
		Node*? init = self.parse_assignment();
		self.in_function = was_function;
		self.in_async = was_async;
		self.in_generator = was_generator;
		p.b = init!;
	}
	self.consume_semicolon()!;
	return p;
}

// ---- patterns ----

fn Node*? Parser.parse_binding_ident(&self)
{
	Token t = self.tok;
	if (t.kind != IDENT)
	{
		if (t.kind.is_keyword()) return self.fail(string::bformat(&self.error_buf, "'%s' is a reserved word", self.describe(&t)))~;
		return self.unexpected()~;
	}
	String name = t.text(self.src);
	if (name == "let" || name == "yield" || (name == "await" && (self.in_async || self.is_module)))
	{
		return self.fail(string::bformat(&self.error_buf, "'%s' cannot be a variable name", name))~;
	}
	self.advance()!;
	return self.ident_from(&t);
}

fn Node*? Parser.parse_binding_target(&self)
{
	switch (self.tok.kind)
	{
		case LBRACKET: return self.parse_array_binding();
		case LBRACE: return self.parse_object_binding();
		default: return self.parse_binding_ident();
	}
}

fn Node*? Parser.parse_binding_element(&self)
{
	Node* target = self.parse_binding_target()!;
	if (self.tok.kind != ASSIGN) return target;
	self.advance()!;
	Node* p = self.node_at(ASSIGN_PATTERN, target);
	p.a = target;
	p.b = self.parse_assignment()!;
	return p;
}

fn Node*? Parser.parse_array_binding(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(ARRAY_PATTERN, &t);
	sz m = self.scratch.len();
	while (self.tok.kind != RBRACKET)
	{
		Token at = self.tok;
		if (at.kind == COMMA)
		{
			self.advance()!;
			self.scratch.push(self.node(HOLE, &at));
			continue;
		}
		if (at.kind == ELLIPSIS)
		{
			self.advance()!;
			Node* rest = self.node(REST, &at);
			rest.a = self.parse_binding_target()!;
			self.scratch.push(rest);
			if (self.tok.kind != RBRACKET) return self.fail("a rest element must be last")~;
			break;
		}
		self.scratch.push(self.parse_binding_element()!);
		if (self.tok.kind != RBRACKET) self.expect(COMMA)!;
	}
	self.expect(RBRACKET)!;
	n.list = self.finish(m);
	return n;
}

fn Node*? Parser.parse_object_binding(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(OBJECT_PATTERN, &t);
	sz m = self.scratch.len();
	while (self.tok.kind != RBRACE)
	{
		Token at = self.tok;
		if (at.kind == ELLIPSIS)
		{
			self.advance()!;
			Node* rest = self.node(REST, &at);
			rest.a = self.parse_binding_ident()!;
			self.scratch.push(rest);
			if (self.tok.kind != RBRACE) return self.fail("a rest element must be last")~;
			break;
		}
		Node* p = self.node(PROPERTY, &at);
		p.a = self.parse_property_key(p)!;
		if (self.eat(COLON)!)
		{
			p.b = self.parse_binding_element()!;
		}
		else
		{
			if (at.kind != IDENT) return self.fail_at(&at, "expected ':' after a property name in a pattern")~;
			p.flags.shorthand = true;
			self.tok = at;
			self.lx.state = at.at;
			self.advance()!;
			Node* target = self.parse_binding_ident()!;
			if (self.tok.kind == ASSIGN)
			{
				self.advance()!;
				Node* d = self.node_at(ASSIGN_PATTERN, target);
				d.a = target;
				d.b = self.parse_assignment()!;
				p.b = d;
			}
			else
			{
				p.b = target;
			}
		}
		self.scratch.push(p);
		if (self.tok.kind != RBRACE) self.expect(COMMA)!;
	}
	self.expect(RBRACE)!;
	n.list = self.finish(m);
	return n;
}

<*
 Reinterpret an expression as an assignment target. binding is true for parameters, which allow names only.
*>
fn Node*? Parser.to_pattern(&self, Node* e, bool binding)
{
	switch (e.kind)
	{
		case IDENT:
			return e;
		case MEMBER:
			if (binding) break;
			return e;
		case ARRAY:
			if (e.flags.parenthesized) break;
			e.kind = ARRAY_PATTERN;
			foreach (i, &el : e.list)
			{
				Node* item = *el;
				if (item.kind == HOLE) continue;
				if (item.kind == SPREAD)
				{
					if (i != e.list.len - 1) return self.fail_at_node(item, "a rest element must be last")~;
					item.kind = REST;
					item.a = self.to_pattern(item.a, binding)!;
					continue;
				}
				*el = self.to_pattern(item, binding)!;
			}
			return e;
		case OBJECT:
			if (e.flags.parenthesized) break;
			e.kind = OBJECT_PATTERN;
			foreach (i, prop : e.list)
			{
				if (prop.kind == SPREAD)
				{
					if (i != e.list.len - 1) return self.fail_at_node(prop, "a rest element must be last")~;
					prop.kind = REST;
					prop.a = self.to_pattern(prop.a, binding)!;
					continue;
				}
				if (prop.flags.method) return self.fail_at_node(prop, "a method cannot be a destructuring target")~;
				if (prop.flags.cover_init)
				{
					prop.flags.cover_init = false;
					self.cover_inits--;
				}
				prop.b = self.to_pattern(prop.b, binding)!;
			}
			return e;
		case ASSIGN:
			if (e.op != ASSIGN || e.flags.parenthesized) break;
			e.kind = ASSIGN_PATTERN;
			e.a = self.to_pattern(e.a, binding)!;
			return e;
		case ASSIGN_PATTERN:
		case ARRAY_PATTERN:
		case OBJECT_PATTERN:
			return e;
		default:
			break;
	}
	return self.fail_at_node(e, binding ? "invalid parameter" : "invalid assignment target")~;
}

fn fault Parser.fail_at_node(&self, Node* n, String message)
{
	self.error = message;
	self.error_line = n.line;
	self.error_col = n.col;
	return lex::SYNTAX;
}

// ---- expressions ----

fn Node*? Parser.parse_expression(&self, bool no_in = false)
{
	Node* e = self.parse_assignment(no_in)!;
	if (self.tok.kind != COMMA) return e;
	sz m = self.scratch.len();
	self.scratch.push(e);
	while (self.eat(COMMA)!) self.scratch.push(self.parse_assignment(no_in)!);
	Node* s = self.node_at(SEQUENCE, e);
	s.list = self.finish(m);
	return s;
}

fn Node*? Parser.parse_assignment(&self, bool no_in = false)
{
	if (self.in_generator && self.at_word("yield")) return self.parse_yield(no_in);
	Node* left = self.parse_conditional(no_in)!;
	if (is_bare_arrow(left)) return left;
	TokenKind op = self.tok.kind;
	if (!op.is_assign()) return left;
	Token op_tok = self.tok;
	self.advance()!;
	Node* n = self.node_at(ASSIGN, left);
	n.op = op;
	if (op == ASSIGN)
	{
		n.a = self.to_pattern(left, false)!;
	}
	else
	{
		if (left.kind != IDENT && left.kind != MEMBER) return self.fail_at(&op_tok, "invalid assignment target")~;
		n.a = left;
	}
	n.b = self.parse_assignment(no_in)!;
	return n;
}

fn Node*? Parser.parse_yield(&self, bool no_in)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(YIELD, &t);
	if (self.tok.nl_before) return n;
	if (self.tok.kind == STAR)
	{
		self.advance()!;
		n.flags.delegate = true;
		n.a = self.parse_assignment(no_in)!;
		return n;
	}
	if (!ends_expression(self.tok.kind) && !(no_in && self.tok.kind == KW_IN)) n.a = self.parse_assignment(no_in)!;
	return n;
}

fn Node*? Parser.parse_conditional(&self, bool no_in)
{
	Node* test = self.parse_binary(0, no_in)!;
	if (self.tok.kind != QUESTION || is_bare_arrow(test)) return test;
	self.advance()!;
	Node* n = self.node_at(CONDITIONAL, test);
	n.a = test;
	n.b = self.parse_assignment()!;
	self.expect(COLON)!;
	n.c = self.parse_assignment(no_in)!;
	return n;
}

fn int binary_precedence(TokenKind k, bool no_in)
{
	switch (k)
	{
		case QUESTION_QUESTION: return 1;
		case PIPE_PIPE: return 2;
		case AMP_AMP: return 3;
		case PIPE: return 4;
		case CARET: return 5;
		case AMP: return 6;
		case EQ:
		case NE:
		case EQ_STRICT:
		case NE_STRICT:
			return 7;
		case LT:
		case GT:
		case LE:
		case GE:
		case KW_INSTANCEOF:
			return 8;
		case KW_IN:
			return no_in ? 0 : 8;
		case SHL:
		case SAR:
		case SHR:
			return 9;
		case PLUS:
		case MINUS:
			return 10;
		case STAR:
		case SLASH:
		case PERCENT:
			return 11;
		case STAR_STAR:
			return 12;
		default:
			return 0;
	}
}

<*
 Precedence climbing: consumes binary operators that bind tighter than min_prec.
*>
fn Node*? Parser.parse_binary(&self, int min_prec, bool no_in)
{
	Node* left = self.parse_unary()!;
	if (is_bare_arrow(left)) return left;
	while (true)
	{
		TokenKind op = self.tok.kind;
		int prec = binary_precedence(op, no_in);
		if (prec <= min_prec) break;
		if (op == STAR_STAR && left.kind == UNARY && !left.flags.parenthesized)
		{
			return self.fail("parenthesize the unary expression before '**'")~;
		}
		self.advance()!;
		// '**' is right-associative, so its right side may hold another '**'.
		Node* right = self.parse_binary(op == STAR_STAR ? prec - 1 : prec, no_in)!;
		bool logical = op == AMP_AMP || op == PIPE_PIPE || op == QUESTION_QUESTION;
		Node* n = self.node_at(logical ? LOGICAL : BINARY, left);
		n.op = op;
		n.a = left;
		n.b = right;
		left = n;
	}
	return left;
}

fn Node*? Parser.check_update_target(&self, Node* target)
{
	if (target.kind != IDENT && target.kind != MEMBER) return self.fail_at_node(target, "invalid increment or decrement target")~;
	return target;
}

fn Node*? Parser.parse_unary(&self)
{
	Token t = self.tok;
	switch (t.kind)
	{
		case BANG:
		case TILDE:
		case PLUS:
		case MINUS:
		case KW_TYPEOF:
		case KW_VOID:
		case KW_DELETE:
			self.advance()!;
			Node* n = self.node(UNARY, &t);
			n.op = t.kind;
			n.a = self.parse_unary()!;
			return n;
		case PLUS_PLUS:
		case MINUS_MINUS:
			self.advance()!;
			Node* n = self.node(UPDATE, &t);
			n.op = t.kind;
			n.flags.prefix = true;
			n.a = self.check_update_target(self.parse_unary()!)!;
			return n;
		case IDENT:
			if (self.at_word("await") && (self.in_async || (self.is_module && !self.in_function)))
			{
				self.advance()!;
				Node* n = self.node(AWAIT, &t);
				n.a = self.parse_unary()!;
				return n;
			}
		default:
			break;
	}
	Node* e = self.parse_call_member()!;
	if (is_bare_arrow(e)) return e;
	if ((self.tok.kind == PLUS_PLUS || self.tok.kind == MINUS_MINUS) && !self.tok.nl_before)
	{
		Node* n = self.node_at(UPDATE, e);
		n.op = self.tok.kind;
		n.a = self.check_update_target(e)!;
		self.advance()!;
		return n;
	}
	return e;
}

fn Node*? Parser.parse_call_member(&self)
{
	Node* e = self.tok.kind == KW_NEW ? self.parse_new()! : self.parse_primary()!;
	if (is_bare_arrow(e)) return e;
	return self.parse_suffixes(e, true);
}

fn Node*? Parser.parse_new(&self)
{
	Token t = self.tok;
	self.advance()!;
	if (self.tok.kind == DOT)
	{
		self.advance()!;
		self.expect_word("target")!;
		if (!self.in_function) return self.fail_at(&t, "'new.target' outside of a function")~;
		return self.node(NEW_TARGET, &t);
	}
	Node* callee = self.tok.kind == KW_NEW ? self.parse_new()! : self.parse_primary()!;
	callee = self.parse_suffixes(callee, false)!;
	Node* n = self.node(NEW, &t);
	n.a = callee;
	if (self.tok.kind == LPAREN) n.list = self.parse_arguments()!;
	return n;
}

fn Node*? Parser.member_name(&self, Node* object, bool optional)
{
	Token t = self.tok;
	if (t.kind == HASH) return self.fail("private '#' members are not supported")~;
	if (t.kind != IDENT && !t.kind.is_keyword()) return self.unexpected()~;
	self.advance()!;
	Node* n = self.node_at(MEMBER, object);
	n.a = object;
	n.name = t.text(self.src);
	n.flags.optional = optional;
	return n;
}

fn Node*? Parser.computed_member(&self, Node* object, bool optional)
{
	self.expect(LBRACKET)!;
	Node* n = self.node_at(MEMBER, object);
	n.a = object;
	n.b = self.parse_expression()!;
	n.flags.computed = true;
	n.flags.optional = optional;
	self.expect(RBRACKET)!;
	return n;
}

<*
 Member accesses, calls and `?.` after a primary. allow_call is false for the callee of `new`.
*>
fn Node*? Parser.parse_suffixes(&self, Node* e, bool allow_call)
{
	bool chain = false;
	while LOOP: (true)
	{
		switch (self.tok.kind)
		{
			case DOT:
				self.advance()!;
				e = self.member_name(e, false)!;
			case QUESTION_DOT:
				if (!allow_call) return self.fail("optional chaining is not allowed in a 'new' callee")~;
				self.advance()!;
				chain = true;
				switch (self.tok.kind)
				{
					case LPAREN:
						Node* call = self.node_at(CALL, e);
						call.a = e;
						call.flags.optional = true;
						call.list = self.parse_arguments()!;
						e = call;
					case LBRACKET:
						e = self.computed_member(e, true)!;
					default:
						e = self.member_name(e, true)!;
				}
			case LBRACKET:
				e = self.computed_member(e, false)!;
			case LPAREN:
				if (!allow_call) break LOOP;
				Node* call = self.node_at(CALL, e);
				call.a = e;
				call.list = self.parse_arguments()!;
				e = call;
			case TEMPLATE:
			case TEMPLATE_HEAD:
				return self.fail("tagged templates are not supported")~;
			default:
				break LOOP;
		}
	}
	if (!chain) return e;
	Node* wrap = self.node_at(OPTIONAL_CHAIN, e);
	wrap.a = e;
	return wrap;
}

fn Node*[]? Parser.parse_arguments(&self)
{
	self.expect(LPAREN)!;
	sz m = self.scratch.len();
	while (self.tok.kind != RPAREN)
	{
		Token t = self.tok;
		if (t.kind == ELLIPSIS)
		{
			self.advance()!;
			Node* s = self.node(SPREAD, &t);
			s.a = self.parse_assignment()!;
			self.scratch.push(s);
		}
		else
		{
			self.scratch.push(self.parse_assignment()!);
		}
		if (!self.eat(COMMA)!) break;
	}
	self.expect(RPAREN)!;
	return self.finish(m);
}

fn Node*? Parser.parse_primary(&self)
{
	Token t = self.tok;
	switch (t.kind)
	{
		case NUMBER:
			self.advance()!;
			Node* n = self.node(NUMBER, &t);
			n.name = t.text(self.src);
			n.number = t.number;
			return n;
		case STRING:
			self.advance()!;
			Node* n = self.node(STRING, &t);
			n.name = t.raw(self.src);
			n.flags.escaped = t.escaped;
			n.flags.single_quote = self.src[t.start] == '\'';
			return n;
		case TEMPLATE:
		case TEMPLATE_HEAD:
			return self.parse_template();
		case SLASH:
		case SLASH_ASSIGN:
			Token? re = self.lx.rescan_regex(&t);
			if (catch re) return self.lex_failed()~;
			self.tok = re;
			self.advance()!;
			Node* n = self.node(REGEX, &re);
			n.name = re.text(self.src);
			return n;
		case IDENT:
			if (self.at_word("async"))
			{
				Token next = self.peek()!;
				if (!next.nl_before && (next.kind == KW_FUNCTION || next.kind == IDENT || next.kind == LPAREN)) return self.parse_async(&t, next.kind);
			}
			self.advance()!;
			if (self.tok.kind == ARROW && !self.tok.nl_before)
			{
				self.tok = t;
				self.lx.state = t.at;
				self.advance()!;
				Node* param = self.parse_binding_ident()!;
				return self.parse_arrow(&t, self.one(param), false);
			}
			return self.ident_from(&t);
		case KW_THIS:
			self.advance()!;
			return self.node(THIS, &t);
		case KW_NULL:
			self.advance()!;
			return self.node(NULL, &t);
		case KW_TRUE:
			self.advance()!;
			return self.node(TRUE, &t);
		case KW_FALSE:
			self.advance()!;
			return self.node(FALSE, &t);
		case KW_SUPER:
			self.advance()!;
			if (self.tok.kind != LPAREN && self.tok.kind != DOT && self.tok.kind != LBRACKET)
			{
				return self.fail_at(&t, "'super' must be called or have a property read")~;
			}
			return self.node(SUPER, &t);
		case LPAREN:
			return self.parse_parenthesized();
		case LBRACKET:
			return self.parse_array_literal();
		case LBRACE:
			return self.parse_object_literal();
		case KW_FUNCTION:
			return self.parse_function(&t, false, false);
		case KW_CLASS:
			return self.parse_class(false);
		case KW_NEW:
			return self.parse_new();
		case HASH:
			return self.fail("private '#' members are not supported")~;
		default:
			return self.unexpected()~;
	}
}

<*
 After `async`: an async function, an async arrow, or a call to something named async.
*>
fn Node*? Parser.parse_async(&self, Token* start, TokenKind next)
{
	self.advance()!;
	switch (next)
	{
		case KW_FUNCTION:
			return self.parse_function(start, false, true);
		case IDENT:
			Node* param = self.parse_binding_ident()!;
			if (self.tok.kind != ARROW) return self.unexpected()~;
			return self.parse_arrow(start, self.one(param), true);
		default:
			Node*[] args = self.parse_arguments()!;
			if (self.tok.kind == ARROW && !self.tok.nl_before) return self.parse_arrow(start, self.to_params(args)!, true);
			Node* call = self.node(CALL, start);
			call.a = self.ident_from(start);
			call.list = args;
			return call;
	}
}

<*
 `( ... )`: a parenthesised expression, or the parameters of an arrow function.
*>
fn Node*? Parser.parse_parenthesized(&self)
{
	Token t = self.tok;
	self.advance()!;
	sz m = self.scratch.len();
	bool trailing_comma = false;
	while (self.tok.kind != RPAREN)
	{
		Token at = self.tok;
		if (at.kind == ELLIPSIS)
		{
			self.advance()!;
			Node* s = self.node(SPREAD, &at);
			s.a = self.parse_binding_target()!;
			self.scratch.push(s);
			break;
		}
		self.scratch.push(self.parse_assignment()!);
		if (!self.eat(COMMA)!) break;
		if (self.tok.kind == RPAREN) trailing_comma = true;
	}
	self.expect(RPAREN)!;
	Node*[] items = self.finish(m);
	if (self.tok.kind == ARROW && !self.tok.nl_before) return self.parse_arrow(&t, self.to_params(items)!, false);
	if (items.len == 0 || trailing_comma || items[^1].kind == SPREAD) return self.fail_at(&t, "invalid parenthesized expression")~;
	Node* e;
	if (items.len == 1)
	{
		e = items[0];
	}
	else
	{
		e = self.node_at(SEQUENCE, items[0]);
		e.list = items;
	}
	e.flags.parenthesized = true;
	return e;
}

fn Node*? Parser.parse_template(&self)
{
	Token t = self.tok;
	Node* n = self.node(TEMPLATE, &t);
	sz m = self.scratch.len();
	self.scratch.push(self.template_part(&t));
	self.advance()!;
	if (t.kind == TEMPLATE)
	{
		n.list = self.finish(m);
		return n;
	}
	while (true)
	{
		self.scratch.push(self.parse_expression()!);
		Token p = self.tok;
		if (p.kind != TEMPLATE_MIDDLE && p.kind != TEMPLATE_TAIL) return self.fail("expected '}' to close a template substitution")~;
		self.scratch.push(self.template_part(&p));
		self.advance()!;
		if (p.kind == TEMPLATE_TAIL) break;
	}
	n.list = self.finish(m);
	return n;
}

fn Node* Parser.template_part(&self, Token* t)
{
	Node* part = self.node(TEMPLATE_PART, t);
	part.name = t.raw(self.src);
	part.flags.escaped = t.escaped;
	return part;
}

fn Node*? Parser.parse_array_literal(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(ARRAY, &t);
	sz m = self.scratch.len();
	while (self.tok.kind != RBRACKET)
	{
		Token at = self.tok;
		if (at.kind == COMMA)
		{
			self.advance()!;
			self.scratch.push(self.node(HOLE, &at));
			continue;
		}
		if (at.kind == ELLIPSIS)
		{
			self.advance()!;
			Node* s = self.node(SPREAD, &at);
			s.a = self.parse_assignment()!;
			self.scratch.push(s);
		}
		else
		{
			self.scratch.push(self.parse_assignment()!);
		}
		if (self.tok.kind != RBRACKET) self.expect(COMMA)!;
	}
	self.advance()!;
	n.list = self.finish(m);
	return n;
}

fn Node*? Parser.parse_object_literal(&self)
{
	Token t = self.tok;
	self.advance()!;
	Node* n = self.node(OBJECT, &t);
	sz m = self.scratch.len();
	while (self.tok.kind != RBRACE)
	{
		self.scratch.push(self.parse_object_member()!);
		if (self.tok.kind != RBRACE) self.expect(COMMA)!;
	}
	self.advance()!;
	n.list = self.finish(m);
	return n;
}

fn Node*? Parser.parse_object_member(&self)
{
	Token t = self.tok;
	if (t.kind == ELLIPSIS)
	{
		self.advance()!;
		Node* s = self.node(SPREAD, &t);
		s.a = self.parse_assignment()!;
		return s;
	}
	Node* p = self.node(PROPERTY, &t);
	self.parse_member_modifiers(p)!;
	Token key_tok = self.tok;
	p.a = self.parse_property_key(p)!;
	if (self.tok.kind == LPAREN || p.flags.getter || p.flags.setter || p.flags.is_async || p.flags.generator)
	{
		p.b = self.parse_method(p)!;
		return p;
	}
	if (self.eat(COLON)!)
	{
		p.b = self.parse_assignment()!;
		return p;
	}
	if (key_tok.kind != IDENT || p.flags.computed) return self.unexpected()~;
	p.flags.shorthand = true;
	Node* value = self.ident_from(&key_tok);
	if (self.tok.kind == ASSIGN)
	{
		Token eq = self.tok;
		self.advance()!;
		Node* d = self.node_at(ASSIGN, value);
		d.op = ASSIGN;
		d.a = value;
		d.b = self.parse_assignment()!;
		p.b = d;
		p.flags.cover_init = true;
		if (self.cover_inits++ == 0) self.cover_init_tok = eq;
		return p;
	}
	p.b = value;
	return p;
}
