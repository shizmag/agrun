require_relative "test_helper"
require "open3"

class M12cs3LspFixtureTest < Minitest::Test
  def test_real_framed_initialize_document_operation_and_shutdown
    skip "set AGRU_M12CS3_LSP=1 for offline Node fixture test" unless ENV["AGRU_M12CS3_LSP"] == "1"
    in_tmp do |workspace|
      transcript = File.join(workspace, "lsp.jsonl")
      messages = [
        {id: 1, method: "initialize", params: {capabilities: {}}},
        {method: "initialized", params: {}},
        {method: "textDocument/didOpen", params: {textDocument: {uri: "file:///workspace/input.agru", languageId: "plaintext", version: 1, text: "x"}}},
        {id: 2, method: "textDocument/hover", params: {textDocument: {uri: "file:///workspace/input.agru"}, position: {line: 0, character: 0}}},
        {id: 3, method: "shutdown"},
        {method: "exit"}
      ]
      input = messages.map do |message|
        body = JSON.generate({jsonrpc: "2.0"}.merge(message))
        "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
      end.join
      output, error, status = Open3.capture3({"AGRU_LSP_TRANSCRIPT" => transcript}, "node",
        File.expand_path("support/m12cs3_lsp_server.cjs", __dir__), stdin_data: input)
      assert status.success?, error
      responses = []
      until output.empty?
        header, body = output.split("\r\n\r\n", 2)
        length = Integer(header.delete_prefix("Content-Length: "))
        responses << JSON.parse(body.byteslice(0, length))
        output = body.byteslice(length..) || ""
      end
      assert_equal [1, nil, 2, 3], responses.map { |response| response["id"] }
      assert_equal "AGRU_LSP_HOVER", responses[2].dig("result", "contents", "value")
      assert_equal "AGRU_LSP_DOCUMENT_OBSERVED", responses[1].dig("params", "diagnostics", 0, "message")
      records = File.readlines(transcript).map { |line| JSON.parse(line) }
      assert_equal "launch", records.first["event"]
      assert_equal messages.map { |message| message[:method] }, records.drop(1).map { |record| record["method"] }
    end
  end
end
