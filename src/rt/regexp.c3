module fastjs::rt;
import std::collections::list, std::core::dstring;

// Regular expressions: a recursive-descent parser builds a small tree, which compiles to
// instructions for a backtracking matcher with an explicit stack (no C recursion per character,
// so long inputs can't overflow the C stack). A step budget stops catastrophic patterns.

excuse REGEX_SYNTAX;

const uint REGEX_STEP_LIMIT = 50_000_000;
const uint REGEX_MAX_REPEAT = 1000;

enum ReOp : char
{
	CHAR,
	ANY,
	CLASS,
	SPLIT,      // try x, backtrack to y
	JMP,
	SAVE,       // capture slot x = position
	MATCH,
	BOL,
	EOL,
	WORDB,
	NWORDB,
	BACKREF,    // group x
	LOOK,       // lookahead sub-program follows; x = its end; flag = negative
	LOOKEND,
	MARK,       // mark x = position (start of a loop iteration)
	PROGRESS,   // fail if the loop body since MARK x consumed nothing
}

struct ReInst
{
	ReOp op;
	bool flag;
	uint x;
	uint y;
}

struct ReRange
{
	uint lo;
	uint hi;
}

struct ReClass
{
	List {ReRange} ranges;
	bool negate;
}

struct Regex
{
	List {ReInst} code;
	List {ReClass} classes;
	List {String} group_names;
	uint ngroups;
	uint nmarks;
	bool icase;
	bool multiline;
	bool dotall;
	bool global;
	bool sticky;
	bool unicode;
}

fn void Regex.free(&self)
{
	self.code.free();
	foreach (&c : self.classes) c.ranges.free();
	self.classes.free();
	foreach (n : self.group_names) free(n);
	self.group_names.free();
}

// ---- parsing ----

enum ReNodeKind : char
{
	SEQ,
	ALT,
	CHAR,
	ANY,
	CLASS,
	GROUP,
	LOOK,
	REPEAT,
	ASSERT,
	BACKREF,
}

struct ReNode
{
	ReNodeKind kind;
	List {ReNode*} items;
	ReNode* child;
	uint value;
	int group;
	uint min;
	uint max;
	bool greedy;
	bool negative;
	ReOp assertion;
}

struct ReParser
{
	ushort[] src;
	usz pos;
	Regex* re;
	String error;
}

fn ReNode* ReParser.node(&self, ReNodeKind kind)
{
	ReNode* n = mem::tnew(ReNode);
	n.kind = kind;
	n.items.tinit();
	return n;
}

fn bool ReParser.at_end(&self) => self.pos >= self.src.len;
fn uint ReParser.peek(&self) => self.pos < self.src.len ? self.src[self.pos] : 0;

fn fault ReParser.fail(&self, String message)
{
	self.error = message;
	return REGEX_SYNTAX;
}

fn ReNode*? ReParser.disjunction(&self)
{
	ReNode* first = self.alternative()!;
	if (self.peek() != '|' || self.at_end()) return first;
	ReNode* alt = self.node(ALT);
	alt.items.push(first);
	while (!self.at_end() && self.peek() == '|')
	{
		self.pos++;
		alt.items.push(self.alternative()!);
	}
	return alt;
}

fn ReNode*? ReParser.alternative(&self)
{
	ReNode* seq = self.node(SEQ);
	while (!self.at_end() && self.peek() != '|' && self.peek() != ')') seq.items.push(self.term()!);
	return seq;
}

fn bool is_digit_unit(uint c) => c >= '0' && c <= '9';

fn uint? ReParser.number(&self)
{
	if (!is_digit_unit(self.peek())) return self.fail("expected a number in a quantifier")~;
	uint v = 0;
	while (is_digit_unit(self.peek()))
	{
		v = v * 10 + (self.peek() - '0');
		if (v > 100000) v = 100000;
		self.pos++;
	}
	return v;
}

fn ReNode*? ReParser.term(&self)
{
	uint c = self.peek();
	switch (c)
	{
		case '^':
			self.pos++;
			ReNode* n = self.node(ASSERT);
			n.assertion = BOL;
			return n;
		case '$':
			self.pos++;
			ReNode* n = self.node(ASSERT);
			n.assertion = EOL;
			return n;
		case '\\':
			if (self.pos + 1 < self.src.len && (self.src[self.pos + 1] == 'b' || self.src[self.pos + 1] == 'B'))
			{
				ReNode* n = self.node(ASSERT);
				n.assertion = self.src[self.pos + 1] == 'b' ? WORDB : NWORDB;
				self.pos += 2;
				return n;
			}
		default:
			break;
	}
	ReNode* atom = self.atom()!;
	if (atom.kind == LOOK) return atom;
	uint min;
	uint max;
	switch (self.peek())
	{
		case '*': min = 0; max = uint::max; self.pos++;
		case '+': min = 1; max = uint::max; self.pos++;
		case '?': min = 0; max = 1; self.pos++;
		case '{':
			usz save = self.pos;
			self.pos++;
			if (!is_digit_unit(self.peek()))
			{
				// Not a quantifier: a literal '{'.
				self.pos = save;
				return atom;
			}
			min = self.number()!;
			max = min;
			if (self.peek() == ',')
			{
				self.pos++;
				max = self.peek() == '}' ? uint::max : self.number()!;
			}
			if (self.peek() != '}') return self.fail("incomplete quantifier")~;
			self.pos++;
			if (max < min) return self.fail("numbers out of order in {} quantifier")~;
		default:
			return atom;
	}
	ReNode* rep = self.node(REPEAT);
	rep.child = atom;
	rep.min = min;
	rep.max = max;
	rep.greedy = true;
	if (self.peek() == '?' && !self.at_end())
	{
		rep.greedy = false;
		self.pos++;
	}
	if (min > REGEX_MAX_REPEAT || (max != uint::max && max > REGEX_MAX_REPEAT)) return self.fail("quantifier too large")~;
	return rep;
}

