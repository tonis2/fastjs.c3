module fastjs::rt;
import std::math, std::core::dstring, std::collections::list;

// console.log formatting, following node's util.inspect (lib/internal/util/inspect.js) with its
// defaults: depth 2, breakLength 80, compact 3, maxArrayLength 100. Matching it exactly lets the
// test suite diff our output against node's.

const int INSPECT_DEPTH = 2;
const int BREAK_LENGTH = 80;
const int COMPACT = 3;
const uint MAX_ARRAY_LENGTH = 100;

struct InspectCtx
{
	int indentation;
	int current_depth;
	List {JsObject*} seen;
	// Objects found to be referenced circularly; index + 1 is the *N node prints.
	List {JsObject*} circular;
}

<*
 Append v the way console.log shows it. Strings print raw at the top level.

 @return? THROWN
*>
fn void? Vm.inspect(&self, Value v, DString* out, int depth, bool top)
{
	if (top && v.is_string())
	{
		v.as_string().to_utf8(out);
		return;
	}
	InspectCtx ctx;
	ctx.seen.init(mem);
	defer ctx.seen.free();
	ctx.circular.init(mem);
	defer ctx.circular.free();
	@pool()
	{
		out.append(self.format_value(&ctx, v, depth)!);
	};
}

// Display width: code points, ignoring UTF-8 continuation bytes.
fn int width(String s)
{
	int w = 0;
	foreach (c : s)
	{
		if ((c & 0xC0) != 0x80) w++;
	}
	return w;
}

fn bool is_identifier(JsString* s)
{
	if (s.len == 0) return false;
	for (uint i = 0; i < s.len; i++)
	{
		ushort c = s.at(i);
		bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || (i > 0 && c >= '0' && c <= '9');
		if (!ok) return false;
	}
	return true;
}

// node's strEscape: single quotes, unless the text has one and a double or backtick quote avoids escaping.
fn String quote_string(JsString* s)
{
	DString out;
	out.tinit();
	String text = s.tutf8();
	char q = '\'';
	if (text.contains("'"))
	{
		if (!text.contains("\""))
		{
			q = '"';
		}
		else if (!text.contains("`") && !text.contains("${"))
		{
			q = '`';
		}
	}
	out.append(q);
	foreach (c : text)
	{
		switch (c)
		{
			case '\n': out.append("\\n");
			case '\t': out.append("\\t");
			case '\r': out.append("\\r");
			case '\b': out.append("\\b");
			case '\f': out.append("\\f");
			case 0x0B: out.append("\\v");
			case '\\': out.append("\\\\");
			default:
				if (c == q)
				{
					out.append('\\');
					out.append(c);
				}
				else if (c < 0x20 || c == 0x7F)
				{
					out.appendf("\\x%02X", c);
				}
				else
				{
					out.append(c);
				}
		}
	}
	out.append(q);
	return out.str_view();
}

fn String Vm.format_key(&self, Value key)
{
	if (key.is_int()) return string::tformat("'%d'", key.as_int());
	if (key.is_string())
	{
		JsString* s = key.as_string();
		return is_identifier(s) ? s.tutf8() : quote_string(s);
	}
	return self.symbol_text(key);
}

fn String Vm.function_name(&self, JsFunction* f) => f.native ? f.native_name : f.proto.name;

<*
 The constructor name node shows before an object's braces, found on the prototype chain.
*>
fn String Vm.constructor_name(&self, JsObject* o)
{
	for (JsObject* p = o.proto(); p; p = p.proto())
	{
		Shape* c = p.find_own(self.atoms.constructor);
		if (!c || c.flags.accessor) continue;
		Value ctor = p.slots[c.slot()];
		if (ctor.is_function()) return self.function_name((JsFunction*)ctor.as_object());
	}
	return "";
}

<*
 @return? THROWN
