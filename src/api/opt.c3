<*
 An argument whose absence means something: `Opt {bool} mipmaps` then `mipmaps.or(true)`.
 undefined counts as not given, so a JS caller passing a default through still gets it.
*>
module fastjs::js::opt <Type>;
import fastjs::js;

struct Opt
{
	Type value;
	bool given;
}

fn Type Opt.or(self, Type fallback) => self.given ? self.value : fallback;

<*
 @return? js::THREW
*>
fn void? Opt.from_js(&self, Call* c, int at)
{
	self.given = c.has(at) && !c.get(at).is_undefined();
	if (self.given) self.value = js::read_arg(c, at, Type)!;
}
