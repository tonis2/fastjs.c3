// Method calls through a prototype, and constructing small objects.
function Vec(x, y) { this.x = x; this.y = y; }
Vec.prototype.add = function (o) { return new Vec(this.x + o.x, this.y + o.y); };
Vec.prototype.dot = function (o) { return this.x * o.x + this.y * o.y; };
function bench() {
	let acc = new Vec(0, 0);
	const step = new Vec(1, 2);
	let d = 0;
	for (let i = 0; i < 1000000; i++) {
		acc = acc.add(step);
		d = (d + acc.dot(step)) % 1000003;
	}
	return d;
}
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
