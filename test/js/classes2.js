// Computed class field names, super[x], super.x = v, super in object literals, __proto__: in literals.
{
let n = 0;
const k = () => 'key' + (++n);
const sym = Symbol('s');
class A {
	[k()] = 1;
	plain = 2;
	[sym] = 'sym';
	['lit' + 'eral'] = this.plain + 1;
	static [k()] = 'static';
	[k()];
}
const a = new A(), b = new A();
console.log(Object.keys(a).join(), a.key1, a.literal, a[sym], A.key2, 'key3' in a, n, Object.keys(b).join());
class B extends A { [`${'x'}y`] = super.constructor.name; }
console.log(new B().xy, Object.keys(new B()).join());
}
{
class A { m() { return 'A.m'; } get g() { return 'A.g:' + this.tag; } set s(v) { this.stored = 'A.s(' + v + ')'; } static sm() { return 'A.sm'; } }
class B extends A {
	constructor() { super(); this.tag = 'b'; }
	m() { const k = 'm'; return super[k]() + '>B'; }
	get g() { return super['g'] + '!'; }
	assign() { super.s = 1; super['s'] = 2; super.plain = 3; return [this.stored, this.plain, Object.hasOwn(this, 'plain'), Object.hasOwn(A.prototype, 'plain')]; }
	compound() { this.n = 1; super.n += 5; super['n'] ??= 9; return this.n; }
	static sm() { return super['sm']() + '+B'; }
	arrow() { return (() => super['m']())(); }
}
const b = new B();
console.log(b.m(), b.g, b.assign().join(), b.compound(), B.sm(), b.arrow());
const base = { hi() { return 'base hi'; }, get who() { return 'base ' + this.name; } };
const obj = { __proto__: base, name: 'obj', hi() { return super.hi() + ' / obj'; }, get who() { return super.who + '!'; }, ['comp' + 'uted']() { return super.hi(); } };
console.log(obj.hi(), obj.who, obj.computed());
const o2 = { f() { return super.toString === Object.prototype.toString; } };
console.log(o2.f());
const p1 = { __proto__: null }, p2 = { '__proto__': [] }, __proto__ = 5, p3 = { __proto__ }, p4 = { __proto__: 7 };
console.log(Object.getPrototypeOf(p1), Array.isArray(Object.getPrototypeOf(p2)), Object.keys(p3).join(), Object.getPrototypeOf(p4) === Object.prototype);
}
