// if/else, loops, break/continue, switch.
let total = 0;
for (let i = 0; i < 10; i++) {
	if (i % 2 === 0) continue;
	if (i > 7) break;
	total += i;
}
console.log("total", total);

let n = 0;
while (n < 5) n++;
console.log("n", n);

for (let i = 0; i < 3; i++) {
	for (let j = 0; j < 3; j++) {
		if (j === 2) break;
		console.log(i, j);
	}
}

function grade(score) {
	switch (true) {
		case score >= 90: return "A";
		case score >= 80: return "B";
		default: return "C";
	}
}
console.log(grade(95), grade(85), grade(10));

function names(x) {
	let out = "";
	switch (x) {
		case 1:
			out += "one ";
		case 2:
			out += "two ";
			break;
		case "3":
			out += "string three ";
			break;
		default:
			out += "other ";
	}
	return out;
}
console.log(names(1), "|", names(2), "|", names(3), "|", names("3"));

let x = 0;
if (x) console.log("truthy"); else if (x === 0) console.log("zero"); else console.log("other");
console.log([] ? "empty array is truthy" : "falsy", "" ? "yes" : "empty string is falsy");
for (;;) { x++; if (x > 3) break; }
console.log("x", x);
