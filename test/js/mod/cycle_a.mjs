import { fromB } from './cycle_b.mjs';
export function fromA() { return 'A'; }
export const aValue = 'a-' + fromB();
console.log('cycle_a evaluated', aValue);
