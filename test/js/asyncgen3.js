// More async generator delegation and closing: nesting, queued requests, return() at the start.
const log = (...a) => console.log(...a);
function src(name, n) {
  let i = 0;
  return {
    [Symbol.asyncIterator]() { return this; },
    next() { i++; return Promise.resolve({ value: i > n ? undefined : Promise.resolve(name + i), done: i > n }); },
    return() { log(name, "return"); return Promise.resolve().then(() => { log(name, "return settled"); return { done: true }; }); },
  };
}
async function* gen() {
  try {
    for await (const p of src("g", 5)) { log("value is promise:", p instanceof Promise); yield await p; }
  } finally { log("gen finally"); }
}
async function* passThrough() { yield* src("pt", 2); }
async function* localReturn() {
  let x = Promise.resolve(3);
  try { return x; } finally { log("finally sees promise:", x instanceof Promise); }
}
async function* throwsInside() { yield 1; throw new Error("inner boom"); }
async function* delegatesThrow() { try { yield* throwsInside(); } catch (e) { log("outer caught", e.message); yield "recovered"; } }
async function* nested() {
  for await (const a of src("n1", 2)) {
    for await (const b of src("n2", 2)) { yield [await a, await b]; return "nested-ret"; }
  }
}
(async () => {
  const g = gen();
  log(JSON.stringify(await g.next()));
  log(JSON.stringify(await g.return("stop")));
  for await (const v of passThrough()) log("pt value is promise:", v instanceof Promise, await v);
  log(JSON.stringify(await localReturn().next()));
  for await (const v of delegatesThrow()) log("dt", v);
  for await (const v of nested()) log("nested", v);
  const n = nested(); await n.next(); log(JSON.stringify(await n.next()));
  // Concurrent next() calls on a delegating generator queue up.
  const p = passThrough();
  const rs = await Promise.all([p.next(), p.next(), p.next()]);
  log(rs.map(r => r.done));
  // return() on a never-started generator awaits a rejected value.
  try { await gen().return(Promise.reject(new Error("rej"))); } catch (e) { log("rejected return:", e.message); }
})();
