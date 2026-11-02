// Closures capture variables, not values; let in loops is per-iteration.
const fns = [];
for (let i = 0; i < 3; i++) fns.push(() => i);
console.log(fns.map(f => f()));

const later = [];
for (const name of ["a", "b", "c"]) later.push(() => name.toUpperCase());
console.log(later.map(f => f()));

function outer() {
	let x = 1;
	function inner() { return x; }
	x = 2;
	return inner;
}
console.log(outer()());

function adder(start) {
	return function (n) { start += n; return start; };
}
const acc = adder(10);
acc(5);
console.log(acc(1));

function deep() {
	let a = "a";
	return () => () => () => a + "!";
}
console.log(deep()()()());

let shared = 0;
const bump = () => shared++;
bump(); bump();
console.log(shared);

function params(p) {
	return [() => p, (v) => { p = v; }];
}
const [get, set] = params("first");
set("second");
console.log(get());
