# Run once: mix run test/support/self_update_fixtures/make_fixtures.exs
#
# Produces:
#   test/support/self_update_fixtures/ok.tar.gz         — normal tarball
#   test/support/self_update_fixtures/traversal.tar.gz  — contains an entry at "../evil"
#   test/support/self_update_fixtures/ok.zip            — normal zip

dir = Path.expand(".", __DIR__)
File.mkdir_p!(dir)

stage = Path.join(dir, "_stage")
File.rm_rf!(stage)
File.mkdir_p!(Path.join(stage, "ok/bin"))
File.write!(Path.join(stage, "ok/bin/scry_2"), "#!/bin/sh\necho ok\n")
File.chmod!(Path.join(stage, "ok/bin/scry_2"), 0o755)

# ok.tar.gz
:ok =
  :erl_tar.create(
    Path.join(dir, "ok.tar.gz") |> String.to_charlist(),
    [{~c"bin/scry_2", Path.join(stage, "ok/bin/scry_2") |> String.to_charlist()}],
    [:compressed]
  )

# traversal.tar.gz — entry names "../evil" pointing at a real file
:ok =
  :erl_tar.create(
    Path.join(dir, "traversal.tar.gz") |> String.to_charlist(),
    [{~c"../evil", Path.join(stage, "ok/bin/scry_2") |> String.to_charlist()}],
    [:compressed]
  )

# ok.zip
file_contents = File.read!(Path.join(stage, "ok/bin/scry_2"))

{:ok, _} =
  :zip.create(
    Path.join(dir, "ok.zip") |> String.to_charlist(),
    [{~c"bin/scry_2.bat", file_contents}]
  )

File.rm_rf!(stage)
IO.puts("fixtures generated in #{dir}")
IO.puts("files: #{Enum.join(File.ls!(dir), ", ")}")
