// JSON.parse with a reviver.
const text = '{"a":1,"b":[1,2,{"c":3}],"d":{"e":"x","f":null},"date":"2020-01-01"}';
const seen = [];
const r = JSON.parse(text, function (k, v) { seen.push(k + ':' + (typeof v) + ':' + (this && Object.keys(this).length)); if (k === 'e') return undefined; if (typeof v === 'number') return v * 10; return v; });
console.log(JSON.stringify(r)); console.log(seen.join(' '));
console.log(JSON.parse('[1,2,3]', (k, v) => k === '1' ? undefined : v), JSON.parse('5', (k, v) => [k, v]));
console.log(JSON.parse('{"x":1}', null), JSON.parse('{"x":1}', 5));
