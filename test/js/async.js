// async/await, promises and the order microtasks run in.
const log = (...a) => console.log(...a);
async function f(x) { log('f start', x); const y = await x; log('f got', y); return y * 2; }
const p = f(1);
log('after call', p);
p.then(v => log('then', v));
Promise.resolve(1).then(v => log('a', v)).then(() => log('b'));
(async () => { log('iife'); await null; log('iife 2'); await new Promise(r => r(3)); log('iife 3'); })();
queueMicrotask(() => log('micro'));
async function bad() { await 1; throw new Error('nope'); }
bad().catch(e => log('caught', e.message));
async function badSync() { throw new RangeError('sync'); }
const bs = badSync();
log('badSync returned', bs instanceof Promise);
bs.catch(e => log('badSync caught', e.name));
async function tryit() {
	try { await Promise.reject(new TypeError('tt')); } catch (e) { log('in catch', e.name); } finally { log('fin'); }
	return 'ok';
}
tryit().then(log);
async function finRet() { try { return await 'value'; } finally { log('finRet finally'); } }
finRet().then(v => log('finRet', v));
new Promise((res, rej) => rej(5)).then(null, r => log('rejected', r));
new Promise(() => { throw new Error('in executor'); }).catch(e => log('executor', e.message));
new Promise(res => { res(1); res(2); throw new Error('ignored'); }).then(v => log('first wins', v));
Promise.all([1, Promise.resolve(2), f(10)]).then(v => log('all', v));
Promise.all([]).then(v => log('all empty', v));
Promise.all([1, Promise.reject('no')]).catch(v => log('all rejects', v));
Promise.allSettled([1, Promise.reject(2)]).then(v => log('settled', v));
Promise.race([new Promise(() => {}), Promise.resolve('fast')]).then(v => log('race', v));
Promise.any([Promise.reject(1), Promise.resolve('any')]).then(v => log('any', v));
Promise.any([Promise.reject(1), Promise.reject(2)]).catch(e => log('any failed', e.errors));
Promise.reject(9).finally(() => log('finally')).catch(v => log('after finally', v));
Promise.resolve(8).finally(() => log('finally2')).then(v => log('after finally2', v));
const thenable = { then(res) { log('thenable then'); res('T'); } };
(async () => log('awaited thenable', await thenable))();
Promise.resolve(thenable).then(v => log('resolved thenable', v));
const self = Promise.resolve().then(() => self);
self.catch(e => log('cycle', e.constructor.name, e.message));
log('sync end');

class Base { async load() { await null; return 'base'; } }
class Derived extends Base {
	constructor() { super(); this.v = 7; }
	async load() { const b = await super.load(); return b + '+' + this.v; }
}
new Derived().load().then(v => log('method', v));
const arrow = async (a, b = a + 1) => a + b;
arrow(1).then(v => log('arrow', v));
const holder = { n: 5, go() { return (async () => { await 0; return this.n; })(); } };
holder.go().then(v => log('arrow this', v));

// Interleaving: two loops take turns, one tick per await.
async function ticker(name, n) { for (let i = 0; i < n; i++) { log(name, i); await null; } return name; }
Promise.all([ticker('A', 3), ticker('B', 2)]).then(v => log('tickers', v));

// Returning a promise from an async function takes extra ticks; awaiting it does not.
async function returnsPromise() { return Promise.resolve('rp'); }
async function awaitsPromise() { return await Promise.resolve('ap'); }
returnsPromise().then(log);
awaitsPromise().then(log);
Promise.resolve().then(() => log('tick 1')).then(() => log('tick 2')).then(() => log('tick 3')).then(() => log('tick 4'));

async function sum(n) { let s = 0; for (let i = 0; i < n; i++) s += await i; return s; }
sum(10000).then(v => log('sum', v));
async function recurse(n) { return n === 0 ? 0 : 1 + await recurse(n - 1); }
recurse(200).then(v => log('recurse', v));
async function loopOf() { const out = []; for (const x of [1, 2, 3]) out.push(await Promise.resolve(x * x)); return out; }
loopOf().then(v => log('loopOf', v));
const { promise, resolve } = Promise.withResolvers();
promise.then(v => log('withResolvers', v));
resolve('done');
log(Promise.resolve(4), new Promise(() => {}), typeof Promise, Promise.name);
