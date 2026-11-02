<*
 A ready-made module loader: `import` confined to one directory, plus an
 embedded namespace for modules built into the binary.

 `Engine.on_modules` is the raw surface — two callbacks and an opaque — and
 every consumer that wired it up wrote the same three things: a resolver that
 keeps specifiers inside one root, a reader that answers with a file's bytes,
 and somewhere for the entry module's own name to come from. This file is that
 code, written once. A host that wants different rules still has the hooks;
 a host that wants the ordinary rules declares a `ModuleLoader` and installs it.

 ## Specifiers are root-relative, and that is the containment

 What crosses the hooks is never a filesystem path — it is a path *within the
 loader's root*: `main.js`, `enemies/orc.js`. `resolve_module` produces them,
 and it is a pure function over two strings with no filesystem in it at all,
 which is what makes the containment testable without a directory to point at.

 Two consequences worth stating:

 - **`..` past the root is refused rather than clamped.** Clamping would make
   `../../etc/passwd` resolve to `etc/passwd` and then fail as *"could not
   load"*, which reads as a missing file and teaches a script author the wrong
   thing. Refusing says what happened.
 - **A leading `/` is rooted at the loader's root, not at the disk.** A script
   that writes `import '/lib/math.js'` means its own `lib/`, and that is the
   only root it has. This is also what makes the obvious attack boring:
   `/etc/passwd` resolves to `etc/passwd` under the root and simply is not
   there.

 **Containment is lexical, not `realpath`.** A symlink inside the root pointing
 outside it is followed. That is deliberate: the root is the script author's
 own, a symlink in it is something they put there, and resolving links would
 make a specifier's meaning depend on the filesystem in a way no error message
 could explain. The boundary this enforces is against a *script* reaching out,
 which is the one that can be written by accident.

 ## The embedded namespace

 A host may carry modules in the binary itself — an API prelude, a standard
 library — and hand them to the loader as a prefix and a table:

 	`loader.set_embedded("app:", parts);`

 A specifier carrying the prefix is answered from the table and never from
 disk, and the space is closed from the outside: only a module already inside
 it may import from it. Script code writing `import 'app:internals.js'` is
 refused exactly as `../` past the root is, because an embedded module is not
 API by virtue of existing, and a script that reached one would be a script
 that breaks on the next refactor of a file it cannot see.
*>
module fastjs::js;

import std::io;
import std::io::file;

excuse
	MODULE_SPECIFIER_IS_EMPTY,
	MODULE_ESCAPES_ROOT,
	MODULE_PATH_TOO_DEEP,
	MODULE_IS_NOT_A_FILE,
	MODULE_IS_TOO_LARGE;

<*
 Directory components a specifier may have.

 Sixty-four is far past anything a person nests and keeps `resolve_module` free
 of an allocation, which is what lets it run inside the engine's normalize
 callback without a pool open.
*>
const usz MAX_MODULE_PARTS = 64;

<*
 The most a single module may be.

 A `.js` file is text somebody typed; four megabytes of it is a mistake — a
 bundled library, or a binary renamed — and reading it into the host's heap
 would spend real memory before the parse starts.
*>
const usz MAX_MODULE_BYTES = 4 * 1024 * 1024;

<*
 Resolve `name`, as written in an import, against `base`, the module writing it.

 Both are root-relative and so is the answer: `resolve_module("enemies/orc.js",
 "../shared/hp.js")` is `shared/hp.js`.

 **No extension is guessed.** `import './player'` does not find `player.js`,
 exactly as it does not in a browser or in Node's ESM mode. Guessing would make
 a specifier's meaning depend on what happens to be on disk, and the habit does
 not survive contact with any other runtime.

 @param base : `The importer's own root-relative specifier. Its last component is a filename and is dropped.`
 @param name : `The specifier as written. A leading '/' roots it at the loader's root.`
 @return `Root-relative, '/'-separated, allocated in the caller's allocator.`
 @return? MODULE_SPECIFIER_IS_EMPTY : `An import of "".`
 @return? MODULE_ESCAPES_ROOT : `More '..' than there was path to climb.`
 @return? MODULE_PATH_TOO_DEEP : `More than MAX_MODULE_PARTS components.`
