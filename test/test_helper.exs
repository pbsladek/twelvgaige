ExUnit.configure(
  exclude: [
    :integration,
    :daemon,
    :persistence,
    :provider_live,
    :keychain_live,
    :sqlcipher_live,
    :k8s_live,
    :slow
  ]
)

base_tmp = if File.dir?("/tmp"), do: "/tmp", else: System.tmp_dir!()

test_tmp =
  Path.join(base_tmp, "tg-#{:os.getpid()}-#{System.unique_integer([:positive])}")

File.mkdir_p!(test_tmp)

System.put_env("TMPDIR", test_tmp)
System.put_env("TMP", test_tmp)
System.put_env("TEMP", test_tmp)

Application.put_env(:twelvgaige, :discover_breech?, false)

ExUnit.start()

ExUnit.after_suite(fn _result ->
  File.rm_rf(test_tmp)
end)
