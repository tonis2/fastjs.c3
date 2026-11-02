// Generators: protocol, yield*, return/throw, finally, iterator closing.
function* count(n) {
	for (let i = 0; i < n; i++) yield i;
	return 'end';
}
const g = count(3);
console.log(g.next(), g.next(), g.next(), g.next(), g.next());
console.log([...count(5)], Array.from(count(3)), new Set(count(4)));
console.log(Math.max(...count(10)));

function* args(a, b = a * 2, ...rest) { yield a; yield b; yield rest; }
console.log([...args(1)], [...args(1, 5, 6, 7)]);

// Parameter defaults run at the call, the body at the first next().
function* lazy(x = console.log('default evaluated')) { console.log('body runs'); yield x; }
const l = lazy();
console.log('created');
l.next();

function* echo() {
	let got = yield 1;
	while (true) got = yield got * 2;
}
const e = echo();
console.log(e.next(), e.next(5), e.next(7));

function* exprs() {
	const a = (yield 'first') + (yield 'second');
	const arr = [yield 'x', yield 'y'];
	console.log('a', a, 'arr', arr);
	return Math.max(yield 'm1', yield 'm2');
}
const x = exprs();
const seen = [x.next().value];
for (let i = 1; i < 7; i++) seen.push(x.next(i * 10).value);
console.log(seen);

// Closures inside generators see per-iteration bindings.
function* makers() { for (let i = 0; i < 3; i++) yield () => i; }
console.log([...makers()].map(f => f()));
function* counter() { let n = 0; const inc = () => ++n; while (n < 3) yield inc(); }
console.log([...counter()]);

// return() and throw() run finally blocks.
function* fin() {
	try { yield 1; yield 2; } finally { console.log('cleanup'); }
}
for (const v of fin()) { console.log('got', v); break; }
const f = fin(); f.next(); console.log(f.return(42), f.next());
const f2 = fin(); console.log(f2.return(1), f2.next());
function* finYield() { try { yield 1; } finally { yield 'from finally'; console.log('after'); } }
const fy = finYield(); fy.next();
console.log(fy.return('r'), fy.next(), fy.next());

function* thrower() { try { yield 1; } catch (err) { console.log('caught', err); yield 2; } }
const t = thrower(); t.next(); console.log(t.throw('boom'), t.next());
const t2 = thrower();
try { t2.throw(new Error('early')); } catch (err) { console.log('not started:', err.message); }
console.log(t2.next());

function* reenter() { yield r.next(); }
const r = reenter();
try { r.next(); } catch (err) { console.log(err.constructor.name, err.message); }

// yield* delegates everything, including the inner return value.
function* inner() { try { yield 'a'; yield 'b'; } finally { console.log('inner finally'); } return 'r'; }
function* outer() { const res = yield* inner(); yield res; yield* [1, 2]; yield* 'hi'; }
console.log([...outer()]);
const o = outer(); o.next(); console.log(o.return('stop'), o.next());
function* catcher() { while (true) { try { yield 'ready'; } catch (err) { console.log('inner caught', err); } } }
function* deleg() { yield* catcher(); }
const d = deleg(); d.next(); console.log(d.throw('E1'), d.throw('E2'));

// Return inside for-of closes the iterator.
function find(it, want) { for (const v of it) if (v === want) return 'found ' + v; return 'none'; }
function* noisy() { try { yield 1; yield 2; yield 3; } finally { console.log('noisy closed'); } }
console.log(find(noisy(), 2), find(noisy(), 9));

// Destructuring stops early and closes.
const [first, second] = noisy();
console.log(first, second);

class Tree {
	constructor(v, kids = []) { this.v = v; this.kids = kids; }
	*[Symbol.iterator]() { yield this.v; for (const k of this.kids) yield* k; }
}
console.log([...new Tree(1, [new Tree(2), new Tree(3, [new Tree(4)])])]);
const obj = { *entries() { yield ['a', 1]; yield ['b', 2]; }, *[Symbol.iterator]() { yield* this.entries(); } };
console.log(new Map(obj), Object.fromEntries(obj.entries()));

class Store {
	constructor() { this.items = [3, 1, 2]; }
	*sorted() { yield* [...this.items].sort(); }
	static *range(a, b) { while (a < b) yield a++; }
}
console.log([...new Store().sorted()], [...Store.range(2, 6)]);

function* fib() { let [a, b] = [0, 1]; while (true) { yield a; [a, b] = [b, a + b]; } }
const firstTen = [];
for (const n of fib()) { if (firstTen.length === 10) break; firstTen.push(n); }
console.log(firstTen);

function* big() { for (let i = 0; i < 20000; i++) yield { i, s: 'v' + i }; }
let total = 0;
for (const item of big()) total += item.i + item.s.length;
console.log(total);
console.log(g, count, typeof g.next, g[Symbol.iterator]() === g);
