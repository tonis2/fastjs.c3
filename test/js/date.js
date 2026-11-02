// Date: construction, fields, setters, formats and parsing (run.sh pins TZ=Europe/Tallinn).
const d = new Date(Date.UTC(2020, 0, 2, 3, 4, 5, 678));
console.log(d.getTime(), d.toISOString(), JSON.stringify({ d }), d.valueOf() === +d);
console.log(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCDay(), d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds());
console.log(d.getFullYear(), d.getMonth(), d.getDate(), d.getDay(), d.getHours(), d.getMinutes(), d.getTimezoneOffset());
console.log(d.toString()); console.log(d.toDateString(), '|', d.toTimeString()); console.log(d.toUTCString());
console.log(d.toLocaleString(), '|', d.toLocaleDateString(), '|', d.toLocaleTimeString());
const local = new Date(2021, 5, 15, 13, 30); console.log(local.getHours(), local.getDate(), local.toISOString());
console.log(new Date(2020, 0, 31).getDate(), new Date(2020, 1, 30).getMonth(), new Date(99, 0).getFullYear(), new Date(2020, 12, 1).getFullYear());
console.log(String(new Date(NaN)), new Date('nonsense').getTime(), JSON.stringify(new Date(NaN)));
try { new Date(NaN).toISOString(); } catch (e) { console.log(e.constructor.name, e.message); }
for (const s of ['2020-01-02', '2020-01-02T03:04:05Z', '2020-01-02T03:04:05.6+02:00', '2020-01', '2020', '+010000-01-01T00:00:00Z', '2020-01-02T03:04', 'Thu, 02 Jan 2020 03:04:05 GMT', 'Jan 2, 2020 10:00 GMT', 'January 2 2020', '1/2/2020', '2020/01/02', 'Thu Jan 02 2020 03:04:05 GMT+0000 (Coordinated Universal Time)', 'Jan 2 2020 10:00 PM GMT+0130'])
	console.log(s, '->', Date.parse(s));
const m = new Date(Date.UTC(2020, 0, 31));
m.setUTCMonth(1); console.log(m.toISOString());
m.setUTCHours(25, 61, 61, 1001); console.log(m.toISOString());
m.setUTCFullYear(2024, 1, 29); console.log(m.toISOString(), m.setUTCDate(0), m.toISOString());
m.setTime(0); m.setMinutes(90); console.log(m.toISOString(), m.setMilliseconds(-1));
const inv = new Date(NaN); console.log(inv.setDate(1), inv.setFullYear(2000), new Date(inv).getUTCFullYear());
console.log(new Date(8.64e15 + 1).getTime(), new Date(-8.64e15).toISOString(), new Date(0) - new Date(1000), typeof (new Date(0) + 1), new Date(5) < new Date(6));
console.log(typeof Date(), Date.length, Date.UTC(2020), Date.UTC(), Object.prototype.toString.call(new Date(0)).length > 0);
console.log([new Date(0)], { at: new Date(86400000) });
console.log(new Date(new Date(77)).getTime(), new Date('2020-06-01').getUTCHours(), new Date(true).getTime());