*>
fn String? Vm.format_value(&self, InspectCtx* ctx, Value v, int recurse)
{
	switch
	{
		case v.is_string():
			return quote_string(v.as_string());
		case v.is_double() && v.as_double() == 0 && bitcast(v.as_double(), ulong) != 0:
			return "-0";
		case v.is_number():
			char[40] buf;
			return format_number(v.as_number(), &buf).tcopy();
		case v.is_symbol():
			return self.symbol_text(v);
		case !v.is_object():
			return self.to_string(v)!.tutf8();
		default:
			break;
	}
	JsObject* o = v.as_object();
	// Like node with showProxy off: a proxy prints as its target, without running any trap.
	while (o.is_proxy) o = o.proxy_target().as_object();
	v = object_value(o);
	if (ctx.seen.contains(o))
	{
		sz? index = ctx.circular.index_of(o);
		if (catch index)
		{
			ctx.circular.push(o);
			return string::tformat("[Circular *%d]", ctx.circular.len());
		}
		return string::tformat("[Circular *%d]", index + 1);
	}
	// Functions print as a tag, followed by their own properties if they have any.
	String base;
	switch (o.kind)
	{
		case FUNCTION:
			JsFunction* f = (JsFunction*)o;
			String name = self.function_name(f);
			if (f.proto && f.proto.is_class_constructor)
			{
				base = string::tformat("[class %s", name.len ? name : "(anonymous)");
				JsObject* parent = o.proto();
				if (f.proto.is_derived && parent && parent.kind == FUNCTION)
				{
					base = string::tformat("%s extends %s", base, self.function_name((JsFunction*)parent));
				}
				base = string::tformat("%s]", base);
			}
			else
			{
				String tag = "Function";
				if (f.proto && f.proto.is_async) tag = "AsyncFunction";
				if (f.proto && f.proto.is_generator) tag = "GeneratorFunction";
				base = name.len ? string::tformat("[%s: %s]", tag, name) : string::tformat("[%s (anonymous)]", tag);
			}
		case REGEXP:
			JsRegExp* re = (JsRegExp*)o;
			return string::tformat("/%s/%s", re.source.as_string().tutf8(), re.flags.as_string().tutf8());
		case ERROR:
			Value stack = self.get(v, self.atoms.stack)!;
			if (stack.is_string()) return stack.as_string().tutf8();
			return self.to_string(v)!.tutf8();
		default:
			break;
	}
	bool is_array = o.kind == ARRAY || o.kind == TYPED_ARRAY;
	String name = self.constructor_name(o);
	String open;
	switch
	{
		case base.len > 0:
			open = string::tformat("%s {", base);
		case o.kind == TYPED_ARRAY:
			JsTypedArray* t = (JsTypedArray*)o;
			open = string::tformat("%s(%d) [", name.len ? name : t.tkind.name, t.length);
		case o.kind == MAP:
			JsMap* m = (JsMap*)o;
			open = string::tformat("%s(%d) {", name.len ? name : m.is_set ? "Set" : "Map", m.live);
		case o.kind == ARRAY_BUFFER:
			open = string::tformat("%s {", name.len ? name : "ArrayBuffer");
		case o.kind == COROUTINE:
			open = "Object [Generator] {";
		case o.kind == PROMISE && (name == "Promise" || !name.len):
			open = "Promise {";
		case o.kind == ITERATOR:
			JsIterator* it = (JsIterator*)o;
			String what = it.iter_kind.ordinal <= IterKind.ARRAY_ENTRIES.ordinal ? "Array Iterator" : it.iter_kind.ordinal <= IterKind.MAP_ENTRIES.ordinal ? "Map Iterator" : "Set Iterator";
			open = string::tformat("Object [%s] {", what);
		case !o.proto():
			open = is_array ? "[Array: null prototype] [" : "[Object: null prototype] {";
		case is_array:
			open = name == "Array" || !name.len ? "[" : string::tformat("%s(%d) [", name, ((JsArray*)o).length);
		default:
			open = name == "Object" || !name.len ? "{" : string::tformat("%s {", name);
	}
	String close = is_array ? "]" : "}";
	if (recurse > INSPECT_DEPTH && !base.len) return is_array ? "[Array]" : string::tformat("[%s]", name.len ? name : "Object");

	List {Value} keys;
	keys.init(mem);
	defer keys.free();
	self.own_keys(o, &keys, true)!;
	List {String} output;
	output.tinit();
	ctx.seen.push(o);
	ctx.current_depth = recurse;
	if (o.kind == TYPED_ARRAY)
	{
		JsTypedArray* t = (JsTypedArray*)o;
		uint shown = min(t.length, MAX_ARRAY_LENGTH);
		for (uint i = 0; i < shown; i++) output.push(self.format_child(ctx, t.get(i), recurse)!);
		if (t.length > shown) output.push(string::tformat("... %d more item%s", t.length - shown, t.length - shown == 1 ? "" : "s"));
	}
	else if (o.kind == MAP)
	{
		JsMap* m = (JsMap*)o;
		for (uint i = 0; i < m.used; i++)
		{
			MapEntry e = m.entries[i];
			if (e.key == EMPTY) continue;
			if (m.is_set)
			{
				output.push(self.format_child(ctx, e.key, recurse)!);
				continue;
			}
			output.push(string::tformat("%s => %s", self.format_child(ctx, e.key, recurse)!, self.format_child(ctx, e.value, recurse)!));
		}
	}
	else if (o.kind == PROMISE)
	{
		JsPromise* p = (JsPromise*)o;
		switch (p.state)
		{
			case PENDING: output.push("<pending>");
			case FULFILLED: output.push(self.format_child(ctx, p.result, recurse)!);
			case REJECTED: output.push(string::tformat("<rejected> %s", self.format_child(ctx, p.result, recurse)!));
		}
	}
	else if (o.kind == ARRAY_BUFFER)
	{
		JsArrayBuffer* b = (JsArrayBuffer*)o;
		DString bytes;
		bytes.tinit();
		bytes.append("[Uint8Contents]: <");
		for (usz i = 0; i < b.byte_length && i < 50; i++)
		{
			if (i > 0) bytes.append(' ');
			bytes.appendf("%02x", b.data[i]);
		}
		if (b.byte_length > 50) bytes.appendf(" ... %d more byte%s", b.byte_length - 50, b.byte_length - 50 == 1 ? "" : "s");
		bytes.append('>');
		output.push(bytes.str_view());
		output.push(string::tformat("[byteLength]: %d", b.byte_length));
	}
	else if (is_array)
	{
		JsArray* arr = (JsArray*)o;
		uint shown = min(arr.length, MAX_ARRAY_LENGTH);
		uint i = 0;
		while (i < shown)
		{
			if (arr.elements[i] == EMPTY)
			{
				uint holes = 0;
				while (i < arr.length && arr.elements[i] == EMPTY)
				{
					holes++;
					i++;
				}
				output.push(string::tformat("<%d empty item%s>", holes, holes == 1 ? "" : "s"));
				continue;
			}
			output.push(self.format_child(ctx, arr.elements[i], recurse)!);
			i++;
		}
		if (arr.length > shown) output.push(string::tformat("... %d more item%s", arr.length - shown, arr.length - shown == 1 ? "" : "s"));
	}
	foreach (key : keys)
	{
		if (is_array && key.is_int()) continue;
		Shape* s = o.find_own(key);
		String value;
		if (s && s.flags.accessor)
		{
			Accessor* acc = (Accessor*)o.slots[s.slot()].as_object();
			value = acc.setter.is_undefined() ? "[Getter]" : acc.getter.is_undefined() ? "[Setter]" : "[Getter/Setter]";
		}
		else
		{
			value = self.format_child(ctx, self.get(v, key)!, recurse)!;
		}
		output.push(string::tformat("%s: %s", self.format_key(key), value));
	}
	(void)ctx.seen.pop();
	String result;
	if (output.len() == 0 && base.len)
	{
		result = base;
	}
	else if (output.len() == 0)
	{
		result = is_array ? string::tformat("%s]", open) : string::tformat("%s}", open);
		// "Map(0) {}" and "Float32Array(0) []" keep a space only when not empty.
	}
	else
	{
		result = self.reduce_to_single_string(ctx, &output, open, close, is_array, recurse, o);
	}
	if (try index = ctx.circular.index_of(o)) return string::tformat("<ref *%d> %s", index + 1, result);
	return result;
}

