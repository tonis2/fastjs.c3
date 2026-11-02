// Labelled statements: break and continue to an outer loop, breaking out of a labelled block,
// and closing the iterators of the loops a labelled jump leaves.
const log = (...a) => console.log(...a);

outer: for (let i = 0; i < 3; i++) {
  for (let j = 0; j < 3; j++) {
    if (j === 1) continue outer;
    if (i === 2) break outer;
    log("for", i, j);
  }
}

let k = 0;
loop: while (true) {
  k++;
  switch (k) {
    case 1: continue loop;
    case 3: break loop;
  }
  log("while", k);
}

block: {
  log("in block");
  if (k === 3) break block;
  log("not reached");
}

a: b: for (const x of [1, 2, 3]) {
  if (x === 2) continue a;
  if (x === 3) break b;
  log("two labels", x);
}

// Inner iterators are closed when a labelled jump leaves their loop.
function iter(name) {
  let i = 0;
  return {
    [Symbol.iterator]() { return this; },
    next() { i++; return { value: i, done: i > 3 }; },
    return() { log(name, "closed"); return { done: true }; },
  };
}
rows: for (const r of iter("rows")) {
  for (const c of iter("cols")) {
    if (c === 2) continue rows;
    log("cell", r, c);
  }
}
done: for (const r of iter("r2")) {
  for (const c of iter("c2")) {
    for (const d of iter("d2")) break done;
  }
}

function* gen(name) {
  try { yield 1; yield 2; yield 3; } finally { log(name, "finally"); }
}
g: for (const x of gen("outer-gen")) {
  for (const y of gen("inner-gen")) {
    if (y === 2) break g;
    log("gen", x, y);
  }
}

// Through try/finally.
fin: for (let i = 0; i < 2; i++) {
  try {
    for (const x of iter("in-try")) {
      try { if (x === 2) continue fin; } finally { log("inner finally", i, x); }
    }
  } finally { log("outer finally", i); }
}

// Labelled if, try and nested blocks.
lbl: if (true) { log("if"); break lbl; }
t: try { log("try"); break t; } finally { log("finally after break t"); }
x: { y: { break x; } log("skipped"); }
log("after x");

// In a function and an arrow, and labels reused in sibling statements.
function find(grid, v) {
  let at = null;
  search: for (let i = 0; i < grid.length; i++) {
    for (let j = 0; j < grid[i].length; j++) {
      if (grid[i][j] === v) { at = [i, j]; break search; }
    }
  }
  return at;
}
log(find([[1, 2], [3, 4]], 3));
search: for (;;) break search;
const f = () => { l: for (;;) { break l; } return "arrow"; };
log(f());

// for await with a labelled jump closes (and awaits) the inner async iterator.
function aiter(name) {
  let i = 0;
  return {
    [Symbol.asyncIterator]() { return this; },
    next() { i++; return Promise.resolve({ value: i, done: i > 3 }); },
    return() { log(name, "return"); return Promise.resolve().then(() => { log(name, "settled"); return { done: true }; }); },
  };
}
(async () => {
  out: for await (const a of aiter("A")) {
    for await (const b of aiter("B")) {
      if (b === 2) continue out;
      log("async", a, b);
    }
  }
  log("async done");
})();
