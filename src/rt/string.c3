module fastjs::rt;
import std::core::dstring, std::math, std::collections::list;

excuse STRING_TOO_LONG;

const uint MAX_STRING_LENGTH = 1 << 29;

<*
 An immutable JS string of UTF-16 code units. A string whose units all fit in a byte is always
 stored narrow (one byte each); any other string is wide. Keeping this canonical means two equal
 strings always have the same representation.
*>
struct JsString
{
	inline GcHeader header;
	uint len;
	// 0 until computed.
	uint hash;
	bool wide;
	bool atom;
	char[*] data;
}

fn char[] JsString.narrow_units(&self) @inline => self.data[:self.len];
fn ushort[] JsString.wide_units(&self) @inline => ((ushort*)&self.data)[:self.len];

<*
 @require i < self.len : "Index out of bounds"
*>
fn ushort JsString.at(&self, uint i) @inline => self.wide ? ((ushort*)&self.data)[i] : (ushort)self.data[i];

fn uint JsString.hash_code(&self)
{
	if (self.hash) return self.hash;
	// FNV-1a over code units, so the hash doesn't depend on the storage width.
	uint h = 2166136261;
	for (uint i = 0; i < self.len; i++)
	{
		h ^= self.at(i);
		h *= 16777619;
	}
	if (h == 0) h = 1;
	self.hash = h;
	return h;
}

fn bool JsString.equals(&self, JsString* other)
{
	if (self == other) return true;
	if (self.len != other.len || self.wide != other.wide) return false;
	if (self.atom && other.atom) return false;
	if (self.hash && other.hash && self.hash != other.hash) return false;
	sz bytes = self.wide ? (sz)self.len * 2 : (sz)self.len;
	return mem::equals((char*)&self.data, (char*)&other.data, bytes);
}

<*
 Compare by code units, as `<` does on strings.

 @return "Negative, zero or positive"
*>
fn int JsString.compare(&self, JsString* other)
{
	uint n = min(self.len, other.len);
	for (uint i = 0; i < n; i++)
	{
		int d = (int)self.at(i) - (int)other.at(i);
		if (d) return d;
	}
	return (int)self.len - (int)other.len;
}

<*
 Append the string as UTF-8. Unpaired surrogates become U+FFFD.
*>
fn void JsString.to_utf8(&self, DString* out)
{
	if (!self.wide)
	{
		foreach (c : self.narrow_units())
		{
			if (c < 0x80)
			{
				out.append(c);
				continue;
			}
			append_code_point(out, c);
		}
		return;
	}
	for (uint i = 0; i < self.len; i++)
	{
		uint cp = self.at(i);
		if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < self.len)
		{
			uint lo = self.at(i + 1);
			if (lo >= 0xDC00 && lo <= 0xDFFF)
			{
				cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
				i++;
			}
		}
		if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
		append_code_point(out, cp);
	}
}

fn void append_code_point(DString* out, uint cp)
{
	switch
	{
		case cp < 0x80:
			out.append((char)cp);
		case cp < 0x800:
			out.append((char)(0xC0 | cp >> 6));
			out.append((char)(0x80 | (cp & 0x3F)));
		case cp < 0x10000:
			out.append((char)(0xE0 | cp >> 12));
			out.append((char)(0x80 | (cp >> 6 & 0x3F)));
			out.append((char)(0x80 | (cp & 0x3F)));
		default:
			out.append((char)(0xF0 | cp >> 18));
			out.append((char)(0x80 | (cp >> 12 & 0x3F)));
			out.append((char)(0x80 | (cp >> 6 & 0x3F)));
			out.append((char)(0x80 | (cp & 0x3F)));
	}
}

<*
 The string as UTF-8 in temp memory.
*>
fn String JsString.tutf8(&self)
{
	DString out;
	out.tinit();
	self.to_utf8(&out);
	return out.str_view();
}

<*
 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.new_string(&self, uint len, bool wide)
{
	if (len > MAX_STRING_LENGTH) return STRING_TOO_LONG~;
	usz bytes = wide ? (usz)len * 2 : len;
	JsString* s = self.alloc(STRING, JsString::size + bytes)!;
	s.len = len;
	s.wide = wide;
	return s;
}