*>
fn String? resolve_module(String base, String name, Allocator allocator)
{
	if (name.len == 0) return MODULE_SPECIFIER_IS_EMPTY~;

	String[MAX_MODULE_PARTS] parts;
	usz count = 0;

	// The importer's directory, unless the specifier is rooted. `base`'s last
	// component is the importing file and is never part of what it resolves
	// against — "enemies/orc.js" imports relative to "enemies/".
	if (name[0] != '/')
	{
		usz cut = 0;
		bool has_dir = false;
		foreach (i, c : base)
		{
			if (c == '/') { cut = (usz)i; has_dir = true; }
		}
		if (has_dir) push_parts(base[:cut], &parts, &count)!;
	}

	push_parts(name, &parts, &count)!;
	if (count == 0) return MODULE_SPECIFIER_IS_EMPTY~;

	usz length = count - 1; // the separators
	for (usz i = 0; i < count; i++) length += parts[i].len;

	DString joined;
	joined.init(allocator, (sz)(length + 1));
	for (usz i = 0; i < count; i++)
	{
		if (i > 0) joined.append_char('/');
		joined.append_string(parts[i]);
	}
	return joined.copy_str(allocator);
}

<*
 Split `text` on '/' onto the stack, applying `.` and `..` as they arrive.

 Applied *during* the walk rather than after it, which is what makes an escape
 detectable: `a/../../b` has as many components as `a/b` by the time anyone
 counts, and only the order says one of them left the root.
*>
fn void? push_parts(String text, String[MAX_MODULE_PARTS]* parts, usz* count) @local
{
	usz start = 0;
	for (usz i = 0; i <= text.len; i++)
	{
		if (i < text.len && text[i] != '/') continue;

		String part = text[start:i - start];
		start = i + 1;

		// An empty component is a doubled or trailing slash. Harmless, and
		// dropping it silently is what every other resolver does.
		if (part.len == 0 || part == ".") continue;

		if (part == "..")
		{
			if (*count == 0) return MODULE_ESCAPES_ROOT~;
			(*count)--;
			continue;
		}

		if (*count >= MAX_MODULE_PARTS) return MODULE_PATH_TOO_DEEP~;
		(*parts)[*count] = part;
		(*count)++;
	}
}

<*
 Resolve an import written inside an embedded namespace.

 `base` carries the prefix — it is a specifier this loader produced, or the
 entry module's own name — and the answer carries it too. `name` is the import
 as written: `./docs.js` from `app:main.js` is `app:docs.js`, relative to the
 importer as any `./` is. An explicit `app:docs.js` is absolute within the
 space — the same module from every importer, exactly as a full URL is. The
 path rules inside the space are `resolve_module`'s either way, so `..` past
 the space's root is refused rather than escaping into the directory root
 next door.

 @param prefix : `The namespace's prefix, ':' included.`
 @param base : `The importing module's specifier, prefix included.`
 @param name : `The specifier as written, with or without the prefix.`
 @return `Prefixed, allocated in the caller's allocator.`
*>
fn String? resolve_embedded(String prefix, String base, String name, Allocator allocator)
{
	String resolved = name.starts_with(prefix)
		? resolve_module("", name[prefix.len..], allocator)!
		: resolve_module(base[prefix.len..], name, allocator)!;
	return string::format(allocator, "%s%s", prefix, resolved);
}

<*
 One module carried in the binary: its full specifier, prefix included, and its
 bytes — a `$embed` in the consumer, usually.
*>
struct EmbeddedModule
{
	String name;
	char[] source;
}

<*
 The ordinary loader: a directory root, an optional embedded namespace, and the
 pair of hooks wired to both.

 **Addressed by the engine once installed, so it must not move** for as long as
 the context is open — a field on something the host already keeps still, not a
 local. Everything it owns is released by `free`.

 	`ModuleLoader modules;`
 	`modules.set_embedded("app:", PARTS[..]);   // before the first import`
 	`modules.install(js);`
 	`modules.set_root("game");                  // when there is a directory`
 	`modules.set_scheme("plugin:", "./panels"); // a second, prefixed directory`

 Until `set_root`, every specifier outside the embedded namespace is refused —
 which is what a host with no script directory wants, and is a
 `ReferenceError` naming the import rather than a mystery.
*>
struct ModuleLoader
{
	ModuleHooks hooks;
	// The directory imports resolve under. Empty means no disk imports at all.
	String root;
	// The embedded namespace, both borrowed: a prefix that is a literal and a
	// table whose sources are `$embed`s live exactly as long as the binary.
	String prefix;
	EmbeddedModule[] embedded;
	// The second namespace — see `set_scheme`. A borrowed prefix like the
	// embedded one, and a directory of its own that is copied like `root`.
	String scheme;
	String scheme_root;
	// The one buffer every disk load is answered out of — see `read` for why
	// one is enough.
	char[] buffer;
}

<*
 Wire the hooks into the engine. `self` must stay put from here on.
*>
fn void ModuleLoader.install(&self, Engine* js)
{
	self.hooks = {
		.normalize = &loader_normalize,
		.load = &loader_load,
		.opaque = self,
	};
	js.on_modules(&self.hooks);
}

