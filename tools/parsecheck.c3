// Parses each file, prints it, reparses the print and prints again; both prints must match.
//   c3c run parsecheck -- ../three.c3/examples/*.js ../three.c3/src/js/prelude/*.js
//   parsecheck --print file.js     shows the normalized print of one file
module parsecheck;
import std::io, std::time, fastjs::parse, fastjs::print, fastjs::ast;

// A file is a module when a line starts with an import or export statement.
fn bool looks_like_module(String src)
{
	Splitter lines = src.tokenize("\n");
	while (try line = lines.next())
	{
		String t = line.trim();
		if (t.starts_with("export ") || t.starts_with("export{")) return true;
		if ((t.starts_with("import ") || t.starts_with("import{") || t.starts_with("import'") || t.starts_with("import\"")) && !t.starts_with("import(")) return true;
	}
	return false;
}

<*
 Parse src and print it. Prints the error and returns an empty optional on failure.
*>
fn String? round(String path, String src, bool is_module, Allocator out, String stage)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024 * 1024);
	defer arena.free();
	Parser p;
	p.init(&arena, src, is_module);
	defer p.free();
	Node*? program = p.parse_program();
	if (catch err = program)
	{
		io::printfn("%s:%d:%d: %s%s", path, p.error_line, p.error_col, stage, p.error);
		return err~;
	}
	return print::to_js(out, program);
}

fn void report_diff(String path, String a, String b)
{
	usz line = 1;
	usz start = 0;
	for (usz i = 0; i < a.len && i < b.len; i++)
	{
		if (a[i] != b[i])
		{
			usz end_a = i;
			while (end_a < a.len && a[end_a] != '\n') end_a++;
			usz end_b = i;
			while (end_b < b.len && b[end_b] != '\n') end_b++;
			io::printfn("%s: print is not stable at printed line %d\n  first:  %s\n  second: %s", path, line, a[start..end_a - 1].trim(), b[start..end_b - 1].trim());
			return;
		}
		if (a[i] == '\n')
		{
			line++;
			start = i + 1;
		}
	}
	io::printfn("%s: print is not stable (lengths %d vs %d)", path, a.len, b.len);
}

fn int main(String[] args)
{
	if (args.len < 2)
	{
		io::eprintn("usage: parsecheck [--print] <file.js>...");
		return 2;
	}
	bool show = args[1] == "--print";
	String[] files = show ? args[2..] : args[1..];
	int failed = 0;
	usz total_bytes = 0;
	NanoDuration parse_time;
	foreach (path : files)
	{
		char[]? data = file::load(mem, path);
		if (catch err = data)
		{
			io::eprintfn("%s: cannot read (%s)", path, err);
			failed++;
			continue;
		}
		defer free(data);
		String src = (String)data;
		bool is_module = looks_like_module(src);
		total_bytes += src.len;

		Clock start = clock::now();
		String? first = round(path, src, is_module, mem, "");
		parse_time += start.to_now();
		if (catch first)
		{
			failed++;
			continue;
		}
		defer free(first);
		if (show) io::print(first);
		String? second = round(path, first, is_module, mem, "reparse: ");
		if (catch second)
		{
			failed++;
			continue;
		}
		defer free(second);
		if (first != second)
		{
			report_diff(path, first, second);
			failed++;
		}
	}
	if (!show)
	{
		io::printfn("%d files, %d KB, parse+print %.2f ms, %d failed", files.len, total_bytes / 1024, (double)parse_time / 1_000_000.0, failed);
	}
	return failed > 0 ? 1 : 0;
}
