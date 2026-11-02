// Numbers, strings, typeof, and how console.log prints them.
console.log(1 + 2, 7 - 10, 6 * 7, 7 / 2, 7 % 3, -7 % 3, 2 ** 10);
console.log(0.1 + 0.2, 1 / 3, 1e21, 1e-7, 123456789 * 1000, -0, 0 * -1);
console.log(2147483647 + 1, -2147483648 - 1, 46341 * 46341);
console.log(1 / 0, -1 / 0, 0 / 0);
console.log("a" + "b", "n=" + 5, 5 + "5", 1 + 2 + "3", "3" * "4", "10" / 4);
console.log(typeof 1, typeof "s", typeof true, typeof undefined, typeof null, typeof {}, typeof [], typeof console.log);
console.log(typeof notDeclaredAnywhere);
console.log(true + 1, null + 1, undefined + 1, "" + null, [1, 2] + "", ({}) + "");
console.log(5 & 3, 5 | 3, 5 ^ 3, ~5, 1 << 31, -16 >> 2, -16 >>> 28);
console.log(Math.floor(3.7), Math.max(1, 9, 4), Math.min(), Math.abs(-2.5), Math.sqrt(16));
console.log((1.005).toFixed(2), (12.5).toFixed(0), (0.000001).toFixed(7));
console.log(String(123), Number("42"), Number(""), Number("x"), Boolean(""), Boolean("0"));
console.log(0.1 * 3, 100 / 3, 2 ** 53, 2 ** 53 + 1, -1e-7);
