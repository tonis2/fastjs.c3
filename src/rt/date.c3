module fastjs::rt;
import std::math, std::time, std::core::dstring, libc;

// Date: a time value in milliseconds since 1970 UTC (NaN for an invalid date), with the
// spec's calendar arithmetic. Local time comes from libc (localtime_r), so TZ is honoured.
// The strings follow V8's formats; toLocale*String are en-US. The one difference from V8 is
// the time zone's name in toString, which V8 gets from ICU: this gives libc's abbreviation
// (e.g. "EET"), except that UTC is "Coordinated Universal Time" as in V8.

struct JsDate
{
	inline JsObject object;
	double time;
}

const double MS_PER_DAY = 86400000.0;
const double MAX_TIME = 8.64e15;
const String[7] WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const String[12] MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

// The fields a time value splits into, in setter order.
enum DateField : char
{
	YEAR,
	MONTH,
	DATE,
	HOURS,
	MINUTES,
	SECONDS,
	MS,
	// Getters only.
	DAY,
}

fn bool finite(double t) @inline => t == t && t != double::inf && t != -double::inf;

fn double time_clip(double t)
{
	if (!finite(t) || math::abs(t) > MAX_TIME) return double::nan;
	return math::trunc(t) + 0.0;
}

fn double floor_mod(double a, double b) @inline
{
	double r = a - b * math::floor(a / b);
	return r;
}

<*
 Days since 1970-01-01 of a proleptic Gregorian date (month 1-12).
*>
fn long days_from_civil(long y, long m, long d)
{
	y -= m <= 2 ? 1 : 0;
	long era = (y >= 0 ? y : y - 399) / 400;
	long yoe = y - era * 400;
	long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
	long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}

fn void civil_from_days(long z, long* y, long* m, long* d)
{
	z += 719468;
	long era = (z >= 0 ? z : z - 146096) / 146097;
	long doe = z - era * 146097;
	long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	long mp = (5 * doy + 2) / 153;
	*d = doy - (153 * mp + 2) / 5 + 1;
	*m = mp < 10 ? mp + 3 : mp - 9;
	*y = yoe + era * 400 + (*m <= 2 ? 1 : 0);
}

<*
 The spec's MakeDay and MakeDate, with months past 11 carrying into years.
*>
fn double make_day(double year, double month, double date)
{
	if (!finite(year) || !finite(month) || !finite(date)) return double::nan;
	double y = math::trunc(year) + math::floor(math::trunc(month) / 12);
	double m = floor_mod(math::trunc(month), 12);
	if (math::abs(y) > 400000) return double::nan;
	return (double)days_from_civil((long)y, (long)m + 1, 1) + math::trunc(date) - 1;
}

fn double make_time(double h, double m, double s, double ms)
{
	if (!finite(h) || !finite(m) || !finite(s) || !finite(ms)) return double::nan;
	return math::trunc(h) * 3600000.0 + math::trunc(m) * 60000.0 + math::trunc(s) * 1000.0 + math::trunc(ms);
}

fn double make_date(double day, double time) => day * MS_PER_DAY + time;

<*
 Split t (finite) into its fields.
*>
fn void split_time(double t, double[8]* out)
{
	double day = math::floor(t / MS_PER_DAY);
	double within = t - day * MS_PER_DAY;
	long y;
	long m;
	long d;
	civil_from_days((long)day, &y, &m, &d);
	(*out)[DateField.YEAR.ordinal] = (double)y;
	(*out)[DateField.MONTH.ordinal] = (double)(m - 1);
	(*out)[DateField.DATE.ordinal] = (double)d;
	(*out)[DateField.HOURS.ordinal] = math::floor(within / 3600000.0);
	(*out)[DateField.MINUTES.ordinal] = floor_mod(math::floor(within / 60000.0), 60);
	(*out)[DateField.SECONDS.ordinal] = floor_mod(math::floor(within / 1000.0), 60);
	(*out)[DateField.MS.ordinal] = floor_mod(within, 1000);
	(*out)[DateField.DAY.ordinal] = floor_mod(day + 4, 7);
}

fn double join_time(double[8]* f)
{
	return make_date(make_day((*f)[0], (*f)[1], (*f)[2]), make_time((*f)[3], (*f)[4], (*f)[5], (*f)[6]));
}

