module fastjs::lex;

excuse SYNTAX;

const uint MAX_TEMPLATE_DEPTH = 32;

enum TokenKind : char (String text)
{
	EOF { "end of input" },
	IDENT { "identifier" },
	NUMBER { "number" },
	STRING { "string" },
	TEMPLATE { "template" },
	TEMPLATE_HEAD { "template head" },
	TEMPLATE_MIDDLE { "template middle" },
	TEMPLATE_TAIL { "template tail" },
	REGEX { "regular expression" },

	KW_BREAK { "break" },
	KW_CASE { "case" },
	KW_CATCH { "catch" },
	KW_CLASS { "class" },
	KW_CONST { "const" },
	KW_CONTINUE { "continue" },
	KW_DEBUGGER { "debugger" },
	KW_DEFAULT { "default" },
	KW_DELETE { "delete" },
	KW_DO { "do" },
	KW_ELSE { "else" },
	KW_EXPORT { "export" },
	KW_EXTENDS { "extends" },
	KW_FALSE { "false" },
	KW_FINALLY { "finally" },
	KW_FOR { "for" },
	KW_FUNCTION { "function" },
	KW_IF { "if" },
	KW_IMPORT { "import" },
	KW_IN { "in" },
	KW_INSTANCEOF { "instanceof" },
	KW_NEW { "new" },
	KW_NULL { "null" },
	KW_RETURN { "return" },
	KW_SUPER { "super" },
	KW_SWITCH { "switch" },
	KW_THIS { "this" },
	KW_THROW { "throw" },
	KW_TRUE { "true" },
	KW_TRY { "try" },
	KW_TYPEOF { "typeof" },
	KW_VAR { "var" },
	KW_VOID { "void" },
	KW_WHILE { "while" },
	KW_WITH { "with" },

	LBRACE { "{" },
	RBRACE { "}" },
	LPAREN { "(" },
	RPAREN { ")" },
	LBRACKET { "[" },
	RBRACKET { "]" },
	SEMICOLON { ";" },
	COMMA { "," },
	DOT { "." },
	ELLIPSIS { "..." },
	QUESTION { "?" },
	QUESTION_DOT { "?." },
	COLON { ":" },
	ARROW { "=>" },
	HASH { "#" },
	AT { "@" },

	LT { "<" },
	GT { ">" },
	LE { "<=" },
	GE { ">=" },
	EQ { "==" },
	NE { "!=" },
	EQ_STRICT { "===" },
	NE_STRICT { "!==" },

	PLUS { "+" },
	MINUS { "-" },
	STAR { "*" },
	SLASH { "/" },
	PERCENT { "%" },
	STAR_STAR { "**" },
	PLUS_PLUS { "++" },
	MINUS_MINUS { "--" },
	SHL { "<<" },
	SAR { ">>" },
	SHR { ">>>" },
	AMP { "&" },
	PIPE { "|" },
	CARET { "^" },
	BANG { "!" },
	TILDE { "~" },
	AMP_AMP { "&&" },
	PIPE_PIPE { "||" },
	QUESTION_QUESTION { "??" },

	ASSIGN { "=" },
	PLUS_ASSIGN { "+=" },
	MINUS_ASSIGN { "-=" },
	STAR_ASSIGN { "*=" },
	SLASH_ASSIGN { "/=" },
	PERCENT_ASSIGN { "%=" },
	STAR_STAR_ASSIGN { "**=" },
	SHL_ASSIGN { "<<=" },
	SAR_ASSIGN { ">>=" },
	SHR_ASSIGN { ">>>=" },
	AMP_ASSIGN { "&=" },
	PIPE_ASSIGN { "|=" },
	CARET_ASSIGN { "^=" },
	AMP_AMP_ASSIGN { "&&=" },
	PIPE_PIPE_ASSIGN { "||=" },
	QUESTION_QUESTION_ASSIGN { "??=" },
}

<*
 Where the lexer is. Saved in every token so the parser can rewind and rescan a '/' as a regex.
*>
struct LexState
{
	uint pos;
	uint line;
	uint line_start;
	uint brace_depth;
	uint template_len;
}

struct Token
{
	TokenKind kind;
	// A line break comes before this token; automatic semicolon insertion needs it.
	bool nl_before;
	// A string or template piece containing backslash escapes, so it must be cooked.
	bool escaped;
	// A template piece with an escape that is no escape, e.g. `\unicode`: an error, except in
	// a tagged template, where that piece's cooked string is undefined.
	bool bad_escape;
	uint start;
	uint end;
	uint line;
	uint col;
	double number;
	LexState at;
}

