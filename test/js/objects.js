// Object literals, properties, accessors, keys order, delete, in.
const key = "dyn";
const o = { a: 1, "b-c": 2, [key + "amic"]: 3, 10: "ten", 2: "two", nested: { deep: [1, 2] } };
console.log(o);
console.log(o.a, o["b-c"], o.dynamic, o[10], o["2"], o.nested.deep[1], o.missing);
console.log(Object.keys(o));

o.added = "yes";
o.a += 10;
delete o["b-c"];
console.log(o.a, "b-c" in o, "added" in o, o.hasOwnProperty("added"), o.hasOwnProperty("toString"));

const shorthand = 5;
const merged = { shorthand, ...{ x: 1, y: 2 }, y: 3 };
console.log(merged);

const temp = {
	celsius: 20,
	get fahrenheit() { return this.celsius * 9 / 5 + 32; },
	set fahrenheit(f) { this.celsius = (f - 32) * 5 / 9; },
};
console.log(temp.fahrenheit);
temp.fahrenheit = 212;
console.log(temp.celsius, temp);

const counts = {};
for (const w of ["x", "y", "x", "z", "x"]) counts[w] = (counts[w] ?? 0) + 1;
console.log(counts);

const keys = [];
for (const k in { b: 1, a: 2, 1: 3 }) keys.push(k);
console.log(keys);
console.log({}, { a: {} }, { a: { b: { c: { d: 1 } } } });
