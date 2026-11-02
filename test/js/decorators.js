// Decorators (the TC39 proposal). node can't run them yet: regen-decorators.sh lowers this file
// with esbuild first.

// A class decorator that adds a static property.
let variable = function (target) {
	target.property = 'GFG is best';
};
@variable
class GFG {}
console.log(GFG.property);

// A class decorator that replaces the class: the inner name sees the replacement too.
let pending = false;
function track(Class, ctx) {
	console.log('track', ctx.kind, ctx.name);
	return new Proxy(Class, {
		construct(target, args, newTarget) {
			if (!pending) throw new Error(`new ${target.name}() is not how a tracked class is built`);
			return Reflect.construct(target, args, newTarget);
		},
	});
}
@track
class Critter {
	static kind = 'critter';
	constructor(x) { this.x = x; }
	static spawn(x) { pending = true; try { return new Critter(x); } finally { pending = false; } }
}
try { new Critter(1); } catch (e) { console.log(e.message); }
const c = Critter.spawn(3);
console.log(c.x, c instanceof Critter, Critter.kind, typeof Critter, Critter.name);

// Method decorators: wrap, and bind through addInitializer.
const calls = [];
function logged(fn, ctx) {
	return function (...args) {
		calls.push(`${String(ctx.name)}(${args.join(', ')})`);
		return fn.apply(this, args);
	};
}
function bound(fn, ctx) {
	ctx.addInitializer(function () { this[ctx.name] = this[ctx.name].bind(this); });
}
class Counter {
	count = 0;
	@logged add(n) { this.count += n; return this; }
	@bound @logged inc() { this.count++; }
	@logged static make() { return new Counter(); }
	@logged [Symbol.iterator]() { return [this.count][Symbol.iterator](); }
}
const k = Counter.make().add(2);
const inc = k.inc;
inc();
inc();
console.log(k.count, [...k], calls.join(' '));
console.log(Object.keys(k), Object.getOwnPropertyNames(Counter.prototype));

// Getters and setters.
function double(fn, ctx) {
	console.log(ctx.kind, ctx.name, ctx.static, ctx.private, Object.keys(ctx.access));
	if (ctx.kind === 'getter') return function () { return fn.call(this) * 2; };
	return function (v) { fn.call(this, v * 2); };
}
class Pair {
	a = 1;
	@double get value() { return this.a; }
	@double set value(v) { this.a = v; }
}
const pair = new Pair();
console.log(pair.value);
pair.value = 5;
console.log(pair.a, pair.value);

// Field decorators: initializer transforms, outermost first.
function plus(n) {
	return (_, ctx) => {
		console.log('field', ctx.name, ctx.static, Object.keys(ctx.access));
		return v => v + n;
	};
}
function times(n) { return () => v => v * n; }
class Fields {
	@plus(1) @times(10) a = 2;
	@times(10) @plus(1) b = 2;
	@plus(5) static s = 1;
	@plus(1) ['comp' + 'uted'] = 0;
	@plus(1) c;
}
const fields = new Fields();
console.log(fields.a, fields.b, Fields.s, fields.computed, fields.c);

// accessor fields: storage nobody else can see.
class Plain {
	accessor x = 1;
	static accessor y = 'y';
	accessor z;
}
const plain = new Plain();
console.log(plain.x, Plain.y, plain.z, Object.keys(plain), Reflect.ownKeys(plain), JSON.stringify(plain));
plain.x = 10;
console.log(plain.x, Object.getOwnPropertyNames(Plain.prototype), typeof Object.getOwnPropertyDescriptor(Plain.prototype, 'x').get);
Object.freeze(plain);
plain.x = 11;
console.log(plain.x, Object.isFrozen(plain));
try { Plain.prototype.x; } catch (e) { console.log(e instanceof TypeError); }
try { Object.getOwnPropertyDescriptor(Plain.prototype, 'x').set.call({}, 1); } catch (e) { console.log(e instanceof TypeError); }
const other = new Plain();
console.log(other.x, plain.x);

