export const PI2 = Math.PI * 2;
export let counter = 0;
export function bump() { return ++counter; }
export class Vec { constructor(x, y) { this.x = x; this.y = y; } len() { return Math.hypot(this.x, this.y); } }
const hidden = 'not exported';
export { hidden as revealed };
export default function scale(v, k) { return new Vec(v.x * k, v.y * k); }
console.log('math evaluated');
