#!/usr/bin/env -S deno run --allow-read --allow-write
// Writes Sources/TelegramClient/Peers/ReceivedPeers+Schema.swift from
// Schemas/api.json: how to find every `User` and `Chat` a received value holds.
// Also writes Tests/TelegramClientTests/ReceivedPeersSchema+Methods.swift, the
// Swift type of every method, so the tests can call a method found in the schema.
//
// A type "carries peers" when one of its constructors has a field whose type is
// `User` or `Chat`, or (through vectors and optional fields, at any depth) a type
// that carries peers. The output is a `ReceivedPeerCarrying` conformance for
// every such type, and for every constructor of one that has such a field,
// visiting exactly those fields. `PeerObservingTransport` casts each typed RPC
// result to the protocol, so a method whose result carries peers needs nothing
// of its own here, and wrappers (`invokeWith…`, `query:!X`) are seen through by
// the typed function itself.
//
// Swift names follow mtproto-gen-swift's (`ResolvedSchema` / `Naming`), which
// generated `TelegramSchema` from the same file; a name that disagrees fails to
// compile rather than going unnoticed. The test `ReceivedPeersSchemaTests`
// re-derives the closure from the schema independently and checks the result.
//
// Plain `node:` APIs only, so `deno run` and `bun` both run it. Run by
// Scripts/generate-schema.sh after the schema is regenerated.
//
//   ./Scripts/generate-received-peers.ts [--check]
//
// `--check` only reports whether the committed files are up to date (exit 1 if not).

import { readFileSync, writeFileSync } from "node:fs";
import process from "node:process";

const repoRoot = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const SCHEMA = `${repoRoot}/Schemas/api.json`;
const OUTPUT = `${repoRoot}/Sources/TelegramClient/Peers/ReceivedPeers+Schema.swift`;
const TEST_OUTPUT = `${repoRoot}/Tests/TelegramClientTests/ReceivedPeersSchema+Methods.swift`;
// Same as generate-schema.sh's --exclude-namespace: never part of generated code.
const EXCLUDED_NAMESPACES = new Set(["mtcute"]);
// The peers themselves; their conformances are written by hand.
const PEER_TYPES = new Set(["User", "Chat"]);

type Param = { name: string; type: string };
type Combinator = {
  id: string;
  predicate?: string;
  method?: string;
  params: Param[];
  type: string;
};

const schema: { constructors: Combinator[]; methods: Combinator[] } = JSON.parse(
  readFileSync(SCHEMA, "utf8"),
);
const nameOf = (c: Combinator) => c.predicate ?? c.method ?? "";

// MARK: - Naming (mirrors MTProtoGenKit's Naming)

const reservedKeywords = new Set([
  "as", "associatedtype", "async", "await", "break", "case", "catch",
  "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
  "extension", "fallthrough", "false", "fileprivate", "for", "func",
  "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
  "nil", "operator", "precedencegroup", "private", "protocol", "public",
  "repeat", "rethrows", "return", "static", "struct", "subscript", "super",
  "switch", "throw", "throws", "true", "try", "typealias", "var", "where",
  "while", "Self", "Any",
]);
const reservedMemberNames = new Set([
  "TL", "TLCoding", "Swift", "Type",
  "Int32", "Int64", "UInt32", "UInt64", "Double", "String", "Data", "Bool",
  "TLInt128", "TLInt256", "TLWriter", "TLReader", "TLError", "TLFunction",
  "TLFunctionWrapper", "TLEncodable", "TLDecodable", "TLConstructed", "TLAnyObject",
  "Equatable", "Sendable", "Optional", "Array",
]);
const builtinTypes = new Set(["Bool", "True", "Null", "Vector t", "Object"]);

const capitalizedFirst = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s);
const lowercasedFirst = (s: string) => (s ? s[0].toLowerCase() + s.slice(1) : s);
function camelCase(name: string): string {
  const parts = name.split("_").filter((p) => p.length > 0);
  if (parts.length === 0) return name;
  return parts[0] + parts.slice(1).map(capitalizedFirst).join("");
}
const flattened = (tl: string) =>
  tl.split(".").map((p) => capitalizedFirst(camelCase(p))).join("");
function escaped(id: string): string {
  if (id === "self") return "self_";
  if (reservedKeywords.has(id)) return "`" + id + "`";
  return id;
}
const propertyName = (field: string) => escaped(camelCase(field));
const namespaceEnumName = (ns: string) => capitalizedFirst(camelCase(ns));
const caseName = (predicate: string) => escaped(lowercasedFirst(flattened(predicate)));
const namespaceOf = (tl: string) => (tl.includes(".") ? tl.slice(0, tl.indexOf(".")) : null);
const localName = (tl: string) => (tl.includes(".") ? tl.slice(tl.indexOf(".") + 1) : tl);

