// Symbols, the iterator protocol, and Map/Set.
const tag = Symbol("tag");
const o = { [tag]: 1, plain: 2 };
console.log(typeof tag, tag.toString(), tag.description, String(tag), o[tag], Object.keys(o), o);
console.log(Symbol() === Symbol(), Symbol.iterator.toString());

class Range {
	constructor(lo, hi) { this.lo = lo; this.hi = hi; }
	[Symbol.iterator]() {
		let cur = this.lo;
		const hi = this.hi;
		return { next: () => cur < hi ? { value: cur++, done: false } : { value: undefined, done: true } };
	}
}
const r = new Range(1, 5);
console.log([...r], Array.from(r), Math.max(...r));
for (const v of r) if (v % 2) console.log("odd", v);
const [a, b, ...rest] = new Range(10, 15);
console.log(a, b, rest);

const m = new Map([["a", 1], ["b", 2]]);
m.set("c", 3).set(NaN, "nan").set(0, "zero");
console.log(m.get("b"), m.get(NaN), m.get(-0), m.has("c"), m.size, m.delete("a"), m.size, m);
for (const [k, v] of m) console.log("entry", k, v);
console.log([...m.keys()], [...m.values()], Array.from(m.entries()).length);
const s = new Set([3, 1, 3, 2, 1]);
s.add(4).add(1);
console.log(s, s.size, s.has(2), [...s], s.delete(3), [...s.values()]);
const seen = [];
s.forEach(v => seen.push(v * 10));
m.forEach((v, k) => seen.push(`${k}=${v}`));
console.log(seen);
const objKey = {};
const wm = new Map([[objKey, "object key"]]);
console.log(wm.get(objKey), wm.get({}), new Map(), new Set());
console.log([..."héllo"], Array.from("ab", c => c + c), [...[1, 2].entries()], [...["x", "y"].keys()]);
const it = [10, 20][Symbol.iterator]();
console.log(it.next(), it.next(), it.next());
