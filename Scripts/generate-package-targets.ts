#!/usr/bin/env -S deno run --allow-read --allow-write
// Rewrites the generated schema targets in `Package.swift` from the module
// graph `mtproto-gen-swift --split-modules` emitted alongside the sources
// (Sources/TelegramSchema/modules.json).
//
// The manifest stays plain, static Swift — it reads no files and decodes no
// JSON while SwiftPM evaluates it — and the ~56 generated targets are still not
// hand-maintained. Scripts/generate-schema.sh runs this after the generator.
//
//   ./Scripts/generate-package-targets.ts [--check]
//
// `--check` only reports whether the region is up to date (exit 1 if not).

const repoRoot = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const SCHEMA_ROOT = "Sources/TelegramSchema";
const MANIFEST = `${repoRoot}/${SCHEMA_ROOT}/modules.json`;
const PACKAGE = `${repoRoot}/Package.swift`;
// Every module the generator names as an external dependency is a swift-mtproto
// product (the TLCoding runtime, and the module owning the root `TL` enum).
const EXTERNAL_PACKAGE = "swift-mtproto";
const BEGIN = "// schema-modules:begin";
const END = "// schema-modules:end";

type Module = {
  name: string;
  directory: string;
  dependencies: string[];
  externalDependencies: string[];
};

const { umbrella, modules }: { umbrella: string; modules: Module[] } = JSON.parse(
  await Deno.readTextFile(MANIFEST).catch(() => {
    console.error(
      `error: ${SCHEMA_ROOT}/modules.json is missing — run Scripts/generate-schema.sh`,
    );
    Deno.exit(1);
  }),
);

function target(module: Module) {
  const deps = [
    ...module.dependencies.map((d) => `"${d}",`),
    ...module.externalDependencies.map((d) =>
      `.product(name: "${d}", package: "${EXTERNAL_PACKAGE}"),`
    ),
  ];
  return [
    `    .target(`,
    `      name: "${module.name}",`,
    `      dependencies: [`,
    ...deps.map((d) => `        ${d}`),
    `      ],`,
    `      path: "${SCHEMA_ROOT}/${module.directory}"`,
    `    ),`,
  ].join("\n");
}

const region = [
  `    ${BEGIN} — Scripts/generate-package-targets.ts. Do not edit by hand.`,
  `    // The API schema is generated as one module per subdirectory, all`,
  `    // re-exported by the ${umbrella} umbrella, so a schema change rebuilds a`,
  `    // part of it instead of every file.`,
  ...modules.map(target),
  `    ${END}`,
].join("\n");

const source = await Deno.readTextFile(PACKAGE);
const markers = new RegExp(`^[ \\t]*${BEGIN}[\\s\\S]*?^[ \\t]*${END}.*$`, "m");
if (!markers.test(source)) {
  console.error(`error: no '${BEGIN} … ${END}' region in Package.swift`);
  Deno.exit(1);
}
const updated = source.replace(markers, region);

if (Deno.args.includes("--check")) {
  if (updated !== source) {
    console.error(
      "error: Package.swift's generated targets are stale — run Scripts/generate-schema.sh",
    );
    Deno.exit(1);
  }
  console.log(`Package.swift is up to date (${modules.length} schema targets).`);
} else if (updated !== source) {
  await Deno.writeTextFile(PACKAGE, updated);
  console.log(`wrote Package.swift (${modules.length} schema targets)`);
} else {
  console.log(`Package.swift unchanged (${modules.length} schema targets)`);
}