<*
 The local zone's offset from UTC at UTC time t, in milliseconds, and its abbreviation.
*>
fn double local_offset(double t, ZString* zone = null)
{
	if (!finite(t)) return 0;
	libc::Time_t secs = (libc::Time_t)math::floor(t / 1000.0);
	libc::Tm tm;
	if (!libc::localtime_r(&secs, &tm)) return 0;
	if (zone) *zone = (ZString)tm.tm_zone;
	return (double)tm.tm_gmtoff * 1000.0;
}

fn double local_time(double t) => t + local_offset(t);

<*
 The UTC time of a local wall-clock time, settling the offset that applies there.
*>
fn double utc_time(double local)
{
	if (!finite(local)) return double::nan;
	double guess = local - local_offset(local);
	return local - local_offset(guess);
}

// libc's zone abbreviations, and the names V8 (ICU) prints for them in toString.
const String[2][29] ZONE_NAMES = {
	{ "UTC", "Coordinated Universal Time" }, { "GMT", "Greenwich Mean Time" },
	{ "BST", "British Summer Time" }, { "IST", "India Standard Time" },
	{ "WET", "Western European Standard Time" }, { "WEST", "Western European Summer Time" },
	{ "CET", "Central European Standard Time" }, { "CEST", "Central European Summer Time" },
	{ "EET", "Eastern European Standard Time" }, { "EEST", "Eastern European Summer Time" },
	{ "MSK", "Moscow Standard Time" },
	{ "EST", "Eastern Standard Time" }, { "EDT", "Eastern Daylight Time" },
	{ "CST", "Central Standard Time" }, { "CDT", "Central Daylight Time" },
	{ "MST", "Mountain Standard Time" }, { "MDT", "Mountain Daylight Time" },
	{ "PST", "Pacific Standard Time" }, { "PDT", "Pacific Daylight Time" },
	{ "AKST", "Alaska Standard Time" }, { "AKDT", "Alaska Daylight Time" },
	{ "HST", "Hawaii-Aleutian Standard Time" }, { "JST", "Japan Standard Time" },
	{ "KST", "Korean Standard Time" }, { "AEST", "Australian Eastern Standard Time" },
	{ "AEDT", "Australian Eastern Daylight Time" }, { "NZST", "New Zealand Standard Time" },
	{ "NZDT", "New Zealand Daylight Time" }, { "SAST", "South Africa Standard Time" },
};

fn String zone_name(String abbreviation)
{
	if (abbreviation == "") return "Coordinated Universal Time";
	foreach (pair : ZONE_NAMES)
	{
		if (pair[0] == abbreviation) return pair[1];
	}
	return abbreviation;
}

fn JsDate*? Vm.this_date(&self, Value v)
{
	if (v.is_object() && v.as_object().kind == DATE) return (JsDate*)v.as_object();
	return self.throw_error(TYPE_ERROR, "this is not a Date object.")~;
}

<*
 @return? THROWN
*>
fn Value? Vm.new_date(&self, double t, JsObject* proto = null)
{
	JsDate* d = (JsDate*)self.heap.new_object(proto ? proto : self.date_proto, DATE, JsDate::size) ?? self.oom()~!;
	d.time = time_clip(t);
	return object_value(d);
}

fn double now_ms() => math::floor((double)time::now().to_seconds() * 1000.0);

fn Value? native_date(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	// Date() without new is today's date as a string.
	if (this_value != EMPTY) return string_value(vm.date_string(now_ms(), FULL)!);
	double t;
	switch (args.len)
	{
		case 0:
			t = now_ms();
		case 1:
			Value v = args[0];
			if (v.is_object() && v.as_object().kind == DATE)
			{
				t = ((JsDate*)v.as_object()).time;
				break;
			}
			Value p = vm.to_primitive(v)!;
			t = p.is_string() ? parse_date(p.as_string().tutf8()) : vm.to_number(p)!;
		default:
			double[7] f = { 0, 0, 1, 0, 0, 0, 0 };
			for (usz i = 0; i < 7 && i < args.len; i++) f[i] = vm.to_number(args[i])!;
			// Two-digit years are 1900s.
			if (finite(f[0]) && f[0] >= 0 && f[0] <= 99 && math::trunc(f[0]) == f[0]) f[0] += 1900;
			t = utc_time(make_date(make_day(f[0], f[1], f[2]), make_time(f[3], f[4], f[5], f[6])));
	}
	return vm.new_date(t);
}

