// Template literals, escapes, unicode, string properties.
const name = "world";
console.log(`hello ${name}!`, `${1 + 1} = two`, `nested ${`inner ${name.length}`}`);
console.log(`multi
line`);
console.log("tab\there", "quote\"s", 'single\'s', "\x41B\u{43}");
const s = "héllo π 😀";
console.log(s, s.length, s[1], s.charCodeAt(7), s.toUpperCase());
console.log("abc"[5], "abc".length, "a" + 1 + 2, 1 + 2 + "a");
console.log(`${null} ${undefined} ${[1, 2]} ${{}}`);
console.log(["a", 'b', "it's"], { s: 'x"y' });
