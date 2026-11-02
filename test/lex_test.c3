module fastjs::lex_test;
import fastjs::lex;

fn void expect_kinds(String src, TokenKind[] want)
{
	Lexer lx;
	lx.init(src);
	foreach (i, kind : want)
	{
		Token t = lx.next()!!;
		test::@check(t.kind == kind, "token %d of `%s`: got %s, want %s", i, src, t.kind, kind);
	}
	test::eq(lx.next()!!.kind, TokenKind.EOF);
}

fn Token first(String src)
{
	Lexer lx;
	lx.init(src);
	return lx.next()!!;
}

fn String first_error(String src)
{
	Lexer lx;
	lx.init(src);
	while (true)
	{
		Token? t = lx.next();
		if (catch t) return lx.error;
		if (t.kind == EOF) return "";
	}
}

fn void punctuators() @test
{
	expect_kinds("a ?. b ?? c >>>= d ... => **= !== ===", {
		IDENT, QUESTION_DOT, IDENT, QUESTION_QUESTION, IDENT, SHR_ASSIGN, IDENT,
		ELLIPSIS, ARROW, STAR_STAR_ASSIGN, NE_STRICT, EQ_STRICT });
	expect_kinds("x >> y >>> z << w <= v >= u", { IDENT, SAR, IDENT, SHR, IDENT, SHL, IDENT, LE, IDENT, GE, IDENT });
	expect_kinds("a &&= b ||= c ??= d", { IDENT, AMP_AMP_ASSIGN, IDENT, PIPE_PIPE_ASSIGN, IDENT, QUESTION_QUESTION_ASSIGN, IDENT });
}

fn void ternary_with_decimal_is_not_optional_chain() @test
{
	expect_kinds("a?.5:b", { IDENT, QUESTION, NUMBER, COLON, IDENT });
}

fn void keywords_and_contextual_words() @test
{
	expect_kinds("class Foo extends Bar { static get x() {} }", {
		KW_CLASS, IDENT, KW_EXTENDS, IDENT, LBRACE, IDENT, IDENT, IDENT, LPAREN, RPAREN, LBRACE, RBRACE, RBRACE });
	expect_kinds("let async await of yield undefined", { IDENT, IDENT, IDENT, IDENT, IDENT, IDENT });
	expect_kinds("var with do", { KW_VAR, KW_WITH, KW_DO });
	expect_kinds("$x _y ünï", { IDENT, IDENT, IDENT });
}

fn void numbers() @test
{
	test::eq(first("0x1F").number, 31.0);
	test::eq(first("0b101").number, 5.0);
	test::eq(first("0o17").number, 15.0);
	test::eq(first("1_000_000").number, 1000000.0);
	test::eq(first("1.5e3").number, 1500.0);
	test::eq(first(".5").number, 0.5);
	test::eq(first("2.").number, 2.0);
	test::eq(first("0.1").number, 0.1);
	test::eq(first("1e-7").number, 1e-7);
	test::eq(first("0").number, 0.0);
}

fn void number_errors() @test
{
	test::eq(first_error("10n"), "BigInt is not supported");
	test::eq(first_error("07"), "legacy octal literals are not supported");
	test::eq(first_error("3in"), "identifier directly after number");
	test::eq(first_error("0x"), "missing digits after number prefix");
	test::eq(first_error("1e+"), "missing exponent digits");
}

fn void strings() @test
{
	String src = `'plain' "esc\"aped\n" '\u{1F600}\x41'`;
	Lexer lx;
	lx.init(src);
	Token a = lx.next()!!;
	test::eq(a.kind, TokenKind.STRING);
	test::eq(a.raw(src), "plain");
	test::eq(a.escaped, false);
	Token b = lx.next()!!;
	test::eq(b.raw(src), `esc\"aped\n`);
	test::eq(b.escaped, true);
	Token c = lx.next()!!;
	test::eq(c.escaped, true);
	test::eq(lx.next()!!.kind, TokenKind.EOF);
}

