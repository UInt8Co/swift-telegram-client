// Converts mtcute's `api-schema.json` (the `{ l, e: [...] }` layout) into the
// `{ constructors, methods }` layout that mtproto-gen-swift consumes, so the
// generated schema speaks exactly the layer that checkout does.
//
// Only needed for `Scripts/generate-schema.sh --from-mtcute`; pinning from
// Telegram's own published JSON needs no conversion.
//
// Usage: deno run --allow-read --allow-write convert-tl-schema.ts <in> <out>
interface Arg {
  name: string
  type: string
  typeModifiers?: { predicate?: string; isVector?: boolean }
}
interface Entry {
  kind: "class" | "method"
  name: string
  id: number
  type: string
  typeModifiers?: { isVector?: boolean }
  arguments?: Arg[]
}

function argType(a: Arg): string {
  if (a.type === "#") return "#"
  // mtcute's "int53" is a TL `long` constrained to 53 bits for JS safety.
  let base = a.type === "int53" ? "long" : a.type
  const m = a.typeModifiers ?? {}
  if (m.isVector) base = `Vector<${base}>`
  if (m.predicate) base = `${m.predicate}?${base}`
  return base
}

function returnType(e: Entry): string {
  const base = e.type === "int53" ? "long" : e.type
  return e.typeModifiers?.isVector ? `Vector<${base}>` : base
}

// The generator parses `id` as a signed 32-bit decimal; mtcute stores unsigned.
function signedId(id: number): string {
  return (id > 0x7fffffff ? id - 0x100000000 : id).toString()

// This is a pure format conversion: every entry the schema publishes is carried
// over verbatim, vendor namespaces included (`mtcute.dummyUpdate`,
// `mtcute.customMethod` …). Those are client-internal and must never reach
// generated code, but dropping them is the generator's job —
// `--exclude-namespace mtcute` in Scripts/generate-schema.sh — so the committed
// schema stays a faithful copy of the layer and one place decides what is
// excluded.
// of the layer and one place decides what is excluded.
const [inPath, outPath] = Deno.args
const schema = JSON.parse(await Deno.readTextFile(inPath)) as { l: number; e: Entry[] }
const constructors: unknown[] = []
const methods: unknown[] = []
for (const e of schema.e) {
  const params = (e.arguments ?? []).map((a) => ({ name: a.name, type: argType(a) }))
  if (e.kind === "class") {
    constructors.push({ id: signedId(e.id), predicate: e.name, params, type: e.type })
  } else if (e.kind === "method") {
    methods.push({ id: signedId(e.id), method: e.name, params, type: returnType(e) })
  }
}
await Deno.writeTextFile(outPath, JSON.stringify({ constructors, methods }, null, 1) + "\n")
console.log(
  `layer ${schema.l}: ${constructors.length} constructors, ${methods.length} methods`,
)