<*
 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.string_from_latin1(&self, char[] units)
{
	JsString* s = self.new_string((uint)units.len, false)!;
	mem::copy(&s.data, units.ptr, units.len);
	return s;
}

<*
 A string from UTF-16 units, stored narrow when every unit fits.

 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.string_from_units(&self, ushort[] units)
{
	bool wide = false;
	foreach (u : units)
	{
		if (u > 0xFF)
		{
			wide = true;
			break;
		}
	}
	JsString* s = self.new_string((uint)units.len, wide)!;
	if (wide)
	{
		mem::copy(&s.data, units.ptr, units.len * 2);
		return s;
	}
	foreach (i, u : units) s.data[i] = (char)u;
	return s;
}

<*
 Decode one UTF-8 sequence at s[*i], advancing i. Malformed input gives U+FFFD.
*>
fn uint utf8_next(String s, usz* i)
{
	char c = s[*i];
	(*i)++;
	if (c < 0x80) return c;
	uint need;
	uint cp;
	switch
	{
		case c >= 0xF0 && c < 0xF8:
			need = 3;
			cp = c & 0x07;
		case c >= 0xE0:
			need = 2;
			cp = c & 0x0F;
		case c >= 0xC0:
			need = 1;
			cp = c & 0x1F;
		default:
			return 0xFFFD;
	}
	if (c >= 0xF8) return 0xFFFD;
	for (uint k = 0; k < need; k++)
	{
		if (*i >= s.len || (s[*i] & 0xC0) != 0x80) return 0xFFFD;
		cp = cp << 6 | (s[*i] & 0x3F);
		(*i)++;
	}
	return cp > 0x10FFFF ? 0xFFFD : cp;
}

fn void push_code_point(List {ushort}* units, uint cp)
{
	if (cp < 0x10000)
	{
		units.push((ushort)cp);
		return;
	}
	cp -= 0x10000;
	units.push((ushort)(0xD800 + (cp >> 10)));
	units.push((ushort)(0xDC00 + (cp & 0x3FF)));
}

<*
 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.string_from_utf8(&self, String s)
{
	bool ascii = true;
	foreach (c : s)
	{
		if (c >= 0x80)
		{
			ascii = false;
			break;
		}
	}
	if (ascii) return self.string_from_latin1(s);
	@pool()
	{
		List {ushort} units;
		units.tinit();
		usz i = 0;
		while (i < s.len) push_code_point(&units, utf8_next(s, &i));
		return self.string_from_units(units.array_view());
	};
}

fn int hex_digit(char c)
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
 The value of a string literal or template piece from its raw source text. The lexer has already
 checked every escape, so malformed ones can't appear here.

 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.cook(&self, String raw, bool template)
{
	@pool()
	{
		List {ushort} units;
		units.tinit();
		usz i = 0;
		while (i < raw.len)
		{
			char c = raw[i];
			if (c == '\r' && template)
			{
				// Template line endings are normalized to \n.
				i++;
				if (i < raw.len && raw[i] == '\n') i++;
				units.push('\n');
				continue;
			}
			if (c != '\\')
			{
				push_code_point(&units, utf8_next(raw, &i));
				continue;
			}
			i++;
			char e = raw[i];
			i++;
			switch (e)
			{
				case 'n': units.push('\n');
				case 't': units.push('\t');
				case 'r': units.push('\r');
				case 'b': units.push(8);
				case 'f': units.push(12);
				case 'v': units.push(11);
				case '0': units.push(0);
				case 'x':
					units.push((ushort)(hex_digit(raw[i]) * 16 + hex_digit(raw[i + 1])));
					i += 2;
				case 'u':
					uint cp = 0;
					if (raw[i] == '{')
					{
						i++;
						while (raw[i] != '}') cp = cp * 16 + (uint)hex_digit(raw[i++]);
						i++;
						push_code_point(&units, cp);
					}
					else
					{
						for (int k = 0; k < 4; k++) cp = cp * 16 + (uint)hex_digit(raw[i++]);
						units.push((ushort)cp);
					}
				case '\r':
					// A line continuation produces nothing.
					if (i < raw.len && raw[i] == '\n') i++;
				case '\n':
					break;
				default:
					i--;
					uint cp = utf8_next(raw, &i);
					// U+2028/2029 after a backslash are line continuations too.
					if (cp != 0x2028 && cp != 0x2029) push_code_point(&units, cp);
			}
		}
		return self.string_from_units(units.array_view());
	};
}

