// Template literals (CONCATN) and strings sharing an append buffer.
const a = 1, b = 'two', c = { toString() { return 'C' } }, w = 'ψ';
console.log(`x${a}y${b}z${c}`, `${a}`, `${''}`, `${w}${a}`, `${a}${w}abc`);
let s = ''; for (let i = 0; i < 100; i++) s = `${s}${i % 10}`; console.log(s.length, s.slice(0, 12));
const many = `${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}${a}-${b}`;
console.log(many);
let t = 'ψ'; for (let i = 0; i < 70; i++) t += 'a'; t += 'ψ'; console.log(t.length, t.endsWith('aψ'));
let u = ''; for (let i = 0; i < 70; i++) u += 'b'; const u1 = u; u += 'X'; const u2 = u1 + 'Y'; console.log(u.slice(-2), u2.slice(-2), u1.length);
