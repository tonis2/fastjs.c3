// Promise and await throughput: an await loop, promise chains, Promise.all fan-out.
async function step(i) { return i & 3; }
async function bench() {
	let sum = 0;
	for (let i = 0; i < 300000; i++) sum += await step(i);
	for (let i = 0; i < 300000; i++) sum += await i;
	let p = Promise.resolve(0);
	for (let i = 0; i < 100000; i++) p = p.then(v => v + 1);
	sum += await p;
	for (let i = 0; i < 100; i++) {
		const all = await Promise.all(Array.from({ length: 1000 }, (_, k) => step(k)));
		sum += all.length;
	}
	return sum;
}
bench().then(r => { if (typeof console !== "undefined") console.log(r); else globalThis.__result = r; });
