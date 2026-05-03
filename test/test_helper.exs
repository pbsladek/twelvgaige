ExUnit.configure(
  exclude: [
    :integration,
    :daemon,
    :persistence,
    :provider_live,
    :k8s_live,
    :slow
  ]
)

Application.put_env(:twelvgaige, :discover_breech?, false)

ExUnit.start()
