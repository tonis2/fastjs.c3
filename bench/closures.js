// Callbacks through a native higher-order function, and closure state.
function bench() {
	const arr = [];
	for (let i = 0; i < 1000; i++) arr.push(i);
	let total = 0;
	const scale = 3;
	for (let k = 0; k < 2000; k++) {
		const out = arr.map(x => x * scale + k);
		total = (total + out[999]) % 1000003;
	}
	return total;
}
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
