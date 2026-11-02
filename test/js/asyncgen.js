// Async generators and for await.
const log = (...a) => console.log(...a);
async function* counter(n) {
	try {
		for (let i = 0; i < n; i++) {
			await null;
			const sent = yield i;
			if (sent) log('sent', sent);
		}
		return 'end';
	} finally {
		log('counter finally');
	}
}
async function* fromPromises() { yield Promise.resolve('a'); yield 'b'; const x = await new Promise(r => r("c")); yield x; }
async function main() {
	for await (const v of counter(3)) log('v', v);
	const g = counter(5);
	log(JSON.stringify(await g.next()), JSON.stringify(await g.next('hi')));
	// Requests made before the first one settles are served in order.
	const [a, b, c] = await Promise.all([g.next(), g.next(), g.return('early')]);
	log(JSON.stringify(a), JSON.stringify(b), JSON.stringify(c), JSON.stringify(await g.next()));
	try { for await (const v of counter(5)) { if (v === 1) throw new Error('stop'); } } catch (e) { log('caught', e.message); }
	for await (const v of counter(5)) { if (v === 2) break; }
	for await (const v of [1, Promise.resolve(2), 3]) log('sync', v);
	const it = { [Symbol.asyncIterator]() { let i = 0; return { next() { return Promise.resolve({ value: i, done: i++ >= 2 }); }, return() { log('custom return'); return Promise.resolve({ done: true }); } }; } };
	for await (const v of it) log('custom', v);
	for await (const v of it) { break; }
	async function* boom() { yield 1; throw new Error('gen threw'); }
	try { for await (const v of boom()) log('boom', v); } catch (e) { log(e.message); }
	const t = boom(); await t.next(); log(await t.throw(new Error('in')).catch(e => 'rejected ' + e.message));
	log(Object.getPrototypeOf(counter).constructor.name, typeof counter.prototype, counter(1)[Symbol.asyncIterator] !== undefined);
	for await (const [k, v] of new Map([['x', 1]])) log(k, v);
	log(JSON.stringify(await fromPromises().next()));
	const out = []; for await (const v of fromPromises()) out.push(v); log(out.join());
}
main().then(() => log('done'));
