<*
 Typed host functions: write a plain C3 function and let `@bind` make the JS glue.

 	fn float? scale(Game* g, float x, Opt {float} by) { … }
 	js.@bind(host_object, "scale", &scale, game)!;

 The glue reads each parameter's type at compile time and converts the JS argument for it.
 Parameters that take no JS argument: the host pointer (the type of what `@bind` was given),
 `Engine*`, and `Call*` (the raw call, for anything unusual).

 | C3 parameter | JS argument |
 |---|---|
 | `double` `float` | Number(v); a missing argument is 0 |
 | integer types | Number(v) truncated; NaN and a missing argument are 0 |
 | `bool` | truthiness; missing is false |
 | `String` | String(v) in temp memory, valid for the call; missing is "" |
 | `Value` | v itself |
 | `float[]` `double[]` `int[]` `uint[]` `short[]` `ushort[]` | a typed array of that element type, read in place; missing is empty |
 | `char[]` | the bytes of any typed array, DataView or ArrayBuffer |
 | `Opt {T}` | a T, and whether it was given at all (undefined counts as not given) |
 | any `T` with `fn void? T.from_js(&self, Call* c, int at)` | whatever that method reads |

 The result converts the same way back: nothing for `void`, a number, a boolean, a string,
 a `Value` as is, or `fn Value? T.to_js(&self, Engine* js)`. An optional result that is empty
 must have thrown already: `return c.fail("…")~` or `js.fail("…")~`, or a converter did.

 `@method` is the same for a host class: its first converted parameter reads `this`, and the
 function goes on the class's prototype.
*>
module fastjs::js;
import fastjs::rt, std::math;

