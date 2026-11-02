// Function calls and recursion.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
function bench() { return fib(30); }
const result = bench();
typeof console !== "undefined" ? console.log(result) : result;