// MARK: - Name resolution (mirrors ResolvedSchema.init)

const excluded = (c: Combinator) => {
  const ns = namespaceOf(nameOf(c));
  return ns !== null && EXCLUDED_NAMESPACES.has(ns);
};
const constructors = schema.constructors.filter((c) => c.predicate && !excluded(c));
const methods = schema.methods.filter((c) => c.method && !excluded(c));

const typeOrder: string[] = [];
const constructorsByType = new Map<string, Combinator[]>();
for (const c of constructors) {
  if (builtinTypes.has(c.type)) continue;
  if (!constructorsByType.has(c.type)) {
    typeOrder.push(c.type);
    constructorsByType.set(c.type, []);
  }
  constructorsByType.get(c.type)!.push(c);
}

const namespaceEnums = new Set<string>();
for (
  const name of [
    ...typeOrder,
    ...[...constructorsByType.values()].flat().map(nameOf),
    ...methods.map(nameOf),
  ]
) {
  const ns = namespaceOf(name);
  if (ns !== null) namespaceEnums.add(namespaceEnumName(ns));
}

const claimed = new Map<string, Set<string>>([["", new Set(namespaceEnums)]]);
function claim(candidate: string, ns: string | null): string {
  const key = ns ?? "";
  if (!claimed.has(key)) claimed.set(key, new Set());
  const names = claimed.get(key)!;
  let name = candidate;
  while (reservedMemberNames.has(name) || names.has(name)) name += "_";
  names.add(name);
  return name;
}
function swiftName(tl: string, suffix = ""): string {
  const ns = namespaceOf(tl);
  const nsEnum = ns === null ? null : namespaceEnumName(ns);
  const local = claim(capitalizedFirst(camelCase(localName(tl))) + suffix, nsEnum);
  return "TL." + (nsEnum ? nsEnum + "." : "") + local;
}

const constructorSwift = new Map<string, string>(); // predicate → struct
for (const type of typeOrder) {
  for (const c of constructorsByType.get(type)!) constructorSwift.set(nameOf(c), swiftName(nameOf(c)));
}
const typeEnumSwift = new Map<string, string>(); // TL type → enum (multi-constructor only)
for (const type of typeOrder) {
  if (constructorsByType.get(type)!.length > 1) typeEnumSwift.set(type, swiftName(type, "Type"));
}
const methodSwift = new Map<string, string>();
for (const m of methods) methodSwift.set(nameOf(m), swiftName(nameOf(m)));

function caseNameIn(type: string, c: Combinator): string {
  const predicate = nameOf(c);
  return namespaceOf(predicate) === namespaceOf(type)
    ? caseName(localName(predicate))
    : caseName(predicate);
}

// MARK: - Field types

type Value =
  | { kind: "primitive"; swift: string }
  | { kind: "vector"; element: Value }
  | { kind: "named"; tl: string; bare: boolean }
  | { kind: "query" };

const primitives: Record<string, string> = {
  int: "Int32", long: "Int64", double: "Double", string: "String", bytes: "Data",
  int128: "TLInt128", int256: "TLInt256", Bool: "Bool", Object: "TLAnyObject",
};

function parseValue(text: string): Value | null {
  if (text.startsWith("%")) {
    const inner = parseValue(text.slice(1));
    return inner && inner.kind === "named" ? { ...inner, bare: true } : inner;
  }
  if (text === "!X" || text === "X") return { kind: "query" };
  if (text === "true") return null;
  if (text in primitives) return { kind: "primitive", swift: primitives[text] };
  const vector = /^[Vv]ector<(.*)>$/.exec(text);
  if (vector) {
    const element = parseValue(vector[1]);
    if (!element) throw new Error(`unsupported vector element in '${text}'`);
    return { kind: "vector", element };
  }
  return { kind: "named", tl: text, bare: false };
}

type Field = {
  name: string;
  value: Value | null; // null: flags, or a `true` flag, which hold no peer
};

function parseField(param: Param): Field {
  if (param.type === "#") return { name: param.name, value: null };
  const question = param.type.indexOf("?");
  return { name: param.name, value: parseValue(param.type.slice(question + 1)) };
}

// The TL type a named reference resolves to: a boxed type, or the type that
// declares a bare constructor reference (`%user`, `vector<user>`).
const declaringType = new Map<string, string>();
for (const [type, cs] of constructorsByType) for (const c of cs) declaringType.set(nameOf(c), type);
const resolveType = (tl: string) => (constructorsByType.has(tl) ? tl : declaringType.get(tl));

