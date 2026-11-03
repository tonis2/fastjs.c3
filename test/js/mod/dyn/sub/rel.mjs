// A relative import() from inside a subfolder resolves against this module.
export async function sibling() { return (await import('./leaf.mjs')).leaf; }
export async function up() { return (await import('../plain.mjs')).f(); }
