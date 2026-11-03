// import(): a promise for the namespace, one instance per module, relative to the importer,
// and failures (missing, syntax, a throwing body, a bad link or dependency) as rejections.
import { runs } from './mod/dyn/plain.mjs';
const p = import('./mod/dyn/plain.mjs');
console.log('promise?', p instanceof Promise);
const a = await p;
const b = await import('./mod/dyn/' + 'plain' + '.mjs');
console.log(a === b, a.f(), a.default, runs, a.runs, Object.keys(a).sort().join());
const rel = await import('./mod/dyn/sub/rel.mjs');
console.log(await rel.sibling(), await rel.up());
console.log((await import('./mod/dyn/tla.mjs')).ready);
function plainFn() { return import('./mod/dyn/sub/leaf.mjs').then((m) => m.leaf); }
console.log('from a plain function:', await plainFn());
import('./mod/dyn/side.mjs');
await null; await null; await null;
const why = async (spec) => { try { await import(spec); return 'resolved'; } catch (e) { return e.constructor.name + (e.message === 'body threw' ? ': body threw' : ''); } };
console.log('missing:', (await why('./mod/dyn/nope.mjs')) !== 'resolved');
console.log('missing again:', (await why('./mod/dyn/nope.mjs')) !== 'resolved');
console.log('syntax:', await why('./mod/dyn/syntax.mjs'));
console.log('throws:', await why('./mod/dyn/throws.mjs'));
console.log('throws again:', await why('./mod/dyn/throws.mjs'));
console.log('missing export:', await why('./mod/dyn/badlink.mjs'));
console.log('missing dependency:', (await why('./mod/dyn/baddep.mjs')) !== 'resolved');
console.log('still fine after:', (await import('./mod/dyn/sub/leaf.mjs')).leaf);
const self = await import('./mod/dyn/self.mjs');
console.log('self:', await self.again);
console.log('to string:', (await import({ toString() { return './mod/dyn/sub/leaf.mjs'; } })).leaf);
