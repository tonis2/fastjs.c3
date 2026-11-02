module fastjs::rt;
import std::io;

<*
 Register-machine instructions, 32 bits each:
   ABC   op:8 a:8 b:8 c:8
   ABx   op:8 a:8 bx:16 (unsigned)
   AsBx  op:8 a:8 sbx:16 (signed, a jump offset relative to the next instruction)
   sAx   op:8 sax:24 (signed jump)
 K[x] is constant x. A call places callee, this and arguments in consecutive registers:
 r[a] = callee, r[a+1] = this, r[a+2..] = arguments; the callee's frame starts at r[a+1],
 so its r0 is `this`, and its result lands back in r[a].
*>
enum Op : char
{
	NOP,
	LOADK,          // ABx  r[a] = K[bx]
	LOADI,          // AsBx r[a] = sbx
	LOADUNDEF,      // A    r[a] = undefined
	LOADNULL,       // A
	LOADTRUE,       // A
	LOADFALSE,      // A
	LOADTDZ,        // A    r[a] = <uninitialized>
	MOVE,           // AB   r[a] = r[b]

	GETSLOT,        // ABx  r[a] = script slot bx (ReferenceError if uninitialized)
	SETSLOT,        // ABx  slot bx = r[a] (ReferenceError if uninitialized)
	INITSLOT,       // ABx  slot bx = r[a], no checks
	GETGLOBAL,      // ABx  r[a] = globalThis[K[bx]] (ReferenceError if missing)
	TYPEOFGLOBAL,   // ABx  r[a] = typeof globalThis[K[bx]], never throws
	SETGLOBAL,      // ABx  globalThis[K[bx]] = r[a]
	GETCAP,         // AB   r[a] = captures[b].value (ReferenceError if uninitialized)
	SETCAP,         // AB   captures[b].value = r[a] (ReferenceError if uninitialized)
	INITCAP,        // AB   captures[b].value = r[a]
	NEWBOX,         // A    r[a] = new box holding <uninitialized>
	GETBOX,         // AB   r[a] = box(r[b]).value (ReferenceError if uninitialized)
	SETBOX,         // AB   box(r[b]).value = r[a] (ReferenceError if uninitialized)
	INITBOX,        // AB   box(r[b]).value = r[a]
	CHECKTDZ,       // ABx  ReferenceError naming K[bx] if r[a] is uninitialized
	THROWCONST,     // ABx  TypeError: assignment to constant K[bx]

	ADD, SUB, MUL, DIV, MOD, POW,       // ABC r[a] = r[b] op r[c]
	BAND, BOR, BXOR, SHL, SAR, SHR,     // ABC
	EQ, NE, SEQ, SNE, LT, LE, GT, GE,   // ABC r[a] = r[b] op r[c]
	INSTANCEOF, IN,                     // ABC
	NEG, POS, NOT, BNOT, TYPEOF,        // AB  r[a] = op r[b]
	INC, DEC,       // AB   r[a] = ToNumber(r[b]) +/- 1
	TONUMERIC,      // AB   r[a] = ToNumber(r[b])
	TOSTRING,       // AB   r[a] = ToString(r[b])
	CONCATN,        // ABC  r[a] = r[b] + ... + r[b + c - 1], all strings: a template literal

	ADDK, SUBK, MULK, DIVK,             // ABC r[a] = r[b] op K[c] (a number constant)
	// Fused compare-and-branch, always followed by a JMP word: when the comparison is false
	// that jump is taken, otherwise it's skipped. One dispatch instead of compare + test + jump.
	JNLT, JNLE, JNGT, JNGE, JNSEQ, JNSNE, // AB  if !(r[a] op r[b]) jump

	JMP,            // sAx
	JMPF,           // AsBx if !r[a] jump
	JMPT,           // AsBx if r[a] jump
	JMPNULLISH,     // AsBx if r[a] is null or undefined jump
	JMPNOTNULLISH,  // AsBx
	JMPNOTUNDEF,    // AsBx if r[a] !== undefined jump

	GETPROP,        // ABC  r[a] = r[b][K[c]]
	SETPROP,        // ABC  r[a][K[b]] = r[c]
	GETELEM,        // ABC  r[a] = r[b][r[c]]
	SETELEM,        // ABC  r[a][r[b]] = r[c]
	DELPROP,        // ABC  r[a] = delete r[b][K[c]]
	DELELEM,        // ABC  r[a] = delete r[b][r[c]]

	NEWOBJ,         // A    r[a] = {}
	NEWARR,         // AB   r[a] = [] with room for b elements
	APPEND,         // AB   r[a].push(r[b])
	APPENDHOLE,     // A    r[a].length++
	APPENDSPREAD,   // AB   push every element of iterable r[b] onto r[a]
	INITPROP,       // ABC  define r[a][K[b]] = r[c]
	INITELEM,       // ABC  define r[a][r[b]] = r[c]
	INITGETTER,     // ABC  define getter r[c] for r[a][r[b]]
	INITSETTER,     // ABC  define setter r[c] for r[a][r[b]]
	COPYPROPS,      // AB   copy own enumerable properties of r[b] into r[a]
	OBJREST,        // ABC  r[a] = new object with r[b]'s own enumerable properties, except the keys in array r[c]
	NEWREGEXP,      // ABC  r[a] = new RegExp(pattern r[b], flags r[c])
	CLOSURE,        // ABx  r[a] = closure of nested function bx