fn ReNode*? ReParser.atom(&self)
{
	uint c = self.peek();
	self.pos++;
	switch (c)
	{
		case '.':
			return self.node(ANY);
		case '(':
			if (self.peek() == '?')
			{
				self.pos++;
				uint kind = self.peek();
				self.pos++;
				switch (kind)
				{
					case ':':
						ReNode* inner = self.disjunction()!;
						if (self.peek() != ')') return self.fail("unterminated group")~;
						self.pos++;
						return inner;
					case '=':
					case '!':
						ReNode* look = self.node(LOOK);
						look.negative = kind == '!';
						look.child = self.disjunction()!;
						if (self.peek() != ')') return self.fail("unterminated group")~;
						self.pos++;
						return look;
					case '<':
						if (self.peek() == '=' || self.peek() == '!') return self.fail("lookbehind is not supported")~;
						DString name;
						name.init(mem);
						while (!self.at_end() && self.peek() != '>')
						{
							append_code_point(&name, self.peek());
							self.pos++;
						}
						if (self.at_end()) return self.fail("unterminated group name")~;
						self.pos++;
						ReNode* g = self.node(GROUP);
						g.group = (int)++self.re.ngroups;
						while (self.re.group_names.len() < (sz)self.re.ngroups - 1) self.re.group_names.push("".copy(mem));
						self.re.group_names.push(name.copy_str(mem));
						name.free();
						g.child = self.disjunction()!;
						if (self.peek() != ')') return self.fail("unterminated group")~;
						self.pos++;
						return g;
					default:
						return self.fail("invalid group")~;
				}
			}
			ReNode* g = self.node(GROUP);
			g.group = (int)++self.re.ngroups;
			g.child = self.disjunction()!;
			if (self.peek() != ')' || self.at_end()) return self.fail("unterminated group")~;
			self.pos++;
			return g;
		case ')':
			return self.fail("unmatched ')'")~;
		case '[':
			return self.class_atom();
		case '\\':
			return self.escape_atom();
		case '*':
		case '+':
		case '?':
			return self.fail("nothing to repeat")~;
		default:
			ReNode* n = self.node(CHAR);
			n.value = c;
			return n;
	}
}

<*
 A class escape (\d \w \s and negations) as ranges added to cls; false if c isn't one.
*>
fn bool add_class_escape(ReClass* cls, uint c)
{
	switch (c)
	{
		case 'd':
			cls.ranges.push({ '0', '9' });
		case 'w':
			cls.ranges.push({ 'a', 'z' });
			cls.ranges.push({ 'A', 'Z' });
			cls.ranges.push({ '0', '9' });
			cls.ranges.push({ '_', '_' });
		case 's':
			foreach (r : (ReRange[10]){ { 9, 13 }, { ' ', ' ' }, { 0xA0, 0xA0 }, { 0x1680, 0x1680 }, { 0x2000, 0x200A }, { 0x2028, 0x2029 }, { 0x202F, 0x202F }, { 0x205F, 0x205F }, { 0x3000, 0x3000 }, { 0xFEFF, 0xFEFF } })
			{
				cls.ranges.push(r);
			}
		case 'D':
			cls.ranges.push({ 0, '0' - 1 });
			cls.ranges.push({ '9' + 1, 0xFFFF });
		case 'W':
			cls.ranges.push({ 0, '0' - 1 });
			cls.ranges.push({ '9' + 1, 'A' - 1 });
			cls.ranges.push({ 'Z' + 1, '_' - 1 });
			cls.ranges.push({ '_' + 1, 'a' - 1 });
			cls.ranges.push({ 'z' + 1, 0xFFFF });
		case 'S':
			cls.ranges.push({ 0, 8 });
			cls.ranges.push({ 14, ' ' - 1 });
			cls.ranges.push({ ' ' + 1, 0x9F });
			cls.ranges.push({ 0xA1, 0x167F });
			cls.ranges.push({ 0x1681, 0x1FFF });
			cls.ranges.push({ 0x200B, 0x2027 });
			cls.ranges.push({ 0x202A, 0x202E });
			cls.ranges.push({ 0x2030, 0x205E });
			cls.ranges.push({ 0x2060, 0x2FFF });
			cls.ranges.push({ 0x3001, 0xFEFE });
			cls.ranges.push({ 0xFF00, 0xFFFF });
		default:
			return false;
	}
	return true;
}

