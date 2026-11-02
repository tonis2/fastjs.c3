// Proxy, in the shapes three.c3 uses: a widget base class whose constructor returns a proxy,
// uniform tables with ownKeys/getOwnPropertyDescriptor, an array-like column, and a class
// wrapped to guard `new`.
const STATE = Symbol('state');
const TRAP = {
	set(target, name, value) {
		target[name] = value;
		if (typeof name !== 'symbol') target[STATE].dirty++;
		return true;
	},
};
class Widget {
	constructor() {
		this[STATE] = { dirty: 0 };
		return new Proxy(this, TRAP);
	}
	get dirty() { return this[STATE].dirty; }
	bump() { this.count = (this.count ?? 0) + 1; return this; }
}
class Hud extends Widget {
	score = 10;
	constructor() { super(); this.label = 'hud'; }
	set points(v) { this.score = v * 2; }
	get points() { return this.score / 2; }
}
const h = new Hud();
h.score += 5;
h.points = 7;
h.bump().bump();
console.log(h.score, h.points, h.count, h.dirty, h.label, h instanceof Hud, h instanceof Widget);
console.log(Object.keys(h), JSON.stringify(h), 'score' in h, h.hasOwnProperty('label'));
console.log(h);

function uniformsProxy(owner, declared) {
	return new Proxy({}, {
		get(_, name) { return owner.values[name]; },
		has(_, name) { return declared.has(name); },
		ownKeys() { return [...declared]; },
		getOwnPropertyDescriptor(_, name) {
			if (!declared.has(name)) return undefined;
			return { enumerable: true, configurable: true, value: owner.values[name] };
		},
		set(_, name, v) {
			if (!declared.has(name)) throw new TypeError(`no uniform called '${String(name)}'`);
			owner.values[name] = v;
			return true;
		},
	});
}
const owner = { values: { time: 0, color: [1, 0, 0] } };
const u = uniformsProxy(owner, new Set(['time', 'color']));
u.time = 2.5;
console.log(u.time, 'color' in u, 'nope' in u, Object.keys(u), { ...u }, JSON.stringify(u));
try { u.nope = 1; } catch (e) { console.log(e.constructor.name, e.message); }
for (const k in u) console.log('key', k);
console.log(Object.entries(u));

const rows = [[1, 2], [3, 4]];
const column = new Proxy(rows, {
	get(r, key) {
		if (key === 'length') return r.length;
		if (typeof key === 'string' && /^\d+$/.test(key)) return r[+key];
		const value = r[key];
		return typeof value === 'function' ? value.bind(r) : value;
	},
	set(_, key, v) {
		if (!(typeof key === 'string' && /^\d+$/.test(key))) throw new TypeError(`write a row, like rows[0] = [1, 0]`);
		rows[+key] = v.map(x => x * 10);
		return true;
	},
});
column[1] = [5, 6];
console.log(column.length, column[0], column[1], column.map(r => r[0]));
try { column.foo = 1; } catch (e) { console.log(e.message); }

let pending = false;
function track(Class) {
	return new Proxy(Class, {
		construct(target, args, newTarget) {
			if (!pending) throw new Error(`new ${target.name}() is not how a tracked class is built`);
			return Reflect.construct(target, args, newTarget);
		},
	});
}
const Critter = track(class Critter {
	static kind = 'critter';
	constructor(x) { this.x = x; }
	static spawn(x) { pending = true; try { return new Critter(x); } finally { pending = false; } }
});
try { new Critter(1); } catch (e) { console.log(e.message); }
const c = Critter.spawn(3);
console.log(c.x, c instanceof Critter, Critter.kind, typeof Critter, Critter.name);

const logged = [];
const watch = new Proxy({ a: 1 }, {
	get(t, k, r) { logged.push(`get ${String(k)}`); return Reflect.has(t, k) ? t[k] : undefined; },
	has(t, k) { logged.push(`has ${String(k)}`); return k in t; },
	deleteProperty(t, k) { logged.push(`delete ${String(k)}`); delete t[k]; return true; },
	defineProperty(t, k, d) { logged.push(`define ${String(k)}`); Object.defineProperty(t, k, d); return true; },
});
watch.a; 'a' in watch; delete watch.a; Object.defineProperty(watch, 'b', { value: 2, enumerable: true });
console.log(logged, watch.b);
const fn = new Proxy(function add(a, b) { return a + b; }, { apply(t, self, args) { return t(...args) * 100; } });
console.log(fn(1, 2), typeof fn);
try { Proxy({}, {}); } catch (e) { console.log(e.message); }
try { new Proxy(1, {}); } catch (e) { console.log(e.message); }
