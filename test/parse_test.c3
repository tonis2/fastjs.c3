module fastjs::parse_test;
import std::core::mem::allocators, fastjs::parse, fastjs::print, fastjs::ast;

// Parse src and return its normalized print, trimmed. Uses temp memory, so call inside @pool.
fn String js(String src, bool is_module = false)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	Parser p;
	p.init(&arena, src, is_module);
	defer p.free();
	Node*? program = p.parse_program();
	if (catch program) return string::tformat("ERROR %d:%d %s", p.error_line, p.error_col, p.error);
	return print::to_js(tmem, program).trim();
}

fn void check(String src, String want, bool is_module = false)
{
	@pool()
	{
		String got = js(src, is_module);
		test::@check(got == want, "\n  source: %s\n  got:    %s\n  want:   %s", src, got, want);
	};
}

fn void check_error(String src, String message, bool is_module = false)
{
	@pool()
	{
		String got = js(src, is_module);
		test::@check(got.starts_with("ERROR") && got.ends_with(message), "\n  source: %s\n  got:    %s\n  want error: %s", src, got, message);
	};
}

fn void precedence() @test
{
	check("a + b * c;", "(a + (b * c));");
	check("a * b + c;", "((a * b) + c);");
	check("a - b - c;", "((a - b) - c);");
	check("a ** b ** c;", "(a ** (b ** c));");
	check("a || b && c;", "(a || (b && c));");
	check("a ?? b;", "(a ?? b);");
	check("a = b = c;", "(a = (b = c));");
	check("a ? b : c ? d : e;", "(a ? b : (c ? d : e));");
	check("!a.b;", "(! a.b);");
	check("typeof a === 'x';", "((typeof a) === 'x');");
	check("a < b == c > d;", "((a < b) == (c > d));");
	check("x in y && z instanceof W;", "((x in y) && (z instanceof W));");
	check("(a, b);", "(a, b);");
	check("-x ** 2;", "ERROR 1:4 parenthesize the unary expression before '**'");
	check("(-x) ** 2;", "((- x) ** 2);");
}

fn void members_and_calls() @test
{
	check("a.b.c(d)[e];", "a.b.c(d)[e];");
	check("a.default.new;", "a.default.new;");
	check("new A.B(1).c();", "(new (A.B)(1)).c();");
	check("new A;", "(new (A)());");
	check("new new A()();", "(new ((new (A)()))());");
	check("f(...xs, y,);", "f(...xs, y);");
	check("1..toString();", "(1.).toString();");
}

fn void optional_chaining() @test
{
	check("a?.b.c;", "(a?.b.c);");
	check("a?.[0]?.(x);", "(a?.[0]?.(x));");
	check("a?.5:b;", "(a ? .5 : b);");
	check("(a?.b).c;", "(a?.b).c;");
}

fn void arrows() @test
{
	check("x => x + 1;", "((x) => (x + 1));");
	check("(a, b = 2, ...c) => {};", "((a, b = 2, ...c) => {\n});");
	check("({a, b: [c]}) => a;", "(({a, b: [c]}) => a);");
	check("() => ({a: 1});", "(() => ({a: 1}));");
	check("async x => await x;", "(async (x) => (await x));");
	check("async (a) => a;", "(async (a) => a);");
	check("async(a);", "async(a);");
	check("f(x => y, z);", "f(((x) => y), z);");
	check("(x => x)(1);", "((x) => x)(1);");
	check("a ? x => 1 : y => 2;", "(a ? ((x) => 1) : ((y) => 2));");
}

fn void destructuring() @test
{
	check("const {a, b: {c}, ...rest} = o;", "const {a, b: {c}, ...rest} = o;");
	check("let [x, , y = 1, ...z] = arr;", "let [x, , y = 1, ...z] = arr;");
	check("[a, b] = [b, a];", "([a, b] = [b, a]);");
	check("({a, b = 2} = o);", "({a, b = 2} = o);");
	check("[a.b, c[0]] = v;", "([a.b, c[0]] = v);");
	check("for (const [k, v] of m) {}", "for (const [k, v] of m) {\n}");
	check("for ([a, b] of m) {}", "for ([a, b] of m) {\n}");
	check("[a,,];", "[a, ,];");
	check_error("({a = 1});", "'=' in an object literal is only valid in destructuring");
	check_error("(a + b) = 1;", "invalid assignment target");
	check_error("a + b++ = 1;", "invalid assignment target");
	check_error("(a.b) => 1;", "invalid parameter");
}

fn void templates_and_regex() @test
{
	check("`a${b + 1}c${`d${e}`}`;", "`a${(b + 1)}c${`d${e}`}`;");
	check("x = /a\\/b[/]/gi.test(y);", "(x = /a\\/b[/]/gi.test(y));");
	check("a / b / c;", "((a / b) / c);");
	check("f(/=/);", "f(/=/);");
	check_error("tag`x`;", "tagged templates are not supported");
}

