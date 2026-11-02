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
	// Async benchmarks finish in the job queue and leave their answer in __result.
	while (ctx.step_job()) {}
	Value global = ctx.global();
	Value async_result = ctx.property(global, "__result");
	ctx.release(global);
	if (!async_result.is_undefined())
	{
		ctx.release(v);
		v = async_result;
	}
	else
	{
		ctx.release(async_result);
	}
	double d = ctx.number(v);
	if (d == (double)(long)d) { io::printfn("%d", (long)d); } else { io::printfn("%s", d); }
	ctx.release(v);
	return 0;
}