// An observable accessor, as a widget or game object would use.
const changes = [];
function observable({ get, set }, ctx) {
	return {
		get() { return get.call(this); },
		set(v) {
			const old = get.call(this);
			set.call(this, v);
			changes.push(`${this.id}.${ctx.name}: ${old} -> ${v}`);
		},
		init(v) {
			changes.push(`init ${ctx.name} = ${v}`);
			return v;
		},
	};
}
class Unit {
	static count = 0;
	id = ++Unit.count;
	@observable accessor hp = 100;
	@observable accessor name = 'unit';
	hit(n) { this.hp -= n; }
}
const u1 = new Unit();
const u2 = new Unit();
u1.hit(30);
u2.name = 'archer';
u1.hit(5);
console.log(u1.hp, u2.hp, u2.name);
console.log(changes.join('\n'));

// The access object.
let access;
class Accessed {
	@((_, ctx) => { access = ctx.access; }) secret = 42;
}
const accessed = new Accessed();
console.log(access.has(accessed), access.get(accessed), access.has({}));
access.set(accessed, 7);
console.log(accessed.secret);

// Metadata: one object per class, inheriting from the parent's.
function meta(key, value) {
	return (_, ctx) => { ctx.metadata[key] = value; };
}
@meta('kind', 'base')
class Base {
	@meta('field', 'x') x = 1;
}
@meta('kind', 'derived')
class Derived extends Base {
	@meta('method', 'go') go() {}
}
const metadataKey = Reflect.ownKeys(Base).find(s => typeof s === 'symbol' && String(s).includes('metadata'));
const bm = Base[metadataKey];
const dm = Derived[metadataKey];
console.log(bm.kind, bm.field, dm.kind, dm.field, dm.method, Object.getPrototypeOf(dm) === bm, Object.keys(dm));

// Evaluation and application order, with computed keys and initializers.
const order = [];
function d(name) {
	order.push('eval ' + name);
	return function (v, ctx) {
		order.push('apply ' + name + ' ' + ctx.kind + ' ' + String(ctx.name));
		ctx.addInitializer(function () { order.push('init ' + name); });
	};
}
function key(n) { order.push('key ' + n); return n; }
@d('class')
class Ordered {
	@d('field') f = order.push('f value');
	@d('static field') static sf = order.push('sf value');
	@d('method') [key('m')]() {}
	@d('static method') static sm() {}
	@d('getter') get g() { return 1; }
	@d('setter') set g(v) {}
	@d('accessor') accessor acc = order.push('acc value');
	@d('static accessor') static accessor sacc = order.push('sacc value');
	constructor() { order.push('constructor'); }
}
order.push('defined');
new Ordered();
console.log(order.join('\n'));

// Decorator expressions: member chains, calls and parentheses.
const deco = {
	tag: { name(n) { return (cls) => { cls.tagged = n; }; } },
	mark(cls) { cls.marked = true; },
};
@deco.tag.name('t') @deco.mark @((cls) => { cls.paren = 1; })
class Expr {}
console.log(Expr.tagged, Expr.marked, Expr.paren);

// Class expressions, named and anonymous.
const Anon = @((cls, ctx) => { console.log('anon', ctx.name); }) class {};
const Named = @((cls, ctx) => { console.log('named', ctx.name); }) class Inner {};
console.log(Anon.name, Named.name);

// A derived class with decorated members still runs them after super().
class Child extends Counter {
	@plus(1) extra = 1;
	@bound who() { return this.count; }
}
const child = new Child();
const who = child.who;
console.log(child.extra, who());

// What a decorator may return.
function returns(value) { return () => value; }
for (const [what, make] of [
	['class', v => { @returns(v) class X {} }],
	['method', v => { class X { @returns(v) m() {} } }],
	['field', v => { class X { @returns(v) f = 1; } }],
	['accessor', v => { class X { @returns(v) accessor a = 1; } }],
]) {
	for (const v of [1, 'x', {}, null]) {
		try { make(v); console.log(what, 'accepted', typeof v); } catch (e) { console.log(what, 'rejected', v === null ? 'null' : typeof v, e instanceof TypeError); }
	}
}
let setLater;
try {
	class Late { @((_, ctx) => { setLater = ctx.addInitializer; }) m() {} }
	setLater(() => {});
} catch (e) { console.log('late addInitializer', e instanceof TypeError); }
try { class Bad { @((_, ctx) => { ctx.addInitializer(1); }) m() {} } } catch (e) { console.log('bad initializer', e instanceof TypeError); }

// Only decorated classes get metadata.
console.log(Reflect.ownKeys(Plain).filter(k => typeof k === 'symbol').length, Reflect.ownKeys(Counter).filter(k => typeof k === 'symbol').length);
