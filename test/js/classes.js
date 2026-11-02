// Classes the way three.c3 uses them: fields, statics, accessors, super, inheritance chains.
class Vec {
	x = 0;
	y = 0;
	static zero = new Vec();
	static count = 0;
	constructor(x = 0, y = 0) {
		this.x = x;
		this.y = y;
		Vec.count++;
	}
	get length() { return Math.sqrt(this.x * this.x + this.y * this.y); }
	set length(l) { const s = l / this.length; this.x *= s; this.y *= s; }
	add(o) { return new Vec(this.x + o.x, this.y + o.y); }
	toString() { return `Vec(${this.x}, ${this.y})`; }
	static of(x, y) { return new this(x, y); }
}
const v = new Vec(3, 4);
console.log(v, v.length, `${v.add(Vec.of(1, 1))}`, Vec.zero, Vec.count);
v.length = 10;
console.log(v.x, v.y, Object.keys(v), typeof Vec, Vec.name, Vec.length);

class Entity {
	static registry = [];
	alive = true;
	name;
	constructor(name) {
		this.name = name;
		Entity.registry.push(name);
	}
	describe() { return `${this.constructor.name}(${this.name})`; }
	update(dt) { return "entity " + dt; }
	get kind() { return "entity"; }
	static create(...args) { return new this(...args); }
}
class Critter extends Entity {
	speed = 2;
	static capacity = 8;
	constructor(name, speed) {
		super(name);
		if (speed !== undefined) this.speed = speed;
	}
	update(dt) { return "critter:" + super.update(dt * this.speed); }
	get kind() { return "critter < " + super.kind; }
}
class Boss extends Critter {
	update(dt) { return "boss:" + super.update(dt); }
}
const c = new Critter("bug", 3);
const b = Boss.create("big");
console.log(c, b);
console.log(c.update(1), b.update(2), c.kind, b.describe(), b.kind);
console.log(b instanceof Boss, b instanceof Critter, b instanceof Entity, c instanceof Boss);
console.log(Entity.registry, Boss.capacity, Object.keys(b), Critter.create("x").speed);
console.log(Object.getPrototypeOf === undefined, Boss.name, new Boss("n").name);

class Shape {
	static [`computed${1 + 1}`]() { return "static computed"; }
	["dyn" + "amic"]() { return "computed method"; }
}
console.log(Shape.computed2(), new Shape().dynamic());

try {
	Vec(1, 2);
} catch (e) {
	console.log(e.constructor === TypeError, e.message);
}
class Early extends Entity {
	constructor() {
		this.x = 1;
		super("early");
	}
}
try { new Early(); } catch (e) { console.log(e.name, e.message); }
class Twice extends Entity {
	constructor() { super("a"); super("b"); }
}
try { new Twice(); } catch (e) { console.log(e.name, e.message); }

class AppError extends Error {
	constructor(message, code) {
		super(message);
		this.code = code;
	}
	get name() { return "AppError"; }
}
const err = new AppError("bad thing", 42);
console.log(err instanceof AppError, err instanceof Error, err.message, err.code, err.name, String(err));

const Anon = class {};
const Named = class Inner { who() { return Inner.name; } };
console.log(Anon.name, Named.name, new Named().who());
console.log([Vec, Critter, Anon], Object.keys(Vec.prototype));