fn Value? native_date_utc(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double[7] f = { double::nan, 0, 1, 0, 0, 0, 0 };
	for (usz i = 0; i < 7 && i < args.len; i++) f[i] = vm.to_number(args[i])!;
	if (finite(f[0]) && f[0] >= 0 && f[0] <= 99 && math::trunc(f[0]) == f[0]) f[0] += 1900;
	return number(time_clip(make_date(make_day(f[0], f[1], f[2]), make_time(f[3], f[4], f[5], f[6]))));
}

fn Value? native_date_parse(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	@pool()
	{
		return number(time_clip(parse_date(vm.to_string(arg(args, 0))!.tutf8())));
	};
}

fn Value? native_date_now(Vm* vm, Value this_value, Value[] args, JsFunction* callee) => number(now_ms());

fn Value? native_date_value(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return number(vm.this_date(this_value)!.time);
}

// magic: the DateField, plus 16 for the UTC version.
fn Value? native_date_get(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double t = vm.this_date(this_value)!.time;
	if (!finite(t)) return number(double::nan);
	if (callee.magic < 16) t = local_time(t);
	double[8] f;
	split_time(t, &f);
	return number(f[callee.magic & 15]);
}

fn Value? native_date_timezone_offset(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	double t = vm.this_date(this_value)!.time;
	if (!finite(t)) return number(double::nan);
	// 0.0 - x, not -x: a zone at UTC is +0, not -0.
	return number(0.0 - local_offset(t) / 60000.0);
}

fn Value? native_date_set_time(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsDate* d = vm.this_date(this_value)!;
	d.time = time_clip(vm.to_number(arg(args, 0))!);
	return number(d.time);
}

// magic: the first DateField the setter sets, plus 16 for the UTC version. It takes that field
// and the ones after it in its group: year, month, date or hours, minutes, seconds, ms.
fn Value? native_date_set(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	JsDate* d = vm.this_date(this_value)!;
	bool utc = callee.magic >= 16;
	uint first = (uint)(callee.magic & 15);
	uint count = first <= DateField.DATE.ordinal ? DateField.DATE.ordinal + 1 - first : DateField.MS.ordinal + 1 - first;
	double t = d.time;
	// setFullYear on an invalid date starts from +0; every other setter keeps it invalid.
	if (!finite(t))
	{
		if (first != DateField.YEAR.ordinal)
		{
			for (uint i = 0; i < count && i < args.len; i++) (void)vm.to_number(args[i])!;
			return number(double::nan);
		}
		t = 0;
	}
	else if (!utc)
	{
		t = local_time(t);
	}
	double[8] f;
	split_time(t, &f);
	if (args.len == 0) f[first] = double::nan;
	for (uint i = 0; i < count && i < args.len; i++) f[first + i] = vm.to_number(args[i])!;
	double result = join_time(&f);
	d.time = time_clip(utc ? result : utc_time(result));
	return number(d.time);
}

enum DateStringKind : char
{
	FULL,
	DATE_ONLY,
	TIME_ONLY,
	UTC,
	ISO,
	LOCALE,
	LOCALE_DATE,
	LOCALE_TIME,
}

<*
 @return? THROWN
