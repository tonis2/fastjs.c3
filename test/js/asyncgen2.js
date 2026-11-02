// for await closing its iterator (awaiting return()), yield* in async generators, and the
// awaited return values of async generators.
const log = (...a) => console.log(...a);

// An async iterable whose return() is slow: break must wait for it.
function slowIter(name, n) {
  let i = 0;
  return {
    [Symbol.asyncIterator]() { return this; },
    next() { i++; return Promise.resolve({ value: name + i, done: i > n }); },
    return(v) {
      log(name, "return called");
      return Promise.resolve().then(() => 0).then(() => 0).then(() => { log(name, "return settled"); return { done: true, value: v }; });
    },
  };
}

async function breakWaits() {
  for await (const x of slowIter("a", 5)) { log("got", x); if (x === "a2") break; }
  log("after break");
}

async function returnWaits() {
  for await (const x of slowIter("b", 5)) { log("got", x); return "ret"; }
}

async function throwWaits() {
  try {
    for await (const x of slowIter("c", 5)) { log("got", x); throw new Error("boom"); }
  } catch (e) { log("caught", e.message); }
}

async function badReturn() {
  const it = { [Symbol.asyncIterator]() { return this; }, next() { return Promise.resolve({ value: 1, done: false }); }, return() { return Promise.resolve(42); } };
  try { for await (const x of it) break; } catch (e) { log("bad return:", e.constructor.name, e.message); }
  // On a throw, the body's exception wins over a bad return().
  try { for await (const x of it) throw new Error("body"); } catch (e) { log("throw wins:", e.message); }
  const rejecting = { [Symbol.asyncIterator]() { return this; }, next() { return Promise.resolve({ value: 1, done: false }); }, return() { return Promise.reject(new Error("rejected return")); } };
  try { for await (const x of rejecting) break; } catch (e) { log("rejected:", e.message); }
  try { for await (const x of rejecting) throw new Error("body2"); } catch (e) { log("throw wins 2:", e.message); }
}


async function syncIterable() {
  const src = { [Symbol.iterator]() { let i = 0; return { next() { return { value: Promise.resolve(++i), done: false }; }, return() { log("sync return"); return { done: true }; } }; } };
  for await (const v of src) { log("sync", v); if (v === 2) break; }
}

// yield* in async generators.
async function* inner() {
  try {
    const a = yield 1;
    log("inner got", a);
    yield Promise.resolve(2);
    return "inner-done";
  } finally { log("inner finally"); }
}
async function* outer() {
  const r = yield* inner();
  log("yield* result", r);
  yield* [10, Promise.resolve(20)];
  yield* slowIter("s", 2);
  return "outer-done";
}

async function delegation() {
  const g = outer();
  log(JSON.stringify(await g.next("ignored")));
  log(JSON.stringify(await g.next("A")));
  for (let i = 0; i < 6; i++) log(JSON.stringify(await g.next()));
}

async function delegateReturn() {
  const g = outer();
  await g.next();
  log(JSON.stringify(await g.return(Promise.resolve("early"))));
  log(JSON.stringify(await g.next()));
}

async function delegateThrow() {
  async function* catching() { try { yield 1; } catch (e) { log("inner caught", e); yield 2; } }
  async function* o() { const r = yield* catching(); log("r", r); }
  const g = o();
  log(JSON.stringify(await g.next()));
  log(JSON.stringify(await g.throw("T")));
  log(JSON.stringify(await g.next()));
  const noThrow = { [Symbol.asyncIterator]() { return this; }, next() { return Promise.resolve({ value: 1, done: false }); }, return() { log("closed for missing throw"); return Promise.resolve({ done: true }); } };
  async function* o2() { yield* noThrow; }
  const g2 = o2();
  await g2.next();
  try { await g2.throw("x"); } catch (e) { log("no throw:", e.constructor.name, e.message); }
}

async function returnAwaits() {
  async function* g() { return Promise.resolve(7); }
  log(JSON.stringify(await g().next()));
  async function* h() { try { yield 1; } finally { log("h finally"); } }
  const it = h();
  await it.next();
  log(JSON.stringify(await it.return(Promise.resolve(8))));
  log(JSON.stringify(await h().return(Promise.resolve(9))));
}

(async () => {
  await breakWaits();
  log(await returnWaits());
  await throwWaits();
  await badReturn();
  await syncIterable();
  await delegation();
  await delegateReturn();
  await delegateThrow();
  await returnAwaits();
})();