<*
 Point disk imports at a directory, and let modules resolve.

 @param root : `The scripts' directory. Copied.`
*>
fn void ModuleLoader.set_root(&self, String root)
{
	if (self.root.len > 0) self.root.free(mem);
	self.root = root.copy(mem);
}

<*
 Declare the embedded namespace. Call before the first import that needs it —
 in practice, before evaluating the entry module that lives there.

 @param prefix : `The namespace's prefix, ':' included. Borrowed; a literal.`
 @param table : `The modules, full specifiers and bytes. Borrowed; static.`
*>
fn void ModuleLoader.set_embedded(&self, String prefix, EmbeddedModule[] table)
{
	self.prefix = prefix;
	self.embedded = table;
}

<*
 Declare a second namespace: a prefix, and a directory it reads from.

 The embedded space carries the host's own modules and is closed; this one
 carries somebody *else's* — a plugin's scripts, shipped beside its binary — and
 the two differ in the three ways that matter.

 - It is on disk, so its modules can be edited between runs.
 - It has a root of its own, so it does not compete with `set_root` for the one
   the host's own script directory uses. A process can have both.
 - **It is open from the outside.** A module under `root` may import
   `<prefix>panel.js`. The embedded space refuses that, because an embedded
   module is the host's internals and importing one would be depending on a
   refactor of a file you cannot see; a directory somebody shipped and you can
   read is the opposite case.

 @param scheme : `The namespace's prefix, ':' included. Borrowed; a literal.`
 @param root : `The directory it reads from. Copied.`
*>
fn void ModuleLoader.set_scheme(&self, String scheme, String root)
{
	if (self.scheme_root.len > 0) self.scheme_root.free(mem);
	self.scheme = scheme;
	self.scheme_root = root.copy(mem);
}

fn void ModuleLoader.free(&self)
{
	if (self.root.len > 0) self.root.free(mem);
	if (self.scheme_root.len > 0) self.scheme_root.free(mem);
	if (self.buffer.len > 0) free(self.buffer);
	*self = {};
}

<*
 An embedded module's bytes, or empty for a specifier the table does not know —
 which the load hook turns into the engine's own "could not load module",
 naming it. The table is a handful of entries and is walked, not indexed;
 a load happens once per module per context.
*>
fn char[] ModuleLoader.embedded_source(&self, String specifier)
{
	foreach (part : self.embedded)
	{
		if (part.name == specifier) return part.source;
	}
	return {};
}

<*
 Where a root-relative path points on disk.

 The general form of what an import loads: the same containment, but for paths
 a script *names* rather than imports — the files it loads, the screenshots it
 writes. With no root the path is used as written, which is the no-directory
 case: a host running one-off scripts names files from wherever the process
 was started, and confining paths to nothing would refuse every path there is.

 **A scheme prefix is honoured here as well as in `normalize`**, so a plugin's
 data files are reachable by the same name its modules are: `plugin:icons/bone.png`
 loads from the directory `set_scheme` named. Without this, a bundle would be a
 bundle only for its code — a plugin could ship a panel but not the icon on it,
 and the only directory a `load` could see would be the one `--assets` owns.

 The confinement is the scheme's own root, so `plugin:../secrets` is refused for
 the reason `import 'plugin:../secrets.js'` is. The embedded space is
 deliberately absent: those modules are bytes in the binary and there is no file
 behind them to open.

 @param path : `As the script wrote it. A leading '/' means the root, not the filesystem's.`
 @param schemes : `False to refuse a prefixed path outright — see below.`
 @return `The path to open, allocated in the caller's allocator.`
 @return? MODULE_ESCAPES_ROOT : `A scheme-prefixed path with schemes off, or one climbing out of whichever root it landed in.`
 @return? MODULE_IS_NOT_A_FILE : `A scheme-prefixed path with no directory declared for that scheme.`
*>
fn String? ModuleLoader.locate(&self, String path, Allocator allocator, bool schemes = true)
{
	if (self.scheme.len > 0 && path.starts_with(self.scheme))
	{
		// **`schemes: false` is for a path being written**, and the asymmetry is
		// the point. Reading a plugin's icon is what the scheme exists for;
		// writing into a plugin's directory would let a game's script replace
		// the application's own panels, which is a different thing wearing the
		// same syntax.
		if (!schemes) return MODULE_ESCAPES_ROOT~;
		// A scheme with no directory behind it has nothing to answer with, and
		// answering the bare tail would silently mean the *game's* file — the
		// one collision `set_scheme`'s prefix exists to prevent.
		if (self.scheme_root.len == 0) return MODULE_IS_NOT_A_FILE~;
		String tail = path[self.scheme.len..];
		String inside = resolve_module("", tail, allocator)!;
		return string::format(allocator, "%s/%s", self.scheme_root, inside);
	}

	if (self.root.len == 0) return path.copy(allocator);
	String specifier = resolve_module("", path, allocator)!;
	return string::format(allocator, "%s/%s", self.root, specifier);
}