*>
fn JsString*? Vm.date_string(&self, double t, DateStringKind kind)
{
	if (!finite(t))
	{
		if (kind == ISO) return self.throw_error(RANGE_ERROR, "Invalid time value")~;
		return self.heap.string_from_utf8("Invalid Date") ?? self.oom()~;
	}
	@pool()
	{
		DString out;
		out.tinit();
		double[8] f;
		if (kind == UTC || kind == ISO)
		{
			split_time(t, &f);
		}
		else
		{
			split_time(local_time(t), &f);
		}
		int year = (int)f[0];
		int month = (int)f[1];
		int date = (int)f[2];
		int hours = (int)f[3];
		int minutes = (int)f[4];
		int seconds = (int)f[5];
		int ms = (int)f[6];
		String weekday = WEEKDAYS[(int)f[7]];
		String year_text = year >= 0 ? string::tformat("%04d", year) : string::tformat("-%06d", -year);
		switch (kind)
		{
			case ISO:
				if (year < 0 || year > 9999)
				{
					out.appendf("%s%06d", year < 0 ? "-" : "+", year < 0 ? -year : year);
				}
				else
				{
					out.appendf("%04d", year);
				}
				out.appendf("-%02d-%02dT%02d:%02d:%02d.%03dZ", month + 1, date, hours, minutes, seconds, ms);
			case UTC:
				out.appendf("%s, %02d %s %s %02d:%02d:%02d GMT", weekday, date, MONTHS[month], year_text, hours, minutes, seconds);
			case LOCALE:
			case LOCALE_DATE:
			case LOCALE_TIME:
				if (kind != LOCALE_TIME) out.appendf("%d/%d/%d", month + 1, date, year);
				if (kind == LOCALE) out.append(", ");
				if (kind != LOCALE_DATE) out.appendf("%d:%02d:%02d %s", hours % 12 == 0 ? 12 : hours % 12, minutes, seconds, hours < 12 ? "AM" : "PM");
			default:
				if (kind != TIME_ONLY) out.appendf("%s %s %02d %s", weekday, MONTHS[month], date, year_text);
				if (kind == FULL) out.append(' ');
				if (kind != DATE_ONLY)
				{
					ZString zone;
					int offset = (int)(local_offset(t, &zone) / 60000.0);
					int a = offset < 0 ? -offset : offset;
					String name = zone_name(zone ? zone.str_view() : "");
					out.appendf("%02d:%02d:%02d GMT%s%02d%02d (%s)", hours, minutes, seconds, offset < 0 ? "-" : "+", a / 60, a % 60, name);
				}
		}
		return self.heap.string_from_utf8(out.str_view()) ?? self.oom()~;
	};
}

fn Value? native_date_to_string(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	return string_value(vm.date_string(vm.this_date(this_value)!.time, DateStringKind::from_ordinal(callee.magic))!);
}

fn Value? native_date_to_json(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	Value p = vm.to_primitive(this_value)!;
	if (p.is_number() && !finite(p.as_number())) return NULL;
	Value method = vm.get(this_value, vm.atom_value("toISOString")!)!;
	return vm.call(method, this_value, {});
}

