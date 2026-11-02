module fastjs::rt;

<*
 A JS value in 8 bytes. Doubles are stored as their raw bits; anything else lives in the NaN space,
 with a tag in the top 16 bits (0xFFF9..0xFFFD) and a payload below. x86's default NaN is
 0xFFF8..., which still reads as a double, so tags start one above it.
*>
typedef Value = ulong;

const ulong TAG_INT = 0xFFF9;
const ulong TAG_SPECIAL = 0xFFFA;
const ulong TAG_STRING = 0xFFFB;
const ulong TAG_OBJECT = 0xFFFC;
const ulong TAG_SYMBOL = 0xFFFD;
const ulong PAYLOAD_MASK = 0x0000_FFFF_FFFF_FFFF;
const ulong CANONICAL_NAN = 0x7FF8_0000_0000_0000;

const Value UNDEFINED = (Value)0xFFFA_0000_0000_0000;
const Value NULL = (Value)0xFFFA_0000_0000_0001;
const Value FALSE = (Value)0xFFFA_0000_0000_0002;
const Value TRUE = (Value)0xFFFA_0000_0000_0003;
// An array hole, or "no value" inside the engine. Never visible to scripts.
const Value EMPTY = (Value)0xFFFA_0000_0000_0004;
// A let/const binding before its declaration runs (the temporal dead zone).
const Value UNINITIALIZED = (Value)0xFFFA_0000_0000_0005;

fn ulong Value.tag(self) @inline => (ulong)self >> 48;
fn bool Value.is_double(self) @inline => (ulong)self >> 48 <= 0xFFF8;
fn bool Value.is_int(self) @inline => (ulong)self >> 48 == TAG_INT;
fn bool Value.is_number(self) @inline => self.is_double() || self.is_int();
fn bool Value.is_string(self) @inline => (ulong)self >> 48 == TAG_STRING;
fn bool Value.is_object(self) @inline => (ulong)self >> 48 == TAG_OBJECT;
fn bool Value.is_symbol(self) @inline => (ulong)self >> 48 == TAG_SYMBOL;
fn bool Value.is_undefined(self) @inline => self == UNDEFINED;
fn bool Value.is_null(self) @inline => self == NULL;
fn bool Value.is_nullish(self) @inline => self == UNDEFINED || self == NULL;
fn bool Value.is_bool(self) @inline => self == TRUE || self == FALSE;
fn bool Value.is_heap(self) @inline => (ulong)self >> 48 >= TAG_STRING;

fn int Value.as_int(self) @inline => (int)(uint)(ulong)self;
fn double Value.as_double(self) @inline => bitcast((ulong)self, double);
fn bool Value.as_bool(self) @inline => self == TRUE;
fn void* Value.as_pointer(self) @inline => (void*)(uptr)((ulong)self & PAYLOAD_MASK);
fn JsString* Value.as_string(self) @inline => (JsString*)(uptr)((ulong)self & PAYLOAD_MASK);

<*
 The numeric value of an int or double.

 @require self.is_number() : "Not a number"
*>
fn double Value.as_number(self) @inline => self.is_int() ? (double)self.as_int() : self.as_double();

<*
 A number, kept as an int32 when it is one exactly (and not -0), else as a double.
*>
fn Value number(double d) @inline
{
	// Range-check first: converting an out-of-range double to int is undefined, and the optimizer
	// will happily fold the round-trip test below to true.
	if (!(d >= -2147483648.0 && d <= 2147483647.0)) return double_value(d);
	int i = (int)d;
	if ((double)i == d && (i != 0 || bitcast(d, ulong) == 0)) return integer(i);
	return double_value(d);
}

<*
 A double, with any NaN replaced by the canonical one so that it can't collide with a tag.
*>
fn Value double_value(double d) @inline
{
	if (d != d) return (Value)CANONICAL_NAN;
	return (Value)bitcast(d, ulong);
}

fn Value integer(int i) @inline => (Value)(TAG_INT << 48 | (ulong)(uint)i);
fn Value boolean(bool b) @inline => b ? TRUE : FALSE;
fn Value string_value(JsString* s) @inline => (Value)(TAG_STRING << 48 | (ulong)(uptr)s);
fn Value pointer_value(ulong tag, void* p) @inline => (Value)(tag << 48 | (ulong)(uptr)p);

enum HeapKind : char
{
	STRING,
	SYMBOL,
	OBJECT,
	BOX,
	SHAPE,
	// A JsStrBuf: the units of strings built by appending.
	STRBUF,
}

<*
 The first field of every garbage-collected allocation.
*>
struct GcHeader
{
	GcHeader* next;
	HeapKind kind;
	bool marked;
	ushort flags;
	uint size;
}
