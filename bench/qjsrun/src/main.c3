module qjsrun;
import std::io, qjs;

// Evaluate a script with QuickJS and print its completion value.
fn int main(String[] args)
{
	char[] src = file::load(mem, args[1])!!;
	defer free(src);
	Context ctx = qjs::open()!!;
	defer ctx.close();
	Value? v = ctx.eval((String)src, args[1]);
	if (catch v)
	{
		io::eprintn(ctx.exception());
		return 1;
	}
	double d = ctx.number(v);
	if (d == (double)(long)d) { io::printfn("%d", (long)d); } else { io::printfn("%s", d); }
	ctx.release(v);
	return 0;
}
