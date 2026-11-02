// Regular expressions: the forms three.c3 uses, plus the common API.
console.log(/\.glb$|\.gltf$/i.test("Model.GLB"), /\.glb$|\.gltf$/i.test("x.png"), /^\d+$/.test("123"), /^\d+$/.test("12a"));
console.log("dir/sub\\file.txt".replace(/^.*[/\\]/, ""), /disposed|no longer in the scene/i.test("Node was DISPOSED"));
console.log(/a|ab/.exec("ab")[0], /(a+)(b*)/.exec("xaabbb"), /(\w+)@(\w+)\.com/.exec("mail bob@site.com now").slice(1));
console.log("a1b22c333".match(/\d+/g), "none".match(/\d/g), "2024-11-02".match(/(\d+)-(\d+)-(\d+)/).slice(1, 4));
console.log("a-b_c d".split(/[-_ ]/), "a1b2c3".split(/\d/), "abc".split(/(b)/), "x".split(/y/));
console.log("John Smith".replace(/(\w+)\s(\w+)/, "$2, $1"), "aaa".replace(/a/g, "b"), "camelCaseName".replace(/[A-Z]/g, m => "_" + m.toLowerCase()));
console.log("price: 10, 20".replace(/\d+/g, (m, i) => `${m * 2}@${i}`), "abc".replace(/x*/g, "-"), "test".search(/s/));
const re = /o/g;
console.log(re.exec("foo boo").index, re.lastIndex, re.exec("foo boo").index, re.lastIndex, re.test("foo boo"), re.lastIndex);
console.log(/a.c/s.test("a\nc"), /a.c/.test("a\nc"), /^b/m.test("a\nb"), /^b/.test("a\nb"), /\bcat\b/.test("a cat!"), /\Bcat/.test("concat"));
console.log(/(?:ab)+/.exec("ababab")[0], /a+?/.exec("aaa")[0], /a{2,3}/.exec("aaaa")[0], /a{2}/.test("a"), /(\d)\1/.test("1223"));
console.log(/foo(?=bar)/.exec("foobar")[0], /foo(?!bar)/.test("foobar"), /[^aeiou\s]+/.exec("aei xyz")[0], /[a-c\d]+/.exec("zzab12x")[0]);
const named = /(?<year>\d{4})-(?<month>\d{2})/.exec("on 2024-11");
console.log(named.groups.year, named.groups.month, named.index);
console.log([..."a1b2".matchAll(/[a-z](\d)/g)].map(m => m[1]), /x/gi.flags, /x/m.source, String(/a\/b/g), new RegExp("a+", "g").test("caat"));
console.log(/A\x42/.test("AB"), /[à-ÿ]/.test("é"), /😀/.test("hi 😀"), /^.$/u.test("é"));
console.log(/(a)|(b)/.exec("b"), /\//.source);
try { new RegExp("("); } catch (e) { console.log(e.name); }
