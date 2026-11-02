// Lexes each file given on the command line and reports the first error in each.
//   c3c run lexcheck -- ../three.c3/examples/*.js ../three.c3/src/js/prelude/*.js
module lexcheck;
import std::io, std::time, fastjs::lex;

// Without a parser, '/' after something that ends an expression is division; elsewhere it starts a regex.
fn bool regex_allowed(TokenKind prev)
{
	switch (prev)
	{
		case IDENT:
		case NUMBER:
		case STRING:
		case TEMPLATE:
		case TEMPLATE_TAIL:
		case REGEX:
		case RPAREN:
		case RBRACKET:
		case RBRACE:
		case KW_THIS:
		case KW_SUPER:
		case KW_NULL:
		case KW_TRUE:
		case KW_FALSE:
		case PLUS_PLUS:
		case MINUS_MINUS:
			return false;
		default:
			return true;
	}
}

fn int main(String[] args)
{
	if (args.len < 2)
	{
		io::eprintn("usage: lexcheck <file.js>...");
		return 2;
	}
	int failed = 0;
	usz total_tokens = 0;
	usz total_bytes = 0;
	usz regexes = 0;
	NanoDuration total_time;
	foreach (path : args[1..])
	{
		char[]? data = file::load(mem, path);
		if (catch err = data)
		{
			io::eprintfn("%s: cannot read (%s)", path, err);
			failed++;
			continue;
		}
		defer free(data);
		Lexer lx;
		lx.init((String)data);
		TokenKind prev = SEMICOLON;
		usz count = 0;
		Clock start = clock::now();
		bool ok = true;
		while (true)
		{
			Token? tok = lx.next();
			if (try t = tok)
			{
				if ((t.kind == SLASH || t.kind == SLASH_ASSIGN) && regex_allowed(prev))
				{
					tok = lx.rescan_regex(&t);
				}
			}
			if (catch tok)
			{
				io::printfn("%s:%d:%d: %s", path, lx.error_line, lx.error_col, lx.error);
				ok = false;
				break;
			}
			if (tok.kind == EOF) break;
			if (tok.kind == REGEX) regexes++;
			prev = tok.kind;
			count++;
		}
		total_time += start.to_now();
		total_tokens += count;
		total_bytes += data.len;
		if (!ok) failed++;
	}
	io::printfn("%d files, %d tokens (%d regex), %d KB, %.2f ms, %d failed",
		args.len - 1, total_tokens, regexes, total_bytes / 1024, (double)total_time / 1_000_000.0, failed);
	return failed > 0 ? 1 : 0;
}
