// Built-ins three.c3's tests needed: lookbehind, AsyncFunction, TypedArray.from/of, Function toString.
const text = 'use three.camera here, not mythree.camera or three.cameras; (three.camera)';
console.log(text.match(/(?<![\w$])three\.camera(?![\w$])/g), text.replace(/(?<![\w$])three\.camera(?![\w$])/g, 'CAM'));
console.log('$10 €20 $30'.match(/(?<=\$)\d+/g), 'abc'.replace(/(?<=a)b/, 'X'), /(?<!foo)bar/.test('foobar'), /(?<!foo)bar/.test('fobar'));
console.log('price: 42 dollars'.match(/(?<=price: )(\d+)/), /(?<=a+)b/.exec('aaab'), 'x,y,z'.replace(/(?<=^|,)\w+/g, '[$&]'));
console.log('x'.repeat(20000).replace(/(?<![\w$])y/g, 'z').length);

{
const af = async () => 1; async function g() {} function* gen() {} function plain() {}
console.log(af.constructor.name, g.constructor.name, gen.constructor.name, plain.constructor.name, af instanceof Function, Object.getPrototypeOf(af) === Function.prototype);
console.log(Int32Array.from([1, 2.7, -3]), Float32Array.from(new Set([1, 2])), Uint8Array.from({ length: 3 }, (_, i) => i * 2), Float64Array.of(1, 2, 3), Int16Array.from('123'));
}
{
const f = () => 1; function named(a, b = 2) { return a + b; } const o = { m(x) { return x; }, get g() { return 1; }, async am() {} };
class K extends Object { constructor() { super(); } static s() {} }
console.log(String(f), '|', named.toString(), '|', o.m.toString(), '|', String(Math.max), '|', K.toString(), '|', String(K.s), '|', String(async (x) => x * 2));
console.log(JSON.stringify([undefined, String(() => 1)]));
}
{
	const o = { a: 1, get b() { return 2; } };
	Object.defineProperty(o, 'hidden', { value: 3, enumerable: false });
	const d = Object.getOwnPropertyDescriptors(o);
	console.log(Object.keys(d), d.a, typeof d.b.get, d.hidden, Object.keys(Object.getOwnPropertyDescriptors([5, 6])));
}
