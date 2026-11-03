// Bindings imported and then exported in a separate statement: indirect exports, as
// `export { x } from` is, so a module importing them links before this one does.
import scale, { counter, bump, Vec } from './math.mjs';
import * as maths from './math.mjs';
export { counter, bump as increment, Vec, scale, maths };
