export const me = 'self';
export const again = import('./self.mjs').then((ns) => ns.me);