<*
 The character a simple escape stands for (\n, \t, \x41, A, \/ ...).
*>
fn uint? ReParser.escape_char(&self, uint c)
{
	switch (c)
	{
		case 'n': return '\n';
		case 't': return '\t';
		case 'r': return '\r';
		case 'f': return 12;
		case 'v': return 11;
		case '0': return 0;
		case 'x':
			if (self.pos + 2 > self.src.len) return self.fail("invalid escape")~;
			int h = hex_digit((char)self.src[self.pos]);
			int l = hex_digit((char)self.src[self.pos + 1]);
			if (h < 0 || l < 0) return self.fail("invalid escape")~;
			self.pos += 2;
			return (uint)(h * 16 + l);
		case 'u':
			if (self.peek() == '{')
			{
				self.pos++;
				uint v = 0;
				while (!self.at_end() && self.peek() != '}')
				{
					int d = hex_digit((char)self.peek());
					if (d < 0) return self.fail("invalid unicode escape")~;
					v = v * 16 + (uint)d;
					self.pos++;
				}
				self.pos++;
				return v;
			}
			if (self.pos + 4 > self.src.len) return self.fail("invalid unicode escape")~;
			uint v = 0;
			for (int i = 0; i < 4; i++)
			{
				int d = hex_digit((char)self.src[self.pos++]);
				if (d < 0) return self.fail("invalid unicode escape")~;
				v = v * 16 + (uint)d;
			}
			return v;
		case 'c':
			uint letter = self.peek();
			self.pos++;
			return letter % 32;
		default:
			return c;
	}
}

fn ReNode*? ReParser.escape_atom(&self)
{
	if (self.at_end()) return self.fail("\\ at end of pattern")~;
	uint c = self.peek();
	self.pos++;
	if (c >= '1' && c <= '9')
	{
		uint n = c - '0';
		while (is_digit_unit(self.peek()))
		{
			n = n * 10 + (self.peek() - '0');
			self.pos++;
		}
		ReNode* b = self.node(BACKREF);
		b.value = n;
		return b;
	}
	ReClass cls;
	cls.ranges.init(mem);
	if (add_class_escape(&cls, c))
	{
		ReNode* n = self.node(CLASS);
		n.value = (uint)self.re.classes.len();
		self.re.classes.push(cls);
		return n;
	}
	cls.ranges.free();
	ReNode* n = self.node(CHAR);
	n.value = self.escape_char(c)!;
	return n;
}

fn ReNode*? ReParser.class_atom(&self)
{
	ReClass cls;
	cls.ranges.init(mem);
	defer (catch err) cls.ranges.free();
	if (self.peek() == '^')
	{
		cls.negate = true;
		self.pos++;
	}
	bool first = true;
	while (true)
	{
		if (self.at_end()) return self.fail("unterminated character class")~;
		uint c = self.peek();
		if (c == ']' && !first)
		{
			self.pos++;
			break;
		}
		if (c == ']' && first)
		{
			// [] matches nothing, [^] anything.
			self.pos++;
			break;
		}
		first = false;
		self.pos++;
		uint lo;
		if (c == '\\')
		{
			if (self.at_end()) return self.fail("\\ at end of pattern")~;
			uint e = self.peek();
			self.pos++;
			if (add_class_escape(&cls, e)) continue;
			lo = e == 'b' ? 8 : self.escape_char(e)!;
		}
		else
		{
			lo = c;
		}
		uint hi = lo;
		if (self.peek() == '-' && self.pos + 1 < self.src.len && self.src[self.pos + 1] != ']')
		{
			self.pos++;
			uint d = self.peek();
			self.pos++;
			if (d == '\\')
			{
				uint e = self.peek();
				self.pos++;
				hi = e == 'b' ? 8 : self.escape_char(e)!;
			}
			else
			{
				hi = d;
			}
			if (hi < lo) return self.fail("range out of order in character class")~;
		}
		cls.ranges.push({ lo, hi });
	}
	ReNode* n = self.node(CLASS);
	n.value = (uint)self.re.classes.len();
	self.re.classes.push(cls);
	return n;
}

// ---- code generation ----

fn uint Regex.emit(&self, ReOp op, uint x = 0, uint y = 0, bool flag = false)
{
	self.code.push({ op, flag, x, y });
	return (uint)self.code.len() - 1;
}

