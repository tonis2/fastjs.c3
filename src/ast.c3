module fastjs::ast;
import fastjs::lex;

enum NodeKind : char (String text)
{
	// Expressions.
	NUMBER { "number" },               // name: source text, number: value
	STRING { "string" },               // name: raw text without quotes; flags.escaped, flags.single_quote
	TEMPLATE { "template" },           // list: TEMPLATE_PART, expr, TEMPLATE_PART, ... (parts at even indices)
	TEMPLATE_PART { "template part" }, // name: raw text; flags.escaped
	REGEX { "regex" },                 // name: full source text, /pattern/flags
	IDENT { "identifier" },            // name
	THIS { "this" },
	SUPER { "super" },
	NULL { "null" },
	TRUE { "true" },
	FALSE { "false" },
	NEW_TARGET { "new.target" },
	ARRAY { "array" },                 // list: elements, which may be SPREAD or HOLE
	HOLE { "hole" },
	OBJECT { "object" },               // list: PROPERTY or SPREAD
	PROPERTY { "property" },           // a: key, b: value; flags: computed shorthand method getter setter is_static field
	FUNCTION { "function" },           // name, list: params, a: body; flags: arrow async generator expression_body declaration
	CLASS { "class" },                 // name, a: superclass, list: PROPERTY members; flags.declaration;
	                                   // the resolver adds b: instance-field initializer, c: static-field initializer
	UNARY { "unary" },                 // op, a
	UPDATE { "update" },               // op, a; flags.prefix
	BINARY { "binary" },               // op, a, b; includes `in` and `instanceof`
	LOGICAL { "logical" },             // op (&& || ??), a, b
	ASSIGN { "assign" },               // op, a: target (pattern for '='), b: value
	CONDITIONAL { "conditional" },     // a ? b : c
	CALL { "call" },                   // a: callee, list: args; flags.optional when called through ?.
	NEW { "new" },                     // a: callee, list: args
	MEMBER { "member" },               // a: object, name, or b when flags.computed; flags.optional
	OPTIONAL_CHAIN { "optional chain" }, // a: the chain; a ?. anywhere inside short-circuits to here
	SEQUENCE { "sequence" },           // list
	SPREAD { "spread" },               // a
	YIELD { "yield" },                 // a (optional); flags.delegate
	AWAIT { "await" },                 // a

	// Patterns, produced from declarations, parameters, or a converted literal.
	ARRAY_PATTERN { "array pattern" },   // list: patterns, ASSIGN_PATTERN, REST or HOLE
	OBJECT_PATTERN { "object pattern" }, // list: PROPERTY (b: pattern) or REST
	ASSIGN_PATTERN { "default" },        // a: target, b: default value
	REST { "rest" },                     // a: target

	// Statements.
	PROGRAM { "program" },             // list; flags.is_module
	VAR_DECL { "declaration" },        // op: KW_CONST or IDENT (let); list: DECLARATOR
	DECLARATOR { "declarator" },       // a: pattern, b: init
	EXPR_STMT { "expression statement" }, // a
	BLOCK { "block" },                 // list
	EMPTY { "empty statement" },
	IF { "if" },                       // a: test, b: then, c: else
	FOR { "for" },                     // a: init, b: test, c: update, d: body
	FOR_OF { "for of" },               // a: VAR_DECL or target, b: iterable, d: body
	FOR_IN { "for in" },               // a: VAR_DECL or target, b: object, d: body
	WHILE { "while" },                 // a: test, d: body
	RETURN { "return" },               // a
	BREAK { "break" },
	CONTINUE { "continue" },
	THROW { "throw" },                 // a
	TRY { "try" },                     // a: block, b: catch binding, c: catch block, d: finally block
	SWITCH { "switch" },               // a: discriminant, list: CASE
	CASE { "case" },                   // a: test, null for default; list: statements
	IMPORT { "import" },               // name: module specifier (raw), list: IMPORT_SPEC
	IMPORT_SPEC { "import specifier" }, // name: imported ("default", "*" or a name), b: local IDENT
	EXPORT { "export" },               // a: declaration, or list: EXPORT_SPEC; name: `from` specifier
	EXPORT_SPEC { "export specifier" }, // a: local IDENT, name: exported name
	EXPORT_DEFAULT { "export default" }, // a: expression, function or class
}

bitstruct NodeFlags : uint
{
	bool computed;
	bool shorthand;
	bool method;
	bool getter;
	bool setter;
	bool is_static;
	bool field;
	bool arrow;
	bool is_async;
	bool generator;
	bool optional;
	bool prefix;
	bool delegate;
	bool escaped;
	bool single_quote;
	bool expression_body;
	bool declaration;
	bool is_module;
	bool parenthesized;
	// `{ a = 1 }` in an object literal: only valid once the literal becomes a pattern.
	bool cover_init;
	// `import a from` rather than `import {default as a} from`.
	bool default_import;
	// Set by the resolver: this read may run before the variable is initialized.
	bool needs_tdz;
	// A class's constructor function, and whether that class has `extends`.
	bool class_constructor;
	bool derived;
}

struct Node
{
	NodeKind kind;
	TokenKind op;
	NodeFlags flags;
	uint start;
	uint line;
	uint col;
	Node* a;
	Node* b;
	Node* c;
	Node* d;
	Node*[] list;
	String name;
	double number;
	// Filled by the resolver: a Binding for identifiers, a Scope for blocks, a FuncInfo for functions.
	void* sema;
}