fn String? Vm.format_child(&self, InspectCtx* ctx, Value v, int recurse)
{
	ctx.indentation += 2;
	defer ctx.indentation -= 2;
	return self.format_value(ctx, v, recurse + 1);
}

fn bool is_below_break_length(List {String}* output, int start)
{
	int total = (int)output.len() + start;
	if (total + (int)output.len() > BREAK_LENGTH) return false;
	foreach (s : *output)
	{
		total += width(s);
		if (total > BREAK_LENGTH) return false;
	}
	return true;
}

fn String join(List {String}* parts, String sep)
{
	DString out;
	out.tinit();
	foreach (i, s : *parts)
	{
		if (i > 0) out.append(sep);
		out.append(s);
	}
	return out.str_view();
}

fn String Vm.reduce_to_single_string(&self, InspectCtx* ctx, List {String}* output, String open, String close, bool is_array, int recurse, JsObject* o)
{
	sz entries = output.len();
	if (is_array && entries > 6) output = self.group_array_elements(ctx, output, o);
	if (ctx.current_depth - recurse < COMPACT && entries == output.len())
	{
		int start = (int)output.len() + ctx.indentation + width(open) + 10;
		if (is_below_break_length(output, start))
		{
			String joined = join(output, ", ");
			if (!joined.contains("\n")) return string::tformat("%s %s %s", open, joined, close);
		}
	}
	DString indent;
	indent.tinit();
	indent.append('\n');
	for (int i = 0; i < ctx.indentation; i++) indent.append(' ');
	String nl = indent.str_view();
	return string::tformat("%s%s  %s%s%s", open, nl, join(output, string::tformat(",%s  ", nl)), nl, close);
}

