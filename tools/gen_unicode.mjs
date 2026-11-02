// Generates src/rt/unicode_data.c3 from node's own Unicode data (its ICU), so fastjs's case
// mapping and regex \p{...} agree with V8's. Run: node tools/gen_unicode.mjs > src/rt/unicode_data.c3
const MAX = 0x10FFFF;
const hex = n => '0x' + n.toString(16).toUpperCase();

// ---- case mapping: runs of code points whose simple mapping adds the same delta ----
function caseRuns(map) {
	const runs = [];
	let cur = null;
	for (let cp = 0; cp <= MAX; cp++) {
		if (cp >= 0xD800 && cp <= 0xDFFF) continue;
		const s = String.fromCodePoint(cp);
		const m = map(s);
		const mc = m.codePointAt(0);
		if (m.length !== (mc > 0xFFFF ? 2 : 1) || mc === cp) continue; // unchanged, or several characters
		const delta = mc - cp;
		// Extend the current run with stride 1 (cp right after) or 2 (alternating pairs).
		if (cur && cur.delta === delta) {
			if (cur.stride === 0 && (cp === cur.hi + 1 || cp === cur.hi + 2)) { cur.stride = cp - cur.hi; cur.hi = cp; continue; }
			if (cur.stride && cp === cur.hi + cur.stride) { cur.hi = cp; continue; }
		}
		cur = { lo: cp, hi: cp, delta, stride: 0 };
		runs.push(cur);
	}
	return runs.map(r => `{ ${hex(r.lo)}, ${hex(r.hi)}, ${r.delta}, ${r.stride || 1} }`);
}

// Mappings to more than one character (full case mapping, SpecialCasing.txt).
function specials(map) {
	const out = [];
	for (let cp = 0; cp <= MAX; cp++) {
		if (cp >= 0xD800 && cp <= 0xDFFF) continue;
		const s = String.fromCodePoint(cp);
		const m = map(s);
		if ([...m].length > 1) out.push(`{ ${hex(cp)}, "${[...m].map(c => { const v = c.codePointAt(0); return v > 0xFFFF ? '\\U' + v.toString(16).padStart(8, '0') : '\\u' + v.toString(16).padStart(4, '0'); }).join('')}" }`);
	}
	return out;
}

// ---- properties: ranges of code points, found by matching runs over a string of all of them ----
let all = '';
for (let cp = 0; cp <= MAX; cp++) if (cp < 0xD800 || cp > 0xDFFF) all += String.fromCodePoint(cp);
const cpAt = i => (i < 0xD800 ? i : i < 0xF800 ? i + 0x800 : (i - 0xF800) / 2 + 0x10000);
function ranges(prop) {
	const re = new RegExp(`\\p{${prop}}+`, 'gu');
	const out = [];
	for (const m of all.matchAll(re)) {
		const lo = cpAt(m.index);
		const hi = cpAt(m.index + m[0].length) - 1;
		out.push([lo, hi]);
	}
	// Lone surrogates aren't in the string: they are exactly Cs.
	if (new RegExp(`^\\p{${prop}}$`, 'u').test('\uD800')) {
		out.push([0xD800, 0xDFFF]);
		out.sort((a, b) => a[0] - b[0]);
		for (let i = out.length - 1; i > 0; i--) {
			if (out[i - 1][1] + 1 >= out[i][0]) { out[i - 1][1] = Math.max(out[i - 1][1], out[i][1]); out.splice(i, 1); }
		}
	}
	return out;
}
const valid = p => { try { new RegExp(`\\p{${p}}`, 'u'); return true; } catch { return false; } };
const same = (a, b) => { const x = ranges(a), y = ranges(b); return JSON.stringify(x) === JSON.stringify(y); };

