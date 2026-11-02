module fastjs::rt;
import std::collections::list;

// Case mapping and Unicode properties over the tables in unicode_data.c3, which
// tools/gen_unicode.mjs generates from node, so the answers are V8's.

<*
 cp mapped by the first of runs that covers it, or cp itself.
*>
fn uint case_run_map(CaseRun[] runs, uint cp)
{
	usz lo = 0;
	usz hi = runs.len;
	// The last run starting at or before cp.
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		if (runs[mid].lo <= cp)
		{
			lo = mid + 1;
		}
		else
		{
			hi = mid;
		}
	}
	if (lo == 0) return cp;
	CaseRun r = runs[lo - 1];
	if (cp > r.hi || (cp - r.lo) % r.stride != 0) return cp;
	return (uint)((int)cp + r.delta);
}

fn uint to_upper_cp(uint c)
{
	if (c < 0x80) return c >= 'a' && c <= 'z' ? c - 32 : c;
	return case_run_map(&UPPER_RUNS, c);
}

fn uint to_lower_cp(uint c)
{
	if (c < 0x80) return c >= 'A' && c <= 'Z' ? c + 32 : c;
	return case_run_map(&LOWER_RUNS, c);
}

fn String special_case(SpecialCase[] table, uint cp)
{
	usz lo = 0;
	usz hi = table.len;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		if (table[mid].cp == cp) return table[mid].to;
		if (table[mid].cp < cp)
		{
			lo = mid + 1;
		}
		else
		{
			hi = mid;
		}
	}
	return "";
}

<*
 The property a \p{...} name stands for: "L", "Letter", "gc=Lu", "General_Category=Lu",
 "Script=Greek", "sc=Grek", "scx=Latn", "Alphabetic", "Alpha"... Null when there is none.
*>
fn UniProperty* find_property(String name)
{
	String key = name;
	String value = "";
	if (try eq = name.index_of_char('='))
	{
		key = name[:eq];
		value = name[eq + 1..];
		switch (key)
		{
			case "General_Category":
			case "gc":
				return find_property(value).name.starts_with("gc=") ? find_property(value) : null;
			case "Script":
			case "sc":
			case "Script_Extensions":
			case "scx":
				String prefix = key == "Script" || key == "sc" ? "sc=" : "scx=";
				String script = resolve_alias(value);
				foreach (&p : PROPERTIES)
				{
					if (p.name.starts_with(prefix) && p.name[prefix.len..] == script) return p;
				}
				return null;
			default:
				return null;
		}
	}
	String target = resolve_alias(name);
	foreach (&p : PROPERTIES)
	{
		if (p.name == target || (p.name.starts_with("gc=") && p.name[3..] == target)) return p;
	}
	return null;
}

fn String resolve_alias(String name)
{
	foreach (a : PROPERTY_ALIASES)
	{
		if (a.name == name) return a.target.starts_with("gc=") ? a.target[3..] : a.target;
	}
	return name;
}

fn uint[] UniProperty.ranges(&self) @inline => PROPERTY_RANGES[self.start * 2:self.count * 2];

fn bool UniProperty.has(&self, uint cp)
{
	uint[] r = self.ranges();
	usz lo = 0;
	usz hi = self.count;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		if (r[mid * 2 + 1] < cp)
		{
			lo = mid + 1;
		}
		else if (r[mid * 2] > cp)
		{
			hi = mid;
		}
		else
		{
			return true;
		}
	}
	return false;
}

UniProperty* cased_property;
UniProperty* case_ignorable_property;

fn bool is_cased(uint cp)
{
	if (!cased_property) cased_property = find_property("Cased");
	return cased_property.has(cp);
}

fn bool is_case_ignorable(uint cp)
{
	if (!case_ignorable_property) case_ignorable_property = find_property("Case_Ignorable");
	return case_ignorable_property.has(cp);
}

fn uint code_point_at(JsString* s, uint i, uint* width) @inline
{
	uint c = s.at(i);
	*width = 1;
	if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.len)
	{
		uint d = s.at(i + 1);
		if (d >= 0xDC00 && d <= 0xDFFF)
		{
			*width = 2;
			return 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
		}
	}
	return c;
}

fn uint code_point_before(JsString* s, uint i, uint* width) @inline
{
	uint c = s.at(i - 1);
	*width = 1;
	if (c >= 0xDC00 && c <= 0xDFFF && i >= 2)
	{
		uint h = s.at(i - 2);
		if (h >= 0xD800 && h <= 0xDBFF)
		{
			*width = 2;
			return 0x10000 + ((h - 0xD800) << 10) + (c - 0xDC00);
		}
	}
	return c;
}

<*
 Greek capital sigma at i lowercases to final ς at the end of a word: after a cased letter
 and not before one, case-ignorable characters skipped.
*>
fn bool final_sigma(JsString* s, uint i)
{
	uint w;
	bool before = false;
	for (uint j = i; j > 0; j -= w)
	{
		uint cp = code_point_before(s, j, &w);
		if (is_case_ignorable(cp)) continue;
		before = is_cased(cp);
		break;
	}
	if (!before) return false;
	for (uint j = i + 1; j < s.len; j += w)
	{
		uint cp = code_point_at(s, j, &w);
		if (is_case_ignorable(cp)) continue;
		return !is_cased(cp);
	}
	return true;
}

fn void push_code_point_unit(List {ushort}* out, uint cp) @inline
{
	if (cp < 0x10000)
	{
		out.push((ushort)cp);
		return;
	}
	cp -= 0x10000;
	out.push((ushort)(0xD800 + (cp >> 10)));
	out.push((ushort)(0xDC00 + (cp & 0x3FF)));
}

<*
 s in upper or lower case: full case mapping, as toUpperCase and toLowerCase do.

 @return? THROWN
*>
fn JsString*? Vm.change_case(&self, JsString* s, bool upper)
{
	// Plain ASCII, the common case, needs no tables.
	if (!s.wide)
	{
		bool ascii = true;
		foreach (c : s.narrow_units())
		{
			if (c >= 0x80)
			{
				ascii = false;
				break;
			}
		}
		if (ascii)
		{
			@pool()
			{
				char[] out = mem::temp_array(char, s.len);
				foreach (i, c : s.narrow_units()) out[i] = (char)(upper ? to_upper_cp(c) : to_lower_cp(c));
				return self.heap.string_from_latin1(out) ?? self.oom()~;
			};
		}
	}
	@pool()
	{
		List {ushort} out;
		out.tinit();
		uint w;
		for (uint i = 0; i < s.len; i += w)
		{
			uint cp = code_point_at(s, i, &w);
			if (!upper && cp == 0x3A3 && final_sigma(s, i))
			{
				out.push(0x3C2);
				continue;
			}
			String special = special_case(upper ? &UPPER_SPECIAL : &LOWER_SPECIAL, cp);
			if (special.len)
			{
				usz k = 0;
				while (k < special.len) push_code_point_unit(&out, utf8_next(special, &k));
				continue;
			}
			push_code_point_unit(&out, upper ? to_upper_cp(cp) : to_lower_cp(cp));
		}
		return self.heap.string_from_units(out.array_view()) ?? self.oom()~;
	};
}