	CALL,           // AB   r[a] = r[a](this = r[a+1], b args from r[a+2])
	CALLSPREAD,     // A    r[a] = r[a](this = r[a+1], ...array r[a+2])
	NEW,            // AB   r[a] = new r[a](b args from r[a+2])
	NEWSPREAD,      // A    r[a] = new r[a](...array r[a+2])
	RET,            // A    return r[a]
	RETUNDEF,       //      return undefined
	THROW,          // A    throw r[a]
	NEWTARGET,      // A    r[a] = new.target
	CURRENTFN,      // A    r[a] = the running function (a named function expression's own name)

	DEFCLASS,       // ABC  set up class r[a] extending r[b] (c = 1 if it has `extends`); r[a+1] = its prototype
	DEFMETHOD,      // ABC  define non-enumerable method r[c] as r[a][r[b]], with r[a] as its home object
	DEFGETTER,      // ABC  same, as a getter
	DEFSETTER,      // ABC  same, as a setter
	SETHOME,        // AB   function r[a]'s home object (where `super` looks) = r[b]
	SETFIELDS,      // AB   class r[a]'s instance-field initializer = r[b]
	GETFIELDS,      // A    r[a] = the running constructor's instance-field initializer
	SUPERCALL,      // AB   like NEW, calling the parent class with this frame's new.target
	SUPERCALLSPREAD,// A    same, arguments in an array
	SETTHIS,        // A    this = r[a]; ReferenceError if super() already ran
	CHECKTHIS,      // A    ReferenceError if r[a] is `this` before super()
	GETSUPER,       // ABx  r[a] = super[K[bx]], with `this` as the receiver

	GETITER,        // ABC  iterate r[b]: r[a] = iterator state, r[a+1] = step state; c = 1 always makes a real iterator
	FORNEXT,        // AsBx r[a+2] = next value, or jump when done
	ITERCLOSE,      // A    call iterator.return() when leaving a for-of early
	ITERSTEP,       // A    r[a+2] = next value, or undefined when done (array destructuring)
	ITERREST,       // AB   r[b] = array of the remaining values
	FORINKEYS,      // AB   r[a] = enumerable string keys of r[b] (an array), r[a+1] = 0

	GENSTART,       // A    a generator's parameters are set up: suspend, and return the generator object (via r[a])
	ASYNCSTART,     //      an async function begins: create its promise
	YIELD,          // ABC  suspend, yielding r[a]; on resume r[a] = the value sent, r[b] = the ResumeMode.
	                //      c = 0: throw() throws at the yield; c = 1 (yield*): it is passed on as a mode
	AWAIT,          // A    suspend until r[a] settles; on resume r[a] = its value, or its reason is thrown
	YSTEP,          // AsBx yield* step: send r[a+2] with mode r[a+3] to iterator r[a] (next method r[a+1]);
	                //      r[a+2] = the result's value; jump when done (r[a+3] stays 2 for a return)
}

macro uint encode_abc(Op op, uint a, uint b, uint c) => (uint)op | a << 8 | b << 16 | c << 24;
macro uint encode_abx(Op op, uint a, uint bx) => (uint)op | a << 8 | bx << 16;
macro uint encode_asbx(Op op, uint a, int sbx) => (uint)op | a << 8 | ((uint)(sbx + SBX_BIAS) & 0xFFFF) << 16;
macro uint encode_sax(Op op, int sax) => (uint)op | ((uint)(sax + SAX_BIAS) & 0xFFFFFF) << 8;

const int SBX_BIAS = 32767;
const int SAX_BIAS = 0x7FFFFF;
const int SBX_MAX = 32767;
const int SBX_MIN = -32767;

macro Op ins_op(uint i) => (Op)(char)(i & 0xFF);
macro uint ins_a(uint i) => (i >> 8) & 0xFF;
macro uint ins_b(uint i) => (i >> 16) & 0xFF;
macro uint ins_c(uint i) => i >> 24;
macro uint ins_bx(uint i) => i >> 16;
macro int ins_sbx(uint i) => (int)(i >> 16) - SBX_BIAS;
macro int ins_sax(uint i) => (int)(i >> 8) - SAX_BIAS;

enum IcKind : char
{
	EMPTY,
	OWN,
	PROTO,
	OWN_GETTER,
	PROTO_GETTER,
	ARRAY_LENGTH,
	// SETPROP/INITPROP that adds the property: shape -> new_shape.
	ADD,
}

<*
 One instruction's inline cache: the receiver shape last seen and where the property was. A
 prototype hit also pins the prototype's shape; an ADD pins the shape the object moves to.
 Cleared after every GC, since the shapes it points at may have been freed.
*>
struct IcEntry
{
	Shape* shape;
	Shape* holder_shape;
	Shape* new_shape;
	uint slot;
	IcKind kind;
}

