// Object, Array, String, Number, Math, JSON and Function built-ins.
const o = { b: 2, a: 1, 3: "three" };
console.log(Object.values(o), Object.entries(o), Object.assign({}, o, { c: 3 }));
const frozen = Object.freeze({ x: 1, list: [1] });
try { (function () { "use strict"; frozen.x = 2; })(); } catch (e) { console.log(e.name); }
console.log(frozen.x, Object.isFrozen(frozen), Object.isFrozen({}));
const target = {};
Object.defineProperty(target, "hidden", { value: 42, enumerable: false });
Object.defineProperty(target, "computed", { get() { return this.hidden * 2; }, enumerable: true });
console.log(target, target.hidden, target.computed, Object.keys(target), Object.getOwnPropertyNames(target));
console.log(Object.getOwnPropertyDescriptor(target, "hidden"), Object.getOwnPropertyDescriptor({ v: 1 }, "v"));
const proto = { greet() { return "hi " + this.name; } };
const child = Object.create(proto);
child.name = "kid";
console.log(child.greet(), Object.getPrototypeOf(child) === proto, proto.isPrototypeOf(child), Object.create(null));
console.log(Object.fromEntries([["k", 1], ["j", 2]]), Object.is(NaN, NaN), Object.is(0, -0), Object.hasOwn(o, "b"));

const arr = [5, 1, 4, 2, 3];
console.log(arr.slice(1, 3), arr.slice(-2), arr.concat([6], 7), arr.includes(4), arr.lastIndexOf(4), arr.at(-1));
console.log([...arr].sort(), [...arr].sort((x, y) => y - x), [10, 9, 1, 100].sort(), ["b", "a", "C"].sort());
console.log(arr.filter(x => x > 2), arr.reduce((s, x) => s + x, 0), arr.reduceRight((s, x) => s + x), arr.find(x => x > 3), arr.findIndex(x => x > 3));
console.log(arr.some(x => x > 4), arr.every(x => x > 0), [[1, [2]], [3]].flat(), [[1, [2]], [3]].flat(Infinity), [1, 2].flatMap(x => [x, x * 2]));
const sp = [1, 2, 3, 4, 5];
console.log(sp.splice(1, 2, "a", "b", "c"), sp, sp.shift(), sp.unshift(0), sp, sp.reverse(), new Array(3).fill(7));
console.log(Array.of(1, 2), Array.from({ length: 3 }, (_, i) => i * i), [3, 1, 2].findLast(x => x > 1), [1, 2, 3].join());

const s = "  Hello, World  ";
console.log(s.trim(), s.trimStart(), s.trimEnd() + "|", s.toLowerCase(), "abc".padStart(6, "12"), "abc".padEnd(5) + "|");
console.log("a-b-c".split("-"), "abc".split(""), "a,b,,c".split(",", 2), "abc".repeat(3), "abcabc".lastIndexOf("bc"));
console.log("hello".replace("l", "L"), "hello".replaceAll("l", "L"), "x".replace("x", "$&$&"), "aXbXc".replace("X", (m, i) => `[${m}${i}]`));
console.log("Hello".startsWith("He"), "Hello".endsWith("lo"), "Hello".includes("ell"), "Hello".charAt(1), "Hello".at(-1), "😀".codePointAt(0));
console.log(String.fromCharCode(72, 105), String.fromCodePoint(128512), "abc".substring(2, 0), "abc".concat(1, 2), "b".localeCompare("a"));

console.log(parseInt("42px"), parseInt("0x1F"), parseInt("101", 2), parseFloat("3.14abc"), parseFloat(".5e1"), Number.isSafeInteger(2 ** 53), Number.isNaN("x"));
console.log((255).toString(16), (255).toString(2), (-7.5).toString(2), (0.5).toString(4), Number.MAX_SAFE_INTEGER, Number.EPSILON > 0);
console.log(Math.round(2.5), Math.round(-2.5), Math.round(-0.4), Math.trunc(-4.7), Math.sign(-3), Math.cbrt(27), Math.hypot(3, 4), Math.clz32(1), Math.fround(5.5));
console.log(Math.atan2(1, 1), Math.log2(8), Math.log10(1000), Math.pow(2, 0.5), Math.imul(0xffffffff, 5), Math.E, Math.ceil(-0.5));
const rnd = Math.random();
console.log(rnd >= 0 && rnd < 1);

console.log(JSON.stringify({ a: [1, "two", null, true], b: { c: undefined, d: () => 1 }, e: NaN }));
console.log(JSON.stringify([1, { x: 2 }], null, 2));
console.log(JSON.stringify({ when: { toJSON() { return "custom"; } } }), JSON.stringify("q\"\n"), JSON.stringify(undefined));
console.log(JSON.parse('{"a":[1,2,{"b":"x\\ny"}],"c":-1.5e2,"d":null}'), JSON.parse("true"), JSON.parse(' "\\u0041" '));
try { JSON.parse("{bad}"); } catch (e) { console.log(e.name); }
const cyclic = {};
cyclic.self = cyclic;
try { JSON.stringify(cyclic); } catch (e) { console.log(e.name, e.message.split("\n")[0]); }

function greet(greeting, punct) { return `${greeting}, ${this.name}${punct}`; }
const bob = { name: "Bob" };
console.log(greet.call(bob, "Hi", "!"), greet.apply(bob, ["Yo", "?"]), greet.bind(bob, "Hey")("."), greet.bind(bob).name);
class P { constructor(x) { this.x = x; } }
const BoundP = P.bind(null, 7);
console.log(new BoundP().x, Reflect.construct(P, [3]).x, Reflect.has({ q: 1 }, "q"), Reflect.ownKeys({ a: 1, [Symbol("s")]: 2 }));
console.log(typeof Date.now(), typeof performance.now(), Boolean(1).toString(), (true).valueOf());
