// for-of over generators, which the interpreter runs inline: every way in and out of the loop.
function* count(n) { for (let i = 0; i < n; i++) yield i; return 'done'; }
let out = [];
for (const v of count(3)) out.push(v);
console.log(out.join());

// A throw inside the generator reaches the loop's handler, and the generator is finished.
function* boom() { yield 1; throw new Error('inside'); }
const g1 = boom();
try { for (const v of g1) out.push('b' + v); } catch (e) { console.log('caught', e.message, g1.next().done); }

// A throw in the body (the generator is suspended) and a break both close it: finally runs.
function* guarded() { try { yield 1; yield 2; } finally { console.log('finally ran'); } }
for (const v of guarded()) { console.log('got', v); break; }
try { for (const v of guarded()) throw new Error('body'); } catch (e) { console.log('body threw', e.message); }

// return from inside the loop, in a function.
function first(g) { for (const v of g) return v; return 'empty'; }
console.log(first(count(5)), first(count(0)));

// Nested generators, each running inline in the other's loop.
function* evens(n) { for (const i of count(n)) if (i % 2 === 0) yield i; }
function* pairs() { for (const a of evens(4)) for (const b of evens(4)) yield a * 10 + b; }
console.log([...pairs()].join(), Array.from(pairs()).length);
let s = 0; for (const p of pairs()) s += p; console.log(s);

// yield* inside a generator iterated by for-of.
function* both() { yield* count(2); yield* ['x', 'y']; yield 'z'; }
out = []; for (const v of both()) out.push(v); console.log(out.join());

// Iterating a generator that is already running is an error.
function* self() { for (const v of it) yield v; }
const it = self();
try { for (const v of it) {} } catch (e) { console.log(e.constructor.name, e.message); }

// A started generator continues where it was; a finished one gives nothing.
const g2 = count(5); g2.next(); g2.next();
out = []; for (const v of g2) out.push(v); console.log(out.join());
for (const v of g2) console.log('never');

// The loop variable and closures over it, and a generator with no yield at all.
const fns = []; for (const v of count(3)) fns.push(() => v); console.log(fns.map(f => f()).join());
function* none() { return 1; } for (const v of none()) console.log('never'); console.log('none ok');

// Methods and this.
class Bag { constructor() { this.items = ['p', 'q']; } *[Symbol.iterator]() { for (const i of this.items) yield i.toUpperCase(); } }
console.log([...new Bag()].join(), (() => { let r = ''; for (const v of new Bag()) r += v; return r; })());

// A deep loop of generators doesn't grow the C stack.
function* deep(n) { if (n > 0) { for (const v of deep(n - 1)) yield v; } else yield 'bottom'; }
for (const v of deep(500)) console.log(v);