struct Lexer
{
	inline LexState state;
	String src;
	// Brace depth at each open `${`, so a '}' at that depth resumes the template.
	uint[MAX_TEMPLATE_DEPTH] template_stack;
	String error;
	uint error_line;
	uint error_col;
	uint first_line;
}

<*
 Start lexing src. The lexer borrows src; it must outlive every token.

 @param first_line : "The line number of src's first line; 0 when a host wrapper line precedes the real source"
 @require src.len < uint::max : "Source too large"
*>
fn void Lexer.init(&self, String src, uint first_line = 1)
{
	*self = { .src = src, .line = first_line, .first_line = first_line };
}

fn bool TokenKind.is_keyword(self) => self.ordinal >= TokenKind.KW_BREAK.ordinal && self.ordinal <= TokenKind.KW_WITH.ordinal;
fn bool TokenKind.is_assign(self) => self.ordinal >= TokenKind.ASSIGN.ordinal && self.ordinal <= TokenKind.QUESTION_QUESTION_ASSIGN.ordinal;

fn bool TokenKind.is_template(self) => self == TEMPLATE || self == TEMPLATE_HEAD || self == TEMPLATE_MIDDLE || self == TEMPLATE_TAIL;

<*
 The source text of a token.
*>
fn String Token.text(&self, String src) => src[self.start:self.end - self.start];

<*
 The raw characters of a string or template token, without its delimiters.

 @require self.kind == STRING || self.kind.is_template() : "Not a string or template token"
*>
fn String Token.raw(&self, String src)
{
	uint open = 1;
	uint close = self.kind == TEMPLATE_HEAD || self.kind == TEMPLATE_MIDDLE ? 2 : 1;
	return src[self.start + open:self.end - self.start - open - close];
}

<*
 The pattern and flags of a regex token.

 @require self.kind == REGEX : "Not a regex token"
*>
fn void Token.regex_parts(&self, String src, String* pattern, String* flags)
{
	String all = self.text(src);
	usz slash = all.len - 1;
	while (all[slash] != '/') slash--;
	*pattern = all[1:slash - 1];
	*flags = all[slash + 1..];
}

<*
 Record a syntax error; the caller returns it with `return self.fail(...)~`.
*>
fn fault Lexer.fail(&self, uint at, String message)
{
	// Recounted from the start: `at` may sit lines before the current position.
	uint line = self.first_line;
	uint line_start = 0;
	for (uint i = 0; i < at; i++)
	{
		char c = self.src[i];
		if (c == '\n' || (c == '\r' && ((usz)i + 1 >= self.src.len || self.src[i + 1] != '\n')))
		{
			line++;
			line_start = i + 1;
		}
	}
	self.error = message;
	self.error_line = line;
	self.error_col = at - line_start + 1;
	return SYNTAX;
}

fn char Lexer.peek(&self, uint ahead = 0) @inline
{
	usz at = (usz)self.pos + ahead;
	return at < self.src.len ? self.src[at] : 0;
}

fn void Lexer.newline(&self, uint next_pos) @inline
{
	self.line++;
	self.line_start = next_pos;
}

// U+2028 and U+2029 are line terminators in JS.
fn bool Lexer.at_unicode_newline(&self)
{
	return self.peek() == 0xE2 && self.peek(1) == 0x80 && (self.peek(2) == 0xA8 || self.peek(2) == 0xA9);
}

fn bool is_ident_start(char c) @inline => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c >= 0x80;
fn bool is_ident_part(char c) @inline => is_ident_start(c) || (c >= '0' && c <= '9');
fn bool is_digit(char c) @inline => c >= '0' && c <= '9';

fn int hex_value(char c) @private
{
	switch
	{
		case c >= '0' && c <= '9': return c - '0';
		case c >= 'a' && c <= 'f': return c - 'a' + 10;
		case c >= 'A' && c <= 'F': return c - 'A' + 10;
		default: return -1;
	}
}

<*
 Skip whitespace and comments.

 @return? SYNTAX
 @return "Whether a line break was crossed"
