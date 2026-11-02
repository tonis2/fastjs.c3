// When for-of closes its iterator (calls return()), and which exception wins.
function iter(name, opts = {}) {
	let i = 0;
	return {
		[Symbol.iterator]() { return this; },
		next() { if (opts.nextThrows && i === 1) throw new Error(name + ' next'); return { value: i++, done: i > 3 }; },
		return() { console.log(name, 'return called'); if (opts.returnThrows) throw new Error(name + ' return'); return {}; },
	};
}
// Body throws: closed, and the body's error wins over return()'s.
try { for (const v of iter('a')) throw new Error('body a'); } catch (e) { console.log(e.message); }
try { for (const v of iter('b', { returnThrows: true })) throw new Error('body b'); } catch (e) { console.log(e.message); }
// next() throws: not closed.
try { for (const v of iter('c', { nextThrows: true })) {} } catch (e) { console.log(e.message); }
// Destructuring the value throws: closed.
try { for (const [x] of iter('d')) {} } catch (e) { console.log(e.constructor.name); }
// return statement, with return() throwing: that error propagates, once.
function f() { for (const v of iter('e', { returnThrows: true })) return v; }
try { f(); } catch (e) { console.log(e.message); }
// break, and running out: closed once / not at all.
for (const v of iter('f')) break;
for (const v of iter('g')) {}
console.log('ran out quietly');
// A try/catch inside the body handles its own throw; the loop goes on.
let n = 0; for (const v of iter('h')) { try { throw 1; } catch { n++; } } console.log('inner', n);
// Nested loops: the inner closes, then the outer.
try { for (const a of iter('outer')) for (const b of iter('inner')) throw new Error('deep'); } catch (e) { console.log(e.message); }
// Arrays and strings have nothing to close.
try { for (const v of [1, 2]) throw new Error('array'); } catch (e) { console.log(e.message); }