<*
 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.concat(&self, JsString* a, JsString* b)
{
	if (a.len == 0) return b;
	if (b.len == 0) return a;
	if ((ulong)a.len + b.len > MAX_STRING_LENGTH) return STRING_TOO_LONG~;
	bool wide = a.wide || b.wide;
	JsString* s = self.new_string(a.len + b.len, wide)!;
	if (!wide)
	{
		mem::copy(&s.data, &a.data, a.len);
		mem::copy((char*)&s.data + a.len, &b.data, b.len);
		return s;
	}
	ushort* out = (ushort*)&s.data;
	for (uint i = 0; i < a.len; i++) out[i] = a.at(i);
	for (uint i = 0; i < b.len; i++) out[a.len + i] = b.at(i);
	return s;
}

<*
 The units [start, end) as a new string.

 @require start <= end && end <= s.len : "Range out of bounds"
 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.substring(&self, JsString* s, uint start, uint end)
{
	if (start == 0 && end == s.len) return s;
	if (!s.wide) return self.string_from_latin1(s.data[start:end - start]);
	return self.string_from_units(s.wide_units()[start:end - start]);
}

<*
 The array index this string names: a canonical decimal integer below 2^32 - 1.
*>
fn bool JsString.array_index(&self, uint* out)
{
	if (self.len == 0 || self.len > 10) return false;
	ushort first = self.at(0);
	if (first == '0')
	{
		if (self.len != 1) return false;
		*out = 0;
		return true;
	}
	ulong v = 0;
	for (uint i = 0; i < self.len; i++)
	{
		ushort c = self.at(i);
		if (c < '0' || c > '9') return false;
		v = v * 10 + (ulong)(c - '0');
	}
	if (v >= 0xFFFF_FFFF) return false;
	*out = (uint)v;
	return true;
}

fn bool is_js_space(uint c)
{
	switch (c)
	{
		case ' ':
		case '\t':
		case '\n':
		case '\r':
		case 0x0B:
		case 0x0C:
		case 0xA0:
		case 0xFEFF:
		case 0x1680:
		case 0x2028:
		case 0x2029:
		case 0x202F:
		case 0x205F:
		case 0x3000:
			return true;
		default:
			return c >= 0x2000 && c <= 0x200A;
	}
}

<*
 ToNumber of a string: whitespace-trimmed decimal, hex, octal or binary, or Infinity. Anything else is NaN.
*>
fn double JsString.to_number(&self)
{
	uint start = 0;
	uint end = self.len;
	while (start < end && is_js_space(self.at(start))) start++;
	while (end > start && is_js_space(self.at(end - 1))) end--;
	if (start == end) return 0;
	if (end - start > 400) return double::nan;
	char[400] buf;
	uint n = 0;
	for (uint i = start; i < end; i++)
	{
		ushort c = self.at(i);
		if (c >= 0x80) return double::nan;
		buf[n++] = (char)c;
	}
	String text = (String)buf[:n];
	switch (text)
	{
		case "Infinity":
		case "+Infinity":
			return double::inf;
		case "-Infinity":
			return -double::inf;
	}
	if (n > 2 && text[0] == '0')
	{
		int radix;
		switch (text[1] | 0x20)
		{
			case 'x': radix = 16;
			case 'o': radix = 8;
			case 'b': radix = 2;
			default: radix = 0;
		}
		if (radix)
		{
			double v = 0;
			foreach (c : text[2..])
			{
				int d = hex_digit(c);
				if (d < 0 || d >= radix) return double::nan;
				v = v * radix + d;
			}
			return v;
		}
	}
	// Check the decimal grammar ourselves: the parser below also accepts things JS doesn't, like "nan".
	usz i = 0;
	if (text[i] == '+' || text[i] == '-') i++;
	usz digits = 0;
	while (i < n && text[i] >= '0' && text[i] <= '9')
	{
		i++;
		digits++;
	}
	if (i < n && text[i] == '.')
	{
		i++;
		while (i < n && text[i] >= '0' && text[i] <= '9')
		{
			i++;
			digits++;
		}
	}
	if (digits == 0) return double::nan;
	if (i < n && (text[i] | 0x20) == 'e')
	{
		i++;
		if (i < n && (text[i] == '+' || text[i] == '-')) i++;
		usz exp_digits = 0;
		while (i < n && text[i] >= '0' && text[i] <= '9')
		{
			i++;
			exp_digits++;
		}
		if (exp_digits == 0) return double::nan;
	}
	if (i != n) return double::nan;
	return text.to_double() ?? double::nan;
}