<*
 Read a module's bytes into the loader's reusable buffer.

 One buffer, overwritten by every load, which the shim documents as correct
 because it copies before compiling — and it copies because module loads nest,
 so a buffer that were merely borrowed would be overwritten by the imports of
 the module being compiled out of it.

 @return? MODULE_IS_NOT_A_FILE : `Nothing there, or a directory.`
 @return? MODULE_IS_TOO_LARGE : `Over MAX_MODULE_BYTES.`
*>
fn String? ModuleLoader.read(&self, String specifier)
{
	@pool()
	{
		// A specifier carrying the scheme names a file under the *other* root, and
		// the prefix comes off before it is joined — see `set_scheme`.
		bool schemed = self.scheme.len > 0 && specifier.starts_with(self.scheme);
		String base = schemed ? self.scheme_root : self.root;
		String named = schemed ? specifier[self.scheme.len..] : specifier;

		String path = base.len > 0
			? string::tformat("%s/%s", base, named)
			: named;
		if (!file::is_file(path)) return MODULE_IS_NOT_A_FILE~;

		char[]? bytes = file::load(mem, path);
		if (catch bytes) return MODULE_IS_NOT_A_FILE~;
		if (bytes.len > MAX_MODULE_BYTES)
		{
			free(bytes);
			return MODULE_IS_TOO_LARGE~;
		}

		if (self.buffer.len > 0) free(self.buffer);
		self.buffer = bytes;
		return (String)self.buffer;
	};
}

<*
 The engine asking what a specifier means. `ModuleNormalizeFn`.

 Writes into the engine's buffer and answers zero, or refuses — and a refusal
 arrives in JavaScript as a `ReferenceError` naming both the specifier and the
 module that wrote it, which is everything an author needs to fix it.
*>
fn int loader_normalize(ZString base, ZString name, char* out, usz out_size, void* opaque) @local
{
	ModuleLoader* self = (ModuleLoader*)opaque;
	String base_str = base.str_view();
	String name_str = name.str_view();
	bool spaced = self.prefix.len > 0;
	bool schemed = self.scheme.len > 0;

	@pool()
	{
		String? resolved;
		switch
		{
			case spaced && base_str.starts_with(self.prefix):
				// A module already inside the embedded namespace, importing a
				// sibling.
				resolved = resolve_embedded(self.prefix, base_str, name_str, tmem);
			case spaced && name_str.starts_with(self.prefix):
				// Script code asking for an embedded internal. Refused — the
				// space is closed from the outside.
				return -1;
			case schemed && base_str.starts_with(self.scheme):
				// A module inside the scheme's directory, importing a sibling. The
				// path rules are the embedded ones because they are the same rules:
				// prefixed, root-relative, `..` past the space refused.
				resolved = resolve_embedded(self.scheme, base_str, name_str, tmem);
			case schemed && name_str.starts_with(self.scheme):
				// Anyone else naming the scheme outright — which is allowed, and
				// is the one place this space differs from the embedded one. `base`
				// is unread on this path: a prefixed specifier is absolute within
				// its space, so who wrote it makes no difference.
				resolved = resolve_embedded(self.scheme, self.scheme, name_str, tmem);
			case self.root.len == 0:
				return -1;
			default:
				resolved = resolve_module(base_str, name_str, tmem);
		}
		if (catch resolved) return -1;
		if (resolved.len + 1 > out_size) return -1;

		for (usz i = 0; i < resolved.len; i++) out[i] = resolved[i];
		out[resolved.len] = 0;
		return 0;
	};
}

<*
 The engine asking for a module's bytes. `ModuleLoadFn`.
*>
fn char* loader_load(ZString name, usz* len_out, void* opaque) @local
{
	ModuleLoader* self = (ModuleLoader*)opaque;
	String specifier = name.str_view();

	// An embedded module's bytes are static, so no buffer is involved at all —
	// which is also why nesting cannot bite it.
	if (self.prefix.len > 0 && specifier.starts_with(self.prefix))
	{
		char[] embedded = self.embedded_source(specifier);
		if (embedded.len == 0) return null;
		*len_out = embedded.len;
		return embedded.ptr;
	}

	String? source = self.read(specifier);
	if (catch source) return null;

	*len_out = source.len;
	return (char*)source.ptr;
}
