// String concatenation and template literals.
function bench() {
	let total = 0;
	for (let k = 0; k < 200; k++) {
		let s = "";
		for (let i = 0; i < 1000; i++) s += `${i},`;
		total += s.length;
	}
	return total;
}
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