*>
fn bool? Lexer.skip_trivia(&self)
{
	bool nl = false;
	if (self.pos == 0 && self.peek() == '#' && self.peek(1) == '!')
	{
		while (self.pos < self.src.len && self.peek() != '\n') self.pos++;
	}
	while (self.pos < self.src.len)
	{
		char c = self.peek();
		switch (c)
		{
			case ' ':
			case '\t':
			case '\v':
			case '\f':
				self.pos++;
			case '\r':
				self.pos++;
				if (self.peek() == '\n') self.pos++;
				self.newline(self.pos);
				nl = true;
			case '\n':
				self.pos++;
				self.newline(self.pos);
				nl = true;
			case '/':
				switch (self.peek(1))
				{
					case '/':
						while (self.pos < self.src.len && self.peek() != '\n' && self.peek() != '\r') self.pos++;
					case '*':
						uint open = self.pos;
						self.pos += 2;
						while (true)
						{
							if (self.pos >= self.src.len)
							{
								self.pos = open;
								return self.fail(open, "unterminated comment")~;
							}
							char d = self.peek();
							if (d == '*' && self.peek(1) == '/')
							{
								self.pos += 2;
								break;
							}
							self.pos++;
							if (d == '\n' || (d == '\r' && self.peek() != '\n'))
							{
								self.newline(self.pos);
								nl = true;
							}
						}
					default:
						return nl;
				}
			case 0xC2:
				// No-break space.
				if (self.peek(1) != 0xA0) return nl;
				self.pos += 2;
			case 0xEF:
				// Byte order mark.
				if (self.peek(1) != 0xBB || self.peek(2) != 0xBF) return nl;
				self.pos += 3;
			case 0xE2:
				if (!self.at_unicode_newline()) return nl;
				self.pos += 3;
				self.newline(self.pos);
				nl = true;
			default:
				return nl;
		}
	}
	return nl;
}

<*
 The next token.

 @return? SYNTAX
*>
fn Token? Lexer.next(&self)
{
	bool nl = self.skip_trivia()!;
	Token tok = { .nl_before = nl, .start = self.pos, .line = self.line, .col = self.pos - self.line_start + 1, .at = self.state };
	if (self.pos >= self.src.len)
	{
		tok.kind = EOF;
		tok.end = self.pos;
		return tok;
	}
	char c = self.peek();
	switch
	{
		case is_ident_start(c):
			if (c == 0xE2 && self.at_unicode_newline()) return self.fail(self.pos, "unexpected line separator")~;
			self.scan_ident(&tok)!;
		case is_digit(c) || (c == '.' && is_digit(self.peek(1))):
			self.scan_number(&tok)!;
		case c == '"' || c == '\'':
			self.scan_string(&tok)!;
		case c == '`':
			self.pos++;
			self.scan_template(&tok, true)!;
		case c == '}' && self.template_len > 0 && self.template_stack[self.template_len - 1] == self.brace_depth:
			self.pos++;
			self.scan_template(&tok, false)!;
		default:
			self.scan_punct(&tok)!;
	}
	tok.end = self.pos;
	return tok;
}

<*
 Re-lex a '/' or '/=' token as a regex literal. The parser calls this in prefix position.

 @param [&in] tok : "The slash token to rescan"
 @require tok.kind == SLASH || tok.kind == SLASH_ASSIGN : "Only a slash can start a regex"
 @return? SYNTAX
*>
fn Token? Lexer.rescan_regex(&self, Token* tok)
{
	self.state = tok.at;
	Token re = *tok;
	re.kind = REGEX;
	uint i = self.pos + 1;
	bool in_class = false;
	while SCAN: (true)
	{
		if (i >= self.src.len) return self.fail(self.pos, "unterminated regular expression")~;
		char c = self.src[i];
		switch (c)
		{
			case '\n':
			case '\r':
				return self.fail(self.pos, "unterminated regular expression")~;
			case '\\':
				i += 2;
				continue;
			case '[':
				in_class = true;
			case ']':
				in_class = false;
			case '/':
				if (!in_class) break SCAN;
		}
		i++;
	}
	i++;
	while (i < self.src.len && is_ident_part(self.src[i])) i++;
	self.pos = i;
	re.end = i;
	return re;
}

fn void? Lexer.scan_ident(&self, Token* tok)
{
	uint start = self.pos;
	while (self.pos < self.src.len)
	{
		char c = self.peek();
		if (c == '\\') return self.fail(self.pos, "unicode escapes in identifiers are not supported")~;
		if (!is_ident_part(c)) break;
		// U+2028/2029 end the identifier; they are line terminators.
		if (c == 0xE2 && self.at_unicode_newline()) break;
		self.pos++;
	}
	tok.kind = keyword(self.src[start:self.pos - start]);
}