function namedIn(value: Value | null): string | null {
  if (!value) return null;
  if (value.kind === "vector") return namedIn(value.element);
  if (value.kind === "named") return resolveType(value.tl) ?? null;
  return null;
}

// MARK: - The closure

const carries = new Set<string>(PEER_TYPES);
for (let changed = true; changed;) {
  changed = false;
  for (const type of typeOrder) {
    if (carries.has(type)) continue;
    const reaches = constructorsByType.get(type)!.some((c) =>
      c.params.some((p) => {
        const named = namedIn(parseField(p).value);
        return named !== null && carries.has(named);
      })
    );
    if (reaches) {
      carries.add(type);
      changed = true;
    }
  }
}

function peerFields(c: Combinator): Field[] {
  return c.params.map(parseField).filter((f) => {
    const named = namedIn(f.value);
    return named !== null && carries.has(named);
  });
}

// MARK: - Emission

const out: string[] = [];
const emit = (line = "") => out.push(line);

emit("// Generated by Scripts/generate-received-peers.ts from Schemas/api.json. DO NOT EDIT.");
emit("//");
emit("// Every TL type whose value can hold a `User` or a `Chat`, at any depth.");
emit("import TLCoding");
emit("import TelegramSchema");
emit("");
emit("// MARK: - Types that carry peers");

const carrierTypes = typeOrder.filter((t) => carries.has(t) && !PEER_TYPES.has(t));
for (const type of carrierTypes) {
  const cs = constructorsByType.get(type)!;
  const enumName = typeEnumSwift.get(type);
  if (enumName) {
    const reaching = cs.filter((c) => peerFields(c).length > 0);
    emit("");
    emit(`extension ${enumName}: ReceivedPeerCarrying {`);
    emit("  func collectReceivedPeers(into peers: inout ReceivedPeerList) {");
    emit("    switch self {");
    for (const c of reaching) {
      emit(`    case .${caseNameIn(type, c)}(let value): value.collectReceivedPeers(into: &peers)`);
    }
    if (reaching.length < cs.length) emit("    default: break");
    emit("    }");
    emit("  }");
    emit("}");
  }
  for (const c of cs) {
    const fields = peerFields(c);
    if (fields.length === 0) continue;
    emit("");
    emit(`/// \`${nameOf(c)}\``);
    emit(`extension ${constructorSwift.get(nameOf(c))}: ReceivedPeerCarrying {`);
    emit("  func collectReceivedPeers(into peers: inout ReceivedPeerList) {");
    for (const f of fields) emit(`    self.${propertyName(f.name)}.collectReceivedPeers(into: &peers)`);
    emit("  }");
    emit("}");
  }
}

emit("");

// MARK: - Test support: every method's Swift type

const tests: string[] = [];
const emitTest = (line = "") => tests.push(line);

emitTest("// Generated by Scripts/generate-received-peers.ts from Schemas/api.json. DO NOT EDIT.");
emitTest("//");
emitTest("// Every method of `TelegramSchema` except the generic wrappers, in schema order, so");
emitTest("// `ReceivedPeersSchemaTests` can invoke a method it found in the schema.");
emitTest("import TLCoding");
emitTest("import TelegramSchema");
emitTest("");
emitTest("let schemaMethods: [any (TLFunction & TLConstructed).Type] = [");
const plainMethods = methods.filter((m) => !m.params.some((p) => p.type === "!X"));
for (const m of plainMethods) emitTest(`  ${methodSwift.get(nameOf(m))}.self,`);
emitTest("]");
emitTest("");

function update(path: string, generated: string, summary: string) {
  const file = path.slice(path.lastIndexOf("/") + 1);
  let current = "";
  try {
    current = readFileSync(path, "utf8");
  } catch {
    // Missing: written below, or reported stale by --check.
  }
  if (process.argv.includes("--check")) {
    if (current !== generated) {
      console.error(`error: ${file} is stale — run Scripts/generate-received-peers.ts`);
      process.exit(1);
    }
    console.log(`${file} is up to date (${summary}).`);
  } else if (current !== generated) {
    writeFileSync(path, generated);
    console.log(`wrote ${file} (${summary})`);
  } else {
    console.log(`${file} unchanged (${summary})`);
  }
}

update(OUTPUT, out.join("\n"), `${carrierTypes.length} types`);
update(TEST_OUTPUT, tests.join("\n"), `${plainMethods.length} methods`);