<*
 Lay a long array out in aligned columns, as node does for arrays of more than six short entries.
*>
fn List {String}* Vm.group_array_elements(&self, InspectCtx* ctx, List {String}* output, JsObject* o)
{
	int total = 0;
	int max_len = 0;
	sz count = output.len();
	uint length = o.kind == ARRAY ? ((JsArray*)o).length : ((JsTypedArray*)o).length;
	// A trailing "... more items" entry isn't part of the grid.
	if (length > MAX_ARRAY_LENGTH) count--;
	const int SEPARATOR_SPACE = 2;
	int[] data_len = mem::temp_array(int, count);
	for (sz i = 0; i < count; i++)
	{
		int len = width((*output)[i]);
		data_len[i] = len;
		total += len + SEPARATOR_SPACE;
		if (max_len < len) max_len = len;
	}
	int actual_max = max_len + SEPARATOR_SPACE;
	if (!(actual_max * 3 + ctx.indentation < BREAK_LENGTH && ((double)total / actual_max > 5 || max_len <= 6))) return output;
	double average_bias = math::sqrt((double)actual_max - (double)total / (double)output.len());
	double biased_max = math::max((double)actual_max - 3.0 - average_bias, 1.0);
	int columns = (int)math::round(math::sqrt(2.5 * biased_max * (double)count) / biased_max);
	columns = min(columns, (BREAK_LENGTH - ctx.indentation) / actual_max, COMPACT * 4, 15);
	if (columns <= 1) return output;
	List {int} max_line;
	max_line.tinit();
	for (int i = 0; i < columns; i++)
	{
		int line = 0;
		for (sz j = i; j < count; j += columns)
		{
			if (data_len[j] > line) line = data_len[j];
		}
		max_line.push(line + SEPARATOR_SPACE);
	}
	// Numbers are right-aligned, anything else left-aligned.
	bool pad_start = true;
	if (o.kind == ARRAY)
	{
		JsArray* arr = (JsArray*)o;
		for (uint i = 0; i < arr.length && i < count; i++)
		{
			if (!arr.elements[i].is_number())
			{
				pad_start = false;
				break;
			}
		}
	}
	List {String}* grouped = mem::tnew(List {String});
	grouped.tinit();
	for (sz i = 0; i < count; i += columns)
	{
		sz max = min(i + columns, count);
		DString line;
		line.tinit();
		sz j = i;
		for (; j < max - 1; j++)
		{
			String cell = string::tformat("%s, ", (*output)[j]);
			pad(&line, cell, max_line[j - i], pad_start);
		}
		if (pad_start)
		{
			pad(&line, (*output)[j], max_line[j - i] - SEPARATOR_SPACE, true);
		}
		else
		{
			line.append((*output)[j]);
		}
		grouped.push(line.str_view());
	}
	if (length > MAX_ARRAY_LENGTH) grouped.push((*output)[count]);
	return grouped;
}

fn void pad(DString* out, String s, int to, bool at_start)
{
	int fill = to - width(s);
	if (at_start) for (int i = 0; i < fill; i++) out.append(' ');
	out.append(s);
	if (!at_start) for (int i = 0; i < fill; i++) out.append(' ');
}
