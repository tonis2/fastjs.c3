// import() from a script, not a module: the same loader, relative to the script.
import('./mod/dyn/sub/leaf.mjs').then((m) => console.log('script import:', m.leaf));
const later = () => import('./mod/dyn/sub/leaf.mjs');
later().then((m) => console.log('from a function:', m.leaf));
