# Offline diagnostic: preserve sqlite3's fork warning and verify the parent DB.
require "sqlite3"
require "tmpdir"
require "json"

Dir.mktmpdir("m12cs3-sqlite-") do |root|
  path = File.join(root, "metadata.sqlite3")
  database = SQLite3::Database.new(path)
  database.busy_timeout(5000)
  database.execute("PRAGMA journal_mode=WAL")
  database.execute("CREATE TABLE evidence (id INTEGER PRIMARY KEY, value TEXT)")
  observations = 30.times.map do |index|
    database.execute("INSERT INTO evidence(value) VALUES (?)", ["before-#{index}"])
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Marshal.dump({closed: database.closed?, entries: Dir.children(root).sort}, writer)
      writer.close
      exit! 0
    end
    writer.close
    child = Marshal.load(reader)
    reader.close
    Process.wait(pid)
    raise "child failure" unless $?.success? && child.fetch(:closed)
    raise "parent connection closed" if database.closed?
    database.execute("INSERT INTO evidence(value) VALUES (?)", ["after-#{index}"])
    child
  end
  count = database.get_first_value("SELECT count(*) FROM evidence")
  integrity = database.get_first_value("PRAGMA integrity_check")
  database.close
  reopened = SQLite3::Database.new(path)
  persisted = reopened.get_first_value("SELECT count(*) FROM evidence")
  reopened.close
  raise "persistence failure" unless count == 60 && persisted == 60 && integrity == "ok"
  puts JSON.pretty_generate(iterations: observations.size, child_connections_closed: observations.all? { |entry| entry[:closed] }, parent_rows: count, reopened_rows: persisted, integrity_check: integrity)
end