const categories = [
	['L', 'Letter'], ['LC', 'Cased_Letter'], ['Lu', 'Uppercase_Letter'], ['Ll', 'Lowercase_Letter'], ['Lt', 'Titlecase_Letter'],
	['Lm', 'Modifier_Letter'], ['Lo', 'Other_Letter'], ['M', 'Mark'], ['Mn', 'Nonspacing_Mark'], ['Mc', 'Spacing_Mark'],
	['Me', 'Enclosing_Mark'], ['N', 'Number'], ['Nd', 'Decimal_Number'], ['Nl', 'Letter_Number'], ['No', 'Other_Number'],
	['P', 'Punctuation'], ['Pc', 'Connector_Punctuation'], ['Pd', 'Dash_Punctuation'], ['Ps', 'Open_Punctuation'],
	['Pe', 'Close_Punctuation'], ['Pi', 'Initial_Punctuation'], ['Pf', 'Final_Punctuation'], ['Po', 'Other_Punctuation'],
	['S', 'Symbol'], ['Sm', 'Math_Symbol'], ['Sc', 'Currency_Symbol'], ['Sk', 'Modifier_Symbol'], ['So', 'Other_Symbol'],
	['Z', 'Separator'], ['Zs', 'Space_Separator'], ['Zl', 'Line_Separator'], ['Zp', 'Paragraph_Separator'],
	['C', 'Other'], ['Cc', 'Control'], ['Cf', 'Format'], ['Cs', 'Surrogate'], ['Co', 'Private_Use'], ['Cn', 'Unassigned'],
];
const binaries = [
	['ASCII'], ['ASCII_Hex_Digit', 'AHex'], ['Alphabetic', 'Alpha'], ['Any'], ['Assigned'], ['Bidi_Control', 'Bidi_C'],
	['Bidi_Mirrored', 'Bidi_M'], ['Case_Ignorable', 'CI'], ['Cased'], ['Changes_When_Casefolded', 'CWCF'],
	['Changes_When_Casemapped', 'CWCM'], ['Changes_When_Lowercased', 'CWL'], ['Changes_When_Titlecased', 'CWT'],
	['Changes_When_Uppercased', 'CWU'], ['Dash'], ['Default_Ignorable_Code_Point', 'DI'], ['Deprecated', 'Dep'],
	['Diacritic', 'Dia'], ['Emoji'], ['Emoji_Component', 'EComp'], ['Emoji_Modifier', 'EMod'], ['Emoji_Modifier_Base', 'EBase'],
	['Emoji_Presentation', 'EPres'], ['Extended_Pictographic', 'ExtPict'], ['Extender', 'Ext'], ['Grapheme_Base', 'Gr_Base'],
	['Grapheme_Extend', 'Gr_Ext'], ['Hex_Digit', 'Hex'], ['IDS_Binary_Operator', 'IDSB'], ['IDS_Trinary_Operator', 'IDST'],
	['ID_Continue', 'IDC'], ['ID_Start', 'IDS'], ['Ideographic', 'Ideo'], ['Join_Control', 'Join_C'],
	['Logical_Order_Exception', 'LOE'], ['Lowercase', 'Lower'], ['Math'], ['Noncharacter_Code_Point', 'NChar'],
	['Pattern_Syntax', 'Pat_Syn'], ['Pattern_White_Space', 'Pat_WS'], ['Quotation_Mark', 'QMark'], ['Radical'],
	['Regional_Indicator', 'RI'], ['Sentence_Terminal', 'STerm'], ['Soft_Dotted', 'SD'], ['Terminal_Punctuation', 'Term'],
	['Unified_Ideograph', 'UIdeo'], ['Uppercase', 'Upper'], ['Variation_Selector', 'VS'], ['White_Space', 'space'],
	['XID_Continue', 'XIDC'], ['XID_Start', 'XIDS'],
];
const scripts = [
	['Adlam', 'Adlm'], ['Ahom'], ['Anatolian_Hieroglyphs', 'Hluw'], ['Arabic', 'Arab'], ['Armenian', 'Armn'], ['Avestan', 'Avst'],
	['Balinese', 'Bali'], ['Bamum', 'Bamu'], ['Bassa_Vah', 'Bass'], ['Batak', 'Batk'], ['Bengali', 'Beng'], ['Bhaiksuki', 'Bhks'],
	['Bopomofo', 'Bopo'], ['Brahmi', 'Brah'], ['Braille', 'Brai'], ['Buginese', 'Bugi'], ['Buhid', 'Buhd'],
	['Canadian_Aboriginal', 'Cans'], ['Carian', 'Cari'], ['Caucasian_Albanian', 'Aghb'], ['Chakma', 'Cakm'], ['Cham'],
	['Cherokee', 'Cher'], ['Chorasmian', 'Chrs'], ['Common', 'Zyyy'], ['Coptic', 'Copt'], ['Cuneiform', 'Xsux'],
	['Cypriot', 'Cprt'], ['Cypro_Minoan', 'Cpmn'], ['Cyrillic', 'Cyrl'], ['Deseret', 'Dsrt'], ['Devanagari', 'Deva'],
	['Dives_Akuru', 'Diak'], ['Dogra', 'Dogr'], ['Duployan', 'Dupl'], ['Egyptian_Hieroglyphs', 'Egyp'], ['Elbasan', 'Elba'],
	['Elymaic', 'Elym'], ['Ethiopic', 'Ethi'], ['Georgian', 'Geor'], ['Glagolitic', 'Glag'], ['Gothic', 'Goth'],
	['Grantha', 'Gran'], ['Greek', 'Grek'], ['Gujarati', 'Gujr'], ['Gunjala_Gondi', 'Gong'], ['Gurmukhi', 'Guru'],
	['Han', 'Hani'], ['Hangul', 'Hang'], ['Hanifi_Rohingya', 'Rohg'], ['Hanunoo', 'Hano'], ['Hatran', 'Hatr'],
	['Hebrew', 'Hebr'], ['Hiragana', 'Hira'], ['Imperial_Aramaic', 'Armi'], ['Inherited', 'Zinh'],
	['Inscriptional_Pahlavi', 'Phli'], ['Inscriptional_Parthian', 'Prti'], ['Javanese', 'Java'], ['Kaithi', 'Kthi'],
	['Kannada', 'Knda'], ['Katakana', 'Kana'], ['Kawi'], ['Kayah_Li', 'Kali'], ['Kharoshthi', 'Khar'],
	['Khitan_Small_Script', 'Kits'], ['Khmer', 'Khmr'], ['Khojki', 'Khoj'], ['Khudawadi', 'Sind'], ['Lao', 'Laoo'],
	['Latin', 'Latn'], ['Lepcha', 'Lepc'], ['Limbu', 'Limb'], ['Linear_A', 'Lina'], ['Linear_B', 'Linb'], ['Lisu'],
	['Lycian', 'Lyci'], ['Lydian', 'Lydi'], ['Mahajani', 'Mahj'], ['Makasar', 'Maka'], ['Malayalam', 'Mlym'],
	['Mandaic', 'Mand'], ['Manichaean', 'Mani'], ['Marchen', 'Marc'], ['Masaram_Gondi', 'Gonm'], ['Medefaidrin', 'Medf'],
	['Meetei_Mayek', 'Mtei'], ['Mende_Kikakui', 'Mend'], ['Meroitic_Cursive', 'Merc'], ['Meroitic_Hieroglyphs', 'Mero'],
	['Miao', 'Plrd'], ['Modi'], ['Mongolian', 'Mong'], ['Mro', 'Mroo'], ['Multani', 'Mult'], ['Myanmar', 'Mymr'],
	['Nabataean', 'Nbat'], ['Nag_Mundari', 'Nagm'], ['Nandinagari', 'Nand'], ['New_Tai_Lue', 'Talu'], ['Newa'],
	['Nko', 'Nkoo'], ['Nushu', 'Nshu'], ['Nyiakeng_Puachue_Hmong', 'Hmnp'], ['Ogham', 'Ogam'], ['Ol_Chiki', 'Olck'],
	['Old_Hungarian', 'Hung'], ['Old_Italic', 'Ital'], ['Old_North_Arabian', 'Narb'], ['Old_Permic', 'Perm'],
	['Old_Persian', 'Xpeo'], ['Old_Sogdian', 'Sogo'], ['Old_South_Arabian', 'Sarb'], ['Old_Turkic', 'Orkh'],
	['Old_Uyghur', 'Ougr'], ['Oriya', 'Orya'], ['Osage', 'Osge'], ['Osmanya', 'Osma'], ['Pahawh_Hmong', 'Hmng'],
	['Palmyrene', 'Palm'], ['Pau_Cin_Hau', 'Pauc'], ['Phags_Pa', 'Phag'], ['Phoenician', 'Phnx'], ['Psalter_Pahlavi', 'Phlp'],
	['Rejang', 'Rjng'], ['Runic', 'Runr'], ['Samaritan', 'Samr'], ['Saurashtra', 'Saur'], ['Sharada', 'Shrd'],
	['Shavian', 'Shaw'], ['Siddham', 'Sidd'], ['SignWriting', 'Sgnw'], ['Sinhala', 'Sinh'], ['Sogdian', 'Sogd'],
	['Sora_Sompeng', 'Sora'], ['Soyombo', 'Soyo'], ['Sundanese', 'Sund'], ['Syloti_Nagri', 'Sylo'], ['Syriac', 'Syrc'],
	['Tagalog', 'Tglg'], ['Tagbanwa', 'Tagb'], ['Tai_Le', 'Tale'], ['Tai_Tham', 'Lana'], ['Tai_Viet', 'Tavt'],
	['Takri', 'Takr'], ['Tamil', 'Taml'], ['Tangsa', 'Tnsa'], ['Tangut', 'Tang'], ['Telugu', 'Telu'], ['Thaana', 'Thaa'],
	['Thai'], ['Tibetan', 'Tibt'], ['Tifinagh', 'Tfng'], ['Tirhuta', 'Tirh'], ['Toto'], ['Ugaritic', 'Ugar'],
	['Vai', 'Vaii'], ['Vithkuqi', 'Vith'], ['Wancho', 'Wcho'], ['Warang_Citi', 'Wara'], ['Yezidi', 'Yezi'], ['Yi', 'Yiii'],
	['Zanabazar_Square', 'Zanb'],
	['Garay', 'Gara'], ['Gurung_Khema', 'Gukh'], ['Kirat_Rai', 'Krai'], ['Ol_Onal', 'Onao'], ['Sunuwar', 'Sunu'], ['Todhri', 'Todr'], ['Tulu_Tigalari', 'Tutg'],
];

