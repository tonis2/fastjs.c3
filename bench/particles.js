// Game-style update: property reads and writes on many small objects, float math.
function bench() {
	const ps = [];
	for (let i = 0; i < 2000; i++) ps.push({ x: i, y: i * 0.5, vx: (i % 7) - 3, vy: (i % 5) - 2, alive: true });
	for (let frame = 0; frame < 500; frame++) {
		for (let i = 0; i < ps.length; i++) {
			const p = ps[i];
			p.vy += 0.1;
			p.x += p.vx * 0.016;
			p.y += p.vy * 0.016;
			if (p.y > 1000) { p.y = 0; p.vy = -p.vy * 0.5; }
		}
	}
	let sum = 0;
	for (const p of ps) sum += p.x + p.y;
	return Math.floor(sum);
}
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
