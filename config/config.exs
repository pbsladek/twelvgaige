import Config

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :twelvgaige, :test_provider_ids, if(config_env() == :test, do: ["mock"], else: [])
config :twelvgaige, :allow_test_agent_fallback, config_env() == :test
