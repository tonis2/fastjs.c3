import scale, { PI2, counter, bump, Vec, revealed } from './mod/math.mjs';
import * as math from './mod/math.mjs';
import { increment, own, aValue, fromA } from './mod/reexport.mjs';
import { late } from './mod/tla.mjs';
import obj from './mod/default_expr.mjs';
import './mod/math.mjs';

console.log(PI2.toFixed(4), revealed, scale(new Vec(3, 4), 2).len());
console.log('live binding', counter, bump(), counter, increment(), counter, math.counter);
console.log(Object.keys(math).sort(), typeof math.default, math.Vec === Vec);
console.log(own, aValue, fromA(), late, obj);
try { counter = 5; } catch (e) { console.log(e.constructor.name, e.message); }
console.log(typeof this);
const later = async () => { await null; return 'after await'; };
console.log(await later());
