import { fromA } from './cycle_a.mjs';
export function fromB() { return 'B'; }
// fromA is hoisted, so a cycle can call it before cycle_a's body runs.
console.log('cycle_b evaluated, calls', fromA());