<*
 The keyword kind of an identifier, or IDENT. Contextual words like `let` and `async` are IDENT.
*>
fn TokenKind keyword(String s)
{
	switch (s)
	{
		case "break": return KW_BREAK;
		case "case": return KW_CASE;
		case "catch": return KW_CATCH;
		case "class": return KW_CLASS;
		case "const": return KW_CONST;
		case "continue": return KW_CONTINUE;
		case "debugger": return KW_DEBUGGER;
		case "default": return KW_DEFAULT;
		case "delete": return KW_DELETE;
		case "do": return KW_DO;
		case "else": return KW_ELSE;
		case "export": return KW_EXPORT;
		case "extends": return KW_EXTENDS;
		case "false": return KW_FALSE;
		case "finally": return KW_FINALLY;
		case "for": return KW_FOR;
		case "function": return KW_FUNCTION;
		case "if": return KW_IF;
		case "import": return KW_IMPORT;
		case "in": return KW_IN;
		case "instanceof": return KW_INSTANCEOF;
		case "new": return KW_NEW;
		case "null": return KW_NULL;
		case "return": return KW_RETURN;
		case "super": return KW_SUPER;
		case "switch": return KW_SWITCH;
		case "this": return KW_THIS;
		case "throw": return KW_THROW;
		case "true": return KW_TRUE;
		case "try": return KW_TRY;
		case "typeof": return KW_TYPEOF;
		case "var": return KW_VAR;
		case "void": return KW_VOID;
		case "while": return KW_WHILE;
		case "with": return KW_WITH;
		default: return IDENT;
	}
}

fn void? Lexer.scan_number(&self, Token* tok)
{
	uint start = self.pos;
	tok.kind = NUMBER;
	char c = self.peek();
	char radix_char = self.peek(1) | 0x20;
	if (c == '0' && (radix_char == 'x' || radix_char == 'b' || radix_char == 'o'))
	{
		int radix = radix_char == 'x' ? 16 : radix_char == 'b' ? 2 : 8;
		self.pos += 2;
		double value = 0;
		uint digits = 0;
		while (true)
		{
			char d = self.peek();
			if (d == '_' && digits > 0 && hex_value(self.peek(1)) >= 0)
			{
				self.pos++;
				continue;
			}
			int v = hex_value(d);
			if (v < 0 || v >= radix) break;
			// Exact up to 2^53, which covers every literal three.c3 writes.
			value = value * radix + v;
			digits++;
			self.pos++;
		}
		if (digits == 0) return self.fail(start, "missing digits after number prefix")~;
		tok.number = value;
		return self.check_number_end(start);
	}
	if (c == '0' && is_digit(self.peek(1))) return self.fail(start, "legacy octal literals are not supported")~;

	bool underscores = false;
	self.skip_digits(&underscores);
	if (self.peek() == '.')
	{
		self.pos++;
		self.skip_digits(&underscores);
	}
	char e = self.peek() | 0x20;
	if (e == 'e')
	{
		uint mark = self.pos;
		self.pos++;
		if (self.peek() == '+' || self.peek() == '-') self.pos++;
		if (!is_digit(self.peek())) return self.fail(mark, "missing exponent digits")~;
		self.skip_digits(&underscores);
	}
	String text = self.src[start:self.pos - start];
	char[64] buf;
	if (underscores)
	{
		usz n = 0;
		foreach (ch : text)
		{
			if (ch == '_') continue;
			if (n == buf.len) return self.fail(start, "number literal too long")~;
			buf[n++] = ch;
		}
		text = (String)buf[:n];
	}
	if (try value = text.to_double())
	{
		tok.number = value;
		return self.check_number_end(start);
	}
	return self.fail(start, "malformed number")~;
}

fn void Lexer.skip_digits(&self, bool* underscores)
{
	while (true)
	{
		char d = self.peek();
		if (is_digit(d))
		{
			self.pos++;
			continue;
		}
		if (d == '_' && is_digit(self.peek(1)) && self.pos > 0 && is_digit(self.src[self.pos - 1]))
		{
			*underscores = true;
			self.pos++;
			continue;
		}
		return;
	}
}