fn void? Regex.compile_node(&self, ReNode* n)
{
	if (self.code.len() > 100_000) return REGEX_SYNTAX~;
	switch (n.kind)
	{
		case SEQ:
			foreach (item : n.items) self.compile_node(item)!;
		case ALT:
			List {uint} ends;
			ends.tinit();
			foreach (i, item : n.items)
			{
				if (i == n.items.len() - 1)
				{
					self.compile_node(item)!;
					break;
				}
				uint split = self.emit(SPLIT);
				self.code[split].x = (uint)self.code.len();
				self.compile_node(item)!;
				ends.push(self.emit(JMP));
				self.code[split].y = (uint)self.code.len();
			}
			foreach (e : ends) self.code[e].x = (uint)self.code.len();
		case CHAR:
			self.emit(CHAR, n.value);
		case ANY:
			self.emit(ANY);
		case CLASS:
			self.emit(CLASS, n.value);
		case GROUP:
			self.emit(SAVE, (uint)n.group * 2);
			self.compile_node(n.child)!;
			self.emit(SAVE, (uint)n.group * 2 + 1);
		case LOOK:
			uint look = self.emit(LOOK, 0, 0, n.negative);
			self.compile_node(n.child)!;
			self.emit(LOOKEND);
			self.code[look].x = (uint)self.code.len();
		case ASSERT:
			self.emit(n.assertion);
		case BACKREF:
			self.emit(BACKREF, n.value);
		case REPEAT:
			for (uint i = 0; i < n.min; i++) self.compile_node(n.child)!;
			if (n.max == uint::max)
			{
				uint mark = self.nmarks++;
				uint loop = self.emit(SPLIT);
				uint body = (uint)self.code.len();
				self.emit(MARK, mark);
				self.compile_node(n.child)!;
				self.emit(PROGRESS, mark);
				self.emit(JMP, loop);
				uint end = (uint)self.code.len();
				self.code[loop].x = n.greedy ? body : end;
				self.code[loop].y = n.greedy ? end : body;
				break;
			}
			List {uint} splits;
			splits.tinit();
			for (uint i = n.min; i < n.max; i++)
			{
				uint split = self.emit(SPLIT);
				splits.push(split);
				uint body = (uint)self.code.len();
				self.code[split].x = body;
				self.compile_node(n.child)!;
			}
			uint end = (uint)self.code.len();
			foreach (s : splits)
			{
				if (!n.greedy)
				{
					self.code[s].y = self.code[s].x;
					self.code[s].x = end;
					continue;
				}
				self.code[s].y = end;
			}
	}
}

<*
 Compile pattern with flags. On a syntax error, error says why.

 @return? REGEX_SYNTAX
*>
fn Regex*? regex_compile(ushort[] pattern, String flags, String* error)
{
	Regex* re = mem::new(Regex);
	re.code.init(mem);
	re.classes.init(mem);
	re.group_names.init(mem);
	defer (catch err)
	{
		re.free();
		free(re);
	}
	foreach (c : flags)
	{
		bool* flag;
		switch (c)
		{
			case 'g': flag = &re.global;
			case 'i': flag = &re.icase;
			case 'm': flag = &re.multiline;
			case 's': flag = &re.dotall;
			case 'y': flag = &re.sticky;
			case 'u': flag = &re.unicode;
			case 'd': continue;
			default:
				*error = "invalid flags";
				return REGEX_SYNTAX~;
		}
		if (*flag)
		{
			*error = "duplicate flag";
			return REGEX_SYNTAX~;
		}
		*flag = true;
	}
	@pool()
	{
		ReParser p = { .src = pattern, .re = re };
		ReNode*? root = p.disjunction();
		if (catch root)
		{
			*error = p.error;
			return REGEX_SYNTAX~;
		}
		if (!p.at_end())
		{
			*error = "unmatched ')'";
			return REGEX_SYNTAX~;
		}
		re.emit(SAVE, 0);
		if (catch re.compile_node(root))
		{
			*error = "pattern too large";
			return REGEX_SYNTAX~;
		}
		re.emit(SAVE, 1);
		re.emit(MATCH);
	};
	return re;
}

// ---- matching ----