fn void string_errors() @test
{
	test::eq(first_error("'abc"), "unterminated string");
	test::eq(first_error("'ab\ncd'"), "unterminated string");
	test::eq(first_error(`'\x4'`), "malformed \\x escape");
	test::eq(first_error(`'\u12'`), "malformed \\u escape");
	test::eq(first_error(`'\u{110000}'`), "code point out of range");
	test::eq(first_error(`'\1'`), "octal escapes are not supported");
}

fn void template_with_object_literal_inside() @test
{
	String src = "`a${b}c${ {x: 1}.x }d`";
	expect_kinds(src, {
		TEMPLATE_HEAD, IDENT, TEMPLATE_MIDDLE, LBRACE, IDENT, COLON, NUMBER, RBRACE, DOT, IDENT, TEMPLATE_TAIL });
	Lexer lx;
	lx.init(src);
	test::eq(lx.next()!!.raw(src), "a");
	(void)lx.next()!!;
	test::eq(lx.next()!!.raw(src), "c");
}

fn void nested_templates() @test
{
	expect_kinds("`a${`b${c}`}d`", { TEMPLATE_HEAD, TEMPLATE_HEAD, IDENT, TEMPLATE_TAIL, TEMPLATE_TAIL });
	expect_kinds("`plain $ {x} multi\nline`", { TEMPLATE });
	expect_kinds("f(`x`, () => { return `${a}`; })", {
		IDENT, LPAREN, TEMPLATE, COMMA, LPAREN, RPAREN, ARROW, LBRACE, KW_RETURN, TEMPLATE_HEAD, IDENT, TEMPLATE_TAIL,
		SEMICOLON, RBRACE, RPAREN });
}

fn void template_tracks_lines() @test
{
	Lexer lx;
	lx.init("`one\ntwo\nthree` x");
	(void)lx.next()!!;
	Token x = lx.next()!!;
	test::eq(x.line, 3u);
	test::eq(x.col, 8u);
}

fn void comments_and_newlines() @test
{
	String src = "#!/usr/bin/env fjs\na // line\n/* block\n */ b /* same line */ c";
	Lexer lx;
	lx.init(src);
	Token a = lx.next()!!;
	test::eq(a.line, 2u);
	test::eq(a.nl_before, true);
	Token b = lx.next()!!;
	test::eq(b.nl_before, true);
	test::eq(b.line, 4u);
	Token c = lx.next()!!;
	test::eq(c.nl_before, false);
	test::eq(first_error("a /* never closed"), "unterminated comment");
}

fn void regex_rescan() @test
{
	String src = "x = /ab[/]c\\//gi.test(y)";
	Lexer lx;
	lx.init(src);
	(void)lx.next()!!;
	(void)lx.next()!!;
	Token slash = lx.next()!!;
	test::eq(slash.kind, TokenKind.SLASH);
	Token re = lx.rescan_regex(&slash)!!;
	test::eq(re.kind, TokenKind.REGEX);
	String pattern;
	String flags;
	re.regex_parts(src, &pattern, &flags);
	test::eq(pattern, "ab[/]c\\/");
	test::eq(flags, "gi");
	test::eq(lx.next()!!.kind, TokenKind.DOT);
	test::eq(lx.next()!!.kind, TokenKind.IDENT);
}

fn void regex_rescan_of_slash_assign() @test
{
	String src = "/=x/";
	Lexer lx;
	lx.init(src);
	Token t = lx.next()!!;
	test::eq(t.kind, TokenKind.SLASH_ASSIGN);
	Token re = lx.rescan_regex(&t)!!;
	test::eq(re.text(src), "/=x/");
	test::eq(lx.next()!!.kind, TokenKind.EOF);
}

fn void error_position() @test
{
	Lexer lx;
	lx.init("a\n  b @");
	(void)lx.next()!!;
	(void)lx.next()!!;
	test::eq(@catch(lx.next()), lex::SYNTAX);
	test::eq(lx.error, "unexpected character");
	test::eq(lx.error_line, 2u);
	test::eq(lx.error_col, 5u);
}

fn void multiline_error_points_at_its_start() @test
{
	Lexer lx;
	lx.init("x\n  /* open\nstill open");
	(void)lx.next()!!;
	test::eq(@catch(lx.next()), lex::SYNTAX);
	test::eq(lx.error_line, 2u);
	test::eq(lx.error_col, 3u);
}
