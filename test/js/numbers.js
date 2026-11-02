// Number formatting: toPrecision, toExponential; and copyWithin.
const xs = [0, 1, -1, 0.3, 0.1234567891, Math.fround(0.3), 123456, 1e21, 1.5e-7, 2.5, 9.99, 0.000001234, 1234.5678, -0.0005, 99.5, 1/3, Math.PI];
for (const x of xs) console.log(x, [1, 2, 3, 6, 9, 17].map(p => x.toPrecision(p)).join(' '), x.toExponential(), x.toExponential(2), x.toPrecision());
console.log(new Float32Array([1, 2, 3, 4, 5]).copyWithin(0, 3), [1, 2, 3, 4, 5].copyWithin(-2, 0, 2), new Int16Array([1,2,3,4,5,6]).copyWithin(2, 0));
try { (1).toPrecision(0) } catch (e) { console.log(e.message) }