fn bool is_line_terminator(uint c) => c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029;
fn bool is_word_unit(uint c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';

fn bool ReClass.contains(&self, uint c, bool icase)
{
	bool hit = false;
	foreach (r : self.ranges)
	{
		if (c >= r.lo && c <= r.hi)
		{
			hit = true;
			break;
		}
	}
	if (!hit && icase)
	{
		uint lower = to_lower_cp(c);
		uint upper = to_upper_cp(c);
		foreach (r : self.ranges)
		{
			if ((lower >= r.lo && lower <= r.hi) || (upper >= r.lo && upper <= r.hi))
			{
				hit = true;
				break;
			}
		}
	}
	return hit != self.negate;
}

enum BacktrackKind : char
{
	BRANCH,
	RESTORE_CAPTURE,
	RESTORE_MARK,
}

struct Backtrack
{
	BacktrackKind kind;
	uint pc;
	uint sp;
	int old;
}

struct Matcher
{
	Regex* re;
	JsString* s;
	int* caps;
	uint* marks;
	List {Backtrack} stack;
	uint steps;
	bool too_complex;
}

fn bool Matcher.same_unit(&self, uint a, uint b) @inline
{
	if (a == b) return true;
	return self.re.icase && to_lower_cp(a) == to_lower_cp(b);
}

<*
 Run the program from pc at position sp. Returns the end position on a match (at MATCH or, for
 a lookahead, at its LOOKEND), or -1.
*>
fn int Matcher.run(&self, uint start_pc, uint start_sp)
{
	sz base = self.stack.len();
	uint pc = start_pc;
	uint sp = start_sp;
	JsString* s = self.s;
	while LOOP: (true)
	{
		if (++self.steps > REGEX_STEP_LIMIT)
		{
			self.too_complex = true;
			self.stack.size = base;
			return -1;
		}
		ReInst ins = self.re.code[pc];
		bool ok = true;
		switch (ins.op)
		{
			case CHAR:
				ok = sp < s.len && self.same_unit(s.at(sp), ins.x);
				if (ok)
				{
					sp++;
					pc++;
				}
			case ANY:
				ok = sp < s.len && (self.re.dotall || !is_line_terminator(s.at(sp)));
				if (ok)
				{
					sp++;
					pc++;
				}
			case CLASS:
				ok = sp < s.len && self.re.classes[ins.x].contains(s.at(sp), self.re.icase);
				if (ok)
				{
					sp++;
					pc++;
				}
			case SPLIT:
				self.stack.push({ .kind = BRANCH, .pc = ins.y, .sp = sp });
				pc = ins.x;
			case JMP:
				pc = ins.x;
			case SAVE:
				self.stack.push({ .kind = RESTORE_CAPTURE, .pc = ins.x, .old = self.caps[ins.x] });
				self.caps[ins.x] = (int)sp;
				pc++;
			case MATCH:
			case LOOKEND:
				self.stack.size = base;
				return (int)sp;
			case BOL:
				ok = sp == 0 || (self.re.multiline && is_line_terminator(s.at(sp - 1)));
				pc++;
			case EOL:
				ok = sp == s.len || (self.re.multiline && is_line_terminator(s.at(sp)));
				pc++;
			case WORDB:
			case NWORDB:
				bool before = sp > 0 && is_word_unit(s.at(sp - 1));
				bool after = sp < s.len && is_word_unit(s.at(sp));
				ok = (before != after) == (ins.op == WORDB);
				pc++;
			case BACKREF:
				int from = ins.x * 2 + 1 < self.re.ngroups * 2 + 2 ? self.caps[ins.x * 2] : -1;
				int to = ins.x * 2 + 1 < self.re.ngroups * 2 + 2 ? self.caps[ins.x * 2 + 1] : -1;
				pc++;
				if (from < 0 || to < 0) break;
				uint len = (uint)(to - from);
				if (sp + len > s.len)
				{
					ok = false;
					break;
				}
				for (uint i = 0; i < len; i++)
				{
					if (!self.same_unit(s.at(sp + i), s.at((uint)from + i)))
					{
						ok = false;
						break;
					}
				}
				if (ok) sp += len;
			case LOOK:
				int end = self.run(pc + 1, sp);
				if (self.too_complex) return -1;
				ok = (end >= 0) != ins.flag;
				pc = ins.x;
			case MARK:
				self.stack.push({ .kind = RESTORE_MARK, .pc = ins.x, .old = (int)self.marks[ins.x] });
				self.marks[ins.x] = sp;
				pc++;
			case PROGRESS:
				ok = self.marks[ins.x] != sp;
				pc++;
		}
		if (ok) continue;
		// Backtrack: undo captures and marks back to the last branch, and take it.
		while (true)
		{
			if (self.stack.len() <= base) return -1;
			Backtrack b = self.stack.pop()!!;
			switch (b.kind)
			{
				case RESTORE_CAPTURE:
					self.caps[b.pc] = b.old;
				case RESTORE_MARK:
					self.marks[b.pc] = (uint)b.old;
				case BRANCH:
					pc = b.pc;
					sp = b.sp;
					continue LOOP;
			}
		}
	}
}

<*
 Find the first match at or after start (only at start when sticky). caps receives 2 slots per
 group, -1 where a group didn't take part.

 @return? THROWN
*>
fn bool? Vm.regex_exec(&self, Regex* re, JsString* s, uint start, int[] caps)
{
	uint* marks = mem::new_array(uint, re.nmarks ? re.nmarks : 1).ptr;
	defer free(marks);
	Matcher m = { .re = re, .s = s, .caps = caps.ptr, .marks = marks };
	m.stack.init(mem);
	defer m.stack.free();
	for (uint at = start; at <= s.len; at++)
	{
		foreach (&c : caps) *c = -1;
		int end = m.run(0, at);
		if (m.too_complex) return self.throw_error(RANGE_ERROR, "Regular expression too complex")~;
		if (end >= 0) return true;
		if (re.sticky) break;
	}
	return false;
}

// ---- RegExp objects ----

struct JsRegExp
{
	inline JsObject object;
	Value source;
	Value flags;
	// Shared and owned by the VM's cache.
	Regex* re;
}

fn void finalize_regexp(JsRegExp* re)
{
}

struct RegexCacheEntry
{
	JsString* pattern;
	JsString* flags;
	Regex* re;
}

<*
 A RegExp object for pattern and flags, compiling (or reusing) the program.

 @return? THROWN
*>
fn Value? Vm.new_regexp(&self, JsString* pattern, JsString* flags)
{
	pattern = self.heap.intern(pattern);
	flags = self.heap.intern(flags);
	Regex* re;
	foreach (e : self.regex_cache)
	{
		if (e.pattern == pattern && e.flags == flags) re = e.re;
	}
	if (!re)
	{
		@pool()
		{
			ushort[] units = mem::temp_array(ushort, pattern.len);
			for (uint i = 0; i < pattern.len; i++) units[i] = pattern.at(i);
			String error;
			Regex*? compiled = regex_compile(units, flags.tutf8(), &error);
			if (catch compiled) return self.throw_error(SYNTAX_ERROR, "Invalid regular expression: /%s/%s: %s", pattern.tutf8(), flags.tutf8(), error)~;
			re = compiled;
		};
		self.regex_cache.push({ pattern, flags, re });
	}
	JsRegExp* obj = (JsRegExp*)self.heap.new_object(self.regexp_proto, REGEXP, JsRegExp::size) ?? self.oom()~!;
	obj.source = string_value(pattern);
	obj.flags = string_value(flags);
	obj.re = re;
	obj.add(&self.heap, self.atoms.last_index, integer(0), { .writable = true }) ?? self.oom()~!;
	return object_value(obj);
}

fn JsRegExp*? Vm.this_regexp(&self, Value v, String method)
{
	if (v.is_object() && v.as_object().kind == REGEXP) return (JsRegExp*)v.as_object();
	return self.throw_error(TYPE_ERROR, "RegExp.prototype.%s called on incompatible receiver %s", method, self.describe(v))~;
}

<*
 RegExpBuiltinExec: match from lastIndex (for g and y), update lastIndex, and build the result
 array (with index, input and groups), or null.

 @return? THROWN
*>
fn Value? Vm.regexp_exec(&self, Value rx, JsString* s)
{
	JsRegExp* obj = (JsRegExp*)rx.as_object();
	Regex* re = obj.re;
	bool uses_last_index = re.global || re.sticky;
	uint start = 0;
	if (uses_last_index)
	{
		double li = self.to_number(self.get(rx, self.atoms.last_index)!)!;
		if (li > s.len)
		{
			self.set(rx, self.atoms.last_index, integer(0))!;
			return NULL;
		}
		start = li > 0 ? (uint)li : 0;
	}
	int[] caps = mem::new_array(int, (usz)(re.ngroups + 1) * 2);
	defer free(caps);
	if (!self.regex_exec(re, s, start, caps)!)
	{
		if (uses_last_index) self.set(rx, self.atoms.last_index, integer(0))!;
		return NULL;
	}
	if (uses_last_index) self.set(rx, self.atoms.last_index, integer(caps[1]))!;
	JsArray* result = self.new_js_array(re.ngroups + 1)!;
	for (uint g = 0; g <= re.ngroups; g++)
	{
		int from = caps[g * 2];
		int to = caps[g * 2 + 1];
		result.push(from < 0 || to < 0 ? UNDEFINED : string_value(self.heap.substring(s, (uint)from, (uint)to) ?? self.oom()~!));
	}
	result.add(&self.heap, self.atom_value("index")!, integer(caps[0])) ?? self.oom()~!;
	result.add(&self.heap, self.atom_value("input")!, string_value(s)) ?? self.oom()~!;
	Value groups = UNDEFINED;
	if (re.group_names.len())
	{
		JsObject* g = self.heap.new_object(null) ?? self.oom()~!;
		foreach (i, name : re.group_names)
		{
			if (name.len) g.add(&self.heap, self.atom_value(name)!, result.elements[i + 1]) ?? self.oom()~!;
		}
		groups = object_value(g);
	}
	result.add(&self.heap, self.atom_value("groups")!, groups) ?? self.oom()~!;
	return object_value(result);
}

fn Value? native_regexp(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value pattern = arg(args, 0);
	Value flags = arg(args, 1);
	JsString* source;
	JsString* flag_text;
	if (pattern.is_object() && pattern.as_object().kind == REGEXP)
	{
		JsRegExp* src = (JsRegExp*)pattern.as_object();
		source = src.source.as_string();
		flag_text = flags.is_undefined() ? src.flags.as_string() : vm.to_string(flags)!;
	}
	else
	{
		source = pattern.is_undefined() ? vm.heap.string_from_latin1("(?:)") ?? vm.oom()~! : vm.to_string(pattern)!;
		flag_text = flags.is_undefined() ? vm.atoms.empty.as_string() : vm.to_string(flags)!;
	}
	return vm.new_regexp(source, flag_text);
}

fn Value? native_regexp_exec(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	vm.this_regexp(this_value, "exec")!;
	return vm.regexp_exec(this_value, vm.to_string(arg(args, 0))!);
}

fn Value? native_regexp_test(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	vm.this_regexp(this_value, "test")!;
	return boolean(!vm.regexp_exec(this_value, vm.to_string(arg(args, 0))!)!.is_null());
}

fn Value? native_regexp_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsRegExp* re = vm.this_regexp(this_value, "toString")!;
	@pool()
	{
		return vm.str_value(string::tformat("/%s/%s", re.source.as_string().tutf8(), re.flags.as_string().tutf8()));
	};
}