fn void classes() @test
{
	check("class A extends B.C { static x = 1; y; constructor(a) { super(a); } get v() { return this._v; } set v(n) {} static *[Symbol.iterator]() {} async load() {} }",
		"class A extends B.C {\n\tstatic x = 1;\n\ty;\n\tconstructor(a) {\n\t\tsuper(a);\n\t}\n\tget v() {\n\t\treturn this._v;\n\t}\n\tset v(n) {\n\t}\n\tstatic *[Symbol.iterator]() {\n\t}\n\tasync load() {\n\t}\n}");
	check("class A { get = 1; set; static() {} async() {} get get() {} }",
		"class A {\n\tget = 1;\n\tset;\n\tstatic() {\n\t}\n\tasync() {\n\t}\n\tget get() {\n\t}\n}");
	check("class A {\n x = 1\n y = 2\n}", "class A {\n\tx = 1;\n\ty = 2;\n}");
	check("const C = class {};", "const C = (class {\n});");
	check_error("class A { #x = 1; }", "private '#' members are not supported");
	check_error("class A { static { } }", "static blocks are not supported");
}

fn void object_literals() @test
{
	check("({a, 'b': 1, 2: c, [d]: e, f() {}, get g() {}, ...h});",
		"({a, 'b': 1, 2: c, [d]: e, f() {\n}, get g() {\n}, ...h});");
	check("({get: 1, set() {}, async: 2});", "({get: 1, set() {\n}, async: 2});");
}

fn void statements() @test
{
	check("if (a) b; else if (c) d; else e;", "if (a) {\n\tb;\n} else {\n\tif (c) {\n\t\td;\n\t} else {\n\t\te;\n\t}\n}");
	check("for (let i = 0, n = 2; i < n; i++) {}", "for (let i = 0, n = 2; (i < n); (i++)) {\n}");
	check("for (;;) break;", "for (;;) {\n\tbreak;\n}");
	check("for (const k in o) {}", "for (const k in o) {\n}");
	check("for (let i = ('x' in o) ? 1 : 0; ;) {}", "for (let i = (('x' in o) ? 1 : 0);;) {\n}");
	check_error("for (let i = 'x' in o; ;) {}", "a for-of or for-in head declares one variable, without an initializer");
	check("switch (x) { case 1: a(); default: b(); }", "switch (x) {\n\tcase 1:\n\t\ta();\n\tdefault:\n\t\tb();\n}");
	check("try { a(); } catch { } finally { b(); }", "try {\n\ta();\n} catch {\n} finally {\n\tb();\n}");
	check("try {} catch ({message}) {}", "try {\n} catch ({message}) {\n}");
	check("while (x) x--;", "while (x) {\n\t(x--);\n}");
	check("function* g() { yield; yield* a; const b = yield c; }", "function* g() {\n\t(yield);\n\t(yield* a);\n\tconst b = (yield c);\n}");
	check("async function f() { await g(); }", "async function f() {\n\t(await g());\n}");
	check("function f() { return new.target; }", "function f() {\n\treturn new.target;\n}");
}

fn void automatic_semicolons() @test
{
	check("a = 1\nb = 2", "(a = 1);\n(b = 2);");
	check("a\n++b", "a;\n(++b);");
	check("function f() { return\n1 }", "function f() {\n\treturn;\n\t1;\n}");
	check("let x = 1\n;[1].map(f)", "let x = 1;\n[1].map(f);");
	check_error("a b", "expected ';' but found 'b'");
}

fn void modules() @test
{
	check("import a, {b, c as d, default as e} from './x.js';", "import a, {b, c as d, default as e} from \"./x.js\";", true);
	check("import * as ns from 'm';", "import * as ns from \"m\";", true);
	check("import 'side';", "import \"side\";", true);
	check("export const a = 1; export function f() {} export class C {}", "export const a = 1;\nexport function f() {\n}\nexport class C {\n}", true);
	check("export default 3;", "export default 3;", true);
	check("export default function () {}", "export default (function() {\n});", true);
	check("export { a, b as c };", "export {a, b as c};", true);
	check("const x = await f();", "const x = (await f());", true);
	check_error("import a from 'b';", "'import' is only allowed at the top level of a module");
	check_error("export * from 'b';", "'export *' is not supported", true);
}

fn void dropped_features() @test
{
	check_error("var x = 1;", "'var' is not supported; use 'let' or 'const'");
	check_error("do { } while (x);", "'do...while' is not supported; use 'while'");
	check_error("with (o) {}", "'with' is not supported");
	check_error("outer: for (;;) {}", "labels are not supported");
	check_error("for (;;) { break outer; }", "labels are not supported");
	check_error("return 1;", "'return' outside of a function");
	check_error("let let = 1;", "'let' cannot be a variable name");
	check_error("const class = 1;", "'class' is a reserved word");
}

fn void error_positions() @test
{
	check("let a = (1;", "ERROR 1:11 expected ')' but found ';'");
	check("f(\n  a,\n  b c)", "ERROR 3:5 expected ')' but found 'c'");
	check("'unterminated", "ERROR 1:1 unterminated string");
}
