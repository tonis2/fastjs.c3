// Declarations, hoisting, recursion, defaults, rest, arrows, named function expressions.
console.log(hoisted(2));
function hoisted(v) { return v * 10; }

function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
console.log(fib(20));

function defaults(a, b = a + 1, c = b * 2) { return [a, b, c]; }
console.log(defaults(1), defaults(1, 5), defaults(1, undefined, 0));

function rest(first, ...others) { return first + ":" + others.join("+"); }
console.log(rest(1), rest(1, 2, 3));

const square = x => x * x;
const add = (a, b) => a + b;
const make = () => ({ made: true });
console.log(square(9), add(2, 3), make());

const fact = function f(n) { return n <= 1 ? 1 : n * f(n - 1); };
console.log(fact(10));

function counter() {
	let count = 0;
	return { inc: () => ++count, get: () => count };
}
const c1 = counter();
const c2 = counter();
c1.inc(); c1.inc(); c2.inc();
console.log(c1.get(), c2.get());

const obj = {
	value: 42,
	regular() { return this.value; },
	arrow() { return (() => this.value)(); },
};
console.log(obj.regular(), obj.arrow());

function Point(x, y) { this.x = x; this.y = y; }
const p = new Point(1, 2);
console.log(p.x + p.y, p instanceof Point, typeof Point.prototype);

console.log(square.name, add.length, fact.name, rest.length, (function () {}).name === "");
function spreadArgs(a, b, c) { return a + b + c; }
console.log(spreadArgs(...[1, 2, 3]), spreadArgs(1, ...[2, 3]));
