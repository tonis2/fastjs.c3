// Tagged templates and String.raw.
function tag(strings, ...values) { return JSON.stringify({ strings, raw: strings.raw, values, frozen: Object.isFrozen(strings) && Object.isFrozen(strings.raw) }); }
console.log(tag`a${1}b${'x'}c`);
console.log(tag`\n${2}\t`, tag``, tag`${3}`);
console.log(String.raw`a\nb${1 + 1}A`, String.raw({ raw: ['x', 'y', 'z'] }, 1, 2, 3, 4));
console.log(tag`bad \unicode and \xZZ ${0} fine \x41`);
const sites = []; function keep(s) { sites.push(s); return s; }
for (let i = 0; i < 2; i++) keep`same site`;
console.log(sites[0] === sites[1], keep`other` === sites[0]);
const obj = { name: 'o', m(s, v) { return this.name + s.join('|') + v; } };
console.log(obj.m`x${5}y`, obj['m']`p${6}q`);
const html = (s, ...v) => s.reduce((acc, str, i) => acc + str + (i < v.length ? `[${v[i]}]` : ''), '');
console.log(html`<a href="${'u'}">${'t'}</a>`);
console.log(tag`line1
line2`);