extern fn CInt snprintf(char* buf, usz n, ZString fmt, ...) @cname("snprintf");

<*
 Number::toString(10): the shortest digits that read back as d, laid out as JS does.

 @require buf.len >= 32 : "Buffer too small"
*>
fn String format_number(double d, char[] buf)
{
	if (d != d) return "NaN";
	if (d == 0) return "0";
	if (d == double::inf) return "Infinity";
	if (d == -double::inf) return "-Infinity";
	usz pos = 0;
	if (d < 0)
	{
		buf[pos++] = '-';
		d = -d;
	}
	if (d < 9007199254740992.0 && d == math::floor(d))
	{
		ulong v = (ulong)d;
		char[20] rev;
		usz k = 0;
		while (v)
		{
			rev[k++] = (char)('0' + v % 10);
			v /= 10;
		}
		while (k) buf[pos++] = rev[--k];
		return (String)buf[:pos];
	}
	// Find the shortest precision that round-trips; 17 significant digits always does.
	char[40] tmp;
	CInt len;
	for (CInt p = 0; p < 17; p++)
	{
		len = snprintf(&tmp, tmp.len, "%.*e", p, d);
		if (try back = ((String)tmp[:len]).to_double())
		{
			if (back == d) break;
		}
	}
	// tmp is "d.ddde+XX" or "de+XX": collect the digits and the exponent.
	char[20] digits;
	int k = 0;
	usz i = 0;
	while (tmp[i] != 'e')
	{
		if (tmp[i] != '.') digits[k++] = tmp[i];
		i++;
	}
	i++;
	bool negative_exp = tmp[i] == '-';
	i++;
	int exp = 0;
	while (i < (usz)len) exp = exp * 10 + (tmp[i++] - '0');
	if (negative_exp) exp = -exp;
	int n = exp + 1;
	switch
	{
		case k <= n && n <= 21:
			foreach (c : digits[:k]) buf[pos++] = c;
			for (int z = 0; z < n - k; z++) buf[pos++] = '0';
		case 0 < n && n <= 21:
			foreach (c : digits[:n]) buf[pos++] = c;
			buf[pos++] = '.';
			foreach (c : digits[n..k - 1]) buf[pos++] = c;
		case -6 < n && n <= 0:
			buf[pos++] = '0';
			buf[pos++] = '.';
			for (int z = 0; z < -n; z++) buf[pos++] = '0';
			foreach (c : digits[:k]) buf[pos++] = c;
		default:
			buf[pos++] = digits[0];
			if (k > 1)
			{
				buf[pos++] = '.';
				foreach (c : digits[1..k - 1]) buf[pos++] = c;
			}
			buf[pos++] = 'e';
			buf[pos++] = n - 1 < 0 ? '-' : '+';
			int e = n - 1 < 0 ? 1 - n : n - 1;
			char[5] rev;
			usz r = 0;
			do
			{
				rev[r++] = (char)('0' + e % 10);
				e /= 10;
			} while (e);
			while (r) buf[pos++] = rev[--r];
	}
	return (String)buf[:pos];
}

<*
 @return? OUT_OF_MEMORY, STRING_TOO_LONG
*>
fn JsString*? Heap.number_to_string(&self, double d)
{
	char[40] buf;
	return self.string_from_latin1(format_number(d, &buf));
}