fn void? Lexer.check_number_end(&self, uint start)
{
	char c = self.peek();
	if (c == 'n') return self.fail(start, "BigInt is not supported")~;
	if (is_ident_start(c) || is_digit(c)) return self.fail(self.pos, "identifier directly after number")~;
}

<*
 Check one escape sequence. On entry pos is at the backslash; on exit it is past the escape.
*>
fn void? Lexer.scan_escape(&self)
{
	uint at = self.pos;
	self.pos++;
	if (self.pos >= self.src.len) return self.fail(at, "unterminated escape")~;
	char c = self.peek();
	switch (c)
	{
		case 'x':
			if (hex_value(self.peek(1)) < 0 || hex_value(self.peek(2)) < 0) return self.fail(at, "malformed \\x escape")~;
			self.pos += 3;
		case 'u':
			self.pos++;
			if (self.peek() == '{')
			{
				self.pos++;
				uint value = 0;
				uint digits = 0;
				while (hex_value(self.peek()) >= 0)
				{
					value = value * 16 + (uint)hex_value(self.peek());
					if (value > 0x10FFFF) return self.fail(at, "code point out of range")~;
					digits++;
					self.pos++;
				}
				if (digits == 0 || self.peek() != '}') return self.fail(at, "malformed \\u{} escape")~;
				self.pos++;
				return;
			}
			for (int i = 0; i < 4; i++)
			{
				if (hex_value(self.peek()) < 0) return self.fail(at, "malformed \\u escape")~;
				self.pos++;
			}
		case '0':
			if (is_digit(self.peek(1))) return self.fail(at, "octal escapes are not supported")~;
			self.pos++;
		case '1'..'9':
			return self.fail(at, "octal escapes are not supported")~;
		case '\r':
			self.pos++;
			if (self.peek() == '\n') self.pos++;
			self.newline(self.pos);
		case '\n':
			self.pos++;
			self.newline(self.pos);
		default:
			// Any other character escapes to itself; UTF-8 continuation bytes follow as ordinary text.
			self.pos++;
	}
}

fn void? Lexer.scan_string(&self, Token* tok)
{
	uint start = self.pos;
	char quote = self.peek();
	tok.kind = STRING;
	self.pos++;
	while (true)
	{
		if (self.pos >= self.src.len) return self.fail(start, "unterminated string")~;
		char c = self.peek();
		if (c == quote)
		{
			self.pos++;
			return;
		}
		switch (c)
		{
			case '\\':
				tok.escaped = true;
				self.scan_escape()!;
			case '\n':
			case '\r':
				return self.fail(start, "unterminated string")~;
			default:
				self.pos++;
		}
	}
}

<*
 Scan template characters up to '`' or '${'. pos is just past the opening '`' or '}'.
*>
fn void? Lexer.scan_template(&self, Token* tok, bool opening)
{
	uint start = tok.start;
	while (true)
	{
		if (self.pos >= self.src.len) return self.fail(start, "unterminated template")~;
		char c = self.peek();
		switch (c)
		{
			case '`':
				self.pos++;
				if (opening)
				{
					tok.kind = TEMPLATE;
				}
				else
				{
					tok.kind = TEMPLATE_TAIL;
					self.template_len--;
				}
				return;
			case '$':
				if (self.peek(1) != '{')
				{
					self.pos++;
					continue;
				}
				self.pos += 2;
				if (opening)
				{
					if (self.template_len == MAX_TEMPLATE_DEPTH) return self.fail(start, "templates nested too deeply")~;
					self.template_stack[self.template_len++] = self.brace_depth;
					tok.kind = TEMPLATE_HEAD;
				}
				else
				{
					tok.kind = TEMPLATE_MIDDLE;
				}
				return;
			case '\\':
				tok.escaped = true;
				uint at = self.pos;
				if (catch self.scan_escape())
				{
					tok.bad_escape = true;
					self.pos = at + 2 <= (uint)self.src.len ? at + 2 : (uint)self.src.len;
				}
			case '\r':
				self.pos++;
				if (self.peek() == '\n') self.pos++;
				self.newline(self.pos);
			case '\n':
				self.pos++;
				self.newline(self.pos);
			default:
				self.pos++;
		}
	}
}

