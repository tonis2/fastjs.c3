// throw/catch/finally, built-in errors, finally with return/break/continue.
try {
	throw new Error("boom");
} catch (e) {
	console.log(e.message, e.name, e instanceof Error, e instanceof TypeError);
}

try {
	undefinedVariable;
} catch (e) {
	console.log(e.name, e.message);
}

try {
	const o = undefined;
	o.prop;
} catch (e) {
	console.log(e.name, e.message);
}

try {
	null();
} catch (e) {
	console.log(e.name);
}

function withFinally() {
	try {
		return "from try";
	} finally {
		console.log("finally runs");
	}
}
console.log(withFinally());

function overrides() {
	try {
		throw new Error("lost");
	} finally {
		return "finally wins";
	}
}
console.log(overrides());

const seen = [];
for (let i = 0; i < 4; i++) {
	try {
		if (i === 1) continue;
		if (i === 3) break;
		seen.push("body" + i);
	} finally {
		seen.push("fin" + i);
	}
}
console.log(seen);

function nested() {
	try {
		try {
			throw new TypeError("inner");
		} finally {
			console.log("inner finally");
		}
	} catch (e) {
		return "caught " + e.name + ": " + e.message;
	}
}
console.log(nested());

try {
	throw { custom: 1 };
} catch ({ custom }) {
	console.log("custom", custom);
}

try {
	let early = later + 1;
	let later = 2;
} catch (e) {
	console.log(e.name, e.message);
}

try {
	const k = 1;
	k = 2;
} catch (e) {
	console.log(e.name, e.message);
}

function deepThrow(n) { if (n === 0) throw new RangeError("bottom"); return deepThrow(n - 1); }
try { deepThrow(50); } catch (e) { console.log(String(e)); }

try {
	(function recurse() { recurse(); })();
} catch (e) {
	console.log(e instanceof RangeError);
}
console.log("still running");
