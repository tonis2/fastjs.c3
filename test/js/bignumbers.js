// Numbers outside int32: conversions that are undefined behaviour in C if done carelessly.
const vals = [1e21, -1e21, 2**31, -(2**31) - 1, 2**32, 2**53, 1e300, -1e300, Infinity, -Infinity, NaN, 4294967296.5, -0.5, 2147483647.5];
for (const v of vals) console.log(v, v | 0, v >>> 0, v >> 1, ~v, [1,2,3].at(v), 'abc'.at(v), Math.floor(v), Math.round(v), v % 7, String(v));
try { new ArrayBuffer(1e30) } catch (e) { console.log(e.constructor.name) }
try { new Float32Array(new ArrayBuffer(8), 1e30) } catch (e) { console.log(e.constructor.name) }
console.log(''.repeat(1e30).length, new Uint8Array([300, -1, 1e30, NaN, 2.5]), new Int32Array([1e30, -1e30, 2**31]), new Uint8ClampedArray([1e30, -5, 2.5, 3.5]));
console.log([1e21].map(x => x + 1), JSON.stringify({a: 1e21, b: -(2**31) - 1}), (2**31).toString(16), (-(2**53)).toString(36));
