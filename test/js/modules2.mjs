// export * as ns from: namespaces re-exported under a name, and live through it.
import { maths, aValue } from './mod/nsreexport.mjs';
import * as whole from './mod/nsreexport.mjs';
console.log(typeof maths, Object.keys(maths).sort().join());
console.log(maths.counter, maths.bump(), maths.counter, maths.revealed, maths.default({ x: 1, y: 2 }, 2).len().toFixed(3));
console.log(whole.maths === maths, Object.keys(whole).sort().join(), whole['string name'] === maths, aValue);
