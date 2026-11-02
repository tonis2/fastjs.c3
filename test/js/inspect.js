// console.log layout: line breaking, grouping, depth, holes, accessors, classes.
console.log([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]);
console.log(["apple", "banana", "cherry", "date", "elderberry", "fig", "grape", "honeydew"]);
const big = [];
for (let i = 0; i < 120; i++) big.push(i * 3);
console.log(big);
console.log({ level1: { level2: { level3: { level4: "hidden" } } } });
console.log([[1, [2, [3, [4]]]]]);
console.log({ a: 1, b: "two", c: [1, 2, 3], d: { e: null, f: undefined }, g: true, h: -0, i: 1.5e300 });
const holes = [1, , , 4, , 6];
holes.extra = "prop";
console.log(holes);
const self = { name: "loop" };
self.me = self;
console.log(self);
function Thing() { this.id = 7; }
console.log(new Thing(), [new Thing()], { t: new Thing() });
console.log({ get only() { return 1; }, set only(v) {}, get g() { return 2; } });
console.log("%", "a\nb", ["a\nb", "it's", 'say "hi"', `both ' and "`]);
console.log([undefined, null, NaN, -Infinity], [function named() {}, () => {}]);
const wide = {};
for (let i = 0; i < 30; i++) wide["key" + i] = i;
console.log(wide);
