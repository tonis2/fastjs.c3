// Each generator function's own prototype, and Promise subclasses with Symbol.species.
function* g() { yield 1; }
function* h() {}
console.log(typeof g.prototype, g.prototype !== h.prototype, Object.getPrototypeOf(g()) === g.prototype, g() instanceof g, Object.getPrototypeOf(g.prototype) === Object.getPrototypeOf(h.prototype));
g.prototype.extra = function () { return 'extra'; };
console.log(g().extra(), typeof h().extra, Object.hasOwn(g.prototype, 'constructor'));
class Gen { *items() { yield 'i'; } }
console.log(Object.getPrototypeOf(new Gen().items()) === Gen.prototype.items.prototype);
class P extends Promise {
	constructor(ex) { super(ex); this.tag = 'P'; }
	static get [Symbol.species]() { return P; }
}
const p = new P(r => r(1));
const t = p.then(v => v + 1);
console.log(p instanceof P, p instanceof Promise, t instanceof P, t.tag, P.resolve(5) instanceof P, Promise.resolve(5) instanceof P);
t.then(v => console.log('then', v));
P.all([1, P.resolve(2)]).then(v => console.log('all', v, P.all([]) instanceof P));
p.finally(() => console.log('finally')).then(v => console.log('after finally', v));
class Q extends Promise {}
console.log(Q.resolve(1) instanceof Q, new Q(() => {}).then(() => {}) instanceof Q, Q.reject(1).catch(() => {}) instanceof Q);