const flat = [];
const props = [];
const aliases = [];
function add(key, query) {
	const rs = ranges(query);
	props.push(`{ "${key}", ${flat.length / 2}, ${rs.length} }`);
	for (const [lo, hi] of rs) flat.push(hex(lo), hex(hi));
}
for (const [short, long] of categories) {
	if (!valid(short)) continue;
	add('gc=' + short, short);
	aliases.push(`{ "${short}", "gc=${short}" }`, `{ "${long}", "gc=${short}" }`);
}
for (const [name, alias] of binaries) {
	if (!valid(name)) continue;
	add(name, name);
	if (alias && valid(alias)) aliases.push(`{ "${alias}", "${name}" }`);
}
for (const [name, code] of scripts) {
	if (!valid('Script=' + name)) continue;
	add('sc=' + name, 'Script=' + name);
	add('scx=' + name, 'Script_Extensions=' + name);
	if (code && valid('Script=' + code)) aliases.push(`{ "${code}", "${name}" }`);
}

const lines = [];
const out = s => lines.push(s);
out('// Generated by tools/gen_unicode.mjs from node ' + process.version + ' (Unicode ' + process.versions.unicode + '). Do not edit.');
out('module fastjs::rt;');
out('');
out(`const String UNICODE_VERSION = "${process.versions.unicode}";`);
out('');
out('// Simple case mappings: code points lo..hi, every stride-th one, map to themselves plus delta.');
out('struct CaseRun\n{\n\tuint lo;\n\tuint hi;\n\tint delta;\n\tuint stride;\n}');
out('');
out('// Mappings to more than one character (full case mapping).');
out('struct SpecialCase\n{\n\tuint cp;\n\tString to;\n}');
out('');
out('// A \\p{...} property: its ranges, pairs in PROPERTY_RANGES from start.');
out('struct UniProperty\n{\n\tString name;\n\tuint start;\n\tuint count;\n}');
out('');
out('struct UniAlias\n{\n\tString name;\n\tString target;\n}');
out('');
const arr = (decl, items, per) => {
	out(decl + ' = {');
	for (let i = 0; i < items.length; i += per) out('\t' + items.slice(i, i + per).join(', ') + ',');
	out('};');
	out('');
};
arr('const CaseRun[*] UPPER_RUNS', caseRuns(s => s.toUpperCase()), 4);
arr('const CaseRun[*] LOWER_RUNS', caseRuns(s => s.toLowerCase()), 4);
arr('const SpecialCase[*] UPPER_SPECIAL', specials(s => s.toUpperCase()), 4);
arr('const SpecialCase[*] LOWER_SPECIAL', specials(s => s.toLowerCase()), 4);
arr('const uint[*] PROPERTY_RANGES', flat, 16);
arr('const UniProperty[*] PROPERTIES', props, 4);
// Long names for General_Category values, short ones for scripts and binary properties.
arr('const UniAlias[*] PROPERTY_ALIASES', aliases, 4);
process.stdout.write(lines.join('\n'));