<*
 A try region: an exception thrown at a pc in [start, end) jumps to handler with the exception in reg.
*>
struct Handler
{
	uint start;
	uint end;
	uint handler;
	uint reg;
}

<*
 Where a closure's capture comes from when CLOSURE runs: a box in the creating frame's register,
 or one of the creating function's own captures.
*>
struct CaptureSource
{
	bool from_capture;
	uint index;
}

<*
 What a call or iteration site looked like in the source, e.g. "o.foo", for error messages.
*>
struct SiteName
{
	uint pc;
	String text;
}

// SiteName.text for a spread argument, whose error V8 words differently.
const String SPREAD_ARGUMENT_SITE = "...";

<*
 A compiled function. Owned by its Script; the constants hold heap strings, so a Script must be
 kept reachable while its functions can run.
*>
struct FunctionProto
{
	String name;
	String source_name;
	// Its source text, for Function.prototype.toString: a slice of the owning script's copy.
	String source;
	uint[] code;
	uint[] lines;
	Value[] consts;
	// One inline cache per instruction (only property instructions use theirs).
	IcEntry[] ics;
	FunctionProto*[] protos;
	CaptureSource[] captures;
	Handler[] handlers;
	// Sorted by pc; only read when a call or iteration fails.
	SiteName[] site_names;
	uint nparams;
	// Function.length: parameters before the first default or rest.
	uint length;
	uint nregs;
	uint line;
	bool is_arrow;
	bool is_async;
	bool is_generator;
	bool has_rest;
	bool is_class_constructor;
	bool is_derived;
	// Methods, getters and setters can't be used with `new` and have no `prototype`.
	bool is_method;
}

fn bool FunctionProto.is_constructor(&self) => !self.is_arrow && (!self.is_method || self.is_class_constructor) && !self.is_generator && !self.is_async;

fn void FunctionProto.free(&self)
{
	foreach (p : self.protos)
	{
		p.free();
		free(p);
	}
	free(self.code);
	free(self.ics);
	free(self.lines);
	free(self.consts);
	free(self.protos);
	free(self.captures);
	free(self.handlers);
	foreach (n : self.site_names) free(n.text);
	free(self.site_names);
	free(self.name);
}

<*
 How the source wrote the callee or iterable of the instruction at pc, or "" when unknown.
*>
fn String FunctionProto.site_name(&self, uint pc)
{
	usz lo = 0;
	usz hi = self.site_names.len;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		uint at = self.site_names[mid].pc;
		if (at == pc) return self.site_names[mid].text;
		if (at < pc)
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

fn void FunctionProto.clear_ics(&self)
{
	mem::clear(self.ics.ptr, self.ics.len * IcEntry::size);
	foreach (p : self.protos) p.clear_ics();
}

fn bool dead_shape(Shape* s) @inline => s != null && (((GcHeader*)s).flags & GC_DOOMED);

<*
 After marking: forget only this function's cache entries that point at shapes about to be
 freed, so code stays warm across a collection. Nested functions are the caller's to visit.
*>
fn void FunctionProto.clear_dead_ics(&self)
{
	foreach (&ic : self.ics)
	{
		if (ic.kind == EMPTY) continue;
		if (dead_shape(ic.shape) || dead_shape(ic.holder_shape) || dead_shape(ic.new_shape)) *ic = {};
	}
}

<*
 Print the bytecode of f and its nested functions, for debugging the compiler.
*>
fn void FunctionProto.dump(&self, int depth = 0)
{
	io::printfn("%*sfunction %s (params %d, regs %d, captures %d)", depth * 2, "", self.name.len ? self.name : "<anonymous>", self.nparams, self.nregs, self.captures.len);
	foreach (pc, ins : self.code)
	{
		Op op = ins_op(ins);
		io::printf("%*s%4d  line %-4d %-14s", depth * 2, "", pc, self.lines[pc], op);
		switch (op)
		{
			case LOADK:
			case GETSLOT:
			case SETSLOT:
			case INITSLOT:
			case GETGLOBAL:
			case TYPEOFGLOBAL:
			case SETGLOBAL:
			case CHECKTDZ:
			case THROWCONST:
			case CLOSURE:
			case GETSUPER:
				io::printf("%d %d", ins_a(ins), ins_bx(ins));
			case LOADI:
				io::printf("%d %d", ins_a(ins), ins_sbx(ins));
			case JMPF:
			case JMPT:
			case JMPNULLISH:
			case JMPNOTNULLISH:
			case JMPNOTUNDEF:
			case FORNEXT:
			case YSTEP:
				io::printf("%d %d  -> %d", ins_a(ins), ins_sbx(ins), (int)pc + 1 + ins_sbx(ins));
			case JMP:
				io::printf("-> %d", (int)pc + 1 + ins_sax(ins));
			default:
				io::printf("%d %d %d", ins_a(ins), ins_b(ins), ins_c(ins));
		}
		io::printn();
	}
	foreach (h : self.handlers) io::printfn("%*s  try [%d, %d) -> %d, r%d", depth * 2, "", h.start, h.end, h.handler, h.reg);
	foreach (p : self.protos) p.dump(depth + 1);
}
