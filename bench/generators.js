// Generator iteration: for-of over generators, yield* delegation, spread.
function* range(n) { for (let i = 0; i < n; i++) yield i; }
function* evens(n) { for (const i of range(n)) if ((i & 1) === 0) yield i; }
class Grid {
	constructor(w, h) { this.w = w; this.h = h; }
	*cells() { for (let y = 0; y < this.h; y++) for (let x = 0; x < this.w; x++) yield x + y * this.w; }
}
function bench() {
	let sum = 0;
	for (const v of range(1000000)) sum += v;
	for (const v of evens(1000000)) sum -= v;
	const g = new Grid(100, 100);
	for (let i = 0; i < 50; i++) for (const c of g.cells()) sum += c & 7;
	function* both() { yield* range(1000); yield* range(1000); }
	for (let i = 0; i < 200; i++) sum += [...both()].length;
	return sum;
}
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
