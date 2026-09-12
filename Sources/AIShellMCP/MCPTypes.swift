import Foundation

struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

extension JSONRPCRequest {
    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try values.decode(String.self, forKey: .jsonrpc)
        method = try values.decode(String.self, forKey: .method)
        id = values.contains(.id) ? try values.decode(JSONValue.self, forKey: .id) : nil
        params = try values.decodeIfPresent(JSONValue.self, forKey: .params)
    }
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: JSONValue
    let result: JSONValue?
    let error: JSONRPCError?

    static func success(id: JSONValue, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONValue, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
    }
}

struct JSONRPCError: Encodable, Sendable {
    let code: Int
    let message: String
}

struct MCPTool: Encodable, Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations
}

struct MCPToolAnnotations: Encodable, Sendable {
    let readOnlyHint: Bool
    let destructiveHint: Bool
    let idempotentHint: Bool
    let openWorldHint: Bool
}

enum ToolCatalog {
    static let tools: [MCPTool] = [
        tool(
            "files_list", "フォルダ一覧", "指定フォルダの項目を一覧します。pathを省略するとMCP起動ディレクトリです。",
            properties: ["path": string("MCP起動ディレクトリからの相対パス、または絶対パス")],
            required: [], readOnly: true, idempotent: true
        ),
        tool(
            "files_search", "ファイル検索", "指定フォルダ内をファイル名で再帰検索します。",
            properties: [
                "query": string("検索文字列"),
                "path": string("検索開始パス。省略時は起動ディレクトリ"),
                "limit": integer("最大件数。省略時は全件")
            ],
            required: ["query"], readOnly: true, idempotent: true
        ),
        tool(
            "files_read_text", "テキスト読取", "UTF-8テキストを省略せず読み取ります。",
            properties: ["path": string("対象ファイルのパス")],
            required: ["path"], readOnly: true, idempotent: true
        ),
        tool(
            "files_stat", "ファイル情報", "ファイル情報、POSIX permission、必要ならSHA-256を取得します。",
            properties: [
                "path": string("対象パス"),
                "include_hash": boolean("ファイルのSHA-256を計算する。既定false")
            ],
            required: ["path"], readOnly: true, idempotent: true
        ),
        tool(
            "files_tree", "ディレクトリツリー", "指定フォルダ内を深さと件数を制限して再帰一覧します。",
            properties: [
                "path": string("開始パス。省略時は起動ディレクトリ"),
                "max_depth": integer("最大深さ。省略時は全階層"),
                "limit": integer("最大件数。省略時は全件")
            ],
            required: [], readOnly: true, idempotent: true
        ),
        tool(
            "files_create_directory", "フォルダ作成", "指定フォルダ内へ新しいフォルダを作成します。",
            properties: ["path": string("作成するフォルダのパス")],
            required: ["path"], idempotent: false
        ),
        tool(
            "files_create_text", "テキスト作成", "既存項目を上書きせず、新しいUTF-8テキストファイルを作成します。",
            properties: [
                "path": string("作成するファイルのパス"),
                "content": string("書き込む内容")
            ],
            required: ["path", "content"], idempotent: false
        ),
        tool(
            "files_write_text", "テキスト更新", "指定内容をUTF-8で書き込みます。expected_sha256を指定した場合だけ、内容の一致を確認します。",
            properties: [
                "path": string("対象ファイルのパス"),
                "content": string("更新後の全内容"),
                "expected_sha256": string("既存ファイルを読み取った時点のSHA-256")
            ],
            required: ["path", "content"], idempotent: false
        ),
        tool(
            "files_replace_text", "部分置換", "old_textを事前条件としてUTF-8テキストの一部を置換します。",
            properties: [
                "path": string("対象ファイルのパス"),
                "old_text": string("置換対象の正確な文字列"),
                "new_text": string("置換後の文字列"),
                "replace_all": boolean("一致箇所をすべて置換する。既定false")
            ],
            required: ["path", "old_text", "new_text"], idempotent: false
        ),
        tool(
            "files_copy", "ファイルコピー", "指定フォルダ内で項目をコピーします。既存項目は上書きしません。",
            properties: [
                "source": string("コピー元パス"),
                "destination": string("コピー先パス")
            ],
            required: ["source", "destination"], idempotent: false
        ),
        tool(
            "files_move", "ファイル移動", "指定フォルダ内で項目を移動します。既存項目は上書きしません。",
            properties: [
                "source": string("移動元パス"),
                "destination": string("移動先パス")
            ],
            required: ["source", "destination"], idempotent: false
        ),
        tool(
            "files_rename", "名前変更", "指定フォルダ内の項目名を変更します。",
            properties: [
                "path": string("対象パス"),
                "new_name": string("新しいファイル名。パスは含めません")
            ],
            required: ["path", "new_name"], idempotent: false
        ),
        tool(
            "files_trash", "Trashへ移動", "項目を完全削除せずmacOSのTrashへ移動します。",
            properties: ["path": string("対象パス")],
            required: ["path"], destructive: true, idempotent: false
        ),
        tool(
            "apps_list_running", "実行中アプリ", "実行中の通常アプリを一覧します。",
            properties: [:], required: [], readOnly: true, idempotent: true
        ),
        tool(
            "apps_list_installed", "インストール済みアプリ", "標準Applicationsフォルダにあるアプリを一覧します。",
            properties: [:], required: [], readOnly: true, idempotent: true
        ),
        tool(
            "apps_open", "アプリ起動", "bundle identifierを指定してアプリを起動します。",
            properties: ["bundle_identifier": string("例: com.apple.TextEdit")],
            required: ["bundle_identifier"], idempotent: true
        ),
        tool(
            "apps_activate", "アプリ前面化", "実行中アプリを前面化します。",
            properties: ["bundle_identifier": string("例: com.apple.TextEdit")],
            required: ["bundle_identifier"], idempotent: true
        ),
        tool(
            "process_run", "プログラム直接実行", "shellを介さず、PATH解決した実行ファイルへ引数配列を直接渡します。stdout、stderr、終了コードを返します。",
            properties: [
                "executable": string("実行ファイル名またはパス。名前だけの場合はPATHから解決します"),
                "arguments": stringArray("引数配列。shell展開は行いません"),
                "working_directory": string("作業ディレクトリ。省略時はMCP起動ディレクトリ"),
                "environment": stringMap("追加・上書きする環境変数"),
                "stdin": string("標準入力のUTF-8テキスト。省略時は空"),
                "timeout_seconds": number("実行を停止するまでの秒数。省略時は完了まで待ちます")
            ],
            required: ["executable"], destructive: true, idempotent: false, openWorld: true
        )
    ]

    private static func tool(
        _ name: String, _ title: String, _ description: String,
        properties: [String: JSONValue], required: [String],
        readOnly: Bool = false, destructive: Bool = false, idempotent: Bool, openWorld: Bool = false
    ) -> MCPTool {
        MCPTool(name: name, title: title, description: description,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)
            ]),
            outputSchema: .object(["type": .string("object")]),
            annotations: MCPToolAnnotations(readOnlyHint: readOnly, destructiveHint: destructive || !readOnly,
                idempotentHint: idempotent, openWorldHint: openWorld))
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "minimum": .number(1), "description": .string(description)])
    }
    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "exclusiveMinimum": .number(0), "description": .string(description)])
    }
    private static func stringArray(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
    private static func stringMap(_ description: String) -> JSONValue {
        .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")]), "description": .string(description)])
    }
}