<*
 What argument `at` holds; `this` when at is -1 (a method's receiver).
*>
fn Value Call.get(&self, int at) @inline
{
	if (at < 0) return self.this;
	return at < self.args.len ? self.args[at] : UNDEFINED;
}

fn bool Call.has(&self, int at) @inline => at < 0 || at < self.args.len;

<*
 Which argument, for a message: "argument 2", or "the receiver". Temp memory.
*>
fn String Call.which(&self, int at)
{
	String name = self.callee ? self.callee.native_name : "";
	if (at < 0) return string::tformat("%s: the receiver", name);
	return string::tformat("%s: argument %d", name, at + 1);
}

fn fault Call.type_error(&self, int at, String wanted)
{
	return self.js.vm.throw_error(TYPE_ERROR, "%s must be %s, not %s", self.which(at), wanted, self.js.describe(self.get(at)));
}

<*
 Argument at as a number; 0 when it is missing.

 @return? THREW
*>
fn double? Call.number(&self, int at)
{
	if (!self.has(at)) return 0;
	return self.js.number(self.get(at));
}

<*
 Argument at as an integer: truncated, NaN and infinities and a missing argument as 0.

 @return? THREW
*>
fn long? Call.integer(&self, int at)
{
	Value v = self.get(at);
	if (v.is_int()) return v.as_int();
	if (!self.has(at)) return 0;
	double d = self.js.number(v)!;
	if (!math::is_finite(d)) return 0;
	if (d >= 9.2e18) return long::max;
	if (d <= -9.2e18) return long::min;
	return (long)d;
}

fn bool Call.truth(&self, int at) => rt::truthy(self.get(at));

<*
 Argument at as text in temp memory; "" when it is missing.
*>
fn String Call.text(&self, int at)
{
	if (!self.has(at)) return "";
	Value v = self.get(at);
	if (v.is_string()) return v.as_string().tutf8();
	return self.js.text(v, tmem);
}

<*
 A typed array of element kind, as a slice. Missing or undefined is empty.

 @return? THREW
*>
macro Call.@elements(&self, int at, ViewKind $kind, $Elem, String $name)
{
	Value v = self.get(at);
	if (!self.has(at) || v.is_undefined()) return ($Elem[]){};
	View? w = view(v);
	if (catch w) return self.type_error(at, $name)~;
	if (w.kind != $kind) return self.type_error(at, $name)~;
	return w.ptr ? (($Elem*)w.ptr)[:w.len] : ($Elem[]){};
}

<*
 The bytes of any typed array, DataView or ArrayBuffer; missing or undefined is empty.

 @return? THREW
*>
fn char[]? Call.bytes_of(&self, int at)
{
	Value v = self.get(at);
	if (!self.has(at) || v.is_undefined()) return (char[]){};
	View? w = view(v);
	if (catch w) return self.type_error(at, "a typed array or ArrayBuffer")~;
	return w.ptr ? w.ptr[:w.byte_len] : (char[]){};
}

<*
 Read argument at as $Type, by the table at the top of this file.

 @return? THREW
*>
macro read_arg(Call* c, int at, $Type)
{
	$Type? r;
	$switch:
		$case $Type == Value: r = c.get(at);
		$case $Type == bool: r = c.truth(at);
		$case $Type == double: r = c.number(at);
		$case $Type == float: r = (float)c.number(at);
		$case types::is_int($Type): r = ($Type)c.integer(at);
		$case $Type == String: r = c.text(at);
		$case $Type == float[]: r = c.@elements(at, FLOAT32, float, "a Float32Array");
		$case $Type == double[]: r = c.@elements(at, FLOAT64, double, "a Float64Array");
		$case $Type == int[]: r = c.@elements(at, INT32, int, "an Int32Array");
		$case $Type == uint[]: r = c.@elements(at, UINT32, uint, "a Uint32Array");
		$case $Type == short[]: r = c.@elements(at, INT16, short, "an Int16Array");
		$case $Type == ushort[]: r = c.@elements(at, UINT16, ushort, "a Uint16Array");
		$case $Type == char[]: r = c.bytes_of(at);
		$default:
			$Type out;
			$if $defined(out.from_js(c, at)):
				if (catch err = out.from_js(c, at))
				{
					r = err~;
				}
				else
				{
					r = out;
				}
			$else
				$error "This parameter type has no conversion from JS: give it `fn void? T.from_js(&self, Call* c, int at)`";
			$endif
	$endswitch
	return r;
}

<*
 A C3 result as a JS value.

 @return? THREW
*>
macro Value? to_value(Engine* js, result)
{
	$switch:
		$case $Typeof(result) == Value: return result;
		$case $Typeof(result) == bool: return rt::boolean(result);
		$case $Typeof(result) == String: return js.string(result);
		$case types::is_int($Typeof(result)) ||| types::is_float($Typeof(result)): return rt::number((double)result);
		$case $defined(result.to_js(js)): return result.to_js(js);
		$default: $error "This result type has no conversion to JS: give it `fn Value? T.to_js(&self, Engine* js)`";
	$endswitch
}

<*
 Whether a parameter of $Type is filled without a JS argument.
*>
macro bool @injected($Type, $Host) @const
{
	return $Type == Call* ||| $Type == Engine* ||| ($Host != void* &&& $Type == $Host);
}

<*
 Call $func with every parameter converted. Recurses once per parameter; $at counts the JS
 arguments used so far.
*>
macro @invoke($func, $Host, $at, Call* c, ...) @local
{
	var $params = $Typeof($func)::params;
	$if $vaarg.len == $params.len:
		return $func(...$vaarg);
	$else
		$switch:
			$case $params[$vaarg.len].type == Call*::typeid:
				return @invoke($func, $Host, $at, c, ...$vaarg, c);
			$case $params[$vaarg.len].type == Engine*::typeid:
				return @invoke($func, $Host, $at, c, ...$vaarg, c.js);
			$case $Host != void* &&& $params[$vaarg.len].type == $Host::typeid:
				return @invoke($func, $Host, $at, c, ...$vaarg, ($Host)c.host);
			$default:
				return @invoke($func, $Host, $at + 1, c, ...$vaarg, read_arg(c, $at, $Typefrom($params[$vaarg.len].type))!);
		$endswitch
	$endif
}

macro bool @uses_text($func) @const
{
	var $text = $Typeof($func)::returns == String::typeid ||| ($Typeof($func)::returns.kind == OPTIONAL &&& $Typeof($func)::returns.inner == String::typeid);
	$foreach $p : $Typeof($func)::params:
		$if $p.type == String::typeid:
			$text = true;
		$endif
	$endforeach
	return $text;
}

macro bool @returns_void($func) @const
{
	return $Typeof($func)::returns == void::typeid ||| ($Typeof($func)::returns.kind == OPTIONAL &&& $Typeof($func)::returns.inner == void::typeid);
}

<*
 How many parameters of $func are converted from JS values (`this` included, for a method).
*>
macro uint @converted($func, $Host) @const => @arity($func, $Host, 0);

<*
 How many JS arguments $func reads.
*>
macro uint @arity($func, $Host, int $first) @const
{
	var $n = 0;
	$foreach $p : $Typeof($func)::params:
		$if !($p.type == Call*::typeid ||| $p.type == Engine*::typeid ||| ($Host != void* &&& $p.type == $Host::typeid)):
			$n = $n + 1;
		$endif
	$endforeach
	return $first < 0 ? $n - 1 : $n;
}

<*
 Call $func with converted arguments and box what it returns.
*>
macro Value? @call_boxed($func, $Host, int $first, Call* c) @local
{
	// The call is optional when the function is, or when any argument conversion is.
	$if $Typeof($func)::returns.kind == OPTIONAL ||| @converted($func, $Host) > 0:
		$if @returns_void($func):
			@invoke($func, $Host, $first, c)!;
			return UNDEFINED;
		$else
			return to_value(c.js, @invoke($func, $Host, $first, c)!);
		$endif
	$else
		$if @returns_void($func):
			@invoke($func, $Host, $first, c);
			return UNDEFINED;
		$else
			return to_value(c.js, @invoke($func, $Host, $first, c));
		$endif
	$endif
}

<*
 The NativeFn for $func: $first is 0 for a function, -1 for a method (its first converted
 parameter reads `this`).
*>
macro rt::NativeFn @glue($func, $Host, int $first) @local
{
	return fn Value?(Vm* vm, Value this_value, Value[] args, JsFunction* callee)
	{
		Call c = { (Engine*)vm, this_value == rt::EMPTY ? UNDEFINED : this_value, args, callee.host_opaque, callee };
		// Temp memory only when text crosses: a String argument or result.
		$if @uses_text($func):
			@pool()
			{
				return @call_boxed($func, $Host, $first, &c);
			};
		$else
			return @call_boxed($func, $Host, $first, &c);
		$endif
	};
}

<*
 A JS function calling $func (a function pointer constant: `&name`), with host as its host
 pointer.

 @return? THREW
*>
macro Value? Engine.@function(&self, String name, $func, host = null)
{
	return self.native(@glue($func, $Typeof(host), 0), name, @arity($func, $Typeof(host), 0), (void*)host);
}

<*
 target[name] = a JS function calling $func.

 @return? THREW
*>
macro void? Engine.@bind(&self, Value target, String name, $func, host = null)
{
	Value f = self.@function(name, $func, host)!;
	self.set(target, name, f)!;
}

<*
 A method of cls calling $func, whose first converted parameter is `this`.

 @return? THREW
*>
macro void? Engine.@method(&self, NativeClass* cls, String name, $func, host = null)
{
	Value f = self.native(@glue($func, $Typeof(host), -1), name, @arity($func, $Typeof(host), -1), (void*)host)!;
	Key k = self.key(name)!;
	if (catch self.vm.define(cls.proto, (Value)k, f, rt::METHOD_PROP)) return THREW~;
}

<*
 A getter on cls's prototype calling $func with `this`.

 @return? THREW
*>
macro void? Engine.@getter(&self, NativeClass* cls, String name, $func, host = null)
{
	Value f = self.native(@glue($func, $Typeof(host), -1), name, 0, (void*)host)!;
	Key k = self.key(name)!;
	if (catch self.vm.define_accessor(cls.proto, (Value)k, f, UNDEFINED, { .configurable = true })) return THREW~;
}
