// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "swift-telegram-client",
  platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .macCatalyst(.v18)],
  products: [
    .library(name: "TelegramSchema", targets: ["TelegramSchema"]),
    .library(name: "TelegramClient", targets: ["TelegramClient"]),
  ],
  dependencies: [
    .package(url: "https://github.com/UInt8Co/swift-mtproto.git", from: "1.0.0"),
    .package(url: "https://github.com/UInt8Co/swift-nio-mtproto.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
  ],
  targets: [
    // The client proper: everything between a connected MTProto session and the
    // Telegram API — authorization, datacenter migration, the connection pool,
    // update differences, peer resolution and file transfer. Independent of any
    // one schema beyond `TelegramSchema`; a private namespace generated on top
    // of it rides the same `invoke`.
    .target(
      name: "TelegramClient",
      dependencies: [
        "TelegramSchema",
        .product(name: "MTProtoClientKit", package: "swift-nio-mtproto"),
        .product(name: "NIOMTProtoEncryption", package: "swift-nio-mtproto"),
        .product(name: "MTProtoCrypto", package: "swift-mtproto"),
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .testTarget(
      name: "TelegramClientTests",
      dependencies: [
        "TelegramClient",
        "TelegramSchema",
        .product(name: "MTProtoClientKit", package: "swift-nio-mtproto"),
        .product(name: "TLCoding", package: "swift-mtproto"),
      ]
    ),
    // schema-modules:begin — Scripts/generate-package-targets.ts. Do not edit by hand.
    // The API schema is generated as one module per subdirectory, all
    // re-exported by the TelegramSchema umbrella, so a schema change rebuilds a
    // part of it instead of every file.
    .target(
      name: "TelegramSchemaSupport",
      dependencies: [
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/Support"
    ),
    .target(
      name: "TelegramSchemaTypes",
      dependencies: [
        "TelegramSchemaSupport",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/Types"
    ),
    .target(
      name: "TelegramSchemaMethodsGlobal",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsGlobal"
    ),
    .target(
      name: "TelegramSchemaMethodsAccount",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsAccount"
    ),
    .target(
      name: "TelegramSchemaMethodsAicompose",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsAicompose"
    ),
    .target(
      name: "TelegramSchemaMethodsAuth",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsAuth"
    ),
    .target(
      name: "TelegramSchemaMethodsBots",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsBots"
    ),
    .target(
      name: "TelegramSchemaMethodsChannels",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsChannels"
    ),
    .target(
      name: "TelegramSchemaMethodsChatlists",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsChatlists"
    ),
    .target(
      name: "TelegramSchemaMethodsCommunities",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsCommunities"
    ),
    .target(
      name: "TelegramSchemaMethodsContacts",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsContacts"
    ),
    .target(
      name: "TelegramSchemaMethodsEphemeral",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsEphemeral"
    ),
    .target(
      name: "TelegramSchemaMethodsFolders",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsFolders"
    ),
    .target(
      name: "TelegramSchemaMethodsFragment",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsFragment"
    ),
    .target(
      name: "TelegramSchemaMethodsHelp",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsHelp"
    ),
    .target(
      name: "TelegramSchemaMethodsLangpack",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsLangpack"
    ),
    .target(
      name: "TelegramSchemaMethodsMessages",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsMessages"
    ),
    .target(
      name: "TelegramSchemaMethodsPayments",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsPayments"
    ),
    .target(
      name: "TelegramSchemaMethodsPhone",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsPhone"
    ),
    .target(
      name: "TelegramSchemaMethodsPhotos",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsPhotos"
    ),
    .target(
      name: "TelegramSchemaMethodsPremium",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsPremium"
    ),
    .target(
      name: "TelegramSchemaMethodsSmsjobs",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsSmsjobs"
    ),
    .target(
      name: "TelegramSchemaMethodsStats",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsStats"
    ),
    .target(
      name: "TelegramSchemaMethodsStickers",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsStickers"
    ),
    .target(
      name: "TelegramSchemaMethodsStories",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsStories"
    ),
    .target(
      name: "TelegramSchemaMethodsUpdates",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsUpdates"
    ),
    .target(
      name: "TelegramSchemaMethodsUpload",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsUpload"
    ),
    .target(
      name: "TelegramSchemaMethodsUsers",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/MethodsUsers"
    ),
    .target(
      name: "TelegramSchemaClient",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/Client"
    ),
    .target(
      name: "TelegramSchemaClientGlobal",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsGlobal",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientGlobal"
    ),
    .target(
      name: "TelegramSchemaClientAccount",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsAccount",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientAccount"
    ),
    .target(
      name: "TelegramSchemaClientAicompose",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsAicompose",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientAicompose"
    ),
    .target(
      name: "TelegramSchemaClientAuth",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsAuth",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientAuth"
    ),
    .target(
      name: "TelegramSchemaClientBots",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsBots",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientBots"
    ),
    .target(
      name: "TelegramSchemaClientChannels",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsChannels",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientChannels"
    ),
    .target(
      name: "TelegramSchemaClientChatlists",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsChatlists",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientChatlists"
    ),
    .target(
      name: "TelegramSchemaClientCommunities",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsCommunities",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientCommunities"
    ),
    .target(
      name: "TelegramSchemaClientContacts",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsContacts",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientContacts"
    ),
    .target(
      name: "TelegramSchemaClientEphemeral",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsEphemeral",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientEphemeral"
    ),
    .target(
      name: "TelegramSchemaClientFolders",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsFolders",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientFolders"
    ),
    .target(
      name: "TelegramSchemaClientFragment",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsFragment",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientFragment"
    ),
    .target(
      name: "TelegramSchemaClientHelp",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsHelp",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientHelp"
    ),
    .target(
      name: "TelegramSchemaClientLangpack",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsLangpack",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientLangpack"
    ),
    .target(
      name: "TelegramSchemaClientMessages",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsMessages",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientMessages"
    ),
    .target(
      name: "TelegramSchemaClientPayments",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsPayments",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientPayments"
    ),
    .target(
      name: "TelegramSchemaClientPhone",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsPhone",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientPhone"
    ),
    .target(
      name: "TelegramSchemaClientPhotos",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsPhotos",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientPhotos"
    ),
    .target(
      name: "TelegramSchemaClientPremium",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsPremium",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientPremium"
    ),
    .target(
      name: "TelegramSchemaClientSmsjobs",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsSmsjobs",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientSmsjobs"
    ),
    .target(
      name: "TelegramSchemaClientStats",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsStats",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientStats"
    ),
    .target(
      name: "TelegramSchemaClientStickers",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsStickers",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientStickers"
    ),
    .target(
      name: "TelegramSchemaClientStories",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsStories",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientStories"
    ),
    .target(
      name: "TelegramSchemaClientUpdates",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsUpdates",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientUpdates"
    ),
    .target(
      name: "TelegramSchemaClientUpload",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsUpload",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientUpload"
    ),
    .target(
      name: "TelegramSchemaClientUsers",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaClient",
        "TelegramSchemaMethodsUsers",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/ClientUsers"
    ),
    .target(
      name: "TelegramSchema",
      dependencies: [
        "TelegramSchemaSupport",
        "TelegramSchemaTypes",
        "TelegramSchemaMethodsGlobal",
        "TelegramSchemaMethodsAccount",
        "TelegramSchemaMethodsAicompose",
        "TelegramSchemaMethodsAuth",
        "TelegramSchemaMethodsBots",
        "TelegramSchemaMethodsChannels",
        "TelegramSchemaMethodsChatlists",
        "TelegramSchemaMethodsCommunities",
        "TelegramSchemaMethodsContacts",
        "TelegramSchemaMethodsEphemeral",
        "TelegramSchemaMethodsFolders",
        "TelegramSchemaMethodsFragment",
        "TelegramSchemaMethodsHelp",
        "TelegramSchemaMethodsLangpack",
        "TelegramSchemaMethodsMessages",
        "TelegramSchemaMethodsPayments",
        "TelegramSchemaMethodsPhone",
        "TelegramSchemaMethodsPhotos",
        "TelegramSchemaMethodsPremium",
        "TelegramSchemaMethodsSmsjobs",
        "TelegramSchemaMethodsStats",
        "TelegramSchemaMethodsStickers",
        "TelegramSchemaMethodsStories",
        "TelegramSchemaMethodsUpdates",
        "TelegramSchemaMethodsUpload",
        "TelegramSchemaMethodsUsers",
        "TelegramSchemaClient",
        "TelegramSchemaClientGlobal",
        "TelegramSchemaClientAccount",
        "TelegramSchemaClientAicompose",
        "TelegramSchemaClientAuth",
        "TelegramSchemaClientBots",
        "TelegramSchemaClientChannels",
        "TelegramSchemaClientChatlists",
        "TelegramSchemaClientCommunities",
        "TelegramSchemaClientContacts",
        "TelegramSchemaClientEphemeral",
        "TelegramSchemaClientFolders",
        "TelegramSchemaClientFragment",
        "TelegramSchemaClientHelp",
        "TelegramSchemaClientLangpack",
        "TelegramSchemaClientMessages",
        "TelegramSchemaClientPayments",
        "TelegramSchemaClientPhone",
        "TelegramSchemaClientPhotos",
        "TelegramSchemaClientPremium",
        "TelegramSchemaClientSmsjobs",
        "TelegramSchemaClientStats",
        "TelegramSchemaClientStickers",
        "TelegramSchemaClientStories",
        "TelegramSchemaClientUpdates",
        "TelegramSchemaClientUpload",
        "TelegramSchemaClientUsers",
        .product(name: "TLCoding", package: "swift-mtproto"),
        .product(name: "MTProtoBaseSchema", package: "swift-mtproto"),
      ],
      path: "Sources/TelegramSchema/Umbrella"
    ),
    // schema-modules:end
  ],
  swiftLanguageModes: [.v6]
)