fn Value? native_regexp_source(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => vm.this_regexp(this_value, "source")!.source;
fn Value? native_regexp_flags(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => vm.this_regexp(this_value, "flags")!.flags;

fn Value? native_regexp_flag(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Regex* re = vm.this_regexp(this_value, "flag")!.re;
	switch (callee.magic)
	{
		case 0: return boolean(re.global);
		case 1: return boolean(re.icase);
		case 2: return boolean(re.multiline);
		case 3: return boolean(re.sticky);
		case 4: return boolean(re.unicode);
		default: return boolean(re.dotall);
	}
}

// ---- String methods with regex arguments ----

fn uint advance_index(JsString* s, uint i, bool unicode)
{
	if (unicode && i + 1 < s.len && s.at(i) >= 0xD800 && s.at(i) <= 0xDBFF) return i + 2;
	return i + 1;
}

fn Value? native_string_match(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	Value rx = arg(args, 0);
	if (!rx.is_object() || rx.as_object().kind != REGEXP) rx = vm.new_regexp(rx.is_undefined() ? vm.atoms.empty.as_string() : vm.to_string(rx)!, vm.atoms.empty.as_string())!;
	JsRegExp* obj = (JsRegExp*)rx.as_object();
	if (!obj.re.global) return vm.regexp_exec(rx, s);
	vm.set(rx, vm.atoms.last_index, integer(0))!;
	JsArray* out = vm.new_js_array()!;
	while (true)
	{
		Value m = vm.regexp_exec(rx, s)!;
		if (m.is_null()) break;
		Value text = vm.get(m, integer(0))!;
		out.push(text);
		if (text.as_string().len == 0)
		{
			uint li = (uint)vm.to_number(vm.get(rx, vm.atoms.last_index)!)!;
			vm.set(rx, vm.atoms.last_index, integer((int)advance_index(s, li, obj.re.unicode)))!;
		}
	}
	return out.length ? object_value(out) : NULL;
}

fn Value? native_string_match_all(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	Value rx = arg(args, 0);
	if (!rx.is_object() || rx.as_object().kind != REGEXP)
	{
		rx = vm.new_regexp(vm.to_string(rx)!, vm.heap.string_from_latin1("g") ?? vm.oom()~!)!;
	}
	else if (!((JsRegExp*)rx.as_object()).re.global)
	{
		return vm.throw_error(TYPE_ERROR, "String.prototype.matchAll called with a non-global RegExp argument")~;
	}
	else
	{
		JsRegExp* src = (JsRegExp*)rx.as_object();
		rx = vm.new_regexp(src.source.as_string(), src.flags.as_string())!;
	}
	JsArray* out = vm.new_js_array()!;
	while (true)
	{
		Value m = vm.regexp_exec(rx, s)!;
		if (m.is_null()) break;
		out.push(m);
		if (vm.get(m, integer(0))!.as_string().len == 0)
		{
			uint li = (uint)vm.to_number(vm.get(rx, vm.atoms.last_index)!)!;
			vm.set(rx, vm.atoms.last_index, integer((int)li + 1))!;
		}
	}
	return vm.new_iterator(object_value(out), ARRAY_VALUES);
}

fn Value? native_string_search(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsString* s = vm.this_string(this_value)!;
	Value rx = arg(args, 0);
	if (!rx.is_object() || rx.as_object().kind != REGEXP) rx = vm.new_regexp(vm.to_string(rx)!, vm.atoms.empty.as_string())!;
	Regex* re = ((JsRegExp*)rx.as_object()).re;
	int[] caps = mem::new_array(int, (usz)(re.ngroups + 1) * 2);
	defer free(caps);
	if (!vm.regex_exec(re, s, 0, caps)!) return integer(-1);
	return integer(caps[0]);
}

fn Value? Vm.regexp_replace(&self, JsString* s, Value rx, Value replacement, bool all)
{
	JsRegExp* obj = (JsRegExp*)rx.as_object();
	Regex* re = obj.re;
	if (all && !re.global) return self.throw_error(TYPE_ERROR, "replaceAll must be called with a global RegExp")~;
	JsString* rep_text = replacement.is_function() ? null : self.to_string(replacement)!;
	int[] caps = mem::new_array(int, (usz)(re.ngroups + 1) * 2);
	defer free(caps);
	Value[] groups = mem::new_array(Value, re.ngroups ? re.ngroups : 1)[:re.ngroups];
	defer free(groups);
	@pool()
	{
		DString out;
		out.tinit();
		uint pos = re.global ? 0 : (re.sticky ? (uint)self.to_number(self.get(rx, self.atoms.last_index)!)! : 0);
		uint copied = 0;
		bool any_match = false;
		while (pos <= s.len)
		{
			if (!self.regex_exec(re, s, pos, caps)!) break;
			any_match = true;
			uint from = (uint)caps[0];
			uint to = (uint)caps[1];
			self.heap.substring(s, copied, from)!!.to_utf8(&out);
			for (uint g = 0; g < re.ngroups; g++)
			{
				int a = caps[(g + 1) * 2];
				int b = caps[(g + 1) * 2 + 1];
				groups[g] = a < 0 || b < 0 ? UNDEFINED : string_value(self.heap.substring(s, (uint)a, (uint)b) ?? self.oom()~!);
			}
			if (rep_text)
			{
				self.expand_replacement(&out, rep_text, s, from, to, groups)!;
			}
			else
			{
				Value[] call_args = mem::temp_array(Value, (usz)re.ngroups + 3);
				call_args[0] = string_value(self.heap.substring(s, from, to) ?? self.oom()~!);
				foreach (g, v : groups) call_args[g + 1] = v;
				call_args[re.ngroups + 1] = integer((int)from);
				call_args[re.ngroups + 2] = string_value(s);
				self.to_string(self.call(replacement, UNDEFINED, call_args)!)!.to_utf8(&out);
			}
			copied = to;
			if (!re.global) break;
			pos = to == from ? advance_index(s, to, re.unicode) : to;
		}
		if (re.global || re.sticky) self.set(rx, self.atoms.last_index, integer(0))!;
		if (!any_match) return string_value(s);
		self.heap.substring(s, copied, s.len)!!.to_utf8(&out);
		return self.str_value(out.str_view());
	};
}

fn Value? Vm.regexp_split(&self, JsString* s, Value rx, Value limit_value)
{
	Regex* re = ((JsRegExp*)rx.as_object()).re;
	uint limit = limit_value.is_undefined() ? uint::max : (uint)to_int32(self.to_number(limit_value)!);
	JsArray* out = self.new_js_array()!;
	if (limit == 0) return object_value(out);
	int[] caps = mem::new_array(int, (usz)(re.ngroups + 1) * 2);
	defer free(caps);
	if (s.len == 0)
	{
		if (!self.regex_exec(re, s, 0, caps)!) out.push(string_value(s));
		return object_value(out);
	}
	uint p = 0;
	uint q = 0;
	while (q < s.len)
	{
		// A split only counts where the match starts at q and doesn't end at p.
		Regex sticky = *re;
		sticky.sticky = true;
		if (!self.regex_exec(&sticky, s, q, caps)! || (uint)caps[1] == p)
		{
			q = advance_index(s, q, re.unicode);
			continue;
		}
		uint e = (uint)caps[1];
		if (e == q && q == p)
		{
			q = advance_index(s, q, re.unicode);
			continue;
		}
		out.push(string_value(self.heap.substring(s, p, q) ?? self.oom()~!));
		if (out.length == limit) return object_value(out);
		for (uint g = 1; g <= re.ngroups; g++)
		{
			int a = caps[g * 2];
			int b = caps[g * 2 + 1];
			out.push(a < 0 || b < 0 ? UNDEFINED : string_value(self.heap.substring(s, (uint)a, (uint)b) ?? self.oom()~!));
			if (out.length == limit) return object_value(out);
		}
		p = e;
		q = e == q ? advance_index(s, q, re.unicode) : e;
	}
	out.push(string_value(self.heap.substring(s, p, s.len) ?? self.oom()~!));
	return object_value(out);
}

fn void? Vm.init_regexp(&self)
{
	self.regexp_proto = self.heap.new_object(self.object_proto)!;
	self.define_constructor("RegExp", &native_regexp, 2, self.regexp_proto)!;
	self.define_native(self.regexp_proto, "exec", &native_regexp_exec, 1)!;
	self.define_native(self.regexp_proto, "test", &native_regexp_test, 1)!;
	self.define_native(self.regexp_proto, "toString", &native_regexp_to_string, 0)!;
	self.define_getter(self.regexp_proto, "source", &native_regexp_source)!;
	self.define_getter(self.regexp_proto, "flags", &native_regexp_flags)!;
	foreach (i, name : (String[6]){ "global", "ignoreCase", "multiline", "sticky", "unicode", "dotAll" })
	{
		JsFunction* getter = self.new_native(string::tformat("get %s", name).copy(mem), &native_regexp_flag, 0)!;
		self.owned_names.push(getter.native_name);
		getter.magic = (int)i;
		self.define_accessor(self.regexp_proto, self.atom_value(name)!, object_value(getter), UNDEFINED, METHOD_PROP) ?? OUT_OF_MEMORY~!;
	}
	self.define_native(self.string_proto, "match", &native_string_match, 1)!;
	self.define_native(self.string_proto, "matchAll", &native_string_match_all, 1)!;
	self.define_native(self.string_proto, "search", &native_string_search, 1)!;
}
