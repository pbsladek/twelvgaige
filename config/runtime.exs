import Config

enabled? = fn name ->
  System.get_env(name, "") |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
end

positive_integer = fn name, default ->
  case Integer.parse(System.get_env(name, "")) do
    {value, ""} when value > 0 -> value
    _other -> default
  end
end

if enabled?.("TWELVGAIGE_OPERATIONS_ENABLED") do
  data_root =
    System.get_env("TWELVGAIGE_DATA_ROOT") ||
      case :os.type() do
        {:unix, :darwin} ->
          Path.join([System.user_home!(), "Library", "Application Support", "Twelvgaige"])

        {:win32, _} ->
          Path.join(System.get_env("LOCALAPPDATA") || System.user_home!(), "Twelvgaige")

        _other ->
          Path.join(
            System.get_env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share"),
            "twelvgaige"
          )
      end

  machine_name = System.get_env("TWELVGAIGE_PODMAN_MACHINE", "twelvgaige")

  operations = [
    data_root: data_root,
    raw_retention_days: positive_integer.("TWELVGAIGE_RAW_RETENTION_DAYS", 30),
    security_retention_days: positive_integer.("TWELVGAIGE_SECURITY_RETENTION_DAYS", 90),
    audit_checkpoint_external_path: System.get_env("TWELVGAIGE_AUDIT_CHECKPOINT_EXTERNAL_PATH"),
    backends: %{
      podman: Twelvgaige.Sandbox.Backend.Podman,
      apple_container: Twelvgaige.Sandbox.Backend.AppleContainer
    },
    backend_opts: %{
      podman: [allowed_roots: [data_root], machine_name: machine_name],
      apple_container: [allowed_roots: [data_root]]
    }
  ]

  config :twelvgaige, :operations_control_plane, operations
end
