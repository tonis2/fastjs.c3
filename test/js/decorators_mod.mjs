// Decorators in modules: `@d export class`, `export @d class` and `export default @d class`.
import Default, { Before, After, seen } from './mod/decorated.mjs';
console.log(seen.join(), Before.noted, After.noted, Default.noted, new Before() instanceof Before);
function stamp(cls) { cls.stamped = 'yes'; }
export @stamp class Local {}
console.log(Local.stamped);