fn Value? native_date_to_primitive(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
{
	if (!this_value.is_object()) return vm.throw_error(TYPE_ERROR, "Date.prototype[Symbol.toPrimitive] called on a non-object")~;
	Value hint = arg(args, 0);
	bool want_number = hint.is_string() && hint.as_string().tutf8() == "number";
	return vm.to_primitive(this_value, !want_number);
}

// ---- parsing ----

fn int month_index(String word)
{
	foreach (i, m : MONTHS)
	{
		if (word.len >= 3 && word[:3].to_lower_tcopy() == m.to_lower_tcopy()) return (int)i;
	}
	return -1;
}

fn bool digits(String s, usz at, usz n)
{
	if (at + n > s.len) return false;
	for (usz i = at; i < at + n; i++)
	{
		if (s[i] < '0' || s[i] > '9') return false;
	}
	return true;
}

fn double number_at(String s, usz at, usz n)
{
	double v = 0;
	for (usz i = at; i < at + n; i++) v = v * 10 + (double)(s[i] - '0');
	return v;
}

<*
 Date.parse: the ISO format (date-only forms are UTC, date-times without a zone are local),
 then V8's own looser forms, e.g. what toString and toUTCString produce, "Jan 2 2020 10:00",
 "2020/01/02". NaN when it can't tell.
*>
fn double parse_date(String s)
{
	s = s.trim();
	double iso = parse_iso(s);
	if (iso == iso) return iso;
	return parse_loose(s);
}

fn double parse_iso(String s)
{
	usz i = 0;
	double year;
	if (s.len > 0 && (s[0] == '+' || s[0] == '-'))
	{
		if (!digits(s, 1, 6)) return double::nan;
		year = number_at(s, 1, 6);
		if (s[0] == '-')
		{
			if (year == 0) return double::nan;
			year = -year;
		}
		i = 7;
	}
	else
	{
		if (!digits(s, 0, 4)) return double::nan;
		year = number_at(s, 0, 4);
		i = 4;
	}
	double month = 0;
	double day = 1;
	if (i < s.len && s[i] == '-')
	{
		if (!digits(s, i + 1, 2)) return double::nan;
		month = number_at(s, i + 1, 2) - 1;
		i += 3;
		if (i < s.len && s[i] == '-')
		{
			if (!digits(s, i + 1, 2)) return double::nan;
			day = number_at(s, i + 1, 2);
			i += 3;
		}
	}
	if (month < 0 || month > 11 || day < 1 || day > 31) return double::nan;
	if (i == s.len) return make_date(make_day(year, month, day), 0);
	if (s[i] != 'T' && s[i] != 't' && s[i] != ' ') return double::nan;
	i++;
	if (!digits(s, i, 2) || i + 2 >= s.len || s[i + 2] != ':' || !digits(s, i + 3, 2)) return double::nan;
	double h = number_at(s, i, 2);
	double mi = number_at(s, i + 3, 2);
	double sec = 0;
	double ms = 0;
	i += 5;
	if (i < s.len && s[i] == ':')
	{
		if (!digits(s, i + 1, 2)) return double::nan;
		sec = number_at(s, i + 1, 2);
		i += 3;
		if (i < s.len && (s[i] == '.' || s[i] == ','))
		{
			i++;
			usz start = i;
			double scale = 100;
			while (i < s.len && s[i] >= '0' && s[i] <= '9')
			{
				ms += (double)(s[i] - '0') * scale;
				scale /= 10;
				i++;
			}
			if (i == start) return double::nan;
			ms = math::floor(ms);
		}
	}
	if (h > 24 || mi > 59 || sec > 59 || (h == 24 && (mi > 0 || sec > 0 || ms > 0))) return double::nan;
	double local = make_date(make_day(year, month, day), make_time(h, mi, sec, ms));
	if (i == s.len) return utc_time(local);
	if (s[i] == 'Z' || s[i] == 'z') return i + 1 == s.len ? local : double::nan;
	if (s[i] != '+' && s[i] != '-') return double::nan;
	if (!digits(s, i + 1, 2) || i + 3 >= s.len || s[i + 3] != ':' || !digits(s, i + 4, 2) || i + 6 != s.len) return double::nan;
	double offset = (number_at(s, i + 1, 2) * 60 + number_at(s, i + 4, 2)) * 60000.0;
	return s[i] == '+' ? local - offset : local + offset;
}

<*
 Words and numbers in any order, as V8's legacy parser takes them: a month name, a day, a year,
 hh:mm[:ss], AM/PM, and a zone (GMT, UTC, Z, +hhmm). Without a zone the time is local.
*>
fn double parse_loose(String s)
{
	double year = double::nan;
	double month = double::nan;
	double day = double::nan;
	double h = 0;
	double mi = 0;
	double sec = 0;
	double offset = double::nan;
	int pm = -1;
	// "GMT+0130": the offset after GMT counts.
	bool after_gmt = false;
	double[3] nums;
	int nnums = 0;
	usz i = 0;
	while (i < s.len)
	{
		char c = s[i];
		if (c == '(')
		{
			// A parenthesized comment, such as the zone name toString appends.
			while (i < s.len && s[i] != ')') i++;
			i++;
			continue;
		}
		if ((c == '+' || c == '-') && digits(s, i + 1, 2) && (offset != offset || after_gmt) && (nnums >= 1 || month == month))
		{
			usz start = i + 1;
			usz j = start;
			while (j < s.len && s[j] >= '0' && s[j] <= '9') j++;
			if (j - start == 4)
			{
				double off = (number_at(s, start, 2) * 60 + number_at(s, start + 2, 2)) * 60000.0;
				offset = c == '+' ? off : -off;
				after_gmt = false;
				i = j;
				continue;
			}
			if (j < s.len && s[j] == ':' && j - start == 2 && digits(s, j + 1, 2))
			{
				double off = (number_at(s, start, 2) * 60 + number_at(s, j + 1, 2)) * 60000.0;
				offset = c == '+' ? off : -off;
				after_gmt = false;
				i = j + 3;
				continue;
			}
		}
		if (c >= '0' && c <= '9')
		{
			usz start = i;
			while (i < s.len && s[i] >= '0' && s[i] <= '9') i++;
			double v = number_at(s, start, i - start);
			if (i < s.len && s[i] == ':')
			{
				h = v;
				if (!digits(s, i + 1, 2)) return double::nan;
				mi = number_at(s, i + 1, 2);
				i += 3;
				if (i < s.len && s[i] == ':' && digits(s, i + 1, 2))
				{
					sec = number_at(s, i + 1, 2);
					i += 3;
				}
				continue;
			}
			if (nnums == 3) return double::nan;
			nums[nnums++] = v;
			continue;
		}
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
		{
			usz start = i;
			while (i < s.len && ((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z'))) i++;
			String word = s[start:i - start].to_lower_tcopy();
			switch
			{
				case word == "am": pm = 0;
				case word == "pm": pm = 1;
				case word == "gmt" || word == "utc" || word == "ut" || word == "z":
					if (offset != offset)
					{
						offset = 0;
						after_gmt = true;
					}
				case month_index(word) >= 0 && month != month:
					month = month_index(word);
				case word.len >= 3 && WEEKDAYS[0].len == 3:
					// A weekday name, or a word the date doesn't need.
					break;
				default:
					return double::nan;
			}
			continue;
		}
		i++;
	}
	// The numbers: with a month name, day then year; otherwise month/day/year, or year/month/day.
	if (month == month)
	{
		if (nnums < 2) return double::nan;
		day = nums[0];
		year = nums[1];
	}
	else
	{
		if (nnums < 3) return double::nan;
		if (nums[0] > 31)
		{
			year = nums[0];
			month = nums[1] - 1;
			day = nums[2];
		}
		else
		{
			month = nums[0] - 1;
			day = nums[1];
			year = nums[2];
		}
	}
	if (year >= 0 && year <= 49) year += 2000;
	if (year >= 50 && year <= 99) year += 1900;
	if (pm == 1 && h < 12) h += 12;
	if (pm == 0 && h == 12) h = 0;
	double local = make_date(make_day(year, month, day), make_time(h, mi, sec, 0));
	if (offset != offset) return utc_time(local);
	return local - offset;
}

fn void? Vm.init_date(&self)
{
	Heap* h = &self.heap;
	self.date_proto = h.new_object(self.object_proto)!;
	JsFunction* ctor = self.define_constructor("Date", &native_date, 7, self.date_proto)!;
	self.define_native(ctor, "now", &native_date_now, 0)!;
	self.define_native(ctor, "UTC", &native_date_utc, 7)!;
	self.define_native(ctor, "parse", &native_date_parse, 1)!;
	JsObject* p = self.date_proto;
	self.define_native(p, "getTime", &native_date_value, 0)!;
	self.define_native(p, "valueOf", &native_date_value, 0)!;
	self.define_native(p, "setTime", &native_date_set_time, 1)!;
	self.define_native(p, "getTimezoneOffset", &native_date_timezone_offset, 0)!;
	foreach (i, name : (String[8]){ "FullYear", "Month", "Date", "Hours", "Minutes", "Seconds", "Milliseconds", "Day" })
	{
		self.define_native(p, string::tformat("get%s", name), &native_date_get, 0)!.magic = (int)i;
		self.define_native(p, string::tformat("getUTC%s", name), &native_date_get, 0)!.magic = (int)i + 16;
		if (i == DateField.DAY.ordinal) continue;
		uint count = i <= DateField.DATE.ordinal ? DateField.DATE.ordinal + 1 - (uint)i : DateField.MS.ordinal + 1 - (uint)i;
		self.define_native(p, string::tformat("set%s", name), &native_date_set, count)!.magic = (int)i;
		self.define_native(p, string::tformat("setUTC%s", name), &native_date_set, count)!.magic = (int)i + 16;
	}
	foreach (i, name : (String[8]){ "toString", "toDateString", "toTimeString", "toUTCString", "toISOString", "toLocaleString", "toLocaleDateString", "toLocaleTimeString" })
	{
		self.define_native(p, name, &native_date_to_string, 0)!.magic = (int)i;
	}
	self.define_native(p, "toGMTString", &native_date_to_string, 0)!.magic = (int)DateStringKind.UTC.ordinal;
	self.define_native(p, "toJSON", &native_date_to_json, 1)!;
	JsFunction* prim = self.new_native("[Symbol.toPrimitive]", &native_date_to_primitive, 1)!;
	p.add(h, self.sym_to_primitive, object_value(prim), { .configurable = true })!;
}
