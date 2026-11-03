// import then export: the re-exported bindings resolve, keep their names or take new ones,
// stay live, and a namespace re-exported this way is the module's own.
import { counter, increment, Vec, scale, maths } from './mod/import_export.mjs';
import * as direct from './mod/math.mjs';
console.log(counter, increment(), counter, maths.counter);
console.log(new Vec(3, 4).len(), scale({ x: 1, y: 0 }, 3).len(), maths === direct);