fn void? Lexer.scan_punct(&self, Token* tok)
{
	char c = self.peek();
	char c1 = self.peek(1);
	char c2 = self.peek(2);
	char c3 = self.peek(3);
	TokenKind kind;
	uint len = 1;
	switch (c)
	{
		case '{':
			kind = LBRACE;
			self.brace_depth++;
		case '}':
			kind = RBRACE;
			if (self.brace_depth > 0) self.brace_depth--;
		case '(': kind = LPAREN;
		case ')': kind = RPAREN;
		case '[': kind = LBRACKET;
		case ']': kind = RBRACKET;
		case ';': kind = SEMICOLON;
		case ',': kind = COMMA;
		case ':': kind = COLON;
		case '~': kind = TILDE;
		case '#': kind = HASH;
		case '@': kind = AT;
		case '.':
			if (c1 == '.' && c2 == '.')
			{
				kind = ELLIPSIS;
				len = 3;
			}
			else
			{
				kind = DOT;
			}
		case '?':
			switch
			{
				case c1 == '?' && c2 == '=': kind = QUESTION_QUESTION_ASSIGN; len = 3;
				case c1 == '?': kind = QUESTION_QUESTION; len = 2;
				// `a?.5:b` is a ternary, not optional chaining.
				case c1 == '.' && !is_digit(c2): kind = QUESTION_DOT; len = 2;
				default: kind = QUESTION;
			}
		case '=':
			switch
			{
				case c1 == '=' && c2 == '=': kind = EQ_STRICT; len = 3;
				case c1 == '=': kind = EQ; len = 2;
				case c1 == '>': kind = ARROW; len = 2;
				default: kind = ASSIGN;
			}
		case '!':
			switch
			{
				case c1 == '=' && c2 == '=': kind = NE_STRICT; len = 3;
				case c1 == '=': kind = NE; len = 2;
				default: kind = BANG;
			}
		case '<':
			switch
			{
				case c1 == '<' && c2 == '=': kind = SHL_ASSIGN; len = 3;
				case c1 == '<': kind = SHL; len = 2;
				case c1 == '=': kind = LE; len = 2;
				default: kind = LT;
			}
		case '>':
			switch
			{
				case c1 == '>' && c2 == '>' && c3 == '=': kind = SHR_ASSIGN; len = 4;
				case c1 == '>' && c2 == '>': kind = SHR; len = 3;
				case c1 == '>' && c2 == '=': kind = SAR_ASSIGN; len = 3;
				case c1 == '>': kind = SAR; len = 2;
				case c1 == '=': kind = GE; len = 2;
				default: kind = GT;
			}
		case '+':
			switch
			{
				case c1 == '+': kind = PLUS_PLUS; len = 2;
				case c1 == '=': kind = PLUS_ASSIGN; len = 2;
				default: kind = PLUS;
			}
		case '-':
			switch
			{
				case c1 == '-': kind = MINUS_MINUS; len = 2;
				case c1 == '=': kind = MINUS_ASSIGN; len = 2;
				default: kind = MINUS;
			}
		case '*':
			switch
			{
				case c1 == '*' && c2 == '=': kind = STAR_STAR_ASSIGN; len = 3;
				case c1 == '*': kind = STAR_STAR; len = 2;
				case c1 == '=': kind = STAR_ASSIGN; len = 2;
				default: kind = STAR;
			}
		case '/':
			if (c1 == '=')
			{
				kind = SLASH_ASSIGN;
				len = 2;
			}
			else
			{
				kind = SLASH;
			}
		case '%':
			if (c1 == '=')
			{
				kind = PERCENT_ASSIGN;
				len = 2;
			}
			else
			{
				kind = PERCENT;
			}
		case '&':
			switch
			{
				case c1 == '&' && c2 == '=': kind = AMP_AMP_ASSIGN; len = 3;
				case c1 == '&': kind = AMP_AMP; len = 2;
				case c1 == '=': kind = AMP_ASSIGN; len = 2;
				default: kind = AMP;
			}
		case '|':
			switch
			{
				case c1 == '|' && c2 == '=': kind = PIPE_PIPE_ASSIGN; len = 3;
				case c1 == '|': kind = PIPE_PIPE; len = 2;
				case c1 == '=': kind = PIPE_ASSIGN; len = 2;
				default: kind = PIPE;
			}
		case '^':
			if (c1 == '=')
			{
				kind = CARET_ASSIGN;
				len = 2;
			}
			else
			{
				kind = CARET;
			}
		default:
			return self.fail(self.pos, "unexpected character")~;
	}
	tok.kind = kind;
	self.pos += len;
}
