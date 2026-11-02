// Unicode: full case mapping over every code point (hashed per block), and /u regexes with \p{...}.
function hash(s) { let h = 0; for (let i = 0; i < s.length; i++) h = (Math.imul(h, 31) + s.charCodeAt(i)) | 0; return h; }
const out = [];
for (let block = 0; block < 0x110000; block += 4096 * 5) {
	let s = '';
	for (let cp = block; cp < block + 4096; cp++) { if (cp >= 0xD800 && cp <= 0xDFFF) continue; s += String.fromCodePoint(cp) + ' '; }
	out.push(block.toString(16) + ':' + hash(s.toUpperCase()) + ',' + hash(s.toLowerCase()));
}
console.log(out.join(' '));
console.log('straße'.toUpperCase(), 'ǅ'.toLowerCase(), 'ǅ'.toUpperCase(), 'İstanbul'.toLowerCase().length, 'ΟΔΥΣΣΕΥΣ'.toLowerCase(), 'Σ'.toLowerCase(), 'ΑΣ.'.toLowerCase(), 'ﬀ'.toUpperCase(), '𐐨'.toUpperCase(), 'ÀÉÎ'.toLowerCase());
const s = 'aé€😀ΩЖ7١ ';
const show = re => { try { return JSON.stringify(s.match(re)); } catch (e) { return e.constructor.name; } };
for (const p of ['\\p{L}', '\\p{Lu}', '\\p{Letter}', '\\p{gc=Ll}', '\\p{General_Category=Lowercase_Letter}', '\\P{L}', '\\p{N}', '\\p{Nd}', '\\p{Script=Greek}', '\\p{sc=Cyrl}', '\\p{Script_Extensions=Latin}', '\\p{Emoji_Presentation}', '\\p{ExtPict}', '\\p{Alphabetic}', '\\p{White_Space}', '\\p{Sc}', '\\p{Any}', '[\\p{Lu}\\p{Nd}]', '[^\\p{L}]', '[\\P{L}a]', '\\p{Lowercase}', '\\p{ASCII}'])
	console.log(p, show(new RegExp(p, 'gu')));
console.log('😀'.match(/./u)[0].length, '😀'.match(/./)[0].length, /^.$/u.test('😀'), /^.$/.test('😀'), /^[😀]$/u.test('😀'), /\u{1F600}/u.test('😀'), /😀/u.test('😀'), /^\S$/u.test('😀'));
console.log('a😀b'.replace(/(?<=a)./u, 'X'), 'x😀😀y'.split(/(?:)/u).length, [...'a😀b'.matchAll(/./gu)].map(m => m.index).join());
console.log(/\p{L}/.test('p{L}'), /ä/iu.test('Ä'), /ǆ/iu.test('ǅ'), /[a-z]/iu.test('K'), /\u{10400}/iu.test('\u{10428}'));
try { new RegExp('\\p{NotAProperty}', 'u'); } catch (e) { console.log(e.constructor.name); }
console.log('ÉCOLE Ölçü'.toLowerCase(), 'hello world'.replace(/\p{Ll}+/gu, w => w.toUpperCase()));
