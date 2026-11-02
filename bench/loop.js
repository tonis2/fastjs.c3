// Tight integer arithmetic.
function bench() {
	let s = 0;
	for (let i = 0; i < 20000000; i++) s = (s + i * i) % 1000003;
	return s;
}
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
